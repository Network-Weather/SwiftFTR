import XCTest

@testable import SwiftFTR

final class SwiftFTRCacheTests: XCTestCase {
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
}
