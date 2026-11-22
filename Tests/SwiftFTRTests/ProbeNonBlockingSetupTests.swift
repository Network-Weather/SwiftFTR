import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// The UDP and TCP probes refuse to run on a socket they could not make non-blocking.
///
/// A blocking TCP socket makes `connect` wait for the kernel's own connect timeout, past the
/// probe's timeout and its cancellation, and a blocking UDP socket can park the probe's queue in
/// `recv` on a readable event with no datagram. So a failed `fcntl` must end the probe with a
/// socket-setup failure in its result, before anything is sent, with the socket closed.
///
/// Each failure is injected through `TestSeams.fileControl`. Every call runs under a watchdog, so
/// a probe that went on to wait for an answer fails rather than hangs. Nothing is bounded from
/// above in time: what is checked is the result, what reached the loopback fixture, and whether
/// the socket was closed.
@Suite("Probe socket non-blocking setup")
struct ProbeNonBlockingSetupTests {
  static let watchdog: TimeInterval = 15

  enum Step: String, CaseIterable, Sendable {
    case getFlags = "F_GETFL"
    case setFlags = "F_SETFL"

    var command: Int32 { self == .getFlags ? F_GETFL : F_SETFL }
  }

  // MARK: UDP

  @Test(
    "UDP probe reports a failed fcntl in its result and sends nothing", arguments: Step.allCases)
  func udpRefusesBlockingSocket(step: Step) async throws {
    let sink = try DatagramSink()
    let sockets = ProbeSocketLog()
    let (result, _) = try await TestSeams.$fileControl.withValue(sockets.failing(step.command)) {
      try await measure(within: Self.watchdog) {
        try await udpProbe(config: Self.udpConfig(port: sink.port))
      }
    }

    #expect(!result.isReachable)
    #expect(result.rtt == nil)
    #expect(result.responseType == nil, "\(result.responseType ?? "nil")")
    let message = result.error ?? ""
    #expect(message.contains("non-blocking"), "\(message)")
    #expect(message.contains(step.rawValue), "\(message)")
    #expect(message.contains("errno=\(EINVAL)"), "\(message)")
    #expect(!sockets.anyConnected, "the probe connected its blocking socket")
    #expect(sink.queued == 0, "a datagram was sent from a blocking socket")
    #expect(sockets.opened == 1, "fcntl was called on \(sockets.opened) sockets")
    #expect(sockets.allClosed, "the probe left its socket open")
  }

  @Test("UDP probe control: with fcntl passed through, it sends one datagram and times out")
  func udpControl() async throws {
    let sink = try DatagramSink()
    let sockets = ProbeSocketLog()
    let (result, _) = try await TestSeams.$fileControl.withValue(sockets.passThrough()) {
      try await measure(within: Self.watchdog) {
        try await udpProbe(config: Self.udpConfig(port: sink.port))
      }
    }

    #expect(result.responseType == "timeout", "\(result.error ?? "nil")")
    #expect(sockets.anyConnected, "the probe never connected its socket")
    // Loopback delivery is asynchronous to `send`, so wait for the datagram to land.
    #expect(await eventually(within: 10) { sink.queued == 1 }, "\(sink.queued) datagrams queued")
    #expect(sockets.opened == 1, "fcntl was called on \(sockets.opened) sockets")
    #expect(sockets.leftNonBlocking, "the probe's socket was not non-blocking")
    #expect(sockets.allClosed, "the probe left its socket open")
  }

  /// Bound to a loopback source address so the probe's socket has a local address unique to it
  /// before `fcntl`, which is how ``ProbeSocketLog`` tells whether it was closed.
  static func udpConfig(port: UInt16) -> UDPProbeConfig {
    UDPProbeConfig(
      host: "127.0.0.1", port: Int(port), timeout: 0.3, payload: Data("probe".utf8),
      sourceIP: "127.0.0.1")
  }

  // MARK: TCP

  @Test(
    "TCP probe reports a failed fcntl in its result and connects to nothing",
    arguments: Step.allCases)
  func tcpRefusesBlockingSocket(step: Step) async throws {
    let listener = try PendingConnectionListener()
    let sockets = ProbeSocketLog()
    let (result, _) = try await TestSeams.$fileControl.withValue(sockets.failing(step.command)) {
      try await measure(within: Self.watchdog) {
        try await tcpProbe(config: Self.tcpConfig(port: listener.port))
      }
    }

    #expect(!result.isReachable)
    #expect(result.connectionState == .error)
    #expect(result.rtt == nil)
    let message = result.error ?? ""
    #expect(message.contains("non-blocking"), "\(message)")
    #expect(message.contains(step.rawValue), "\(message)")
    #expect(message.contains("errno=\(EINVAL)"), "\(message)")
    #expect(!sockets.anyConnected, "the probe connected its blocking socket")
    #expect(!listener.hasPendingConnection, "a connection reached the fixture")
    #expect(sockets.opened == 1, "fcntl was called on \(sockets.opened) sockets")
    #expect(sockets.allClosed, "the probe left its socket open")
  }

  @Test("TCP probe control: with fcntl passed through, it connects and reports open")
  func tcpControl() async throws {
    let listener = try PendingConnectionListener()
    let sockets = ProbeSocketLog()
    let (result, _) = try await TestSeams.$fileControl.withValue(sockets.passThrough()) {
      try await measure(within: Self.watchdog) {
        try await tcpProbe(config: Self.tcpConfig(port: listener.port))
      }
    }

    #expect(result.connectionState == .open, "\(result.error ?? "nil")")
    #expect(sockets.anyConnected, "the probe never connected its socket")
    // The listener learns of the handshake asynchronously to the probe, so wait for it.
    #expect(
      await eventually(within: 10) { listener.hasPendingConnection },
      "no connection reached the fixture")
    #expect(sockets.opened == 1, "fcntl was called on \(sockets.opened) sockets")
    #expect(sockets.leftNonBlocking, "the probe's socket was not non-blocking")
    #expect(sockets.allClosed, "the probe left its socket open")
  }

  static func tcpConfig(port: UInt16) -> TCPProbeConfig {
    TCPProbeConfig(host: "127.0.0.1", port: Int(port), timeout: 1, sourceIP: "127.0.0.1")
  }
}

// MARK: - Fixtures

/// Records each socket a probe passes to `fcntl`, to tell afterwards whether it was closed.
///
/// It keeps a duplicate of each descriptor, so the socket's local address stays allocated to it
/// and no other socket can be given that address. The probe's descriptor number is closed when it
/// no longer names a socket with that address: either nothing, or a different socket another test
/// was handed.
private final class ProbeSocketLog: @unchecked Sendable {
  private let lock = NSLock()
  private var sockets: [(fd: Int32, copy: Int32, address: [UInt8])] = []
  private var nonBlocking = false

  deinit { for socket in sockets { close(socket.copy) } }

  /// Refuses `command` with `EINVAL` and passes every other command to `fcntl`.
  func failing(_ command: Int32) -> TestSeams.FileControl {
    { [self] fd, cmd, argument in
      record(fd)
      guard cmd == command else { return fcntl(fd, cmd, argument) }
      errno = EINVAL
      return -1
    }
  }

  /// Passes every command to `fcntl`, noting whether a set left the socket non-blocking.
  func passThrough() -> TestSeams.FileControl {
    { [self] fd, cmd, argument in
      record(fd)
      let result = fcntl(fd, cmd, argument)
      if cmd == F_SETFL, result >= 0 {
        let flags = fcntl(fd, F_GETFL, 0)
        lock.lock()
        nonBlocking = flags >= 0 && flags & O_NONBLOCK != 0
        lock.unlock()
      }
      return result
    }
  }

  var opened: Int {
    lock.lock()
    defer { lock.unlock() }
    return sockets.count
  }

  var leftNonBlocking: Bool {
    lock.lock()
    defer { lock.unlock() }
    return nonBlocking
  }

  var allClosed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return sockets.allSatisfy { Self.localAddress($0.fd) != $0.address }
  }

  /// Whether any recorded socket has a peer: it got as far as `connect`. Read through the
  /// duplicate, which keeps the socket and its connection state after the probe closes its own.
  var anyConnected: Bool {
    lock.lock()
    defer { lock.unlock() }
    return sockets.contains { socket in
      var storage = sockaddr_storage()
      var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
      return withUnsafeMutablePointer(to: &storage) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          getpeername(socket.copy, $0, &length) == 0
        }
      }
    }
  }

  private func record(_ fd: Int32) {
    lock.lock()
    defer { lock.unlock() }
    guard !sockets.contains(where: { $0.fd == fd }) else { return }
    sockets.append((fd, dup(fd), Self.localAddress(fd) ?? []))
  }

  private static func localAddress(_ fd: Int32) -> [UInt8]? {
    var storage = sockaddr_storage()
    var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let result = withUnsafeMutablePointer(to: &storage) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    guard result == 0 else { return nil }
    return withUnsafeBytes(of: storage) { Array($0.prefix(Int(length))) }
  }
}

/// A loopback UDP port that nobody reads, so every datagram sent to it stays queued and countable.
private final class DatagramSink: @unchecked Sendable {
  let port: UInt16
  private let fd: Int32

  init() throws { (fd, port) = try bindLoopback(family: AF_INET, type: SOCK_DGRAM) }

  deinit { close(fd) }

  /// Datagrams waiting on the port, from `SO_NUMRCVPKT`, or -1 if it cannot be read.
  var queued: Int32 {
    var count: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(fd, SOL_SOCKET, SO_NUMRCVPKT, &count, &length) == 0 else { return -1 }
    return count
  }
}

/// A loopback TCP listener that never accepts, so a completed connection stays in its queue.
private final class PendingConnectionListener: @unchecked Sendable {
  let port: UInt16
  private let fd: Int32

  init() throws {
    let (bound, boundPort) = try bindLoopback(family: AF_INET, type: SOCK_STREAM)
    guard listen(bound, 8) == 0 else {
      let code = errno
      close(bound)
      throw FixtureError.socket("listen", code)
    }
    (fd, port) = (bound, boundPort)
  }

  deinit { close(fd) }

  /// Whether a completed connection is waiting to be accepted.
  var hasPendingConnection: Bool {
    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    return poll(&pfd, 1, 0) > 0 && pfd.revents & Int16(POLLIN) != 0
  }
}
