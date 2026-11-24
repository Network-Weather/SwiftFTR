import XCTest

// swift-format-ignore: OrderedImports
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

  private struct ImmediateFailureResolver: ASNResolver {
    func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
      throw ControlledResolverError.requestedFailure
    }
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
      try await caching.resolve(ipv4Addrs: addresses, timeout: 60)
    }
    let firstStarted = await waitForCallCount(1, from: base)
    XCTAssertTrue(firstStarted)

    let second = Task {
      try await caching.resolve(ipv4Addrs: addresses, timeout: 60)
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
        timeout: 60
      )
    }
    let firstStarted = await waitForCallCount(1, from: base)
    XCTAssertTrue(firstStarted)

    let second = Task {
      try await caching.resolve(
        ipv4Addrs: ["203.0.113.2", "203.0.113.3"],
        timeout: 60
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
      try await outer.resolve(ipv4Addrs: [address], timeout: 60)
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
      try await firstCache.resolve(ipv4Addrs: [address], timeout: 60)
    }
    let firstStarted = await waitForCallCount(1, from: firstBase)
    XCTAssertTrue(firstStarted)
    let second = Task {
      try await secondCache.resolve(ipv4Addrs: [address], timeout: 60)
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
      try await caching.resolve(ipv4Addrs: [address], timeout: 30)
    }
    let firstStarted = await waitForCallCount(1, from: base)
    XCTAssertTrue(firstStarted)
    let long = Task {
      try await caching.resolve(ipv4Addrs: [address], timeout: 60)
    }
    let secondStarted = await waitForCallCount(2, from: base)
    XCTAssertTrue(secondStarted, "A short-timeout caller must not join a longer flight")

    await base.succeedAll()
    _ = try await short.value
    _ = try await long.value
    let callCount = await base.callCount()
    XCTAssertEqual(callCount, 2)
  }

  func testRejectedNaNTimeoutReleasesFlightReservation() async {
    let caching = CachingASNResolver(base: ImmediateFailureResolver())

    do {
      _ = try await caching.resolve(ipv4Addrs: ["203.0.113.7"], timeout: .nan)
      XCTFail("The base resolver should reject the lookup")
    } catch ControlledResolverError.requestedFailure {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let reservationCount = await _ASNMemoryCache.shared.inFlightReservationCount
    XCTAssertEqual(reservationCount, 0, "A rejected timeout must not leak its flight key")
  }

  func testCachingResolverReleasesFailedFlightsForRetry() async throws {
    let base = ControlledResolver()
    let caching = CachingASNResolver(base: base)
    let address = "203.0.113.20"

    let first = Task {
      try await caching.resolve(ipv4Addrs: [address], timeout: 60)
    }
    let firstStarted = await waitForCallCount(1, from: base)
    XCTAssertTrue(firstStarted)
    let joined = Task {
      try await caching.resolve(ipv4Addrs: [address], timeout: 60)
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
      try await caching.resolve(ipv4Addrs: [address], timeout: 60)
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
      try await caching.resolve(ipv4Addrs: [address], timeout: 60)
    }
    let ownerStarted = await waitForCallCount(1, from: base)
    XCTAssertTrue(ownerStarted)
    let joined = Task {
      try await caching.resolve(ipv4Addrs: [address], timeout: 60)
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
      try await caching.resolve(ipv4Addrs: [address], timeout: 60)
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
      try await caching.resolve(ipv4Addrs: [address], timeout: 60)
    }
    let retryStarted = await waitForCallCount(2, from: base)
    XCTAssertTrue(retryStarted)
    await base.succeedAll()
    let retryResult = try await retry.value
    let batches = await base.recordedBatches()

    XCTAssertEqual(batches, [[address], [address]])
    XCTAssertNotNil(retryResult[address])
  }

  /// A caller of the caching resolver returns at its own timeout even when the resolver behind it
  /// overruns, and leaving does not cancel the flight: it completes, fills the cache, and the next
  /// caller is answered from it without another upstream call.
  func testCallerReturnsAtItsTimeoutAndLeavesFlightRunning() async throws {
    final class OverrunningResolver: ASNResolver, @unchecked Sendable {
      let gate = StallGate()
      let calls = FaultCounter()
      let cancelled = FaultCounter()
      func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
        calls.increment()
        await gate.waitAsync(limit: 60)
        if Task.isCancelled { cancelled.increment() }
        var out: [String: ASNInfo] = [:]
        for ip in ipv4Addrs { out[ip] = ASNInfo(asn: 64_510, name: "Overrun") }
        return out
      }
    }

    let base = OverrunningResolver()
    defer { base.gate.open() }
    let caching = CachingASNResolver(base: base)
    let address = "203.0.113.80"

    let (early, _) = try await SwiftFTRTests.measure(within: 20) {
      try await caching.resolve(ipv4Addrs: [address], timeout: 0.3)
    }
    XCTAssertTrue(early.isEmpty, "nothing could answer before the timeout")
    let reservations = await _ASNMemoryCache.shared.inFlightReservationCount
    XCTAssertEqual(reservations, 1, "the flight ended when its only caller left")

    base.gate.open()
    let filled = await eventually(within: 20) { await _ASNMemoryCache.shared.count > 0 }
    XCTAssertTrue(filled, "the abandoned flight never filled the cache")
    let later = try await caching.resolve(ipv4Addrs: [address], timeout: 0.3)

    XCTAssertEqual(later[address]?.asn, 64_510)
    XCTAssertEqual(base.calls.value, 1, "the flight was started again instead of finishing once")
    XCTAssertEqual(base.cancelled.value, 0, "the flight was cancelled when its caller left")
  }

  /// A caller whose timeout passes while one of its flights is held still gets every answer the
  /// other flights gave, however many there are, whichever flight it waited on first.
  func testCallerKeepsAnswersOfFinishedFlightsAtItsTimeout() async throws {
    final class HoldingResolver: ASNResolver, @unchecked Sendable {
      let gate = StallGate()
      let held: Set<String>
      init(held: Set<String>) { self.held = held }
      func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
        if ipv4Addrs.contains(where: held.contains) { await gate.waitAsync(limit: 60) }
        var out: [String: ASNInfo] = [:]
        for ip in ipv4Addrs { out[ip] = ASNInfo(asn: 64_530, name: "Held") }
        return out
      }
    }

    // More answers than the cache keeps, so they cannot be read back from it. Each round starts
    // its two flights afresh, so the order the caller waits on them varies between rounds.
    let rounds = 6
    let heldAddresses = Set((0..<rounds).map { "198.51.100.\($0)" })
    let base = HoldingResolver(held: heldAddresses)
    defer { base.gate.open() }
    let caching = CachingASNResolver(base: base)
    for round in 0..<rounds {
      let held = "198.51.100.\(round)"
      // The same timeout as the caller below, so the caller joins this flight for `held`.
      let holding = Task { try await caching.resolve(ipv4Addrs: [held], timeout: 1) }
      let reserved = await eventually(within: 20) {
        await _ASNMemoryCache.shared.inFlightReservationCount >= round + 1
      }
      XCTAssertTrue(reserved)
      let quick = (0..<2_100).map { "203.\(round).\($0 / 256).\($0 % 256)" }
      let (result, _) = try await SwiftFTRTests.measure(within: 20) {
        try await caching.resolve(ipv4Addrs: [held] + quick, timeout: 1)
      }
      let answered = quick.filter { result[$0] != nil }.count
      XCTAssertEqual(answered, quick.count, "round \(round): answers lost at the timeout")
      holding.cancel()
    }
  }

  /// Callers that stop waiting for shared work, at their deadline or by cancellation, leave nothing
  /// registered on it, and the work still answers whoever asks once it finishes.
  func testWaitersLeavingSharedWorkLeaveNothingBehind() async throws {
    let gate = StallGate()
    defer { gate.open() }
    let work = SharedWork(
      Task<Int, Error> {
        await gate.waitAsync(limit: 60)
        return 7
      })

    for _ in 0..<200 {
      let value = try await work.value(until: .now + .milliseconds(1))
      XCTAssertNil(value)
    }
    let cancelled = Task { try await work.value(until: nil) }
    let registered = await eventually(within: 20) { work.waiterCount > 0 }
    XCTAssertTrue(registered)
    cancelled.cancel()
    _ = await cancelled.result
    let left = work.waiterCount
    XCTAssertEqual(left, 0, "callers that left are still registered")

    gate.open()
    let (value, _) = try await SwiftFTRTests.measure(within: 20) {
      try await work.value(until: nil)
    }
    XCTAssertEqual(value, 7)
  }

  /// Concurrent hybrid lookups of one address the database lacks share one DNS flight, whatever
  /// time each has left.
  func testConcurrentHybridFallbacksShareOneFlight() async throws {
    final class HeldCountingResolver: ASNResolver, @unchecked Sendable {
      let gate = StallGate()
      let calls = FaultCounter()
      func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
        calls.increment()
        await gate.waitAsync(limit: 60)
        var out: [String: ASNInfo] = [:]
        for ip in ipv4Addrs { out[ip] = ASNInfo(asn: 64_540, name: "DNS") }
        return out
      }
    }

    let base = HeldCountingResolver()
    defer { base.gate.open() }
    let store = LocalASNDatabaseStore(loader: { _ in EmptyLocalTable() })
    let hybrid = HybridASNResolver(
      local: LocalASNResolver(source: .embedded, store: store),
      dns: CachingASNResolver(base: base), fallbackTimeout: 30)

    let lookups = (0..<8).map { _ in
      Task { try await hybrid.resolve(ipv4Addrs: ["203.0.113.90"], timeout: 30) }
    }
    let allArrived = await eventually(within: 20) {
      await base.calls.value + _ASNMemoryCache.shared.inFlightJoinCount >= 8
    }
    XCTAssertTrue(allArrived, "the lookups never all reached the fallback")
    let calls = base.calls.value

    base.gate.open()
    for lookup in lookups {
      let (result, _) = try await SwiftFTRTests.measure(within: 20) { try await lookup.value }
      XCTAssertEqual(result["203.0.113.90"]?.asn, 64_540)
    }
    XCTAssertEqual(calls, 1, "identical fallbacks did not share a flight")
  }

  /// Through the cache, a Team Cymru lookup whose time runs out still returns the origins already
  /// answered, and the AS names that came back, as a direct lookup does.
  func testCachedCymruLookupReturnsAnsweredOriginsAtItsTimeout() async throws {
    let cymru = CymruDNSResolver(servers: ["192.0.2.1"], query: CymruScript.originsAnswered)
    let caching = CachingASNResolver(base: cymru)

    let (result, _) = try await SwiftFTRTests.measure(within: 20) {
      try await caching.resolve(ipv4Addrs: ["8.8.8.8", "1.1.1.1"], timeout: 0.3)
    }

    XCTAssertEqual(result["8.8.8.8"]?.asn, 15169, "the answered origin was dropped")
    XCTAssertEqual(result["8.8.8.8"]?.name, "", "the name never came back")
    XCTAssertEqual(result["1.1.1.1"]?.asn, 13335, "the answered origin was dropped")
    XCTAssertEqual(result["1.1.1.1"]?.name, "CLOUDFLARENET, US", "the answered name was dropped")
  }

  /// The default hybrid resolver's DNS fallback does the same for addresses its database lacks.
  func testHybridFallbackReturnsAnsweredOriginsAtItsTimeout() async throws {
    let cymru = CymruDNSResolver(servers: ["192.0.2.1"], query: CymruScript.originsAnswered)
    let store = LocalASNDatabaseStore(loader: { _ in EmptyLocalTable() })
    let hybrid = HybridASNResolver(
      local: LocalASNResolver(source: .embedded, store: store),
      dns: CachingASNResolver(base: cymru), fallbackTimeout: 2)

    let (result, _) = try await SwiftFTRTests.measure(within: 20) {
      try await hybrid.resolve(ipv4Addrs: ["8.8.8.8"], timeout: 0.3)
    }

    XCTAssertEqual(result["8.8.8.8"]?.asn, 15169, "the answered origin was dropped")
  }

  /// What a caller gets when one of its flights failed does not depend on the order it looks at
  /// them: with no answer from the others it throws, with an answer it returns that answer.
  func testFailedFlightOutcomeDoesNotDependOnOrder() async throws {
    // Holds 198.51.100.x for good and 192.0.2.x until `release` opens, then answers it; fails
    // everything else at once.
    final class HoldOrFail: ASNResolver, @unchecked Sendable {
      let gate = StallGate()
      let release = StallGate()
      func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
        if ipv4Addrs.contains(where: { $0.hasPrefix("198.51.100.") }) {
          await gate.waitAsync(limit: 60)
          return [:]
        }
        if ipv4Addrs.contains(where: { $0.hasPrefix("192.0.2.") }) {
          await release.waitAsync(limit: 60)
          return Dictionary(
            uniqueKeysWithValues: ipv4Addrs.map { ($0, ASNInfo(asn: 64_550, name: "OK")) })
        }
        throw ControlledResolverError.requestedFailure
      }
    }

    var threw = 0
    var answered = 0
    let rounds = 20
    for round in 0..<rounds {
      let base = HoldOrFail()
      defer {
        base.gate.open()
        base.release.open()
      }
      let caching = CachingASNResolver(base: base)

      // A held flight and one that fails at once: nothing to return, so the caller throws.
      let held = "198.51.100.\(round)"
      _ = try await caching.resolve(ipv4Addrs: [held], timeout: 0.05)  // leaves its flight held
      do {
        _ = try await caching.resolve(ipv4Addrs: [held, "203.0.113.\(round)"], timeout: 0.05)
      } catch ControlledResolverError.requestedFailure {
        threw += 1
      }

      // A flight that answers once released and one that fails at once: the answer is returned.
      let answering = "192.0.2.\(round)"
      let starter = Task { try await caching.resolve(ipv4Addrs: [answering], timeout: 30) }
      let reserved = await eventually(within: 20) {
        await _ASNMemoryCache.shared.inFlightReservationCount >= 2
      }
      XCTAssertTrue(reserved)
      let joinsBefore = await _ASNMemoryCache.shared.inFlightJoinCount
      let mixed = Task {
        try await caching.resolve(ipv4Addrs: [answering, "203.0.114.\(round)"], timeout: 30)
      }
      let joined = await eventually(within: 20) {
        await _ASNMemoryCache.shared.inFlightJoinCount > joinsBefore
      }
      XCTAssertTrue(joined)
      base.release.open()
      _ = try await starter.value
      if let result = try? await mixed.value, result[answering] != nil { answered += 1 }
    }
    XCTAssertEqual(threw, rounds, "a caller with nothing but a failure did not always throw")
    XCTAssertEqual(answered, rounds, "an answer beside a failure was not always returned")
  }

  /// A caller whose time runs out while it is still preparing its addresses starts no lookup: its
  /// deadline is taken when the call begins.
  func testDeadlineCoversPreparingTheAddresses() async throws {
    let base = CountingResolver()
    let caching = CachingASNResolver(base: base)
    let addresses = (0..<65_536).map { "8.8.\($0 / 256).\($0 % 256)" }

    let result = try await caching.resolve(ipv4Addrs: addresses, timeout: 1e-9)

    XCTAssertTrue(result.isEmpty)
    let calls = await base.calls()
    XCTAssertEqual(calls, 0, "a lookup started after the deadline had passed")
  }

  /// A caller whose time runs out while it sorts its addresses still gets what the flights it had
  /// already joined have answered.
  func testCallerOutOfTimeWhileSortingKeepsJoinedAnswers() async throws {
    // Publishes an answer for every address at once, then holds its flight until `gate` opens.
    final class PublishThenHold: ASNProgressReporting, @unchecked Sendable {
      let gate = StallGate()
      let published = FaultCounter()
      func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
        await gate.waitAsync(limit: 60)
        return [:]
      }
      func resolve(
        ipv4Addrs: [String], timeout: TimeInterval, publishing log: ASNAnswerLog
      ) async throws -> [String: ASNInfo] {
        log.publish(
          Dictionary(uniqueKeysWithValues: ipv4Addrs.map { ($0, ASNInfo(asn: 64_560, name: "P")) }))
        published.increment()
        return try await resolve(ipv4Addrs: ipv4Addrs, timeout: timeout)
      }
    }
    let base = PublishThenHold()
    defer { base.gate.open() }
    let caching = CachingASNResolver(base: base)
    let joined = "198.51.100.77"
    let holder = Task { try await caching.resolve(ipv4Addrs: [joined], timeout: 30) }
    defer { holder.cancel() }
    let published = await eventually(within: 20) { base.published.value > 0 }
    XCTAssertTrue(published, "the held flight never published its answer")

    // Prepared in this order, so the joined address is sorted before the first look at the clock,
    // which has passed by then.
    let others = (0..<65_536).map { "8.9.\($0 / 256).\($0 % 256)" }
    let result = try await caching.resolve(
      prepared: [joined] + others, timeout: 30, until: .now + .nanoseconds(1))

    XCTAssertEqual(result[joined]?.asn, 64_560, "the joined flight's answer was dropped")
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
          return (try? await caching.resolve(ipv4Addrs: ips, timeout: 60)) ?? [:]
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
    // A resolver that holds one address until the test opens `gate` and answers any other at once.
    final class GatedResolver: ASNResolver, @unchecked Sendable {
      let gate = StallGate()
      let slowStarted = FaultCounter()
      func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
        if ipv4Addrs.contains("203.0.113.1") {
          slowStarted.increment()
          await gate.waitAsync(limit: 60)
        }
        var out: [String: ASNInfo] = [:]
        for ip in ipv4Addrs { out[ip] = ASNInfo(asn: 65000, name: "Gated") }
        return out
      }
    }

    let base = GatedResolver()
    defer { base.gate.open() }
    let caching = CachingASNResolver(base: base)

    // The first call is held in the resolver until the second has returned.
    let slowCall = Task { try await caching.resolve(ipv4Addrs: ["203.0.113.1"], timeout: 60) }
    let started = await eventually(within: 20) { base.slowStarted.value > 0 }
    XCTAssertTrue(started, "the first lookup never reached the resolver")

    // A different address must not wait for the held one: it returns while the gate is still
    // closed, or trips the watchdog. (Qualified: XCTestCase's own `measure` hides the helper.)
    let (fast, _) = try await SwiftFTRTests.measure(within: 20) {
      try await caching.resolve(ipv4Addrs: ["203.0.113.2"], timeout: 60)
    }
    XCTAssertEqual(fast["203.0.113.2"]?.asn, 65000)

    base.gate.open()
    let (slow, _) = try await SwiftFTRTests.measure(within: 20) { try await slowCall.value }
    XCTAssertEqual(slow["203.0.113.1"]?.asn, 65000)
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

    // 100 concurrent tasks, each requesting 10 IPs. The watchdog catches a cache that deadlocks
    // under contention; it is not a claim about speed.
    _ = try await SwiftFTRTests.measure(within: 20) {
      await withTaskGroup(of: Void.self) { group in
        for i in 0..<100 {
          group.addTask {
            let ips = (0..<10).map { "203.0.113.\($0 + (i % 25))" }
            _ = try? await caching.resolve(ipv4Addrs: ips, timeout: 60)
          }
        }
      }
    }

    let calls = await base.getCallCount()

    // The requests cover 34 unique addresses. Each upstream call must reserve at least one new
    // address, so overlapping misses can never produce more calls than unique keys.
    XCTAssertLessThanOrEqual(calls, 34, "Cache should coalesce overlapping misses (got \(calls))")
  }
}

/// A database stand-in that answers nothing.
private struct EmptyLocalTable: LocalASNTable {
  func lookup(_ ipString: String) -> (asn: UInt32, name: String?)? { nil }
}

/// Team Cymru answers scripted for a resolver's query function: the origins of 8.8.8.8 and
/// 1.1.1.1 at once, the AS name of AS13335 at once, and silence for AS15169's name until the
/// query's deadline.
enum CymruScript {
  static let originsAnswered: CymruDNSResolver.TXTQuery = { name, _, deadline in
    switch name.lowercased() {
    case "8.8.8.8.origin.asn.cymru.com":
      return ["15169 | 8.8.8.0/24 | US | arin | 2023-12-28"]
    case "1.1.1.1.origin.asn.cymru.com":
      return ["13335 | 1.1.1.0/24 | AU | apnic | 2011-08-11"]
    case "as13335.asn.cymru.com":
      return ["13335 | US | arin | 2010-07-14 | CLOUDFLARENET, US"]
    default:
      try? await Task.sleep(until: deadline, clock: .continuous)
      return nil
    }
  }
}
