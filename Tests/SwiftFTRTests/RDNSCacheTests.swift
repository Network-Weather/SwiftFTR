import Foundation
import Testing

@testable import SwiftFTR

/// `RDNSCache` on ``ReverseDNSLookup``: what it caches, what counts toward its stall breaker, the
/// cap on link-local lookups, the cap on lookups in flight, and independence from the blocking-I/O
/// executor.
@Suite
struct RDNSCacheTests {
  static let watchdog: TimeInterval = 60

  /// Records each address asked and the timeout it was given, and reports `outcome` for it.
  private final class RecordingResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [(address: String, timeout: TimeInterval)] = []
    private let outcome: @Sendable (String) -> ReverseDNSLookupOutcome

    init(_ outcome: @escaping @Sendable (String) -> ReverseDNSLookupOutcome) {
      self.outcome = outcome
    }

    var calls: [(address: String, timeout: TimeInterval)] {
      lock.lock()
      defer { lock.unlock() }
      return asked
    }

    func resolve(_ address: String, _ timeout: TimeInterval) -> ReverseDNSLookupOutcome {
      lock.lock()
      asked.append((address, timeout))
      lock.unlock()
      return outcome(address)
    }
  }

  static let uncachedOutcomes: [ReverseDNSLookupOutcome] = [
    .noSuchRecord, .timedOut, .timedOutBeforeQuery, .cancelled,
    .error(.invalidAddress), .error(.daemon(DNSServiceStatus.serviceNotRunning)),
    .error(.malformedRecord),
  ]

  @Test("Only an answer is cached; every other outcome is asked again", arguments: uncachedOutcomes)
  func onlyAnswersAreCached(outcome: ReverseDNSLookupOutcome) async {
    let resolver = RecordingResolver { _ in outcome }
    let cache = RDNSCache { address, timeout in resolver.resolve(address, timeout) }

    #expect(await cache.lookup("192.0.2.1") == nil)
    #expect(await cache.lookup("192.0.2.1") == nil)
    #expect(await cache.count == 0, "\(outcome) was cached")
    #expect(resolver.calls.count == 2, "a second lookup after \(outcome) was answered from cache")
  }

  @Test("An answer is cached and served without asking again")
  func answerIsCached() async {
    let resolver = RecordingResolver { _ in .answer("router.example") }
    let cache = RDNSCache { address, timeout in resolver.resolve(address, timeout) }

    #expect(await cache.lookup("192.0.2.1") == "router.example")
    #expect(await cache.lookup("192.0.2.1") == "router.example")
    #expect(await cache.count == 1)
    #expect(resolver.calls.count == 1)
  }

  /// Two of an outcome in a row, and whether they open the breaker.
  static let breakerTable: [(String, ReverseDNSLookupOutcome, Bool)] = [
    // Asked and unanswered: the resolver is stalled.
    ("192.0.2.1", .timedOut, true),
    // Never asked (no permit in time, or no time left to start): no evidence (David, 2026-11-24).
    ("192.0.2.1", .timedOutBeforeQuery, false),
    // Asked by multicast on the link, where silence means no responder, not a stalled resolver.
    ("fe80::1%lo0", .timedOut, false),
    ("169.254.1.1", .timedOut, false),
    ("::ffff:169.254.1.1", .timedOut, false),
    // Failed without waiting on the resolver.
    ("192.0.2.1", .error(.daemon(DNSServiceStatus.serviceNotRunning)), false),
    ("192.0.2.1", .noSuchRecord, false),
    ("192.0.2.1", .answer("router.example"), false),
  ]

  @Test("Only an asked, unanswered unicast question counts as a stall", arguments: breakerTable)
  func whatCountsAsAStall(address: String, outcome: ReverseDNSLookupOutcome, opens: Bool) async {
    let cache = RDNSCache { _, _ in outcome }
    for _ in 0..<RDNSCache.stallsBeforeSuppressing {
      _ = await cache.lookup(address)
    }
    let suppressing = await cache.isSuppressingLookups
    #expect(suppressing == opens, "\(address): \(outcome)")
  }

  @Test("Outcomes that are no evidence neither count nor reset the stall count")
  func neutralOutcomesKeepTheCount() async {
    // stall, then each neutral outcome, then one more stall: the breaker opens only if none of
    // the neutral outcomes reset the count.
    let neutral: [(String, ReverseDNSLookupOutcome)] = [
      ("192.0.2.2", .timedOutBeforeQuery),
      ("192.0.2.3", .error(.daemon(DNSServiceStatus.serviceNotRunning))),
      ("fe80::1%lo0", .answer("peer.local")),
      ("fe80::2%lo0", .timedOut),
    ]
    let outcomes: [String: ReverseDNSLookupOutcome] = Dictionary(
      uniqueKeysWithValues: neutral + [("192.0.2.1", .timedOut), ("192.0.2.9", .timedOut)])
    let cache = RDNSCache { address, _ in outcomes[address] ?? .noSuchRecord }

    _ = await cache.lookup("192.0.2.1")
    for (address, _) in neutral {
      _ = await cache.lookup(address)
    }
    let suppressedEarly = await cache.isSuppressingLookups
    #expect(!suppressedEarly, "a neutral outcome counted as a stall")
    _ = await cache.lookup("192.0.2.9")
    let suppressed = await cache.isSuppressingLookups
    #expect(suppressed, "a neutral outcome reset the stall count")
  }

  @Test("A link-local lookup gets the shorter link-local cap; every other lookup the full deadline")
  func linkLocalCap() async {
    let resolver = RecordingResolver { _ in .noSuchRecord }
    let cache = RDNSCache(lookupDeadline: 7) { address, timeout in
      resolver.resolve(address, timeout)
    }
    let linkLocal = ["fe80::1%lo0", "fe80::1", "169.254.1.1", "::ffff:169.254.1.1"]
    let unicast = ["192.0.2.1", "2001:db8::1", "10.0.0.1", "fc00::1", "127.0.0.1"]
    for address in linkLocal + unicast {
      _ = await cache.lookup(address)
    }
    let timeouts = Dictionary(uniqueKeysWithValues: resolver.calls.map { ($0.address, $0.timeout) })
    for address in linkLocal {
      #expect(timeouts[address] == RDNSCache.linkLocalLookupDeadline, "\(address)")
    }
    for address in unicast {
      #expect(timeouts[address] == 7, "\(address)")
    }
    #expect(RDNSCache.linkLocalLookupDeadline < SwiftFTRConfig.defaultRDNSLookupTimeout)

    // A deadline shorter than the link-local cap applies to link-local lookups too.
    let short = RecordingResolver { _ in .noSuchRecord }
    let shortCache = RDNSCache(lookupDeadline: 0.25) { address, timeout in
      short.resolve(address, timeout)
    }
    _ = await shortCache.lookup("fe80::1%lo0")
    #expect(short.calls.first?.timeout == 0.25)
  }

  @Test("The cache's lookups wait for its limiter: no more queries in flight than the cap")
  func concurrencyCap() async throws {
    let cap = 4
    let limiter = _ConcurrencySemaphore(maxConcurrent: cap)
    let daemon = FakeDNSService()
    let cache = RDNSCache(lookupDeadline: 120, limiter: limiter)
    let ips = (1...40).map { "192.0.2.\($0)" }

    try await daemon.install {
      let batch = Task { await cache.batchLookup(ips) }
      // Every lookup has armed its deadline, `cap` have asked, and the rest wait for a permit.
      let settled = await eventually(within: Self.watchdog) {
        let waiting = await limiter.waitingCount
        return daemon.deadlinesArmed == ips.count && waiting == ips.count - cap
          && daemon.startedCount >= cap
      }
      #expect(settled, "the batch never reached the limiter")
      #expect(daemon.startedCount == cap, "\(daemon.startedCount) queries asked, cap \(cap)")
      // Every deadline passes before any lookup is woken, so a permit freed by one woken lookup
      // cannot reach a waiter whose deadline has not passed yet.
      for number in 0..<ips.count { daemon.passDeadline(number: number) }
      daemon.expireDeadlines()
      let (results, _) = try await measure(within: Self.watchdog) { await batch.value }
      #expect(results.isEmpty)
    }
    #expect(daemon.maxConcurrent <= cap)
    #expect(daemon.startedCount == cap, "a lookup asked after its deadline passed")
    #expect(await eventually(within: Self.watchdog) { daemon.liveCount == 0 })
    // `cap` stalls were asked; the other lookups timed out before asking, and are no evidence.
    #expect(await cache.isSuppressingLookups)
  }

  @Test("With every blocking-I/O worker held, a lookup through the cache still answers")
  func answersWithEveryWorkerHeld() async throws {
    let held = await HeldExecutor.fill()
    defer { held.release() }
    // The daemon answers loopback from its local records without sending a query. A limiter of
    // its own, so lookups in other tests cannot hold its permit.
    let cache = RDNSCache(lookupDeadline: 120, limiter: _ConcurrencySemaphore(maxConcurrent: 1))
    let (hostname, _) = try await measure(within: Self.watchdog) {
      await TestSeams.$blockingIOExecutor.withValue(held.executor) {
        await cache.lookup("127.0.0.1")
      }
    }
    // Answered while every worker was still held, so the lookup needed none.
    #expect(held.finished.value == 0)
    #expect(hostname == "localhost")
  }

  @Test("A discoverPaths flow cancelled in its reverse-DNS wave returns while the wave stalls")
  func multipathFlowLeavesStalledWave() async throws {
    let gate = StallGate()
    defer { gate.open() }
    let entered = FaultCounter()
    // Ignores cancellation, so only the flow's own race can release it. Its hold outlasts the
    // watchdog, and the gate opens only when the test ends, so a run that returns within the
    // watchdog returned while the wave was still stalled.
    let rdns = stallingRDNSCache(gate: gate, limit: 2 * Self.watchdog, entered: entered)
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 4), rdns: rdns, publicIP: "198.51.100.7")
    let config = MultipathConfig(
      flowVariations: 1, maxPaths: 4, earlyStopThreshold: 1, timeoutMs: 2000, maxHops: 4)

    try await network.install {
      let task = Task { try await tracer.discoverPaths(to: "fake.test", config: config) }
      #expect(await eventually(within: Self.watchdog) { entered.value > 0 })
      let (outcome, _) = try await measure(within: Self.watchdog) {
        task.cancel()
        return await task.result
      }
      var cancelled = false
      if case .failure(let error) = outcome { cancelled = error is CancellationError }
      #expect(cancelled, "\(outcome)")
    }
  }
}
