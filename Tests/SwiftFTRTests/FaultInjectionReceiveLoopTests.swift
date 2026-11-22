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
  private var senderGone = false
  private var lastSend: TimeInterval?
  private var longestGap: TimeInterval = 0
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
      var handedOver = false
      defer { if !handedOver { close(fd) } }
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
      handedOver = true
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
      defer {
        lock.lock()
        senderGone = true
        lock.unlock()
        senderExited.signal()
      }
      send(datagram, to: port)
    }
    thread.start()
  }

  /// How much traffic there had been at one moment: replies sent, and how many of them some
  /// reader had taken off the probe socket.
  struct Traffic: Sendable {
    let sent: Int
    let read: Int
  }

  /// Replies sent so far, and how many have been read from the probe socket. Read counts the
  /// datagrams no longer queued on it (`SO_NUMRCVPKT` on the fixture's duplicate). It is 0 before
  /// the socket exists, and -1 if the queue cannot be counted, which no check accepts.
  func traffic() -> Traffic {
    lock.lock()
    defer { lock.unlock() }
    return Traffic(sent: sentCount, read: readCount())
  }

  /// Whether the socket stayed fed since `mark` and the operation read it: the sender is still
  /// running, no gap between sends reached the receive timeout (after which a read reports no
  /// data), neither has the time since the last send, and at least `minimumSent` more replies
  /// were sent and `minimumRead` more were read. The default of ten reads is far more than
  /// loopback ever has in flight at this spacing, so those replies were read, not merely still on
  /// their way. A test that checks reading before it cancels passes zero for both, since a prompt
  /// return can come before the next reply; the read count is an estimate, so with zero its
  /// change is not checked at all.
  func fedAndRead(
    since mark: Traffic, minimumSent: Int = 1, minimumRead: Int = 10
  ) -> (ok: Bool, detail: String) {
    lock.lock()
    defer { lock.unlock() }
    let read = readCount()
    let sinceLastSend = lastSend.map { monotonicNow() - $0 }
    let ok =
      !senderGone && !stopped && sentCount > 0 && sentCount - mark.sent >= minimumSent
      && longestGap < receiveTimeout && sinceLastSend.map { $0 < receiveTimeout } == true
      && mark.read >= 0 && read >= 0 && (minimumRead == 0 || read - mark.read >= minimumRead)
    let detail =
      "sender running: \(!senderGone && !stopped), sent \(mark.sent) -> \(sentCount), "
      + "read \(mark.read) -> \(read), longest gap \(longestGap)s, "
      + "since last send \(sinceLastSend.map { "\($0)s" } ?? "never")"
    return (ok, detail)
  }

  /// Replies sent so far.
  var sent: Int {
    lock.lock()
    defer { lock.unlock() }
    return sentCount
  }

  /// Replies taken off the probe socket, or -1 if its queue cannot be counted. Call with `lock`
  /// held.
  private func readCount() -> Int {
    // No socket yet: nothing can have been sent or read.
    if port == 0 { return 0 }
    guard socketCopy >= 0 else { return -1 }
    var queued: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(socketCopy, SOL_SOCKET, SO_NUMRCVPKT, &queued, &length) == 0 else {
      return -1
    }
    return max(0, sentCount - Int(queued))
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
        let now = monotonicNow()
        lock.lock()
        sentCount += 1
        if let lastSend { longestGap = max(longestGap, now - lastSend) }
        lastSend = now
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
      var handedOver = false
      defer { if !handedOver { close(fd) } }
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
      handedOver = true
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
/// arriving and its receive loop was reading them (``EndlessReplies/fedAndRead(since:minimumRead:)``),
/// so a test cannot pass on a socket that was idle or a loop that never read.
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

    let before = replies.traffic()
    let (result, elapsed) = try await measure(within: Self.watchdog) {
      try await replies.install(network, descriptors: descriptors) {
        try await tracer.trace(to: "fake.test")
      }
    }
    let flow = replies.fedAndRead(since: before)

    #expect(flow.ok, "the socket was not kept fed and read while the trace ran: \(flow.detail)")
    #expect(elapsed >= window * 0.9, "the trace ended before its \(window)s window: \(elapsed)s")
    #expect(!result.reached)
    #expect(result.hops.count == 4)
    #expect(result.hops.allSatisfy { $0.outcome == .timedOut })
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
    // The loop must be reading the replies when it is cancelled.
    #expect(
      await eventually(within: 5) { replies.traffic().read >= 10 },
      "the trace never read the replies: \(replies.traffic())")
    let atCancel = replies.traffic()
    trace.cancel()

    let (outcome, _) = try await measure(within: Self.watchdog) {
      await trace.result.map { _ in () }
    }
    let flow = replies.fedAndRead(since: atCancel, minimumSent: 0, minimumRead: 0)

    #expect(
      flow.ok, "the socket was not kept fed until the cancelled trace returned: \(flow.detail)")
    #expect(outcome.isCallerCancellation, "\(outcome)")
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

    let before = replies.traffic()
    let (result, _) = try await measure(within: Self.watchdog) {
      try await replies.install(network) { try await tracer.trace(to: "fake.test") }
    }
    let flow = replies.fedAndRead(since: before)

    // Foreign replies were read before the trace completed, so the valid ones came among them.
    #expect(flow.ok, "\(flow.detail)")
    #expect(result.reached)
    #expect(result.hops.count == 3)
    #expect(result.hops.allSatisfy { $0.ipAddress != nil })
  }

  @Test("A backlog longer than one read callback is read to the end without new arrivals")
  func traceReadsWholeBacklog() async throws {
    // The probe socket is handed to the trace already holding more foreign replies than one read
    // callback handles, then the reply that completes the trace, and the network stays silent.
    // Nothing new ever arrives, so the trace completes only if the read source fires again for
    // data an earlier callback left unread.
    let identifier: UInt16 = 0x5A5A
    let backlog = 2 * receiveBatchLimit
    let datagramCount = backlog + 1
    let network = try FakeICMPNetwork { _ in [] }
    defer { network.stop() }
    let queuedAtHandover = LockedCount()
    let preloaded: TestSeams.MakeICMPSocket = { family in
      let fd = try network.makeSocket(family)
      var handedOver = false
      defer { if !handedOver { close(fd) } }
      var (address, length) = loopbackAddress(family: family, port: 0)
      let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
      }
      guard bound == 0 else { throw FixtureError.socket("bind probe socket", errno) }
      var actual = sockaddr_storage()
      var actualLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
      _ = withUnsafeMutablePointer(to: &actual) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &actualLength) }
      }
      let foreign = ICMPWire.echoReply(family: family, id: identifier &+ 1, seq: 1)
      let valid = ICMPWire.echoReply(family: family, id: identifier, seq: 1)
      let datagrams = Array(repeating: foreign, count: backlog) + [valid]
      let sender = socket(family, SOCK_DGRAM, IPPROTO_UDP)
      guard sender >= 0 else { throw FixtureError.socket("socket", errno) }
      defer { close(sender) }
      for datagram in datagrams {
        _ = datagram.withUnsafeBytes { raw in
          withUnsafePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
              sendto(sender, raw.baseAddress, raw.count, 0, $0, actualLength)
            }
          }
        }
      }
      // Loopback delivers on its own thread, so wait until every datagram is queued. Count
      // datagrams, not bytes: Darwin's FIONREAD on a datagram socket includes each datagram's
      // address, so a byte count is reached with only part of the backlog queued.
      let giveUp = monotonicNow() + 5
      var queued: Int32 = 0
      repeat {
        var optionLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_NUMRCVPKT, &queued, &optionLength) == 0 else {
          throw FixtureError.socket("SO_NUMRCVPKT", errno)
        }
        if queued >= datagramCount { break }
        usleep(1000)
      } while monotonicNow() < giveUp
      queuedAtHandover.set(Int(queued))
      guard queued == datagramCount else {
        throw FixtureError.socket("backlog: \(queued) of \(datagramCount) datagrams queued", 0)
      }
      handedOver = true
      return fd
    }
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 1, maxWaitMs: 5000, noReverseDNS: true))

    let (result, _) = try await measure(within: Self.watchdog) {
      try await network.install(socketFactory: preloaded) {
        try await tracer.performTrace(
          to: "fake.test", handle: TraceHandle(), flowIdentifier: identifier)
      }
    }
    #expect(
      queuedAtHandover.value == datagramCount,
      "\(queuedAtHandover.value) of \(datagramCount) datagrams were queued before the trace read")
    #expect(datagramCount > receiveBatchLimit, "the backlog fits in one read callback")
    #expect(
      await eventually(within: 5) { network.probes.value == 1 },
      "the silent network saw \(network.probes.value) probes")
    #expect(result.reached, "the reply behind the backlog was never read")
    #expect(result.hops.count == 1)
    #expect(result.hops.first?.reachedDestination == true)
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

    let before = replies.traffic()
    let (hops, elapsed) = try await measure(within: Self.watchdog) {
      try await replies.install(network, descriptors: descriptors) {
        var hops: [StreamingHop] = []
        for try await hop in tracer.traceStream(to: "fake.test", config: config) {
          hops.append(hop)
        }
        return hops
      }
    }
    let flow = replies.fedAndRead(since: before)

    #expect(flow.ok, "the socket was not kept fed and read while the stream ran: \(flow.detail)")
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
    // The loop must be reading the replies when it is cancelled.
    #expect(
      await eventually(within: 5) { replies.traffic().read >= 10 },
      "the stream never read the replies: \(replies.traffic())")
    let atCancel = replies.traffic()
    // Cancels the producer, not the consumer: a cancelled consumer stops waiting on its own,
    // which would prove nothing about the receive loop.
    await tracer.cancelActiveTraces()

    let (outcome, _) = try await measure(within: Self.watchdog) { await consumer.result }
    let flow = replies.fedAndRead(since: atCancel, minimumSent: 0, minimumRead: 0)

    #expect(flow.ok, "the socket was not kept fed until the cancelled stream ended: \(flow.detail)")
    #expect(outcome.isLibraryCancellation, "\(outcome)")
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

    let before = replies.traffic()
    let consumer = Task {
      try await replies.install(network) {
        for try await _ in tracer.traceStream(to: "fake.test", config: config) {}
      }
    }
    defer { consumer.cancel() }
    // Four initial probes, then the retry re-sends TTLs 1...3.
    let retried = await eventually(within: Self.watchdog) { network.probes.value == 7 }
    let flow = replies.fedAndRead(since: before)
    await tracer.cancelActiveTraces()
    _ = try await measure(within: Self.watchdog) { await consumer.result }

    #expect(retried, "the retry did not go out: \(network.probes.value) probes")
    #expect(flow.ok, "the socket was not kept fed and read until the retry: \(flow.detail)")
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

    let before = replies.traffic()
    let (hops, _) = try await measure(within: Self.watchdog) {
      try await replies.install(network) {
        var hops: [StreamingHop] = []
        for try await hop in tracer.traceStream(to: "fake.test", config: config) {
          hops.append(hop)
        }
        return hops
      }
    }
    let flow = replies.fedAndRead(since: before)

    #expect(flow.ok, "\(flow.detail)")
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
    // Ping also arms a safety timer, at twice its whole schedule plus 5 s (5.8 s here). A ping
    // that never moved its deadline to the last probe's reply window would end on that timer, so
    // the watchdog sits a second below it.
    let schedule = Double(config.count - 1) * config.interval + config.timeout
    let safetyBudget = 2 * schedule + 5

    let before = replies.traffic()
    let (result, elapsed) = try await measure(within: safetyBudget - 1) {
      try await replies.install(network, descriptors: descriptors) {
        try await tracer.ping(to: "fake.test", config: config)
      }
    }
    let flow = replies.fedAndRead(since: before)

    #expect(flow.ok, "the socket was not kept fed and read while the ping ran: \(flow.detail)")
    // Ping's sends run on the queue its receive loop drains on, so all three going out shows the
    // loop let them through.
    #expect(result.statistics.sent == 3)
    #expect(
      await eventually(within: 5) { network.probes.value == 3 },
      "the network saw \(network.probes.value) probes")
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
    // The loop must be reading the replies when it is cancelled.
    #expect(
      await eventually(within: 5) { replies.traffic().read >= 10 },
      "the ping never read the replies: \(replies.traffic())")
    let atCancel = replies.traffic()
    ping.cancel()

    let (outcome, _) = try await measure(within: Self.watchdog) {
      await ping.result.map { _ in () }
    }
    let flow = replies.fedAndRead(since: atCancel, minimumSent: 0, minimumRead: 0)

    #expect(
      flow.ok, "the socket was not kept fed until the cancelled ping returned: \(flow.detail)")
    #expect(outcome.isCallerCancellation, "\(outcome)")
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

    let before = replies.traffic()
    let (result, _) = try await measure(within: Self.watchdog) {
      try await replies.install(network) { try await tracer.ping(to: "fake.test", config: config) }
    }
    let flow = replies.fedAndRead(since: before)

    #expect(flow.ok, "\(flow.detail)")
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
  /// Whether this is a failure with ``TracerouteError/cancelled``: the tracer ended it.
  fileprivate var isLibraryCancellation: Bool {
    guard case .failure(let error) = self, case .cancelled? = error as? TracerouteError else {
      return false
    }
    return true
  }

  /// Whether this is a failure with `CancellationError`: the caller's task ended it.
  fileprivate var isCallerCancellation: Bool {
    guard case .failure(let error) = self else { return false }
    return error is CancellationError
  }
}

/// An integer set on one thread and read on another.
private final class LockedCount: @unchecked Sendable {
  private let lock = NSLock()
  private var stored = -1

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func set(_ newValue: Int) {
    lock.lock()
    stored = newValue
    lock.unlock()
  }
}
