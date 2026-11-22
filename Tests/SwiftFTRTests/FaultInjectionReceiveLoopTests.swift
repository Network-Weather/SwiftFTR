import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// An IPv4 probe socket kept continuously readable with well-formed replies for another
/// identifier.
///
/// Every receive loop must reject these one by one, so they exercise the drain itself: malformed
/// datagrams make the trace parser stop at once and would not. Bound through
/// ``socketFactory(_:)``, the probe socket is bound to loopback so the flood can address it, and
/// the flood keeps a duplicate of it so the port cannot be handed to another socket while the
/// flood still sends to it. The flood starts when the network sees the first probe, because the
/// reply identifier must differ from the operation's, and runs until ``stop()``.
///
/// Senders keep the socket's queue (`FIONREAD`) near `highWaterBytes`, so the receive loop never
/// finds it empty. The mark stays below the level at which the kernel drops datagrams for a full
/// buffer, about 64 KiB queued for the 256 KiB buffer ping sets, so a valid reply sent into the
/// flood is queued behind it. Senders also stop at the mark rather than sending flat out: past
/// it, they would overflow loopback's input queue and drop datagrams for every socket on the
/// host, including other tests'. The defaults (four senders, 48 KiB) held an unbounded receive
/// loop for the whole watchdog on an M4 in debug builds, with no loss at the IP layer; in release
/// builds the loop sometimes escaped after a few seconds.
///
/// IPv4 only: on Darwin the IPv6 loopback path keeps the socket readable only about three
/// quarters of the time, even with twelve senders, so an IPv6 flood would not hold the loop. The
/// receive loops share their drain logic across families.
final class ReplyFlood: @unchecked Sendable {
  let family = AF_INET
  private let senderCount: Int
  private let highWater: Int32
  private let lock = NSLock()
  private var started = false
  private var stopped = false
  private var probeSocketCopy: Int32 = -1
  private var probePort: UInt16 = 0
  private var sentCount = 0
  private var samples = 0
  private var readableSamples = 0
  private let senders = DispatchGroup()

  init(senders: Int = 4, highWaterBytes: Int32 = 48 * 1024) {
    self.senderCount = senders
    self.highWater = highWaterBytes
  }

  deinit { stop() }

  /// Opens the probe socket through `network` and binds it to loopback for the flood.
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
      let port = withUnsafeBytes(of: actual) {
        UInt16(bigEndian: $0.load(fromByteOffset: 2, as: UInt16.self))
      }
      lock.lock()
      probeSocketCopy = dup(fd)
      probePort = port
      lock.unlock()
      return fd
    }
  }

  /// A network that answers nothing itself and starts the flood at the first probe.
  func silentScript() -> FakeICMPNetwork.Script {
    { [self] probe in
      start(foreignTo: probe.identifier)
      return []
    }
  }

  /// Wraps `script`, starting the flood at the first probe.
  func script(_ script: @escaping FakeICMPNetwork.Script) -> FakeICMPNetwork.Script {
    { [self] probe in
      start(foreignTo: probe.identifier)
      return script(probe)
    }
  }

  /// Starts flooding with echo replies for an identifier other than `identifier`. Later calls do
  /// nothing.
  func start(foreignTo identifier: UInt16) {
    lock.lock()
    guard !started, !stopped, probeSocketCopy >= 0 else {
      lock.unlock()
      return
    }
    started = true
    let port = probePort
    lock.unlock()
    let datagram = ICMPWire.echoReply(family: family, id: identifier &+ 1, seq: 1)
    for _ in 0..<senderCount {
      senders.enter()
      let thread = Thread { [self] in
        defer { senders.leave() }
        send(datagram, to: port)
      }
      thread.start()
    }
  }

  /// Whether the flood has started and not been stopped.
  var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return started && !stopped
  }

  /// Datagrams the flood has sent so far.
  var sent: Int {
    lock.lock()
    defer { lock.unlock() }
    return sentCount
  }

  /// The share of the senders' checks that found the probe socket readable.
  var readableShare: Double {
    lock.lock()
    defer { lock.unlock() }
    return samples == 0 ? 0 : Double(readableSamples) / Double(samples)
  }

  /// Stops every sender, waits for them to exit, and releases the duplicate descriptor.
  func stop() {
    lock.lock()
    let wasStopped = stopped
    stopped = true
    lock.unlock()
    guard !wasStopped else { return }
    senders.wait()
    lock.lock()
    if probeSocketCopy >= 0 { close(probeSocketCopy) }
    probeSocketCopy = -1
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
    // A test that forgets to stop the flood must not leave it running for the rest of the suite.
    let safetyStop = monotonicNow() + 60
    while monotonicNow() < safetyStop {
      lock.lock()
      let done = stopped
      let watched = probeSocketCopy
      lock.unlock()
      if done { return }
      var queued: Int32 = 0
      _ = ioctl(watched, fionread, &queued)
      lock.lock()
      samples += 1
      if queued > 0 { readableSamples += 1 }
      lock.unlock()
      if queued >= highWater {
        sched_yield()
        continue
      }
      var burst = 0
      for _ in 0..<16 {
        let n = datagram.withUnsafeBytes { Darwin.send(s, $0.baseAddress, $0.count, 0) }
        if n > 0 { burst += 1 }
      }
      lock.lock()
      sentCount += burst
      lock.unlock()
    }
  }
}

/// Records the sockets a socket factory hands out, so a test can check the library closed them.
///
/// The log keeps its own duplicate of each socket. A descriptor the library has closed no longer
/// refers to that socket, even if its number has since been handed to another one, so the check
/// holds while parallel tests open and close descriptors.
final class DescriptorLog: @unchecked Sendable {
  private let lock = NSLock()
  private var sockets: [(fd: Int32, copy: Int32)] = []

  deinit { for socket in sockets { close(socket.copy) } }

  func wrap(_ factory: @escaping TestSeams.MakeICMPSocket) -> TestSeams.MakeICMPSocket {
    { [self] family in
      let fd = try factory(family)
      lock.lock()
      sockets.append((fd, dup(fd)))
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
    return sockets.allSatisfy { !Self.sameSocket($0.fd, $0.copy) }
  }

  private static func sameSocket(_ a: Int32, _ b: Int32) -> Bool {
    var first = stat()
    var second = stat()
    guard fstat(a, &first) == 0, fstat(b, &second) == 0 else { return false }
    return first.st_ino == second.st_ino && first.st_dev == second.st_dev
  }
}

/// Receive loops under a socket that never stops being readable.
///
/// Each receive handler drains its socket on the serial queue that also delivers its deadline
/// timer, its cancellation and, for a stream, its retry timer. These tests keep the socket
/// readable with replies the handler must reject one by one, and check that the deadline,
/// cancellation and retry still happen, and that a valid reply in the middle of the flood is
/// still recorded.
///
/// Every operation runs under a watchdog, so a handler that holds its queue fails its test
/// instead of hanging the suite. Bounds come from the operation's configuration, and the main
/// claim of each liveness test is an event: the operation returned while the flood was still
/// running.
@Suite("FaultInjection: receive loop bounds", .serialized)
struct FaultInjectionReceiveLoopTests {
  /// Generous: an operation that is not starved returns within its own window plus scheduling.
  static let watchdog: TimeInterval = 10

  // MARK: Trace

  @Test("A flooded trace still ends at its receive deadline")
  func traceDeadlineUnderFlood() async throws {
    let flood = ReplyFlood()
    defer { flood.stop() }
    let network = try FakeICMPNetwork(script: flood.silentScript())
    defer { network.stop() }
    let descriptors = DescriptorLog()
    let window: TimeInterval = 0.3
    let tracer = offlineTracer(
      SwiftFTRConfig(maxHops: 4, maxWaitMs: Int(window * 1000), noReverseDNS: true))

    let (result, elapsed) = try await measure(within: Self.watchdog) {
      try await network.install(socketFactory: descriptors.wrap(flood.socketFactory(network))) {
        try await tracer.trace(to: "fake.test")
      }
    }
    let floodWasRunning = flood.isRunning

    #expect(floodWasRunning, "the trace returned only once the flood stopped")
    #expect(elapsed >= window * 0.9, "the trace ended before its \(window)s window: \(elapsed)s")
    #expect(!result.reached)
    #expect(result.hops.count == 4)
    #expect(result.hops.allSatisfy { $0.outcome == .timedOut })
    #expect(flood.readableShare > 0.5, "the flood kept the socket readable \(flood.readableShare)")
    #expect(descriptors.opened == 1 && descriptors.allClosed, "the probe socket was left open")
  }

  @Test("Cancelling a flooded trace returns promptly")
  func traceCancelledUnderFlood() async throws {
    let flood = ReplyFlood()
    defer { flood.stop() }
    let network = try FakeICMPNetwork(script: flood.silentScript())
    defer { network.stop() }
    let descriptors = DescriptorLog()
    // The window outlasts the watchdog, so only cancellation can end the trace in time.
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 4, maxWaitMs: 60_000, noReverseDNS: true))

    let factory = descriptors.wrap(flood.socketFactory(network))
    let trace = Task {
      try await network.install(socketFactory: factory) {
        try await tracer.trace(to: "fake.test")
      }
    }
    #expect(await eventually(within: 5) { flood.sent > 0 }, "the flood never started")
    try await Task.sleep(nanoseconds: 100_000_000)
    trace.cancel()

    let (outcome, _) = try await measure(within: Self.watchdog) {
      await trace.result.map { _ in () }
    }
    let floodWasRunning = flood.isRunning

    #expect(floodWasRunning, "the cancelled trace returned only once the flood stopped")
    if case .failure(let error) = outcome {
      #expect(isCancellation(error), "threw \(error)")
    } else {
      Issue.record("a cancelled trace succeeded")
    }
    #expect(descriptors.opened == 1 && descriptors.allClosed, "the probe socket was left open")
    #expect(await tracer.activeTraces.isEmpty)
  }

  @Test("A valid reply in the middle of a flood is still recorded")
  func traceRecordsReplyInFlood() async throws {
    // A gentler flood: this checks that bounded reads lose nothing, so it must not lose replies
    // on the way in either.
    let flood = ReplyFlood(senders: 2, highWaterBytes: 16 * 1024)
    defer { flood.stop() }
    // The replies are held back until the flood is under way, so they land behind it.
    let network = try FakeICMPNetwork(
      script: flood.script(pathScript(destinationTTL: 3, after: 0.15)))
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 6, maxWaitMs: 5000, noReverseDNS: true))

    let (result, _) = try await measure(within: Self.watchdog) {
      try await network.install(socketFactory: flood.socketFactory(network)) {
        try await tracer.trace(to: "fake.test")
      }
    }
    let floodWasRunning = flood.isRunning

    #expect(floodWasRunning)
    #expect(result.reached)
    #expect(result.hops.count == 3)
    #expect(result.hops.allSatisfy { $0.ipAddress != nil })
  }

  @Test("A backlog larger than one read callback is read to the end without new arrivals")
  func traceReadsWholeBacklog() async throws {
    // Each probe is answered with a long run of foreign replies and then the valid one, all sent
    // back to back, and then nothing more arrives. Reaching the valid replies needs the read
    // source to fire again for data left over from an earlier callback.
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

  @Test("A flooded stream still ends at its probe timeout")
  func streamDeadlineUnderFlood() async throws {
    let flood = ReplyFlood()
    defer { flood.stop() }
    let network = try FakeICMPNetwork(script: flood.silentScript())
    defer { network.stop() }
    let descriptors = DescriptorLog()
    let tracer = offlineTracer(SwiftFTRConfig(noReverseDNS: true))
    let config = StreamingTraceConfig(probeTimeout: 0.3, retryAfter: nil, maxHops: 4)

    let (hops, elapsed) = try await measure(within: Self.watchdog) {
      try await network.install(socketFactory: descriptors.wrap(flood.socketFactory(network))) {
        var hops: [StreamingHop] = []
        for try await hop in tracer.traceStream(to: "fake.test", config: config) {
          hops.append(hop)
        }
        return hops
      }
    }
    let floodWasRunning = flood.isRunning

    #expect(floodWasRunning, "the stream ended only once the flood stopped")
    #expect(elapsed >= config.probeTimeout * 0.9, "the stream ended early: \(elapsed)s")
    #expect(hops.map(\.ttl).sorted() == Array(1...4), "one placeholder per TTL")
    #expect(hops.allSatisfy { $0.ipAddress == nil })
    #expect(descriptors.opened == 1 && descriptors.allClosed, "the probe socket was left open")
  }

  @Test("Cancelling a flooded stream ends it promptly")
  func streamCancelledUnderFlood() async throws {
    let flood = ReplyFlood()
    defer { flood.stop() }
    let network = try FakeICMPNetwork(script: flood.silentScript())
    defer { network.stop() }
    let descriptors = DescriptorLog()
    let tracer = offlineTracer(SwiftFTRConfig(noReverseDNS: true))
    // The timeout outlasts the watchdog, so only cancellation can end the stream in time.
    let config = StreamingTraceConfig(probeTimeout: 60, retryAfter: nil, maxHops: 4)

    let factory = descriptors.wrap(flood.socketFactory(network))
    let consumer = Task {
      try await network.install(socketFactory: factory) {
        for try await _ in tracer.traceStream(to: "fake.test", config: config) {}
      }
    }
    #expect(await eventually(within: 5) { flood.sent > 0 }, "the flood never started")
    try await Task.sleep(nanoseconds: 100_000_000)
    // Cancels the producer, not the consumer: a cancelled consumer stops waiting on its own,
    // which would prove nothing about the receive loop.
    await tracer.cancelActiveTraces()

    let (outcome, _) = try await measure(within: Self.watchdog) {
      await consumer.result
    }
    let floodWasRunning = flood.isRunning

    #expect(floodWasRunning, "the cancelled stream ended only once the flood stopped")
    if case .failure(let error) = outcome {
      #expect(isCancellation(error), "threw \(error)")
    } else {
      Issue.record("a cancelled stream finished without an error")
    }
    #expect(descriptors.opened == 1 && descriptors.allClosed, "the probe socket was left open")
  }

  @Test("A flooded stream still sends its retries")
  func streamRetryUnderFlood() async throws {
    let flood = ReplyFlood()
    defer { flood.stop() }
    let network = try FakeICMPNetwork(script: flood.silentScript())
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(noReverseDNS: true))
    // The timeout outlasts the watchdog, so the retry is observed while the stream still runs.
    let config = StreamingTraceConfig(probeTimeout: 60, retryAfter: 0.2, maxHops: 4)

    let consumer = Task {
      try await network.install(socketFactory: flood.socketFactory(network)) {
        for try await _ in tracer.traceStream(to: "fake.test", config: config) {}
      }
    }
    defer { consumer.cancel() }
    // Four initial probes, then the retry re-sends TTLs 1...3. One of them reaching the network
    // shows the retry ran.
    let retried = await eventually(within: Self.watchdog) { network.probes.value > 4 }
    let floodWasRunning = flood.isRunning
    await tracer.cancelActiveTraces()
    _ = try await measure(within: Self.watchdog) { await consumer.result }

    #expect(retried, "the retry never went out: \(network.probes.value) probes")
    #expect(floodWasRunning)
  }

  @Test("A valid reply in the middle of a flood is still streamed")
  func streamDeliversReplyInFlood() async throws {
    let flood = ReplyFlood(senders: 2, highWaterBytes: 16 * 1024)
    defer { flood.stop() }
    let network = try FakeICMPNetwork(
      script: flood.script(pathScript(destinationTTL: 3, after: 0.15)))
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(noReverseDNS: true))
    let config = StreamingTraceConfig(probeTimeout: 5, retryAfter: nil, maxHops: 5)

    let (hops, _) = try await measure(within: Self.watchdog) {
      try await network.install(socketFactory: flood.socketFactory(network)) {
        var hops: [StreamingHop] = []
        for try await hop in tracer.traceStream(to: "fake.test", config: config) {
          hops.append(hop)
        }
        return hops
      }
    }
    let floodWasRunning = flood.isRunning

    #expect(floodWasRunning)
    let answered = Set(hops.filter { $0.ipAddress != nil }.map(\.ttl))
    #expect(
      answered.isSuperset(of: [1, 2, 3]), "\(hops.map { "\($0.ttl):\($0.ipAddress ?? "-")" })")
    #expect(hops.filter(\.reachedDestination).map(\.ttl).min() == 3)
  }

  // MARK: Ping

  @Test("A flooded ping still sends every probe and ends at its timeout")
  func pingDeadlineUnderFlood() async throws {
    let flood = ReplyFlood()
    defer { flood.stop() }
    let network = try FakeICMPNetwork(script: flood.silentScript())
    defer { network.stop() }
    let descriptors = DescriptorLog()
    let tracer = offlineTracer(SwiftFTRConfig())
    let config = PingConfig(count: 3, interval: 0.05, timeout: 0.3)

    let (result, elapsed) = try await measure(within: Self.watchdog) {
      try await network.install(socketFactory: descriptors.wrap(flood.socketFactory(network))) {
        try await tracer.ping(to: "fake.test", config: config)
      }
    }
    let floodWasRunning = flood.isRunning

    #expect(floodWasRunning, "the ping returned only once the flood stopped")
    // The sends wait on the queue the drain runs on, so all three going out shows the drain let
    // them through.
    #expect(result.statistics.sent == 3)
    #expect(result.statistics.received == 0)
    // The last probe is owed its full reply window.
    #expect(elapsed >= 2 * config.interval + config.timeout * 0.9, "returned after \(elapsed)s")
    #expect(descriptors.opened == 1 && descriptors.allClosed, "the probe socket was left open")
  }

  @Test("Cancelling a flooded ping returns promptly")
  func pingCancelledUnderFlood() async throws {
    let flood = ReplyFlood()
    defer { flood.stop() }
    let network = try FakeICMPNetwork(script: flood.silentScript())
    defer { network.stop() }
    let descriptors = DescriptorLog()
    let tracer = offlineTracer(SwiftFTRConfig())
    // The reply window outlasts the watchdog, so only cancellation can end the ping in time.
    let config = PingConfig(count: 1, timeout: 60)

    let factory = descriptors.wrap(flood.socketFactory(network))
    let ping = Task {
      try await network.install(socketFactory: factory) {
        try await tracer.ping(to: "fake.test", config: config)
      }
    }
    #expect(await eventually(within: 5) { flood.sent > 0 }, "the flood never started")
    try await Task.sleep(nanoseconds: 100_000_000)
    ping.cancel()

    let (outcome, _) = try await measure(within: Self.watchdog) {
      await ping.result.map { _ in () }
    }
    let floodWasRunning = flood.isRunning

    #expect(floodWasRunning, "the cancelled ping returned only once the flood stopped")
    if case .failure(let error) = outcome {
      #expect(isCancellation(error), "threw \(error)")
    } else {
      Issue.record("a cancelled ping succeeded")
    }
    #expect(descriptors.opened == 1 && descriptors.allClosed, "the probe socket was left open")
  }

  @Test("Valid echo replies in the middle of a flood are still counted")
  func pingCountsRepliesInFlood() async throws {
    let flood = ReplyFlood(senders: 2, highWaterBytes: 16 * 1024)
    defer { flood.stop() }
    let network = try FakeICMPNetwork(
      script: flood.script { probe in
        [.init(ICMPWire.echoReply(family: AF_INET, id: probe.identifier, seq: probe.sequence))]
      })
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig())
    let config = PingConfig(count: 3, interval: 0.1, timeout: 2)

    let (result, _) = try await measure(within: Self.watchdog) {
      try await network.install(socketFactory: flood.socketFactory(network)) {
        try await tracer.ping(to: "fake.test", config: config)
      }
    }
    let floodWasRunning = flood.isRunning

    #expect(floodWasRunning)
    #expect(result.statistics.sent == 3)
    #expect(result.statistics.received == 3)
  }

  // MARK: Non-blocking socket

  @Test(
    "A trace whose socket cannot be made non-blocking fails before probing",
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
      }
    }
    #expect(network.probes.value == 0, "a probe was sent from a blocking socket")
    #expect(descriptors.opened == 3 && descriptors.allClosed, "a failed trace left its socket open")
    #expect(await tracer.activeTraces.isEmpty)
  }
}

/// `FIONREAD`, which the Swift overlay does not export: `_IOR('f', 127, int)`.
private let fionread: UInt = 0x4004_667F

private func isCancellation(_ error: any Error) -> Bool {
  if case .cancelled? = error as? TracerouteError { return true }
  return false
}
