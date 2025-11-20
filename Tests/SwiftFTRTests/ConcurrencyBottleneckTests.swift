import Foundation
import Testing

@testable import SwiftFTR

/// Tests that reproduce concurrency bottlenecks in SwiftFTR v0.5.3
///
/// These tests are EXPECTED TO FAIL or show poor performance, proving that
/// bottlenecks exist. Once the concurrency modernization is complete, these
/// tests should pass with acceptable performance.
///
/// Bottlenecks being tested:
/// 1. Actor serialization: Multiple `trace()` calls serialize on same instance
/// 2. Blocking I/O: STUN/DNS operations block actor, delaying other operations
/// 3. Sequential multipath: Flow variations execute serially, not in parallel
/// 4. Cache contention: NSLock-based ASN cache may show contention
///
/// Reference: docs/development/SwiftFTR-Concurrency-Audit.md
@Suite("Concurrency Bottleneck Reproduction Tests")
struct ConcurrencyBottleneckTests {

  /// Test 1: Concurrent traces serialize on single SwiftFTR instance
  ///
  /// BOTTLENECK: SwiftFTR is an actor, so multiple `trace()` calls execute
  /// serially, one at a time. With 20 traces @ ~1s each = ~20s total.
  ///
  /// EXPECTED BEHAVIOR (after fix): 20 traces should complete in ~1-2s
  /// (parallel execution with proper session workers)
  ///
  /// CURRENT BEHAVIOR: Will take ~15-20s due to actor serialization
  @Test(
    "Concurrent traces serialize on single actor instance",
    .disabled(
      "Known bottleneck - requires concurrency refactor. See docs/development/SwiftFTR-Concurrency-Audit.md"
    ),
    .timeLimit(.minutes(2))
  )
  func testConcurrentTracesSerialize() async throws {
    let config = SwiftFTRConfig(maxHops: 10, maxWaitMs: 500, publicIP: "0.0.0.0")
    let tracer = SwiftFTR(config: config)

    let startTime = Date()
    var completionTimes: [TimeInterval] = []

    // Launch 20 concurrent traces to the same destination
    try await withThrowingTaskGroup(of: TraceResult.self) { group in
      for _ in 1...20 {
        group.addTask {
          try await tracer.trace(to: "8.8.8.8")
        }
      }

      // Collect results and track when each completes
      for try await _ in group {
        completionTimes.append(Date().timeIntervalSince(startTime))
      }
    }

    let elapsed = Date().timeIntervalSince(startTime)

    // Calculate spread (how far apart completions are)
    let minCompletion = completionTimes.min()!
    let maxCompletion = completionTimes.max()!
    let spread = maxCompletion - minCompletion

    print(
      """
      Concurrent Trace Bottleneck Test:
        Total time: \(String(format: "%.2f", elapsed))s
        Completion spread: \(String(format: "%.2f", spread))s
        Min completion: \(String(format: "%.2f", minCompletion))s
        Max completion: \(String(format: "%.2f", maxCompletion))s

      EXPECTED (serialized): ~15-20s total, ~15-20s spread
      TARGET (parallel): <2s total, <1s spread
      """
    )

    // This SHOULD pass after concurrency modernization
    // Currently EXPECTED TO FAIL showing serialization
    let spreadMsg =
      "Traces serialize (spread: \(String(format: "%.2f", spread))s). "
      + "After modernization, should be <1s."
    #expect(spread < 1.0, Comment(rawValue: spreadMsg))

    let timeMsg =
      "20 traces took \(String(format: "%.2f", elapsed))s. "
      + "After modernization, should be <2s (parallel)."
    #expect(elapsed < 2.0, Comment(rawValue: timeMsg))
  }

  /// Test 1b: Longer concurrent traces with STUN enabled (improved test)
  ///
  /// BOTTLENECK: SwiftFTR is an actor, so multiple `trace()` calls execute
  /// serially. This improved version uses longer traces and STUN to detect
  /// the bottleneck that the original test missed.
  ///
  /// EXPECTED BEHAVIOR (after fix): 10 traces should complete in ~2-3s
  /// (parallel execution with proper session workers)
  ///
  /// CURRENT BEHAVIOR: Will take ~15-20s due to actor serialization
  @Test(
    "Longer concurrent traces with STUN serialize on actor",
    .disabled(
      "Known bottleneck - requires concurrency refactor. See docs/development/SwiftFTR-Concurrency-Audit.md"
    ),
    .timeLimit(.minutes(3))
  )
  func testLongConcurrentTracesWithSTUN() async throws {
    // Use default config to enable STUN (no publicIP override)
    let config = SwiftFTRConfig(maxHops: 30, maxWaitMs: 2000)
    let tracer = SwiftFTR(config: config)

    let startTime = Date()
    var completionTimes: [TimeInterval] = []

    // Launch 10 concurrent traces to distant host
    try await withThrowingTaskGroup(of: TraceResult.self) { group in
      for _ in 1...10 {
        group.addTask {
          try await tracer.trace(to: "1.1.1.1")
        }
      }

      // Collect results and track when each completes
      for try await _ in group {
        completionTimes.append(Date().timeIntervalSince(startTime))
      }
    }

    let elapsed = Date().timeIntervalSince(startTime)

    // Calculate spread (how far apart completions are)
    let minCompletion = completionTimes.min()!
    let maxCompletion = completionTimes.max()!
    let spread = maxCompletion - minCompletion

    print(
      """
      Long Concurrent Trace Bottleneck Test (STUN enabled):
        Total time: \(String(format: "%.2f", elapsed))s
        Completion spread: \(String(format: "%.2f", spread))s
        Min completion: \(String(format: "%.2f", minCompletion))s
        Max completion: \(String(format: "%.2f", maxCompletion))s

      EXPECTED (serialized): ~20-30s total, ~18-27s spread
      TARGET (parallel): <5s total, <2s spread
      """
    )

    // This SHOULD pass after concurrency modernization
    // Currently EXPECTED TO FAIL showing serialization
    let spreadMsg =
      "Traces serialize (spread: \(String(format: "%.2f", spread))s). "
      + "After modernization, should be <2s."
    #expect(spread < 2.0, Comment(rawValue: spreadMsg))

    let timeMsg =
      "10 traces took \(String(format: "%.2f", elapsed))s. "
      + "After modernization, should be <5s (parallel)."
    #expect(elapsed < 5.0, Comment(rawValue: timeMsg))
  }

  /// Test 2: Actor remains responsive during STUN/DNS operations
  ///
  /// BOTTLENECK: STUN and DNS operations use synchronous blocking I/O
  /// (socket send/recv). When running on the actor, this blocks the entire
  /// actor, preventing other operations from proceeding.
  ///
  /// EXPECTED BEHAVIOR (after fix): Ping calls should complete quickly
  /// even while STUN/DNS is running (async wrappers free the actor)
  ///
  /// CURRENT BEHAVIOR: Ping may be delayed waiting for actor availability
  @Test(
    "Actor blocked by synchronous STUN/DNS operations",
    .disabled(
      "Known bottleneck - requires async I/O refactor. See docs/development/SwiftFTR-Concurrency-Audit.md"
    ),
    .timeLimit(.minutes(1))
  )
  func testBlockingIOStallsActor() async throws {
    // Use default config to trigger STUN (no publicIP override)
    let config = SwiftFTRConfig(maxHops: 10, maxWaitMs: 500, noReverseDNS: false)
    let tracer = SwiftFTR(config: config)
    var pingTimes: [TimeInterval] = []

    // Start a classified trace (triggers STUN discovery + DNS lookups + rDNS)
    async let classifiedTrace = tracer.traceClassified(to: "1.1.1.1")

    // Give trace a moment to start and hit STUN
    try await Task.sleep(for: .milliseconds(100))

    // Now try to ping while trace is running
    // If actor is blocked by STUN/DNS, these will be delayed
    for _ in 0..<5 {
      let pingStart = Date()
      _ = try await tracer.ping(
        to: "8.8.8.8",
        config: PingConfig(count: 1, interval: 0, timeout: 1.0)
      )
      let pingElapsed = Date().timeIntervalSince(pingStart)
      pingTimes.append(pingElapsed)
      try await Task.sleep(for: .milliseconds(200))
    }

    // Wait for classified trace to complete
    _ = try await classifiedTrace

    let maxPingTime = pingTimes.max()!
    let avgPingTime = pingTimes.reduce(0, +) / Double(pingTimes.count)

    print(
      """
      Blocking I/O Test:
        Ping times: \(pingTimes.map { String(format: "%.2f", $0) }.joined(separator: "s, "))s
        Max ping time: \(String(format: "%.2f", maxPingTime))s
        Avg ping time: \(String(format: "%.2f", avgPingTime))s

      EXPECTED (blocking): Some pings delayed >1s waiting for STUN/DNS
      TARGET (async): All pings <0.5s (actor stays responsive)
      """
    )

    // Note: ping() is nonisolated, so this test may not show blocking
    // in current implementation. But it establishes baseline.
    // The real issue is concurrent trace() or traceClassified() calls.
    let msg =
      "Max ping time: \(String(format: "%.2f", maxPingTime))s. "
      + "After async I/O wrappers, should be <0.5s."

    // Relaxed expectation since ping is already nonisolated
    #expect(maxPingTime < 2.0, Comment(rawValue: msg))
  }

  /// Test 2b: Concurrent traceClassified calls detect blocking I/O (improved test)
  ///
  /// BOTTLENECK: STUN and DNS operations use synchronous blocking I/O.
  /// When multiple traceClassified() calls run concurrently on the same actor,
  /// the synchronous operations serialize them.
  ///
  /// EXPECTED BEHAVIOR (after fix): 5 classified traces should complete in ~2-3s
  /// (parallel execution with async I/O wrappers)
  ///
  /// CURRENT BEHAVIOR: Will take much longer due to STUN/DNS blocking
  @Test(
    "Concurrent traceClassified calls serialize due to blocking I/O",
    .disabled(
      "Known bottleneck - requires async I/O refactor. See docs/development/SwiftFTR-Concurrency-Audit.md"
    ),
    .timeLimit(.minutes(2))
  )
  func testConcurrentClassifiedTracesBlocking() async throws {
    // Use default config to enable STUN and rDNS
    let config = SwiftFTRConfig(maxHops: 15, maxWaitMs: 1000, noReverseDNS: false)
    let tracer = SwiftFTR(config: config)

    let startTime = Date()
    var completionTimes: [TimeInterval] = []

    // Launch 5 concurrent classified traces
    // Each will trigger: STUN (first call) + ASN lookups + rDNS
    try await withThrowingTaskGroup(of: ClassifiedTrace.self) { group in
      for _ in 1...5 {
        group.addTask {
          try await tracer.traceClassified(to: "1.1.1.1")
        }
      }

      // Collect results and track when each completes
      for try await _ in group {
        completionTimes.append(Date().timeIntervalSince(startTime))
      }
    }

    let elapsed = Date().timeIntervalSince(startTime)

    // Calculate spread (how far apart completions are)
    let minCompletion = completionTimes.min()!
    let maxCompletion = completionTimes.max()!
    let spread = maxCompletion - minCompletion

    print(
      """
      Concurrent Classified Trace Blocking I/O Test:
        Total time: \(String(format: "%.2f", elapsed))s
        Completion spread: \(String(format: "%.2f", spread))s
        Min completion: \(String(format: "%.2f", minCompletion))s
        Max completion: \(String(format: "%.2f", maxCompletion))s

      EXPECTED (blocking I/O): Long spread, operations serialize
      TARGET (async I/O): <3s total, <1s spread
      """
    )

    // This SHOULD pass after async I/O wrappers are implemented
    // Currently EXPECTED TO FAIL if blocking I/O causes serialization
    let spreadMsg =
      "Classified traces serialize (spread: \(String(format: "%.2f", spread))s). "
      + "After async I/O, should be <1s."
    #expect(spread < 1.0, Comment(rawValue: spreadMsg))

    let timeMsg =
      "5 classified traces took \(String(format: "%.2f", elapsed))s. "
      + "After async I/O, should be <3s (parallel)."
    #expect(elapsed < 3.0, Comment(rawValue: timeMsg))
  }

  /// Test 3: Multipath discovery runs flows sequentially
  ///
  /// BOTTLENECK: MultipathDiscovery.discoverPaths() uses a `for` loop
  /// (line 285 in Multipath.swift) to execute flow variations serially.
  /// Each flow runs a full traceroute (~2s), so N flows = N*2s total.
  ///
  /// EXPECTED BEHAVIOR (after fix): Flows run in parallel via TaskGroup,
  /// so N flows complete in ~2s total (one traceroute duration)
  ///
  /// CURRENT BEHAVIOR: Will take ~N*2s (fully sequential)
  @Test(
    "Multipath flows execute sequentially not in parallel",
    .disabled(
      "Known bottleneck - requires parallel flow execution. See docs/development/SwiftFTR-Concurrency-Audit.md"
    ),
    .timeLimit(.minutes(2))
  )
  func testMultipathFlowsRunSequentially() async throws {
    let tracer = SwiftFTR(config: SwiftFTRConfig(maxHops: 15, maxWaitMs: 500))
    let multipathConfig = MultipathConfig(
      flowVariations: 10,  // 10 flows
      maxPaths: 16,
      earlyStopThreshold: 999,  // Disable early stopping
      timeoutMs: 500,
      maxHops: 15
    )

    let startTime = Date()
    let topology = try await tracer.discoverPaths(to: "8.8.8.8", config: multipathConfig)
    let elapsed = Date().timeIntervalSince(startTime)

    print(
      """
      Multipath Sequential Bottleneck Test:
        Flows: 10
        Time: \(String(format: "%.2f", elapsed))s
        Paths discovered: \(topology.uniquePathCount)

      EXPECTED (sequential): ~10-20s (10 flows × ~1-2s each)
      TARGET (parallel): ~2-3s (flows run concurrently)
      """
    )

    // This SHOULD pass after multipath parallelism is implemented
    // Currently EXPECTED TO FAIL showing sequential execution
    let msg =
      "10 flows took \(String(format: "%.2f", elapsed))s (sequential). "
      + "After parallelism, should be <5s."
    #expect(elapsed < 5.0, Comment(rawValue: msg))
  }

  /// Test 4: ASN cache shows acceptable performance under concurrent access
  ///
  /// BASELINE TEST: _ASNMemoryCache uses NSLock, which may show contention
  /// under heavy concurrent access. This test establishes baseline performance.
  ///
  /// EXPECTED BEHAVIOR (after fix): Actor-based cache should show similar
  /// or better performance with better safety guarantees
  ///
  /// CURRENT BEHAVIOR: Should pass but may show lock contention in profiling
  @Test(
    "ASN cache concurrent access baseline",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")),
    .timeLimit(.minutes(1))
  )
  func testASNCacheConcurrentAccess() async throws {
    // Create batch of IPs to resolve
    let ips = (1...50).map { "8.8.8.\($0)" }

    let startTime = Date()
    var taskTimes: [TimeInterval] = []

    // Launch 20 concurrent tasks hammering the cache
    try await withThrowingTaskGroup(of: TimeInterval.self) { group in
      for _ in 1...20 {
        group.addTask {
          let taskStart = Date()
          let resolver = CachingASNResolver(base: CymruDNSResolver())
          _ = try await resolver.resolve(ipv4Addrs: ips, timeout: 2.0)
          return Date().timeIntervalSince(taskStart)
        }
      }

      for try await taskTime in group {
        taskTimes.append(taskTime)
      }
    }

    let elapsed = Date().timeIntervalSince(startTime)
    let avgTaskTime = taskTimes.reduce(0, +) / Double(taskTimes.count)
    let maxTaskTime = taskTimes.max()!
    let minTaskTime = taskTimes.min()!

    print(
      """
      ASN Cache Concurrency Baseline:
        Total time: \(String(format: "%.2f", elapsed))s
        Avg task time: \(String(format: "%.2f", avgTaskTime))s
        Min task time: \(String(format: "%.2f", minTaskTime))s
        Max task time: \(String(format: "%.2f", maxTaskTime))s
        Task time spread: \(String(format: "%.2f", maxTaskTime - minTaskTime))s

      This establishes baseline for NSLock-based cache.
      After converting to actor, performance should remain similar or improve.
      """
    )

    // Relaxed assertion - just checking it completes in reasonable time
    // The real value is the baseline metrics for comparison
    let msg =
      "Cache stress test took \(String(format: "%.2f", elapsed))s. "
      + "Should complete in reasonable time (<30s)."
    #expect(elapsed < 30.0, Comment(rawValue: msg))
  }
}
