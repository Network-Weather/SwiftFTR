import Foundation
import Testing

@testable import SwiftFTR

/// A Team Cymru lookup must stop waiting when the shared blocking-I/O executor has no free slot,
/// rather than waiting for however long sibling work holds every slot.
@Suite
struct CymruQueueDeadlineTests {

  @Test("A lookup queued behind a full executor gives up at its deadline")
  func queuedLookupIsBounded() async throws {
    // A private single-slot executor: one occupant fills it, and nothing else in the process is
    // starved while it is held.
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.cymru-deadline")
    // The occupant holds the slot until the test opens the gate, which it does only after the
    // lookup has returned. So a lookup that returns at all returned while the slot was still
    // taken; one that waits for the slot never returns and trips the watchdog instead. No bound
    // here depends on how fast the machine is.
    let occupant = StallGate()
    let watchdog: TimeInterval = 20
    let started = StartCounter()

    let holder = Task {
      try? await executor.run(priority: .userInitiated) {
        started.increment()
        occupant.wait(limit: watchdog * 2)
      }
    }
    defer {
      occupant.open()
      holder.cancel()
    }
    while started.value == 0 { try await Task.sleep(nanoseconds: 5_000_000) }

    let timeout: TimeInterval = 0.05
    let (result, _) = try await measure(within: watchdog) {
      try await CymruDNSResolver(executor: executor)
        .resolve(ipv4Addrs: ["8.8.8.8"], timeout: timeout)
    }

    // Queued behind the occupant, the query never starts, so nothing reaches the network.
    #expect(result.isEmpty)
  }
}

private final class StartCounter: @unchecked Sendable {
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
