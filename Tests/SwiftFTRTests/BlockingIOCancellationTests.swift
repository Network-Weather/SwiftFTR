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

  /// Simulates a syscall that blocks its worker until the test opens `gate`.
  func hold(until gate: StallGate) {
    markRun()
    gate.wait(limit: stallLimit)
  }
}

/// How long a gated stall may last if a test never opens its gate, and the watchdog on each wait
/// for a caller to be released. Neither is a claim about speed: a released caller returns while
/// its gate is still closed, and a caller that is not released trips the watchdog.
private let stallLimit: TimeInterval = 60
private let watchdog: TimeInterval = 20

/// Whether `result` is a failure of type `E`.
private func failed<T, E: Error>(_ result: Result<T, Error>, with type: E.Type) -> Bool {
  if case .failure(let error) = result { return error is E }
  return false
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
    let slotHeld = StallGate()
    defer { slotHeld.open() }

    // Occupy the only slot until the end of the test, so the operation under test cannot start.
    let holder = Task {
      try await executor.run(priority: .userInitiated) { occupant.hold(until: slotHeld) }
    }
    defer { holder.cancel() }
    try #require(await eventually(within: 10) { occupant.didRun }, "the occupant never ran")

    let victim = Task { try await executor.run(priority: .userInitiated) { queued.stall(0) } }
    try await Task.sleep(nanoseconds: 100_000_000)
    victim.cancel()

    // The slot is still held, so a caller that returns here was released by its cancellation and
    // not by getting a worker.
    let (result, _) = try await measure(within: watchdog) { await victim.result }
    #expect(failed(result, with: CancellationError.self))
    #expect(queued.didRun == false, "a cancelled, never-started operation must not run its body")
  }

  @Test("A caller is freed promptly even when the syscall is already in flight")
  func cancellationFreesCallerDuringRunningSyscall() async throws {
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.running")
    let probe = StallProbe()
    let syscall = StallGate()
    defer { syscall.open() }

    let victim = Task {
      try await executor.run(priority: .userInitiated) { probe.hold(until: syscall) }
    }
    try #require(await eventually(within: 10) { probe.didRun }, "the operation never ran")
    victim.cancel()

    // The syscall keeps running on its worker until the gate opens; only the caller is released.
    // A caller that waited for the syscall would still be waiting, which is the production hang.
    let (result, _) = try await measure(within: watchdog) { await victim.result }
    #expect(failed(result, with: CancellationError.self))
  }

  @Test("A deadline bounds the caller's wait and reports a timeout")
  func deadlineBoundsCallerWait() async throws {
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.deadline")
    let probe = StallProbe()
    let syscall = StallGate()
    defer { syscall.open() }

    // The syscall is still stalled when the caller returns, so it was the deadline that ended
    // the wait.
    let (result, elapsed) = try await measure(within: watchdog) {
      await Task {
        try await executor.run(priority: .userInitiated, deadline: 0.2) {
          probe.hold(until: syscall)
        }
      }.result
    }
    #expect(failed(result, with: BlockingIOTimeout.self))
    #expect(elapsed >= 0.2, "returned before its own deadline (\(elapsed)s)")
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
    let syscall = StallGate()
    defer { syscall.open() }

    let victim = Task { try await runDetachedBlockingIO { probe.hold(until: syscall) } }
    try #require(await eventually(within: 10) { probe.didRun }, "the operation never ran")
    victim.cancel()

    let (result, _) = try await measure(within: watchdog) { await victim.result }
    #expect(failed(result, with: CancellationError.self))
  }
}
