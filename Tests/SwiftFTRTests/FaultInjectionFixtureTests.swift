import Foundation
@_spi(Test) import SwiftFTR
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
  func loopbackFixtureKeepsOffWildcardPorts() async throws {
    // Some 4,000 socket calls: on a thread of their own, not the cooperative pool, which a
    // repeated run of this test would otherwise hold for seconds at a time.
    let (heldCount, collisions) = try await onOwnThread { try Self.wildcardPortCollisions() }
    #expect(heldCount == 128)
    #expect(collisions.isEmpty, "fixtures were handed held ports: \(collisions)")
  }

  static func wildcardPortCollisions() throws -> (heldCount: Int, collisions: [UInt16]) {
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
    return (heldPorts.count, collisions)
  }

  @Test("An IPv4 refusing UDP port is never handed to a dual-stack IPv6 socket")
  func refusingUDPPortKeepsOffDualStack() async throws {
    // On a thread of its own, for the reason given in loopbackFixtureKeepsOffWildcardPorts.
    let (heldCount, collisions) = try await onOwnThread { try Self.dualStackCollisions() }
    #expect(heldCount == 64)
    #expect(collisions.isEmpty, "dual-stack sockets were handed refusing ports: \(collisions)")
  }

  static func dualStackCollisions() throws -> (heldCount: Int, collisions: [UInt16]) {
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
    withExtendedLifetime(refusing) {}
    return (heldPorts.count, collisions)
  }

  @Test("The UDP responder hands a zero-byte request to its script")
  func udpZeroByteRequest() async throws {
    let responder = try LoopbackUDPResponder(accepts: .payload([])) { _ in ([0x2A], 0) }
    defer { responder.stop() }
    let client = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    defer { close(client) }
    // Generous: the answer ends the wait, and loopback can be slow on a loaded host.
    setReceiveTimeout(client, seconds: 10)
    var (address, length) = responder.address
    let sent = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(client, nil, 0, 0, $0, length) }
    }
    #expect(sent == 0)
    // On a thread of its own, so the blocking read holds no cooperative thread. The client's
    // ephemeral port can receive another test's stray, so read until the responder's one byte.
    let answered = try await onOwnThread { () -> Bool in
      var reply = [UInt8](repeating: 0, count: 64)
      while true {
        let received = recv(client, &reply, reply.count, 0)
        if received < 0 { return false }
        if received == 1 && reply[0] == 0x2A { return true }
      }
    }
    #expect(answered, "the responder never answered the zero-byte request")
    // Counted before the reply was sent.
    #expect(responder.requests.value == 1)
  }

  @Test("The UDP responder answers its query after a short and an empty stray queued ahead")
  func udpResponderIgnoresStrays() async throws {
    // The DNS fault script writes into the request's header, so a stray shorter than one handed
    // to it would end the test process (#169).
    let gate = StallGate()
    defer { gate.open() }
    let name = "stray.example"
    let responder = try LoopbackUDPResponder(accepts: .dnsQuery(named: name), readsAfter: gate) {
      query in
      (FaultInjectionWireTests.dnsResponse(to: query, answers: FaultInjectionWireTests.aRecord), 0)
    }
    defer { responder.stop() }
    #expect(Strays.send(to: responder.port))
    try #require(
      await eventually(within: 10) { responder.queued >= 2 }, "queued: \(responder.queued)")
    gate.open()

    let (answers, _) = try await measure(within: 20) {
      try await __dnsQuery(
        server: "127.0.0.1", port: responder.port, name: name, type: 1, timeout: 10)
    }
    #expect(answers.first?.rdata == Data([192, 0, 2, 9]))
    #expect(responder.requests.value == 1)
    #expect(responder.ignored.value >= 2, "ignored: \(responder.ignored.value)")
  }

  @Test("The DNS filter takes a query for its name and nothing shorter, other or malformed")
  func dnsQueryFilter() {
    let query = Array(
      Data([0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]) + __dnsEncodeQName("Stray.Example")
        + Data([0, 1, 0, 1]))
    let filter = DatagramFilter.dnsQuery(named: "stray.example")
    #expect(filter.accepts(query))
    #expect(DatagramFilter.dnsQuery().accepts(query))
    #expect(!DatagramFilter.dnsQuery(named: "other.example").accepts(query))
    // Every prefix is too short to carry the question's type and class.
    for length in 0..<query.count { #expect(!filter.accepts(Array(query.prefix(length)))) }
    var reply = query
    reply[2] |= 0x80
    #expect(!filter.accepts(reply), "a response is not a query")
    let echoReply: [UInt8] = [0, 0, 0, 0, 0, 1, 0, 1] + [UInt8](repeating: 0x61, count: 8)
    #expect(!DatagramFilter.dnsQuery().accepts(echoReply))
    let root: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1]
    #expect(!DatagramFilter.dnsQuery().accepts(root), "a query for the root has no label to read")
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

  @Test("A stopped TCP server ends a connection with end-of-file even with its request unread")
  func tcpServerStopDiscardsUnreadRequest() async throws {
    // Part of LoopbackTCPServer.stop()'s contract: a request already queued, unread, when the
    // server stops is discarded with the read side and the client sees end-of-file. (One still
    // in flight at the stop, or sent after it, usually resets the connection instead; that is
    // why a test checking for end-of-file must not stop the server with a request in flight.)
    let exitGate = StallGate()
    defer { exitGate.open() }
    let server = try LoopbackTCPServer(behavior: .silent, exitGate: exitGate)
    defer { server.stop() }
    let client = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(client) }
    var (address, length) = loopbackAddress(family: AF_INET, port: server.port)
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, length) }
    }
    #expect(connected == 0)
    #expect(await eventually(within: 10) { server.accepted.value == 1 })
    _ = Darwin.send(client, "GET / HTTP/1.1\r\n\r\n", 18, 0)
    // Nothing left in the client's send buffer means the server's kernel has acknowledged it,
    // so it is in the server's receive buffer, which the silent handler never reads.
    #expect(
      await eventually(within: 10) {
        var unsent: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(client, SOL_SOCKET, SO_NWRITE, &unsent, &size)
        return unsent == 0
      })
    server.stop()
    exitGate.open()
    await server.stopAndWait()
    setReceiveTimeout(client, seconds: 1)
    var buffer = [UInt8](repeating: 0, count: 16)
    let received = recv(client, &buffer, buffer.count, 0)
    #expect(received == 0, "recv returned \(received), errno \(errno): not end-of-file")
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

  /// An echo request for `seq`, as the library sends one on a datagram socket.
  static func echoRequest(seq: UInt16) -> [UInt8] {
    [8, 0, 0, 0, 0x12, 0x34, UInt8(seq >> 8), UInt8(seq & 0xFF)] + [UInt8](repeating: 0, count: 8)
  }

  /// Sends `bytes` to the network on `fd` as the library would, through `send` (the isolating
  /// send, or plain `sendto` when `nil`).
  static func sendProbe(
    _ bytes: [UInt8], on fd: Int32, to network: FakeICMPNetwork, with send: TestSeams.SendProbe?
  ) -> Int {
    var address = network.resolved.address
    let length = network.resolved.addressLen
    return bytes.withUnsafeBytes { raw in
      withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
          if let send { return send(fd, raw, sa, length) }
          return sendto(fd, raw.baseAddress, raw.count, 0, sa, length)
        }
      }
    }
  }

  static func localPort(_ fd: Int32) -> UInt16 {
    var local = sockaddr_storage()
    var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
    _ = withUnsafeMutablePointer(to: &local) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    return withUnsafeBytes(of: local) {
      UInt16(bigEndian: $0.load(fromByteOffset: 2, as: UInt16.self))
    }
  }

  @Test(
    "A probe socket the fake network connects receives only what the network sends",
    arguments: [true, false])
  func isolatedProbeSocketRefusesStrays(isolated: Bool) async throws {
    // Isolated: the socket is connected to the network on its first send, so the kernel refuses
    // a short and an empty stray from other sockets; each stray's sender is connected to the
    // probe's port, so a refusal comes back to it as ECONNREFUSED. Not isolated (main's
    // behaviour, the control): both strays are queued beside the network's own reply.
    let network = try FakeICMPNetwork { _ in [] }
    defer { network.stop() }
    let probe = try network.makeSocket(AF_INET)
    defer { close(probe) }
    let send = isolated ? FakeICMPNetwork.connectingSend : nil
    let request = Self.echoRequest(seq: 1)
    #expect(Self.sendProbe(request, on: probe, to: network, with: send) == request.count)
    #expect(await eventually(within: 10) { network.probes.value == 1 })

    // A sender of its own per stray, each connected to the probe's port: a refusal of the first
    // would otherwise come back as the second send's error, though isolation had worked.
    var senders: [Int32] = []
    defer { for sender in senders { close(sender) } }
    var (address, length) = loopbackAddress(family: AF_INET, port: Self.localPort(probe))
    for datagram in [Strays.short, Strays.empty] {
      let sender = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
      try #require(sender >= 0)
      senders.append(sender)
      let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sender, $0, length) }
      }
      try #require(connected == 0)
      #expect(datagram.withUnsafeBytes { Darwin.send(sender, $0.baseAddress, $0.count, 0) } >= 0)
    }
    #expect(
      network.inject(.init(ICMPWire.echoReply(family: AF_INET, id: 0x1234, seq: 1)), to: probe))

    if isolated {
      // The refusal ends the wait as soon as it comes back. ICMP errors are rate-limited host
      // wide, so on a loaded host it may not come, and the wait then ends at its bound: a stray
      // still in flight after it would go unseen, which can only let this pass, never fail it.
      // A refusal is read once and then gone, so each sender's is remembered across polls.
      let refusals = DescriptorCopies()
      let strays = senders
      let refused = await eventually(within: 2) {
        for sender in strays where !refusals.all.contains(sender) {
          var byte: UInt8 = 0
          if recv(sender, &byte, 1, MSG_DONTWAIT) < 0 && errno == ECONNREFUSED {
            refusals.add(sender)
          }
        }
        return refusals.all.count == strays.count
      }
      #expect(await eventually(within: 10) { queuedDatagrams(probe) >= 1 })
      #expect(
        queuedDatagrams(probe) == 1,
        "queued: \(queuedDatagrams(probe)), stray refused: \(refused)")
    } else {
      #expect(
        await eventually(within: 10) { queuedDatagrams(probe) == 3 },
        "queued: \(queuedDatagrams(probe))")
    }
  }

  @Test("A fake network answers only the sockets it made, however they were bound")
  func fakeNetworkAnswersOnlyItsOwnSockets() async throws {
    let network = try FakeICMPNetwork { probe in
      [.init(ICMPWire.echoReply(family: AF_INET, id: probe.identifier, seq: probe.sequence))]
    }
    defer { network.stop() }
    // Bound by its first send, as the library leaves it.
    let implicit = try network.makeSocket(AF_INET)
    defer { close(implicit) }
    // Bound after the network made it, as the library does with a source address.
    let late = try network.makeSocket(AF_INET)
    defer { close(late) }
    var (any, anyLength) = loopbackAddress(family: AF_INET, port: 0)
    _ = withUnsafePointer(to: &any) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(late, $0, anyLength) }
    }
    // Another test's socket, sending to this network's port.
    let stranger = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    defer { close(stranger) }
    let request = Self.echoRequest(seq: 1)
    for fd in [stranger, implicit, late] {
      #expect(Self.sendProbe(request, on: fd, to: network, with: nil) == request.count)
    }
    #expect(
      await eventually(within: 10) { network.probes.value == 2 && network.foreignProbes.value == 1 }
    )
    #expect(network.probes.value == 2, "probes: \(network.probes.value)")
    #expect(network.foreignProbes.value == 1, "foreign: \(network.foreignProbes.value)")
    // Two replies in all, so none went to the stranger.
    #expect(await eventually(within: 10) { network.repliesSent.value == 2 })
    let settled = await eventually(within: 0.5) { network.repliesSent.value > 2 }
    #expect(!settled, "replies: \(network.repliesSent.value)")
  }

  enum Operation: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case trace, stream, ping
    var testDescription: String { rawValue }
  }

  @Test(
    "Trace, stream and ping send through the isolating send, so their probe sockets are connected",
    arguments: Operation.allCases)
  func operationsConnectTheirProbeSockets(operation: Operation) async throws {
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 1))
    defer { network.stop() }
    // A duplicate of every probe socket, kept past the operation's close to ask its peer.
    let copies = DescriptorCopies()
    defer { for fd in copies.all { close(fd) } }
    let factory: TestSeams.MakeICMPSocket = { family in
      let fd = try network.makeSocket(family)
      copies.add(dup(fd))
      return fd
    }
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 1, maxWaitMs: 60_000, noReverseDNS: true))
    _ = try await measure(within: 20) {
      try await network.install(socketFactory: factory) {
        switch operation {
        case .trace: _ = try await tracer.trace(to: "fake.test")
        case .stream:
          for try await _ in tracer.traceStream(
            to: "fake.test", config: StreamingTraceConfig(probeTimeout: 60, maxHops: 1))
          {}
        case .ping:
          _ = try await tracer.ping(to: "fake.test", config: PingConfig(count: 1, timeout: 60))
        }
      }
    }
    let fds = copies.all
    try #require(fds.count == 1, "sockets made: \(fds.count)")
    var peer = sockaddr_storage()
    var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let connected = withUnsafeMutablePointer(to: &peer) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fds[0], $0, &length) }
    }
    #expect(connected == 0, "the \(operation) probe socket was not connected")
    #expect(
      withUnsafeBytes(of: peer) { UInt16(bigEndian: $0.load(fromByteOffset: 2, as: UInt16.self)) }
        == network.port)
  }

  @Test(
    "Trace, stream and ping read their probe socket through the receive observer",
    arguments: Operation.allCases)
  func operationsReadThroughTheObserver(operation: Operation) async throws {
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 1))
    defer { network.stop() }
    let reads = FaultCounter()
    let observe: TestSeams.ObserveProbeReceive = { _, receive in
      let result = receive()
      let code = errno
      if result >= 0 { reads.increment() }
      errno = code
      return result
    }
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 1, maxWaitMs: 60_000, noReverseDNS: true))
    _ = try await measure(within: 20) {
      try await TestSeams.$observeProbeReceive.withValue(observe) {
        try await network.install {
          switch operation {
          case .trace: _ = try await tracer.trace(to: "fake.test")
          case .stream:
            for try await _ in tracer.traceStream(
              to: "fake.test", config: StreamingTraceConfig(probeTimeout: 60, maxHops: 1))
            {}
          case .ping:
            _ = try await tracer.ping(to: "fake.test", config: PingConfig(count: 1, timeout: 60))
          }
        }
      }
    }
    // The destination's reply ends each one, and it can only have been read through the observer.
    #expect(reads.value >= 1, "the \(operation) read nothing through the observer")
  }

  @Test("A stopped UDP fixture's own thread closes its socket")
  func udpFixtureThreadClosesItsSocket() async throws {
    let responder = try LoopbackUDPResponder(accepts: .payload([])) { _ in nil }
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

/// Descriptors a test collects from another thread or across polls: probe-socket duplicates kept
/// past the operation's close, or stray senders already seen refused.
private final class DescriptorCopies: @unchecked Sendable {
  private let lock = NSLock()
  private var fds: [Int32] = []

  func add(_ fd: Int32) { lock.withLock { fds.append(fd) } }
  var all: [Int32] { lock.withLock { fds } }
}
