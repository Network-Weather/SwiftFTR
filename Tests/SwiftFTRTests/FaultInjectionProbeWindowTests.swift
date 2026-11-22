import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// The probe window under a failing network: silence, late replies, malformed and foreign
/// datagrams, a socket that cannot be read, and failures before the first probe is sent.
///
/// Every trace here runs against ``FakeICMPNetwork``, so the probes never leave the host. The
/// first test is the positive control: it proves the fake delivers replies the library accepts,
/// which is what makes the silent and garbage cases below mean anything.
@Suite("FaultInjection: probe window")
struct FaultInjectionProbeWindowTests {
  static let families: [Int32] = [AF_INET, AF_INET6]

  // MARK: Positive control

  @Test("A staged path is traced hop by hop and completes early", arguments: families)
  func stagedPathCompletes(family: Int32) async throws {
    let network = try FakeICMPNetwork(
      family: family, script: pathScript(family: family, destinationTTL: 3))
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 8, maxWaitMs: 3000, noReverseDNS: true))

    let (result, elapsed) = try await measure(within: 10) {
      try await network.install { try await tracer.trace(to: "fake.test") }
    }

    #expect(result.reached)
    #expect(result.hops.count == 3)
    #expect(result.hops.allSatisfy { $0.ipAddress == network.resolved.canonical })
    #expect(result.hops.last?.reachedDestination == true)
    // Early completion: all hops answered, so the trace must not sit out its 3 s window.
    #expect(elapsed < 1.5, "a fully answered trace waited \(elapsed)s")
    #expect(network.probes.value >= 3)
  }

  // MARK: Silence and late replies

  @Test("A silent network ends the trace at its receive deadline", arguments: families)
  func silenceEndsAtDeadline(family: Int32) async throws {
    let network = try FakeICMPNetwork(family: family) { _ in [] }
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 6, maxWaitMs: 400, noReverseDNS: true))

    let (result, elapsed) = try await measure(within: 10) {
      try await network.install { try await tracer.trace(to: "fake.test") }
    }

    #expect(!result.reached)
    #expect(result.hops.count == 6)
    #expect(result.hops.allSatisfy { $0.ipAddress == nil && $0.outcome == .timedOut })
    #expect(
      elapsed >= 0.35 && elapsed < 2.0, "silent trace returned after \(elapsed)s, window 0.4s")
    #expect(network.probes.value == 6, "every TTL should have been sent")
  }

  @Test("Replies that arrive after the deadline are ignored, not fatal", arguments: families)
  func lateRepliesIgnored(family: Int32) async throws {
    let network = try FakeICMPNetwork(
      family: family, script: pathScript(family: family, destinationTTL: 2, after: 0.6))
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 4, maxWaitMs: 300, noReverseDNS: true))

    let (result, elapsed) = try await measure(within: 10) {
      try await network.install { try await tracer.trace(to: "fake.test") }
    }
    #expect(!result.reached)
    #expect(result.hops.allSatisfy { $0.ipAddress == nil })
    #expect(elapsed < 1.5)

    // The late replies land after the socket is closed. Give them time to arrive, then prove the
    // tracer is still usable.
    try await Task.sleep(nanoseconds: 500_000_000)
    let again = try await measure(within: 10) {
      try await network.install { try await tracer.trace(to: "fake.test") }
    }.0
    #expect(again.hops.count == 4)
  }

  // MARK: Malformed and foreign datagrams

  /// Datagrams the parser must reject without disturbing the reply that follows them.
  static func garbage(family: Int32, id: UInt16, seq: UInt16) -> [[UInt8]] {
    let valid = ICMPWire.timeExceeded(family: family, id: id, seq: seq)
    var oversizedIHL = [UInt8](repeating: 0, count: 24)
    oversizedIHL[0] = 0x4F  // IHL 60 bytes, longer than the datagram
    oversizedIHL[9] = UInt8(IPPROTO_ICMP)
    var claimsIPv4 = [UInt8](repeating: 0xFF, count: 40)
    claimsIPv4[0] = 0x45  // IPv4 header naming a protocol that is not ICMP
    return [
      [],
      [0x0B],
      [0x0B, 0x00, 0x00],
      Array(valid.prefix(7)),
      Array(valid.prefix(12)),  // error header with a truncated quote
      Array(valid.prefix(valid.count - 1)),  // quote cut one byte short
      oversizedIHL,
      claimsIPv4,
      [UInt8](repeating: 0xFF, count: 1500),
      [family == AF_INET6 ? 129 : 0, 1, 0, 0, 0, 0, 0, 0],  // echo reply with a nonzero code
    ]
  }

  @Test(
    "Malformed and truncated datagrams do not stop the trace from reading valid replies",
    arguments: families)
  func malformedBeforeValid(family: Int32) async throws {
    let network = try FakeICMPNetwork(family: family) { probe in
      let ttl = Int(probe.sequence)
      var replies = Self.garbage(family: family, id: probe.identifier, seq: probe.sequence)
        .map { FakeICMPNetwork.Reply($0) }
      let valid =
        ttl < 3
        ? ICMPWire.timeExceeded(family: family, id: probe.identifier, seq: probe.sequence)
        : ICMPWire.echoReply(family: family, id: probe.identifier, seq: probe.sequence)
      // Sent back to back with the garbage, so one read event finds them all queued and the
      // receive loop must get past every rejected datagram to reach this one.
      replies.append(FakeICMPNetwork.Reply(valid))
      return replies
    }
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 5, maxWaitMs: 3000, noReverseDNS: true))

    let (result, elapsed) = try await measure(within: 10) {
      try await network.install { try await tracer.trace(to: "fake.test") }
    }

    #expect(result.reached)
    #expect(result.hops.count == 3)
    #expect(result.hops.allSatisfy { $0.ipAddress != nil })
    #expect(elapsed < 1.5, "garbage ahead of valid replies held the trace for \(elapsed)s")
  }

  @Test("Random datagrams never crash the receive loop", arguments: families)
  func randomDatagrams(family: Int32) async throws {
    let network = try FakeICMPNetwork(family: family) { probe in
      var generator = SeededGenerator(seed: UInt64(probe.sequence) &* 0x9E37_79B9)
      return (0..<40).map { _ in
        let length = Int.random(in: 0...96, using: &generator)
        var bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
        // Bias toward the types the parser inspects, so the fuzzing reaches its deeper branches.
        if !bytes.isEmpty {
          let types: [UInt8] = family == AF_INET6 ? [1, 3, 129] : [0, 3, 11, 0x45]
          bytes[0] = types[Int.random(in: 0..<types.count, using: &generator)]
        }
        return FakeICMPNetwork.Reply(bytes)
      }
    }
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 6, maxWaitMs: 400, noReverseDNS: true))

    let (result, elapsed) = try await measure(within: 10) {
      try await network.install { try await tracer.trace(to: "fake.test") }
    }
    #expect(result.hops.count <= 6)
    #expect(elapsed < 2.0)
  }

  @Test("A valid reply queued behind random datagrams is still processed", arguments: families)
  func validReplyBehindRandomDatagrams(family: Int32) async throws {
    let valid = pathScript(family: family, destinationTTL: 3)
    let network = try FakeICMPNetwork(family: family) { probe in
      var generator = SeededGenerator(seed: UInt64(probe.sequence) &* 0x9E37_79B9)
      let noise = (0..<40).map { _ in
        let length = Int.random(in: 0...96, using: &generator)
        return FakeICMPNetwork.Reply(
          (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) })
      }
      return noise + valid(probe)
    }
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 6, maxWaitMs: 2000, noReverseDNS: true))

    let result = try await measure(within: 10) {
      try await network.install { try await tracer.trace(to: "fake.test") }
    }.0
    #expect(result.reached, "the destination's reply was lost behind the noise")
    #expect(result.hops.prefix(3).allSatisfy { $0.ipAddress != nil })
  }

  @Test("Replies quoting another trace's identifier are ignored", arguments: families)
  func foreignIdentifierIgnored(family: Int32) async throws {
    let network = try FakeICMPNetwork(family: family) { probe in
      let other = probe.identifier &+ 1
      return [
        .init(ICMPWire.timeExceeded(family: family, id: other, seq: probe.sequence)),
        .init(ICMPWire.echoReply(family: family, id: other, seq: probe.sequence)),
        .init(
          ICMPWire.unreachable(family: family, code: 3, id: other, seq: probe.sequence)),
      ]
    }
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 4, maxWaitMs: 300, noReverseDNS: true))

    let result = try await measure(within: 10) {
      try await network.install { try await tracer.trace(to: "fake.test") }
    }.0
    #expect(!result.reached)
    #expect(result.hops.allSatisfy { $0.ipAddress == nil && $0.outcome == .timedOut })
  }

  @Test("Unreachable replies are reported per hop and do not end the trace early")
  func unreachableReported() async throws {
    let network = try FakeICMPNetwork { probe in
      [
        .init(
          ICMPWire.unreachable(family: AF_INET, code: 1, id: probe.identifier, seq: probe.sequence))
      ]
    }
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 3, maxWaitMs: 300, noReverseDNS: true))

    let result = try await measure(within: 10) {
      try await network.install { try await tracer.trace(to: "fake.test") }
    }.0
    #expect(!result.reached)
    #expect(result.hops.allSatisfy { $0.outcome == .unreachable(code: 1) })
  }

  // MARK: The socket

  @Test("A non-transient send error ends every operation at once, with nothing left registered")
  func nonTransientSendError() async throws {
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    let tracer = offlineTracer(
      SwiftFTRConfig(maxHops: 4, maxWaitMs: 3000, publicIP: "198.51.100.7", noReverseDNS: true))

    let connectedFactory = Self.connectedSocketFactory(network)

    func expectSendFailure(_ name: String, _ body: @escaping @Sendable () async throws -> Void)
      async
    {
      let start = monotonicNow()
      do {
        _ = try await measure(within: 5) { try await body() }
        Issue.record("\(name) succeeded though no probe could be sent")
      } catch TracerouteError.sendFailed(let code) {
        #expect(code == EISCONN, "\(name) reported errno \(code)")
      } catch {
        Issue.record("\(name) threw \(error)")
      }
      #expect(monotonicNow() - start < 1.0, "\(name) did not fail fast")
    }

    try await network.install(socketFactory: connectedFactory) {
      await expectSendFailure("trace") { _ = try await tracer.trace(to: "fake.test") }
      await expectSendFailure("traceClassified") {
        _ = try await tracer.traceClassified(to: "fake.test", resolver: EmptyASNResolver())
      }
      await expectSendFailure("traceStream") {
        for try await _ in tracer.traceStream(to: "fake.test") {}
      }
    }
    #expect(await tracer.activeTraces.isEmpty)
    #expect(network.probes.value == 0)
  }

  /// A socket factory whose sockets are connected datagram sockets. One rejects every `sendto`
  /// that names an address with EISCONN, a non-transient errno, so the very first probe fails.
  static func connectedSocketFactory(_ network: FakeICMPNetwork) -> TestSeams.MakeICMPSocket {
    { family in
      let fd = try network.makeSocket(family)
      var (address, length) = loopbackAddress(family: family, port: network.port)
      _ = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
      }
      return fd
    }
  }

  @Test("A ping whose every send fails reports nothing sent, not loss, without waiting")
  func pingNonTransientSendError() async throws {
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 1))
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig())
    let timeout: TimeInterval = 10

    // A ping that counted its failed sends would wait out their reply window.
    let (result, _) = try await measure(within: timeout / 2) {
      try await network.install(socketFactory: Self.connectedSocketFactory(network)) {
        try await tracer.ping(
          to: "fake.test", config: PingConfig(count: 3, interval: 0.05, timeout: timeout))
      }
    }
    #expect(result.statistics.sent == 0, "failed sends counted as sent")
    #expect(result.statistics.received == 0)
    #expect(network.probes.value == 0)
  }

  @Test("Socket creation failure throws at once from every operation")
  func socketCreationFailure() async throws {
    // Fails the way socket(2) does, so each operation's own descriptor check must notice it and
    // report the errno.
    let refuse: TestSeams.MakeICMPSocket = { _ in
      errno = EMFILE
      return -1
    }
    let network = try FakeICMPNetwork { _ in [] }
    defer { network.stop() }
    let tracer = offlineTracer(
      SwiftFTRConfig(maxHops: 4, maxWaitMs: 2000, publicIP: "198.51.100.7", noReverseDNS: true))

    func expectSocketFailure(_ name: String, _ body: @escaping @Sendable () async throws -> Void)
      async
    {
      let start = monotonicNow()
      do {
        _ = try await measure(within: 5) { try await body() }
        Issue.record("\(name) succeeded without a socket")
      } catch TracerouteError.socketCreateFailed(let code, _) {
        #expect(code == EMFILE, "\(name)")
      } catch {
        Issue.record("\(name) threw \(error)")
      }
      #expect(monotonicNow() - start < 1.0, "\(name) did not fail fast")
    }

    try await network.install(socketFactory: refuse) {
      await expectSocketFailure("trace") { _ = try await tracer.trace(to: "fake.test") }
      await expectSocketFailure("traceClassified") {
        _ = try await tracer.traceClassified(to: "fake.test", resolver: EmptyASNResolver())
      }
      await expectSocketFailure("traceStream") {
        for try await _ in tracer.traceStream(to: "fake.test") {}
      }
      await expectSocketFailure("ping") {
        _ = try await tracer.ping(to: "fake.test", config: PingConfig(count: 2, timeout: 1))
      }
    }
    #expect(await tracer.activeTraces.isEmpty)
  }

  @Test("Resolution failure throws at once from every operation")
  func resolutionFailure() async throws {
    let fail: TestSeams.ResolveHost = { host, _ in
      throw TracerouteError.resolutionFailed(host: host, details: "injected NXDOMAIN")
    }
    let tracer = offlineTracer(
      SwiftFTRConfig(maxHops: 4, maxWaitMs: 2000, publicIP: "198.51.100.7", noReverseDNS: true))

    func expectResolutionFailure(
      _ name: String, _ body: @escaping @Sendable () async throws -> Void
    ) async {
      let start = monotonicNow()
      do {
        _ = try await measure(within: 5) { try await body() }
        Issue.record("\(name) succeeded without resolving")
      } catch TracerouteError.resolutionFailed(_, let details) {
        // Only the substitute says this, so a call that went around it cannot pass.
        #expect(details == "injected NXDOMAIN", "\(name) resolved without the substitute")
      } catch {
        Issue.record("\(name) threw \(error)")
      }
      #expect(monotonicNow() - start < 1.0, "\(name) did not fail fast")
    }

    // The destination is a loopback literal: an operation that went around the substitute would
    // resolve it locally and fail the details check, without asking any DNS server.
    await TestSeams.$resolveHost.withValue(fail) {
      await expectResolutionFailure("trace") { _ = try await tracer.trace(to: "127.0.0.1") }
      await expectResolutionFailure("traceClassified") {
        _ = try await tracer.traceClassified(to: "127.0.0.1", resolver: EmptyASNResolver())
      }
      await expectResolutionFailure("traceStream") {
        for try await _ in tracer.traceStream(to: "127.0.0.1") {}
      }
      await expectResolutionFailure("ping") {
        _ = try await tracer.ping(to: "127.0.0.1", config: PingConfig(count: 1, timeout: 1))
      }
    }
    #expect(await tracer.activeTraces.isEmpty)
  }

  // MARK: Streaming

  @Test("A silent network ends the stream at its timeout with a placeholder per hop")
  func streamSilenceBounded() async throws {
    let network = try FakeICMPNetwork { _ in [] }
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(noReverseDNS: true))
    let config = StreamingTraceConfig(probeTimeout: 0.5, retryAfter: 0.2, maxHops: 5)

    let (hops, elapsed) = try await measure(within: 10) {
      try await network.install {
        var hops: [StreamingHop] = []
        for try await hop in tracer.traceStream(to: "fake.test", config: config) {
          hops.append(hop)
        }
        return hops
      }
    }
    // The stream must sit out its window, not give up early.
    #expect(elapsed >= 0.45 && elapsed < 2.0, "silent stream took \(elapsed)s, timeout 0.5s")
    #expect(hops.map(\.ttl).sorted() == Array(1...5), "one placeholder per TTL")
    #expect(hops.allSatisfy { $0.ipAddress == nil })
    // Five initial probes, then the retry at 0.2 s re-sends TTLs 1...4 (the retry stops below
    // maxHops), so exactly nine reach the network.
    #expect(
      await eventually(within: 1) { network.probes.value == 9 }, "\(network.probes.value) probes")
  }

  @Test("Malformed datagrams do not stop a stream from delivering valid hops")
  func streamMalformedBeforeValid() async throws {
    let network = try FakeICMPNetwork { probe in
      var replies = Self.garbage(family: AF_INET, id: probe.identifier, seq: probe.sequence)
        .map { FakeICMPNetwork.Reply($0) }
      let ttl = probe.hopLimit ?? Int(probe.sequence)
      let valid =
        ttl < 3
        ? ICMPWire.timeExceeded(family: AF_INET, id: probe.identifier, seq: probe.sequence)
        : ICMPWire.echoReply(family: AF_INET, id: probe.identifier, seq: probe.sequence)
      replies.append(.init(valid, after: 0.02))
      return replies
    }
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(noReverseDNS: true))
    let config = StreamingTraceConfig(probeTimeout: 3, retryAfter: nil, maxHops: 5)

    let (hops, elapsed) = try await measure(within: 10) {
      try await network.install {
        var hops: [StreamingHop] = []
        for try await hop in tracer.traceStream(to: "fake.test", config: config) {
          hops.append(hop)
        }
        return hops
      }
    }
    #expect(elapsed < 1.5)
    // Hops arrive in arrival order, so a destination reply for a TTL past the destination can be
    // yielded before the real destination's; consumers take the lowest such TTL.
    let answered = Set(hops.filter { $0.ipAddress != nil }.map(\.ttl))
    #expect(
      answered.isSuperset(of: [1, 2, 3]), "\(hops.map { "\($0.ttl):\($0.ipAddress ?? "-")" })")
    #expect(hops.filter(\.reachedDestination).map(\.ttl).min() == 3)
  }

  // MARK: Ping

  @Test("Ping counts replies from the fake network and tolerates garbage between them")
  func pingWithGarbage() async throws {
    let network = try FakeICMPNetwork { probe in
      Self.garbage(family: AF_INET, id: probe.identifier, seq: probe.sequence).map { .init($0) }
        + [.init(ICMPWire.echoReply(family: AF_INET, id: probe.identifier, seq: probe.sequence))]
    }
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig())

    let (result, elapsed) = try await measure(within: 10) {
      try await network.install {
        try await tracer.ping(
          to: "fake.test", config: PingConfig(count: 3, interval: 0.05, timeout: 1.0))
      }
    }
    #expect(result.statistics.received == 3)
    #expect(elapsed < 2.0)
  }

  @Test("Ping against a silent network reports full loss within its timeout")
  func pingSilenceBounded() async throws {
    let network = try FakeICMPNetwork { _ in [] }
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig())

    let (result, elapsed) = try await measure(within: 10) {
      try await network.install {
        try await tracer.ping(
          to: "fake.test", config: PingConfig(count: 3, interval: 0.05, timeout: 0.3))
      }
    }
    #expect(result.statistics.sent == 3)
    #expect(result.statistics.received == 0)
    #expect(result.statistics.packetLoss == 1)
    #expect(network.probes.value == 3, "the network saw \(network.probes.value) probes")
    // The last probe leaves at about 0.1 s and is owed its 0.3 s reply window, so a ping that
    // gives up after its last send returns too early.
    #expect(elapsed >= 0.35 && elapsed < 1.5, "silent ping took \(elapsed)s")
  }
}

/// SplitMix64, so fuzz inputs are reproducible from the seed.
struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
