import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// Why a ``UDPExchange`` ended without a reply.
enum UDPExchangeFailure: Error, Equatable {
  /// `socket(2)` failed.
  case socketCreationFailed(errno: Int32)
  /// `O_NONBLOCK` could not be read or set on the new socket.
  case nonBlockingFailed(errno: Int32)
  /// The request never left whole: a hard send error, a short count (`errno` is `nil`), or send
  /// buffer or interface queue pressure that outlasted the deadline.
  case sendFailed(errno: Int32?)
  /// The peer's host answered that nothing is listening on the port (an ICMP port unreachable,
  /// reported by the kernel as `ECONNREFUSED`). `rtt` is the time from sending to the refusal.
  case refused(rtt: TimeInterval)
  /// The network reported the peer unreachable (`EHOSTUNREACH` or `ENETUNREACH`). `rtt` is the
  /// time from sending to the report.
  case unreachable(errno: Int32, rtt: TimeInterval)
  /// `recv` failed with an errno not listed above.
  case receiveFailed(errno: Int32)
  /// No datagram arrived before the deadline.
  case timedOut
}

/// The first datagram back that the caller accepted, and how long it took.
struct UDPExchangeReply: Sendable {
  let bytes: [UInt8]
  /// Seconds from the moment the request was sent to the moment the read handler took the reply.
  let rtt: TimeInterval
}

/// One UDP request and the first datagram back that answers it, on a non-blocking connected socket.
///
/// The wait holds no thread: a Dispatch read source delivers the reply, a timer on the same
/// monotonic clock ends the wait at the deadline, and cancelling the calling task ends it at
/// once. This type knows nothing about the protocol: it sends bytes and returns the first
/// datagram the caller's `accepts` check takes as addressed to this request, or a
/// ``UDPExchangeFailure``. The check answers only that question (for DNS, whether the datagram
/// carries the query's transaction ID); the caller validates the rest of what comes back.
///
/// Descriptor ownership: ``perform(family:request:timeout:receiveCapacity:accepts:configure:)`` owns the
/// socket until the read source exists and closes it itself if setup fails. From then on the
/// descriptor is closed exactly once, by the cancel handler of the last source watching it, and
/// the caller is resumed only after that close. Every source is activated as soon as it is
/// created, because libdispatch traps when a source that was never activated is released.
///
/// States and events. Everything after `start` runs on `queue`, so events never interleave. A
/// read is one `receiveDatagram` call (`recv(2)`, or the test seam), whatever the state.
///
/// A read is stamped before the call, and the stamp stands for the datagram's arrival. That holds
/// only for a datagram that was already queued when the read event fired: the first read of an
/// event, or a read retried after `EINTR`, which took nothing. So after the send, at most one
/// datagram or error is judged per read event. A read that consumed one and did not end the
/// exchange returns, and the next datagram gets its own event and its own stamp. Before the send,
/// the handler may read again within one event: everything it reads then is ignored, because
/// nothing in the handler can send.
///
///     State             Event                        Rule
///     setup             any setup step fails          close in setup, throw; no source exists
///     created           cancel before start          start sees the flag; finish, close, resume
///     unsent            read: datagram, empty, error  consume and ignore; it cannot answer this
///                                                    request (a stale datagram on a reused port)
///     unsent            send EINTR                   retry at once, inside the deadline
///     waiting to write  writable                     cancel the write source, retry the send
///     backing off       backoff timer                retry the send
///     any unsent        a retry starts at or after   not sent; deadlinePassed: sendFailed
///                       the deadline
///     any unsent        deadline timer               sendFailed (nothing left, so no evidence)
///     sent              read: datagram or empty,     success with the bytes, if before deadline
///                       accepted (or no check)
///     sent              read: datagram or empty,     consume and ignore; return and wait for the
///                       not accepted                 next read event, deadline unchanged (a stale
///                                                    or foreign datagram). A read error is never
///                                                    put to the check
///     sent              read: ECONNREFUSED           refused; EHOSTUNREACH, ENETUNREACH:
///                                                    unreachable (both with rtt); other errno:
///                                                    receiveFailed
///     sent              read after the deadline      deadlinePassed, before the timer runs
///     sent              deadline timer               timedOut
///     any but finished  task cancellation            CancellationError
///     finished          any event                    ignored: every handler checks `finished`
///                                                    before touching the descriptor
///
/// `finish` runs once (a second call returns): it cancels the timers and every source on the
/// descriptor. The last cancel handler closes the descriptor and resumes the caller, once.
final class UDPExchange: @unchecked Sendable {
  /// `recv` calls one read event may make. Only `EINTR`, which took nothing, and anything read
  /// before the request has left, which is ignored, repeat a call. After the send, one datagram or
  /// error is judged per event, so a peer that never stops sending costs one event per datagram
  /// and cannot hold the queue the deadline timer and cancellation run on.
  private static let receiveAttemptsPerEvent = 4

  /// Longest wait before retrying a send that failed with `ENOBUFS`. The socket reports writable
  /// at once in that state, so waiting for writability would spin (docs/EAGAIN-MECHANISM.md).
  private static let noBufferSpaceBackoff: DispatchTimeInterval = .milliseconds(1)

  /// Sends `request` to the peer `configure` connects the socket to and returns the first
  /// datagram back that `accepts` takes.
  ///
  /// - Parameters:
  ///   - family: `AF_INET` or `AF_INET6`.
  ///   - request: One datagram, sent whole or not at all.
  ///   - timeout: Seconds from the start of the exchange until it gives up. Validated by the
  ///     caller: finite and greater than zero.
  ///   - receiveCapacity: Bytes read from the reply; a longer datagram is truncated to this.
  ///   - accepts: Whether a datagram read after the send is addressed to this request. One it
  ///     rejects is consumed and ignored, and the wait goes on to the same deadline. `nil` accepts
  ///     every datagram. Runs on the exchange's queue; it must not block.
  ///   - configure: Binds and connects the new non-blocking socket. Runs before any source
  ///     exists; an error it throws closes the socket and is rethrown unchanged.
  /// - Throws: ``UDPExchangeFailure``, whatever `configure` throws, or `CancellationError` when
  ///   the calling task is cancelled.
  static func perform(
    family: Int32,
    request: [UInt8],
    timeout: TimeInterval,
    receiveCapacity: Int,
    accepts: (@Sendable (ArraySlice<UInt8>) -> Bool)? = nil,
    configure: (Int32) throws -> Void
  ) async throws -> UDPExchangeReply {
    try Task.checkCancellation()

    // Read on the async side: the dispatch queue that runs the exchange cannot see task-locals.
    let sendDatagram =
      TestSeams.sendDatagram ?? { fd, bytes in
        send(fd, bytes.baseAddress, bytes.count, 0)
      }
    let closeDescriptor = TestSeams.closeDescriptor ?? { fd in close(fd) }
    let receiveDatagram =
      TestSeams.receiveDatagram ?? { fd, buffer in
        recv(fd, buffer.baseAddress, buffer.count, 0)
      }

    let fd = socket(family, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { throw UDPExchangeFailure.socketCreationFailed(errno: errno) }

    do {
      // Shared with trace and ping; it reads `TestSeams.fileControl` here, on the async side.
      do {
        try setProbeSocketNonBlocking(fd)
      } catch TracerouteError.socketCreateFailed(let code, _) {
        throw UDPExchangeFailure.nonBlockingFailed(errno: code)
      }
      try configure(fd)
    } catch {
      _ = closeDescriptor(fd)
      throw error
    }

    let exchange = UDPExchange(
      fd: fd, request: request, timeout: timeout, receiveCapacity: receiveCapacity,
      accepts: accepts, sendDatagram: sendDatagram, receiveDatagram: receiveDatagram,
      closeDescriptor: closeDescriptor)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        exchange.start(continuation)
      }
    } onCancel: {
      exchange.cancel()
    }
  }

  private let fd: Int32
  private let request: [UInt8]
  private let deadline: DispatchTime
  private let accepts: (@Sendable (ArraySlice<UInt8>) -> Bool)?
  private let sendDatagram: TestSeams.SendDatagram
  private let receiveDatagram: TestSeams.ReceiveDatagram
  private let closeDescriptor: TestSeams.CloseDescriptor
  private let queue = DispatchQueue(label: "com.swiftftr.udp-exchange", qos: .userInitiated)

  // Guarded by `lock`: cancellation arrives on any thread.
  private let lock = NSLock()
  private var continuation: CheckedContinuation<UDPExchangeReply, Error>?
  private var started = false
  private var cancelRequested = false

  // Owned by `queue`.
  private var receiveBuffer: [UInt8]
  private var finished = false
  private var outcome: Result<UDPExchangeReply, Error>?
  private var readSource: DispatchSourceRead?
  private var writeSource: DispatchSourceWrite?
  private var deadlineTimer: DispatchSourceTimer?
  private var backoffTimer: DispatchSourceTimer?
  /// Sources created on `fd` whose cancel handler has not run yet.
  private var sourcesWatchingDescriptor = 0
  private var descriptorClosed = false
  private var sentAt: DispatchTime?
  private var lastSendErrno: Int32?

  private init(
    fd: Int32,
    request: [UInt8],
    timeout: TimeInterval,
    receiveCapacity: Int,
    accepts: (@Sendable (ArraySlice<UInt8>) -> Bool)?,
    sendDatagram: @escaping TestSeams.SendDatagram,
    receiveDatagram: @escaping TestSeams.ReceiveDatagram,
    closeDescriptor: @escaping TestSeams.CloseDescriptor
  ) {
    self.fd = fd
    self.request = request
    self.accepts = accepts
    self.receiveBuffer = [UInt8](repeating: 0, count: max(1, receiveCapacity))
    self.sendDatagram = sendDatagram
    self.receiveDatagram = receiveDatagram
    self.closeDescriptor = closeDescriptor
    // Clamped so an extreme timeout cannot overflow the clock; 10^18 ns is about 31 years.
    let nanoseconds = UInt64(min(max(timeout, 0) * 1_000_000_000, 1e18))
    self.deadline = DispatchTime(
      uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + nanoseconds)
  }

  private func start(_ continuation: CheckedContinuation<UDPExchangeReply, Error>) {
    lock.lock()
    self.continuation = continuation
    started = true
    let cancelled = cancelRequested
    lock.unlock()
    queue.async {
      if cancelled {
        self.finish(.failure(CancellationError()))
      } else {
        self.begin()
      }
    }
  }

  private func cancel() {
    lock.lock()
    guard !cancelRequested else {
      lock.unlock()
      return
    }
    cancelRequested = true
    let wasStarted = started
    lock.unlock()
    // Before `start`, the flag is enough: `start` sees it and finishes at once.
    if wasStarted { queue.async { self.finish(.failure(CancellationError())) } }
  }

  // MARK: Queue-owned

  private func begin() {
    guard !finished else { return }

    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { self.handleRead() }
    source.setCancelHandler { self.descriptorSourceDidCancel() }
    sourcesWatchingDescriptor += 1
    readSource = source
    source.activate()

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: deadline)
    timer.setEventHandler { self.deadlinePassed() }
    deadlineTimer = timer
    timer.activate()

    attemptSend()
  }

  private func attemptSend() {
    while !finished {
      // Checked before every attempt, including one a writable or backoff callback makes after
      // the deadline but before the deadline timer runs: a datagram sent then could only report a
      // missing reply, which is not evidence about the peer.
      let attemptStarted = DispatchTime.now()
      guard attemptStarted < deadline else {
        deadlinePassed()
        return
      }
      let sent = request.withUnsafeBytes { sendDatagram(fd, $0) }
      if sent == request.count {
        // Stamped before the call, so a thread descheduled once the datagram left cannot start
        // the clock after the reply was already on its way.
        sentAt = attemptStarted
        return
      }
      // A UDP send is all or nothing; a short count means the datagram did not leave whole.
      guard sent < 0 else {
        finish(.failure(UDPExchangeFailure.sendFailed(errno: nil)))
        return
      }
      let code = errno
      lastSendErrno = code
      guard DispatchTime.now() < deadline else {
        finish(.failure(UDPExchangeFailure.sendFailed(errno: code)))
        return
      }
      switch code {
      case EINTR:
        continue
      case EAGAIN, EWOULDBLOCK:
        waitForWritable()
        return
      case ENOBUFS:
        retryAfterBackoff()
        return
      default:
        finish(.failure(UDPExchangeFailure.sendFailed(errno: code)))
        return
      }
    }
  }

  /// The send buffer is full: retry the whole datagram once the socket drains.
  private func waitForWritable() {
    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { self.writable() }
    source.setCancelHandler { self.descriptorSourceDidCancel() }
    sourcesWatchingDescriptor += 1
    writeSource = source
    source.activate()
  }

  private func writable() {
    // Held locally: clearing the property may drop the last reference to the source.
    guard !finished, let source = writeSource else { return }
    writeSource = nil
    source.cancel()
    attemptSend()
  }

  /// The interface queue is full: retry after a short timer rather than a writability wait.
  private func retryAfterBackoff() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: min(DispatchTime.now() + Self.noBufferSpaceBackoff, deadline))
    timer.setEventHandler { self.backoffElapsed() }
    backoffTimer = timer
    timer.activate()
  }

  private func backoffElapsed() {
    guard !finished, let timer = backoffTimer else { return }
    backoffTimer = nil
    timer.cancel()
    attemptSend()
  }

  private func handleRead() {
    for _ in 0..<Self.receiveAttemptsPerEvent {
      guard !finished else { return }
      // Stamped before the call: the datagram is already queued when the read event runs (after
      // the send, this is the event's first read or a retry after EINTR, which took nothing), and
      // a thread descheduled inside `recv` must not add that delay to the round trip.
      let receivedAt = DispatchTime.now()
      let received = receiveBuffer.withUnsafeMutableBytes { receiveDatagram(fd, $0) }
      let code = received < 0 ? errno : 0
      if received < 0, code == EAGAIN || code == EWOULDBLOCK { return }
      if received < 0, code == EINTR { continue }

      // Whatever arrived, it arrived too late if the deadline has passed and the timer simply
      // has not run yet.
      guard receivedAt <= deadline else {
        deadlinePassed()
        return
      }

      // Before the request has left, nothing read can answer it: a datagram or error from an
      // earlier socket on the same port. It is consumed and ignored, and the send goes on. Reading
      // again is safe: nothing in this handler sends, so every later read in it is ignored too.
      guard let sentAt else { continue }
      let rtt = Self.seconds(from: sentAt, to: receivedAt)
      guard received >= 0 else {
        switch code {
        case ECONNREFUSED:
          finish(.failure(UDPExchangeFailure.refused(rtt: rtt)))
        case EHOSTUNREACH, ENETUNREACH:
          finish(.failure(UDPExchangeFailure.unreachable(errno: code, rtt: rtt)))
        default:
          finish(.failure(UDPExchangeFailure.receiveFailed(errno: code)))
        }
        return
      }

      // Zero bytes is an empty datagram, judged like any other. One the caller does not accept is
      // not addressed to this request. Return rather than read again: a datagram the next read
      // returns may have arrived after this event's stamp, even after the deadline.
      let datagram = receiveBuffer.prefix(received)
      if let accepts, !accepts(datagram) { return }
      finish(.success(UDPExchangeReply(bytes: Array(datagram), rtt: rtt)))
      return
    }
  }

  private func deadlinePassed() {
    let failure: UDPExchangeFailure =
      sentAt == nil ? .sendFailed(errno: lastSendErrno) : .timedOut
    finish(.failure(failure))
  }

  private func finish(_ result: Result<UDPExchangeReply, Error>) {
    guard !finished else { return }
    finished = true
    outcome = result

    deadlineTimer?.cancel()
    deadlineTimer = nil
    backoffTimer?.cancel()
    backoffTimer = nil

    // No source was ever created on the descriptor, so setup still owns it.
    guard sourcesWatchingDescriptor > 0 else {
      closeDescriptorAndResume()
      return
    }
    // The last cancel handler to run closes the descriptor.
    readSource?.cancel()
    readSource = nil
    writeSource?.cancel()
    writeSource = nil
  }

  /// Dispatch runs this on `queue` once a source is fully cancelled and no handler of it can
  /// still be using the descriptor.
  private func descriptorSourceDidCancel() {
    sourcesWatchingDescriptor -= 1
    if sourcesWatchingDescriptor == 0, finished { closeDescriptorAndResume() }
  }

  private func closeDescriptorAndResume() {
    precondition(!descriptorClosed, "UDPExchange closed its descriptor twice")
    descriptorClosed = true
    _ = closeDescriptor(fd)

    lock.lock()
    let pending = continuation
    continuation = nil
    lock.unlock()
    if let pending, let outcome { pending.resume(with: outcome) }
  }

  private static func seconds(from start: DispatchTime, to end: DispatchTime) -> TimeInterval {
    guard end.uptimeNanoseconds > start.uptimeNanoseconds else { return 0 }
    return TimeInterval(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
  }
}
