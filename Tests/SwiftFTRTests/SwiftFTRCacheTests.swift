import XCTest

@_spi(Testing) @testable import SwiftFTR

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

  private enum ControlledResolverError: Error {
    case requestedFailure
  }

  /// Resolver whose calls remain suspended until a test explicitly completes them.
  private actor ControlledResolver: ASNResolver {
    private var batches: [[String]] = []
    private var pendingCalls: [Int: CheckedContinuation<[String: ASNInfo], Error>] = [:]

    func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
      let callIndex = batches.count
      batches.append(ipv4Addrs.sorted())
      return try await withCheckedThrowingContinuation { continuation in
        pendingCalls[callIndex] = continuation
      }
    }

    func callCount() -> Int { batches.count }

    func recordedBatches() -> [[String]] { batches }

    func succeed(callAt index: Int) {
      guard let continuation = pendingCalls.removeValue(forKey: index) else { return }
      var result: [String: ASNInfo] = [:]
      for address in batches[index] {
        let suffix = Int(address.split(separator: ".").last ?? "0") ?? 0
        result[address] = ASNInfo(asn: 65_000 + suffix, name: "Controlled")
      }
      continuation.resume(returning: result)
    }

    func succeedAll() {
      for index in pendingCalls.keys.sorted() {
        succeed(callAt: index)
      }
    }

    func failAll() {
      for index in pendingCalls.keys.sorted() {
        pendingCalls.removeValue(forKey: index)?.resume(
          throwing: ControlledResolverError.requestedFailure
        )
      }
    }
  }

  private func waitForCallCount(
    _ expectedCount: Int,
    from resolver: ControlledResolver
  ) async -> Bool {
    for _ in 0..<2_000 {
      if await resolver.callCount() >= expectedCount { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return await resolver.callCount() >= expectedCount
  }

  private func waitForJoinCount(_ expectedCount: Int) async -> Bool {
    for _ in 0..<2_000 {
      if await _ASNMemoryCache.shared.inFlightJoinCount >= expectedCount { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return await _ASNMemoryCache.shared.inFlightJoinCount >= expectedCount
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

  func testCachingResolverCoalescesIdenticalConcurrentMisses() async throws {
    let base = ControlledResolver()
    let caching = CachingASNResolver(base: base)
    let addresses = ["203.0.113.10", "203.0.113.11"]

    let first = Task {
      try await caching.resolve(ipv4Addrs: addresses, timeout: 1.0)
    }
    let firstStarted = await waitForCallCount(1, from: base)
    XCTAssertTrue(firstStarted)

    let second = Task {
      try await caching.resolve(ipv4Addrs: addresses, timeout: 1.0)
    }
    let secondJoined = await waitForJoinCount(1)
    let callsWhileSuspended = await base.callCount()

    await base.succeedAll()
    let firstResult = try await first.value
    let secondResult = try await second.value

    XCTAssertTrue(secondJoined)
    XCTAssertEqual(callsWhileSuspended, 1, "Identical misses should share one upstream call")
    XCTAssertEqual(firstResult, secondResult)
    XCTAssertEqual(Set(secondResult.keys), Set(addresses))
  }

  func testCachingResolverCoalescesOverlappingBatches() async throws {
    let base = ControlledResolver()
    let caching = CachingASNResolver(base: base)

    let first = Task {
      try await caching.resolve(
        ipv4Addrs: ["203.0.113.1", "203.0.113.2"],
        timeout: 1.0
      )
    }
    let firstStarted = await waitForCallCount(1, from: base)
    XCTAssertTrue(firstStarted)

    let second = Task {
      try await caching.resolve(
        ipv4Addrs: ["203.0.113.2", "203.0.113.3"],
        timeout: 1.0
      )
    }
    let secondStarted = await waitForCallCount(2, from: base)
    XCTAssertTrue(secondStarted)
    let batches = await base.recordedBatches()

    await base.succeedAll()
    let firstResult = try await first.value
    let secondResult = try await second.value

    XCTAssertEqual(batches, [["203.0.113.1", "203.0.113.2"], ["203.0.113.3"]])
    XCTAssertEqual(Set(firstResult.keys), ["203.0.113.1", "203.0.113.2"])
    XCTAssertEqual(Set(secondResult.keys), ["203.0.113.2", "203.0.113.3"])
  }

  func testNestedCachingResolversUseIndependentFlights() async throws {
    let base = ControlledResolver()
    let inner = CachingASNResolver(base: base)
    let outer = CachingASNResolver(base: inner)
    let address = "203.0.113.4"

    let lookup = Task {
      try await outer.resolve(ipv4Addrs: [address], timeout: 1.0)
    }
    let baseStarted = await waitForCallCount(1, from: base)
    XCTAssertTrue(baseStarted, "Nested caching decorators must not await their own outer flight")
    await base.succeedAll()

    let result = try await lookup.value
    let callCount = await base.callCount()
    XCTAssertEqual(callCount, 1)
    XCTAssertNotNil(result[address])
  }

  func testDifferentCachingResolversDoNotShareFlights() async throws {
    let firstBase = ControlledResolver()
    let secondBase = ControlledResolver()
    let firstCache = CachingASNResolver(base: firstBase)
    let secondCache = CachingASNResolver(base: secondBase)
    let address = "203.0.113.5"

    let first = Task {
      try await firstCache.resolve(ipv4Addrs: [address], timeout: 1.0)
    }
    let firstStarted = await waitForCallCount(1, from: firstBase)
    XCTAssertTrue(firstStarted)
    let second = Task {
      try await secondCache.resolve(ipv4Addrs: [address], timeout: 1.0)
    }
    let secondStarted = await waitForCallCount(1, from: secondBase)
    XCTAssertTrue(
      secondStarted, "Each caching decorator must use its own base for an in-flight miss")

    await firstBase.succeedAll()
    await secondBase.succeedAll()
    _ = try await first.value
    _ = try await second.value
  }

  func testDifferentTimeoutsDoNotShareFlights() async throws {
    let base = ControlledResolver()
    let caching = CachingASNResolver(base: base)
    let address = "203.0.113.6"

    let short = Task {
      try await caching.resolve(ipv4Addrs: [address], timeout: 0.1)
    }
    let firstStarted = await waitForCallCount(1, from: base)
    XCTAssertTrue(firstStarted)
    let long = Task {
      try await caching.resolve(ipv4Addrs: [address], timeout: 1.0)
    }
    let secondStarted = await waitForCallCount(2, from: base)
    XCTAssertTrue(secondStarted, "A short-timeout caller must not join a longer flight")

    await base.succeedAll()
    _ = try await short.value
    _ = try await long.value
    let callCount = await base.callCount()
    XCTAssertEqual(callCount, 2)
  }

  func testCachingResolverReleasesFailedFlightsForRetry() async throws {
    let base = ControlledResolver()
    let caching = CachingASNResolver(base: base)
    let address = "203.0.113.20"

    let first = Task {
      try await caching.resolve(ipv4Addrs: [address], timeout: 1.0)
    }
    let firstStarted = await waitForCallCount(1, from: base)
    XCTAssertTrue(firstStarted)
    let joined = Task {
      try await caching.resolve(ipv4Addrs: [address], timeout: 1.0)
    }
    let secondJoined = await waitForJoinCount(1)
    let callsWhileSuspended = await base.callCount()

    await base.failAll()
    for task in [first, joined] {
      do {
        _ = try await task.value
        XCTFail("The failed shared load should throw")
      } catch ControlledResolverError.requestedFailure {
        // Expected.
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
    }

    let retry = Task {
      try await caching.resolve(ipv4Addrs: [address], timeout: 1.0)
    }
    let retryStarted = await waitForCallCount(2, from: base)
    XCTAssertTrue(retryStarted)
    await base.succeedAll()
    let retryResult = try await retry.value
    let batches = await base.recordedBatches()

    XCTAssertTrue(secondJoined)
    XCTAssertEqual(callsWhileSuspended, 1)
    XCTAssertEqual(batches, [[address], [address]])
    XCTAssertNotNil(retryResult[address])
  }

  func testCancelingCallerDoesNotCancelSharedFlight() async throws {
    let base = ControlledResolver()
    let caching = CachingASNResolver(base: base)
    let address = "203.0.113.40"

    let owner = Task {
      try await caching.resolve(ipv4Addrs: [address], timeout: 1.0)
    }
    let ownerStarted = await waitForCallCount(1, from: base)
    XCTAssertTrue(ownerStarted)
    let joined = Task {
      try await caching.resolve(ipv4Addrs: [address], timeout: 1.0)
    }
    let secondJoined = await waitForJoinCount(1)

    let cancellationObserved = expectation(description: "Canceled caller stops waiting")
    let canceledResult = Task {
      defer { cancellationObserved.fulfill() }
      do {
        _ = try await joined.value
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }
    joined.cancel()
    await fulfillment(of: [cancellationObserved], timeout: 1.0)
    await base.succeedAll()
    let ownerResult = try await owner.value
    let canceledPromptly = await canceledResult.value

    XCTAssertTrue(secondJoined)
    XCTAssertTrue(canceledPromptly)
    let callCount = await base.callCount()
    XCTAssertEqual(callCount, 1)
    XCTAssertNotNil(ownerResult[address])
  }

  func testClearingCacheCancelsFlightsAndPreventsStalePopulation() async throws {
    let base = ControlledResolver()
    let caching = CachingASNResolver(base: base)
    let address = "203.0.113.50"

    let first = Task {
      try await caching.resolve(ipv4Addrs: [address], timeout: 1.0)
    }
    let firstStarted = await waitForCallCount(1, from: base)
    XCTAssertTrue(firstStarted)

    await _ASNMemoryCache.shared.clear()
    await base.succeedAll()
    do {
      _ = try await first.value
      XCTFail("Clearing the cache should cancel its shared flights")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let cacheCount = await _ASNMemoryCache.shared.count
    XCTAssertEqual(cacheCount, 0)

    let retry = Task {
      try await caching.resolve(ipv4Addrs: [address], timeout: 1.0)
    }
    let retryStarted = await waitForCallCount(2, from: base)
    XCTAssertTrue(retryStarted)
    await base.succeedAll()
    let retryResult = try await retry.value
    let batches = await base.recordedBatches()

    XCTAssertEqual(batches, [[address], [address]])
    XCTAssertNotNil(retryResult[address])
  }

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

    // The requests cover 34 unique addresses. Each upstream call must reserve at least one new
    // address, so overlapping misses can never produce more calls than unique keys.
    XCTAssertLessThanOrEqual(calls, 34, "Cache should coalesce overlapping misses (got \(calls))")
  }
}
