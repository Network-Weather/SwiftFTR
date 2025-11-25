@_spi(Testing) @testable import SwiftFTR
import XCTest

final class SwiftFTRCacheTests: XCTestCase {
  override func setUp() async throws {
    // Clear the global ASN cache before each test for isolation
    await _ASNMemoryCache.shared.clear()
  }

  private actor CountingResolver: ASNResolver {
    private var count = 0
    func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
      count += 1
      var out: [String: ASNInfo] = [:]
      for ip in ipv4Addrs { out[ip] = ASNInfo(asn: 65000, name: "X") }
      return out
    }
    func calls() -> Int {
      return count
    }
  }

  /// Mock resolver that tracks timing to verify parallel execution.
  private actor TimingResolver: ASNResolver {
    private var callTimes: [Date] = []
    private let delay: TimeInterval

    init(delay: TimeInterval = 0.1) {
      self.delay = delay
    }

    func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
      callTimes.append(Date())
      // Simulate network delay
      try await Task.sleep(for: .milliseconds(Int(delay * 1000)))
      var out: [String: ASNInfo] = [:]
      for ip in ipv4Addrs { out[ip] = ASNInfo(asn: 65000, name: "TestASN") }
      return out
    }

    func getCallTimes() -> [Date] {
      return callTimes
    }
  }

  func testCachingResolverHitsCache() async throws {
    let base = CountingResolver()
    let caching = CachingASNResolver(base: base)
    // First call should consult base
    let _ = try await caching.resolve(ipv4Addrs: ["203.0.113.1"], timeout: 0.1)
    let count1 = await base.calls()
    XCTAssertEqual(count1, 1)
    // Second call with same key should be served from cache
    let _ = try await caching.resolve(ipv4Addrs: ["203.0.113.1"], timeout: 0.1)
    let count2 = await base.calls()
    XCTAssertEqual(count2, 1)
    // Mixed: one cached, one new => base called once more
    let _ = try await caching.resolve(ipv4Addrs: ["203.0.113.1", "203.0.113.2"], timeout: 0.1)
    let count3 = await base.calls()
    XCTAssertEqual(count3, 2)
  }

  /// Verify CymruDNSResolver executes lookups in parallel (v0.8.1 improvement).
  ///
  /// Uses real DNS queries to Team Cymru. With 8 diverse IPs and parallel execution,
  /// should complete in ~1-3s. Sequential would take ~8-16s (1-2s per IP).
  func testCymruResolverParallelExecution() async throws {
    // Skip if network tests are disabled
    guard ProcessInfo.processInfo.environment["SKIP_NETWORK_TESTS"] == nil else {
      throw XCTSkip("Network tests disabled")
    }

    // Diverse IPs from different ASNs to ensure actual DNS queries
    let testIPs = [
      "1.1.1.1",  // Cloudflare
      "8.8.8.8",  // Google
      "9.9.9.9",  // Quad9
      "208.67.222.222",  // OpenDNS
      "4.2.2.1",  // Level3
      "64.6.64.6",  // Verisign
      "77.88.8.8",  // Yandex
      "185.228.168.9",  // CleanBrowsing
    ]

    let resolver = CymruDNSResolver()
    let start = Date()
    let results = try await resolver.resolve(ipv4Addrs: testIPs, timeout: 2.0)
    let elapsed = Date().timeIntervalSince(start)

    // Should resolve most IPs (some may fail due to network conditions)
    XCTAssertGreaterThan(results.count, 4, "Should resolve at least half of the IPs")

    // With parallel execution (max 8 concurrent), should complete much faster than serial
    // Serial: 8 IPs × 1-2s each = 8-16s
    // Parallel: ~1-3s (limited by slowest query + AS name lookups)
    XCTAssertLessThan(
      elapsed, 6.0,
      "Parallel ASN resolution should complete in <6s (was \(String(format: "%.2f", elapsed))s)")
  }

  /// Verify ASN name deduplication reduces queries.
  ///
  /// When multiple IPs share the same ASN, we should only query the AS name once.
  func testCymruResolverDeduplicatesASNNames() async throws {
    guard ProcessInfo.processInfo.environment["SKIP_NETWORK_TESTS"] == nil else {
      throw XCTSkip("Network tests disabled")
    }

    // Multiple Google DNS IPs - all should resolve to same ASN
    let googleIPs = ["8.8.8.8", "8.8.4.4", "8.8.8.1", "8.8.4.1"]

    let resolver = CymruDNSResolver()
    let results = try await resolver.resolve(ipv4Addrs: googleIPs, timeout: 2.0)

    // All should resolve to Google's ASN (15169)
    let asns = Set(results.values.map { $0.asn })
    XCTAssertEqual(asns.count, 1, "All Google IPs should share one ASN")
    if let firstASN = asns.first {
      XCTAssertEqual(firstASN, 15169, "Google's ASN should be 15169")
    }

    // All should have the same AS name (deduplication worked)
    let names = Set(results.values.map { $0.name })
    XCTAssertEqual(names.count, 1, "All results should share deduplicated AS name")
  }

  // MARK: - Cache Correctness Tests

  /// Verify cache deduplicates IPs within a single call.
  func testCachingResolverDeduplicatesInput() async throws {
    let base = CountingResolver()
    let caching = CachingASNResolver(base: base)

    // Same IP repeated - should only query once
    let _ = try await caching.resolve(
      ipv4Addrs: ["203.0.113.1", "203.0.113.1", "203.0.113.1"], timeout: 0.1)
    let count = await base.calls()
    XCTAssertEqual(count, 1, "Duplicate IPs should be deduplicated before querying")
  }

  /// Verify cache handles empty input gracefully.
  func testCachingResolverEmptyInput() async throws {
    let base = CountingResolver()
    let caching = CachingASNResolver(base: base)

    let result = try await caching.resolve(ipv4Addrs: [], timeout: 0.1)
    XCTAssertTrue(result.isEmpty, "Empty input should return empty result")

    let count = await base.calls()
    XCTAssertEqual(count, 0, "Empty input should not call base resolver")
  }

  /// Verify cache filters out empty strings.
  func testCachingResolverFiltersEmptyStrings() async throws {
    let base = CountingResolver()
    let caching = CachingASNResolver(base: base)

    let result = try await caching.resolve(ipv4Addrs: ["", "", "203.0.113.1", ""], timeout: 0.1)
    XCTAssertEqual(result.count, 1, "Should only resolve non-empty IPs")

    let count = await base.calls()
    XCTAssertEqual(count, 1, "Should call base once for the one valid IP")
  }

  /// Verify cache returns correct data (not stale or mixed up).
  func testCachingResolverDataIntegrity() async throws {
    // Custom resolver that returns unique data per IP
    actor UniqueResolver: ASNResolver {
      func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
        var out: [String: ASNInfo] = [:]
        for ip in ipv4Addrs {
          // Use last octet as ASN for verification
          let lastOctet = Int(ip.split(separator: ".").last ?? "0") ?? 0
          out[ip] = ASNInfo(asn: lastOctet, name: "AS\(lastOctet)")
        }
        return out
      }
    }

    let base = UniqueResolver()
    let caching = CachingASNResolver(base: base)

    // First call
    let result1 = try await caching.resolve(
      ipv4Addrs: ["203.0.113.1", "203.0.113.2"], timeout: 0.1)
    XCTAssertEqual(result1["203.0.113.1"]?.asn, 1)
    XCTAssertEqual(result1["203.0.113.2"]?.asn, 2)

    // Second call - mix of cached and new
    let result2 = try await caching.resolve(
      ipv4Addrs: ["203.0.113.1", "203.0.113.3"], timeout: 0.1)
    XCTAssertEqual(result2["203.0.113.1"]?.asn, 1, "Cached value should be returned")
    XCTAssertEqual(result2["203.0.113.3"]?.asn, 3, "New value should be resolved")
  }

  // MARK: - Concurrent Access Tests

  /// Verify concurrent cache access doesn't corrupt data.
  func testCacheConcurrentAccessCorrectness() async throws {
    actor SequenceResolver: ASNResolver {
      private var callCount = 0

      func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
        callCount += 1
        // Small delay to increase chance of race conditions
        try await Task.sleep(for: .milliseconds(10))
        var out: [String: ASNInfo] = [:]
        for ip in ipv4Addrs {
          let lastOctet = Int(ip.split(separator: ".").last ?? "0") ?? 0
          out[ip] = ASNInfo(asn: lastOctet, name: "AS\(lastOctet)")
        }
        return out
      }

      func getCallCount() -> Int { callCount }
    }

    let base = SequenceResolver()
    let caching = CachingASNResolver(base: base)

    // Phase 1: Prime the cache with a known set of IPs
    _ = try await caching.resolve(
      ipv4Addrs: ["203.0.113.1", "203.0.113.2"], timeout: 1.0)
    let primeCalls = await base.getCallCount()
    XCTAssertEqual(primeCalls, 1, "Initial prime should be 1 call")

    // Phase 2: Launch many concurrent tasks all requesting the cached IPs
    let results = await withTaskGroup(of: [String: ASNInfo].self) { group in
      for _ in 0..<50 {
        group.addTask {
          // All tasks request the same cached IPs
          let ips = ["203.0.113.1", "203.0.113.2"]
          return (try? await caching.resolve(ipv4Addrs: ips, timeout: 1.0)) ?? [:]
        }
      }

      var allResults: [[String: ASNInfo]] = []
      for await result in group {
        allResults.append(result)
      }
      return allResults
    }

    // Verify all results have correct data (no corruption)
    for result in results {
      XCTAssertEqual(result["203.0.113.1"]?.asn, 1, "ASN for .1 should always be 1")
      XCTAssertEqual(result["203.0.113.2"]?.asn, 2, "ASN for .2 should always be 2")
    }

    // All 50 concurrent tasks should have been served from cache (no additional calls)
    let totalCalls = await base.getCallCount()
    XCTAssertEqual(
      totalCalls, 1, "All concurrent requests should hit cache (got \(totalCalls) calls)")
  }

  /// Verify cache operations don't block the caller (non-blocking).
  func testCacheNonBlocking() async throws {
    // Resolver that takes a long time
    actor SlowResolver: ASNResolver {
      func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
        try await Task.sleep(for: .milliseconds(500))
        var out: [String: ASNInfo] = [:]
        for ip in ipv4Addrs { out[ip] = ASNInfo(asn: 65000, name: "Slow") }
        return out
      }
    }

    let caching = CachingASNResolver(base: SlowResolver())

    // First call triggers slow resolution
    async let slowCall = caching.resolve(ipv4Addrs: ["203.0.113.1"], timeout: 2.0)

    // Give it a moment to start
    try await Task.sleep(for: .milliseconds(50))

    // This should NOT block waiting for the first call
    // It queries a different IP, so it should proceed independently
    let start = Date()
    async let fastCall = caching.resolve(ipv4Addrs: ["203.0.113.2"], timeout: 2.0)

    // Wait for both
    _ = try await slowCall
    _ = try await fastCall

    let elapsed = Date().timeIntervalSince(start)

    // If blocking, this would take ~1s (500ms + 500ms serial)
    // If non-blocking (parallel), should take ~500ms
    // Allow some margin but should be well under 800ms
    XCTAssertLessThan(
      elapsed, 0.8,
      "Concurrent cache calls should not block each other (took \(String(format: "%.2f", elapsed))s)"
    )
  }

  /// Stress test: many concurrent tasks with high volume.
  func testCacheStressTest() async throws {
    actor FastResolver: ASNResolver {
      private var callCount = 0
      func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
        callCount += 1
        var out: [String: ASNInfo] = [:]
        for ip in ipv4Addrs { out[ip] = ASNInfo(asn: 65000, name: "Fast") }
        return out
      }
      func getCallCount() -> Int { callCount }
    }

    let base = FastResolver()
    let caching = CachingASNResolver(base: base)

    let start = Date()

    // 100 concurrent tasks, each requesting 10 IPs
    await withTaskGroup(of: Void.self) { group in
      for i in 0..<100 {
        group.addTask {
          let ips = (0..<10).map { "203.0.113.\($0 + (i % 25))" }
          _ = try? await caching.resolve(ipv4Addrs: ips, timeout: 1.0)
        }
      }
    }

    let elapsed = Date().timeIntervalSince(start)
    let calls = await base.getCallCount()

    // Should complete quickly (cache is fast)
    XCTAssertLessThan(elapsed, 2.0, "Stress test should complete in <2s (took \(elapsed)s)")

    // Should have far fewer calls than 100 (caching worked)
    XCTAssertLessThan(calls, 100, "Cache should deduplicate (got \(calls) calls)")
  }
}
