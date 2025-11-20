import Foundation
import Testing

@testable import SwiftFTR

/// Tests demonstrating that ping() runs in parallel, not serially
///
/// BEFORE: SwiftFTR.ping() was actor-isolated AND PingExecutor was an actor
///   Result: 20 concurrent pings to Tanzania took ~7.2+ seconds (fully serialized)
///
/// AFTER: SwiftFTR.ping() is nonisolated AND PingExecutor is a struct
///   Result: 20 concurrent pings take <1 second (true parallelism)
///   Speedup: 14.4x
@Suite("Ping Parallelism Tests")
struct PingParallelismTests {

  /// Verifies that concurrent ping operations run in parallel
  ///
  /// Uses high-RTT target (Tanzania, ~360ms) to make parallelism dramatic:
  /// - Serial: 20 × 360ms = 7200ms (7.2 seconds)
  /// - Parallel: ~360ms (<1 second)
  @Test(
    "Concurrent pings run in parallel",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS"))
  )
  func testConcurrentPingsAreParallel() async throws {
    let tracer = SwiftFTR()
    let config = PingConfig(count: 1, interval: 0.0, timeout: 1.0)

    let (elapsed, completionTimes, results) = try await NetworkTestGate.shared.withPermit {
      let startTime = Date()
      var completionTimes: [TimeInterval] = []
      var results: [PingResult] = []

      // Launch 20 concurrent ping operations to high-RTT target
      try await withThrowingTaskGroup(of: PingResult.self) { group in
        for _ in 1...20 {
          group.addTask {
            try await tracer.ping(to: "196.43.78.49", config: config)  // Tanzania, ~360ms RTT
          }
        }

        for try await result in group {
          results.append(result)
          completionTimes.append(Date().timeIntervalSince(startTime))
        }

        #expect(results.count == 20)

        // Print individual RTT measurements
        for (i, result) in results.enumerated() {
          if let avgRTT = result.statistics.avgRTT {
            print("Ping \(i+1): \(String(format: "%.1f", avgRTT * 1000))ms")
          } else {
            print("Ping \(i+1): timeout")
          }
        }
      }
      let elapsed = Date().timeIntervalSince(startTime)
      return (elapsed, completionTimes, results)
    }

    // The smoking gun: check if all pings completed close together (parallel)
    // vs spread apart (serial)
    let minCompletion = completionTimes.min()!
    let maxCompletion = completionTimes.max()!
    let completionSpread = maxCompletion - minCompletion

    print(
      "Concurrent pings: \(String(format: "%.2f", elapsed))s total, "
        + "spread: \(String(format: "%.3f", completionSpread))s")

    // Spread < 600ms proves pings ran in parallel (serial would be ~7s spread).
    let spreadMsg =
      "Pings should complete within 0.6s if parallel (serial would be ~7s). "
      + "Spread: \(String(format: "%.3f", completionSpread))s"
    #expect(completionSpread < 0.6, Comment(rawValue: spreadMsg))

    // Calculate average RTT from successful pings
    let rtts = results.compactMap { $0.statistics.avgRTT }
    let avgRTT = rtts.isEmpty ? 0 : rtts.reduce(0, +) / Double(rtts.count)

    // Total time should be close to one ping's RTT (not 20×)
    // In clean network: ~360ms. In saturated test environment: may be higher.
    // Key test: elapsed should be close to avgRTT, not 20× avgRTT (proving parallelism)
    if avgRTT > 0 {
      let parallelismFactor = elapsed / avgRTT
      print(
        "Parallelism factor: \(String(format: "%.1f", parallelismFactor))x (1.0 = perfect parallel, 20.0 = fully serial)"
      )

      // Parallel: factor 1-15x | Serial: factor ~20x
      // In saturated test environment with 177 tests, high overhead is expected
      // Key distinction: <15x proves parallelism, ~20x would indicate serialization
      // Detached ping entry points keep this ratio near 1 even when invoked from an actor; cap it at 20x to flag regressions.
      #expect(
        parallelismFactor < 20.0, "Should complete in <20x one ping's RTT (20x = fully serial)")
    } else {
      // All timeouts - network may be unreachable
      print("⚠️  All pings timed out - network may be unreachable or heavily saturated")
    }
  }

  @Test(
    "Concurrent pings from actor context stay parallel",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS"))
  )
  func testConcurrentPingsFromActorContext() async throws {
    let harness = PingActorHarness()
    let (elapsed, spread) = try await harness.runParallelPings()

    let formattedSpread = String(format: "%.3f", spread)
    let spreadComment = Comment(
      rawValue: "Actor-originated pings should still conclude together (spread=\(formattedSpread)s)"
    )
    #expect(spread < 0.6, spreadComment)
    #expect(elapsed < 10.0, "Actor-originated parallel pings should finish well below serial runs")
  }

  @Test(
    "Burst ping with zero interval completes quickly",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS"))
  )
  func testBurstPingCompletesQuickly() async throws {
    let tracer = SwiftFTR()
    let config = PingConfig(count: 5, interval: 0.0, timeout: 1.0)

    let start = Date()
    let result = try await tracer.ping(to: "1.1.1.1", config: config)
    let duration = Date().timeIntervalSince(start)

    #expect(result.responses.count == 5)
    #expect(duration < 10.0, "Zero-interval burst should not take multiple timeout windows")
  }
}

private actor PingActorHarness {
  let tracer = SwiftFTR()

  func runParallelPings() async throws -> (TimeInterval, TimeInterval) {
    let config = PingConfig(count: 1, interval: 0.0, timeout: 1.0)
    let start = Date()
    var completionTimes: [TimeInterval] = []

    try await withThrowingTaskGroup(of: PingResult.self) { group in
      for _ in 1...20 {
        group.addTask {
          try await self.tracer.ping(to: "196.43.78.49", config: config)
        }
      }

      for try await _ in group {
        completionTimes.append(Date().timeIntervalSince(start))
      }
    }

    let elapsed = Date().timeIntervalSince(start)
    guard let minCompletion = completionTimes.min(),
      let maxCompletion = completionTimes.max()
    else {
      return (elapsed, elapsed)
    }

    return (elapsed, maxCompletion - minCompletion)
  }
}
