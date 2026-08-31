import Dispatch
import Foundation
import Testing

@testable import SwiftFTR

/// Records whether a blocking operation body actually executed, and blocks for a controllable
/// duration to simulate a stalled syscall without touching the network.
private final class StallProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var _didRun = false

  var didRun: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _didRun
  }

  func markRun() {
    lock.lock()
    _didRun = true
    lock.unlock()
  }

  /// Simulates a syscall that blocks its worker for `seconds`.
  func stall(_ seconds: TimeInterval) {
    markRun()
    Thread.sleep(forTimeInterval: seconds)
  }
}

/// Cancellation and deadline behavior of the bridge from Swift concurrency to blocking syscalls.
///
/// A single-slot executor makes queueing deterministic: one occupant plus one queued operation is
/// enough to exercise every path without depending on machine core count.
@Suite(.serialized)
struct BlockingIOCancellationTests {

  @Test("A queued operation is dropped, not run, when its caller is cancelled")
  func cancellationDequeuesQueuedOperation() async throws {
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.dequeue")
    let occupant = StallProbe()
    let queued = StallProbe()

    // Occupy the only slot so the operation under test cannot start.
    let holder = Task { try await executor.run(priority: .userInitiated) { occupant.stall(1.5) } }
    while !occupant.didRun { try await Task.sleep(nanoseconds: 5_000_000) }

    let start = monotonicNow()
    let victim = Task { try await executor.run(priority: .userInitiated) { queued.stall(1.5) } }
    try await Task.sleep(nanoseconds: 100_000_000)
    victim.cancel()

    await #expect(throws: CancellationError.self) { try await victim.value }
    let elapsed = monotonicNow() - start

    #expect(
      elapsed < 0.5, "cancellation resumed the caller in \(elapsed)s; expected well under 0.5s")
    #expect(queued.didRun == false, "a cancelled, never-started operation must not run its body")

    _ = try? await holder.value
  }

  @Test("A caller is freed promptly even when the syscall is already in flight")
  func cancellationFreesCallerDuringRunningSyscall() async throws {
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.running")
    let probe = StallProbe()

    let start = monotonicNow()
    let victim = Task { try await executor.run(priority: .userInitiated) { probe.stall(2.0) } }
    while !probe.didRun { try await Task.sleep(nanoseconds: 5_000_000) }
    victim.cancel()

    await #expect(throws: CancellationError.self) { try await victim.value }
    let elapsed = monotonicNow() - start

    // The syscall keeps running on its worker; only the caller is released. Anything close to the
    // 2.0s stall means the caller waited for the syscall, which is the production hang.
    #expect(
      elapsed < 1.0, "caller waited \(elapsed)s for an in-flight syscall; expected under 1.0s")
  }

  @Test("A deadline bounds the caller's wait and reports a timeout")
  func deadlineBoundsCallerWait() async throws {
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.deadline")
    let probe = StallProbe()

    let start = monotonicNow()
    await #expect(throws: BlockingIOTimeout.self) {
      try await executor.run(priority: .userInitiated, deadline: 0.2) { probe.stall(2.0) }
    }
    let elapsed = monotonicNow() - start

    #expect(elapsed >= 0.2, "returned before its own deadline (\(elapsed)s)")
    #expect(elapsed < 0.8, "deadline overshot: \(elapsed)s for a 0.2s budget")
  }

  @Test("An operation completing inside its deadline returns normally")
  func deadlineDoesNotDisturbFastOperations() async throws {
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.fast")

    let value = try await executor.run(priority: .userInitiated, deadline: 2.0) { 42 }
    #expect(value == 42)

    // Outlive the deadline so a leaked timer would fire against an already-resumed continuation.
    // A double resume traps the checked continuation, failing this test rather than passing quietly.
    try await Task.sleep(nanoseconds: 2_400_000_000)
  }

  @Test("Errors thrown by the operation still propagate")
  func operationErrorsPropagate() async throws {
    struct Boom: Error {}
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.throws")

    await #expect(throws: Boom.self) {
      try await executor.run(priority: .userInitiated) { throw Boom() }
    }
  }

  @Test("Cancelling before submission resumes rather than stranding the caller")
  func alreadyCancelledTaskDoesNotStrand() async throws {
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.precancelled")
    let probe = StallProbe()

    let victim = Task {
      // Give the cancel below a chance to land before the executor call begins.
      try? await Task.sleep(nanoseconds: 150_000_000)
      return try await executor.run(priority: .userInitiated) { probe.stall(1.0) }
    }
    victim.cancel()

    await #expect(throws: (any Error).self) { try await victim.value }
  }

  @Test("The shared runDetachedBlockingIO entry point honors cancellation")
  func sharedEntryPointHonorsCancellation() async throws {
    let probe = StallProbe()
    let start = monotonicNow()

    let victim = Task { try await runDetachedBlockingIO { probe.stall(2.0) } }
    while !probe.didRun { try await Task.sleep(nanoseconds: 5_000_000) }
    victim.cancel()

    await #expect(throws: CancellationError.self) { try await victim.value }
    #expect(monotonicNow() - start < 1.0)
  }
}
