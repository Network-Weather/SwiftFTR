import Foundation

/// One operation's overall deadline: an absolute instant on one clock, taken once and never reset.
///
/// A wait bounded by it is either handed the instant and holds it itself, or raced against it by
/// ``raceDeadline(until:arm:_:)``, never both, so an answer the work is entitled to give at the
/// instant cannot lose to a second timer aimed at the same one.
struct TraceDeadline: Sendable {
  /// The instant, on `clock`.
  let instant: TimeInterval
  /// The clock `instant` is on, captured where the deadline was taken: queues and workers cannot
  /// read the task-local test clock.
  let clock: DiscoveryClock

  init(instant: TimeInterval, clock: DiscoveryClock) {
    self.instant = instant
    self.clock = clock
  }

  /// `total` seconds from now on `clock`, or `nil` for positive infinity, which is no deadline.
  static func after(_ total: TimeInterval, clock: DiscoveryClock = .current) -> TraceDeadline? {
    guard total != .infinity else { return nil }
    return TraceDeadline(instant: clock.now() + total, clock: clock)
  }

  /// Whether the instant has passed.
  var hasPassed: Bool { clock.hasPassed(instant) }

  /// The cutoff for a phase whose own cap is `cap` seconds from now: the earlier of the two, and
  /// whether it is this deadline's instant. A tie is the instant, so the overall deadline decides.
  func cutoff(cap: TimeInterval) -> (instant: TimeInterval, overallBinds: Bool) {
    let own = clock.now() + cap
    return own < instant ? (own, false) : (instant, true)
  }

  /// Starts the wake-up for this deadline: `wake` runs once the instant has passed, unless the
  /// returned stop is called first. A stopped wake-up never runs `wake`.
  func armWake(_ wake: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
    let clock = clock
    let instant = instant
    let timer = Task {
      await clock.sleep(until: instant)
      if !Task.isCancelled { wake() }
    }
    return { timer.cancel() }
  }
}

/// Starts a wake-up that calls its argument at the deadline, and returns the function that stops it.
typealias ArmDeadlineWake = (_ wake: @escaping @Sendable () -> Void) -> @Sendable () -> Void

/// `work`'s value if it is committed before `deadline`, else ``DeadlineOutcome/expired``.
///
/// The work runs in a task of its own that this does not wait for, so work that never returns, or
/// ignores cancellation, cannot hold the caller; it is cancelled once the outcome is committed, and
/// the wake-up is stopped. A deadline already passed starts no work. A value or error committed
/// once the deadline has passed is expiry, decided under the race's lock. The calling task's
/// cancellation wins over expiry, but not over a value committed in time.
///
/// - Parameter arm: Starts the wake-up; by default `deadline`'s own (``TraceDeadline/armWake(_:)``).
/// - Throws: `CancellationError` when the calling task is cancelled, or the work's own error when
///   it throws in time.
func raceDeadline<Value: Sendable>(
  until deadline: TraceDeadline,
  arm: ArmDeadlineWake? = nil,
  _ work: @escaping @Sendable () async throws -> Value
) async throws -> DeadlineOutcome<Value> {
  try Task.checkCancellation()
  guard !deadline.hasPassed else { return .expired }
  let race = DeadlineRace<Value>(hasPassed: { deadline.hasPassed })
  let armWake = arm ?? deadline.armWake
  let outcome = try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { continuation in
      race.attach(continuation)
      let task = Task {
        do {
          race.commit(.answer(.success(try await work())))
        } catch {
          race.commit(.answer(.failure(error)))
        }
      }
      let stopWake = armWake { race.commit(.wake) }
      race.onFinish {
        task.cancel()
        stopWake()
      }
    }
  } onCancel: {
    race.commit(.cancellation)
  }
  if case .expired = outcome, Task.isCancelled { throw CancellationError() }
  return outcome
}
