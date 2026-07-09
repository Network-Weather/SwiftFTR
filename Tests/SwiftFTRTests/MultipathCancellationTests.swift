import Foundation
import Testing

@testable import SwiftFTR

@Suite("Multipath Cancellation Tests")
struct MultipathCancellationTests {
  @Test("Caller cancellation joins every flow worker", .timeLimit(.minutes(1)))
  func callerCancellationJoinsEveryFlowWorker() async {
    let worker = ControlledMultipathWorker(expectedFlowCount: 5, behavior: .suspend)
    let discovery = MultipathDiscovery(worker: worker, config: SwiftFTRConfig())
    let config = MultipathConfig(
      flowVariations: 5,
      maxPaths: 16,
      earlyStopThreshold: 5,
      timeoutMs: 30_000,
      maxHops: 40
    )

    let operation = Task {
      try await discovery.discoverPaths(to: "example.test", multipathConfig: config)
    }

    await worker.waitUntilAllFlowsStarted()
    operation.cancel()

    do {
      _ = try await operation.value
      Issue.record("Cancelled discovery unexpectedly returned a topology")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("Cancelled discovery threw an unexpected error: \(error)")
    }

    let state = await worker.state()
    #expect(state.started == Set(0..<5))
    #expect(state.exited == state.started)
  }

  @Test("Flow failure cancels and joins sibling workers", .timeLimit(.minutes(1)))
  func flowFailureCancelsAndJoinsSiblingWorkers() async {
    let worker = ControlledMultipathWorker(
      expectedFlowCount: 5,
      behavior: .fail(variation: 2)
    )
    let discovery = MultipathDiscovery(worker: worker, config: SwiftFTRConfig())
    let config = MultipathConfig(
      flowVariations: 5,
      maxPaths: 16,
      earlyStopThreshold: 5,
      timeoutMs: 30_000,
      maxHops: 40
    )

    do {
      _ = try await discovery.discoverPaths(to: "example.test", multipathConfig: config)
      Issue.record("Discovery unexpectedly succeeded after an injected flow failure")
    } catch is InjectedMultipathFailure {
      // Expected.
    } catch {
      Issue.record("Discovery threw an unexpected error: \(error)")
    }

    let state = await worker.state()
    #expect(state.started == Set(0..<5))
    #expect(state.exited == state.started)
  }

  @Test("Early stopping finishes the current batch before returning")
  func earlyStoppingFinishesCurrentBatchBeforeReturning() async throws {
    let worker = ControlledMultipathWorker(expectedFlowCount: 5, behavior: .succeed)
    let discovery = MultipathDiscovery(worker: worker, config: SwiftFTRConfig())
    let config = MultipathConfig(
      flowVariations: 10,
      maxPaths: 16,
      earlyStopThreshold: 2,
      timeoutMs: 2_000,
      maxHops: 40
    )

    let topology = try await discovery.discoverPaths(
      to: "example.test",
      multipathConfig: config
    )

    let state = await worker.state()
    #expect(state.started == Set(0..<5))
    #expect(state.exited == state.started)
    #expect(topology.paths.count == 5)
    #expect(topology.uniquePathCount == 1)
  }
}

private struct InjectedMultipathFailure: Error {}

private actor ControlledMultipathWorker: MultipathFlowRunning {
  enum Behavior: Sendable {
    case suspend
    case fail(variation: Int)
    case succeed
  }

  private let expectedFlowCount: Int
  private let behavior: Behavior
  private var started: Set<Int> = []
  private var exited: Set<Int> = []
  private var allStartedWaiters: [CheckedContinuation<Void, Never>] = []
  private var suspensionWaiters: [Int: CheckedContinuation<Void, Error>] = [:]
  private var cancellationRequested: Set<Int> = []

  init(expectedFlowCount: Int, behavior: Behavior) {
    self.expectedFlowCount = expectedFlowCount
    self.behavior = behavior
  }

  func runMultipathFlow(
    target: String,
    flowID: FlowIdentifier,
    maxHops: Int,
    timeoutMs: Int
  ) async throws -> (FlowIdentifier, ClassifiedTrace) {
    let variation = flowID.variation
    started.insert(variation)
    resumeAllStartedWaitersIfReady()
    defer { exited.insert(variation) }

    switch behavior {
    case .suspend:
      try await suspendUntilCancelled(variation: variation)

    case .fail(let failingVariation):
      if variation == failingVariation {
        await waitUntilAllFlowsStarted()
        throw InjectedMultipathFailure()
      }
      try await suspendUntilCancelled(variation: variation)

    case .succeed:
      break
    }

    try Task.checkCancellation()
    return (flowID, makeTrace(destination: target))
  }

  func waitUntilAllFlowsStarted() async {
    guard started.count < expectedFlowCount else { return }

    await withCheckedContinuation { continuation in
      allStartedWaiters.append(continuation)
    }
  }

  func state() -> (started: Set<Int>, exited: Set<Int>) {
    (started, exited)
  }

  private func resumeAllStartedWaitersIfReady() {
    guard started.count >= expectedFlowCount else { return }

    let waiters = allStartedWaiters
    allStartedWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  private func suspendUntilCancelled(variation: Int) async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled || cancellationRequested.remove(variation) != nil {
          continuation.resume(throwing: CancellationError())
        } else {
          suspensionWaiters[variation] = continuation
        }
      }
    } onCancel: {
      Task { await self.cancelSuspension(variation: variation) }
    }
  }

  private func cancelSuspension(variation: Int) {
    if let waiter = suspensionWaiters.removeValue(forKey: variation) {
      waiter.resume(throwing: CancellationError())
    } else {
      cancellationRequested.insert(variation)
    }
  }

  private func makeTrace(destination: String) -> ClassifiedTrace {
    ClassifiedTrace(
      destinationHost: destination,
      destinationIP: "192.0.2.1",
      destinationHostname: nil,
      publicIP: nil,
      publicHostname: nil,
      clientASN: nil,
      clientASName: nil,
      destinationASN: nil,
      destinationASName: nil,
      hops: [
        ClassifiedHop(
          ttl: 1,
          ip: "192.0.2.1",
          rtt: 0.001,
          asn: nil,
          asName: nil,
          category: .destination,
          hostname: nil
        )
      ]
    )
  }
}
