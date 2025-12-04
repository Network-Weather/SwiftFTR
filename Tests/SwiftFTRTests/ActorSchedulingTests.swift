import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// Spin-waits without suspending so we can simulate long synchronous actor work.
private func busySpin(for duration: TimeInterval) {
  let deadline = monotonicNow() + duration
  while monotonicNow() < deadline {
    _ = 1  // Prevent the optimizer from removing the loop
  }
}

/// Reproduces the pattern used in `PingExecutor`: spawn a `Task {}` from an actor while
/// immediately performing synchronous work, then measure when the task actually ran.
actor TaskInheritanceProbe {
  func spawnActorHoppingChild(spinDuration: TimeInterval) async -> TimeInterval {
    let start = monotonicNow()

    let child = Task {
      // Child immediately hops back to the actor, so it must wait until the actor yields.
      let started = await self.actorTimestamp()
      return started - start
    }

    busySpin(for: spinDuration)
    return await child.value
  }

  func spawnDetachedNonActorChild(spinDuration: TimeInterval) async -> TimeInterval {
    let start = monotonicNow()

    let child = Task.detached(priority: .userInitiated) {
      let started = monotonicNow()
      return started - start
    }

    busySpin(for: spinDuration)
    return await child.value
  }

  private func actorTimestamp() async -> TimeInterval {
    await Task.yield()
    return monotonicNow()
  }
}

/// Mirrors Multipath's `withTaskGroup` pattern where every child immediately calls
/// back into the same actor, demonstrating serialized execution despite the task group.
actor TaskGroupSerializationProbe {
  func runFlows(count: Int, spinPerFlow: TimeInterval) async -> TimeInterval {
    let start = monotonicNow()

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<count {
        group.addTask {
          await self.performFlow(spinDuration: spinPerFlow)
        }
      }
    }

    return monotonicNow() - start
  }

  private func performFlow(spinDuration: TimeInterval) async {
    busySpin(for: spinDuration)
  }
}

/// Tests for Swift concurrency scheduling behavior.
///
/// These tests verify the semantics of Task.detached vs Task{} and actor executor inheritance.
/// They document expected Swift runtime behavior for PingExecutor's design decisions.
@Suite("Actor Scheduling Regression Tests")
struct ActorSchedulingTests {

  @Test("Actor-bound Task waits for synchronous work to finish")
  func testActorBoundTaskDelaysUntilActorYields() async {
    let probe = TaskInheritanceProbe()
    let spinDuration = 0.2

    // Run multiple times and check consistency
    var delays: [TimeInterval] = []
    for _ in 0..<3 {
      let delay = await probe.spawnActorHoppingChild(spinDuration: spinDuration)
      delays.append(delay)
    }

    // At least one run should show the actor blocking pattern
    let maxDelay = delays.max() ?? 0
    #expect(
      maxDelay >= spinDuration * 0.8,
      "Child Task should be delayed while actor is busy (max observed: \(maxDelay)s)")
  }

  @Test("Detached Task starts faster than actor-bound Task", .disabled("Flaky under system load"))
  func testDetachedTaskStartsFasterThanActorBound() async {
    let probe = TaskInheritanceProbe()
    let spinDuration = 0.2

    // Measure both concurrently to ensure fair comparison under same load conditions
    // Run multiple trials and check relative behavior
    var detachedWonCount = 0
    let trials = 5

    for _ in 0..<trials {
      async let detachedDelay = probe.spawnDetachedNonActorChild(spinDuration: spinDuration)
      async let actorDelay = probe.spawnActorHoppingChild(spinDuration: spinDuration)

      let d = await detachedDelay
      let a = await actorDelay

      if d < a {
        detachedWonCount += 1
      }
    }

    // Detached should reliably start faster in most trials
    // Under extreme load, both may be delayed, but detached should still win
    #expect(
      detachedWonCount >= trials / 2,
      "Detached Task should start faster than actor-bound in most trials (\(detachedWonCount)/\(trials))"
    )
  }

  @Test("TaskGroup calling actor-isolated work still serializes")
  func testTaskGroupStillSerialWhenCallingActor() async {
    let probe = TaskGroupSerializationProbe()

    let flowCount = 5
    let spinPerFlow: TimeInterval = 0.05
    let elapsed = await probe.runFlows(count: flowCount, spinPerFlow: spinPerFlow)

    // Every child calls back into the same actor, so total time should ~= count * spin.
    let expected = Double(flowCount) * spinPerFlow * 0.8  // allow scheduler variance
    #expect(
      elapsed >= expected,
      "Actor-isolated flows should add up serially (expected ≥\(expected)s, saw \(elapsed)s)")
  }
}
