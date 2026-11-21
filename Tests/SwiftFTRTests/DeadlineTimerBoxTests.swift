import Foundation
import Testing

@testable import SwiftFTR

/// The deadline timer loses a race when the caller is cancelled between the cancellation check and
/// arming. libdispatch traps if a timer source is released without ever having been resumed, so
/// the losing path must still leave the source in a releasable state.
@Suite
struct DeadlineTimerBoxTests {

  @Test("Arming after cancellation neither crashes nor fires")
  func armAfterCancelIsInert() async throws {
    let fired = FiredFlag()

    // Repeat so a release that libdispatch defers still happens inside the test.
    for _ in 0..<200 {
      let box = DeadlineTimerBox()
      box.cancel()
      box.arm(after: 0.01) { fired.set() }
    }

    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(!fired.isSet, "a timer armed after cancellation fired")
  }

  @Test("Cancelling an armed timer stops it")
  func cancelStopsArmedTimer() async throws {
    let fired = FiredFlag()
    let box = DeadlineTimerBox()

    box.arm(after: 0.05) { fired.set() }
    box.cancel()

    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(!fired.isSet, "a cancelled timer fired")
  }
}

private final class FiredFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  var isSet: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func set() {
    lock.lock()
    value = true
    lock.unlock()
  }
}
