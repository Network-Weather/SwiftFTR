import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// Cancellation, `networkChanged()` and `cancelActiveTraces()` arriving at every phase of every
/// operation, with the phase stalled so the cancellation is the only thing that can end it.
///
/// Every stall is staged to last twenty seconds or more. A cancelled operation must return within
/// ``watchdog``, half the shortest stall, so a caller released only when the stall ends fails
/// instead of passing late, and a caller never released fails instead of hanging the run.
@Suite("FaultInjection: cancellation at every phase")
struct FaultInjectionCancellationTests {
  /// How long a cancelled operation may take to return: half the shortest staged stall.
  static let watchdog: TimeInterval = 10

  enum Canceller: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case taskCancel, networkChanged, cancelActiveTraces
    /// The caller cancels its task and then the tracer cancels its traces, in one step on the
    /// tracer, so the operation cannot report the first before the second has happened.
    case both
    var testDescription: String { rawValue }

    /// The cancellations that come from the tracer alone.
    static let library: [Canceller] = [.networkChanged, .cancelActiveTraces]
  }

  /// The error a cancelled operation must throw.
  enum Expected {
    /// `TracerouteError.cancelled`: the tracer's handle ended it.
    case handle
    /// `CancellationError`: the caller's task ended it.
    case caller
    /// Either: the caller's task and the tracer both cancelled, but the tracer may have done so
    /// before the operation registered, when it could not reach it.
    case either

    /// What a trace, classified trace or stream must report for `canceller`: the caller's own
    /// cancellation as `CancellationError`, and the tracer's, alone or with the caller's, as
    /// `TracerouteError.cancelled`.
    static func forTrace(_ canceller: Canceller) -> Expected {
      canceller == .taskCancel ? .caller : .handle
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
    case .both: await tracer.cancelTaskThenActiveTraces(task)
    }
  }

  /// Runs `cancelling`, then asserts the task ends with the `expected` cancellation error, or, when
  /// `mayComplete`, returns a value. Both must finish within ``watchdog``, timed from before
  /// `cancelling` starts, so a slow or stuck cancellation call fails too.
  ///
  /// `mustComplete` is for a stream whose consumer cancelled: it must end normally, not throw.
  private static func expectPromptCancellation<T: Sendable>(
    _ task: Task<T, Error>, expected: Expected, mayComplete: Bool = false,
    mustComplete: Bool = false, _ label: String,
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
      #expect(!mustComplete, "\(label): threw instead of ending normally")
      #expect(expected != .caller, "\(label): caller cancellation reported as the tracer's")
    } catch is CancellationError {
      #expect(!mustComplete, "\(label): threw instead of ending normally")
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
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 8, maxWaitMs: 20_000, noReverseDNS: true))

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
            #expect(await eventually(within: Self.watchdog) { await !tracer.activeTraces.isEmpty })
          }
          try await Task.sleep(nanoseconds: UInt64(step - 8) * 15_000_000)
        }
        // A trace not yet registered cannot be reached by the tracer; its own task can. Which of
        // the two then ends it depends on whether it registered first.
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

  @Test(
    "traceStream ends promptly whenever it is cancelled",
    arguments: [Canceller.taskCancel] + Canceller.library)
  func streamSweep(canceller: Canceller) async throws {
    let network = try FakeICMPNetwork { _ in [] }
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(noReverseDNS: true))
    let config = StreamingTraceConfig(probeTimeout: 20, retryAfter: 0.1, maxHops: 8)

    try await network.install {
      for step in 0..<16 {
        let task = Task {
          var count = 0
          for try await _ in tracer.traceStream(to: "fake.test", config: config) { count += 1 }
          return count
        }
        if canceller != .taskCancel {
          // The tracer can only cancel a stream it has registered.
          #expect(await eventually(within: Self.watchdog) { await !tracer.activeTraces.isEmpty })
        }
        try await Task.sleep(nanoseconds: UInt64(step) * 15_000_000)
        // Cancelling the consuming task ends iteration normally (see
        // `consumerCancellationEndsIterationNormally`); the tracer's cancellation throws.
        await Self.expectPromptCancellation(
          task, expected: Expected.forTrace(canceller), mayComplete: canceller == .taskCancel,
          mustComplete: canceller == .taskCancel, "step \(step)"
        ) { await Self.cancel(task, on: tracer, by: canceller) }
      }
    }
    #expect(await eventually(within: Self.watchdog) { await tracer.activeTraces.isEmpty })
  }

  /// The premise of the stream tests: once a consumer that cancelled its own task has been
  /// handed the end of iteration, a producer that finishes with an error later cannot change it.
  /// (An error the producer finishes with inside `onTermination` itself does reach the consumer,
  /// so `traceStream` finishes normally when its consumer cancels rather than relying on order.)
  @Test("Cancelling a stream's consumer ends its iteration normally")
  func consumerCancellationEndsIterationNormally() async throws {
    let terminated = FaultCounter()
    let (stream, continuation) = AsyncThrowingStream<Int, Error>.makeStream()
    continuation.onTermination = { _ in terminated.increment() }
    let consumer = Task {
      var count = 0
      for try await _ in stream { count += 1 }
      return count
    }
    let (count, _) = try await measure(within: Self.watchdog) {
      consumer.cancel()
      return try await consumer.value
    }
    #expect(count == 0)
    #expect(terminated.value == 1)
    // Too late to matter: the consumer has already returned.
    continuation.finish(throwing: TracerouteError.cancelled)
  }

  @Test("A stream whose consumer cancels ends normally and its producer lets go of everything")
  func streamConsumerCancellationCleansUp() async throws {
    let network = try FakeICMPNetwork { _ in [] }
    defer { network.stop() }
    let log = DescriptorLog()
    let tracer = offlineTracer(SwiftFTRConfig(noReverseDNS: true))
    let config = StreamingTraceConfig(probeTimeout: 20, retryAfter: 0.1, maxHops: 8)

    try await network.install(socketFactory: log.wrap { try network.makeSocket($0) }) {
      let consumer = Task {
        var count = 0
        for try await _ in tracer.traceStream(to: "fake.test", config: config) { count += 1 }
        return count
      }
      let receiving = await eventually(within: Self.watchdog) {
        // Probes sent, so past resolution, whose wait also installs a handler.
        guard network.probes.value > 0, let handle = await tracer.activeTraces.first else {
          return false
        }
        return await handle.hasCancellationHandler
      }
      #expect(receiving, "the stream never reached its receive window")
      _ = try await measure(within: Self.watchdog) {
        consumer.cancel()
        return try await consumer.value
      }
    }
    #expect(await eventually(within: Self.watchdog) { await tracer.activeTraces.isEmpty })
    #expect(log.opened == 1)
    #expect(await eventually(within: Self.watchdog) { log.allClosed }, "the socket was left open")
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
            to: "fake.test", config: PingConfig(count: 40, interval: 0.5, timeout: 5))
        }
        if step > 0 {
          // Mid-flight: the ping has really started sending before it is cancelled.
          let before = network.probes.value
          #expect(await eventually(within: Self.watchdog) { network.probes.value > before })
        }
        try await Task.sleep(nanoseconds: UInt64(step) * 20_000_000)
        // Forty probes half a second apart cannot finish here, so the ping must throw the
        // caller's own cancellation.
        await Self.expectPromptCancellation(task, expected: .caller, "step \(step)") {
          task.cancel()
        }
      }
    }
  }

  // MARK: traceClassified, one stalled phase at a time

  enum ClassifiedPhase: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case publicIPDiscovery, probeWindow, reverseDNS, asnLookup
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
    // A stall in a blocking attempt's executor slot, as a STUN `recv` stalls.
    let discovery: TestSeams.DiscoverPublicIP = { _ in
      if phase == .publicIPDiscovery {
        entered.increment()
        try await runDetachedBlockingIO { gate.wait(limit: 20) }
      }
      return STUNPublicIP(ip: "198.51.100.7")
    }
    let resolver = StallingASNResolver(stall: phase == .asnLookup, entered: entered)
    // Reverse DNS as production composes it, the real lookup under a long deadline, against a
    // daemon that takes the question and never answers.
    let daemon = FakeDNSService()
    let rdns = RDNSCache(lookupDeadline: 20, limiter: _ConcurrencySemaphore(maxConcurrent: 32))
    let tracer = offlineTracer(
      SwiftFTRConfig(
        maxHops: 4, maxWaitMs: 20_000, noReverseDNS: phase != .reverseDNS,
        publicIPDiscoveryTimeout: 20),
      rdns: rdns)

    await TestSeams.$blockingIOExecutor.withValue(executor) {
      await TestSeams.$discoverPublicIP.withValue(discovery) {
        await daemon.install {
          await network.install {
            let task = Task {
              try await tracer.traceClassified(to: "fake.test", resolver: resolver)
            }
            let reached = await eventually(within: Self.watchdog) {
              switch phase {
              case .probeWindow: network.probes.value >= 4
              case .reverseDNS: daemon.scheduledCount > 0
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
    }
    // The trace left its wave at once; the shared queries run on to their deadline, which the
    // test now passes, and end.
    daemon.expireDeadlines()
    #expect(await eventually(within: Self.watchdog) { daemon.liveCount == 0 })
    #expect(await eventually(within: Self.watchdog) { await tracer.activeTraces.isEmpty })
  }

  @Test(
    "A trace cancelled during its reverse-DNS wave ends promptly, reporting who cancelled it",
    arguments: Canceller.allCases)
  func reverseDNSWave(canceller: Canceller) async throws {
    // Production composition: the real lookup under a long deadline, against a daemon that takes
    // the question and never answers.
    let daemon = FakeDNSService()
    let rdns = RDNSCache(lookupDeadline: 20, limiter: _ConcurrencySemaphore(maxConcurrent: 32))
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 3))
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 4, maxWaitMs: 2000), rdns: rdns)

    await daemon.install {
      await network.install {
        let task = Task { try await tracer.trace(to: "fake.test") }
        #expect(await eventually(within: Self.watchdog) { daemon.scheduledCount > 0 })
        await Self.expectPromptCancellation(
          task, expected: Expected.forTrace(canceller), "reverse DNS"
        ) {
          await Self.cancel(task, on: tracer, by: canceller)
        }
      }
    }
    // The trace left its wave at once; the shared queries run on to their deadline, which the
    // test now passes, and are then stopped.
    daemon.expireDeadlines()
    #expect(await eventually(within: Self.watchdog) { daemon.liveCount == 0 })
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
    // A stall in a blocking attempt's executor slot, as a STUN `recv` stalls.
    let discovery: TestSeams.DiscoverPublicIP = { _ in
      if phase == .publicIPDiscovery {
        entered.increment()
        try await runDetachedBlockingIO { gate.wait(limit: 20) }
      }
      return STUNPublicIP(ip: "198.51.100.7")
    }
    // Reverse DNS that ignores cancellation, as the ASN resolver here does, so only a flow's own
    // race against its cancellation can release it.
    let rdns =
      phase == .reverseDNS
      ? stallingRDNSCache(gate: gate, limit: 20, entered: entered)
      : RDNSCache { _, _ in .noSuchRecord }
    let tracer = SwiftFTR(
      config: SwiftFTRConfig(maxHops: 4, publicIPDiscoveryTimeout: 20),
      rdnsCache: rdns,
      asnResolver: UncancellableASNResolver(
        stall: phase == .asnLookup, gate: gate, entered: entered),
      publicIPCache: [:])
    let config = MultipathConfig(
      flowVariations: 2, maxPaths: 8, earlyStopThreshold: 2, timeoutMs: 20_000, maxHops: 4)

    await TestSeams.$blockingIOExecutor.withValue(executor) {
      await TestSeams.$discoverPublicIP.withValue(discovery) {
        await network.install {
          let resolve: TestSeams.ResolveHost = { [network] _, _ in
            resolutions.increment()
            return network.resolved
          }
          await TestSeams.$resolveHost.withValue(resolve) {
            let task = Task { try await tracer.discoverPaths(to: "fake.test", config: config) }
            let reached = await eventually(within: Self.watchdog) {
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

  // MARK: traceStream's end

  /// Runs `body` with a stream that has delivered its only hop and is held at its commit step until
  /// `gate` opens. The consumer task returns how many hops it saw.
  private static func withStreamAtCommit(
    _ body: @Sendable (SwiftFTR, Task<Int, Error>, StallGate) async throws -> Void
  ) async throws {
    let gate = StallGate()
    defer { gate.open() }
    let atCommit = FaultCounter()
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 1))
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(noReverseDNS: true))
    let config = StreamingTraceConfig(probeTimeout: 10, retryAfter: nil, maxHops: 1)
    let hold: @Sendable () async -> Void = {
      atCommit.increment()
      await gate.waitAsync(limit: 20)
    }
    try await network.install {
      try await TestSeams.$beforeStreamCommit.withValue(hold) {
        let consumer = Task {
          var count = 0
          for try await _ in tracer.traceStream(to: "fake.test", config: config) { count += 1 }
          return count
        }
        let reached = await eventually(within: Self.watchdog) { atCommit.value > 0 }
        #expect(reached, "the stream never reached its commit")
        try await body(tracer, consumer, gate)
      }
    }
    #expect(await tracer.activeTraces.isEmpty)
  }

  @Test("A stream cancelled by the tracer after its last hop but before it ends reports it")
  func streamCancelledBeforeCommit() async throws {
    try await Self.withStreamAtCommit { tracer, consumer, gate in
      await Self.expectPromptCancellation(consumer, expected: .handle, "cancelled before commit") {
        await tracer.cancelActiveTraces()
        gate.open()
      }
    }
  }

  @Test("A stream that ended before the tracer's cancellation keeps its normal end")
  func streamCommittedBeforeCancellation() async throws {
    try await Self.withStreamAtCommit { tracer, consumer, gate in
      gate.open()
      let (count, _) = try await measure(within: Self.watchdog) { try await consumer.value }
      await tracer.cancelActiveTraces()
      #expect(count == 1)
    }
  }

  @Test(
    "Reverse-DNS lookups by callers already cancelled ask nothing and do not trip the stall breaker"
  )
  func cancelledLookupNotCached() async throws {
    let calls = FaultCounter()
    let rdns = RDNSCache { _, _ in
      calls.increment()
      return .timedOut
    }

    // Two callers cancelled before they look up: they start nothing, so two stalls cannot come
    // of them.
    for ip in ["198.51.100.20", "198.51.100.21"] {
      let hostname = await Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await rdns.lookup(ip)
      }.value
      #expect(hostname == nil)
    }
    #expect(calls.value == 0, "a cancelled caller started a query")
    let suppressedByCancelled = await rdns.isSuppressingLookups
    #expect(!suppressedByCancelled, "cancelled lookups counted toward the stall breaker")

    // Control: the same outcome from two lookups nobody cancelled does open the breaker.
    for ip in ["198.51.100.22", "198.51.100.23"] {
      _ = try await measure(within: Self.watchdog) { await rdns.lookup(ip) }
    }
    let suppressedByStalls = await rdns.isSuppressingLookups
    #expect(suppressedByStalls, "two uncancelled stalls did not open the breaker")
  }
}

extension SwiftFTR {
  /// Withdraws every registered handle without cancelling it, as `cancelActiveTraces()` does
  /// before it awaits each handle's `cancel()`.
  fileprivate func withdrawActiveTraces() { activeTraces.removeAll() }

  /// Cancels `task`, then every registered trace, in one step on this tracer, so an operation
  /// reporting from the tracer cannot see the first without the second.
  fileprivate func cancelTaskThenActiveTraces<T>(_ task: Task<T, Error>) {
    task.cancel()
    cancelRegisteredTraces()
  }
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
