import Foundation
import Testing

@testable import SwiftFTR

/// End-to-end bounds on `traceClassified`, which reaches every enrichment path at once.
///
/// The mechanisms are covered offline by `BlockingIOCancellationTests` and `RDNSSuppressionTests`.
/// These tests exercise the assembled pipeline, so they need a working network and are skipped
/// when `SKIP_NETWORK_TESTS` is set.
@Suite(.serialized)
struct ClassifiedTraceBoundsTests {
  private static var skipsNetwork: Bool {
    ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")
  }

  @Test(
    "A cancelled classified trace terminates promptly",
    .enabled(if: !ClassifiedTraceBoundsTests.skipsNetwork))
  func cancellationTerminatesPromptly() async throws {
    try await NetworkTestGate.shared.withPermit {
      // Force the slow path: no public-IP override and reverse DNS on, so the trace exercises
      // STUN discovery and a cold reverse-DNS wave rather than short-circuiting on cache hits.
      let tracer = SwiftFTR(config: SwiftFTRConfig(maxHops: 40, maxWaitMs: 1000))

      let start = monotonicNow()
      let victim = Task { try await tracer.traceClassified(to: "1.1.1.1") }
      try await Task.sleep(nanoseconds: 100_000_000)
      victim.cancel()

      _ = try? await victim.value
      let elapsed = monotonicNow() - start

      // Before the executor honored cancellation, this returned only when a slot freed. The bound
      // is deliberately loose: the point is "seconds, not a watchdog timeout", not a tight number.
      #expect(elapsed < 5.0, "cancelled traceClassified took \(elapsed)s to return")
    }
  }

  @Test(
    "A classified trace completes within a budget derived from its configuration",
    .enabled(if: !ClassifiedTraceBoundsTests.skipsNetwork))
  func completesWithinConfiguredBudget() async throws {
    try await NetworkTestGate.shared.withPermit {
      let config = SwiftFTRConfig(
        maxHops: 40,
        maxWaitMs: 1000,
        rdnsLookupTimeout: 2.0,
        publicIPDiscoveryTimeout: 3.0
      )
      let tracer = SwiftFTR(config: config)

      let start = monotonicNow()
      _ = try await tracer.traceClassified(to: "1.1.1.1")
      let elapsed = monotonicNow() - start

      // Discovery (3s) + probe phase (1s) + reverse DNS (2s, concurrent across hops) + ASN work,
      // with headroom. The value that matters is that it is derived from configuration at all:
      // before these bounds existed, no configuration capped the enrichment phase.
      #expect(elapsed < 20.0, "classified trace took \(elapsed)s against a ~6s configured budget")
    }
  }
}
