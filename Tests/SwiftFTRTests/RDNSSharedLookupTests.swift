import Foundation
import Testing

@testable import SwiftFTR

/// Lookups of one address share one query (David, 2026-11-24: "Build share lookups").
///
/// Every gate here holds for twice the watchdog and opens only when the test says, so a lookup
/// that returns within the watchdog returned because its query was let go.
@Suite
struct RDNSSharedLookupTests {
  static let watchdog: TimeInterval = 60

  /// A resolver whose `n`th ask (from 1) waits for gate `n`, then reports `outcome(n)`. Call
  /// numbers are taken under one lock, so two asks never share one.
  final class GatedResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var issued = 0
    private var asked: [String] = []
    let cancellations = FaultCounter()
    private let gates = (1...4).map { _ in StallGate() }
    private let outcome: @Sendable (_ call: Int) -> ReverseDNSLookupOutcome

    init(_ outcome: @escaping @Sendable (_ call: Int) -> ReverseDNSLookupOutcome) {
      self.outcome = outcome
    }

    var calls: Int { locked { issued } }
    func calls(for address: String) -> Int { locked { asked.filter { $0 == address }.count } }
    func open(_ call: Int) { gates[call - 1].open() }
    func openAll() { for gate in gates { gate.open() } }

    func resolve(_ address: String) async -> ReverseDNSLookupOutcome {
      let call = locked {
        issued += 1
        asked.append(address)
        return issued
      }
      let gate = gates[min(call, gates.count) - 1]
      await withTaskCancellationHandler {
        await gate.waitAsync(limit: 2 * RDNSSharedLookupTests.watchdog)
      } onCancel: {
        self.cancellations.increment()
      }
      return outcome(call)
    }

    private func locked<T>(_ body: () -> T) -> T {
      lock.lock()
      defer { lock.unlock() }
      return body()
    }
  }

  static func lookups(_ cache: RDNSCache, _ ips: [String]) -> [Task<String?, Never>] {
    ips.map { ip in Task { await cache.lookup(ip) } }
  }

  static func awaiting(_ cache: RDNSCache, _ count: Int) async -> Bool {
    await eventually(within: watchdog) { await cache.awaiting == count }
  }

  @Test(
    "Concurrent lookups of one address make one query, and every one gets its outcome",
    arguments: [true, false])
  func concurrentLookupsShareOneQuery(answered: Bool) async throws {
    let resolver = GatedResolver { _ in answered ? .answer("router.example") : .timedOut }
    defer { resolver.openAll() }
    // A TTL of zero, so a late lookup could not be answered from the cache instead of joining.
    let cache = RDNSCache(ttl: 0) { address, _ in await resolver.resolve(address) }

    let tasks = Self.lookups(cache, Array(repeating: "192.0.2.1", count: 5))
    #expect(await Self.awaiting(cache, 5), "the five lookups never all waited")
    resolver.open(1)
    for task in tasks {
      let hostname = try await measure(within: Self.watchdog) { await task.value }.0
      #expect(hostname == (answered ? "router.example" : nil))
    }
    #expect(resolver.calls == 1, "\(resolver.calls) queries for one address")
    // The one outcome was applied once.
    #expect(await cache.stallCount == (answered ? 0 : 1))
    #expect(await cache.holdoffCount == (answered ? 0 : 1))
    #expect(await cache.count == (answered ? 1 : 0))
    #expect(await cache.inFlightCount == 0)
  }

  @Test("A cancelled joiner gets nil; the query is not cancelled and the others get its answer")
  func cancelledJoinerGetsNil() async throws {
    let resolver = GatedResolver { _ in .answer("router.example") }
    defer { resolver.openAll() }
    let cache = RDNSCache(ttl: 0) { address, _ in await resolver.resolve(address) }

    let tasks = Self.lookups(cache, Array(repeating: "192.0.2.1", count: 3))
    #expect(await Self.awaiting(cache, 3))
    tasks[0].cancel()
    resolver.open(1)
    let hostnames = try await measure(within: Self.watchdog) {
      await [tasks[0].value, tasks[1].value, tasks[2].value]
    }.0
    #expect(hostnames == [nil, "router.example", "router.example"])
    #expect(resolver.cancellations.value == 0, "a joiner's cancellation reached the query")
    #expect(resolver.calls == 1)
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
    let resolver = GatedResolver { call in call == 1 ? .timedOut : .answer("router.example") }
    defer { resolver.openAll() }
    let cache = RDNSCache { address, _ in await resolver.resolve(address) }
    let ip = "192.168.1.1"

    let old = Task { await cache.lookup(ip) }
    #expect(await eventually(within: Self.watchdog) { resolver.calls == 1 })
    switch reset {
    case .clear: await cache.clear()
    case .invalidateNetworkScoped: await cache.invalidateNetworkScoped()
    }
    let fresh = Task { await cache.lookup(ip) }
    #expect(
      await eventually(within: Self.watchdog) { resolver.calls == 2 },
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

  @Test(
    "An answer from before a reset reaches neither the lookup that asked nor the cache",
    arguments: Reset.allCases)
  func answerFromBeforeReset(reset: Reset) async throws {
    let resolver = GatedResolver { _ in .answer("router.old") }
    defer { resolver.openAll() }
    let cache = RDNSCache { address, _ in await resolver.resolve(address) }

    let old = Task { await cache.lookup("192.168.1.1") }
    #expect(await Self.awaiting(cache, 1))
    switch reset {
    case .clear: await cache.clear()
    case .invalidateNetworkScoped: await cache.invalidateNetworkScoped()
    }
    resolver.open(1)
    let hostname = try await measure(within: Self.watchdog) { await old.value }.0
    #expect(hostname == nil, "an answer from the old network reached its caller")
    #expect(await eventually(within: Self.watchdog) { await cache.inFlightCount == 0 })
    #expect(await cache.count == 0, "an answer from the old network was cached")
  }

  @Test("A shared query takes one permit from the limiter, however many lookups wait on it")
  func onePermitPerQuery() async throws {
    let limiter = _ConcurrencySemaphore(maxConcurrent: 1)
    let daemon = FakeDNSService()
    let cache = RDNSCache(lookupDeadline: 120, limiter: limiter)

    try await daemon.install {
      let tasks = Self.lookups(cache, Array(repeating: "192.0.2.1", count: 5))
      let settled = await eventually(within: Self.watchdog) {
        let awaiting = await cache.awaiting
        return awaiting == 5 && daemon.scheduledCount == 1
      }
      #expect(settled, "the lookups did not settle on one query")
      #expect(await limiter.waitingCount == 0, "a joiner waited for a permit of its own")
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
    let resolverA = GatedResolver { _ in answered ? .answer("a.example") : .timedOut }
    defer { resolverA.openAll() }
    let cache = RDNSCache(maxSize: 1) { address, _ in
      address == "192.0.2.1" ? await resolverA.resolve(address) : .answer("b.example")
    }

    let tasks = Self.lookups(cache, ["192.0.2.1", "192.0.2.1"])
    #expect(await Self.awaiting(cache, 2))
    let other = await cache.lookup("192.0.2.2")
    #expect(other == "b.example")
    resolverA.open(1)
    let expected = answered ? "a.example" : nil
    for task in tasks {
      let hostname = try await measure(within: Self.watchdog) { await task.value }.0
      #expect(hostname == expected)
    }
    #expect(resolverA.calls == 1)
    #expect(await cache.holdoffCount == (answered ? 0 : 1))
    #expect(await cache.stallCount == (answered ? 0 : 1))
  }

  @Test("A lookup joins a query in flight even after the breaker has opened")
  func joinsWhileBreakerOpen() async throws {
    let held = GatedResolver { _ in .answer("one.example") }
    defer { held.openAll() }
    let cache = RDNSCache(ttl: 0) { address, _ in
      address == "1.1.1.1" ? await held.resolve(address) : .timedOut
    }

    let first = Task { await cache.lookup("1.1.1.1") }
    #expect(await Self.awaiting(cache, 1))
    _ = await cache.lookup("192.0.2.1")
    _ = await cache.lookup("192.0.2.2")
    let open = await cache.isSuppressingLookups
    #expect(open, "two stalls did not open the breaker")
    let second = Task { await cache.lookup("1.1.1.1") }
    #expect(await Self.awaiting(cache, 2), "the lookup did not join the query in flight")
    held.open(1)
    let firstHostname = try await measure(within: Self.watchdog) { await first.value }.0
    let secondHostname = try await measure(within: Self.watchdog) { await second.value }.0
    #expect(firstHostname == "one.example")
    #expect(secondHostname == "one.example")
    #expect(held.calls == 1)
  }

  @Test("Every spelling of one PTR question is one address: one query, one holdoff, one stall")
  func spellingsOfOneAddress() async throws {
    let resolver = GatedResolver { call in call == 1 ? .timedOut : .answer("host.example") }
    defer { resolver.openAll() }
    let cache = RDNSCache(ttl: 3600) { address, _ in await resolver.resolve(address) }

    // An IPv4 address and its IPv4-mapped IPv6 spelling ask one question.
    resolver.open(1)
    _ = await cache.lookup("192.0.2.1")
    _ = await cache.lookup("::ffff:192.0.2.1")
    #expect(resolver.calls == 1, "the mapped spelling was asked again despite the holdoff")
    #expect(await cache.stallCount == 1)
    #expect(await cache.holdoffCount == 1)

    // Two spellings of one IPv6 address share one query and one cached answer.
    let tasks = Self.lookups(cache, ["2001:db8::1", "2001:0db8:0:0:0:0:0:1"])
    #expect(await Self.awaiting(cache, 2), "the two spellings did not share one query")
    resolver.open(2)
    for task in tasks {
      let hostname = try await measure(within: Self.watchdog) { await task.value }.0
      #expect(hostname == "host.example")
    }
    let cached = await cache.lookup("2001:db8:0::1")
    #expect(cached == "host.example")
    #expect(resolver.calls == 2)
  }

  @Test("A link-local address keeps its zone: the same interface is one address, no zone another")
  func linkLocalZoneIsPartOfTheAddress() async throws {
    let resolver = GatedResolver { _ in .answer("peer.local") }
    defer { resolver.openAll() }
    let cache = RDNSCache { address, _ in await resolver.resolve(address) }
    let index = if_nametoindex("lo0")
    #expect(index != 0)

    let tasks = Self.lookups(cache, ["fe80::1%lo0", "fe80::1%\(index)"])
    #expect(await Self.awaiting(cache, 2), "one interface named two ways was two addresses")
    resolver.open(1)
    for task in tasks {
      let hostname = try await measure(within: Self.watchdog) { await task.value }.0
      #expect(hostname == "peer.local")
    }
    resolver.open(2)
    _ = await cache.lookup("fe80::1")
    #expect(resolver.calls == 2, "an unscoped link-local address shared the zoned one's entry")
    #expect(resolver.calls(for: "fe80::1") == 1)
  }
}
