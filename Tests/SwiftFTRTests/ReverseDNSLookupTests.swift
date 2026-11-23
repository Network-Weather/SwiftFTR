import Foundation
import Testing
import dnssd

@testable import SwiftFTR

/// The `DNSServiceQueryRecord` reverse lookup: the question it asks, the outcome of each reply,
/// and the `DNSServiceRef` rules (start and deallocate on the lookup's queue, one deallocate per
/// reference, one resume per call) under every way a lookup can end. Everything here runs
/// against ``FakeDNSService`` except the real-daemon tests, which ask only for loopback names
/// the daemon answers from its local records, and the gated live comparison.
@Suite
struct ReverseDNSLookupTests {
  static let watchdog: TimeInterval = 20
  /// Long enough that no test ends by its deadline unless it means to.
  static let longTimeout: TimeInterval = 60

  // MARK: - The question

  @Test("The PTR question for IPv4, IPv6, mapped and zoned addresses")
  func questions() throws {
    let v4 = try #require(ReverseDNSQuestion(address: "1.2.3.4"))
    #expect(v4.name == "4.3.2.1.in-addr.arpa")
    #expect(v4.interfaceIndex == 0)
    #expect(!v4.isMulticast)

    let v6 = try #require(ReverseDNSQuestion(address: "2001:db8::1"))
    #expect(
      v6.name == "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa")
    #expect(v6.interfaceIndex == 0)
    #expect(!v6.isMulticast)

    // A mapped address asks the IPv4 question, as getnameinfo does.
    let mapped = try #require(ReverseDNSQuestion(address: "::ffff:1.2.3.4"))
    #expect(mapped == v4)

    // A zone selects the link on a link-local address, by name or by number.
    let loopbackIndex = if_nametoindex("lo0")
    #expect(loopbackIndex != 0)
    let zoned = try #require(ReverseDNSQuestion(address: "fe80::1%lo0"))
    #expect(zoned.interfaceIndex == loopbackIndex)
    #expect(zoned.isMulticast)
    #expect(zoned.name.hasSuffix(".0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.e.f.ip6.arpa"))
    #expect(try #require(ReverseDNSQuestion(address: "fe80::1%7")).interfaceIndex == 7)
    #expect(try #require(ReverseDNSQuestion(address: "fe80::1")).interfaceIndex == 0)

    // On any other address a zone is ignored: it would scope a unicast question to one link.
    #expect(try #require(ReverseDNSQuestion(address: "2001:db8::1%lo0")) == v6)

    #expect(try #require(ReverseDNSQuestion(address: "169.254.10.20")).isMulticast)
    #expect(try #require(ReverseDNSQuestion(address: "::ffff:169.254.10.20")).isMulticast)

    for invalid in ["", "host.example", "1.2.3", "1.2.3.4.5", "fe80::1%", "%lo0", "::g"] {
      #expect(ReverseDNSQuestion(address: invalid) == nil, "\(invalid)")
    }
  }

  @Test("PTR data is decoded as exactly one uncompressed name, without the trailing dot")
  func ptrData() {
    func decode(_ bytes: [UInt8]) -> String? {
      bytes.withUnsafeBytes { ReverseDNSLookup.hostname(fromPTR: $0) }
    }
    #expect(decode(PTRData.name("one.one.one.one")) == "one.one.one.one")
    #expect(decode(PTRData.name("dns.google.")) == "dns.google")
    #expect(decode([0]) == nil, "the root name is no hostname")
    #expect(decode([]) == nil)
    #expect(decode([5, 0x61, 0x62]) == nil, "a label longer than the data")
    #expect(decode([3, 0x61, 0x62, 0x63]) == nil, "no terminating root label")
    #expect(decode(PTRData.name("a.b") + [1]) == nil, "data after the name")
    #expect(decode([0xC0, 0x00]) == nil, "a compression pointer to itself")
    #expect(decode([0x40, 0x00]) == nil, "a reserved label type")
  }

  @Test("Labels from the reverse zone are escaped: printable ASCII only, one label reads as one")
  func hostileLabels() {
    func decode(_ labels: [[UInt8]]) -> String? {
      var wire: [UInt8] = []
      for label in labels {
        wire.append(UInt8(label.count))
        wire.append(contentsOf: label)
      }
      wire.append(0)
      return wire.withUnsafeBytes { ReverseDNSLookup.hostname(fromPTR: $0) }
    }
    let net = Array("net".utf8)
    #expect(decode([Array("evil.example".utf8), net]) == #"evil\.example.net"#)
    #expect(decode([Array(#"a\b"#.utf8), net]) == #"a\\b.net"#)
    #expect(decode([Array("a b".utf8), net]) == #"a\032b.net"#)
    #expect(decode([[0x61, 0x00, 0x62], net]) == #"a\000b.net"#)
    #expect(decode([Array("\u{1B}[31m".utf8), net]) == #"\027[31m.net"#)
    #expect(decode([[0x61, 0xFF, 0x62], net]) == #"a\255b.net"#, "invalid UTF-8")
    #expect(decode([Array("aéb".utf8), net]) == #"a\195\169b.net"#, "UTF-8 outside ASCII")
    #expect(decode([[0x7F], net]) == #"\127.net"#)
    #expect(decode([Array("host-1_a".utf8), Array("Example".utf8), net]) == "host-1_a.Example.net")

    let label63 = [UInt8](repeating: 0x61, count: 63)
    #expect(decode([label63, net]) == String(repeating: "a", count: 63) + ".net")
    // 63 + 63 + 63 + 61 bytes of labels, four length bytes and the root: 255, the maximum.
    let longest = [label63, label63, label63, [UInt8](repeating: 0x62, count: 61)]
    let longestLength = 63 * 3 + 61 + 3
    #expect(decode(longest)?.count == longestLength)
    let tooLong = [label63, label63, label63, [UInt8](repeating: 0x62, count: 62)]
    #expect(decode(tooLong) == nil, "256 bytes in wire form")
    #expect(decode([[UInt8](repeating: 0x61, count: 64)]) == nil, "a 64-byte label")
    #expect(
      [UInt8]([1, 0x61, 0xC0, 0x00]).withUnsafeBytes { ReverseDNSLookup.hostname(fromPTR: $0) }
        == nil, "a compression pointer after a label")

    // Whatever the bytes, the result is printable ASCII, and its unescaped dots separate
    // exactly the labels the data had.
    var generator = SystemRandomNumberGenerator()
    for _ in 0..<500 {
      let labels = (0..<Int.random(in: 1...4, using: &generator)).map { _ in
        (0..<Int.random(in: 1...20, using: &generator)).map { _ in
          UInt8.random(in: 0...255, using: &generator)
        }
      }
      guard let name = decode(labels) else {
        Issue.record("well-formed labels were rejected: \(labels)")
        continue
      }
      let printable = name.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
      #expect(printable, "\(name)")
      #expect(Self.unescapedDots(name) == labels.count - 1, "\(name)")
    }
  }

  /// The dots in `name` that are not escaped by a backslash.
  static func unescapedDots(_ name: String) -> Int {
    var count = 0
    var escaped = false
    for character in name {
      if escaped {
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "." {
        count += 1
      }
    }
    return count
  }

  @Test("An address that is not a literal makes no query")
  func invalidAddressMakesNoQuery() async {
    let fake = FakeDNSService()
    let outcome = await fake.install {
      await ReverseDNSLookup.lookup("not-an-address", timeout: Self.longTimeout)
    }
    #expect(outcome == .error(.invalidAddress))
    #expect(fake.starts.isEmpty)
  }

  // MARK: - Outcomes

  @Test("An added PTR record is the answer; the query is started and deallocated on its queue")
  func answer() async throws {
    let fake = FakeDNSService()
    let outcome = try await Self.run(fake, "1.1.1.1") {
      fake.deliver(rdata: PTRData.name("one.one.one.one"))
    }
    #expect(outcome == .answer("one.one.one.one"))
    #expect(outcome.isCacheable)
    let question = try #require(fake.question())
    #expect(question.name == "1.1.1.1.in-addr.arpa")
    #expect(question.interfaceIndex == 0)
    #expect(question.flags & DNSServiceFlags(kDNSServiceFlagsReturnIntermediates) != 0)
    try await Self.expectTornDown(fake, references: 1)
  }

  @Test(
    "No such record or no such name is noSuchRecord, which is not cacheable",
    arguments: [DNSServiceStatus.noSuchRecord, DNSServiceStatus.noSuchName])
  func noSuchRecord(code: DNSServiceErrorType) async throws {
    let fake = FakeDNSService()
    let outcome = try await Self.run(fake, "192.0.2.1") {
      fake.deliver(flags: DNSServiceFlags(kDNSServiceFlagsAdd), error: code)
    }
    #expect(outcome == .noSuchRecord)
    #expect(!outcome.isCacheable)
    try await Self.expectTornDown(fake, references: 1)
  }

  @Test(
    "A daemon error ends the lookup with that error",
    arguments: [DNSServiceStatus.serviceNotRunning, DNSServiceStatus.defunctConnection])
  func daemonError(code: DNSServiceErrorType) async throws {
    let fake = FakeDNSService()
    let outcome = try await Self.run(fake, "192.0.2.1") {
      fake.deliver(flags: 0, error: code)
    }
    #expect(outcome == .error(.daemon(code)))
    #expect(!outcome.isCacheable)
    try await Self.expectTornDown(fake, references: 1)
  }

  @Test("The daemon's own timeout is timedOut")
  func daemonTimeout() async throws {
    let fake = FakeDNSService()
    let outcome = try await Self.run(fake, "192.0.2.1") {
      fake.deliver(error: DNSServiceStatus.timeout)
    }
    #expect(outcome == .timedOut)
    try await Self.expectTornDown(fake, references: 1)
  }

  @Test("An answer whose label holds a dot reaches the caller escaped")
  func escapedAnswer() async throws {
    let fake = FakeDNSService()
    var rdata: [UInt8] = [12]
    rdata.append(contentsOf: "evil.example".utf8)
    rdata.append(3)
    rdata.append(contentsOf: "net".utf8)
    rdata.append(0)
    let outcome = try await Self.run(fake, "192.0.2.1") { [rdata] in
      fake.deliver(rdata: rdata)
    }
    #expect(outcome == .answer(#"evil\.example.net"#))
    try await Self.expectTornDown(fake, references: 1)
  }

  @Test("PTR data that is not a name is malformedRecord")
  func malformedRecord() async throws {
    let fake = FakeDNSService()
    let outcome = try await Self.run(fake, "192.0.2.1") {
      fake.deliver(rdata: [9, 0x61])
    }
    #expect(outcome == .error(.malformedRecord))
    try await Self.expectTornDown(fake, references: 1)
  }

  @Test("Intermediate CNAMEs and remove events are ignored; the PTR after them answers")
  func intermediatesIgnored() async throws {
    let fake = FakeDNSService()
    let outcome = try await Self.run(fake, "192.0.2.1") {
      // A CNAME (RFC 2317 delegation), then the PTR going away, then the PTR. All three are
      // queued on the lookup's queue in this order.
      fake.deliver(rrtype: UInt16(kDNSServiceType_CNAME), rdata: PTRData.name("1.0/25.2.0.192"))
      fake.deliver(flags: 0, rdata: PTRData.name("old.example"))
      fake.deliver(rdata: PTRData.name("host.example"))
    }
    #expect(outcome == .answer("host.example"))
    try await Self.expectTornDown(fake, references: 1)
  }

  @Test("A start call that fails is an error, with nothing to deallocate")
  func startFails() async throws {
    let fake = FakeDNSService(start: .fail(DNSServiceStatus.serviceNotRunning))
    let (outcome, _) = try await measure(within: Self.watchdog) {
      await fake.install {
        await ReverseDNSLookup.lookup("192.0.2.1", timeout: Self.longTimeout)
      }
    }
    #expect(outcome == .error(.startFailed(DNSServiceStatus.serviceNotRunning)))
    #expect(fake.starts.count == 1)
    let startedOnQueue = fake.starts.allSatisfy { $0.onLookupQueue }
    #expect(startedOnQueue)
    #expect(fake.deallocs.isEmpty)
  }

  @Test("A queue call that fails is an error, and the reference is deallocated on its queue")
  func queueCallFails() async throws {
    let code = DNSServiceErrorType(kDNSServiceErr_BadParam)
    let fake = FakeDNSService(queueResult: code)
    let (outcome, _) = try await measure(within: Self.watchdog) {
      await fake.install {
        await ReverseDNSLookup.lookup("192.0.2.1", timeout: Self.longTimeout)
      }
    }
    #expect(outcome == .error(.dispatchQueueFailed(code)))
    try await Self.expectTornDown(fake, references: 1)
  }

  @Test("With no reply, the lookup times out at its deadline, not before")
  func deadline() async throws {
    let fake = FakeDNSService()
    let timeout: TimeInterval = 0.3
    let (outcome, elapsed) = try await measure(within: Self.watchdog) {
      await fake.install { await ReverseDNSLookup.lookup("192.0.2.1", timeout: timeout) }
    }
    #expect(outcome == .timedOut)
    #expect(elapsed >= timeout)
    try await Self.expectTornDown(fake, references: 1)
  }

  // MARK: - Cancellation and the deadline at every point

  @Test("Cancelled before it starts: cancelled, no query made, the permit returned")
  func cancelledBeforeStart() async throws {
    let fake = FakeDNSService()
    let limiter = _ConcurrencySemaphore(maxConcurrent: 1)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await fake.install {
        await ReverseDNSLookup.lookup("192.0.2.1", timeout: Self.longTimeout, limiter: limiter)
      }
    }
    let (outcome, _) = try await measure(within: Self.watchdog) { await task.value }
    #expect(outcome == .cancelled)
    #expect(fake.starts.isEmpty)
    #expect(fake.deallocs.isEmpty)

    // The only permit came back: a second lookup on the same limiter runs.
    let (second, _) = try await measure(within: Self.watchdog) {
      await fake.install {
        await ReverseDNSLookup.lookup("192.0.2.1", timeout: 0.05, limiter: limiter)
      }
    }
    #expect(second == .timedOut)
  }

  @Test("Cancelled during a stalled start: released at once, deallocated once the start returns")
  func cancelledDuringStart() async throws {
    let gate = StallGate()
    defer { gate.open() }
    let fake = FakeDNSService(start: .gated(gate))
    let task = Task {
      await fake.install {
        await ReverseDNSLookup.lookup("192.0.2.1", timeout: Self.longTimeout)
      }
    }
    try await waitBounded("the start call") {
      _ = await eventually(within: 60) { !fake.starts.isEmpty }
    }
    task.cancel()
    let (outcome, _) = try await measure(within: Self.watchdog) { await task.value }
    // Released while the start call was still blocked in the daemon.
    let stillBlocked = fake.startedCount == 0
    #expect(stillBlocked)
    #expect(outcome == .cancelled)

    gate.open()
    try await Self.expectTornDown(fake, references: 1)
    #expect(fake.scheduledCount == 1)
  }

  @Test("Cancelled after it starts: cancelled, and deallocated on its queue")
  func cancelledAfterStart() async throws {
    let fake = FakeDNSService()
    let task = Task {
      await fake.install {
        await ReverseDNSLookup.lookup("192.0.2.1", timeout: Self.longTimeout)
      }
    }
    try await Self.waitScheduled(fake, 1)
    task.cancel()
    let (outcome, _) = try await measure(within: Self.watchdog) { await task.value }
    #expect(outcome == .cancelled)
    try await Self.expectTornDown(fake, references: 1)
  }

  @Test("A start stalled past the deadline releases the caller and deallocates once on return")
  func startStalledPastDeadline() async throws {
    let gate = StallGate()
    defer { gate.open() }
    let fake = FakeDNSService(start: .gated(gate))
    let (outcome, _) = try await measure(within: Self.watchdog) {
      await fake.install { await ReverseDNSLookup.lookup("192.0.2.1", timeout: 0.2) }
    }
    // The deadline ran on its own queue while the start call held the lookup's queue.
    let stillBlocked = fake.startedCount == 0
    #expect(stillBlocked)
    #expect(outcome == .timedOut)
    #expect(fake.starts.count == 1)

    gate.open()
    try await Self.expectTornDown(fake, references: 1)
  }

  @Test("Cancellation racing a reply: one outcome, one deallocate, on the lookup's queue")
  func cancellationRacesReply() async throws {
    for _ in 0..<200 {
      let fake = FakeDNSService()
      let task = Task {
        await fake.install {
          await ReverseDNSLookup.lookup("192.0.2.1", timeout: Self.longTimeout)
        }
      }
      try await Self.waitScheduled(fake, 1)
      fake.deliver(rdata: PTRData.name("host.example"))
      task.cancel()
      let (outcome, _) = try await measure(within: Self.watchdog) { await task.value }
      let expected = outcome == .answer("host.example") || outcome == .cancelled
      #expect(expected, "\(outcome)")
      try await Self.expectTornDown(fake, references: 1)
    }
  }

  @Test("Cancellation racing the deadline: one outcome, and every reference deallocated once")
  func cancellationRacesDeadline() async throws {
    for iteration in 0..<200 {
      let fake = FakeDNSService()
      let limiter = _ConcurrencySemaphore(maxConcurrent: 1)
      let timeout = 0.0005 * Double(1 + iteration % 6)
      let task = Task {
        await fake.install {
          await ReverseDNSLookup.lookup("192.0.2.1", timeout: timeout, limiter: limiter)
        }
      }
      try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
      task.cancel()
      let (outcome, _) = try await measure(within: Self.watchdog) { await task.value }
      let expected = outcome == .timedOut || outcome == .cancelled
      #expect(expected, "\(outcome)")
      // The permit comes back only once the lookup is torn down, so after this nothing moves.
      try await waitBounded("the permit returned", within: Self.watchdog) {
        try? await limiter.wait()
      }
      // Resolved before the start ran makes no query; otherwise its one reference is freed.
      try await Self.expectTornDown(fake, references: fake.startedCount)
    }
  }

  // MARK: - The cap on lookups in flight

  @Test("The limiter bounds the references open at once, and a waiting lookup can be cancelled")
  func limiterBoundsReferences() async throws {
    let fake = FakeDNSService()
    let limiter = _ConcurrencySemaphore(maxConcurrent: 3)
    let (outcomes, _) = try await measure(within: Self.watchdog) {
      await fake.install {
        await withTaskGroup(of: ReverseDNSLookupOutcome.self) { group in
          for _ in 0..<12 {
            group.addTask {
              await ReverseDNSLookup.lookup("192.0.2.1", timeout: 0.1, limiter: limiter)
            }
          }
          var all: [ReverseDNSLookupOutcome] = []
          for await outcome in group { all.append(outcome) }
          return all
        }
      }
    }
    #expect(outcomes.count == 12)
    #expect(outcomes.allSatisfy { $0 == .timedOut })
    #expect(fake.maxConcurrent == 3)
    try await Self.expectTornDown(fake, references: 12)

    // Every permit taken by a lookup that never returns: a further lookup waits, and ends when
    // its task is cancelled, without making a query.
    let blocked = FakeDNSService()
    let holders = (0..<3).map { _ in
      Task {
        await blocked.install {
          await ReverseDNSLookup.lookup("192.0.2.1", timeout: Self.longTimeout, limiter: limiter)
        }
      }
    }
    defer { for holder in holders { holder.cancel() } }
    try await Self.waitScheduled(blocked, 3)
    let waiter = Task {
      await blocked.install {
        await ReverseDNSLookup.lookup("192.0.2.1", timeout: Self.longTimeout, limiter: limiter)
      }
    }
    // Let the waiter reach the limiter before cancelling it; either order must end the wait.
    try? await Task.sleep(nanoseconds: 50_000_000)
    waiter.cancel()
    let (waited, _) = try await measure(within: Self.watchdog) { await waiter.value }
    #expect(waited == .cancelled)
    #expect(blocked.starts.count == 3)
    for holder in holders { holder.cancel() }
    for holder in holders {
      let (held, _) = try await measure(within: Self.watchdog) { await holder.value }
      #expect(held == .cancelled)
    }
    try await Self.expectTornDown(blocked, references: 3)
  }

  @Test("A lookup released at its deadline keeps its permit until its reference is gone")
  func permitHeldUntilTornDown() async throws {
    let gate = StallGate()
    defer { gate.open() }
    let fake = FakeDNSService(start: .gated(gate))
    let limiter = _ConcurrencySemaphore(maxConcurrent: 1)
    let (first, _) = try await measure(within: Self.watchdog) {
      await fake.install {
        await ReverseDNSLookup.lookup("192.0.2.1", timeout: 0.1, limiter: limiter)
      }
    }
    #expect(first == .timedOut)

    // The stalled start call will still make a reference, so the next lookup must wait.
    let next = Task {
      await fake.install {
        await ReverseDNSLookup.lookup("192.0.2.1", timeout: 0.1, limiter: limiter)
      }
    }
    try? await Task.sleep(nanoseconds: 200_000_000)
    let waitedForPermit = fake.starts.count == 1
    #expect(waitedForPermit)

    gate.open()
    let (second, _) = try await measure(within: Self.watchdog) { await next.value }
    #expect(second == .timedOut)
    try await Self.expectTornDown(fake, references: 2)
  }

  // MARK: - Helpers

  /// Starts a lookup of `address` through `fake`, waits until its query is scheduled, runs
  /// `respond`, and returns the outcome.
  static func run(
    _ fake: FakeDNSService, _ address: String, respond: @escaping @Sendable () -> Void
  ) async throws -> ReverseDNSLookupOutcome {
    let task = Task {
      await fake.install { await ReverseDNSLookup.lookup(address, timeout: longTimeout) }
    }
    try await waitScheduled(fake, 1)
    respond()
    return try await measure(within: watchdog) { await task.value }.0
  }

  static func waitScheduled(_ fake: FakeDNSService, _ count: Int) async throws {
    try await waitBounded("\(count) scheduled queries", within: watchdog) {
      _ = await eventually(within: 60) { fake.scheduledCount >= count }
    }
  }

  /// Waits until every reference is gone, then checks there were `references` of them, each
  /// deallocated exactly once on the queue it was started on, and every start ran on a lookup
  /// queue.
  static func expectTornDown(_ fake: FakeDNSService, references: Int) async throws {
    try await waitBounded("every reference deallocated", within: watchdog) {
      _ = await eventually(within: 60) {
        fake.liveCount == 0 && fake.deallocs.count >= references
      }
    }
    #expect(fake.startedCount == references)
    #expect(fake.deallocs.count == references)
    #expect(fake.deallocatedOnOwnQueue.count == references)
    let deallocatedOnQueue = fake.deallocatedOnOwnQueue.allSatisfy { $0 }
    #expect(deallocatedOnQueue)
    let startedOnQueue = fake.starts.allSatisfy { $0.onLookupQueue }
    #expect(startedOnQueue)
    let misuse = fake.misuse
    #expect(misuse.unknown == 0)
    #expect(misuse.double == 0)
  }
}
