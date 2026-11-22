import Foundation
import Testing

@testable import SwiftFTR

/// Every call into the blocking-I/O bridge must resume its caller and release what it allocated,
/// whichever of completion, cancellation and the deadline gets there first.
@Suite(.serialized)
struct BlockingIOStrandingTests {

  @Test("Cancelling during submission never strands the caller, even with every worker busy")
  func cancellationDuringSubmissionResumes() async throws {
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.stranding")
    let callCount = 10_000
    let finished = Counter()
    let occupied = Counter()
    let release = DispatchSemaphore(value: 0)

    // Hold the only worker throughout, so a caller that depends on its operation being dequeued
    // cannot return.
    let holder = Task {
      try? await executor.run(priority: .userInitiated) {
        occupied.increment()
        release.wait()
      }
    }
    try #require(
      await eventually(within: 10) { occupied.value > 0 }, "the worker was never occupied")

    // Cancel from another task after a varying number of yields, so across the run the
    // cancellation lands at every point of the submission path.
    for index in 0..<callCount {
      let call = Task {
        // The deadline outlasts the test, so only cancellation can resume this caller.
        do {
          _ = try await executor.run(priority: .userInitiated, deadline: 60) { 1 }
        } catch is CancellationError {
          finished.increment()
        } catch {}
      }
      Task.detached {
        for _ in 0..<(index % 16) { await Task.yield() }
        call.cancel()
      }
    }

    // Cancellation should resume each caller at once; allow far longer before calling it stranded.
    let giveUp = monotonicNow() + 5.0
    while finished.value < callCount, monotonicNow() < giveUp {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let finishedWhileHeld = finished.value
    release.signal()
    await holder.value

    #expect(
      finishedWhileHeld == callCount,
      "\(callCount - finishedWhileHeld) callers were not resumed by cancellation while the worker was held"
    )
  }

  @Test("A deadline that fires while the operation is still queued releases its timer")
  func expiredQueuedOperationReleasesTimer() async throws {
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.timer-release")
    let occupied = Counter()
    let released = Counter()

    let holder = Task {
      try? await executor.run(priority: .userInitiated) {
        occupied.increment()
        Thread.sleep(forTimeInterval: 0.3)
      }
    }
    try #require(
      await eventually(within: 10) { occupied.value > 0 }, "the worker was never occupied")

    // The marker lives only in the operation's closure, so it dies when the bridge lets go.
    do {
      let marker = DeinitMarker { released.increment() }
      await #expect(throws: BlockingIOTimeout.self) {
        try await executor.run(priority: .userInitiated, deadline: 0.05) { marker.touch() }
      }
    }
    await holder.value

    let giveUp = monotonicNow() + 2.0
    while released.value == 0, monotonicNow() < giveUp {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(released.value == 1, "the expired operation and its timer were never released")
  }
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}

private final class DeinitMarker: Sendable {
  private let onDeinit: @Sendable () -> Void

  init(_ onDeinit: @escaping @Sendable () -> Void) { self.onDeinit = onDeinit }

  func touch() {}

  deinit { onDeinit() }
}
