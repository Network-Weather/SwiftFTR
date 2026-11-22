import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// A probe socket that never reports it has no more data, fed with well-formed replies for
/// another identifier.
///
/// Every receive loop reads until a read reports no data, so on this socket a loop with no other
/// way out never returns. The replies are ones the loop must reject one by one; malformed
/// datagrams would not serve, because the trace parser's rejection ends its drain at once.
///
/// A real flood cannot hold a loop reliably. On Darwin, loopback delivers datagrams at about the
/// rate a receive loop drains them: a flood paced to stay ahead without overflowing loopback held
/// an unbounded loop past a 10 s watchdog in most runs on an M4, but in the rest the loop found
/// the socket empty within seconds. A flood sent flat out overflows loopback's input queue and
/// drops datagrams for every socket on the host, other tests' included. So this fixture changes
/// the socket rather than the traffic. It leaves the socket blocking, with a receive timeout far
/// longer than ``interval``, and sends one reply every ``interval``. Each read waits at most about
/// ``interval`` for the next reply instead of reporting no data, at a few hundred datagrams a
/// second. Once ``stop()`` ends the replies, a read waits out the timeout and reports no data, so
/// a held loop ends after the test.
///
/// ``install(_:descriptors:_:)`` routes the operation's sockets through ``socketFactory(_:)``,
/// which binds each to loopback so replies can be addressed to it, sets the timeout, and keeps a
/// duplicate so the port cannot be handed to another socket while replies still go to it. It also
/// substitutes `fcntl` so the operation's switch to non-blocking reports success and changes
/// nothing. Replies start when the network sees the first probe, because their identifier must
/// differ from the operation's, and run until ``stop()``.
final class EndlessReplies: @unchecked Sendable {
  let family: Int32
  /// The gap between replies, and so the longest a read waits for one.
  let interval: TimeInterval = 0.002
  private let receiveTimeout: TimeInterval = 1
  private let lock = NSLock()
  private var started = false
  private var stopped = false
  private var socketCopy: Int32 = -1
  private var port: UInt16 = 0
  private var sentCount = 0
  private let senderExited = DispatchSemaphore(value: 0)

  init(family: Int32 = AF_INET) {
    self.family = family
  }

  deinit { stop() }

  /// Runs `body` with `network` installed, the operation's sockets left blocking and opened by
  /// ``socketFactory(_:)``, and those sockets recorded in `descriptors` when given.
  func install<T>(
    _ network: FakeICMPNetwork, descriptors: DescriptorLog? = nil,
    _ body: () async throws -> T
  ) async rethrows -> T {
    let factory = socketFactory(network)
    let leaveBlocking: TestSeams.FileControl = { fd, command, argument in
      command == F_SETFL ? 0 : fcntl(fd, command, argument)
    }
    return try await TestSeams.$fileControl.withValue(leaveBlocking) {
      try await network.install(socketFactory: descriptors?.wrap(factory) ?? factory, body)
    }
  }

  /// Opens a probe socket through `network`, bound to loopback and with the receive timeout set.
  func socketFactory(_ network: FakeICMPNetwork) -> TestSeams.MakeICMPSocket {
    { [self] requestedFamily in
      let fd = try network.makeSocket(requestedFamily)
      var (address, length) = loopbackAddress(family: requestedFamily, port: 0)
      let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
      }
      guard bound == 0 else { throw FixtureError.socket("bind probe socket", errno) }
      var actual = sockaddr_storage()
      var actualLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
      _ = withUnsafeMutablePointer(to: &actual) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &actualLength) }
      }
      let boundPort = withUnsafeBytes(of: actual) {
        UInt16(bigEndian: $0.load(fromByteOffset: 2, as: UInt16.self))
      }
      setReceiveTimeout(fd, seconds: receiveTimeout)
      lock.lock()
      socketCopy = dup(fd)
      port = boundPort
      lock.unlock()
      return fd
    }
  }

  /// A network script that answers nothing itself and starts the replies at the first probe.
  func silentScript() -> FakeICMPNetwork.Script {
    script { _ in [] }
  }

  /// Wraps `script`, starting the replies at the first probe.
  func script(_ script: @escaping FakeICMPNetwork.Script) -> FakeICMPNetwork.Script {
    { [self] probe in
      start(foreignTo: probe.identifier)
      return script(probe)
    }
  }

  /// Starts sending echo replies for an identifier other than `identifier`. Later calls do
  /// nothing.
  func start(foreignTo identifier: UInt16) {
    lock.lock()
    guard !started, !stopped, socketCopy >= 0 else {
      lock.unlock()
      return
    }
    started = true
    let port = self.port
    lock.unlock()
    let datagram = ICMPWire.echoReply(family: family, id: identifier &+ 1, seq: 1)
    let thread = Thread { [self] in
      defer { senderExited.signal() }
      send(datagram, to: port)
    }
    thread.start()
  }

  /// Whether the replies have started and not been stopped.
  var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return started && !stopped
  }

  /// Replies sent so far.
  var sent: Int {
    lock.lock()
    defer { lock.unlock() }
    return sentCount
  }

  /// Stops the replies, waits for the sender to exit, and releases the duplicate descriptor.
  func stop() {
    lock.lock()
    let wasStopped = stopped
    let wasStarted = started
    stopped = true
    lock.unlock()
    guard !wasStopped else { return }
    if wasStarted { senderExited.wait() }
    lock.lock()
    if socketCopy >= 0 { close(socketCopy) }
    socketCopy = -1
    lock.unlock()
  }

  private func send(_ datagram: [UInt8], to port: UInt16) {
    let s = socket(family, SOCK_DGRAM, IPPROTO_UDP)
    guard s >= 0 else { return }
    defer { close(s) }
    var (destination, length) = loopbackAddress(family: family, port: port)
    let connected = withUnsafePointer(to: &destination) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, length) }
    }
    guard connected == 0 else { return }
    // A test that forgets to stop the replies must not leave them running for the whole suite.
    let safetyStop = monotonicNow() + 60
    while monotonicNow() < safetyStop {
      lock.lock()
      let done = stopped
      lock.unlock()
      if done { return }
      if datagram.withUnsafeBytes({ Darwin.send(s, $0.baseAddress, $0.count, 0) }) > 0 {
        lock.lock()
        sentCount += 1
        lock.unlock()
      }
      usleep(useconds_t(interval * 1_000_000))
    }
  }
}

/// Records the sockets a socket factory hands out, so a test can check the library closed them.
///
/// Each socket is identified by its local address. The log binds a socket the factory left
/// unbound to an ephemeral loopback port, and keeps a duplicate, which holds that port reserved.
/// A descriptor the library has closed then no longer has that address, even if its number has
/// since been handed to another socket, so the check holds while parallel tests open and close
/// descriptors. (`fstat` cannot tell sockets apart on Darwin: it reports inode 0 for all of them.)
final class DescriptorLog: @unchecked Sendable {
  private let lock = NSLock()
  private var sockets: [(fd: Int32, copy: Int32, address: [UInt8])] = []

  deinit { for socket in sockets { close(socket.copy) } }

  func wrap(_ factory: @escaping TestSeams.MakeICMPSocket) -> TestSeams.MakeICMPSocket {
    { [self] family in
      let fd = try factory(family)
      if Self.localAddress(fd).map(Self.port) == 0 {
        var (address, length) = loopbackAddress(family: family, port: 0)
        let bound = withUnsafePointer(to: &address) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0 else { throw FixtureError.socket("bind logged socket", errno) }
      }
      lock.lock()
      sockets.append((fd, dup(fd), Self.localAddress(fd) ?? []))
      lock.unlock()
      return fd
    }
  }

  var opened: Int {
    lock.lock()
    defer { lock.unlock() }
    return sockets.count
  }

  /// Whether every descriptor handed out has been closed by the library.
  var allClosed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return sockets.allSatisfy { Self.localAddress($0.fd) != $0.address }
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

  /// The port in a `sockaddr_in` or `sockaddr_in6`, which share its offset.
  private static func port(_ address: [UInt8]) -> UInt16 {
    address.count >= 4 ? UInt16(address[2]) << 8 | UInt16(address[3]) : 0
  }
}

/// Receive loops on a socket that never runs dry.
///
/// Each receive handler drains its socket on the serial queue that also delivers its deadline
/// timer, its cancellation, ping's sends and a stream's retry. These tests keep the socket
/// readable with replies the handler must reject one by one (``EndlessReplies``), and check that
/// the deadline, cancellation, sends and retry still happen, and that a valid reply among the
/// foreign ones is still recorded.
///
/// Every operation runs under a watchdog, so a handler that holds its queue fails its test
/// instead of hanging the suite. Bounds come from the operation's configuration, and the main
/// claim of each liveness test is an event: the operation returned while the replies were still
/// arriving.
@Suite("FaultInjection: receive loop bounds")
struct FaultInjectionReceiveLoopTests {
  static let families: [Int32] = [AF_INET, AF_INET6]

  /// Generous: an operation that is not held returns within its own window plus scheduling.
  static let watchdog: TimeInterval = 10

  // MARK: Trace

  @Test("A trace on a socket that never runs dry still ends at its deadline", arguments: families)
  func traceDeadline(family: Int32) async throws {
    let replies = EndlessReplies(family: family)
    defer { replies.stop() }
    let network = try FakeICMPNetwork(family: family, script: replies.silentScript())
    defer { network.stop() }
    let descriptors = DescriptorLog()
    let window: TimeInterval = 0.3
    let tracer = offlineTracer(
      SwiftFTRConfig(maxHops: 4, maxWaitMs: Int(window * 1000), noReverseDNS: true))

    let (result, elapsed) = try await measure(within: Self.watchdog) {
      try await replies.install(network, descriptors: descriptors) {
        try await tracer.trace(to: "fake.test")
      }
    }
    let stillArriving = replies.isRunning

    #expect(stillArriving, "the trace returned only once the replies stopped")
    #expect(elapsed >= window * 0.9, "the trace ended before its \(window)s window: \(elapsed)s")
    #expect(!result.reached)
    #expect(result.hops.count == 4)
    #expect(result.hops.allSatisfy { $0.outcome == .timedOut })
    #expect(replies.sent > 0)
    #expect(descriptors.opened == 1 && descriptors.allClosed, "the probe socket was left open")
  }

  @Test("Cancelling a trace on a socket that never runs dry returns promptly")
  func traceCancelled() async throws {
    let replies = EndlessReplies()
    defer { replies.stop() }
    let network = try FakeICMPNetwork(script: replies.silentScript())
    defer { network.stop() }
    let descriptors = DescriptorLog()
    // The window outlasts the watchdog, so only cancellation can end the trace in time.
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 4, maxWaitMs: 60_000, noReverseDNS: true))

    let trace = Task {
      try await replies.install(network, descriptors: descriptors) {
        try await tracer.trace(to: "fake.test")
      }
    }
    #expect(await eventually(within: 5) { replies.sent > 10 }, "the replies never started")
    trace.cancel()

    let (outcome, _) = try await measure(within: Self.watchdog) {
      await trace.result.map { _ in () }
    }
    let stillArriving = replies.isRunning

    #expect(stillArriving, "the cancelled trace returned only once the replies stopped")
    #expect(outcome.isCancellation, "\(outcome)")
    #expect(descriptors.opened == 1 && descriptors.allClosed, "the probe socket was left open")
    #expect(await tracer.activeTraces.isEmpty)
  }

  @Test("A valid reply among endless foreign ones is still recorded")
  func traceRecordsValidReply() async throws {
    let replies = EndlessReplies()
    defer { replies.stop() }
    // Held back until the foreign replies are under way, so the valid ones arrive among them.
    let network = try FakeICMPNetwork(
      script: replies.script(pathScript(destinationTTL: 3, after: 0.1)))
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 6, maxWaitMs: 5000, noReverseDNS: true))

    let (result, _) = try await measure(within: Self.watchdog) {
      try await replies.install(network) { try await tracer.trace(to: "fake.test") }
    }

    #expect(replies.isRunning)
    #expect(result.reached)
    #expect(result.hops.count == 3)
    #expect(result.hops.allSatisfy { $0.ipAddress != nil })
  }

  @Test("A backlog longer than one read callback is read to the end without new arrivals")
  func traceReadsWholeBacklog() async throws {
    // Each probe is answered with a long run of foreign replies and then the valid one, all sent
    // back to back, and then nothing more arrives. The socket is the library's own non-blocking
    // one. Reaching the valid replies needs the read source to fire again for data left over
    // from an earlier callback.
    let network = try FakeICMPNetwork { probe in
      let ttl = probe.hopLimit ?? Int(probe.sequence)
      let foreign = ICMPWire.echoReply(family: AF_INET, id: probe.identifier &+ 1, seq: 1)
      let valid =
        ttl < 3
        ? ICMPWire.timeExceeded(family: AF_INET, id: probe.identifier, seq: probe.sequence)
        : ICMPWire.echoReply(family: AF_INET, id: probe.identifier, seq: probe.sequence)
      return Array(repeating: FakeICMPNetwork.Reply(foreign), count: 300) + [.init(valid)]
    }
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 5, maxWaitMs: 5000, noReverseDNS: true))

    let (result, _) = try await measure(within: Self.watchdog) {
      try await network.install { try await tracer.trace(to: "fake.test") }
    }
    #expect(result.reached)
    #expect(result.hops.count == 3)
    #expect(result.hops.allSatisfy { $0.ipAddress != nil })
  }

  // MARK: Streaming

  @Test(
    "A stream on a socket that never runs dry still ends at its probe timeout", arguments: families
  )
  func streamDeadline(family: Int32) async throws {
    let replies = EndlessReplies(family: family)
    defer { replies.stop() }
    let network = try FakeICMPNetwork(family: family, script: replies.silentScript())
    defer { network.stop() }
    let descriptors = DescriptorLog()
    let tracer = offlineTracer(SwiftFTRConfig(noReverseDNS: true))
    let config = StreamingTraceConfig(probeTimeout: 0.3, retryAfter: nil, maxHops: 4)

    let (hops, elapsed) = try await measure(within: Self.watchdog) {
      try await replies.install(network, descriptors: descriptors) {
        var hops: [StreamingHop] = []
        for try await hop in tracer.traceStream(to: "fake.test", config: config) {
          hops.append(hop)
        }
        return hops
      }
    }
    let stillArriving = replies.isRunning

    #expect(stillArriving, "the stream ended only once the replies stopped")
    #expect(elapsed >= config.probeTimeout * 0.9, "the stream ended early: \(elapsed)s")
    #expect(hops.map(\.ttl).sorted() == Array(1...4), "one placeholder per TTL")
    #expect(hops.allSatisfy { $0.ipAddress == nil })
    #expect(descriptors.opened == 1 && descriptors.allClosed, "the probe socket was left open")
  }

  @Test("Cancelling a stream on a socket that never runs dry ends it promptly")
  func streamCancelled() async throws {
    let replies = EndlessReplies()
    defer { replies.stop() }
    let network = try FakeICMPNetwork(script: replies.silentScript())
    defer { network.stop() }
    let descriptors = DescriptorLog()
    let tracer = offlineTracer(SwiftFTRConfig(noReverseDNS: true))
    // The timeout outlasts the watchdog, so only cancellation can end the stream in time.
    let config = StreamingTraceConfig(probeTimeout: 60, retryAfter: nil, maxHops: 4)

    let consumer = Task {
      try await replies.install(network, descriptors: descriptors) {
        for try await _ in tracer.traceStream(to: "fake.test", config: config) {}
      }
    }
    #expect(await eventually(within: 5) { replies.sent > 10 }, "the replies never started")
    // Cancels the producer, not the consumer: a cancelled consumer stops waiting on its own,
    // which would prove nothing about the receive loop.
    await tracer.cancelActiveTraces()

    let (outcome, _) = try await measure(within: Self.watchdog) { await consumer.result }
    let stillArriving = replies.isRunning

    #expect(stillArriving, "the cancelled stream ended only once the replies stopped")
    #expect(outcome.isCancellation, "\(outcome)")
    #expect(descriptors.opened == 1 && descriptors.allClosed, "the probe socket was left open")
  }

  @Test("A stream on a socket that never runs dry still sends its retries")
  func streamRetry() async throws {
    let replies = EndlessReplies()
    defer { replies.stop() }
    let network = try FakeICMPNetwork(script: replies.silentScript())
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(noReverseDNS: true))
    // The timeout outlasts the watchdog, so the retry is observed while the stream still runs.
    let config = StreamingTraceConfig(probeTimeout: 60, retryAfter: 0.2, maxHops: 4)

    let consumer = Task {
      try await replies.install(network) {
        for try await _ in tracer.traceStream(to: "fake.test", config: config) {}
      }
    }
    defer { consumer.cancel() }
    // Four initial probes, then the retry re-sends TTLs 1...3.
    let retried = await eventually(within: Self.watchdog) { network.probes.value == 7 }
    let stillArriving = replies.isRunning
    await tracer.cancelActiveTraces()
    _ = try await measure(within: Self.watchdog) { await consumer.result }

    #expect(retried, "the retry did not go out: \(network.probes.value) probes")
    #expect(stillArriving)
  }

  @Test("A valid reply among endless foreign ones is still streamed")
  func streamDeliversValidReply() async throws {
    let replies = EndlessReplies()
    defer { replies.stop() }
    let network = try FakeICMPNetwork(
      script: replies.script(pathScript(destinationTTL: 3, after: 0.1)))
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(noReverseDNS: true))
    let config = StreamingTraceConfig(probeTimeout: 5, retryAfter: nil, maxHops: 5)

    let (hops, _) = try await measure(within: Self.watchdog) {
      try await replies.install(network) {
        var hops: [StreamingHop] = []
        for try await hop in tracer.traceStream(to: "fake.test", config: config) {
          hops.append(hop)
        }
        return hops
      }
    }

    #expect(replies.isRunning)
    let answered = Set(hops.filter { $0.ipAddress != nil }.map(\.ttl))
    #expect(
      answered.isSuperset(of: [1, 2, 3]), "\(hops.map { "\($0.ttl):\($0.ipAddress ?? "-")" })")
    #expect(hops.filter(\.reachedDestination).map(\.ttl).min() == 3)
  }

  // MARK: Ping

  @Test(
    "A ping on a socket that never runs dry still sends every probe and ends at its timeout",
    arguments: families)
  func pingDeadline(family: Int32) async throws {
    let replies = EndlessReplies(family: family)
    defer { replies.stop() }
    let network = try FakeICMPNetwork(family: family, script: replies.silentScript())
    defer { network.stop() }
    let descriptors = DescriptorLog()
    let tracer = offlineTracer(SwiftFTRConfig())
    let config = PingConfig(count: 3, interval: 0.05, timeout: 0.3)

    let (result, elapsed) = try await measure(within: Self.watchdog) {
      try await replies.install(network, descriptors: descriptors) {
        try await tracer.ping(to: "fake.test", config: config)
      }
    }
    let stillArriving = replies.isRunning

    #expect(stillArriving, "the ping returned only once the replies stopped")
    // Ping's sends run on the queue its receive loop drains on, so all three going out shows the
    // loop let them through.
    #expect(result.statistics.sent == 3)
    #expect(network.probes.value == 3, "the network saw \(network.probes.value) probes")
    #expect(result.statistics.received == 0)
    // The last probe is owed its full reply window.
    #expect(elapsed >= 2 * config.interval + config.timeout * 0.9, "returned after \(elapsed)s")
    #expect(descriptors.opened == 1 && descriptors.allClosed, "the probe socket was left open")
  }

  @Test("Cancelling a ping on a socket that never runs dry returns promptly")
  func pingCancelled() async throws {
    let replies = EndlessReplies()
    defer { replies.stop() }
    let network = try FakeICMPNetwork(script: replies.silentScript())
    defer { network.stop() }
    let descriptors = DescriptorLog()
    let tracer = offlineTracer(SwiftFTRConfig())
    // The reply window outlasts the watchdog, so only cancellation can end the ping in time.
    let config = PingConfig(count: 1, timeout: 60)

    let ping = Task {
      try await replies.install(network, descriptors: descriptors) {
        try await tracer.ping(to: "fake.test", config: config)
      }
    }
    #expect(await eventually(within: 5) { replies.sent > 10 }, "the replies never started")
    ping.cancel()

    let (outcome, _) = try await measure(within: Self.watchdog) {
      await ping.result.map { _ in () }
    }
    let stillArriving = replies.isRunning

    #expect(stillArriving, "the cancelled ping returned only once the replies stopped")
    #expect(outcome.isCancellation, "\(outcome)")
    #expect(descriptors.opened == 1 && descriptors.allClosed, "the probe socket was left open")
  }

  @Test("Valid echo replies among endless foreign ones are still counted")
  func pingCountsValidReplies() async throws {
    let replies = EndlessReplies()
    defer { replies.stop() }
    let network = try FakeICMPNetwork(
      script: replies.script { probe in
        [.init(ICMPWire.echoReply(family: AF_INET, id: probe.identifier, seq: probe.sequence))]
      })
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig())
    let config = PingConfig(count: 3, interval: 0.1, timeout: 2)

    let (result, _) = try await measure(within: Self.watchdog) {
      try await replies.install(network) { try await tracer.ping(to: "fake.test", config: config) }
    }

    #expect(replies.isRunning)
    #expect(result.statistics.sent == 3)
    #expect(result.statistics.received == 3)
  }

  // MARK: Non-blocking switch

  @Test(
    "An operation whose socket cannot be made non-blocking fails before probing",
    arguments: [F_GETFL, F_SETFL])
  func nonBlockingFailure(command: Int32) async throws {
    // Every TTL is answered with time-exceeded and the destination never replies, so a trace
    // left on a blocking socket would wait in the read after the last reply, on the queue that
    // delivers its deadline.
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 99))
    defer { network.stop() }
    let descriptors = DescriptorLog()
    let tracer = offlineTracer(
      SwiftFTRConfig(maxHops: 3, maxWaitMs: 300, publicIP: "198.51.100.7", noReverseDNS: true))
    let name = command == F_GETFL ? "F_GETFL" : "F_SETFL"
    let refuse: TestSeams.FileControl = { fd, cmd, argument in
      guard cmd == command else { return fcntl(fd, cmd, argument) }
      errno = EINVAL
      return -1
    }

    func expectFailure(_ operation: String, _ body: @escaping @Sendable () async throws -> Void)
      async
    {
      do {
        _ = try await measure(within: 5) { try await body() }
        Issue.record("\(operation) ran though its socket stayed blocking")
      } catch TracerouteError.socketCreateFailed(let code, let details) {
        #expect(code == EINVAL, "\(operation) reported errno \(code)")
        #expect(details.contains(name), "\(operation): \(details)")
      } catch {
        Issue.record("\(operation) threw \(error)")
      }
    }

    try await TestSeams.$fileControl.withValue(refuse) {
      try await network.install(socketFactory: descriptors.wrap { try network.makeSocket($0) }) {
        await expectFailure("trace") { _ = try await tracer.trace(to: "fake.test") }
        await expectFailure("traceClassified") {
          _ = try await tracer.traceClassified(to: "fake.test", resolver: EmptyASNResolver())
        }
        await expectFailure("traceStream") {
          for try await _ in tracer.traceStream(to: "fake.test") {}
        }
        await expectFailure("ping") {
          _ = try await tracer.ping(to: "fake.test", config: PingConfig(count: 1, timeout: 1))
        }
      }
    }
    #expect(network.probes.value == 0, "a probe was sent from a blocking socket")
    #expect(descriptors.opened == 4, "\(descriptors.opened) sockets opened")
    #expect(descriptors.allClosed, "a failed operation left its socket open")
    #expect(await tracer.activeTraces.isEmpty)
  }
}

extension Result {
  /// Whether this is a failure with ``TracerouteError/cancelled``.
  fileprivate var isCancellation: Bool {
    guard case .failure(let error) = self, case .cancelled? = error as? TracerouteError else {
      return false
    }
    return true
  }
}
