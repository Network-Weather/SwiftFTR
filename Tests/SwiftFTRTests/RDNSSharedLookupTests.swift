import Foundation
import Testing

@testable import SwiftFTR

/// Lookups of one address share one query (David, 2026-11-24: "Build share lookups").
///
/// Every gate here holds for twice the watchdog and opens only when the test says, so a lookup
/// that returns within the watchdog returned while its query was still held.
@Suite
struct RDNSSharedLookupTests {
  static let watchdog: TimeInterval = 60

  /// A resolver whose `n`th ask (from 1) waits for gate `n`, records whether its task was
  /// cancelled, and reports `outcome(n, cancelled)`. Cancellation opens that ask's gate.
  final class GatedResolver: @unchecked Sendable {
    let calls = FaultCounter()
    let cancellations = FaultCounter()
    let ended = FaultCounter()
    private let gates = (1...4).map { _ in StallGate() }
    private let outcome: @Sendable (_ call: Int, _ cancelled: Bool) -> ReverseDNSLookupOutcome

    init(_ outcome: @escaping @Sendable (_ call: Int, _ cancelled: Bool) -> ReverseDNSLookupOutcome)
    {
      self.outcome = outcome
    }

    func open(_ call: Int) { gates[call - 1].open() }
    func openAll() { for gate in gates { gate.open() } }

    func resolve() async -> ReverseDNSLookupOutcome {
      calls.increment()
      let call = calls.value
      let gate = gates[min(call, gates.count) - 1]
      let cancelled = FaultCounter()
      await withTaskCancellationHandler {
        await gate.waitAsync(limit: 2 * RDNSSharedLookupTests.watchdog)
      } onCancel: {
        cancelled.increment()
        self.cancellations.increment()
        gate.open()
      }
      ended.increment()
      return outcome(call, cancelled.value > 0)
    }
  }

  static func lookups(_ cache: RDNSCache, _ ip: String, count: Int) -> [Task<String?, Never>] {
    (0..<count).map { _ in Task { await cache.lookup(ip) } }
  }

  @Test(
    "Concurrent lookups of one address make one query, and every one gets its outcome",
    arguments: [true, false])
  func concurrentLookupsShareOneQuery(answered: Bool) async throws {
    let resolver = GatedResolver { _, _ in answered ? .answer("router.example") : .timedOut }
    defer { resolver.openAll() }
    let cache = RDNSCache { _, _ in await resolver.resolve() }
    let ip = "192.0.2.1"

    let tasks = Self.lookups(cache, ip, count: 5)
    let joined = await eventually(within: Self.watchdog) {
      await cache.waiterCount(for: ip) == 5
    }
    #expect(joined, "the five lookups did not all wait on one query")
    #expect(resolver.calls.value == 1)
    resolver.open(1)
    for task in tasks {
      let hostname = try await measure(within: Self.watchdog) { await task.value }.0
      #expect(hostname == (answered ? "router.example" : nil))
    }
    #expect(resolver.calls.value == 1, "\(resolver.calls.value) queries for one address")
    // The one outcome was applied once.
    #expect(await cache.stallCount == (answered ? 0 : 1))
    #expect(await cache.holdoffCount == (answered ? 0 : 1))
    #expect(await cache.count == (answered ? 1 : 0))
    #expect(await cache.inFlightCount == 0)
    #expect(await cache.waiterCount(for: ip) == 0)
  }

  @Test("A cancelled joiner leaves at once; the query and the other joiners carry on")
  func cancelledJoinerLeavesOthersAlone() async throws {
    let resolver = GatedResolver { _, cancelled in
      cancelled ? .cancelled : .answer("router.example")
    }
    defer { resolver.openAll() }
    let cache = RDNSCache { _, _ in await resolver.resolve() }
    let ip = "192.0.2.1"

    let tasks = Self.lookups(cache, ip, count: 3)
    #expect(await eventually(within: Self.watchdog) { await cache.waiterCount(for: ip) == 3 })
    let leaving = tasks[0]
    let left = try await measure(within: Self.watchdog) {
      leaving.cancel()
      return await leaving.value
    }.0
    #expect(left == nil)
    #expect(await cache.waiterCount(for: ip) == 2, "the cancelled joiner's registration stayed")
    #expect(resolver.cancellations.value == 0, "one joiner leaving cancelled the shared query")

    resolver.open(1)
    for task in tasks.dropFirst() {
      let hostname = try await measure(within: Self.watchdog) { await task.value }.0
      #expect(hostname == "router.example")
    }
    #expect(resolver.calls.value == 1)
    #expect(await cache.waiterCount(for: ip) == 0)
  }

  @Test("When the last waiter leaves, the query is cancelled and its outcome recorded nowhere")
  func lastWaiterLeavingCancelsQuery() async throws {
    // The worst a resolver can do: report its cancelled wait as a timeout.
    let resolver = GatedResolver { call, _ in call == 1 ? .timedOut : .answer("router.example") }
    defer { resolver.openAll() }
    let cache = RDNSCache { _, _ in await resolver.resolve() }
    let ip = "192.0.2.1"

    let tasks = Self.lookups(cache, ip, count: 2)
    #expect(await eventually(within: Self.watchdog) { await cache.waiterCount(for: ip) == 2 })
    for task in tasks {
      let hostname = try await measure(within: Self.watchdog) {
        task.cancel()
        return await task.value
      }.0
      #expect(hostname == nil)
    }
    #expect(
      await eventually(within: Self.watchdog) { resolver.cancellations.value == 1 },
      "the abandoned query was not cancelled")
    #expect(await eventually(within: Self.watchdog) { await cache.inFlightCount == 0 })
    #expect(await cache.holdoffCount == 0, "an abandoned query held the address off")
    #expect(await cache.stallCount == 0, "an abandoned query counted a stall")
    #expect(await cache.count == 0)

    // The next lookup asks again, in a query of its own.
    resolver.open(2)
    let next = try await measure(within: Self.watchdog) { await cache.lookup(ip) }.0
    #expect(next == "router.example")
    #expect(resolver.calls.value == 2)
  }

  enum Reset: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case clear, invalidateNetworkScoped
    var testDescription: String { rawValue }
  }

  @Test(
    "A reset mid-flight: a later lookup starts a fresh query, and the old one records nothing",
    arguments: Reset.allCases, [true, false])
  func resetMidFlight(reset: Reset, oldEndsFirst: Bool) async throws {
    // The old query times out; the fresh one, after the reset, answers. Only the old query's
    // timeout could hold the address off or count a stall.
    let resolver = GatedResolver { call, _ in call == 1 ? .timedOut : .answer("router.example") }
    defer { resolver.openAll() }
    let cache = RDNSCache { _, _ in await resolver.resolve() }
    let ip = "192.168.1.1"

    let old = Task { await cache.lookup(ip) }
    #expect(await eventually(within: Self.watchdog) { resolver.calls.value == 1 })
    switch reset {
    case .clear: await cache.clear()
    case .invalidateNetworkScoped: await cache.invalidateNetworkScoped()
    }
    let fresh = Task { await cache.lookup(ip) }
    #expect(
      await eventually(within: Self.watchdog) { resolver.calls.value == 2 },
      "the lookup after the reset joined the query from before it")

    let first = oldEndsFirst ? 1 : 2
    resolver.open(first)
    _ = try await measure(within: Self.watchdog) { await (oldEndsFirst ? old : fresh).value }
    resolver.open(3 - first)
    let oldHostname = try await measure(within: Self.watchdog) { await old.value }.0
    let freshHostname = try await measure(within: Self.watchdog) { await fresh.value }.0

    #expect(oldHostname == nil)
    #expect(freshHostname == "router.example")
    #expect(await cache.holdoffCount == 0, "the old query's timeout held the address off")
    #expect(await cache.stallCount == 0, "the old query's timeout counted a stall")
    #expect(await cache.inFlightCount == 0)
  }

  @Test("A shared query takes one permit from the limiter, however many lookups wait on it")
  func onePermitPerQuery() async throws {
    let limiter = _ConcurrencySemaphore(maxConcurrent: 1)
    let daemon = FakeDNSService()
    let cache = RDNSCache(lookupDeadline: 120, limiter: limiter)
    let ip = "192.0.2.1"

    try await daemon.install {
      let tasks = Self.lookups(cache, ip, count: 5)
      let settled = await eventually(within: Self.watchdog) {
        let waiting = await cache.waiterCount(for: ip)
        return waiting == 5 && daemon.scheduledCount == 1
      }
      #expect(settled, "the lookups did not settle on one query")
      #expect(await limiter.waitingCount == 0, "a joiner waited for a permit of its own")
      #expect(daemon.startedCount == 1)
      #expect(daemon.deliver(to: 0, rdata: PTRData.name("router.example")))
      for task in tasks {
        let hostname = try await measure(within: Self.watchdog) { await task.value }.0
        #expect(hostname == "router.example")
      }
    }
    #expect(daemon.startedCount == 1)
    #expect(await eventually(within: Self.watchdog) { daemon.liveCount == 0 })
  }

  @Test(
    "The review's case cannot arise: a lookup of an address waiting on its query gets that query's one outcome",
    arguments: [true, false])
  func overlappingLookupsGetOneOutcome(answered: Bool) async throws {
    // A cache of one entry. A's query is held; a second lookup of A arrives; B is looked up and
    // answered, filling the cache; then A's query ends. With one query for A, there is no
    // separate answer for A that a timeout could contradict.
    let resolverA = GatedResolver { _, _ in answered ? .answer("a.example") : .timedOut }
    defer { resolverA.openAll() }
    let cache = RDNSCache(maxSize: 1) { address, _ in
      address == "192.0.2.1" ? await resolverA.resolve() : .answer("b.example")
    }

    let first = Task { await cache.lookup("192.0.2.1") }
    #expect(await eventually(within: Self.watchdog) { resolverA.calls.value == 1 })
    let second = Task { await cache.lookup("192.0.2.1") }
    #expect(
      await eventually(within: Self.watchdog) { await cache.waiterCount(for: "192.0.2.1") == 2 })
    #expect(await cache.lookup("192.0.2.2") == "b.example")
    resolverA.open(1)
    let expected = answered ? "a.example" : nil
    let firstHostname = try await measure(within: Self.watchdog) { await first.value }.0
    let secondHostname = try await measure(within: Self.watchdog) { await second.value }.0
    #expect(firstHostname == expected)
    #expect(secondHostname == expected)

    #expect(resolverA.calls.value == 1)
    #expect(await cache.holdoffCount == (answered ? 0 : 1))
    #expect(await cache.stallCount == (answered ? 0 : 1))
  }
}
