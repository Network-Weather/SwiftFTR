import Foundation
import Testing

@testable import SwiftFTR

/// The stalled-address holdoff and the once-per-streak stall count of `RDNSCache`.
///
/// The holdoff is David's decision (2026-11-24): an address whose question was asked and timed
/// out is not asked again for `RDNSCache.stalledAddressHoldoff`. That one address counts at most
/// once toward the stall breaker in a run of stalls is proposed by an agent, not yet confirmed
/// by David (2026-11-24).
@Suite
struct RDNSHoldoffTests {
  static let watchdog: TimeInterval = 60

  /// A monotonic clock the test moves by hand.
  final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private let base = ContinuousClock.now
    private var offset: Duration = .zero

    func now() -> ContinuousClock.Instant {
      lock.lock()
      defer { lock.unlock() }
      return base + offset
    }

    func advance(_ duration: Duration) {
      lock.lock()
      offset += duration
      lock.unlock()
    }
  }

  /// Counts the questions asked per address and reports `outcome(address)`.
  final class Daemon: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String: Int] = [:]
    private let outcome: @Sendable (String) -> ReverseDNSLookupOutcome

    init(_ outcome: @escaping @Sendable (String) -> ReverseDNSLookupOutcome) {
      self.outcome = outcome
    }

    func resolve(_ address: String) -> ReverseDNSLookupOutcome {
      lock.lock()
      asked[address, default: 0] += 1
      lock.unlock()
      return outcome(address)
    }

    func asks(_ address: String) -> Int {
      lock.lock()
      defer { lock.unlock() }
      return asked[address] ?? 0
    }
  }

  static func cache(
    _ daemon: Daemon, clock: TestClock = TestClock(), maxSize: Int = 1000
  ) -> RDNSCache {
    RDNSCache(
      maxSize: maxSize, resolver: { address, _ in daemon.resolve(address) },
      now: { clock.now() })
  }

  @Test(
    "A timed-out address is held off: asked once, then nil at once without asking or touching the breaker",
    arguments: ["192.0.2.1", "fe80::1%lo0"])
  func holdoffPreventsReask(address: String) async {
    let daemon = Daemon { _ in .timedOut }
    let cache = Self.cache(daemon)

    #expect(await cache.lookup(address) == nil)
    let stallsAfterAsking = await cache.stallCount
    #expect(await cache.lookup(address) == nil)
    #expect(await cache.lookup(address) == nil)

    #expect(daemon.asks(address) == 1, "a held-off address was asked again")
    let stalls = await cache.stallCount
    #expect(stalls == stallsAfterAsking, "a held-off lookup changed the stall count")
    #expect(await cache.count == 0, "a timeout became a cached answer")
    #expect(await cache.holdoffCount == 1)
  }

  @Test("A holdoff ends at ten minutes on the cache's clock, and the address is asked again")
  func holdoffExpires() async {
    #expect(RDNSCache.stalledAddressHoldoff == .seconds(600))
    let clock = TestClock()
    let daemon = Daemon { _ in .timedOut }
    let cache = Self.cache(daemon, clock: clock)

    _ = await cache.lookup("192.0.2.1")
    clock.advance(.seconds(600) - .milliseconds(1))
    _ = await cache.lookup("192.0.2.1")
    #expect(daemon.asks("192.0.2.1") == 1, "asked again before the holdoff ended")

    clock.advance(.milliseconds(1))
    _ = await cache.lookup("192.0.2.1")
    #expect(daemon.asks("192.0.2.1") == 2, "not asked again once the holdoff ended")
  }

  enum Reset: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case clear, invalidateNetworkScoped, networkChanged, invalidateNetworkScopedRDNS, clearCaches
    var testDescription: String { rawValue }
  }

  @Test(
    "Every reset drops holdoffs, for global and network-scoped addresses", arguments: Reset.allCases
  )
  func resetDropsHoldoffs(reset: Reset) async {
    let daemon = Daemon { _ in .timedOut }
    let cache = Self.cache(daemon)
    let tracer = SwiftFTR(
      config: SwiftFTRConfig(), rdnsCache: cache, asnResolver: EmptyASNResolver(),
      publicIPCache: [:])
    let addresses = ["198.51.100.1", "192.168.1.1"]
    for address in addresses { _ = await cache.lookup(address) }
    #expect(await cache.holdoffCount == 2)

    switch reset {
    case .clear: await cache.clear()
    case .invalidateNetworkScoped: await cache.invalidateNetworkScoped()
    case .networkChanged: await tracer.networkChanged()
    case .invalidateNetworkScopedRDNS: await tracer.invalidateNetworkScopedRDNS()
    case .clearCaches: await tracer.clearCaches()
    }
    #expect(await cache.holdoffCount == 0)
    for address in addresses {
      _ = await cache.lookup(address)
      #expect(daemon.asks(address) == 2, "\(address) still held off after \(reset)")
    }
  }

  static let neutralOutcomes: [ReverseDNSLookupOutcome] = [
    .noSuchRecord, .timedOutBeforeQuery, .cancelled,
    .error(.daemon(DNSServiceStatus.serviceNotRunning)), .error(.invalidAddress),
  ]

  @Test(
    "No holdoff for an outcome other than an asked, unanswered question", arguments: neutralOutcomes
  )
  func neutralOutcomesHoldNothingOff(outcome: ReverseDNSLookupOutcome) async {
    let daemon = Daemon { _ in outcome }
    let cache = Self.cache(daemon)
    _ = await cache.lookup("192.0.2.1")
    _ = await cache.lookup("192.0.2.1")
    #expect(daemon.asks("192.0.2.1") == 2, "\(outcome) held the address off")
    #expect(await cache.holdoffCount == 0)
  }

  @Test("A lookup whose caller cancelled holds nothing off, whatever it reports")
  func cancelledLookupHoldsNothingOff() async throws {
    let asked = FaultCounter()
    let cache = RDNSCache { _, _ in
      asked.increment()
      guard asked.value == 1 else { return .timedOut }
      // The first ask waits until its query is cancelled, then reports a timeout anyway.
      try? await Task.sleep(nanoseconds: 120_000_000_000)
      return .timedOut
    }
    let lookup = Task { await cache.lookup("192.0.2.1") }
    #expect(await eventually(within: Self.watchdog) { asked.value == 1 })
    _ = try await measure(within: Self.watchdog) {
      lookup.cancel()
      return await lookup.value
    }
    // The abandoned query has ended, and its timeout was handled, once it is no longer tracked.
    #expect(await eventually(within: Self.watchdog) { await cache.inFlightCount == 0 })
    #expect(await cache.holdoffCount == 0)
    #expect(await cache.stallCount == 0)
    _ = await cache.lookup("192.0.2.1")
    #expect(asked.value == 2, "a cancelled lookup held the address off")
  }

  @Test("A timeout from before a reset holds nothing off after it")
  func staleTimeoutHoldsNothingOff() async throws {
    let gate = StallGate()
    defer { gate.open() }
    let asked = FaultCounter()
    let cache = RDNSCache { _, _ in
      asked.increment()
      if asked.value == 1 { await gate.waitAsync(limit: 2 * Self.watchdog) }
      return .timedOut
    }
    let lookup = Task { await cache.lookup("198.51.100.1") }
    #expect(await eventually(within: Self.watchdog) { asked.value == 1 })
    await cache.clear()
    gate.open()
    _ = try await measure(within: Self.watchdog) { await lookup.value }
    #expect(await cache.holdoffCount == 0, "a timeout from before clear() held the address off")
    #expect(await cache.stallCount == 0)
  }

  @Test("The holdoff table is bounded by the cache size, oldest held off evicted first")
  func holdoffTableBounded() async {
    // Link-local addresses, which are held off but never count toward the breaker, so the
    // breaker cannot be what keeps an address from being asked.
    let addresses = ["fe80::1%lo0", "fe80::2%lo0", "fe80::3%lo0"]
    let clock = TestClock()
    let daemon = Daemon { _ in .timedOut }
    let cache = Self.cache(daemon, clock: clock, maxSize: 2)
    for address in addresses {
      _ = await cache.lookup(address)
      clock.advance(.seconds(1))
    }
    #expect(await cache.holdoffCount == 2)
    // The two newest are still held off; the oldest was evicted and is asked again.
    for address in addresses.reversed() {
      _ = await cache.lookup(address)
    }
    #expect(daemon.asks(addresses[2]) == 1)
    #expect(daemon.asks(addresses[1]) == 1)
    #expect(daemon.asks(addresses[0]) == 2, "the oldest holdoff was not evicted")
    #expect(await cache.holdoffCount == 2)
  }

  @Test("One address counts once per run of stalls when asked again after its holdoff ends")
  func oneAddressCountsOncePerStreak() async {
    // Concurrent lookups of one address share one query and so one outcome; what this rule still
    // covers is the same address asked again in the same run of stalls once its holdoff has
    // ended (or been evicted), with nothing answered in between.
    let clock = TestClock()
    let daemon = Daemon { _ in .timedOut }
    let cache = Self.cache(daemon, clock: clock)

    _ = await cache.lookup("192.0.2.1")
    clock.advance(RDNSCache.stalledAddressHoldoff)
    _ = await cache.lookup("192.0.2.1")
    #expect(daemon.asks("192.0.2.1") == 2)
    let stalls = await cache.stallCount
    #expect(stalls == 1, "one address counted \(stalls) stalls")
    let suppressing = await cache.isSuppressingLookups
    #expect(!suppressing, "one address opened the breaker by itself")

    // A second address that stalls is still the second stall.
    _ = await cache.lookup("192.0.2.2")
    let suppressingAfterSecond = await cache.isSuppressingLookups
    #expect(suppressingAfterSecond)
  }

  enum Path: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case stalledOnly, namedAndStalled, namedNoRecordAndStalled, stalledWithResets
    case wholeResolverStalled
    var testDescription: String { rawValue }

    static let named = "192.0.2.10"
    static let noRecord = "192.0.2.11"
    static let stalled = "192.0.2.12"
    static let sixHops = (1...6).map { "198.51.100.\($0)" }

    var hops: [String] {
      switch self {
      case .stalledOnly, .stalledWithResets: [Self.stalled]
      case .namedAndStalled: [Self.named, Self.stalled]
      case .namedNoRecordAndStalled: [Self.named, Self.noRecord, Self.stalled]
      case .wholeResolverStalled: Self.sixHops
      }
    }

    /// Traces, of ten, that wait out a lookup budget; and whether the breaker is open after.
    var expected: (budgetsPaid: Int, breakerOpen: Bool) {
      switch self {
      case .stalledOnly, .namedAndStalled, .namedNoRecordAndStalled: (1, false)
      // `invalidateNetworkScopedRDNS()` before traces 4, 7 and 10 drops the holdoff each time.
      case .stalledWithResets: (4, false)
      // Six distinct stalls in the first wave open the breaker; nothing is asked after.
      case .wholeResolverStalled: (1, true)
      }
    }
  }

  @Test(
    "Ten traces of one path: every path pays a bounded number of lookup budgets",
    arguments: Path.allCases)
  func tenTraces(path: Path) async {
    // Each trace's reverse-DNS wave is one batch over its hop addresses, as `performTrace` makes.
    // A named hop answers, an unnamed one answers "no such record", and a stalled one, or every
    // address when the whole resolver is stalled, times out. The clock does not move, so no
    // holdoff expires within the ten traces.
    let daemon = Daemon { address in
      switch address {
      case Path.named where path != .wholeResolverStalled: .answer("router.example")
      case Path.noRecord where path != .wholeResolverStalled: .noSuchRecord
      default: .timedOut
      }
    }
    let cache = Self.cache(daemon)
    let stalledAddresses = path == .wholeResolverStalled ? Path.sixHops : [Path.stalled]
    func timeouts() -> Int { stalledAddresses.map { daemon.asks($0) }.reduce(0, +) }

    var budgetsPaid = 0
    for trace in 1...10 {
      if path == .stalledWithResets, trace > 1, (trace - 1) % 3 == 0 {
        await cache.invalidateNetworkScoped()
      }
      let before = timeouts()
      _ = await cache.batchLookup(path.hops)
      if timeouts() > before { budgetsPaid += 1 }
    }
    #expect(
      budgetsPaid == path.expected.budgetsPaid, "\(path): \(budgetsPaid) budgets in 10 traces")
    let open = await cache.isSuppressingLookups
    #expect(open == path.expected.breakerOpen, "\(path): breaker open \(open)")
    if path.expected.breakerOpen {
      // The breaker still does its job: an address never seen is not asked.
      _ = await cache.lookup("203.0.113.1")
      #expect(daemon.asks("203.0.113.1") == 0)
    }
  }
}
