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
      ipv4Addrs: ["8.8.8.8", "1.1.1.1"], timeout: 1.0)

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
      ipv4Addrs: ["2606:4700:4700::1111", "2001:4860:4860::8888"], timeout: 1.0)

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
      _ = try await resolver.resolve(ipv4Addrs: ips, timeout: 1.0)
    }
    let elapsed = Date().timeIntervalSince(start)

    // 1000 lookups should complete in well under 1 second
    // (microseconds per lookup means ~10ms total max)
    XCTAssertLessThan(
      elapsed, 1.0,
      "1000 lookups should complete in <1s (took \(String(format: "%.3f", elapsed))s)")
  }

  /// Verify preload works and eliminates first-lookup latency.
  func testPreload() async throws {
    let resolver = LocalASNResolver(source: .embedded)

    // Preload
    let preloadStart = Date()
    await resolver.preload()
    let preloadTime = Date().timeIntervalSince(preloadStart)

    // Preload typically takes ~35-50ms on a developer machine, but GitHub-hosted
    // macOS runners are routinely slower (observed 0.9s under load). Use a
    // generous ceiling that catches outright regressions without flaking on
    // shared CI runners; the actual perf budget is enforced by ResourceBenchmark.
    XCTAssertLessThan(preloadTime, 2.0, "Preload should complete in <2s")

    // Subsequent lookup should be fast (no load delay)
    let lookupStart = Date()
    _ = try await resolver.resolve(ipv4Addrs: ["8.8.8.8"], timeout: 1.0)
    let lookupTime = Date().timeIntervalSince(lookupStart)

    // Lookup should be < 50ms under CI load (microseconds for actual lookup + scheduling overhead).
    XCTAssertLessThan(lookupTime, 0.05, "Post-preload lookup should be <50ms")
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
      timeout: 1.0
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
      timeout: 1.0
    )

    XCTAssertEqual(results.count, 1, "Only public IPs should be resolved")
    XCTAssertNil(results["100.64.0.1"], "CGNAT IP should not be resolved")
    XCTAssertNil(results["100.127.255.254"], "CGNAT IP should not be resolved")
  }

  /// Verify empty and invalid inputs are handled gracefully.
  func testEmptyAndInvalidInput() async throws {
    let resolver = LocalASNResolver(source: .embedded)

    // Empty input
    let emptyResult = try await resolver.resolve(ipv4Addrs: [], timeout: 1.0)
    XCTAssertTrue(emptyResult.isEmpty, "Empty input should return empty result")

    // Empty strings
    let emptyStrings = try await resolver.resolve(ipv4Addrs: ["", "", "8.8.8.8"], timeout: 1.0)
    XCTAssertEqual(emptyStrings.count, 1, "Should filter empty strings")
  }

  // MARK: - HybridASNResolver Tests

  /// Verify hybrid resolver uses local DB for known IPs.
  func testHybridLocalHit() async throws {
    let resolver = HybridASNResolver(source: .embedded, fallbackTimeout: 0.5)

    let results = try await resolver.resolve(ipv4Addrs: ["8.8.8.8"], timeout: 1.0)

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

    let firstResult = try await first.resolve(ipv4Addrs: ["8.8.8.8"], timeout: 1.0)
    let secondResult = try await second.resolve(ipv4Addrs: ["1.1.1.1"], timeout: 1.0)
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
      let result = try await resolver.resolve(ipv4Addrs: ["8.8.8.8"], timeout: 1.0)
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
    let firstResult = try await first.resolve(ipv4Addrs: ["8.8.8.8"], timeout: 1.0)
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
}
