import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// Enrichment under failure, without cancellation: each stalled or failing dependency must cost
/// no more than its configured budget, and the result must degrade rather than fail.
///
/// Stalls are held by a gate for up to 20 s. An operation that honours its budget returns while
/// the stall is still in force, so the tests assert that rather than an elapsed time.
@Suite("FaultInjection: enrichment budgets")
struct FaultInjectionEnrichmentTests {
  /// How long a stalled operation may run before it is reported as waiting for the stall: the
  /// default public-IP budget, which every test here configures well below.
  static let watchdog = SwiftFTRConfig.defaultPublicIPDiscoveryTimeout

  @Test("Stalled public-IP discovery costs its budget and the trace still classifies")
  func publicIPStallBounded() async throws {
    let gate = StallGate()
    defer { gate.open() }
    let attempts = FaultCounter()
    let finished = FaultCounter()
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 2, name: "test.pip-stall")
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    // Short against the watchdog; long enough that load cannot spend it before the question.
    let budget: TimeInterval = 2
    let tracer = offlineTracer(
      SwiftFTRConfig(
        maxHops: 4, maxWaitMs: 2000, noReverseDNS: true, publicIPDiscoveryTimeout: budget))
    // A blocking attempt that stalls in its executor slot, as a STUN `recv` does.
    let discovery: TestSeams.DiscoverPublicIP = { _ in
      attempts.increment()
      return try await runDetachedBlockingIO {
        gate.wait(limit: 20)
        finished.increment()
        throw PublicIPError.allMethodsFailed(stunError: "stalled", dnsError: "stalled")
      }
    }

    let trace = try await TestSeams.$blockingIOExecutor.withValue(executor) {
      try await TestSeams.$discoverPublicIP.withValue(discovery) {
        try await network.install {
          // A trace that ignored its budget would wait at least the default one.
          try await measure(within: Self.watchdog) {
            try await tracer.traceClassified(to: "fake.test", resolver: EmptyASNResolver())
          }.0
        }
      }
    }

    #expect(attempts.value > 0, "discovery was never attempted")
    #expect(finished.value == 0, "the trace waited for a stalled discovery to end")
    #expect(trace.publicIP == nil)
    #expect(trace.hops.count == 2)
    #expect(
      await tracer.publicIP(for: .v4)?.address == nil, "a failed discovery must not be cached")
  }

  @Test("A failed public-IP discovery is attempted once per classified trace")
  func publicIPDiscoveredOnce() async throws {
    let attempts = FaultCounter()
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 2, name: "test.pip-once")
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    // The substitute fails at once; the budget is long so load cannot spend it before the question.
    let tracer = offlineTracer(
      SwiftFTRConfig(maxHops: 4, maxWaitMs: 2000, noReverseDNS: true, publicIPDiscoveryTimeout: 60)
    )
    let discovery: TestSeams.DiscoverPublicIP = { _ in
      attempts.increment()
      throw PublicIPError.allMethodsFailed(stunError: "down", dnsError: "down")
    }

    _ = try await TestSeams.$blockingIOExecutor.withValue(executor) {
      try await TestSeams.$discoverPublicIP.withValue(discovery) {
        try await network.install {
          try await tracer.traceClassified(to: "fake.test", resolver: EmptyASNResolver())
        }
      }
    }
    #expect(attempts.value == 1, "discovery ran \(attempts.value) times")
  }

  @Test("Public-IP discovery that finishes after a network change is neither returned nor cached")
  func staleDiscoveryDiscarded() async throws {
    let gate = StallGate()
    defer { gate.open() }
    let entered = FaultCounter()
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 2, name: "test.pip-stale")
    let tracer = offlineTracer(SwiftFTRConfig(noReverseDNS: true, publicIPDiscoveryTimeout: 5))
    let discovery: TestSeams.DiscoverPublicIP = { _ in
      entered.increment()
      await gate.waitAsync(limit: 5)
      return STUNPublicIP(ip: "8.8.4.99")
    }

    await TestSeams.$blockingIOExecutor.withValue(executor) {
      await TestSeams.$discoverPublicIP.withValue(discovery) {
        let lookup = Task {
          await tracer.effectivePublicIPv4 {
            try? await tracer.discoverPublicIP()
          }
        }
        #expect(await eventually(within: Self.watchdog) { entered.value > 0 })
        // The network-change path, not the direct invalidation one (CacheGenerationTests covers that).
        await tracer.networkChanged()
        gate.open()
        let observed = await lookup.value
        #expect(observed == nil, "stale address \(observed ?? "") escaped")
        #expect(await tracer.publicIP(for: .v4)?.address == nil)
      }
    }
  }

  @Test("Each stalled reverse-DNS wave costs its deadline once, and two open the breaker")
  func reverseDNSStallBounded() async throws {
    // A daemon that takes every question and never answers, behind the real lookup and its real
    // deadline timer, as a resolver that stopped answering looks. Every hop of the fake path
    // answers from one address, so each trace asks one question.
    let daemon = FakeDNSService(deadline: .timer)
    let rdns = RDNSCache(
      lookupDeadline: 0.3, limiter: _ConcurrencySemaphore(maxConcurrent: 32))
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 3))
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 4, maxWaitMs: 2000), rdns: rdns)

    try await daemon.install {
      try await network.install {
        let (first, _) = try await measure(within: Self.watchdog) {
          try await tracer.trace(to: "fake.test")
        }
        #expect(daemon.startedCount == 1, "one trace asked \(daemon.startedCount) questions")
        #expect(first.reached)
        #expect(first.hops.allSatisfy { $0.hostname == nil })
        #expect(await rdns.isSuppressingLookups == false, "one stall opened the breaker")

        // Nothing was cached, so the second trace asks again, and its stall is the second.
        _ = try await measure(within: Self.watchdog) { try await tracer.trace(to: "fake.test") }
        #expect(daemon.startedCount == 2)
        let before = daemon.startedCount
        _ = try await measure(within: Self.watchdog) { try await tracer.trace(to: "fake.test") }
        let unseen = try await measure(within: Self.watchdog) { await rdns.lookup("198.51.100.77") }
        #expect(unseen.0 == nil)
        #expect(daemon.startedCount == before, "the breaker should suppress further lookups")
      }
    }
    #expect(await rdns.isSuppressingLookups)
    // Every query the stalled wave asked was stopped, not abandoned.
    #expect(await eventually(within: Self.watchdog) { daemon.liveCount == 0 })
    #expect(daemon.misuse.unknown == 0 && daemon.misuse.double == 0)
  }

  @Test("discoverPaths honours the configured public-IP budget")
  func multipathHonoursPublicIPBudget() async throws {
    let gate = StallGate()
    defer { gate.open() }
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 4, name: "test.mp-pip")
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    // Short against the watchdog; long enough that load cannot spend it before the question.
    let budget: TimeInterval = 2
    let tracer = offlineTracer(
      SwiftFTRConfig(maxHops: 4, noReverseDNS: true, publicIPDiscoveryTimeout: budget))
    let attempts = FaultCounter()
    let discovery: TestSeams.DiscoverPublicIP = { _ in
      attempts.increment()
      return try await runDetachedBlockingIO {
        gate.wait(limit: 20)
        throw PublicIPError.allMethodsFailed(stunError: "stalled", dnsError: "stalled")
      }
    }
    let config = MultipathConfig(
      flowVariations: 1, maxPaths: 4, earlyStopThreshold: 1, timeoutMs: 2000, maxHops: 4)

    let topology = try await TestSeams.$blockingIOExecutor.withValue(executor) {
      try await TestSeams.$discoverPublicIP.withValue(discovery) {
        try await network.install {
          // Ignoring the configured budget means waiting the default one at least.
          try await measure(within: Self.watchdog) {
            try await tracer.discoverPaths(to: "fake.test", config: config)
          }.0
        }
      }
    }
    #expect(attempts.value > 0, "discovery was never attempted")
    #expect(topology.paths.count == 1)
  }

  /// Who ends a trace stalled in forward resolution.
  enum ResolutionCanceller: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case taskCancel, cancelActiveTraces
    var testDescription: String { rawValue }
  }

  @Test(
    "A stalled forward resolution does not hold the tracer or its cancellation",
    .disabled(
      "finding 5 in docs/ROBUSTNESS-TESTING.md: getaddrinfo runs synchronously on the actor"),
    arguments: ResolutionCanceller.allCases)
  func forwardResolutionStall(canceller: ResolutionCanceller) async throws {
    // One gated trace per cancellation source, so each source is the only thing that can end it.
    let gate = StallGate()
    defer { gate.open() }
    let entered = FaultCounter()
    let stall: TestSeams.ResolveHost = { host, _ in
      entered.increment()
      gate.wait(limit: 5)
      throw TracerouteError.resolutionFailed(host: host, details: "stalled")
    }
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 4, maxWaitMs: 1000, noReverseDNS: true))

    await TestSeams.$resolveHost.withValue(stall) {
      let task = Task { try await tracer.trace(to: "slow-resolver.test") }
      #expect(await eventually(within: 2) { entered.value > 0 })

      // The cancellation call itself must not wait for the resolver: the tracer's, because it is
      // a call on the actor the resolver holds; the caller's, because it is synchronous.
      let (_, callLag) = await measure {
        switch canceller {
        case .taskCancel: task.cancel()
        case .cancelActiveTraces: await tracer.cancelActiveTraces()
        }
      }
      #expect(callLag < 0.5, "cancelling took \(callLag)s behind a resolver stall")

      let cancelledAt = monotonicNow()
      let outcome = await task.result
      let lag = monotonicNow() - cancelledAt
      #expect(lag < 0.5, "a trace stalled in resolution returned \(lag)s after cancellation")
      switch (canceller, outcome) {
      case (.taskCancel, .failure(let error)):
        #expect(error is CancellationError, "\(error)")
      case (.cancelActiveTraces, .failure(TracerouteError.cancelled)):
        break
      default:
        Issue.record("\(canceller): \(outcome)")
      }
    }
  }

  // MARK: A full blocking-I/O executor

  /// Fills a private single-slot executor with a call that holds it for up to 20 s. Returns the
  /// gate that releases it and a counter that reaches 1 once it has let go of the slot.
  private static func occupy(_ executor: BlockingIOExecutor) async -> (StallGate, FaultCounter) {
    let gate = StallGate()
    let occupied = FaultCounter()
    let released = FaultCounter()
    Task {
      try? await executor.run(priority: .userInitiated) {
        occupied.increment()
        gate.wait(limit: 20)
        released.increment()
      }
    }
    let started = await eventually(within: Self.watchdog) { occupied.value > 0 }
    #expect(started, "the occupant never took the executor's slot")
    return (gate, released)
  }

  @Test("A classified trace stays within its budgets when every executor slot is held")
  func classifiedTraceWithFullExecutor() async throws {
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.full-classified")
    let (gate, released) = await Self.occupy(executor)
    defer { gate.open() }
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    // A STUN attempt queues behind the occupant, and only its deadline ends it. Reverse DNS needs
    // no slot: it asks the daemon, which here never answers, so its own deadline ends it.
    let daemon = FakeDNSService(deadline: .timer)
    let rdns = RDNSCache(lookupDeadline: 0.3, limiter: _ConcurrencySemaphore(maxConcurrent: 32))
    let tracer = offlineTracer(
      SwiftFTRConfig(maxHops: 4, maxWaitMs: 2000, publicIPDiscoveryTimeout: 0.3), rdns: rdns)
    // Discovery whose answer needs an executor slot, as a STUN attempt does.
    let discovery: TestSeams.DiscoverPublicIP = { _ in
      try await runDetachedBlockingIO { STUNPublicIP(ip: "8.8.4.7") }
    }

    let trace = try await TestSeams.$blockingIOExecutor.withValue(executor) {
      try await TestSeams.$discoverPublicIP.withValue(discovery) {
        try await daemon.install {
          try await network.install {
            try await measure(within: Self.watchdog) {
              try await tracer.traceClassified(to: "fake.test", resolver: EmptyASNResolver())
            }.0
          }
        }
      }
    }
    #expect(released.value == 0, "the trace waited for the occupant to free its slot")
    #expect(daemon.startedCount > 0, "reverse DNS was never asked")
    #expect(trace.publicIP == nil, "discovery cannot have run with no free slot")
    #expect(trace.hops.count == 2)
  }

  @Test("An invalid DNS query is rejected as invalid even when no executor slot is free")
  func invalidDNSQueryWithFullExecutor() async throws {
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.full-dns-input")
    let (gate, released) = await Self.occupy(executor)
    defer { gate.open() }

    // Each query must fail without waiting for the occupant, so under a watchdog shorter than
    // the occupant's hold. One that queued would fail with WatchdogExpired instead.
    let cases: [(String, String, String?, @Sendable (Error) -> Bool)] = [
      (
        "example..com", "127.0.0.1", nil,
        { if case DNSError.invalidHostname = $0 { true } else { false } }
      ),
      (
        "example.com", "not-an-ip", nil, { if case DNSError.invalidIP = $0 { true } else { false } }
      ),
      // An IPv6 source for an IPv4 server can never bind.
      (
        "example.com", "127.0.0.1", "::1",
        { if case DNSError.bindFailed = $0 { true } else { false } }
      ),
    ]
    await TestSeams.$blockingIOExecutor.withValue(executor) {
      for (name, server, sourceIP, matches) in cases {
        do {
          _ = try await measure(within: Self.watchdog) {
            try await queryA(hostname: name, server: server, timeout: 0.05, sourceIP: sourceIP)
          }
          Issue.record("\(name) via \(server): succeeded")
        } catch {
          #expect(matches(error), "\(name) via \(server) from \(sourceIP ?? "any"): \(error)")
        }
      }
    }
    #expect(released.value == 0, "a query waited for the occupant to free its slot")
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

    // Traces on one tracer are serialized by the actor only while they set up; their receive
    // windows overlap. Sixteen serialized windows would take 16 times the configured wait.
    let serialized = 16 * TimeInterval(config.maxWaitMs) / 1000
    let (outcomes, _) = try await measure(within: serialized) {
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
    #expect(await shared.activeTraces.isEmpty)
    for tracer in others { #expect(await tracer.activeTraces.isEmpty) }
  }
}
