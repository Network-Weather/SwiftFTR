import Foundation
import Testing

@testable import SwiftFTR

/// Reverse DNS degradation when the system resolver stops answering.
///
/// A stall is a lookup whose question was asked and got no answer by its deadline
/// (`ReverseDNSLookupOutcome.timedOut`). These tests use an injected resolver that reports
/// outcomes directly, so the behavior is exercised without waiting and without live DNS.
@Suite(.serialized)
struct RDNSSuppressionTests {

  /// Counts calls and reports a fixed outcome, standing in for the daemon.
  private final class CountingResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    let outcome: ReverseDNSLookupOutcome

    init(_ outcome: ReverseDNSLookupOutcome) {
      self.outcome = outcome
    }

    var calls: Int {
      lock.lock()
      defer { lock.unlock() }
      return _calls
    }

    func resolve() -> ReverseDNSLookupOutcome {
      lock.lock()
      _calls += 1
      lock.unlock()
      return outcome
    }
  }

  @Test("Repeated stalls suppress further lookups instead of re-paying the deadline")
  func stallsSuppressFurtherLookups() async {
    let probe = CountingResolver(.timedOut)
    let cache = RDNSCache(resolver: { _, _ in probe.resolve() })

    _ = await cache.lookup("192.0.2.1")
    _ = await cache.lookup("192.0.2.2")
    #expect(await cache.isSuppressingLookups, "two stalled lookups should open the breaker")

    let callsBefore = probe.calls
    let hostname = await cache.lookup("192.0.2.3")

    #expect(hostname == nil)
    #expect(probe.calls == callsBefore, "a suppressed lookup must not reach the resolver")
  }

  @Test("A fast resolver never trips the breaker")
  func fastLookupsDoNotSuppress() async {
    let probe = CountingResolver(.answer("host.example"))
    let cache = RDNSCache(resolver: { _, _ in probe.resolve() })

    for octet in 1...5 {
      #expect(await cache.lookup("192.0.2.\(octet)") == "host.example")
    }
    #expect(await cache.isSuppressingLookups == false)
    #expect(probe.calls == 5)
  }

  @Test("One stall followed by an answer resets the count", arguments: [true, false])
  func recoveryResetsTheStallCount(answered: Bool) async {
    let slow = CountingResolver(.timedOut)
    let fast = CountingResolver(answered ? .answer("host.example") : .noSuchRecord)
    let useFast = Mutex(false)

    let cache = RDNSCache { _, _ in
      useFast.value ? fast.resolve() : slow.resolve()
    }

    _ = await cache.lookup("192.0.2.1")
    useFast.value = true
    _ = await cache.lookup("192.0.2.2")

    #expect(await cache.isSuppressingLookups == false)

    // A single later stall must not open the breaker on its own now that the count reset.
    useFast.value = false
    _ = await cache.lookup("192.0.2.3")
    #expect(await cache.isSuppressingLookups == false)
  }

  @Test("clear() reopens the breaker so a fixed network is retried")
  func clearResetsSuppression() async {
    let probe = CountingResolver(.timedOut)
    let cache = RDNSCache(resolver: { _, _ in probe.resolve() })

    _ = await cache.lookup("192.0.2.1")
    _ = await cache.lookup("192.0.2.2")
    #expect(await cache.isSuppressingLookups)

    await cache.clear()
    #expect(await cache.isSuppressingLookups == false)

    let callsBefore = probe.calls
    _ = await cache.lookup("192.0.2.3")
    #expect(probe.calls == callsBefore + 1, "clear() should let lookups reach the resolver again")
  }

  @Test("A batch runs its lookups concurrently, not one after another")
  func batchLookupStaysBounded() async throws {
    // Every lookup waits until all forty are in flight at once, so a batch that ran them one
    // after another never releases the first, and trips the watchdog.
    let ips = (1...40).map { "192.0.2.\($0)" }
    let allInFlight = StallGate()
    defer { allInFlight.open() }
    let inFlight = FaultCounter()
    let cache = RDNSCache { _, _ in
      inFlight.increment()
      if inFlight.value >= ips.count { allInFlight.open() }
      await allInFlight.waitAsync(limit: 60)
      return .timedOut
    }

    let (results, _) = try await measure(within: 20) { await cache.batchLookup(ips) }

    #expect(results.isEmpty)
    #expect(inFlight.value == ips.count)
  }
}

/// Minimal mutable box for the recovery test's resolver switch.
private final class Mutex<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: T

  init(_ value: T) { self.storage = value }

  var value: T {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }
    set {
      lock.lock()
      storage = newValue
      lock.unlock()
    }
  }
}

/// Validation and plumbing of the caller-settable enrichment budgets.
@Suite("Enrichment timeout configuration")
struct EnrichmentTimeoutConfigTests {

  @Test("Callers can raise the budgets for slow-but-working networks")
  func callerSuppliedTimeoutsAreHonored() {
    let config = SwiftFTRConfig(rdnsLookupTimeout: 12.0, publicIPDiscoveryTimeout: 20.0)
    #expect(config.rdnsLookupTimeoutForConstruction == 12.0)
    #expect(config.publicIPDiscoveryTimeoutForOperation == 20.0)
  }

  @Test("Omitted budgets fall back to the documented defaults")
  func defaultsApplyWhenUnset() {
    let config = SwiftFTRConfig()
    #expect(config.rdnsLookupTimeoutForConstruction == SwiftFTRConfig.defaultRDNSLookupTimeout)
    #expect(
      config.publicIPDiscoveryTimeoutForOperation
        == SwiftFTRConfig.defaultPublicIPDiscoveryTimeout)
  }

  @Test("Nonsensical budgets fall back rather than disabling enrichment")
  func invalidTimeoutsFallBack() {
    for bad in [0.0, -1.0, TimeInterval.nan, TimeInterval.infinity] {
      let config = SwiftFTRConfig(rdnsLookupTimeout: bad, publicIPDiscoveryTimeout: bad)
      #expect(config.rdnsLookupTimeoutForConstruction == SwiftFTRConfig.defaultRDNSLookupTimeout)
      #expect(
        config.publicIPDiscoveryTimeoutForOperation
          == SwiftFTRConfig.defaultPublicIPDiscoveryTimeout)
    }
  }
}
