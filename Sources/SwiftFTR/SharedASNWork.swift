import Foundation

/// Receives ASN answers as a lookup learns them. An origin whose AS name is still pending is an
/// answer with an empty name; a later call can replace it with the named entry.
typealias ASNPublish = @Sendable ([String: ASNInfo]) -> Void

/// A built-in resolver: it is bounded by one absolute deadline, passed down unchanged from the
/// public call that took it, and it publishes answers as it learns them.
///
/// Two rules hold at every step of every built-in resolver:
///
/// - **A passed deadline starts nothing, and still returns everything already available without
///   I/O**: cache hits, a database another resolver already holds, and whatever running or
///   finished shared work has published.
/// - **Shared work runs on its own budget; a waiter's deadline bounds only the waiter.** A cache
///   flight runs for its own `timeout` (part of its identity) from when it starts, and the
///   database load runs to its end, whichever caller started them.
protocol PublishingASNResolver: ASNResolver {
  /// Resolves `addresses` until `deadline`, publishing each answer as it is learned and
  /// returning every answer it has.
  ///
  /// - Parameters:
  ///   - timeout: The public call's `timeout`, unchanged. It identifies a shared cache flight and
  ///     is what the DNS resolver validates; it is never a measure of time left.
  ///   - deadline: An instant on `DiscoveryClock.current` that bounds this caller's waits.
  ///   - publish: Receives answers as they are learned.
  func resolve(
    _ addresses: [String], timeout: TimeInterval, deadline: TimeInterval,
    publish: @escaping ASNPublish
  ) async throws -> [String: ASNInfo]
}

/// The deadline a public `resolve(ipv4Addrs:timeout:)` call takes on entry: `timeout` seconds from
/// now on the deadline clock. Zero, a negative value or NaN has already passed; infinity never
/// passes; a huge finite value is as good as infinity.
func asnDeadline(_ timeout: TimeInterval) -> TimeInterval {
  DiscoveryClock.current.now() + timeout
}

/// Work run once and shared by any number of waiters (a cache flight, a database load).
///
/// The work runs in a task of its own, which inherits the starting caller's task-local values but
/// not its cancellation, and which holds the work until it ends: nothing a waiter does stops it.
/// While it runs it publishes ASN answers per address; it ends with a value or an error. A waiter
/// can do one thing, ``wait(until:forwardingTo:)``: wait until the work ends, its deadline passes
/// or its task is cancelled, then read what has been published and the outcome, if there is one
/// yet. Starter or joiner alike, a waiter that gives a publish function receives everything
/// published before and during its wait, so a waiter that is itself shared work passes it on at
/// once, at any depth of nesting. A waiter leaves nothing registered behind it.
final class SharedASNWork<Value: Sendable>: @unchecked Sendable {
  /// What a waiter reads when its wait ends.
  struct Snapshot {
    /// Every answer published so far.
    let answers: [String: ASNInfo]
    /// How the work ended, or `nil` while it is still running.
    let outcome: Result<Value, Error>?
  }

  private let lock = NSLock()
  private var answers: [String: ASNInfo] = [:]
  private var outcome: Result<Value, Error>?
  private var waiters: [UInt64: (resume: CheckedContinuation<Void, Never>, forward: ASNPublish?)] =
    [:]
  private var nextWaiterID: UInt64 = 0

  /// Starts `body` at once. `body` receives the work's own publish function.
  init(_ body: @escaping @Sendable (_ publish: @escaping ASNPublish) async throws -> Value) {
    Task { [self] in
      let result: Result<Value, Error>
      do {
        result = .success(try await body { self.publish($0) })
      } catch {
        result = .failure(error)
      }
      self.end(result)
    }
  }

  /// Work that has already ended with `value`.
  init(finished value: Value) {
    outcome = .success(value)
  }

  /// Records `found`. An entry with an AS name is never replaced by one without, so answers only
  /// become more complete, whatever order they arrive in.
  func publish(_ found: [String: ASNInfo]) {
    let forwards = lock.withLock {
      for (address, info) in found {
        if info.name.isEmpty, let known = answers[address], !known.name.isEmpty { continue }
        answers[address] = info
      }
      return waiters.values.compactMap(\.forward)
    }
    for forward in forwards { forward(found) }
  }

  /// Waits until the work ends, `deadline` (an instant on `DiscoveryClock.current`; `nil` is none)
  /// passes, or the calling task is cancelled, then reads what the work has published. `forward`
  /// receives what was published before the wait, each publication during it, and the snapshot.
  ///
  /// The wait is a task group of at most two children, so neither outlives the call: one waits
  /// for the end, the other sleeps until the deadline, and the first to finish cancels the other.
  func wait(until deadline: TimeInterval?, forwardingTo forward: ASNPublish? = nil) async
    -> Snapshot
  {
    let clock = DiscoveryClock.current
    if !hasEnded, !clock.hasPassed(deadline) {
      await withTaskGroup(of: Void.self) { group in
        group.addTask { await self.waitForEnd(forwardingTo: forward) }
        if let deadline { group.addTask { await clock.sleep(until: deadline) } }
        await group.next()
        group.cancelAll()
      }
    }
    let snapshot = lock.withLock { Snapshot(answers: answers, outcome: outcome) }
    forward?(snapshot.answers)
    return snapshot
  }

  /// Waiters registered now. For tests, which check that a waiter that left left nothing.
  var waiterCount: Int { lock.withLock { waiters.count } }

  private var hasEnded: Bool { lock.withLock { outcome != nil } }

  private func end(_ result: Result<Value, Error>) {
    let waiting = lock.withLock {
      outcome = result
      defer { waiters.removeAll() }
      return Array(waiters.values)
    }
    for waiter in waiting { waiter.resume.resume() }
  }

  /// Suspends until the work ends or the calling task is cancelled, registered only meanwhile.
  private func waitForEnd(forwardingTo forward: ASNPublish?) async {
    let id = lock.withLock {
      nextWaiterID &+= 1
      return nextWaiterID
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        // A cancellation that came first has already run its handler and found nothing to
        // remove, so it is seen here instead.
        let known: [String: ASNInfo]? = lock.withLock {
          if outcome != nil || Task.isCancelled { return nil }
          waiters[id] = (continuation, forward)
          return answers
        }
        if let known { forward?(known) } else { continuation.resume() }
      }
    } onCancel: {
      lock.withLock { waiters.removeValue(forKey: id) }?.resume.resume()
    }
  }
}
