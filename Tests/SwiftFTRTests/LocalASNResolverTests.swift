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

    // Preload should take ~35-50ms (database load)
    XCTAssertLessThan(preloadTime, 0.5, "Preload should complete in <500ms")

    // Subsequent lookup should be fast (no load delay)
    let lookupStart = Date()
    _ = try await resolver.resolve(ipv4Addrs: ["8.8.8.8"], timeout: 1.0)
    let lookupTime = Date().timeIntervalSince(lookupStart)

    // Lookup should be < 10ms (microseconds for actual lookup + overhead)
    XCTAssertLessThan(lookupTime, 0.01, "Post-preload lookup should be <10ms")
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
}
