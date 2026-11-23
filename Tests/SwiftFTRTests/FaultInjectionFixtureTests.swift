import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// The fault-injection fixtures themselves: a fixture that misbehaves in the wrong way would make
/// every test built on it mean something else.
@Suite("FaultInjection: fixtures")
struct FaultInjectionFixtureTests {

  @Test("A stall gate that timed out does not release the next waiter; open() releases all")
  func stallGate() async throws {
    let gate = StallGate()
    gate.wait(limit: 0.01)
    let start = monotonicNow()
    gate.wait(limit: 0.25)
    #expect(monotonicNow() - start >= 0.2, "a timed-out wait released the next one")

    let released = FaultCounter()
    for _ in 0..<3 {
      Thread.detachNewThread {
        gate.wait(limit: 5)
        released.increment()
      }
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    gate.open()
    #expect(await eventually(within: 10) { released.value == 3 })
  }

  @Test("The watchdog fails an operation that never returns, without waiting for it")
  func watchdogFires() async throws {
    // The operation ignores cancellation and is held by a gate that opens only once the watchdog
    // has returned, so a watchdog that returns at all did so without waiting for it. The gate's
    // own limit ends the operation if a watchdog that waits holds the gate shut.
    let gate = StallGate()
    defer { gate.open() }
    let finished = FaultCounter()
    do {
      _ = try await measure(within: 0.2, diagnose: "fixture state") {
        await gate.waitAsync(limit: 20)
        finished.increment()
      }
      Issue.record("the watchdog did not fire")
    } catch let expired as WatchdogExpired {
      #expect(expired.diagnosis == "fixture state", "\(expired)")
    }
    #expect(finished.value == 0, "the watchdog returned only after the operation had ended")

    // Released, the abandoned operation ends, so nothing is stranded.
    gate.open()
    #expect(
      await eventually(within: 10) { finished.value == 1 }, "the abandoned operation never ended")
  }

  @Test("A loopback fixture is never handed the port of a socket bound to the unspecified address")
  func loopbackFixtureKeepsOffWildcardPorts() throws {
    // A probe socket the library sends on unbound takes an ephemeral port on the unspecified
    // address at its first send. A fixture later handed the same number on ::1 would receive
    // every loopback reply meant for the probe socket, and the operation would wait out its whole
    // window. Hold `held` such sockets and bind `binds` fixtures one at a time: were the kernel
    // free to hand out held ports, about held * binds / 16384 (some 31) would collide.
    let held = 128
    let binds = 4000
    var holders: [Int32] = []
    defer { for fd in holders { close(fd) } }
    var heldPorts = Set<UInt16>()
    for _ in 0..<held {
      let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
      guard fd >= 0 else { throw FixtureError.socket("socket", errno) }
      holders.append(fd)
      var any = sockaddr_in6()
      any.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
      any.sin6_family = sa_family_t(AF_INET6)
      let bound = withUnsafePointer(to: &any) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
        }
      }
      guard bound == 0 else { throw FixtureError.socket("bind", errno) }
      var actual = sockaddr_storage()
      var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
      _ = withUnsafeMutablePointer(to: &actual) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
      }
      heldPorts.insert(
        withUnsafeBytes(of: actual) {
          UInt16(bigEndian: $0.load(fromByteOffset: 2, as: UInt16.self))
        })
    }
    var collisions: [UInt16] = []
    for _ in 0..<binds {
      let (fd, port) = try bindLoopback(family: AF_INET6, type: SOCK_DGRAM)
      close(fd)
      if heldPorts.contains(port) { collisions.append(port) }
    }
    #expect(heldPorts.count == held)
    #expect(collisions.isEmpty, "fixtures were handed held ports: \(collisions)")
  }

  @Test("An IPv4 refusing UDP port is never handed to a dual-stack IPv6 socket")
  func refusingUDPPortKeepsOffDualStack() throws {
    // A dual-stack socket bound to [::] on a refusing port's number would receive the IPv4
    // datagrams meant to be refused, and the operation under test would see silence. Hold
    // `held` refusing ports and bind `binds` dual-stack sockets one at a time: were the kernel
    // free to hand out the held numbers, about held * binds / 16384 (some 16) would collide.
    let held = 64
    let binds = 4000
    let refusing = try (0..<held).map { _ in try RefusingUDPPort(family: AF_INET) }
    let heldPorts = Set(refusing.map(\.port))
    var collisions: [UInt16] = []
    for _ in 0..<binds {
      let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
      guard fd >= 0 else { throw FixtureError.socket("socket", errno) }
      defer { close(fd) }
      var off: Int32 = 0
      _ = setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
      var any = sockaddr_in6()
      any.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
      any.sin6_family = sa_family_t(AF_INET6)
      let bound = withUnsafePointer(to: &any) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
        }
      }
      guard bound == 0 else { throw FixtureError.socket("bind", errno) }
      var actual = sockaddr_storage()
      var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
      _ = withUnsafeMutablePointer(to: &actual) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
      }
      let port = withUnsafeBytes(of: actual) {
        UInt16(bigEndian: $0.load(fromByteOffset: 2, as: UInt16.self))
      }
      if heldPorts.contains(port) { collisions.append(port) }
    }
    #expect(heldPorts.count == held)
    #expect(collisions.isEmpty, "dual-stack sockets were handed refusing ports: \(collisions)")
    withExtendedLifetime(refusing) {}
  }

  @Test("The UDP responder hands a zero-byte request to its script")
  func udpZeroByteRequest() async throws {
    let responder = try LoopbackUDPResponder { _ in ([0x2A], 0) }
    defer { responder.stop() }
    let client = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    defer { close(client) }
    setReceiveTimeout(client, seconds: 1)
    var (address, length) = responder.address
    let sent = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(client, nil, 0, 0, $0, length) }
    }
    #expect(sent == 0)
    var reply = [UInt8](repeating: 0, count: 8)
    let received = recv(client, &reply, reply.count, 0)
    #expect(received == 1)
    #expect(responder.requests.value == 1)
  }

  @Test("The refusing TCP port resets connections and stays reserved")
  func refusingPort() throws {
    let refusing = try RefusingTCPPort()

    let client = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(client) }
    var (address, length) = loopbackAddress(family: AF_INET, port: refusing.port)
    // Non-blocking, so a SYN that is dropped rather than reset fails the poll's 10 s watchdog
    // instead of holding the test for the minute and more a blocking connect would wait.
    _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL, 0) | O_NONBLOCK)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, length) }
    }
    var code = errno
    if result == -1 && code == EINPROGRESS {
      var pending = pollfd(fd: client, events: Int16(POLLOUT), revents: 0)
      let ready = poll(&pending, 1, 10_000)
      #expect(ready == 1, "the connect was neither refused nor accepted within 10 s")
      var soError: Int32 = 0
      var soErrorLength = socklen_t(MemoryLayout<Int32>.size)
      _ = getsockopt(client, SOL_SOCKET, SO_ERROR, &soError, &soErrorLength)
      code = soError
    }
    #expect(code == ECONNREFUSED, "connect returned \(result), errno \(code)")

    // Nothing else may take the port while the fixture holds it.
    let rival = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(rival) }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(rival, $0, length) }
    }
    #expect(bound == -1 && errno == EADDRINUSE, "another socket could bind the refusing port")
  }

  @Test(
    "Stopping the TCP server does not wait for its handlers; stopAndWait() ends every one",
    arguments: [
      LoopbackTCPServer.Behavior.silent,
      .respond(response: Array("late".utf8), after: 30),
    ])
  func tcpServerStopDoesNotWaitAndStopAndWaitJoins(behavior: LoopbackTCPServer.Behavior)
    async throws
  {
    let exitGate = StallGate()
    defer { exitGate.open() }
    let server = try LoopbackTCPServer(behavior: behavior, exitGate: exitGate)
    let client = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(client) }
    var (address, length) = loopbackAddress(family: AF_INET, port: server.port)
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, length) }
    }
    #expect(connected == 0)
    if case .respond = behavior {
      // Sent at once, so it is waiting for the handler however late the handler or this task
      // runs, and read by the handler before stop(): a request still unread when the connection
      // closes turns the end-of-file checked below into a reset. The silent handler reads
      // nothing, so it is sent no request.
      _ = Darwin.send(client, "GET / HTTP/1.1\r\n\r\n", 18, 0)
    }
    #expect(await eventually(within: 10) { server.accepted.value == 1 })
    if case .respond = behavior {
      #expect(await eventually(within: 10) { server.requestsRead.value == 1 })
    }

    // The handler cannot finish while the exit gate is shut (its own limit is 30 s), so a stop()
    // that returns within the 10 s watchdog did so without waiting for it. Run on its own thread,
    // so a stop() that does wait cannot park this test's.
    let returned = await returnsWithin(10) { server.stop() }
    #expect(returned, "stop() waited for a handler")

    // stopAndWait() must not return until the gate opens: returning earlier means it did not wait
    // for the handler.
    let joined = FaultCounter()
    let join = Task {
      await server.stopAndWait()
      joined.increment()
    }
    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(joined.value == 0, "stopAndWait() returned while a handler was still running")

    // Released, the handler finishes and stopAndWait() returns, without waiting for the
    // handler's own 30 s behavior.
    exitGate.open()
    _ = try await measure(within: 10) { await join.value }
    #expect(joined.value == 1)

    // The connection was shut down, so the client sees end-of-file: 0, not a receive timeout.
    setReceiveTimeout(client, seconds: 1)
    var buffer = [UInt8](repeating: 0, count: 16)
    let received = recv(client, &buffer, buffer.count, 0)
    #expect(received == 0, "recv returned \(received), errno \(errno)")
  }

  /// Whether a fresh socket, with no reuse options, can bind `port` on loopback: false while
  /// another socket still holds it.
  static func canBind(type: Int32, port: UInt16) -> Bool {
    let probe = socket(AF_INET, type, 0)
    guard probe >= 0 else { return false }
    defer { close(probe) }
    var (address, length) = loopbackAddress(family: AF_INET, port: port)
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(probe, $0, length) }
    } == 0
  }

  @Test("A fake network keeps a closed probe socket's port taken until it stops")
  func fakeNetworkHoldsProbePorts() async throws {
    // A reply the network sends after the operation closed its probe socket goes to that port
    // number; while the network can still send, no other socket may be handed it.
    let network = try FakeICMPNetwork { _ in [] }
    defer { network.stop() }
    let probe = try network.makeSocket(AF_INET)
    var (any, anyLength) = loopbackAddress(family: AF_INET, port: 0)
    let bound = withUnsafePointer(to: &any) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(probe, $0, anyLength) }
    }
    #expect(bound == 0)
    var actual = sockaddr_storage()
    var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
    _ = withUnsafeMutablePointer(to: &actual) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(probe, $0, &length) }
    }
    let port = withUnsafeBytes(of: actual) {
      UInt16(bigEndian: $0.load(fromByteOffset: 2, as: UInt16.self))
    }
    close(probe)
    #expect(!Self.canBind(type: SOCK_DGRAM, port: port), "the closed probe socket's port was free")
    network.stop()
    #expect(
      await eventually(within: 10) { Self.canBind(type: SOCK_DGRAM, port: port) },
      "the port stayed taken after the network stopped")
  }

  @Test("A stopped UDP fixture's own thread closes its socket")
  func udpFixtureThreadClosesItsSocket() async throws {
    let responder = try LoopbackUDPResponder { _ in nil }
    let network = try FakeICMPNetwork { _ in [] }
    let ports = [responder.port, network.port]
    #expect(!ports.contains { Self.canBind(type: SOCK_DGRAM, port: $0) }, "a port was not held")
    responder.stop()
    network.stop()
    // stop() returns at once and leaves the socket to the serve thread, which must close it.
    let released = await eventually(within: 10) {
      ports.allSatisfy { Self.canBind(type: SOCK_DGRAM, port: $0) }
    }
    #expect(released, "a serve thread did not close its socket")
  }
}
