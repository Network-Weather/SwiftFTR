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
    let holdSeconds: TimeInterval = 1.5
    let started = StartCounter()

    let holder = Task {
      try? await executor.run(priority: .userInitiated) {
        started.increment()
        Thread.sleep(forTimeInterval: holdSeconds)
      }
    }
    defer { holder.cancel() }
    while started.value == 0 { try await Task.sleep(nanoseconds: 5_000_000) }

    let timeout: TimeInterval = 0.05
    let start = monotonicNow()
    let result = try await CymruDNSResolver(executor: executor)
      .resolve(ipv4Addrs: ["8.8.8.8"], timeout: timeout)
    let elapsed = monotonicNow() - start

    // Queued behind the occupant, the query never starts, so nothing reaches the network.
    #expect(result.isEmpty)
    #expect(
      elapsed < holdSeconds / 2,
      "lookup waited \(elapsed)s for a slot; its deadline is \(cymruQueryDeadline(timeout: timeout))s"
    )
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
