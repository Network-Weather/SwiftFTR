import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// Which echo replies a ping counts: only the first reply to a sequence number the ping actually
/// sent. Replies carrying the ping's identifier but a sequence it never sent, or not yet sent, and
/// second replies to a sequence already answered must change neither the statistics nor when the
/// ping ends.
///
/// Every ping here runs against ``FakeICMPNetwork``. Replies are marked with a TTL (IPv4, in an IP
/// header the receive loop parses) or a hop limit (IPv6, in ancillary data), so the test can tell
/// which of two replies to one sequence the ping kept. The control proves the marks arrive.
///
/// No test bounds how long a ping took from above. One that must end early is given a reply window
/// past ``watchdog``; one that must wait out its window keeps a lower bound and a watchdog below
/// ping's safety timer, so only the reply deadline can end it in time.
@Suite("Ping reply matching")
struct PingReplyMatchingTests {
  static let families: [Int32] = [AF_INET, AF_INET6]

  /// How long a ping that should end early may run before it is reported as stuck.
  static let watchdog: TimeInterval = 20

  /// A reply window that outlasts ``watchdog``: a ping given it that returns did not wait it out.
  static let windowPastWatchdog: TimeInterval = 60

  /// The mark on a reply the ping should keep, and on one it should ignore.
  static let kept: Int32 = 9
  static let ignored: Int32 = 7

  /// An echo reply for `seq` marked with `mark` as its TTL or hop limit.
  static func reply(
    _ family: Int32, id: UInt16, seq: UInt16, mark: Int32 = kept, after delay: TimeInterval = 0
  ) -> FakeICMPNetwork.Reply {
    let icmp = ICMPWire.echoReply(family: family, id: id, seq: seq)
    if family == AF_INET6 {
      return .init(icmp, after: delay, hopLimit: mark)
    }
    var ip = [UInt8](repeating: 0, count: 20)
    ip[0] = 0x45
    let total = UInt16(20 + icmp.count)
    ip[2] = UInt8(total >> 8)
    ip[3] = UInt8(total & 0xFF)
    ip[8] = UInt8(mark)
    ip[9] = UInt8(IPPROTO_ICMP)
    return .init(ip + icmp, after: delay)
  }

  /// Ping's safety timer for `config`: it ends a ping whose reply deadline never fires.
  static func safetyTimer(_ config: PingConfig) -> TimeInterval {
    2 * (Double(config.count - 1) * config.interval + config.timeout) + 5
  }

  static func summary(_ result: PingResult) -> String {
    let s = result.statistics
    let rows = result.responses.map { r in
      "#\(r.sequence) rtt=\(r.rtt.map { String(format: "%.4f", $0) } ?? "-") ttl=\(r.ttl.map(String.init) ?? "-")"
    }
    return
      "sent=\(s.sent) received=\(s.received) loss=\(s.packetLoss) min=\(s.minRTT.map { "\($0)" } ?? "-") "
      + rows.joined(separator: ", ")
  }

  // MARK: Control

  @Test(
    "A ping whose every probe is answered once counts each reply and ends early",
    arguments: families)
  func control(family: Int32) async throws {
    let network = try FakeICMPNetwork(family: family) { probe in
      [Self.reply(family, id: probe.identifier, seq: probe.sequence)]
    }
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig())
    let config = PingConfig(count: 3, interval: 0.05, timeout: Self.windowPastWatchdog)

    let (result, _) = try await measure(within: Self.watchdog) {
      try await network.install { try await tracer.ping(to: "fake.test", config: config) }
    }
    let s = result.statistics
    #expect(s.sent == 3 && s.received == 3 && s.packetLoss == 0, "\(Self.summary(result))")
    #expect(result.responses.map(\.sequence) == [1, 2, 3])
    #expect(result.responses.allSatisfy { ($0.rtt ?? -1) >= 0 }, "\(Self.summary(result))")
    // The marks arrive, which is what lets the duplicate test below tell two replies apart.
    #expect(result.responses.allSatisfy { $0.ttl == Int(Self.kept) }, "\(Self.summary(result))")
    if let min = s.minRTT, let avg = s.avgRTT, let max = s.maxRTT {
      #expect(min <= avg && avg <= max)
    } else {
      Issue.record("missing RTT statistics: \(Self.summary(result))")
    }
    #expect(s.jitter != nil)
  }

  // MARK: Sequences never sent

  @Test(
    "Replies to sequences the ping never sent, and duplicates, cannot end it early",
    arguments: families)
  func unsentSequencesCannotEndPingEarly(family: Int32) async throws {
    // Probes 1 and 2 are answered, probe 3 never is. Alongside the first reply come replies to
    // sequences a three-probe ping never sends and a duplicate, enough to make up three replies.
    let network = try FakeICMPNetwork(family: family) { probe in
      let id = probe.identifier
      switch probe.sequence {
      case 1:
        return [
          Self.reply(family, id: id, seq: 1),
          Self.reply(family, id: id, seq: 9, mark: Self.ignored),
          Self.reply(family, id: id, seq: 0, mark: Self.ignored),
          Self.reply(family, id: id, seq: 65535, mark: Self.ignored),
          Self.reply(family, id: id, seq: 1, mark: Self.ignored),
        ]
      case 2: return [Self.reply(family, id: id, seq: 2)]
      default: return []
      }
    }
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig())
    let config = PingConfig(count: 3, interval: 0.05, timeout: 0.5)

    let (result, elapsed) = try await measure(within: Self.safetyTimer(config) - 1) {
      try await network.install { try await tracer.ping(to: "fake.test", config: config) }
    }
    let s = result.statistics
    #expect(
      s.sent == 3,
      "a stray reply ended the ping before it sent every probe: \(Self.summary(result))")
    #expect(s.received == 2, "\(Self.summary(result))")
    #expect(abs(s.packetLoss - 1.0 / 3) < 1e-9, "\(Self.summary(result))")
    #expect(
      result.responses.map { $0.rtt != nil } == [true, true, false], "\(Self.summary(result))")
    #expect(result.responses.compactMap(\.ttl).allSatisfy { $0 == Int(Self.kept) })
    // Probe 3 leaves at about 0.1 s and is owed its 0.5 s window.
    #expect(elapsed >= 0.55, "the ping ended after \(elapsed)s: \(Self.summary(result))")
    #expect(
      await eventually(within: 5) { network.probes.value == 3 }, "probes: \(network.probes.value)")
  }

  @Test(
    "Replies to sequences the ping never sent are not counted when every probe is answered",
    arguments: families)
  func unsentSequencesAreNotCounted(family: Int32) async throws {
    // Each stray arrives ahead of the real reply, so a ping that counted strays would reach three
    // replies before probe 3 is answered.
    let network = try FakeICMPNetwork(family: family) { probe in
      let id = probe.identifier
      return [
        Self.reply(family, id: id, seq: probe.sequence &+ 8, mark: Self.ignored),
        Self.reply(family, id: id, seq: probe.sequence),
      ]
    }
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig())
    // The reply window outlasts the watchdog, so the ping must end on its third real reply.
    let config = PingConfig(count: 3, interval: 0.05, timeout: Self.windowPastWatchdog)

    let (result, _) = try await measure(within: Self.watchdog) {
      try await network.install { try await tracer.ping(to: "fake.test", config: config) }
    }
    let s = result.statistics
    #expect(s.sent == 3 && s.received == 3 && s.packetLoss == 0, "\(Self.summary(result))")
    #expect(result.responses.allSatisfy { ($0.rtt ?? -1) >= 0 }, "\(Self.summary(result))")
    #expect(result.responses.allSatisfy { $0.ttl == Int(Self.kept) }, "\(Self.summary(result))")
  }

  // MARK: Sequences not yet sent

  @Test("A reply to a sequence not yet sent is not counted for it", arguments: families)
  func futureSequenceIsNotCounted(family: Int32) async throws {
    // Probe 1's answer comes with a reply for sequence 2, a second before probe 2 leaves. Probe 2
    // itself is never answered; probe 3 is.
    let network = try FakeICMPNetwork(family: family) { probe in
      let id = probe.identifier
      switch probe.sequence {
      case 1:
        return [
          Self.reply(family, id: id, seq: 1),
          Self.reply(family, id: id, seq: 2, mark: Self.ignored),
        ]
      case 3: return [Self.reply(family, id: id, seq: 3)]
      default: return []
      }
    }
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig())
    let config = PingConfig(count: 3, interval: 1.0, timeout: 0.5)

    let (result, elapsed) = try await measure(within: Self.safetyTimer(config) - 1) {
      try await network.install { try await tracer.ping(to: "fake.test", config: config) }
    }
    let s = result.statistics
    #expect(s.sent == 3 && s.received == 2, "\(Self.summary(result))")
    #expect(
      result.responses.map { $0.rtt != nil } == [true, false, true], "\(Self.summary(result))")
    #expect((s.minRTT ?? -1) >= 0, "\(Self.summary(result))")
    #expect(result.responses.compactMap(\.ttl).allSatisfy { $0 == Int(Self.kept) })
    // Probe 2 is unanswered, so the ping waits out probe 3's window: about 2.5 s.
    #expect(elapsed >= 2.4, "the ping ended after \(elapsed)s: \(Self.summary(result))")
  }

  // MARK: Duplicates

  @Test("The first reply to a sequence is kept and a duplicate is not counted", arguments: families)
  func firstReplyWins(family: Int32) async throws {
    // Probe 1 is answered, then answered again at once and once more when probe 3 arrives, just
    // ahead of probe 3's own reply.
    let arrivals = ProbeArrivals()
    let network = try FakeICMPNetwork(family: family) { probe in
      arrivals.record(probe.sequence)
      let id = probe.identifier
      switch probe.sequence {
      case 1:
        return [
          Self.reply(family, id: id, seq: 1),
          Self.reply(family, id: id, seq: 1, mark: Self.ignored),
        ]
      case 3:
        return [
          Self.reply(family, id: id, seq: 1, mark: Self.ignored),
          Self.reply(family, id: id, seq: 3),
        ]
      default: return [Self.reply(family, id: id, seq: probe.sequence)]
      }
    }
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig())
    let config = PingConfig(count: 3, interval: 0.5, timeout: Self.windowPastWatchdog)

    let (result, _) = try await measure(within: Self.watchdog) {
      try await network.install { try await tracer.ping(to: "fake.test", config: config) }
    }
    let s = result.statistics
    #expect(s.sent == 3 && s.received == 3 && s.packetLoss == 0, "\(Self.summary(result))")
    #expect(
      result.responses.allSatisfy { $0.ttl == Int(Self.kept) },
      "a duplicate replaced the first reply: \(Self.summary(result))")
    // The last duplicate is sent only after the network has seen probe 3, so an RTT measured to it
    // is longer than the time between the network seeing probes 1 and 3 (about 1 s). Probe 1's
    // first reply leaves at once.
    let gap = try #require(arrivals.gap(from: 1, to: 3))
    let rtt = try #require(result.responses.first?.rtt)
    #expect(rtt < gap, "probe 1's RTT \(rtt)s is a duplicate's (probes 1 to 3: \(gap)s)")
  }

  // MARK: Late replies

  @Test(
    "A reply that arrives after its own probe's timeout but before the ping ends is counted",
    arguments: families)
  func lateReplyWithinPingIsCounted(family: Int32) async throws {
    // `timeout` is the reply window after the last probe; an earlier probe's reply counts until
    // then. Probe 1's reply comes 0.7 s after it, past the 0.5 s timeout but well before the ping
    // ends, which is no earlier than probe 3 at about 2 s.
    let delay: TimeInterval = 0.7
    let network = try FakeICMPNetwork(family: family) { probe in
      let id = probe.identifier
      return [
        Self.reply(family, id: id, seq: probe.sequence, after: probe.sequence == 1 ? delay : 0)
      ]
    }
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig())
    let config = PingConfig(count: 3, interval: 1.0, timeout: 0.5)

    let (result, _) = try await measure(within: Self.safetyTimer(config) - 1) {
      try await network.install { try await tracer.ping(to: "fake.test", config: config) }
    }
    let s = result.statistics
    #expect(s.sent == 3 && s.received == 3, "\(Self.summary(result))")
    #expect((result.responses.first?.rtt ?? 0) >= delay, "\(Self.summary(result))")
  }
}

/// When the fake network saw each probe, on its own thread.
private final class ProbeArrivals: @unchecked Sendable {
  private let lock = NSLock()
  private var times: [UInt16: TimeInterval] = [:]

  func record(_ sequence: UInt16) {
    let now = monotonicNow()
    lock.lock()
    defer { lock.unlock() }
    if times[sequence] == nil { times[sequence] = now }
  }

  func gap(from first: UInt16, to last: UInt16) -> TimeInterval? {
    lock.lock()
    defer { lock.unlock() }
    guard let start = times[first], let end = times[last] else { return nil }
    return end - start
  }
}
