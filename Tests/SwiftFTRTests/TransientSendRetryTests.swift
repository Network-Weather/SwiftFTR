import Foundation
import Testing

@testable import SwiftFTR

/// Regression coverage for transient `sendto` pressure on the non-blocking
/// probe sockets.
///
/// Harness note: an ICMP `SOCK_DGRAM` socket cannot be pushed into
/// `EAGAIN`/`EWOULDBLOCK` by shrinking `SO_SNDBUF`. Datagram sends are atomic
/// and never occupy the send buffer, so `sbspace` stays full and a shrunken
/// buffer only yields `EMSGSIZE` once it drops below the packet size (measured
/// on macOS 15: 2000 back-to-back 64-byte ICMP sends on a socket with
/// `SO_SNDBUF` 128 all succeed).
///
/// An `AF_UNIX` `SOCK_STREAM` pair does hold bytes in the send buffer, so
/// filling one reproduces a real kernel `EWOULDBLOCK` on the exact `sendto`
/// call the probe path makes; `sendto` with a destination address on a
/// connected stream socket succeeds on macOS, so `sendTraceProbe` runs
/// unmodified against it.
///
/// Serialized: these tests assert on elapsed time, so they run one at a time
/// rather than competing with each other for the machine.
@Suite(.serialized)
struct TransientSendRetryTests {

  // MARK: - Errno classification

  @Test("Only buffer-pressure errnos are treated as transient")
  func transientErrnoClassification() {
    #expect(isTransientSendErrno(EAGAIN))
    #expect(isTransientSendErrno(EWOULDBLOCK))
    #expect(isTransientSendErrno(ENOBUFS))

    // NWX maps these to offline states and to a permissions diagnostic; they
    // must keep failing fast.
    #expect(!isTransientSendErrno(EHOSTUNREACH))
    #expect(!isTransientSendErrno(ENETDOWN))
    #expect(!isTransientSendErrno(ENETUNREACH))
    #expect(!isTransientSendErrno(EACCES))
    #expect(!isTransientSendErrno(EPERM))
    #expect(!isTransientSendErrno(EMSGSIZE))
    #expect(!isTransientSendErrno(EINVAL))
    #expect(!isTransientSendErrno(EBADF))
  }

  // MARK: - Trace burst

  @Test("A trace burst survives a send buffer that is full when it starts")
  func traceBurstSurvivesTransientSendPressure() throws {
    let pair = try BlockedSendPair()
    defer { pair.close() }
    let resolved = try resolveHost(host: "127.0.0.1", prefer: .v4)

    pair.fillSendBuffer()
    #expect(pair.rawSendErrno() == EWOULDBLOCK, "harness must start with a blocked socket")

    pair.startDraining(after: 0.03)

    // A deliberately generous deadline. What this test pins is that a blocked
    // burst recovers at all; `transientPressureFailsAtBudget` pins the budget.
    let deadline = monotonicNow() + 5.0
    let start = monotonicNow()
    for ttl in 1...30 {
      try sendTraceProbe(
        sockfd: pair.writer, resolved: resolved, identifier: 0x1234,
        sequence: UInt16(ttl), payloadSize: 56, retryDeadline: deadline)
    }
    let elapsed = monotonicNow() - start

    // The socket had no free space when the burst began, so these probes only
    // went out because the retry path waited for the drainer to make room.
    #expect(pair.drainedByteCount > 0)
    #expect(elapsed < 2.0)
  }

  @Test("A send that never clears fails with the transient errno at the budget")
  func transientPressureFailsAtBudget() throws {
    let pair = try BlockedSendPair()
    defer { pair.close() }
    let resolved = try resolveHost(host: "127.0.0.1", prefer: .v4)

    pair.fillSendBuffer()

    let budget: TimeInterval = 0.1
    let start = monotonicNow()
    let thrown = captureSendErrno {
      try sendTraceProbe(
        sockfd: pair.writer, resolved: resolved, identifier: 0x1234,
        sequence: 1, payloadSize: 56, retryDeadline: monotonicNow() + budget)
    }
    let elapsed = monotonicNow() - start

    #expect(thrown == EWOULDBLOCK)
    #expect(elapsed >= budget * 0.8)
    #expect(elapsed < budget + 1.0)
  }

  @Test("The retry budget is shared across the burst, not granted per probe")
  func retryBudgetIsSharedAcrossTheBurst() throws {
    let pair = try BlockedSendPair()
    defer { pair.close() }
    let resolved = try resolveHost(host: "127.0.0.1", prefer: .v4)

    pair.fillSendBuffer()

    // One deadline for the whole burst, exactly as the send loops compute it.
    let deadline = monotonicNow() + 0.1

    let firstThrown = captureSendErrno {
      try sendTraceProbe(
        sockfd: pair.writer, resolved: resolved, identifier: 0x1234,
        sequence: 1, payloadSize: 56, retryDeadline: deadline)
    }
    #expect(firstThrown == EWOULDBLOCK)

    // The first probe consumed the budget, so the next probe in the same burst
    // gets no further waiting. A per-probe budget would wait another 100 ms here.
    let start = monotonicNow()
    let secondThrown = captureSendErrno {
      try sendTraceProbe(
        sockfd: pair.writer, resolved: resolved, identifier: 0x1234,
        sequence: 2, payloadSize: 56, retryDeadline: deadline)
    }
    let elapsed = monotonicNow() - start

    #expect(secondThrown == EWOULDBLOCK)
    #expect(elapsed < 0.05)
  }

  @Test("Non-transient errnos propagate on the first attempt")
  func nonTransientErrnoFailsFast() throws {
    let resolved = try resolveHost(host: "127.0.0.1", prefer: .v4)

    // A closed descriptor makes sendto fail with EBADF immediately. The budget
    // is deliberately generous: a fail-fast errno must not consume any of it.
    let start = monotonicNow()
    let thrown = captureSendErrno {
      try sendTraceProbe(
        sockfd: -1, resolved: resolved, identifier: 0x1234,
        sequence: 1, payloadSize: 56, retryDeadline: monotonicNow() + 5.0)
    }
    let elapsed = monotonicNow() - start

    #expect(thrown == EBADF)
    #expect(elapsed < 0.5)
  }

  // MARK: - ENOBUFS

  @Test("ENOBUFS backs off on a sleep rather than spinning on poll")
  func enobufsBacksOffWithoutSpinning() throws {
    let pair = try BlockedDatagramPair()
    defer { pair.close() }

    pair.fillPeerReceiveBuffer()
    #expect(pair.rawSendErrno() == ENOBUFS)

    // The premise for sleeping instead of waiting on POLLOUT: ENOBUFS does not
    // describe this socket's send buffer, so the socket reports itself writable
    // straight away while sends keep failing.
    #expect(pair.isImmediatelyWritable())

    let budget: TimeInterval = 0.05
    var attempts = 0
    let start = monotonicNow()
    let thrown = captureSendErrno {
      _ = try sendRetryingTransientPressure(
        sockfd: pair.writer, deadline: monotonicNow() + budget
      ) {
        attempts += 1
        return pair.rawSend()
      }
    }
    let elapsed = monotonicNow() - start

    #expect(thrown == ENOBUFS)
    #expect(elapsed >= budget * 0.8)
    #expect(elapsed < budget + 1.0)
    // Roughly one attempt per millisecond of budget. Spinning on poll would run
    // this into the tens of thousands.
    #expect(attempts < 500, "ENOBUFS retries should sleep between attempts")
  }

  // MARK: - Ping

  @Test("A ping send survives a send buffer that is full when it starts")
  func pingSendSurvivesTransientSendPressure() throws {
    let pair = try BlockedSendPair()
    defer { pair.close() }
    let resolved = try resolveHost(host: "127.0.0.1", prefer: .v4)

    pair.fillSendBuffer()
    #expect(pair.rawSendErrno() == EWOULDBLOCK, "harness must start with a blocked socket")

    // The ping budget is a fixed internal constant, so the drainer releases the
    // socket quickly to leave room for scheduling jitter on a loaded machine.
    pair.startDraining(after: 0.002)

    let executor = PingExecutor(config: SwiftFTRConfig())
    let packet = makeICMPEchoRequest(identifier: 0x1234, sequence: 1, payloadSize: 56)

    // Ping timestamps come from the executor's clock, not `monotonicNow()`.
    let start = executor.monotonicTime()
    let sendTime = try executor.sendPacket(
      sockfd: pair.writer, packet: packet, to: resolved)
    let finish = executor.monotonicTime()

    // The socket had no free space when the send began, so it only went out
    // because the retry path waited for the drainer to make room.
    #expect(pair.drainedByteCount > 0)

    // The reported send time is the attempt that reached the wire, so it lands
    // within the call rather than before the wait.
    #expect(sendTime >= start)
    #expect(sendTime <= finish)
  }

  @Test("A ping send that never clears reports the transient errno")
  func pingSendFailsAtBudget() throws {
    let pair = try BlockedSendPair()
    defer { pair.close() }
    let resolved = try resolveHost(host: "127.0.0.1", prefer: .v4)

    pair.fillSendBuffer()

    let executor = PingExecutor(config: SwiftFTRConfig())
    let packet = makeICMPEchoRequest(identifier: 0x1234, sequence: 1, payloadSize: 56)

    let start = monotonicNow()
    let thrown = captureSendErrno {
      _ = try executor.sendPacket(sockfd: pair.writer, packet: packet, to: resolved)
    }
    let elapsed = monotonicNow() - start

    #expect(thrown == EWOULDBLOCK)
    #expect(elapsed >= pingSendRetryBudget * 0.8)
    #expect(elapsed < pingSendRetryBudget + 1.0)
  }
}

/// Runs `body` and returns the errno carried by the `TracerouteError.sendFailed`
/// it throws, or `nil` if it threw nothing or threw something else.
private func captureSendErrno(_ body: () throws -> Void) -> Int32? {
  do {
    try body()
    return nil
  } catch let error as TracerouteError {
    guard case .sendFailed(let code) = error else { return nil }
    return code
  } catch {
    return nil
  }
}

/// A connected `AF_UNIX` stream pair whose writer can be driven into a real
/// kernel `EWOULDBLOCK` and released again on demand.
private final class BlockedSendPair: @unchecked Sendable {
  let writer: Int32
  private let reader: Int32
  private let lock = NSLock()
  private var draining = false
  private var drainerRunning = false
  private var drainedBytes = 0
  private let drainerExited = DispatchSemaphore(value: 0)

  /// How many bytes the drainer has consumed so far. Every byte counted here is
  /// space the writer did not have when its burst started.
  var drainedByteCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return drainedBytes
  }

  init(sendBufferBytes: Int32 = 2048) throws {
    var descriptors: [Int32] = [-1, -1]
    let rc = socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors)
    guard rc == 0 else {
      throw TracerouteError.socketCreateFailed(errno: errno, details: "socketpair")
    }
    writer = descriptors[0]
    reader = descriptors[1]

    var size = sendBufferBytes
    _ = setsockopt(
      writer, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    let flags = fcntl(writer, F_GETFL, 0)
    _ = fcntl(writer, F_SETFL, flags | O_NONBLOCK)
    let readerFlags = fcntl(reader, F_GETFL, 0)
    _ = fcntl(reader, F_SETFL, readerFlags | O_NONBLOCK)
  }

  /// Writes until the kernel reports the send buffer full.
  func fillSendBuffer() {
    let chunk = [UInt8](repeating: 0x41, count: 512)
    while true {
      let sent = chunk.withUnsafeBytes { send(writer, $0.baseAddress, $0.count, 0) }
      if sent < 0 { return }
    }
  }

  /// The errno a bare 1-byte `send` reports right now, or 0 if it succeeded.
  func rawSendErrno() -> Int32 {
    var byte: UInt8 = 0x41
    let sent = send(writer, &byte, 1, 0)
    return sent < 0 ? errno : 0
  }

  /// Starts consuming from the reader `delay` after this call returns, which
  /// lets the writer's send buffer drain.
  ///
  /// The drainer runs on a dedicated thread rather than the global queue: the
  /// test suite saturates the global pool, and a drainer that cannot be
  /// scheduled turns a correctness test into a load test. This call returns only
  /// once that thread is running, so `delay` measures from a thread that already
  /// exists rather than from an unscheduled work item.
  func startDraining(after delay: TimeInterval) {
    lock.lock()
    draining = true
    drainerRunning = true
    lock.unlock()

    let reader = self.reader
    let ready = DispatchSemaphore(value: 0)
    let thread = Thread { [self] in
      ready.signal()
      Thread.sleep(forTimeInterval: delay)
      var buffer = [UInt8](repeating: 0, count: 64 * 1024)
      while shouldKeepDraining() {
        var descriptor = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
        if poll(&descriptor, 1, 20) > 0 {
          let received = buffer.withUnsafeMutableBytes {
            recv(reader, $0.baseAddress, $0.count, 0)
          }
          if received > 0 { recordDrained(received) }
        }
      }
      drainerExited.signal()
    }
    thread.stackSize = 512 * 1024
    thread.start()
    ready.wait()
  }

  func close() {
    lock.lock()
    let wasRunning = drainerRunning
    draining = false
    drainerRunning = false
    lock.unlock()
    if wasRunning { drainerExited.wait() }
    _ = Darwin.close(writer)
    _ = Darwin.close(reader)
  }

  private func shouldKeepDraining() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return draining
  }

  private func recordDrained(_ count: Int) {
    lock.lock()
    drainedBytes += count
    lock.unlock()
  }
}

/// An `AF_UNIX` datagram sender whose bound peer has a small, undrained receive
/// buffer. Sends into a full peer report `ENOBUFS`, which is the errno the
/// interface output queue raises on a real probe socket.
private final class BlockedDatagramPair: @unchecked Sendable {
  let writer: Int32
  private let reader: Int32
  private let path: String
  private var address = sockaddr_un()

  init(receiveBufferBytes: Int32 = 2048) throws {
    let socketPath =
      "/tmp/swiftftr-sendretry-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
    unlink(socketPath)

    let readerFD = socket(AF_UNIX, SOCK_DGRAM, 0)
    guard readerFD >= 0 else {
      throw TracerouteError.socketCreateFailed(errno: errno, details: "unix datagram reader")
    }
    var size = receiveBufferBytes
    _ = setsockopt(
      readerFD, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))

    var bound = sockaddr_un()
    bound.sun_family = sa_family_t(AF_UNIX)
    bound.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let capacity = MemoryLayout.size(ofValue: bound.sun_path)
    socketPath.withCString { source in
      withUnsafeMutablePointer(to: &bound.sun_path) { raw in
        raw.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
          _ = strncpy(destination, source, capacity - 1)
        }
      }
    }

    let rc = withUnsafePointer(to: &bound) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        Darwin.bind(readerFD, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard rc == 0 else {
      let code = errno
      _ = Darwin.close(readerFD)
      throw TracerouteError.socketCreateFailed(errno: code, details: "bind unix datagram")
    }

    let writerFD = socket(AF_UNIX, SOCK_DGRAM, 0)
    guard writerFD >= 0 else {
      let code = errno
      _ = Darwin.close(readerFD)
      unlink(socketPath)
      throw TracerouteError.socketCreateFailed(errno: code, details: "unix datagram writer")
    }
    let flags = fcntl(writerFD, F_GETFL, 0)
    _ = fcntl(writerFD, F_SETFL, flags | O_NONBLOCK)

    writer = writerFD
    reader = readerFD
    path = socketPath
    address = bound
  }

  /// One `sendto` into the peer, returning the raw syscall result.
  func rawSend() -> ssize_t {
    var destination = address
    let payload = [UInt8](repeating: 0x41, count: 56)
    return withUnsafePointer(to: &destination) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        payload.withUnsafeBytes { buffer in
          sendto(
            writer, buffer.baseAddress, buffer.count, 0, sa,
            socklen_t(MemoryLayout<sockaddr_un>.size))
        }
      }
    }
  }

  func rawSendErrno() -> Int32 {
    rawSend() < 0 ? errno : 0
  }

  /// Sends until the peer's receive buffer is full.
  func fillPeerReceiveBuffer() {
    while rawSend() >= 0 {}
  }

  /// Whether `poll` reports the writer writable without waiting.
  func isImmediatelyWritable() -> Bool {
    var descriptor = pollfd(fd: writer, events: Int16(POLLOUT), revents: 0)
    return poll(&descriptor, 1, 0) == 1 && (descriptor.revents & Int16(POLLOUT)) != 0
  }

  func close() {
    _ = Darwin.close(writer)
    _ = Darwin.close(reader)
    unlink(path)
  }
}
