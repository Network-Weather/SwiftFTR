import Foundation
import Testing

@testable import SwiftFTR

@Suite("Bufferbloat Lifecycle Tests")
struct BufferbloatLifecycleTests {
  @Test("Successful measurement awaits load completion", .timeLimit(.minutes(1)))
  func successfulMeasurementAwaitsLoadCompletion() async throws {
    let load = SuspendingOperationProbe()
    let pingReadyToReturn = OneShotSignal()
    let dependencies = BufferbloatDependencies(
      ping: { _, _ in
        await load.waitUntilStarted()
        await pingReadyToReturn.signal()
        return stubPingResult()
      },
      generateLoad: { _, _ in
        await load.run()
      }
    )
    let runner = makeRunner(dependencies: dependencies)

    let task = Task {
      try await runner.run()
    }

    await pingReadyToReturn.wait()

    let pendingState = await load.state
    #expect(pendingState.didStart)
    #expect(!pendingState.didFinish)
    #expect(!pendingState.wasCancelled)

    await load.finish()
    _ = try await task.value

    let finalState = await load.state
    #expect(finalState.didStart)
    #expect(finalState.didFinish)
    #expect(!finalState.wasCancelled)
  }

  @Test("Ping failure cancels and awaits load", .timeLimit(.minutes(1)))
  func pingFailureCancelsAndAwaitsLoad() async {
    let load = SuspendingOperationProbe()
    let dependencies = BufferbloatDependencies(
      ping: { _, _ in
        await load.waitUntilStarted()
        throw StubPingError.failed
      },
      generateLoad: { _, _ in
        await load.run()
      }
    )

    do {
      _ = try await makeRunner(dependencies: dependencies).run()
      Issue.record("Expected the ping failure to be propagated")
    } catch StubPingError.failed {
      // Expected.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    let state = await load.state
    #expect(state.didStart)
    #expect(state.didFinish)
    #expect(state.wasCancelled)
  }

  @Test("Caller cancellation stops ping and load", .timeLimit(.minutes(1)))
  func callerCancellationStopsPingAndLoad() async {
    let load = SuspendingOperationProbe()
    let ping = SuspendingOperationProbe()
    let dependencies = BufferbloatDependencies(
      ping: { _, _ in
        await load.waitUntilStarted()
        await ping.run()
        try Task.checkCancellation()
        return stubPingResult()
      },
      generateLoad: { _, _ in
        await load.run()
      }
    )
    let runner = makeRunner(dependencies: dependencies)

    let task = Task {
      try await runner.run()
    }
    await load.waitUntilStarted()
    await ping.waitUntilStarted()
    task.cancel()

    do {
      _ = try await task.value
      Issue.record("Expected cancellation to be propagated")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    let loadState = await load.state
    let pingState = await ping.state
    #expect(loadState.didFinish)
    #expect(loadState.wasCancelled)
    #expect(pingState.didFinish)
    #expect(pingState.wasCancelled)
  }

  @Test(
    "Caller cancellation after ping completion stops and awaits load",
    .timeLimit(.minutes(1))
  )
  func callerCancellationAfterPingCompletionStopsAndAwaitsLoad() async {
    let load = SuspendingOperationProbe()
    let pingReadyToReturn = OneShotSignal()
    let dependencies = BufferbloatDependencies(
      ping: { _, _ in
        await load.waitUntilStarted()
        await pingReadyToReturn.signal()
        return stubPingResult()
      },
      generateLoad: { _, _ in
        await load.run()
      }
    )
    let runner = makeRunner(dependencies: dependencies)

    let task = Task {
      try await runner.run()
    }

    await pingReadyToReturn.wait()

    let pendingState = await load.state
    #expect(pendingState.didStart)
    #expect(!pendingState.didFinish)

    task.cancel()

    do {
      _ = try await task.value
      Issue.record("Expected cancellation to be propagated")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    let finalState = await load.state
    #expect(finalState.didStart)
    #expect(finalState.didFinish)
    #expect(finalState.wasCancelled)
  }

  private func makeRunner(dependencies: BufferbloatDependencies) -> BufferbloatRunner {
    BufferbloatRunner(
      testConfig: BufferbloatConfig(
        baselineDuration: 0,
        loadDuration: 1,
        loadType: .download,
        parallelStreams: 1,
        pingInterval: 1,
        calculateRPM: false
      ),
      swiftConfig: SwiftFTRConfig(),
      dependencies: dependencies
    )
  }
}

private enum StubPingError: Error {
  case failed
}

private struct OperationProbeState: Sendable {
  let didStart: Bool
  let didFinish: Bool
  let wasCancelled: Bool
}

private actor OneShotSignal {
  private var isSignaled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func signal() {
    guard !isSignaled else { return }

    isSignaled = true
    let waiters = waiters
    self.waiters.removeAll()

    for waiter in waiters {
      waiter.resume()
    }
  }

  func wait() async {
    guard !isSignaled else { return }

    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }
}

private actor SuspendingOperationProbe {
  private let finishStream: AsyncStream<Void>
  private let finishContinuation: AsyncStream<Void>.Continuation

  private var didStart = false
  private var didFinish = false
  private var wasCancelled = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []

  init() {
    (finishStream, finishContinuation) = AsyncStream.makeStream(of: Void.self)
  }

  var state: OperationProbeState {
    OperationProbeState(
      didStart: didStart,
      didFinish: didFinish,
      wasCancelled: wasCancelled
    )
  }

  func run() async {
    didStart = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }

    await withTaskCancellationHandler {
      var iterator = finishStream.makeAsyncIterator()
      _ = await iterator.next()
    } onCancel: {
      finishContinuation.finish()
    }

    wasCancelled = Task.isCancelled
    didFinish = true
  }

  func waitUntilStarted() async {
    guard !didStart else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func finish() {
    finishContinuation.yield()
    finishContinuation.finish()
  }
}

private func stubPingResult() -> PingResult {
  let response = PingResponse(sequence: 0, rtt: 0.01, ttl: 64, timestamp: Date())
  return PingResult(
    target: "192.0.2.1",
    resolvedIP: "192.0.2.1",
    responses: [response],
    statistics: PingStatistics(
      sent: 1,
      received: 1,
      packetLoss: 0,
      minRTT: response.rtt,
      avgRTT: response.rtt,
      maxRTT: response.rtt,
      jitter: 0
    )
  )
}
