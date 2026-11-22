import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// Cancellation, `networkChanged()` and `cancelActiveTraces()` arriving at every phase of every
/// operation, with the phase stalled so the cancellation is the only thing that can end it.
///
/// Every stall is staged to last ten seconds or more. A cancelled operation must return within
/// ``watchdog``, half the shortest stall, so a caller released only when the stall ends fails
/// instead of passing late, and a caller never released fails instead of hanging the run.
@Suite("FaultInjection: cancellation at every phase")
struct FaultInjectionCancellationTests {
  /// How long a cancelled operation may take to return: half the shortest staged stall.
  static let watchdog: TimeInterval = 5

  enum Canceller: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case taskCancel, networkChanged, cancelActiveTraces
    var testDescription: String { rawValue }
  }

  /// The error a cancelled operation must throw.
  enum Expected {
    /// `TracerouteError.cancelled`: the tracer's handle ended it.
    case handle
    /// `CancellationError`: the caller's task ended it, on an API that reports it that way.
    case caller
    /// Either: the caller's task ended an API that may report it either way.
    case either

    /// What a trace, classified trace or stream must report for `canceller`.
    static func forTrace(_ canceller: Canceller) -> Expected {
      canceller == .taskCancel ? .either : .handle
    }
  }

  private static func cancel<T>(
    _ task: Task<T, Error>, on tracer: SwiftFTR, by canceller: Canceller
  )
    async
  {
    switch canceller {
    case .taskCancel: task.cancel()
    case .networkChanged: await tracer.networkChanged()
    case .cancelActiveTraces: await tracer.cancelActiveTraces()
    }
  }

  /// Runs `cancelling`, then asserts the task ends with the `expected` cancellation error, or, when
  /// `mayComplete`, returns a value. Both must finish within ``watchdog``, timed from before
  /// `cancelling` starts, so a slow or stuck cancellation call fails too.
  private static func expectPromptCancellation<T: Sendable>(
    _ task: Task<T, Error>, expected: Expected, mayComplete: Bool = false, _ label: String,
    cancelling: @escaping @Sendable () async -> Void
  ) async {
    do {
      _ = try await measure(within: watchdog) {
        await cancelling()
        return try await task.value
      }
      if !mayComplete { Issue.record("\(label): completed instead of being cancelled") }
    } catch let expired as WatchdogExpired {
      Issue.record("\(label): \(expired)")
    } catch TracerouteError.cancelled {
      #expect(expected != .caller, "\(label): caller cancellation reported as the tracer's")
    } catch is CancellationError {
      #expect(expected != .handle, "\(label): the tracer's cancellation reported as the caller's")
    } catch {
      Issue.record("\(label): threw \(error)")
    }
  }

  // MARK: Probe window, swept across its whole duration

  @Test("trace() returns promptly whenever it is cancelled", arguments: Canceller.allCases)
  func traceSweep(canceller: Canceller) async throws {
    let network = try FakeICMPNetwork { _ in [] }
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 8, maxWaitMs: 10_000, noReverseDNS: true))

    try await network.install {
      for step in 0..<24 {
        let task = Task { try await tracer.trace(to: "fake.test") }
        // 0, 1, 2 ... yields and then growing sleeps, so the cancellation lands before
        // registration, during the send burst and throughout the receive window.
        if step < 8 {
          for _ in 0..<step { await Task.yield() }
        } else {
          if canceller != .taskCancel {
            // From here on the sweep is of a registered trace, which the tracer can reach.
            #expect(await eventually(within: 2) { await !tracer.activeTraces.isEmpty })
          }
          try await Task.sleep(nanoseconds: UInt64(step - 8) * 15_000_000)
        }
        // A trace not yet registered cannot be reached by the tracer; its own task can.
        let alsoCancelTask = canceller != .taskCancel && step < 8
        await Self.expectPromptCancellation(
          task, expected: alsoCancelTask ? .either : Expected.forTrace(canceller), "step \(step)"
        ) {
          await Self.cancel(task, on: tracer, by: canceller)
          if alsoCancelTask { task.cancel() }
        }
      }
    }
    #expect(await tracer.activeTraces.isEmpty)
  }

  @Test("traceStream ends promptly whenever it is cancelled", arguments: Canceller.allCases)
  func streamSweep(canceller: Canceller) async throws {
    let network = try FakeICMPNetwork { _ in [] }
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(noReverseDNS: true))
    let config = StreamingTraceConfig(probeTimeout: 10, retryAfter: 0.1, maxHops: 8)

    try await network.install {
      for step in 0..<16 {
        let task = Task {
          var count = 0
          for try await _ in tracer.traceStream(to: "fake.test", config: config) { count += 1 }
          return count
        }
        if canceller != .taskCancel {
          // The tracer can only cancel a stream it has registered.
          #expect(await eventually(within: 2) { await !tracer.activeTraces.isEmpty })
        }
        try await Task.sleep(nanoseconds: UInt64(step) * 15_000_000)
        // Cancelling the consuming task ends iteration normally, as for any AsyncSequence, or
        // with a cancellation error. Anything else is a failure, not a cancellation.
        await Self.expectPromptCancellation(
          task, expected: Expected.forTrace(canceller), mayComplete: canceller == .taskCancel,
          "step \(step)"
        ) { await Self.cancel(task, on: tracer, by: canceller) }
      }
    }
    #expect(await eventually(within: 1) { await tracer.activeTraces.isEmpty })
  }

  @Test("ping returns promptly whenever its task is cancelled")
  func pingSweep() async throws {
    let network = try FakeICMPNetwork { _ in [] }
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig())

    try await network.install {
      for step in 0..<16 {
        let task = Task {
          try await tracer.ping(
            to: "fake.test", config: PingConfig(count: 20, interval: 0.5, timeout: 5))
        }
        if step > 0 {
          // Mid-flight: the ping has really started sending before it is cancelled.
          let before = network.probes.value
          #expect(await eventually(within: 2) { network.probes.value > before })
        }
        try await Task.sleep(nanoseconds: UInt64(step) * 20_000_000)
        // A cancelled ping may return the partial result it has or throw a cancellation error;
        // any other error means it failed rather than being cancelled.
        await Self.expectPromptCancellation(
          task, expected: .either, mayComplete: true, "step \(step)"
        ) { task.cancel() }
      }
    }
  }

  // MARK: traceClassified, one stalled phase at a time

  enum ClassifiedPhase: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case publicIPDiscovery, probeWindow, asnLookup
    var testDescription: String { rawValue }
  }

  @Test(
    "traceClassified returns promptly when cancelled in any phase",
    arguments: ClassifiedPhase.allCases, Canceller.allCases)
  func classifiedPhase(phase: ClassifiedPhase, canceller: Canceller) async throws {
    let gate = StallGate()
    defer { gate.open() }
    let entered = FaultCounter()
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 2, name: "test.classified-phase")

    // Only the phase under test stalls; the others answer at once.
    let network = try FakeICMPNetwork { probe in
      phase == .probeWindow
        ? []
        : pathScript(destinationTTL: 2)(probe)
    }
    defer { network.stop() }
    let discovery: TestSeams.DiscoverPublicIPv4 = {
      if phase == .publicIPDiscovery {
        entered.increment()
        gate.wait(limit: 20)
      }
      return STUNPublicIP(ip: "198.51.100.7")
    }
    let resolver = StallingASNResolver(stall: phase == .asnLookup, entered: entered)
    let tracer = offlineTracer(
      SwiftFTRConfig(
        maxHops: 4, maxWaitMs: 10_000, noReverseDNS: true, publicIPDiscoveryTimeout: 20))

    try await TestSeams.$blockingIOExecutor.withValue(executor) {
      try await TestSeams.$discoverPublicIPv4.withValue(discovery) {
        try await network.install {
          let task = Task { try await tracer.traceClassified(to: "fake.test", resolver: resolver) }
          let reached = await eventually(within: 3) {
            switch phase {
            case .probeWindow: network.probes.value >= 4
            case .publicIPDiscovery, .asnLookup: entered.value > 0
            }
          }
          #expect(reached, "the trace never reached \(phase)")
          await Self.expectPromptCancellation(
            task, expected: Expected.forTrace(canceller), "\(phase)"
          ) { await Self.cancel(task, on: tracer, by: canceller) }
        }
      }
    }
    #expect(await eventually(within: 1) { await tracer.activeTraces.isEmpty })
  }

  @Test(
    "A network change during a trace's reverse-DNS wave ends the trace promptly",
    arguments: [Canceller.networkChanged, .cancelActiveTraces])
  func reverseDNSWave(canceller: Canceller) async throws {
    let gate = StallGate()
    defer { gate.open() }
    let started = FaultCounter()
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 4, name: "test.rdns-wave")
    // Production composition: the lookup runs on the executor under the cache's deadline.
    let rdns = RDNSCache(lookupDeadline: 10) { _ in
      started.increment()
      return try? await runDetachedBlockingIO(priority: .background, deadline: 10) {
        gate.wait(limit: 20)
        return String?.none
      }
    }
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 3))
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 4, maxWaitMs: 2000), rdns: rdns)

    try await TestSeams.$blockingIOExecutor.withValue(executor) {
      try await network.install {
        let task = Task { try await tracer.trace(to: "fake.test") }
        #expect(await eventually(within: 3) { started.value > 0 })
        await Self.expectPromptCancellation(task, expected: .handle, "reverse DNS") {
          await Self.cancel(task, on: tracer, by: canceller)
        }
      }
    }
  }

  // MARK: discoverPaths

  enum MultipathPhase: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case publicIPDiscovery, probeWindow, reverseDNS, asnLookup
    var testDescription: String { rawValue }
  }

  @Test(
    "discoverPaths ends promptly when cancelled in any phase, reporting who cancelled it",
    arguments: MultipathPhase.allCases, Canceller.allCases)
  func discoverPathsCancellation(phase: MultipathPhase, canceller: Canceller) async throws {
    let gate = StallGate()
    defer { gate.open() }
    let entered = FaultCounter()
    let resolutions = FaultCounter()
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 8, name: "test.mp-phase")

    let network = try FakeICMPNetwork { probe in
      phase == .probeWindow ? [] : pathScript(destinationTTL: 2)(probe)
    }
    defer { network.stop() }
    let discovery: TestSeams.DiscoverPublicIPv4 = {
      if phase == .publicIPDiscovery {
        entered.increment()
        gate.wait(limit: 20)
      }
      return STUNPublicIP(ip: "198.51.100.7")
    }
    // Reverse DNS on the executor under a long deadline, as production composes it.
    let rdns = RDNSCache(lookupDeadline: 20) { _ in
      guard phase == .reverseDNS else { return nil }
      entered.increment()
      return try? await runDetachedBlockingIO(priority: .background, deadline: 20) {
        gate.wait(limit: 20)
        return String?.none
      }
    }
    let tracer = SwiftFTR(
      config: SwiftFTRConfig(maxHops: 4, publicIPDiscoveryTimeout: 20),
      rdnsCache: rdns,
      asnResolver: UncancellableASNResolver(
        stall: phase == .asnLookup, gate: gate, entered: entered),
      cachedPublicIP: nil)
    let config = MultipathConfig(
      flowVariations: 2, maxPaths: 8, earlyStopThreshold: 2, timeoutMs: 10_000, maxHops: 4)

    try await TestSeams.$blockingIOExecutor.withValue(executor) {
      try await TestSeams.$discoverPublicIPv4.withValue(discovery) {
        try await network.install {
          let resolve: TestSeams.ResolveHost = { [network] _, _ in
            resolutions.increment()
            return network.resolved
          }
          try await TestSeams.$resolveHost.withValue(resolve) {
            let task = Task { try await tracer.discoverPaths(to: "fake.test", config: config) }
            let reached = await eventually(within: 3) {
              phase == .probeWindow ? network.probes.value >= 8 : entered.value > 0
            }
            #expect(reached, "discovery never reached \(phase)")
            let resolvedBeforeCancel = resolutions.value
            await Self.expectPromptCancellation(
              task, expected: canceller == .taskCancel ? .caller : .handle, "\(phase)"
            ) { await Self.cancel(task, on: tracer, by: canceller) }
            if phase == .publicIPDiscovery {
              #expect(
                resolutions.value == resolvedBeforeCancel,
                "a cancelled flow went on to resolve its destination")
            }
          }
        }
      }
    }
  }

  // MARK: discoverPaths publication

  /// Runs `body` with a discovery in flight, held at its commit step until `gate` opens. The
  /// discovery is fully answered, or, when `failing`, every flow's resolution fails.
  private static func withDiscoveryAtCommit(
    failing: Bool = false,
    _ body: @Sendable (SwiftFTR, Task<NetworkTopology, Error>, StallGate) async throws -> Void
  ) async throws {
    let gate = StallGate()
    defer { gate.open() }
    let atCommit = FaultCounter()
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    let tracer = offlineTracer(
      SwiftFTRConfig(maxHops: 4, noReverseDNS: true), publicIP: "198.51.100.7")
    let config = MultipathConfig(
      flowVariations: 1, maxPaths: 4, earlyStopThreshold: 1, timeoutMs: 2000, maxHops: 4)
    let hold: @Sendable () async -> Void = {
      atCommit.increment()
      await gate.waitAsync(limit: 20)
    }
    let fail: TestSeams.ResolveHost = { host, _ in
      throw TracerouteError.resolutionFailed(host: host, details: "staged")
    }
    try await network.install {
      try await TestSeams.$beforeMultipathCommit.withValue(hold) {
        let task = TestSeams.$resolveHost.withValue(failing ? fail : TestSeams.resolveHost) {
          Task { try await tracer.discoverPaths(to: "fake.test", config: config) }
        }
        let reached = await eventually(within: Self.watchdog) { atCommit.value > 0 }
        #expect(reached, "discovery never reached its commit")
        try await body(tracer, task, gate)
      }
    }
    #expect(await tracer.activeTraces.isEmpty)
  }

  @Test(
    "A topology not yet committed when the tracer is invalidated is discarded",
    arguments: [Canceller.networkChanged, .cancelActiveTraces])
  func discoverPathsInvalidatedBeforeCommit(canceller: Canceller) async throws {
    try await Self.withDiscoveryAtCommit { tracer, task, gate in
      await Self.expectPromptCancellation(task, expected: .handle, "invalidated before commit") {
        await Self.cancel(task, on: tracer, by: canceller)
        gate.open()
      }
    }
  }

  @Test(
    "A caller that cancels before discoverPaths commits gets CancellationError, unless the tracer also invalidated it",
    arguments: [false, true])
  func discoverPathsCallerCancelledBeforeCommit(alsoInvalidated: Bool) async throws {
    try await Self.withDiscoveryAtCommit { tracer, task, gate in
      await Self.expectPromptCancellation(
        task, expected: alsoInvalidated ? .handle : .caller, "caller cancelled before commit"
      ) {
        task.cancel()
        if alsoInvalidated { await tracer.cancelActiveTraces() }
        gate.open()
      }
    }
  }

  @Test("A discovery that fails after the tracer began invalidating it reports the invalidation")
  func discoverPathsFailureAfterInvalidationBegan() async throws {
    try await Self.withDiscoveryAtCommit(failing: true) { tracer, task, gate in
      // The first, synchronous half of cancelActiveTraces(): the handle is withdrawn, but its
      // cancel() has not been delivered yet.
      await tracer.withdrawActiveTraces()
      gate.open()
      await Self.expectPromptCancellation(task, expected: .handle, "failed after withdrawal") {}
    }
  }

  @Test("A topology committed before the tracer is invalidated is returned")
  func discoverPathsCommittedBeforeInvalidation() async throws {
    try await Self.withDiscoveryAtCommit { tracer, task, gate in
      // Cache invalidation that is not a network change does not end an operation.
      await tracer.invalidatePublicIP()
      await tracer.clearCaches()
      gate.open()
      let (topology, _) = try await measure(within: Self.watchdog) { try await task.value }
      await tracer.networkChanged()
      #expect(topology.paths.count == 1)
    }
  }

  @Test("A reverse-DNS lookup cut short by cancellation is not cached as a miss")
  func cancelledLookupNotCached() async throws {
    let calls = FaultCounter()
    let rdns = RDNSCache(lookupDeadline: 20) { _ in
      calls.increment()
      // Like the production resolver: a cancelled wait comes back as nil.
      try? await Task.sleep(nanoseconds: 20_000_000_000)
      return Task.isCancelled ? nil : "late.example"
    }
    let lookup = Task { await rdns.lookup("198.51.100.20") }
    #expect(await eventually(within: 2) { calls.value == 1 })
    lookup.cancel()
    #expect(await lookup.value == nil)
    #expect(await rdns.count == 0, "the cancelled lookup was cached")
    #expect(await !rdns.isSuppressingLookups)
  }
}

extension SwiftFTR {
  /// Withdraws every registered handle without cancelling it, as `cancelActiveTraces()` does
  /// before it awaits each handle's `cancel()`.
  fileprivate func withdrawActiveTraces() { activeTraces.removeAll() }
}

/// An ASN resolver that, when told to, waits for `gate` on a thread and ignores cancellation,
/// the way a wait on a shared database load does.
struct UncancellableASNResolver: ASNResolver {
  let stall: Bool
  let gate: StallGate
  let entered: FaultCounter

  func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
    guard stall else { return [:] }
    entered.increment()
    await gate.waitAsync(limit: 20)
    return [:]
  }
}

/// An ASN resolver that, when told to, stalls until cancelled, ignoring its timeout.
struct StallingASNResolver: ASNResolver {
  let stall: Bool
  let entered: FaultCounter

  func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
    guard stall else { return [:] }
    entered.increment()
    try await Task.sleep(nanoseconds: 60_000_000_000)
    return [:]
  }
}
