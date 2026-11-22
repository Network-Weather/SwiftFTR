import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// Cancellation, `networkChanged()` and `cancelActiveTraces()` arriving at every phase of every
/// operation, with the phase stalled so the cancellation is the only thing that can end it.
///
/// The bound asserted after a cancellation is "well under a second", against phases staged to
/// last ten seconds or more. A caller that is only released when the stall ends fails it.
@Suite("FaultInjection: cancellation at every phase")
struct FaultInjectionCancellationTests {
  /// How long a cancelled operation may take to return.
  static let promptly: TimeInterval = 0.75

  enum Canceller: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case taskCancel, networkChanged, cancelActiveTraces
    var testDescription: String { rawValue }
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

  /// Asserts the task ends with a cancellation error within ``promptly`` of `cancelledAt`.
  private static func expectPromptCancellation<T>(
    _ task: Task<T, Error>, cancelledAt: TimeInterval, _ label: String
  ) async {
    do {
      _ = try await task.value
      Issue.record("\(label): completed instead of being cancelled")
    } catch TracerouteError.cancelled {
    } catch is CancellationError {
    } catch {
      Issue.record("\(label): threw \(error)")
    }
    let lag = monotonicNow() - cancelledAt
    #expect(lag < promptly, "\(label): returned \(lag)s after cancellation")
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
          try await Task.sleep(nanoseconds: UInt64(step - 8) * 15_000_000)
        }
        let cancelledAt = monotonicNow()
        await Self.cancel(task, on: tracer, by: canceller)
        if canceller != .taskCancel, step < 8 {
          // A trace not yet registered cannot be reached by the tracer; its own task can.
          task.cancel()
        }
        await Self.expectPromptCancellation(task, cancelledAt: cancelledAt, "step \(step)")
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
        let cancelledAt = monotonicNow()
        await Self.cancel(task, on: tracer, by: canceller)
        if canceller == .taskCancel {
          // Cancelling the consuming task ends iteration normally, as for any AsyncSequence.
          _ = try? await task.value
          let lag = monotonicNow() - cancelledAt
          #expect(lag < Self.promptly, "step \(step): stream ended \(lag)s after cancellation")
        } else {
          await Self.expectPromptCancellation(task, cancelledAt: cancelledAt, "step \(step)")
        }
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
        try await Task.sleep(nanoseconds: UInt64(step) * 20_000_000)
        let cancelledAt = monotonicNow()
        task.cancel()
        // A cancelled ping may also return the partial result it has; either way it must return.
        _ = try? await task.value
        let lag = monotonicNow() - cancelledAt
        #expect(lag < Self.promptly, "step \(step): ping returned \(lag)s after cancellation")
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
          let cancelledAt = monotonicNow()
          await Self.cancel(task, on: tracer, by: canceller)
          await Self.expectPromptCancellation(task, cancelledAt: cancelledAt, "\(phase)")
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
        let cancelledAt = monotonicNow()
        await Self.cancel(task, on: tracer, by: canceller)
        await Self.expectPromptCancellation(task, cancelledAt: cancelledAt, "reverse DNS")
      }
    }
  }

  // MARK: discoverPaths

  @Test(
    "discoverPaths ends promptly on a network change",
    arguments: [Canceller.taskCancel, .networkChanged, .cancelActiveTraces])
  func discoverPathsCancellation(canceller: Canceller) async throws {
    let network = try FakeICMPNetwork { _ in [] }
    defer { network.stop() }
    let tracer = offlineTracer(
      SwiftFTRConfig(maxHops: 4, publicIP: "198.51.100.7", noReverseDNS: true))
    let config = MultipathConfig(
      flowVariations: 5, maxPaths: 8, earlyStopThreshold: 5, timeoutMs: 10_000, maxHops: 4)

    try await network.install {
      let task = Task { try await tracer.discoverPaths(to: "fake.test", config: config) }
      #expect(await eventually(within: 3) { network.probes.value >= 20 })
      let cancelledAt = monotonicNow()
      await Self.cancel(task, on: tracer, by: canceller)
      await Self.expectPromptCancellation(task, cancelledAt: cancelledAt, "discoverPaths")
    }
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
