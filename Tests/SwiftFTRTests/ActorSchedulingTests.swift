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

@Suite("Actor Scheduling Regression Tests")
struct ActorSchedulingTests {

  @Test("Actor-bound Task waits for synchronous work to finish")
  func testActorBoundTaskDelaysUntilActorYields() async {
    let probe = TaskInheritanceProbe()
    let delay = await probe.spawnActorHoppingChild(spinDuration: 0.2)

    // Because the child inherits the actor executor, it should not start until after the spin.
    #expect(
      delay >= 0.18,
      "Child Task should be delayed roughly as long as the actor stayed busy (\(delay)s observed)")
  }

  @Test("Detached Task can run immediately")
  func testDetachedTaskStartsImmediately() async {
    let probe = TaskInheritanceProbe()
    let delay = await probe.spawnDetachedNonActorChild(spinDuration: 0.2)

    // Detached tasks bypass the actor executor, so they should start near-instantly.
    #expect(
      delay < 0.05,
      "Detached Task should start immediately even while actor spins (\(delay)s observed)")
  }

  @Test("TaskGroup calling actor-isolated work still serializes")
  func testTaskGroupStillSerialWhenCallingActor() async {
    let probe = TaskGroupSerializationProbe()

    let flowCount = 5
    let spinPerFlow: TimeInterval = 0.05
    let elapsed = await probe.runFlows(count: flowCount, spinPerFlow: spinPerFlow)

    // Every child calls back into the same actor, so total time should ~= count * spin.
    let expected = Double(flowCount) * spinPerFlow * 0.9  // allow small scheduler variance
    #expect(
      elapsed >= expected,
      "Actor-isolated flows should add up serially (expected ≥\(expected)s, saw \(elapsed)s)")
  }
}
