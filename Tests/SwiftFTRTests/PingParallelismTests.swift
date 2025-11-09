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

    let startTime = Date()
    var completionTimes: [TimeInterval] = []

    // Launch 20 concurrent ping operations to high-RTT target
    try await withThrowingTaskGroup(of: PingResult.self) { group in
      for _ in 1...20 {
        group.addTask {
          try await tracer.ping(to: "196.43.78.49", config: config)  // Tanzania, ~360ms RTT
        }
      }

      var results: [PingResult] = []
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

    // The smoking gun: check if all pings completed close together (parallel)
    // vs spread apart (serial)
    let minCompletion = completionTimes.min()!
    let maxCompletion = completionTimes.max()!
    let completionSpread = maxCompletion - minCompletion

    print(
      "Concurrent pings: \(String(format: "%.2f", elapsed))s total, "
        + "spread: \(String(format: "%.3f", completionSpread))s")

    // All 20 pings should complete within 500ms of each other if parallel
    // (Before fix: spread was ~7+ seconds for serial execution)
    let spreadMsg =
      "Pings should complete within 500ms if parallel. "
      + "Spread: \(String(format: "%.3f", completionSpread))s"
    #expect(completionSpread < 0.5, Comment(rawValue: spreadMsg))

    // Total time should be close to one ping (~300ms RTT), not 20× (~6s)
    // With 1s timeout, each ping can take up to 1s. If parallel, all 20 should complete in ~1s.
    // If serial, would take ~20s. Allow 2s for network variance.
    let timeMsg =
      "20 parallel pings should take <2s (all concurrent), not >10s (serialized). "
      + "Actual: \(String(format: "%.2f", elapsed))s"
    #expect(elapsed < 2.0, Comment(rawValue: timeMsg))
  }
}
