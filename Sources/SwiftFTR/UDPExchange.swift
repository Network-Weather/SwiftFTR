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

/// The first datagram the peer sent back, and how long it took.
struct UDPExchangeReply: Sendable {
  let bytes: [UInt8]
  /// Seconds from the moment the request was sent to the moment the read handler took the reply.
  let rtt: TimeInterval
}

/// One UDP request and the first datagram back, on a non-blocking connected socket.
///
/// The wait holds no thread: a Dispatch read source delivers the reply, a timer on the same
/// monotonic clock ends the wait at the deadline, and cancelling the calling task ends it at
/// once. This type knows nothing about the protocol: it sends bytes and returns the first
/// datagram, or a ``UDPExchangeFailure``. The caller validates what comes back.
///
/// Descriptor ownership: ``perform(family:request:timeout:receiveCapacity:configure:)`` owns the
/// socket until the read source exists and closes it itself if setup fails. From then on the
/// descriptor is closed exactly once, by the cancel handler of the last source watching it, and
/// the caller is resumed only after that close. Every source is activated as soon as it is
/// created, because libdispatch traps when a source that was never activated is released.
final class UDPExchange: @unchecked Sendable {
  /// `recv` calls one read event may make. Only `EINTR` repeats a call; the first datagram ends
  /// the exchange whatever it holds.
  private static let receiveAttemptsPerEvent = 4

  /// Longest wait before retrying a send that failed with `ENOBUFS`. The socket reports writable
  /// at once in that state, so waiting for writability would spin (docs/EAGAIN-MECHANISM.md).
  private static let noBufferSpaceBackoff: DispatchTimeInterval = .milliseconds(1)

  /// Sends `request` to the peer `configure` connects the socket to and returns the first
  /// datagram back.
  ///
  /// - Parameters:
  ///   - family: `AF_INET` or `AF_INET6`.
  ///   - request: One datagram, sent whole or not at all.
  ///   - timeout: Seconds from the start of the exchange until it gives up. Validated by the
  ///     caller: finite and greater than zero.
  ///   - receiveCapacity: Bytes read from the reply; a longer datagram is truncated to this.
  ///   - configure: Binds and connects the new non-blocking socket. Runs before any source
  ///     exists; an error it throws closes the socket and is rethrown unchanged.
  /// - Throws: ``UDPExchangeFailure``, whatever `configure` throws, or `CancellationError` when
  ///   the calling task is cancelled.
  static func perform(
    family: Int32,
    request: [UInt8],
    timeout: TimeInterval,
    receiveCapacity: Int,
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
      sendDatagram: sendDatagram, receiveDatagram: receiveDatagram,
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
    sendDatagram: @escaping TestSeams.SendDatagram,
    receiveDatagram: @escaping TestSeams.ReceiveDatagram,
    closeDescriptor: @escaping TestSeams.CloseDescriptor
  ) {
    self.fd = fd
    self.request = request
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
      let sent = request.withUnsafeBytes { sendDatagram(fd, $0) }
      if sent == request.count {
        sentAt = DispatchTime.now()
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
      let received = receiveBuffer.withUnsafeMutableBytes { receiveDatagram(fd, $0) }
      let code = received < 0 ? errno : 0
      let receivedAt = DispatchTime.now()
      if received < 0, code == EAGAIN || code == EWOULDBLOCK { return }
      if received < 0, code == EINTR { continue }

      // Whatever arrived, it arrived too late if the deadline has passed and the timer simply
      // has not run yet.
      guard receivedAt <= deadline else {
        deadlinePassed()
        return
      }

      let rtt = sentAt.map { Self.seconds(from: $0, to: receivedAt) } ?? 0
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

      // Zero bytes is an empty datagram, and the first datagram decides.
      finish(.success(UDPExchangeReply(bytes: Array(receiveBuffer.prefix(received)), rtt: rtt)))
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
