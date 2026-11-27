import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// `SwiftFTRConfig.resolutionTimeout` bounds every operation's resolution, and `discoverPaths`
/// resolves its target once, before its public-IP question, for every flow
/// (docs/BLOCKING-IO.md, Resolution Off The Actor, decision 7). Stalled lookups wait on a gate that
/// holds for three times the watchdog.
@Suite("Resolution budget and resolving once")
struct ResolutionBudgetTests {
  static let watchdog: TimeInterval = 20
  static let hold: TimeInterval = 60

  enum Operation: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case trace, traceClassified, traceStream, ping
    var testDescription: String { rawValue }

    func run(_ tracer: SwiftFTR, to host: String) async throws {
      switch self {
      case .trace: _ = try await tracer.trace(to: host)
      case .traceClassified:
        _ = try await tracer.traceClassified(to: host, resolver: EmptyASNResolver())
      case .traceStream: for try await _ in tracer.traceStream(to: host) {}
      case .ping: _ = try await tracer.ping(to: host, config: PingConfig(count: 1))
      }
    }
  }

  /// A public-IP resolver that counts its questions and has no answer.
  struct CountingResolver: PublicIPResolver {
    let asked: FaultCounter
    func publicIP(for request: PublicIPRequest) async throws -> PublicIPObservation? {
      asked.increment()
      return nil
    }
  }

  // MARK: The option

  @Test(
    "The configured budget, not the default, ends each operation's wait",
    arguments: Operation.allCases)
  func budgetReachesEachOperation(operation: Operation) async throws {
    let gate = StallGate()
    defer { gate.open() }
    let entered = FaultCounter()
    let clock = MovableClock()
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.budget-reach")
    let stall: TestSeams.ResolveHost = { host, _ in
      entered.increment()
      gate.wait(limit: Self.hold)
      throw TracerouteError.resolutionFailed(host: host, details: "stalled")
    }
    let tracer = offlineTracer(
      SwiftFTRConfig(maxHops: 2, noReverseDNS: true, resolutionTimeout: 5))

    let outcome = try await TestSeams.$blockingIOExecutor.withValue(executor) {
      try await TestSeams.$monotonicClock.withValue(clock.now) {
        try await TestSeams.$resolveHost.withValue(stall) {
          let task = Task { try await operation.run(tracer, to: "gated.test") }
          #expect(await eventually(within: Self.watchdog) { entered.value == 1 })
          // Past the configured 5 s, well short of the 20 s default.
          return try await measure(within: Self.watchdog) {
            clock.jump(by: 6)
            return await task.result
          }.0
        }
      }
    }
    guard case .failure(TracerouteError.resolutionFailed(_, let details)) = outcome else {
      Issue.record("\(operation): expected the resolution timeout, got \(outcome)")
      return
    }
    #expect(details == "timed out")
  }

  @Test(
    "A resolution budget that is not finite and positive is rejected before anything resolves",
    arguments: [0, -1, TimeInterval.nan, .infinity, TimeInterval(Int32.max) * 2])
  func invalidBudgetRejected(budget: TimeInterval) async throws {
    let consulted = FaultCounter()
    let seam: TestSeams.ResolveHost = { host, _ in
      consulted.increment()
      throw TracerouteError.resolutionFailed(host: host, details: "consulted")
    }
    let tracer = offlineTracer(
      SwiftFTRConfig(maxHops: 2, noReverseDNS: true, resolutionTimeout: budget))
    let config = MultipathConfig(flowVariations: 1, maxPaths: 1, earlyStopThreshold: 1)
    let calls: [(String, @Sendable () async throws -> Void)] = [
      ("trace", { _ = try await tracer.trace(to: "name.test") }),
      ("ping", { _ = try await tracer.ping(to: "name.test", config: PingConfig(count: 1)) }),
      ("discoverPaths", { _ = try await tracer.discoverPaths(to: "name.test", config: config) }),
    ]
    await TestSeams.$resolveHost.withValue(seam) {
      for (name, call) in calls {
        do {
          try await call()
          Issue.record("\(name) accepted resolutionTimeout \(budget)")
        } catch TracerouteError.invalidConfiguration(let reason) {
          #expect(reason.contains("resolutionTimeout"), "\(name): \(reason)")
        } catch {
          Issue.record("\(name) threw \(error) for resolutionTimeout \(budget)")
        }
      }
    }
    #expect(consulted.value == 0, "an operation resolved with an invalid budget")
  }

  @Test("Every published SwiftFTRConfig initializer keeps its meaning, with the 20 s budget")
  func initializerSelection() {
    // The initializers published before this option, used as function values with their types
    // stated: both must still bind, and to the default budget.
    let original:
      (
        Int, Int, Int, String?, Bool, Bool, TimeInterval?, Int?, TimeInterval?, TimeInterval?,
        String?, String?, ASNResolverStrategy, PreferredFamily
      ) -> SwiftFTRConfig = SwiftFTRConfig.init
    let withResolver:
      (
        Int, Int, Int, String?, Bool, Bool, TimeInterval?, Int?, TimeInterval?, TimeInterval?,
        String?, String?, ASNResolverStrategy, PreferredFamily, PublicIPResolverStrategy
      ) -> SwiftFTRConfig = SwiftFTRConfig.init
    let a = original(40, 1000, 56, nil, false, false, nil, nil, nil, nil, nil, nil, .dns, .auto)
    let b = withResolver(
      40, 1000, 56, nil, false, false, nil, nil, nil, nil, nil, nil, .dns, .auto, .disabled)
    let budgets = [
      a.resolutionTimeout, b.resolutionTimeout, SwiftFTRConfig().resolutionTimeout,
      SwiftFTRConfig(maxHops: 3, publicIPResolver: .disabled).resolutionTimeout,
    ]
    #expect(budgets == Array(repeating: 20, count: 4))
    #expect(SwiftFTRConfig.defaultResolutionTimeout == 20)
    let chosen = SwiftFTRConfig(maxHops: 3, resolutionTimeout: 7)
    #expect(chosen.resolutionTimeout == 7 && chosen.maxHops == 3)
  }

  // MARK: discoverPaths resolves once

  @Test("Every flow of a run probes the parent's one resolution and reports the caller's name")
  func discoverPathsResolvesOnce() async throws {
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    let calls = FaultCounter()
    let base = network.resolved
    // A name whose every lookup gives another address, as a round-robin record can.
    let rotating: TestSeams.ResolveHost = { _, _ in
      calls.increment()
      return ResolvedHost(
        family: base.family, address: base.address, addressLen: base.addressLen,
        canonical: "198.51.100.\(calls.value)")
    }
    let tracer = offlineTracer(
      SwiftFTRConfig(maxHops: 3, noReverseDNS: true), publicIP: "198.51.100.200")
    let config = MultipathConfig(
      flowVariations: 3, maxPaths: 8, earlyStopThreshold: 3, timeoutMs: 2000, maxHops: 3)

    let topology = try await network.install {
      try await TestSeams.$resolveHost.withValue(rotating) {
        try await measure(within: Self.watchdog) {
          try await tracer.discoverPaths(to: "rotating.test", config: config)
        }.0
      }
    }
    #expect(calls.value == 1, "the run resolved its target \(calls.value) times")
    #expect(topology.paths.count == 3)
    #expect(Set(topology.paths.map(\.trace.destinationIP)) == ["198.51.100.1"])
    #expect(topology.paths.allSatisfy { $0.trace.destinationHost == "rotating.test" })
    #expect(topology.destination == "rotating.test")
  }

  @Test("A target that does not resolve ends the run before its public-IP question")
  func unresolvableTargetAsksNothing() async throws {
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    let asked = FaultCounter()
    let nxdomain: TestSeams.ResolveHost = { host, _ in
      throw TracerouteError.resolutionFailed(host: host, details: "injected NXDOMAIN")
    }
    let tracer = offlineTracer(
      SwiftFTRConfig(
        maxHops: 3, noReverseDNS: true, publicIPResolver: .custom(CountingResolver(asked: asked))))
    let config = MultipathConfig(flowVariations: 2, maxPaths: 4, earlyStopThreshold: 2)

    let outcome = await network.install {
      await TestSeams.$resolveHost.withValue(nxdomain) {
        await resultOf { try await tracer.discoverPaths(to: "nowhere.test", config: config) }
      }
    }
    guard case .failure(TracerouteError.resolutionFailed(_, let details)) = outcome else {
      Issue.record("expected the resolution failure, got \(outcome)")
      return
    }
    #expect(details == "injected NXDOMAIN")
    #expect(asked.value == 0, "the caller's resolver was asked for a run that could not resolve")
    #expect(network.probes.value == 0)
  }

  @Test("A run's reported duration includes resolving its target")
  func durationIncludesResolution() async throws {
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 1))
    defer { network.stop() }
    let base = network.resolved
    let slow: TestSeams.ResolveHost = { _, _ in
      Thread.sleep(forTimeInterval: 0.3)  // in its executor slot, not on the cooperative pool
      return base
    }
    let tracer = offlineTracer(
      SwiftFTRConfig(maxHops: 2, noReverseDNS: true), publicIP: "198.51.100.200")
    let config = MultipathConfig(
      flowVariations: 1, maxPaths: 1, earlyStopThreshold: 1, timeoutMs: 2000, maxHops: 2)
    let topology = try await network.install {
      try await TestSeams.$resolveHost.withValue(slow) {
        try await measure(within: Self.watchdog) {
          try await tracer.discoverPaths(to: "slow.test", config: config)
        }.0
      }
    }
    #expect(topology.discoveryDuration >= 0.3, "\(topology.discoveryDuration) s omits the lookup")
  }

  @Test(
    "Cancellation during the run's one resolution reports who cancelled",
    arguments: [false, true])
  func cancelledDuringParentResolution(byTracer: Bool) async throws {
    let gate = StallGate()
    defer { gate.open() }
    let entered = FaultCounter()
    let asked = FaultCounter()
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.budget-cancel")
    let stall: TestSeams.ResolveHost = { host, _ in
      entered.increment()
      gate.wait(limit: Self.hold)
      throw TracerouteError.resolutionFailed(host: host, details: "stalled")
    }
    let tracer = offlineTracer(
      SwiftFTRConfig(
        maxHops: 3, noReverseDNS: true, publicIPResolver: .custom(CountingResolver(asked: asked))))

    let outcome = try await TestSeams.$blockingIOExecutor.withValue(executor) {
      try await TestSeams.$resolveHost.withValue(stall) {
        let task = Task { try await tracer.discoverPaths(to: "gated.test") }
        #expect(await eventually(within: Self.watchdog) { entered.value == 1 })
        return try await measure(within: Self.watchdog) {
          if byTracer { await tracer.cancelActiveTraces() } else { task.cancel() }
          return await task.result
        }.0
      }
    }
    switch (byTracer, outcome) {
    case (true, .failure(TracerouteError.cancelled)): break
    case (false, .failure(let error)) where error is CancellationError: break
    default: Issue.record("byTracer \(byTracer): \(outcome)")
    }
    #expect(asked.value == 0)
    #expect(await tracer.activeTraces.isEmpty)
  }
}
