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
    // Also on an early exit, so a worker that starts after the check below gives up is not left
    // blocked for the rest of the suite. The extra signal on the normal path is harmless.
    defer { release.signal() }
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
    let free = DispatchSemaphore(value: 0)

    // The only worker stays held until the deadline has fired, so the operation is still queued
    // when it does, however slowly this task runs.
    let holder = Task {
      try? await executor.run(priority: .userInitiated) {
        occupied.increment()
        free.wait()
      }
    }
    // Also on an early exit, so the worker is not left blocked for the rest of the suite.
    defer { free.signal() }
    try #require(
      await eventually(within: 10) { occupied.value > 0 }, "the worker was never occupied")

    // The marker lives only in the operation's closure, so it dies when the bridge lets go. The
    // call runs under a watchdog of its own: the worker stays held until after it returns, so a
    // deadline that failed to resume the caller would otherwise hang the test.
    do {
      let marker = DeinitMarker { released.increment() }
      let (thrown, _) = try await measure(within: 20) { () -> Error? in
        do {
          try await executor.run(priority: .userInitiated, deadline: 0.05) { marker.touch() }
          return nil
        } catch {
          return error
        }
      }
      #expect(thrown is BlockingIOTimeout, "\(String(describing: thrown))")
    }
    free.signal()
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
