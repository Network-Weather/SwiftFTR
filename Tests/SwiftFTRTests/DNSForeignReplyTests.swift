import Foundation
@_spi(Test) import SwiftFTR
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// A loopback DNS peer that answers each query with a scripted list of datagrams, sent in order,
/// and can also keep sending one datagram derived from the first query every ``interval`` until
/// ``stop()``.
///
/// Every datagram leaves from the socket the query reached, so the client's connected socket
/// accepts it as coming from its server. The continuous feed is slow on purpose: a flood sent flat
/// out overflows loopback's input queue and drops datagrams for every socket on the host.
final class ScriptedDNSPeer: @unchecked Sendable {
  typealias Script = @Sendable (_ query: [UInt8]) -> [(datagram: [UInt8], after: TimeInterval)]
  typealias Feed = @Sendable (_ query: [UInt8]) -> [UInt8]

  let port: UInt16
  let requests = FaultCounter()
  /// Datagrams sent, scripted and fed.
  let sent = FaultCounter()
  /// The gap between fed datagrams, and so the longest a blocking read waits for one.
  let interval: TimeInterval = 0.002

  private let fd: Int32
  private let script: Script
  private let feed: Feed?
  private let lock = NSLock()
  private var stopped = false
  private var feeding = false
  private var feedSent = 0
  private var lastFeed: TimeInterval?
  private var longestGap: TimeInterval = 0
  private var scriptedSendStarts: [TimeInterval] = []
  private var lastQuery: (query: [UInt8], source: sockaddr_storage, length: socklen_t)?
  private let threadsExited = DispatchSemaphore(value: 0)
  private var threads = 1

  init(family: Int32 = AF_INET, feed: Feed? = nil, script: @escaping Script) throws {
    self.script = script
    self.feed = feed
    (fd, port) = try bindLoopback(family: family, type: SOCK_DGRAM)
    setReceiveTimeout(fd, seconds: 0.02)
    Thread { [self] in self.serve() }.start()
  }

  deinit { stop() }

  func stop() {
    lock.lock()
    let wasStopped = stopped
    stopped = true
    let count = threads
    lock.unlock()
    guard !wasStopped else { return }
    for _ in 0..<count { threadsExited.wait() }
    close(fd)
  }

  /// When each scripted datagram's `sendto` began, in order: a reader that has a datagram cannot
  /// have it before this.
  var scriptedSendTimes: [TimeInterval] {
    lock.lock()
    defer { lock.unlock() }
    return scriptedSendStarts
  }

  /// Sends `make(query)` now, to whoever sent the last query. Returns whether it left whole.
  func sendToLastQuerier(_ make: ([UInt8]) -> [UInt8]) -> Bool {
    lock.lock()
    let last = lastQuery
    lock.unlock()
    guard let last else { return false }
    return send(make(last.query), to: last.source, last.length)
  }

  /// How much the feed had sent at one moment.
  var fedCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return feedSent
  }

  /// Whether the feed was still running, sent at least `minimum` datagrams since `mark`, and never
  /// left a gap reaching `limit` (after which a blocking read on the client would report no data).
  func keptFeeding(since mark: Int, minimum: Int = 1, limit: TimeInterval) -> (
    ok: Bool, detail: String
  ) {
    lock.lock()
    defer { lock.unlock() }
    let sinceLast = lastFeed.map { monotonicNow() - $0 }
    let ok =
      feeding && !stopped && feedSent - mark >= minimum && longestGap < limit
      && sinceLast.map { $0 < limit } == true
    return (
      ok,
      "feeding: \(feeding && !stopped), fed \(mark) -> \(feedSent), longest gap \(longestGap)s, "
        + "since last \(sinceLast.map { "\($0)s" } ?? "never")"
    )
  }

  private var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }

  private func send(_ datagram: [UInt8], to address: sockaddr_storage, _ length: socklen_t) -> Bool
  {
    var destination = address
    let n = datagram.withUnsafeBytes { raw in
      withUnsafePointer(to: &destination) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          sendto(fd, raw.baseAddress, raw.count, 0, $0, length)
        }
      }
    }
    if n == datagram.count { sent.increment() }
    return n == datagram.count
  }

  private func serve() {
    defer { threadsExited.signal() }
    var buffer = [UInt8](repeating: 0, count: 65536)
    while !isStopped {
      var source = sockaddr_storage()
      var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
      let n = buffer.withUnsafeMutableBytes { raw in
        withUnsafeMutablePointer(to: &source) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &length)
          }
        }
      }
      guard n >= 0 else { continue }
      let query = Array(buffer.prefix(n))
      lock.lock()
      lastQuery = (query, source, length)
      lock.unlock()
      requests.increment()
      for (datagram, after) in script(query) {
        if after > 0 { usleep(useconds_t(after * 1_000_000)) }
        guard !isStopped else { return }
        lock.lock()
        scriptedSendStarts.append(monotonicNow())
        lock.unlock()
        _ = send(datagram, to: source, length)
      }
      if let feed { startFeeding(feed(query), to: source, length) }
    }
  }

  private func startFeeding(_ datagram: [UInt8], to source: sockaddr_storage, _ length: socklen_t) {
    lock.lock()
    guard !feeding, !stopped else {
      lock.unlock()
      return
    }
    feeding = true
    threads += 1
    lock.unlock()
    Thread { [self] in
      defer { threadsExited.signal() }
      // A test that forgets to stop the feed must not leave it running for the whole suite.
      let safetyStop = monotonicNow() + 60
      while !isStopped, monotonicNow() < safetyStop {
        if send(datagram, to: source, length) {
          let now = monotonicNow()
          lock.lock()
          feedSent += 1
          if let lastFeed { longestGap = max(longestGap, now - lastFeed) }
          lastFeed = now
          lock.unlock()
        }
        usleep(useconds_t(interval * 1_000_000))
      }
    }.start()
  }
}

/// A DNS query ignores every datagram that does not carry its transaction ID, however many arrive,
/// and keeps waiting to the same deadline. A datagram that does carry it decides the query, valid
/// or not.
@Suite("DNS ignores replies addressed to another query")
struct DNSForeignReplyTests {
  static let watchdog: TimeInterval = 20
  static let families: [Int32] = [AF_INET, AF_INET6]

  static func loopback(_ family: Int32) -> String { family == AF_INET6 ? "::1" : "127.0.0.1" }

  /// The query's transaction ID.
  static func transactionID(_ query: [UInt8]) -> [UInt8] { Array(query.prefix(2)) }

  /// A well-formed answer to `query` carrying 192.0.2.`last`.
  static func answer(_ query: [UInt8], last: UInt8) -> [UInt8] {
    let record: [UInt8] = [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, last]
    return FaultInjectionWireTests.dnsResponse(to: query, answers: record)
  }

  /// `datagram` with its transaction ID changed, so it answers some other query.
  static func foreign(_ datagram: [UInt8]) -> [UInt8] {
    var copy = datagram
    copy[0] ^= 0x80
    return copy
  }

  /// A `recv` that counts the datagrams it returns.
  static func countingReceive(_ reads: FaultCounter) -> TestSeams.ReceiveDatagram {
    { fd, buffer in
      let received = Darwin.recv(fd, buffer.baseAddress, buffer.count, 0)
      if received >= 0 { reads.increment() }
      return received
    }
  }

  // MARK: Foreign, then the reply

  @Test(
    "A reply for another query is ignored, and the query's own reply answers it",
    arguments: families)
  func foreignThenValid(family: Int32) async throws {
    let delay: TimeInterval = 0.2
    // The foreign reply goes at once; the real one only after `delay`.
    let peer = try ScriptedDNSPeer(family: family) { query in
      [(Self.foreign(Self.answer(query, last: 1)), 0), (Self.answer(query, last: 2), delay)]
    }
    defer { peer.stop() }

    let (result, _) = try await measure(within: Self.watchdog) {
      try await TestSeams.$dnsServerPort.withValue(peer.port) {
        try await SwiftFTR().dns.a(
          hostname: "foreign.example", server: Self.loopback(family), timeout: 5)
      }
    }
    #expect(result.records.first.map { "\($0.data)" } == "\(DNSRecordData.ipv4("192.0.2.2"))")
    // The round trip is the real reply's: it cannot be shorter than the wait before it was sent.
    #expect(result.rttMs >= delay * 1000, "rttMs \(result.rttMs)")
    #expect(
      await eventually(within: Self.watchdog) { peer.sent.value == 2 }, "sent: \(peer.sent.value)")
  }

  enum Unattributable: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case empty, oneByte
    var datagram: [UInt8] { self == .empty ? [] : [0x42] }
    var testDescription: String { rawValue }
  }

  @Test(
    "A datagram too short to carry a transaction ID is ignored, and the reply after it answers",
    arguments: Unattributable.allCases)
  func tooShortThenValid(datagram: Unattributable) async throws {
    let peer = try ScriptedDNSPeer { query in
      [(datagram.datagram, 0), (Self.answer(query, last: 2), 0)]
    }
    defer { peer.stop() }
    let reads = FaultCounter()

    let (answers, _) = try await measure(within: Self.watchdog) {
      try await TestSeams.$receiveDatagram.withValue(Self.countingReceive(reads)) {
        try await __dnsQuery(
          server: "127.0.0.1", port: peer.port, name: "short.example", type: 1, timeout: 5)
      }
    }
    #expect(answers.first?.rdata == Data([192, 0, 2, 2]))
    // Both were read: the short one was consumed and ignored, not left queued.
    #expect(reads.value == 2)
  }

  // MARK: Foreign only

  /// Runs `body` with reads counted, and checks the claim that makes a timeout the deadline's
  /// doing: every foreign datagram had been read while the query was still waiting.
  static func waitsOutForeign<T: Sendable>(
    count: Int, timeout: TimeInterval, _ body: @escaping @Sendable () async throws -> T
  ) async throws -> (T, TimeInterval) {
    let reads = FaultCounter()
    let lastRead = TimeStamp()
    let receive: TestSeams.ReceiveDatagram = { fd, buffer in
      let received = Darwin.recv(fd, buffer.baseAddress, buffer.count, 0)
      let code = Darwin.errno
      if received >= 0 {
        reads.increment()
        lastRead.set(monotonicNow())
      }
      Darwin.errno = code
      return received
    }
    // Both ends are stamped on the query's side, so a slow resume of the test cannot move them.
    let ((value, end), elapsed) = try await TestSeams.$receiveDatagram.withValue(receive) {
      try await measure(within: Self.watchdog) { (try await body(), monotonicNow()) }
    }
    #expect(reads.value == count, "read \(reads.value) of \(count) foreign datagrams")
    // It went on waiting after the last foreign datagram, and ended at its deadline.
    let read = try #require(lastRead.value)
    #expect(end > read)
    #expect(elapsed >= timeout * 0.95, "ended after \(elapsed)s against a \(timeout)s timeout")
    return (value, elapsed)
  }

  @Test("A server that sends only replies for other queries times out, and is not reachable")
  func foreignOnly() async throws {
    let count = 3
    let peer = try ScriptedDNSPeer { query in
      (0..<count).map { _ in (Self.foreign(Self.answer(query, last: 1)), 0) }
    }
    defer { peer.stop() }
    let timeout: TimeInterval = 2

    let (thrown, _) = try await Self.waitsOutForeign(count: count, timeout: timeout) {
      await EventBasedDNSTests.error {
        try await __dnsQuery(
          server: "127.0.0.1", port: peer.port, name: "foreign.example", type: 1,
          timeout: timeout)
      }
    }
    #expect(EventBasedDNSTests.isTimeout(thrown), "\(String(describing: thrown))")

    let (probe, _) = try await Self.waitsOutForeign(count: count, timeout: timeout) {
      try await TestSeams.$dnsServerPort.withValue(peer.port) {
        try await dnsProbe(server: "127.0.0.1", query: "foreign.example", timeout: timeout)
      }
    }
    #expect(probe.outcome == .timedOut)
    #expect(!probe.isReachable)
    #expect(probe.rtt == nil)
    #expect(probe.elapsed == nil)
    #expect(probe.error == "Timeout - no response")
    #expect(
      await eventually(within: Self.watchdog) { peer.sent.value == 2 * count },
      "sent: \(peer.sent.value)")
  }

  // MARK: The right ID decides

  enum RightIDMalformed: String, CaseIterable, CustomTestStringConvertible, Sendable {
    /// Only the two bytes of the ID.
    case idOnly
    /// The ID and the flags of a response, but no rest of the header.
    case shortHeader
    func datagram(_ query: [UInt8]) -> [UInt8] {
      DNSForeignReplyTests.transactionID(query) + (self == .idOnly ? [] : [0x81, 0x80])
    }
    var testDescription: String { rawValue }
  }

  @Test(
    "A malformed datagram that carries the query's ID still ends it at once as malformed",
    arguments: RightIDMalformed.allCases)
  func rightIDMalformed(body: RightIDMalformed) async throws {
    let peer = try ScriptedDNSPeer { query in [(body.datagram(query), 0)] }
    defer { peer.stop() }
    // Waiting out this timeout would mean the datagram was ignored.
    let timeout: TimeInterval = 30

    let (outcome, _) = try await measure(within: Self.watchdog) {
      try await TestSeams.$dnsServerPort.withValue(peer.port) {
        let thrown = await EventBasedDNSTests.error {
          try await __dnsQuery(
            server: "127.0.0.1", port: peer.port, name: "malformed.example", type: 1,
            timeout: timeout)
        }
        let probe = try await dnsProbe(
          server: "127.0.0.1", query: "malformed.example", timeout: timeout)
        return (thrown, probe)
      }
    }
    let (thrown, probe) = outcome
    #expect(EventBasedDNSTests.isMalformed(thrown), "\(String(describing: thrown))")
    #expect(probe.outcome == .malformedReply)
    #expect(probe.isReachable)
    #expect(probe.error == "Malformed response")
  }

  // MARK: Stale reply queued before the send

  @Test("A stale reply queued before the request left, and read after it, is ignored")
  func staleReplyReadAfterTheSend() async throws {
    let replies = FaultCounter()
    // The stale reply carries 192.0.2.1, the one to the request that left carries 192.0.2.2.
    let peer = try ScriptedDNSPeer { query in
      replies.increment()
      return [(Self.answer(query, last: replies.value == 1 ? 1 : 2), 0)]
    }
    defer { peer.stop() }
    let staged = FaultCounter()
    let reads = FaultCounter()
    // The only send puts a copy of the request with another ID on the wire first, as an earlier
    // query from the same port would have, waits until its reply is queued, and then sends the
    // request itself. The exchange's queue is busy with the send until then, so it reads the
    // stale reply only after the request has left.
    let send: TestSeams.SendDatagram = { fd, bytes in
      var stale = [UInt8](bytes)
      stale[0] ^= 0x80
      _ = Darwin.send(fd, stale, stale.count, 0)
      if EventBasedDNSTests.waitUntilReadable(fd, limit: 5) { staged.increment() }
      return Darwin.send(fd, bytes.baseAddress, bytes.count, 0)
    }

    let (answers, _) = try await measure(within: Self.watchdog) {
      try await TestSeams.$sendDatagram.withValue(send) {
        try await TestSeams.$receiveDatagram.withValue(Self.countingReceive(reads)) {
          try await __dnsQuery(
            server: "127.0.0.1", port: peer.port, name: "stale.example", type: 1, timeout: 5)
        }
      }
    }
    try #require(staged.value == 1, "the stale reply was never queued before the send")
    #expect(answers.first?.rdata == Data([192, 0, 2, 2]))
    #expect(reads.value == 2, "reads: \(reads.value)")
  }

  // MARK: A peer that never stops

  /// Leaves the exchange's socket blocking, with a receive timeout far longer than the feed's
  /// interval, so each read waits for the next foreign datagram instead of reporting no data: the
  /// socket never runs dry while the feed runs.
  static let neverDryTimeout: TimeInterval = 1
  static let leaveBlocking: TestSeams.FileControl = { fd, command, argument in
    guard command == F_SETFL else { return fcntl(fd, command, argument) }
    setReceiveTimeout(fd, seconds: neverDryTimeout)
    return 0
  }

  static func endlessForeign(family: Int32 = AF_INET) throws -> ScriptedDNSPeer {
    try ScriptedDNSPeer(
      family: family, feed: { Self.foreign(Self.answer($0, last: 1)) }, script: { _ in [] })
  }

  @Test(
    "Foreign datagrams that never stop do not hold off the deadline", arguments: families)
  func endlessForeignDeadline(family: Int32) async throws {
    let peer = try Self.endlessForeign(family: family)
    defer { peer.stop() }
    let reads = FaultCounter()
    let timeout: TimeInterval = 0.3

    let (thrown, elapsed) = try await measure(within: Self.watchdog) {
      await TestSeams.$fileControl.withValue(Self.leaveBlocking) {
        await TestSeams.$receiveDatagram.withValue(Self.countingReceive(reads)) {
          await EventBasedDNSTests.error {
            try await __dnsQuery(
              server: Self.loopback(family), port: peer.port, name: "endless.example", type: 1,
              timeout: timeout)
          }
        }
      }
    }
    let flow = peer.keptFeeding(since: 0, limit: Self.neverDryTimeout)

    #expect(flow.ok, "the socket was not kept fed while the query waited: \(flow.detail)")
    #expect(reads.value >= 10, "the query read only \(reads.value) datagrams")
    #expect(EventBasedDNSTests.isTimeout(thrown), "\(String(describing: thrown))")
    #expect(elapsed >= timeout * 0.95, "ended after \(elapsed)s against a \(timeout)s timeout")
  }

  @Test("Cancelling a query fed foreign datagrams that never stop returns promptly")
  func endlessForeignCancelled() async throws {
    let peer = try Self.endlessForeign()
    defer { peer.stop() }
    let reads = FaultCounter()
    // Only cancellation can end the query within the watchdog.
    let timeout: TimeInterval = 60

    let task = Task {
      await TestSeams.$fileControl.withValue(Self.leaveBlocking) {
        await TestSeams.$receiveDatagram.withValue(Self.countingReceive(reads)) {
          await EventBasedDNSTests.error {
            try await __dnsQuery(
              server: "127.0.0.1", port: peer.port, name: "endless.example", type: 1,
              timeout: timeout)
          }
        }
      }
    }
    #expect(
      await eventually(within: Self.watchdog) { reads.value >= 10 },
      "the query never read the feed: \(reads.value)")
    let atCancel = peer.fedCount
    task.cancel()

    let (thrown, _) = try await measure(within: 10) { await task.value }
    let flow = peer.keptFeeding(since: atCancel, minimum: 0, limit: Self.neverDryTimeout)

    #expect(flow.ok, "the socket was not kept fed until the query returned: \(flow.detail)")
    #expect(thrown is CancellationError, "\(String(describing: thrown))")
  }

  // MARK: Nothing late is judged with an early stamp

  enum LateEvent: String, CaseIterable, CustomTestStringConvertible, Sendable {
    /// The query's reply, delivered after the deadline.
    case reply
    /// A refusal, reported after the deadline.
    case refusal
    var testDescription: String { rawValue }
  }

  enum Caller: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case query, probe
    var testDescription: String { rawValue }
  }

  @Test(
    "After a foreign datagram, a reply or refusal that comes after the deadline is a timeout",
    arguments: LateEvent.allCases, Caller.allCases)
  func lateEventAfterForeign(event: LateEvent, caller: Caller) async throws {
    let peer = try ScriptedDNSPeer { query in [(Self.foreign(Self.answer(query, last: 1)), 0)] }
    defer { peer.stop() }
    let timeout: TimeInterval = 0.3
    let calls = FaultCounter()
    let firstRead = TimeStamp()
    let lateSent = FaultCounter()
    // The first read takes the foreign datagram. Any later read behaves as a thread descheduled
    // between its stamp and `recv` would: it returns only what came after the deadline (the late
    // reply, or a refusal). A read in the same event must not be made; a read in a later event,
    // which can legitimately run before the deadline timer does, must report a timeout. Either
    // way the outcome below is a timeout, so that is what the test asserts.
    let receive: TestSeams.ReceiveDatagram = { fd, buffer in
      calls.increment()
      if calls.value == 1 {
        firstRead.set(monotonicNow())
        return Darwin.recv(fd, buffer.baseAddress, buffer.count, 0)
      }
      let giveUp = monotonicNow() + 5
      switch event {
      case .reply:
        while lateSent.value == 0, monotonicNow() < giveUp { usleep(1000) }
        _ = EventBasedDNSTests.waitUntilReadable(fd, limit: 5)
        return Darwin.recv(fd, buffer.baseAddress, buffer.count, 0)
      case .refusal:
        let first = firstRead.value ?? 0
        while monotonicNow() <= first + timeout + 0.05, monotonicNow() < giveUp { usleep(1000) }
        Darwin.errno = ECONNREFUSED
        return -1
      }
    }
    let task = Task {
      await TestSeams.$receiveDatagram.withValue(receive) {
        await TestSeams.$dnsServerPort.withValue(peer.port) {
          switch caller {
          case .query:
            let thrown = await EventBasedDNSTests.error {
              try await __dnsQuery(
                server: "127.0.0.1", port: peer.port, name: "late.example", type: 1,
                timeout: timeout)
            }
            return (thrown, DNSProbeResult?.none)
          case .probe:
            let probe = try? await dnsProbe(
              server: "127.0.0.1", query: "late.example", timeout: timeout)
            return (Error?.none, probe)
          }
        }
      }
    }
    if event == .reply {
      // Once the first read is done, wait until well past the deadline, which was fixed before
      // that read, and only then deliver the query's own reply.
      #expect(await eventually(within: Self.watchdog) { firstRead.value != nil })
      let first = try #require(firstRead.value)
      #expect(
        await eventually(within: Self.watchdog) { monotonicNow() > first + timeout + 0.05 })
      #expect(peer.sendToLastQuerier { Self.answer($0, last: 2) })
      lateSent.increment()
    }
    let ((thrown, probe), _) = try await measure(within: Self.watchdog) { await task.value }

    switch caller {
    case .query:
      #expect(EventBasedDNSTests.isTimeout(thrown), "\(String(describing: thrown))")
    case .probe:
      let result = try #require(probe)
      #expect(result.outcome == .timedOut, "\(result)")
      #expect(result.rtt == nil)
    }
  }

  // MARK: Team Cymru

  @Test("A Cymru lookup ignores a reply for another query and resolves from its own")
  func cymruForeignThenValid() async throws {
    let delay: TimeInterval = 0.2
    // Each TXT query gets a foreign copy of its answer at once and the real one after `delay`,
    // so a lookup that moved on at the foreign one would not resolve.
    let peer = try ScriptedDNSPeer { query in
      guard let (reply, _) = CymruFixture.answer(query) else { return [] }
      return [(Self.foreign(reply), 0), (reply, delay)]
    }
    defer { peer.stop() }

    let (result, elapsed) = try await measure(within: Self.watchdog) {
      try await TestSeams.$dnsServerPort.withValue(peer.port) {
        try await CymruDNSResolver(servers: ["127.0.0.1"])
          .resolve(ipv4Addrs: ["8.8.8.8"], timeout: 5)
      }
    }
    let info = try #require(result["8.8.8.8"])
    #expect(info.asn == 15169)
    #expect(info.name == "GOOGLE, US")
    // One origin query and one AS-name query, each answered foreign first.
    #expect(peer.requests.value == 2)
    #expect(
      await eventually(within: Self.watchdog) { peer.sent.value == 4 }, "sent: \(peer.sent.value)")
    #expect(elapsed >= 2 * delay, "resolved after \(elapsed)s")
  }

  // MARK: TXT lookups

  static let txtRecord: [UInt8] =
    [0xC0, 0x0C, 0, 16, 0, 1, 0, 0, 0, 60, 0, 3, 2] + Array("ok".utf8)

  @Test("A TXT lookup, as the whoami fallback makes it, ignores a reply for another query")
  func txtForeignThenValid() async throws {
    let peer = try ScriptedDNSPeer { query in
      let reply = FaultInjectionWireTests.dnsResponse(to: query, answers: Self.txtRecord)
      return [(Self.foreign(reply), 0), ([], 0), (reply, 0)]
    }
    defer { peer.stop() }

    let (strings, _) = try await measure(within: Self.watchdog) {
      await TestSeams.$dnsServerPort.withValue(peer.port) {
        await DNSClient.queryTXT(name: "txt.example", timeout: 5, servers: ["127.0.0.1"])
      }
    }
    #expect(strings == ["ok"])
    #expect(
      await eventually(within: Self.watchdog) { peer.sent.value == 3 }, "sent: \(peer.sent.value)")
  }
}

/// One time stamp that several threads write and read.
final class TimeStamp: @unchecked Sendable {
  private let lock = NSLock()
  private var stamp: TimeInterval?

  var value: TimeInterval? {
    lock.lock()
    defer { lock.unlock() }
    return stamp
  }

  func set(_ time: TimeInterval) {
    lock.lock()
    stamp = time
    lock.unlock()
  }
}
