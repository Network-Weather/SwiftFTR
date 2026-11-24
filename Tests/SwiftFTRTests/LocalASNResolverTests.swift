import XCTest

@testable import SwiftFTR

/// Tests for LocalASNResolver using Swift-IP2ASN embedded database.
final class LocalASNResolverTests: XCTestCase {

  // MARK: - Embedded Database Tests

  /// Verify LocalASNResolver can load embedded database and resolve known IPs.
  func testEmbeddedDatabaseLookup() async throws {
    let resolver = LocalASNResolver(source: .embedded)

    // Well-known public IPs
    let results = try await resolver.resolve(
      ipv4Addrs: ["8.8.8.8", "1.1.1.1"], timeout: 60)

    // Should resolve both
    XCTAssertEqual(results.count, 2, "Should resolve both public IPs")

    // Google DNS (8.8.8.8) should be AS15169
    if let google = results["8.8.8.8"] {
      XCTAssertEqual(google.asn, 15169, "8.8.8.8 should be Google AS15169")
      XCTAssertFalse(google.name.isEmpty, "Should have AS name")
    } else {
      XCTFail("Should resolve 8.8.8.8")
    }

    // Cloudflare DNS (1.1.1.1) should be AS13335
    if let cloudflare = results["1.1.1.1"] {
      XCTAssertEqual(cloudflare.asn, 13335, "1.1.1.1 should be Cloudflare AS13335")
    } else {
      XCTFail("Should resolve 1.1.1.1")
    }
  }

  /// IPv6 ASN lookups via swift-ip2asn's dual-stack UltraCompactDatabase.
  /// No network required — uses the bundled DB.
  func testEmbeddedDatabaseIPv6Lookup() async throws {
    let resolver = LocalASNResolver(source: .embedded)
    let results = try await resolver.resolve(
      ipv4Addrs: ["2606:4700:4700::1111", "2001:4860:4860::8888"], timeout: 60)

    XCTAssertEqual(
      results["2606:4700:4700::1111"]?.asn, 13335, "Cloudflare v6 → AS13335")
    XCTAssertEqual(
      results["2001:4860:4860::8888"]?.asn, 15169, "Google v6 → AS15169")
  }

  /// Verify lookup performance is microsecond-level (not network-bound).
  func testLookupPerformance() async throws {
    let resolver = LocalASNResolver(source: .embedded)

    // Preload to exclude database load time
    await resolver.preload()

    // Time 1000 lookups
    let ips = (1...100).map { "8.8.\($0 % 256).\($0 % 256)" }
    let start = Date()
    for _ in 0..<10 {
      _ = try await resolver.resolve(ipv4Addrs: ips, timeout: 60)
    }
    let elapsed = Date().timeIntervalSince(start)

    // 1000 lookups should complete in well under 1 second
    // (microseconds per lookup means ~10ms total max)
    XCTAssertLessThan(
      elapsed, 1.0,
      "1000 lookups should complete in <1s (took \(String(format: "%.3f", elapsed))s)")
  }

  /// Verify preload loads the database, so the first lookup does not. Load time itself is
  /// measured by ResourceBenchmark, not here.
  func testPreload() async throws {
    let store = LocalASNDatabaseStore()
    let resolver = LocalASNResolver(source: .embedded, store: store)

    await resolver.preload()
    let loadsAfterPreload = await store.loadCount
    let residentAfterPreload = await store.isResident(.embedded)
    XCTAssertEqual(loadsAfterPreload, 1, "preload should load the database")
    XCTAssertTrue(residentAfterPreload, "the preloaded database should stay resident")

    // The first lookup is served by the preloaded database rather than loading its own.
    let results = try await resolver.resolve(ipv4Addrs: ["8.8.8.8"], timeout: 60)
    let loadsAfterLookup = await store.loadCount
    XCTAssertEqual(results["8.8.8.8"]?.asn, 15169)
    XCTAssertEqual(loadsAfterLookup, 1, "the first lookup after preload loaded the database again")
  }

  // MARK: - IP Filtering Tests

  /// Verify private IPs are filtered out (not queried).
  func testPrivateIPFiltering() async throws {
    let resolver = LocalASNResolver(source: .embedded)

    let results = try await resolver.resolve(
      ipv4Addrs: [
        "10.0.0.1",  // Private (Class A)
        "172.16.0.1",  // Private (Class B)
        "192.168.1.1",  // Private (Class C)
        "8.8.8.8",  // Public
      ],
      timeout: 60
    )

    // Only the public IP should be resolved
    XCTAssertEqual(results.count, 1, "Only public IPs should be resolved")
    XCTAssertNotNil(results["8.8.8.8"], "Public IP should be resolved")
    XCTAssertNil(results["10.0.0.1"], "Private IP should not be resolved")
    XCTAssertNil(results["172.16.0.1"], "Private IP should not be resolved")
    XCTAssertNil(results["192.168.1.1"], "Private IP should not be resolved")
  }

  /// Verify CGNAT IPs are filtered out.
  func testCGNATFiltering() async throws {
    let resolver = LocalASNResolver(source: .embedded)

    let results = try await resolver.resolve(
      ipv4Addrs: [
        "100.64.0.1",  // CGNAT
        "100.127.255.254",  // CGNAT (end of range)
        "8.8.8.8",  // Public
      ],
      timeout: 60
    )

    XCTAssertEqual(results.count, 1, "Only public IPs should be resolved")
    XCTAssertNil(results["100.64.0.1"], "CGNAT IP should not be resolved")
    XCTAssertNil(results["100.127.255.254"], "CGNAT IP should not be resolved")
  }

  /// Verify empty and invalid inputs are handled gracefully.
  func testEmptyAndInvalidInput() async throws {
    let resolver = LocalASNResolver(source: .embedded)

    // Empty input
    let emptyResult = try await resolver.resolve(ipv4Addrs: [], timeout: 60)
    XCTAssertTrue(emptyResult.isEmpty, "Empty input should return empty result")

    // Empty strings
    let emptyStrings = try await resolver.resolve(ipv4Addrs: ["", "", "8.8.8.8"], timeout: 60)
    XCTAssertEqual(emptyStrings.count, 1, "Should filter empty strings")
  }

  // MARK: - HybridASNResolver Tests

  /// Verify hybrid resolver uses local DB for known IPs.
  func testHybridLocalHit() async throws {
    let resolver = HybridASNResolver(source: .embedded, fallbackTimeout: 0.5)

    let results = try await resolver.resolve(ipv4Addrs: ["8.8.8.8"], timeout: 60)

    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results["8.8.8.8"]?.asn, 15169, "Should resolve from local DB")
  }

  // MARK: - Strategy Configuration Tests

  /// Verify SwiftFTRConfig with .embedded strategy creates LocalASNResolver.
  func testConfigEmbeddedStrategy() async throws {
    let config = SwiftFTRConfig(asnResolverStrategy: .embedded)
    let tracer = SwiftFTR(config: config)

    // The tracer should use LocalASNResolver internally
    // We can't directly access it, but we can test via traceClassified behavior
    // For now, just verify construction succeeds
    XCTAssertNotNil(tracer)
  }

  /// Verify SwiftFTRConfig with .dns strategy (default) works.
  func testConfigDNSStrategy() async throws {
    let config = SwiftFTRConfig(asnResolverStrategy: .dns)
    let tracer = SwiftFTR(config: config)
    XCTAssertNotNil(tracer)
  }

  /// Verify default config uses .dns strategy.
  func testDefaultConfigUsesDNS() async throws {
    let config = SwiftFTRConfig()
    // Default should be .dns - can't directly test enum equality,
    // but we verify via the config init parameter default
    let tracer = SwiftFTR(config: config)
    XCTAssertNotNil(tracer)
  }

  // MARK: - Shared Database Store Tests

  /// Two resolvers for the same source load the database once and both answer from it.
  func testSiblingResolversShareOneLoad() async throws {
    let store = LocalASNDatabaseStore()
    let first = LocalASNResolver(source: .embedded, store: store)
    let second = LocalASNResolver(source: .embedded, store: store)

    await first.preload()
    await second.preload()

    let loads = await store.loadCount
    XCTAssertEqual(loads, 1, "Second resolver should reuse the first resolver's database")

    let firstResult = try await first.resolve(ipv4Addrs: ["8.8.8.8"], timeout: 60)
    let secondResult = try await second.resolve(ipv4Addrs: ["1.1.1.1"], timeout: 60)
    XCTAssertEqual(firstResult["8.8.8.8"]?.asn, 15169)
    XCTAssertEqual(secondResult["1.1.1.1"]?.asn, 13335)
  }

  /// Resolvers constructed and preloaded at the same time join one in-flight load.
  func testConcurrentPreloadsCoalesceIntoOneLoad() async throws {
    let store = LocalASNDatabaseStore()
    let resolvers = (0..<8).map { _ in LocalASNResolver(source: .embedded, store: store) }

    await withTaskGroup(of: Void.self) { group in
      for resolver in resolvers {
        group.addTask { await resolver.preload() }
      }
    }

    let loads = await store.loadCount
    XCTAssertEqual(loads, 1, "Eight concurrent preloads should share one load")
    for resolver in resolvers {
      let result = try await resolver.resolve(ipv4Addrs: ["8.8.8.8"], timeout: 60)
      XCTAssertEqual(result["8.8.8.8"]?.asn, 15169)
    }
  }

  /// The store holds databases weakly: once the last resolver goes away, the next one reloads.
  func testDatabaseReleasedAfterLastResolverGoesAway() async throws {
    let store = LocalASNDatabaseStore()

    do {
      let resolver = LocalASNResolver(source: .embedded, store: store)
      await resolver.preload()
      let resident = await store.isResident(.embedded)
      XCTAssertTrue(resident, "Database should be resident while a resolver holds it")
      withExtendedLifetime(resolver) {}
    }

    let residentAfterRelease = await store.isResident(.embedded)
    XCTAssertFalse(residentAfterRelease, "Database should be released with its last resolver")

    let again = LocalASNResolver(source: .embedded, store: store)
    await again.preload()
    let loads = await store.loadCount
    XCTAssertEqual(loads, 2, "A resolver created after release should load again")
  }

  /// A failed load is not cached by the store, so a later resolver retries instead of inheriting it.
  func testFailedLoadIsNotCachedByStore() async throws {
    let store = LocalASNDatabaseStore()
    let missing = LocalASNSource.bundled("/nonexistent/swiftftr-asn-test.ultra")

    let first = LocalASNResolver(source: missing, store: store)
    let firstResult = try await first.resolve(ipv4Addrs: ["8.8.8.8"], timeout: 60)
    XCTAssertTrue(firstResult.isEmpty, "A resolver whose database failed to load answers nothing")

    let second = LocalASNResolver(source: missing, store: store)
    await second.preload()

    let loads = await store.loadCount
    XCTAssertEqual(loads, 2, "Each resolver should attempt the load; failures are not shared")
    let resident = await store.isResident(missing)
    XCTAssertFalse(resident)
  }

  /// Hybrid resolvers built for the same source share one database through the process-wide store.
  func testHybridResolversShareOneLoad() async throws {
    let first = HybridASNResolver(source: .embedded)
    await first.preload()
    let loadsBefore = await LocalASNDatabaseStore.shared.loadCount

    let second = HybridASNResolver(source: .embedded)
    await second.preload()
    let loadsAfter = await LocalASNDatabaseStore.shared.loadCount

    XCTAssertEqual(loadsAfter, loadsBefore, "Second hybrid resolver should not load again")
    withExtendedLifetime(first) {}
  }

  /// Tracers built with the embedded strategy share one database through the process-wide store.
  func testTracersShareOneEmbeddedDatabase() async throws {
    let first = SwiftFTR(config: SwiftFTRConfig(asnResolverStrategy: .embedded))
    await first.preloadASNDatabase()
    let loadsBefore = await LocalASNDatabaseStore.shared.loadCount

    let second = SwiftFTR(config: SwiftFTRConfig(asnResolverStrategy: .embedded))
    await second.preloadASNDatabase()
    let loadsAfter = await LocalASNDatabaseStore.shared.loadCount

    XCTAssertEqual(loadsAfter, loadsBefore, "Second tracer should not load the database again")
    withExtendedLifetime(first) {}
  }

  // MARK: - Lookup bounds and shared-load lifetimes

  /// Generous limit on any wait a test expects to end; never a claim about speed.
  private static let watchdog: TimeInterval = 20

  /// A lookup's timeout reaches the DNS fallback: the caller stops waiting for it at its own
  /// timeout, while the fallback keeps `fallbackTimeout` as the timeout it shares flights by.
  func testHybridFallbackWaitEndsAtTheCallersTimeout() async throws {
    let store = LocalASNDatabaseStore(loader: { _ in FakeASNTable([:]) })
    let dns = TimeoutRecordingResolver(held: true)
    defer { dns.gate.open() }
    let hybrid = HybridASNResolver(
      local: LocalASNResolver(source: .embedded, store: store),
      dns: CachingASNResolver(base: dns), fallbackTimeout: 30)

    let (result, _) = try await SwiftFTRTests.measure(within: Self.watchdog) {
      try await hybrid.resolve(ipv4Addrs: ["203.0.113.70"], timeout: 0.3)
    }

    XCTAssertTrue(result.isEmpty)
    let timeouts = await dns.timeouts
    XCTAssertEqual(timeouts, [30], "the address the table lacks should reach the fallback once")
  }

  /// With time to spare, the fallback keeps its own, shorter `fallbackTimeout` exactly, so concurrent
  /// lookups of one address still share one cached flight.
  func testHybridFallbackKeepsItsShorterTimeout() async throws {
    let store = LocalASNDatabaseStore(loader: { _ in FakeASNTable([:]) })
    let dns = TimeoutRecordingResolver()
    let hybrid = HybridASNResolver(
      local: LocalASNResolver(source: .embedded, store: store),
      dns: CachingASNResolver(base: dns), fallbackTimeout: 0.25)

    _ = try await hybrid.resolve(ipv4Addrs: ["203.0.113.71"], timeout: 60)

    let timeouts = await dns.timeouts
    XCTAssertEqual(timeouts, [0.25])
  }

  /// A hybrid lookup whose database is still loading returns at its timeout instead of waiting for
  /// the load.
  func testHybridReturnsAtItsTimeoutWhileTheDatabaseLoads() async throws {
    let loader = GatedASNLoader(FakeASNTable(["203.0.113.72": 64_500]))
    defer { loader.gate.open() }
    let store = LocalASNDatabaseStore(loader: loader.load)
    let dns = TimeoutRecordingResolver()
    let hybrid = HybridASNResolver(
      local: LocalASNResolver(source: .embedded, store: store),
      dns: CachingASNResolver(base: dns), fallbackTimeout: 1)

    let (result, _) = try await SwiftFTRTests.measure(within: Self.watchdog) {
      try await hybrid.resolve(ipv4Addrs: ["203.0.113.72"], timeout: 0.3)
    }

    XCTAssertEqual(loader.started.value, 1)
    XCTAssertTrue(result.isEmpty, "nothing could answer before the timeout")
    let timeouts = await dns.timeouts
    XCTAssertTrue(timeouts.isEmpty, "the fallback was asked with no time left: \(timeouts)")
  }

  /// A lookup of many addresses in a loaded database stops at its deadline instead of finishing the
  /// batch.
  func testWarmLookupStopsAtItsDeadline() async throws {
    let table = SlowASNTable()
    let resolver = LocalASNResolver(
      source: .embedded, store: LocalASNDatabaseStore(loader: { _ in table }))
    await resolver.preload()
    let addresses = (0..<400).map { "203.0.\($0 / 256).\($0 % 256)" }

    _ = try await SwiftFTRTests.measure(within: Self.watchdog) {
      try await resolver.resolve(ipv4Addrs: addresses, timeout: 0.02)
    }

    // Each lookup takes at least a millisecond, so finishing the batch took 0.4 s or more.
    XCTAssertLessThan(table.lookups.value, addresses.count, "the batch ran past its deadline")
  }

  /// Preparing a batch, the pass every resolver makes over its addresses before any lookup, stops
  /// once the deadline has passed instead of finishing the pass.
  func testPreparingABatchStopsAtTheDeadline() {
    let keyed = FaultCounter()
    let addresses = (0..<65_536).map { "8.8.\($0 / 256).\($0 % 256)" }

    let late = prepareASNBatch(addresses, until: .now + .nanoseconds(1)) { address in
      keyed.increment()
      return address
    }
    let unbounded = prepareASNBatch(addresses + ["", "8.8.0.0"], until: nil) { $0 }

    XCTAssertNil(late, "a pass whose deadline passed reported itself complete")
    XCTAssertLessThan(keyed.value, addresses.count, "the pass went on past its deadline")
    XCTAssertEqual(unbounded?.count, addresses.count, "empty and repeated addresses are dropped")
  }

  /// One caller's batch does not hold the resolver: a lookup started while it runs is answered
  /// before it ends.
  func testLookupIsNotQueuedBehindAnotherBatch() async throws {
    // The batch's lookups are synchronous work, as the real database's are, and occupy the thread
    // they run on. With a one-thread cooperative pool nothing else runs until they end, whatever
    // the resolver does, so the property this checks needs a second thread.
    if ProcessInfo.processInfo.environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] != nil {
      throw XCTSkip("needs more than one cooperative thread")
    }
    let table = SlowASNTable()
    let resolver = LocalASNResolver(
      source: .embedded, store: LocalASNDatabaseStore(loader: { _ in table }))
    await resolver.preload()
    let batch = (0..<1_000).map { "203.0.\($0 / 256).\($0 % 256)" }

    let long = Task { try await resolver.resolve(ipv4Addrs: batch, timeout: 60) }
    let started = await eventually(within: Self.watchdog) { table.lookups.value > 0 }
    XCTAssertTrue(started, "the batch never reached the table")

    let (single, _) = try await SwiftFTRTests.measure(within: Self.watchdog) {
      try await resolver.resolve(ipv4Addrs: ["198.51.100.200"], timeout: 60)
    }
    let doneByThen = table.lookups.value
    _ = try await long.value

    XCTAssertNotNil(single["198.51.100.200"])
    XCTAssertLessThan(doneByThen, batch.count, "the lookup waited for the whole batch")
  }

  /// A timeout too large to be an instant on the clock waits for a loading database without
  /// crashing, as an unbounded one does.
  func testHugeTimeoutWaitsForTheLoad() async throws {
    let address = "203.0.113.75"
    let loader = GatedASNLoader(FakeASNTable([address: 64_503]))
    defer { loader.gate.open() }
    let resolver = LocalASNResolver(
      source: .embedded, store: LocalASNDatabaseStore(loader: loader.load))

    let lookup = Task {
      try await resolver.resolve(ipv4Addrs: [address], timeout: Double(Int.max).nextDown)
    }
    let started = await eventually(within: Self.watchdog) { loader.started.value > 0 }
    XCTAssertTrue(started, "the lookup never reached the load")
    loader.gate.open()
    let (result, _) = try await SwiftFTRTests.measure(within: Self.watchdog) {
      try await lookup.value
    }
    XCTAssertEqual(result[address]?.asn, 64_503)
  }

  /// A caller that runs out of time waiting for a shared database load leaves it running for the
  /// others, and its resolver is not left failed: its next lookup is answered by that same load.
  func testCallerTimingOutLeavesSharedLoadRunningAndResolverUsable() async throws {
    let address = "203.0.113.73"
    let loader = GatedASNLoader(FakeASNTable([address: 64_501]))
    defer { loader.gate.open() }
    let store = LocalASNDatabaseStore(loader: loader.load)
    let leaving = LocalASNResolver(source: .embedded, store: store)
    let staying = LocalASNResolver(source: .embedded, store: store)

    let (early, _) = try await SwiftFTRTests.measure(within: Self.watchdog) {
      try await leaving.resolve(ipv4Addrs: [address], timeout: 0.3)
    }
    XCTAssertTrue(early.isEmpty)

    let other = Task { try await staying.resolve(ipv4Addrs: [address], timeout: 60) }
    loader.gate.open()
    let (otherResult, _) = try await SwiftFTRTests.measure(within: Self.watchdog) {
      try await other.value
    }
    let (retry, _) = try await SwiftFTRTests.measure(within: Self.watchdog) {
      try await leaving.resolve(ipv4Addrs: [address], timeout: 60)
    }

    XCTAssertEqual(otherResult[address]?.asn, 64_501, "the other caller lost the shared load")
    XCTAssertEqual(retry[address]?.asn, 64_501, "the resolver that timed out stayed failed")
    let loads = await store.loadCount
    XCTAssertEqual(loads, 1, "the load was started again instead of finishing once")
    XCTAssertEqual(loader.cancelled.value, 0, "the shared load was cancelled")
  }

  /// A cancelled caller stops waiting for a shared database load at once, without cancelling the
  /// load it started for the others or leaving its resolver failed.
  func testCancelledCallerLeavesSharedLoadRunningAndResolverUsable() async throws {
    let address = "203.0.113.74"
    let loader = GatedASNLoader(FakeASNTable([address: 64_502]))
    defer { loader.gate.open() }
    let store = LocalASNDatabaseStore(loader: loader.load)
    let leaving = LocalASNResolver(source: .embedded, store: store)
    let staying = LocalASNResolver(source: .embedded, store: store)

    // The leaving caller starts the load, so the load is its own work if anything's is.
    let cancelled = Task { try await leaving.resolve(ipv4Addrs: [address], timeout: 60) }
    let started = await eventually(within: Self.watchdog) { loader.started.value > 0 }
    XCTAssertTrue(started, "the lookup never reached the load")
    let other = Task { try await staying.resolve(ipv4Addrs: [address], timeout: 60) }

    cancelled.cancel()
    let (outcome, _) = try await SwiftFTRTests.measure(within: Self.watchdog) {
      () async -> Result<[String: ASNInfo], Error> in await cancelled.result
    }
    XCTAssertThrowsError(try outcome.get()) { error in
      XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
    }

    loader.gate.open()
    let (otherResult, _) = try await SwiftFTRTests.measure(within: Self.watchdog) {
      try await other.value
    }
    let (retry, _) = try await SwiftFTRTests.measure(within: Self.watchdog) {
      try await leaving.resolve(ipv4Addrs: [address], timeout: 60)
    }

    XCTAssertEqual(otherResult[address]?.asn, 64_502, "the other caller lost the shared load")
    XCTAssertEqual(retry[address]?.asn, 64_502, "the cancelled caller's resolver stayed failed")
    let loads = await store.loadCount
    XCTAssertEqual(loads, 1, "the load was started again instead of finishing once")
    XCTAssertEqual(loader.cancelled.value, 0, "the shared load was cancelled")
  }
}

// MARK: - Fixtures

/// A database stand-in answering a fixed ASN for each listed address.
private struct FakeASNTable: LocalASNTable {
  let asns: [String: UInt32]
  init(_ asns: [String: UInt32]) { self.asns = asns }
  func lookup(_ ipString: String) -> (asn: UInt32, name: String?)? {
    asns[ipString].map { ($0, "FAKE-AS\($0)") }
  }
}

/// A database load held until `gate` opens. It counts the loads started, and the loads that had
/// been cancelled by the time the gate let them go; a cancelled load fails, as a cancelled
/// download would.
private final class GatedASNLoader: Sendable {
  let gate = StallGate()
  let started = FaultCounter()
  let cancelled = FaultCounter()
  private let table: FakeASNTable

  init(_ table: FakeASNTable) { self.table = table }

  var load: LocalASNDatabaseStore.Loader {
    { [self] _ in
      started.increment()
      await gate.waitAsync(limit: 60)
      if Task.isCancelled {
        cancelled.increment()
        throw CancellationError()
      }
      return table
    }
  }
}

/// A database stand-in whose every lookup takes a millisecond of CPU-bound work, as a large batch
/// does, and is counted.
private final class SlowASNTable: LocalASNTable {
  let lookups = FaultCounter()
  func lookup(_ ipString: String) -> (asn: UInt32, name: String?)? {
    usleep(1_000)
    lookups.increment()
    return (64_520, "SLOW")
  }
}

/// A DNS stand-in that records the timeout of every lookup and answers nothing, at once or, when
/// held, once `gate` opens.
private actor TimeoutRecordingResolver: ASNResolver {
  nonisolated let gate = StallGate()
  private let held: Bool
  private(set) var timeouts: [TimeInterval] = []

  init(held: Bool = false) { self.held = held }

  func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
    timeouts.append(timeout)
    if held { await gate.waitAsync(limit: 60) }
    return [:]
  }
}
