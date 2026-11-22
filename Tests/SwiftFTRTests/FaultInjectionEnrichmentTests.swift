import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// Enrichment under failure, without cancellation: each stalled or failing dependency must cost
/// no more than its configured budget, and the result must degrade rather than fail.
@Suite("FaultInjection: enrichment budgets")
struct FaultInjectionEnrichmentTests {

  @Test("Stalled public-IP discovery costs its budget and the trace still classifies")
  func publicIPStallBounded() async throws {
    let gate = StallGate()
    defer { gate.open() }
    let attempts = FaultCounter()
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 2, name: "test.pip-stall")
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    let budget: TimeInterval = 0.3
    let tracer = offlineTracer(
      SwiftFTRConfig(
        maxHops: 4, maxWaitMs: 2000, noReverseDNS: true, publicIPDiscoveryTimeout: budget))
    let discovery: TestSeams.DiscoverPublicIPv4 = {
      attempts.increment()
      gate.wait(limit: 20)
      throw PublicIPError.allMethodsFailed(stunError: "stalled", dnsError: "stalled")
    }

    let (trace, elapsed) = try await measure {
      try await TestSeams.$blockingIOExecutor.withValue(executor) {
        try await TestSeams.$discoverPublicIPv4.withValue(discovery) {
          try await network.install {
            try await tracer.traceClassified(to: "fake.test", resolver: EmptyASNResolver())
          }
        }
      }
    }

    #expect(trace.publicIP == nil)
    #expect(trace.hops.count == 2)
    // Today a failed discovery is retried by the classifier, so the bound is two budgets plus the
    // early-completing probe phase (finding 6 in docs/ROBUSTNESS-TESTING.md).
    #expect(
      elapsed < 2 * budget + 1.0, "classified trace took \(elapsed)s with a \(budget)s budget")
    #expect(await tracer.publicIP == nil, "a failed discovery must not be cached")
  }

  @Test(
    "A failed public-IP discovery is attempted once per classified trace",
    .disabled("finding 6 in docs/ROBUSTNESS-TESTING.md: the classifier rediscovers"))
  func publicIPDiscoveredOnce() async throws {
    let attempts = FaultCounter()
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 2, name: "test.pip-once")
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    let tracer = offlineTracer(
      SwiftFTRConfig(maxHops: 4, maxWaitMs: 2000, noReverseDNS: true, publicIPDiscoveryTimeout: 0.3)
    )
    let discovery: TestSeams.DiscoverPublicIPv4 = {
      attempts.increment()
      throw PublicIPError.allMethodsFailed(stunError: "down", dnsError: "down")
    }

    _ = try await TestSeams.$blockingIOExecutor.withValue(executor) {
      try await TestSeams.$discoverPublicIPv4.withValue(discovery) {
        try await network.install {
          try await tracer.traceClassified(to: "fake.test", resolver: EmptyASNResolver())
        }
      }
    }
    #expect(attempts.value == 1)
  }

  @Test("Public-IP discovery that finishes after a network change is neither returned nor cached")
  func staleDiscoveryDiscarded() async throws {
    let gate = StallGate()
    defer { gate.open() }
    let entered = FaultCounter()
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 2, name: "test.pip-stale")
    let tracer = offlineTracer(SwiftFTRConfig(noReverseDNS: true, publicIPDiscoveryTimeout: 5))
    let discovery: TestSeams.DiscoverPublicIPv4 = {
      entered.increment()
      gate.wait(limit: 5)
      return STUNPublicIP(ip: "198.51.100.99")
    }

    try await TestSeams.$blockingIOExecutor.withValue(executor) {
      try await TestSeams.$discoverPublicIPv4.withValue(discovery) {
        let lookup = Task {
          await tracer.effectivePublicIPForClassification {
            try? await tracer.discoverPublicIP()
          }
        }
        #expect(await eventually(within: 2) { entered.value > 0 })
        await tracer.invalidatePublicIP()
        gate.open()
        let observed = await lookup.value
        #expect(observed == nil, "stale address \(observed ?? "") escaped")
        #expect(await tracer.publicIP == nil)
      }
    }
  }

  @Test("A stalled reverse-DNS wave costs its deadline once, then the breaker skips it")
  func reverseDNSStallBounded() async throws {
    let gate = StallGate()
    defer { gate.open() }
    let lookups = FaultCounter()
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 4, name: "test.rdns-stall")
    let deadline: TimeInterval = 0.3
    let rdns = RDNSCache(lookupDeadline: deadline) { _ in
      lookups.increment()
      return try? await runDetachedBlockingIO(priority: .background, deadline: deadline) {
        gate.wait(limit: 20)
        return String?.none
      }
    }
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 3))
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 4, maxWaitMs: 2000), rdns: rdns)

    try await TestSeams.$blockingIOExecutor.withValue(executor) {
      try await network.install {
        let (first, firstElapsed) = try await measure { try await tracer.trace(to: "fake.test") }
        #expect(first.reached)
        #expect(first.hops.allSatisfy { $0.hostname == nil })
        #expect(firstElapsed < deadline + 1.0, "first trace took \(firstElapsed)s")

        let before = lookups.value
        let (_, secondElapsed) = try await measure { try await tracer.trace(to: "fake.test") }
        #expect(lookups.value == before, "the breaker should suppress further lookups")
        #expect(secondElapsed < 0.5)
      }
    }
    #expect(await rdns.isSuppressingLookups)
  }

  @Test("discoverPaths honours the configured public-IP budget")
  func multipathHonoursPublicIPBudget() async throws {
    let gate = StallGate()
    defer { gate.open() }
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 4, name: "test.mp-pip")
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    let budget: TimeInterval = 0.3
    let tracer = offlineTracer(
      SwiftFTRConfig(maxHops: 4, noReverseDNS: true, publicIPDiscoveryTimeout: budget))
    let discovery: TestSeams.DiscoverPublicIPv4 = {
      gate.wait(limit: 20)
      throw PublicIPError.allMethodsFailed(stunError: "stalled", dnsError: "stalled")
    }
    let config = MultipathConfig(
      flowVariations: 1, maxPaths: 4, earlyStopThreshold: 1, timeoutMs: 2000, maxHops: 4)

    let (topology, elapsed) = try await measure {
      try await TestSeams.$blockingIOExecutor.withValue(executor) {
        try await TestSeams.$discoverPublicIPv4.withValue(discovery) {
          try await network.install {
            try await tracer.discoverPaths(to: "fake.test", config: config)
          }
        }
      }
    }
    #expect(topology.paths.count == 1)
    // One flow, so at most two discovery budgets (finding 6) plus an early-completing trace. The
    // default budget is 6 s, so ignoring the configured one costs far more than this.
    #expect(elapsed < 2 * budget + 1.5, "discoverPaths took \(elapsed)s with a \(budget)s budget")
  }

  @Test(
    "A stalled forward resolution does not hold the tracer or its cancellation",
    .disabled(
      "finding 5 in docs/ROBUSTNESS-TESTING.md: getaddrinfo runs synchronously on the actor"))
  func forwardResolutionStall() async throws {
    let gate = StallGate()
    defer { gate.open() }
    let entered = FaultCounter()
    let stall: TestSeams.ResolveHost = { host, _ in
      entered.increment()
      gate.wait(limit: 5)
      throw TracerouteError.resolutionFailed(host: host, details: "stalled")
    }
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 4, maxWaitMs: 1000, noReverseDNS: true))

    try await TestSeams.$resolveHost.withValue(stall) {
      let task = Task { try await tracer.trace(to: "slow-resolver.test") }
      #expect(await eventually(within: 2) { entered.value > 0 })

      // Any other call on the tracer must not wait for the resolver.
      let (_, actorLag) = await measure { await tracer.cancelActiveTraces() }
      #expect(actorLag < 0.5, "the tracer was unavailable for \(actorLag)s behind a resolver stall")

      let cancelledAt = monotonicNow()
      task.cancel()
      _ = try? await task.value
      let lag = monotonicNow() - cancelledAt
      #expect(lag < 0.5, "a trace stalled in resolution returned \(lag)s after cancellation")
    }
  }

  // MARK: Concurrency under faults

  @Test("Many concurrent traces on one tracer and across tracers all finish under faults")
  func concurrentTracesUnderFaults() async throws {
    // Roughly a third of probes go unanswered, a third are answered late or after garbage, and
    // the rest normally, decided per probe from its sequence and identifier.
    let network = try FakeICMPNetwork { probe in
      let roll = (Int(probe.identifier) &+ Int(probe.sequence) &* 7) % 3
      let valid =
        probe.sequence < 3
        ? ICMPWire.timeExceeded(family: AF_INET, id: probe.identifier, seq: probe.sequence)
        : ICMPWire.echoReply(family: AF_INET, id: probe.identifier, seq: probe.sequence)
      switch roll {
      case 0: return []
      case 1: return [.init([0x0B, 0, 0]), .init(valid, after: 0.05)]
      default: return [.init(valid)]
      }
    }
    defer { network.stop() }
    let config = SwiftFTRConfig(maxHops: 5, maxWaitMs: 500, noReverseDNS: true)
    let shared = offlineTracer(config)
    let others = (0..<4).map { _ in offlineTracer(config) }

    let (outcomes, elapsed) = await measure {
      await network.install {
        await withTaskGroup(of: String.self) { group in
          for _ in 0..<16 {
            group.addTask {
              do {
                _ = try await shared.trace(to: "fake.test")
                return "ok"
              } catch { return "\(error)" }
            }
          }
          for tracer in others {
            for _ in 0..<4 {
              group.addTask {
                do {
                  _ = try await tracer.traceClassified(
                    to: "fake.test", resolver: EmptyASNResolver())
                  return "ok"
                } catch TracerouteError.cancelled {
                  return "cancelled"
                } catch { return "\(error)" }
              }
            }
          }
          // A network change lands on every tracer mid-flight.
          group.addTask {
            try? await Task.sleep(nanoseconds: 100_000_000)
            for tracer in others { await tracer.networkChanged() }
            return "ok"
          }
          var results: [String] = []
          for await outcome in group { results.append(outcome) }
          return results
        }
      }
    }

    #expect(outcomes.count == 33)
    #expect(
      outcomes.allSatisfy { $0 == "ok" || $0 == "cancelled" },
      "unexpected outcomes: \(outcomes.filter { $0 != "ok" && $0 != "cancelled" })")
    // Traces on one tracer are serialized by the actor only while they set up; their receive
    // windows overlap. Sixteen serialized windows would take 8 s.
    #expect(elapsed < 4.0, "33 concurrent operations took \(elapsed)s")
    #expect(await shared.activeTraces.isEmpty)
    for tracer in others { #expect(await tracer.activeTraces.isEmpty) }
  }
}
