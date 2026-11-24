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

    let (result, _) = try await measure(within: Self.watchdog, diagnose: network.journal) {
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
    // Probe 3 leaves only once all six replies are queued or read, so the ping reads them within
    // probe 3's window however slow loopback is, and the window alone ends it.
    let ping = try DirectPing(
      family: family, config: PingConfig(count: 3, interval: 0.05, timeout: 0.5)
    ) { probe in
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
    defer { ping.stop() }
    ping.beforeSend = { seq, fd in
      guard seq == 3 else { return }
      ping.premise(ping.waitUntilReplied(6, fd))
    }

    let config = ping.config
    let (result, elapsed) = try await ping.runWatched(within: Self.safetyTimer(config) - 1)
    #expect(
      ping.premiseHeld,
      "the six replies were never queued before probe 3's send: \(ping.holdDetail)")
    let s = result.statistics
    #expect(
      s.sent == 3,
      "a stray reply ended the ping before it sent every probe: \(Self.summary(result))")
    #expect(s.received == 2, "\(Self.summary(result))")
    #expect(abs(s.packetLoss - 1.0 / 3) < 1e-9, "\(Self.summary(result))")
    #expect(
      result.responses.map { $0.rtt != nil } == [true, true, false], "\(Self.summary(result))")
    #expect(result.responses.compactMap(\.ttl).allSatisfy { $0 == Int(Self.kept) })
    // Probe 3 is owed its 0.5 s window from its own send, which the hold above delays.
    ping.expectWaitedOut(config.timeout, after: 3, "ran \(elapsed)s: \(Self.summary(result))")
    #expect(
      await eventually(within: 5) { ping.network.probes.value == 3 },
      "probes: \(ping.network.probes.value)")
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

    let (result, _) = try await measure(within: Self.watchdog, diagnose: network.journal) {
      try await network.install { try await tracer.ping(to: "fake.test", config: config) }
    }
    let s = result.statistics
    #expect(s.sent == 3 && s.received == 3 && s.packetLoss == 0, "\(Self.summary(result))")
    #expect(result.responses.allSatisfy { ($0.rtt ?? -1) >= 0 }, "\(Self.summary(result))")
    #expect(result.responses.allSatisfy { $0.ttl == Int(Self.kept) }, "\(Self.summary(result))")
  }

  // MARK: Replies queued before their request left

  @Test(
    "A reply queued while its request is still being sent does not displace the real reply",
    arguments: families)
  func replyQueuedBeforeSendIsIgnored(family: Int32) async throws {
    // Probe 2's send stands for one retrying buffer pressure: before the attempt that reaches the
    // wire, a reply for sequence 2 reaches the probe socket and is confirmed queued there. The read
    // handler shares the send's queue, so it reads that reply only after probe 2's send time is
    // recorded. The network then answers every probe, probe 2 included.
    let ping = try DirectPing(
      family: family, config: PingConfig(count: 3, interval: 0.05, timeout: Self.windowPastWatchdog)
    ) { probe in
      [Self.reply(family, id: probe.identifier, seq: probe.sequence)]
    }
    defer { ping.stop() }
    ping.beforeSend = { seq, fd in
      guard seq == 2 else { return }
      // The premise needs the injected reply itself on the wire: if its send failed, the queue
      // check would be satisfied by the ordinary replies alone.
      let injected = ping.network.inject(
        Self.reply(family, id: DirectPing.identifier, seq: 2, mark: Self.ignored), to: fd)
      ping.premise(injected && ping.waitUntilEveryReplyQueuedOrRead(fd))
    }

    let (result, _) = try await measure(within: Self.watchdog, diagnose: ping.network.journal) {
      try await ping.run()
    }
    #expect(ping.premiseHeld, "the early reply was never queued ahead of probe 2's send")
    let s = result.statistics
    #expect(s.sent == 3 && s.received == 3 && s.packetLoss == 0, "\(Self.summary(result))")
    #expect(result.responses.allSatisfy { ($0.rtt ?? -1) >= 0 }, "\(Self.summary(result))")
    #expect(
      result.responses.allSatisfy { $0.ttl == Int(Self.kept) },
      "a reply queued before probe 2 left was kept: \(Self.summary(result))")
  }

  @Test("A reply to a sequence not yet sent is not counted for it", arguments: families)
  func futureSequenceIsNotCounted(family: Int32) async throws {
    // Right after probe 1 leaves, a reply for sequence 2 is queued on the probe socket, before
    // probe 2 is sent. Probe 2 itself is never answered, so no genuine reply can stand in for a
    // false match: a ping that took the early reply would show probe 2 answered. Probe 2 leaves
    // only once probe 1's reply and the early one are both queued, so both are read inside its
    // window however slow loopback is.
    let ping = try DirectPing(
      family: family, config: PingConfig(count: 2, interval: 0.05, timeout: 0.5)
    ) { probe in
      probe.sequence == 1 ? [Self.reply(family, id: probe.identifier, seq: 1)] : []
    }
    defer { ping.stop() }
    ping.afterSend = { seq, fd in
      guard seq == 1 else { return }
      ping.premise(
        ping.network.inject(
          Self.reply(family, id: DirectPing.identifier, seq: 2, mark: Self.ignored), to: fd))
    }
    ping.beforeSend = { seq, fd in
      guard seq == 2 else { return }
      ping.premise(ping.waitUntilReplied(2, fd))
    }

    let config = ping.config
    let (result, _) = try await ping.runWatched(within: Self.safetyTimer(config) - 1)
    #expect(
      ping.premiseHeld,
      "the early reply and probe 1's were not queued before probe 2 left: \(ping.holdDetail)")
    let s = result.statistics
    #expect(s.sent == 2 && s.received == 1, "\(Self.summary(result))")
    #expect(
      result.responses.map { $0.rtt != nil } == [true, false],
      "the reply queued before probe 2 left was counted for it: \(Self.summary(result))")
    #expect((s.minRTT ?? -1) >= 0, "\(Self.summary(result))")
    #expect(result.responses.compactMap(\.ttl).allSatisfy { $0 == Int(Self.kept) })
  }

  // MARK: Duplicates

  @Test("The first reply to a sequence is kept and a duplicate is not counted", arguments: families)
  func firstReplyWins(family: Int32) async throws {
    // Probe 1 is answered, then answered again at once and once more when probe 3 arrives, just
    // ahead of probe 3's own reply.
    let network = try FakeICMPNetwork(family: family) { probe in
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
    let config = PingConfig(count: 3, interval: 0.05, timeout: Self.windowPastWatchdog)

    let (result, _) = try await measure(within: Self.watchdog, diagnose: network.journal) {
      try await network.install { try await tracer.ping(to: "fake.test", config: config) }
    }
    let s = result.statistics
    #expect(s.sent == 3 && s.received == 3 && s.packetLoss == 0, "\(Self.summary(result))")
    #expect(
      result.responses.allSatisfy { $0.ttl == Int(Self.kept) },
      "a duplicate replaced the first reply: \(Self.summary(result))")
  }

  @Test("A duplicate does not replace the first reply's RTT", arguments: families)
  func firstReplyKeepsItsRTT(family: Int32) async throws {
    // Right after probe 1 leaves, its reply and a duplicate are both queued on the probe socket,
    // so the ping reads them back to back in one read callback. Each receive stamp is recorded
    // with the number of datagrams still queued when it was taken: the first reply's stamp is the
    // one taken with the duplicate still waiting. Probe 2 is answered only once both are read.
    let ping = try DirectPing(
      family: family, config: PingConfig(count: 2, interval: 0.05, timeout: Self.windowPastWatchdog)
    ) { _ in [] }
    defer { ping.stop() }
    ping.afterSend = { seq, fd in
      if seq == 1 {
        ping.network.inject(Self.reply(family, id: DirectPing.identifier, seq: 1), to: fd)
        ping.network.inject(
          Self.reply(family, id: DirectPing.identifier, seq: 1, mark: Self.ignored), to: fd)
        ping.premise(waitForQueued(fd, atLeast: 2))
      } else {
        // Delivered from another thread once the first two are read: this closure runs on the
        // ping's queue, which must stay free to read them.
        Thread.detachNewThread {
          ping.premise(waitForQueued(fd, atMost: 0))
          ping.network.inject(Self.reply(family, id: DirectPing.identifier, seq: 2), to: fd)
        }
      }
    }

    let (result, _) = try await measure(within: Self.watchdog, diagnose: ping.network.journal) {
      try await ping.run()
    }
    #expect(ping.premiseHeld, "the replies were not queued and read as staged")
    let s = result.statistics
    #expect(s.sent == 2 && s.received == 2, "\(Self.summary(result))")
    // The first reading taken with one datagram queued is the first reply's: a later reading (arming
    // the deadline after reply 2 is queued) can also see one queued, so the count is not asserted.
    let firstStamp = try #require(ping.clock.stamps(withQueued: 1).first)
    let sentAt = try #require(ping.sendTimes[1])
    let rtt = try #require(result.responses.first?.rtt)
    #expect(
      rtt == firstStamp - sentAt,
      "probe 1's RTT \(rtt)s is not its first reply's (\(firstStamp - sentAt)s)")
  }

  // MARK: Late replies

  @Test(
    "A reply that arrives after its own probe's timeout but before the ping ends is counted",
    arguments: families)
  func lateReplyWithinPingIsCounted(family: Int32) async throws {
    // `timeout` is the reply window after the last probe; an earlier probe's reply counts until
    // then. Probe 1's reply comes 0.7 s after it, past the 0.5 s timeout. Probe 3, which is never
    // answered, leaves only once that reply and probe 2's are queued, so the ping is still running
    // when it reads them, however slowly loopback delivers.
    let delay: TimeInterval = 0.7
    let ping = try DirectPing(
      family: family, config: PingConfig(count: 3, interval: 0.05, timeout: 0.5)
    ) { probe in
      switch probe.sequence {
      case 1: return [Self.reply(family, id: probe.identifier, seq: 1, after: delay)]
      case 2: return [Self.reply(family, id: probe.identifier, seq: 2)]
      default: return []
      }
    }
    defer { ping.stop() }
    ping.beforeSend = { seq, fd in
      guard seq == 3 else { return }
      ping.premise(ping.waitUntilReplied(2, fd))
    }

    let config = ping.config
    let (result, _) = try await ping.runWatched(within: Self.safetyTimer(config) - 1)
    #expect(
      ping.premiseHeld,
      "probe 1's late reply was never queued before probe 3's send: \(ping.holdDetail)")
    let s = result.statistics
    #expect(s.sent == 3 && s.received == 2, "\(Self.summary(result))")
    #expect(
      result.responses.map { $0.rtt != nil } == [true, true, false], "\(Self.summary(result))")
    #expect((result.responses.first?.rtt ?? 0) >= delay, "\(Self.summary(result))")
  }

  // MARK: Failed sends

  @Test(
    "A ping whose send failed ends when the last reply arrives after the send loop finished",
    arguments: families)
  func failedSendEndsOnLastReply(family: Int32) async throws {
    // Probe 1's send fails; probe 2 leaves and is answered only once the send loop has finished,
    // which reads the clock to re-arm the reply deadline. Until a reply is parsed nothing else
    // reads ping's clock, so the first reading is the loop finishing.
    let ping = try DirectPing(
      family: family, config: PingConfig(count: 2, interval: 0.05, timeout: Self.windowPastWatchdog)
    ) { _ in [] }
    defer { ping.stop() }
    ping.failingSends = [1]
    ping.afterSend = { seq, fd in
      guard seq == 2 else { return }
      Thread.detachNewThread {
        let deadline = monotonicNow() + 10
        while ping.clock.readingCount == 0 && monotonicNow() < deadline { usleep(500) }
        ping.premise(ping.clock.readingCount > 0)
        ping.network.inject(Self.reply(family, id: DirectPing.identifier, seq: 2), to: fd)
      }
    }

    let (result, _) = try await measure(within: Self.watchdog, diagnose: ping.network.journal) {
      try await ping.run()
    }
    #expect(ping.premiseHeld, "the send loop never finished before the reply was sent")
    let s = result.statistics
    #expect(s.sent == 1 && s.received == 1 && s.packetLoss == 0, "\(Self.summary(result))")
    #expect(result.responses.map { $0.rtt != nil } == [false, true], "\(Self.summary(result))")
  }

  @Test(
    "A ping whose last send failed ends when the send loop finishes after every reply",
    arguments: families)
  func failedSendEndsWhenSendLoopFinishes(family: Int32) async throws {
    // Probe 1's reply is put on its socket right after it leaves, one loopback crossing rather
    // than the network's two; probe 2's send then fails. The premise, checked on the ping's queue
    // at probe 2's send, is that probe 1's reply has already been read. The send loop enqueues
    // each send and sleeps on its own, so no hook can hold probe 2 back until the reply is read:
    // the interval must outlast loopback delivery, which took up to 0.75 s on a loaded host.
    let ping = try DirectPing(
      family: family, config: PingConfig(count: 2, interval: 2, timeout: Self.windowPastWatchdog)
    ) { _ in [] }
    defer { ping.stop() }
    ping.failingSends = [2]
    ping.afterSend = { seq, fd in
      guard seq == 1 else { return }
      let injected = ping.network.inject(
        Self.reply(family, id: DirectPing.identifier, seq: 1), to: fd)
      ping.premise(injected && ping.waitUntilEveryReplyQueuedOrRead(fd))
    }
    ping.beforeSend = { seq, _ in
      guard seq == 2 else { return }
      ping.premise(ping.clock.readingCount > 0)
    }

    let (result, _) = try await measure(within: Self.watchdog, diagnose: ping.network.journal) {
      try await ping.run()
    }
    #expect(ping.premiseHeld, "probe 1's reply was not read before probe 2's send")
    let s = result.statistics
    #expect(s.sent == 1 && s.received == 1 && s.packetLoss == 0, "\(Self.summary(result))")
    #expect(result.responses.map { $0.rtt != nil } == [true, false], "\(Self.summary(result))")
  }

  @Test(
    "A failed send does not end a ping before its remaining probes are sent", arguments: families)
  func failedSendDoesNotEndPingBeforeLaterProbes(family: Int32) async throws {
    // Probe 2's send fails. Probe 1's reply matches the one send that has succeeded so far, but
    // probe 3 is still to come, so the ping must go on to send and count it.
    let ping = try DirectPing(
      family: family, config: PingConfig(count: 3, interval: 0.2, timeout: Self.windowPastWatchdog)
    ) { probe in
      [Self.reply(family, id: probe.identifier, seq: probe.sequence)]
    }
    defer { ping.stop() }
    ping.failingSends = [2]

    let (result, _) = try await measure(within: Self.watchdog, diagnose: ping.network.journal) {
      try await ping.run()
    }
    let s = result.statistics
    #expect(
      s.sent == 2 && s.received == 2,
      "the ping ended before sending probe 3: \(Self.summary(result))")
    #expect(
      result.responses.map { $0.rtt != nil } == [true, false, true], "\(Self.summary(result))")
  }

  @Test(
    "A ping whose send failed still waits out its window for an unanswered probe",
    arguments: families)
  func failedSendStillWaitsForUnansweredProbe(family: Int32) async throws {
    // Probe 1's send fails, probe 2 is answered, probe 3 never is: one sent probe is owed its
    // window, so the ping does not end on probe 2's reply. Probe 3 leaves only once that reply is
    // queued or read, so the ping counts it within probe 3's window however slow loopback is.
    let ping = try DirectPing(
      family: family, config: PingConfig(count: 3, interval: 0.05, timeout: 0.5)
    ) { probe in
      probe.sequence == 2 ? [Self.reply(family, id: probe.identifier, seq: 2)] : []
    }
    defer { ping.stop() }
    ping.failingSends = [1]
    ping.beforeSend = { seq, fd in
      guard seq == 3 else { return }
      ping.premise(ping.waitUntilReplied(1, fd))
    }

    let config = ping.config
    let (result, elapsed) = try await ping.runWatched(within: Self.safetyTimer(config) - 1)
    #expect(
      ping.premiseHeld, "probe 2's reply was never queued before probe 3's send: \(ping.holdDetail)"
    )
    let s = result.statistics
    #expect(s.sent == 2 && s.received == 1, "\(Self.summary(result))")
    // Probe 3 is owed its 0.5 s window from its own send, which the hold above delays.
    ping.expectWaitedOut(config.timeout, after: 3, "ran \(elapsed)s: \(Self.summary(result))")
  }
}

/// A ``PingOperation`` driven directly, on a probe socket from ``FakeICMPNetwork`` configured by
/// ping's own socket setup, sending through ping's real send path.
///
/// `beforeSend` and `afterSend` run on the ping's queue around each request's real send, where the
/// read handler cannot run, so a datagram they queue on the probe socket is read only after the
/// send's time is recorded (`beforeSend`) or after the request has left (`afterSend`). The clock
/// is ping's, and records each reading with how many datagrams were still queued.
final class DirectPing: @unchecked Sendable {
  static let identifier: UInt16 = 0x4242

  typealias Hook = @Sendable (_ sequence: UInt16, _ fd: Int32) -> Void

  let network: FakeICMPNetwork
  let config: PingConfig
  let clock: RecordingClock
  private let state = State()
  private let operation: PingOperation

  /// Hooks and observations, shared with the send path on the ping's queue.
  private final class State: @unchecked Sendable {
    let lock = NSLock()
    var before: Hook?
    var after: Hook?
    var premises: [Bool] = []
    var holdsGivenUp: [String] = []
    var runStart: TimeInterval?
    var sent: [UInt16: TimeInterval] = [:]
    var failing: Set<UInt16> = []
    var closed: TimeInterval?
  }

  /// Sequences whose send fails, after `beforeSend` runs, as a send that outlasted its retries.
  var failingSends: Set<UInt16> {
    get { state.lock.withLock { state.failing } }
    set { state.lock.withLock { state.failing = newValue } }
  }

  var beforeSend: Hook? {
    get { state.lock.withLock { state.before } }
    set { state.lock.withLock { state.before = newValue } }
  }
  var afterSend: Hook? {
    get { state.lock.withLock { state.after } }
    set { state.lock.withLock { state.after = newValue } }
  }

  /// Each request's send time, as ping recorded it.
  var sendTimes: [UInt16: TimeInterval] { state.lock.withLock { state.sent } }

  /// When ping closed its socket as it finished, on ping's clock, stamped on ping's queue; `nil`
  /// until then. A "not early" bound is measured from a send time to this, never from the start
  /// of a run that may contain a hold of unknown length.
  var closeTime: TimeInterval? { state.lock.withLock { state.closed } }

  /// Checks that ping waited out `window` after sequence `seq` left, measured on ping's clock from
  /// that send to the close, both stamped on ping's queue.
  func expectWaitedOut(_ window: TimeInterval, after seq: UInt16, _ detail: String) {
    guard let sent = sendTimes[seq], let closed = closeTime else {
      Issue.record("no send time for probe \(seq) or no close: \(detail)")
      return
    }
    #expect(
      closed - sent >= window * 0.95,
      "probe \(seq) got \(closed - sent)s of its \(window)s window: \(detail)")
  }

  /// Whether every staged condition the hooks checked held.
  var premiseHeld: Bool {
    state.lock.withLock { !state.premises.isEmpty && state.premises.allSatisfy { $0 } }
  }

  func premise(_ held: Bool) { state.lock.withLock { state.premises.append(held) } }

  /// Why a hold gave up, if one did, for a test's premise message.
  var holdDetail: String {
    let given = state.lock.withLock { state.holdsGivenUp }
    return given.isEmpty ? "no hold gave up" : given.joined(separator: "; ")
  }

  /// How far into the run ``waitUntilReplied(_:_:limit:)`` stops holding a send: what is left of
  /// the tests' watchdog (`safetyTimer - 1`, from the start of the run) once the held probe's
  /// reply window and half a second are taken off. It is counted from the start of the run, not
  /// from when the hold begins, since the watchdog and ping's safety timer both start with the
  /// run; past it a correct ping could no longer end inside the watchdog, so the hold gives up
  /// and the test fails on its premise instead.
  var holdCap: TimeInterval {
    PingReplyMatchingTests.safetyTimer(config) - 1 - config.timeout - 0.5
  }

  /// Waits, blocking this thread for at most `limit` seconds, until every datagram the network
  /// has sent to `fd` is either queued there or already read by the ping. Returns whether that
  /// happened.
  ///
  /// Called from a send hook, on the ping's queue, right after an injection, it shows that the
  /// injected datagram is queued: the read handler cannot run meanwhile, so nothing more is read,
  /// and the count is met only once that datagram has landed. Loopback delivers after `sendto`
  /// returns, so a bare "at least one queued" can be met instead by an earlier reply still
  /// waiting unread while the injected one is in flight, which then lands after the send it was
  /// meant to precede. Every reply the ping reads takes one clock reading, and before the send
  /// loop finishes nothing else reads that clock.
  func waitUntilEveryReplyQueuedOrRead(_ fd: Int32, limit: TimeInterval = 10) -> Bool {
    let giveUp = monotonicNow() + limit
    while true {
      let sent = network.repliesSent.value
      let accounted = Int(queuedDatagrams(fd)) + clock.readingCount
      if accounted == sent && network.repliesSent.value == sent { return true }
      if monotonicNow() >= giveUp { return false }
      usleep(500)
    }
  }

  /// Waits, blocking this thread for at most `limit` seconds, until the network has sent at least
  /// `count` replies and every reply it sent to `fd` is queued there or read. Called from a send
  /// hook, it holds that send until earlier replies have crossed loopback, so a reply window that
  /// starts at the send does not depend on how fast loopback delivers. The probe socket is
  /// connected to the network, which answers only this socket, so the count is exact. Returns
  /// whether that happened.
  func waitUntilReplied(_ count: Int, _ fd: Int32, limit: TimeInterval? = nil) -> Bool {
    let began = monotonicNow()
    let runStart = state.lock.withLock { state.runStart } ?? began
    let giveUp = limit.map { began + $0 } ?? (runStart + holdCap)
    var held = true
    while network.repliesSent.value < count {
      if monotonicNow() >= giveUp {
        held = false
        break
      }
      usleep(500)
    }
    if held { held = waitUntilEveryReplyQueuedOrRead(fd, limit: max(0, giveUp - monotonicNow())) }
    if !held {
      let sent = network.repliesSent.value
      let note = String(
        format: "hold gave up %.1f s into the run: %d of %d replies sent, %d queued, %d read",
        monotonicNow() - runStart, sent, count, queuedDatagrams(fd), clock.readingCount)
      state.lock.withLock { state.holdsGivenUp.append(note) }
    }
    return held
  }

  init(family: Int32, config: PingConfig, script: @escaping FakeICMPNetwork.Script) throws {
    let network = try FakeICMPNetwork(family: family, script: script)
    let executor = PingExecutor(config: SwiftFTRConfig())
    let makeSocket: TestSeams.MakeICMPSocket = { try network.makeSocket($0) }
    let fd = try TestSeams.$makeICMPSocket.withValue(makeSocket) {
      try executor.createICMPSocket(family: family)
    }
    try setProbeSocketNonBlocking(fd)
    let clock = RecordingClock(fd: fd) { executor.monotonicTime() }
    let state = self.state
    self.network = network
    self.config = config
    self.clock = clock
    operation = PingOperation(
      sockfd: fd, target: "fake.test", resolved: network.resolved, config: config,
      identifier: Self.identifier,
      sendPacket: { fd, packet, resolved in
        let seq = UInt16(packet[6]) << 8 | UInt16(packet[7])
        let (before, after, fails) = state.lock.withLock {
          (state.before, state.after, state.failing.contains(seq))
        }
        before?(seq, fd)
        if fails { throw TracerouteError.sendFailed(errno: ENOBUFS) }
        let time = try executor.sendPacket(
          sockfd: fd, packet: packet, to: resolved, sendProbe: FakeICMPNetwork.connectingSend)
        state.lock.withLock { state.sent[seq] = time }
        after?(seq, fd)
        return time
      },
      monotonicTime: { clock.now() },
      closeSocket: { fd in
        state.lock.withLock {
          state.closed = state.closed ?? pingClockSeconds(machAbsoluteTime: mach_absolute_time())
        }
        _ = close(fd)
      })
  }

  func run() async throws -> PingResult {
    state.lock.withLock { state.runStart = state.runStart ?? monotonicNow() }
    return try await operation.run()
  }

  /// Runs the ping under a watchdog of `limit` seconds, as ``measure(within:diagnose:_:)`` does.
  /// The start of the run is recorded here, before the watchdog is started, because the watchdog
  /// and the ping run in separate tasks: taken inside the ping's task it could be later than the
  /// watchdog's start, and a hold could then outlast the watchdog instead of giving up first.
  func runWatched(within limit: TimeInterval) async throws -> (PingResult, TimeInterval) {
    state.lock.withLock { state.runStart = monotonicNow() }
    return try await measure(within: limit, diagnose: self.network.journal) {
      try await self.run()
    }
  }

  func stop() {
    // The hooks capture this object; drop them so it and its fixture are released.
    beforeSend = nil
    afterSend = nil
    network.stop()
  }
}

/// Ping's clock, recording each reading with the number of datagrams queued on `fd` at the time.
final class RecordingClock: @unchecked Sendable {
  private let fd: Int32
  private let read: @Sendable () -> TimeInterval
  private let lock = NSLock()
  private var readings: [(time: TimeInterval, queued: Int32)] = []

  init(fd: Int32, read: @escaping @Sendable () -> TimeInterval) {
    self.fd = fd
    self.read = read
  }

  func now() -> TimeInterval {
    let time = read()
    let queued = queuedDatagrams(fd)
    lock.withLock { readings.append((time, queued)) }
    return time
  }

  /// How many times the ping has read its clock.
  var readingCount: Int { lock.withLock { readings.count } }

  func stamps(withQueued queued: Int32) -> [TimeInterval] {
    lock.withLock { readings.filter { $0.queued == queued }.map(\.time) }
  }
}

/// Datagrams waiting on `fd`, from `SO_NUMRCVPKT`; -1 if it cannot be read.
func queuedDatagrams(_ fd: Int32) -> Int32 {
  var count: Int32 = 0
  var length = socklen_t(MemoryLayout<Int32>.size)
  guard getsockopt(fd, SOL_SOCKET, SO_NUMRCVPKT, &count, &length) == 0 else { return -1 }
  return count
}

/// Waits, blocking this thread for at most `limit` seconds, until at least `atLeast` (or at most
/// `atMost`) datagrams are queued on `fd`. Returns whether that happened. Never call it from the
/// cooperative pool.
func waitForQueued(
  _ fd: Int32, atLeast: Int32? = nil, atMost: Int32? = nil, limit: TimeInterval = 10
) -> Bool {
  let giveUp = monotonicNow() + limit
  func met() -> Bool {
    let n = queuedDatagrams(fd)
    guard n >= 0 else { return false }
    if let atLeast, n < atLeast { return false }
    if let atMost, n > atMost { return false }
    return true
  }
  while !met() {
    if monotonicNow() >= giveUp { return false }
    usleep(500)
  }
  return true
}
