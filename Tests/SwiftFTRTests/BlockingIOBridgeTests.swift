import Dispatch
import Foundation
import Testing

@testable import SwiftFTR

private enum BlockingIOTestError: Error, Equatable {
  case expected(Int)
}

/// A synchronous gate used only from `BlockingIOExecutor` operations.
///
/// The lock protects all mutable state, so the helper is safe to capture in the executor's
/// `@Sendable` operation closures. Waiting on the semaphore deliberately simulates a blocking
/// syscall without using live networking.
private final class BlockingOperationProbe: @unchecked Sendable {
  private struct State {
    var activeCount = 0
    var invocationCount = 0
    var maximumActiveCount = 0
  }

  let starts: AsyncStream<Int>

  private let lock = NSLock()
  private let releaseGate = DispatchSemaphore(value: 0)
  private let startContinuation: AsyncStream<Int>.Continuation
  private var state = State()

  init() {
    let (starts, continuation) = AsyncStream.makeStream(
      of: Int.self,
      bufferingPolicy: .unbounded
    )
    self.starts = starts
    self.startContinuation = continuation
  }

  deinit {
    startContinuation.finish()
  }

  func block(returning value: Int) -> Int {
    let activeCount = withState { state in
      state.activeCount += 1
      state.invocationCount += 1
      state.maximumActiveCount = max(state.maximumActiveCount, state.activeCount)
      return state.activeCount
    }
    startContinuation.yield(activeCount)

    releaseGate.wait()

    withState { state in
      state.activeCount -= 1
    }
    return value
  }

  func release(count: Int) {
    for _ in 0..<count {
      releaseGate.signal()
    }
  }

  var invocationCount: Int {
    withState { $0.invocationCount }
  }

  var maximumActiveCount: Int {
    withState { $0.maximumActiveCount }
  }

  private func withState<T>(_ body: (inout State) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(&state)
  }
}

@Suite("Blocking I/O Bridge Tests")
struct BlockingIOBridgeTests {
  @Test("Blocking work executes outside a Swift task")
  func operationRunsOutsideCooperativeExecutor() async throws {
    let hasCurrentSwiftTask = try await runDetachedBlockingIO {
      withUnsafeCurrentTask { task in
        task != nil
      }
    }

    #expect(hasCurrentSwiftTask == false)
  }

  @Test("Executor bounds blocking work without starving cooperative tasks")
  func boundsConcurrencyWithoutStarvation() async throws {
    let width = 3
    let operationCount = width * 32
    let executor = BlockingIOExecutor(
      maximumConcurrentOperations: width,
      name: "BlockingIOBridgeTests.boundsConcurrency"
    )
    let probe = BlockingOperationProbe()

    let operations = Task {
      try await withThrowingTaskGroup(of: Int.self, returning: [Int].self) { group in
        for value in 0..<operationCount {
          group.addTask {
            try await executor.run(priority: .medium) {
              probe.block(returning: value)
            }
          }
        }

        var results: [Int] = []
        for try await result in group {
          results.append(result)
        }
        return results
      }
    }
    defer { probe.release(count: operationCount) }

    var startIterator = probe.starts.makeAsyncIterator()
    var observedActiveCounts: [Int] = []
    for _ in 0..<width {
      if let activeCount = await startIterator.next() {
        observedActiveCounts.append(activeCount)
      }
    }

    #expect(observedActiveCounts.sorted() == Array(1...width))
    #expect(probe.maximumActiveCount == width)

    // All executor lanes are blocked and the remaining operations are queued. This Swift task must
    // still run because none of those synchronous waits occupies a cooperative-executor worker.
    let cooperativeHeartbeat = Task { 42 }
    #expect(await cooperativeHeartbeat.value == 42)

    probe.release(count: operationCount)
    let results = try await operations.value

    #expect(results.sorted() == Array(0..<operationCount))
    #expect(probe.invocationCount == operationCount)
    #expect(probe.maximumActiveCount <= width)
  }

  @Test("Cancellation waits for a started blocking operation")
  func cancellationDoesNotAbandonContinuation() async throws {
    let executor = BlockingIOExecutor(
      maximumConcurrentOperations: 1,
      name: "BlockingIOBridgeTests.cancellation"
    )
    let probe = BlockingOperationProbe()
    let operation = Task {
      try await executor.run(priority: .background) {
        probe.block(returning: 7)
      }
    }
    defer { probe.release(count: 1) }

    var startIterator = probe.starts.makeAsyncIterator()
    let started = await startIterator.next()
    #expect(started == 1)

    operation.cancel()
    #expect(operation.isCancelled)

    probe.release(count: 1)
    let value = try await operation.value

    #expect(value == 7)
    #expect(probe.invocationCount == 1)
  }

  @Test("Concurrent values and errors resume each caller exactly once")
  func forwardsConcurrentValuesAndErrors() async {
    let executor = BlockingIOExecutor(
      maximumConcurrentOperations: 4,
      name: "BlockingIOBridgeTests.results"
    )
    let operationCount = 128

    let outcomes = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
      for value in 0..<operationCount {
        group.addTask {
          do {
            let result = try await executor.run(priority: .userInitiated) {
              if value.isMultiple(of: 2) {
                return value
              }
              throw BlockingIOTestError.expected(value)
            }
            return value.isMultiple(of: 2) && result == value
          } catch let error as BlockingIOTestError {
            return !value.isMultiple(of: 2) && error == .expected(value)
          } catch {
            return false
          }
        }
      }

      var outcomes: [Bool] = []
      for await outcome in group {
        outcomes.append(outcome)
      }
      return outcomes
    }

    #expect(outcomes.count == operationCount)
    #expect(outcomes.allSatisfy { $0 })
  }
}
