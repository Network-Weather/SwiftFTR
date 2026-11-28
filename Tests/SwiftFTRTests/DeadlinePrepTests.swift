import Foundation
import Testing

@testable import SwiftFTR

/// The pieces the overall deadline for classified traces is built from, each on a test clock:
/// ``TraceDeadline``, ``raceDeadline(until:arm:_:)`` and ``RDNSCache/batchLookup(_:until:)``.
/// Nothing in production uses them yet; these tests hold each to its contract on its own.
@Suite("Deadline preparation")
struct DeadlinePrepTests {
  struct Late: Error {}

  /// A deadline 30 s ahead on a clock the test moves, and a wake-up that counts how often it was
  /// armed and stopped, so a test can see that nothing is left running.
  final class Staging: @unchecked Sendable {
    let movable = MovableClock()
    let clock: DiscoveryClock
    let deadline: TraceDeadline
    let armed = FaultCounter()
    let stopped = FaultCounter()
    var wakes = true

    init() {
      clock = DiscoveryClock(now: movable.now, slice: 0.01)
      deadline = TraceDeadline(instant: clock.now() + 30, clock: clock)
    }

    func pass() { movable.jump(by: 31) }

    var arm: ArmDeadlineWake { { self.armCounting($0) } }

    func armCounting(_ wake: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
      armed.increment()
      var stop: @Sendable () -> Void = {}
      if wakes { stop = deadline.armWake(wake) }
      let stopWake = stop
      let stopped = self.stopped
      return {
        stopped.increment()
        stopWake()
      }
    }
  }

  @Test("A deadline's cutoff is the earlier instant, and a tie is the deadline's")
  func cutoff() {
    let staging = Staging()
    let deadline = staging.deadline
    let early = deadline.cutoff(cap: 10)
    #expect(!early.overallBinds && early.instant < deadline.instant)
    let late = deadline.cutoff(cap: 40)
    #expect(late.overallBinds && late.instant == deadline.instant)
    let frozen = DiscoveryClock(now: { 100 }, slice: 0.01)
    let tie = TraceDeadline(instant: 130, clock: frozen).cutoff(cap: 30)
    #expect(tie.overallBinds && tie.instant == 130)
    #expect(TraceDeadline.after(.infinity, clock: frozen) == nil)
    #expect(TraceDeadline.after(5, clock: frozen)?.instant == 105)
    #expect(!deadline.hasPassed)
    staging.pass()
    #expect(deadline.hasPassed)
  }

  @Test("A value in time is returned, and the wake-up is stopped")
  func valueInTime() async throws {
    let staging = Staging()
    let outcome = try await raceDeadline(until: staging.deadline, arm: staging.arm) { 7 }
    guard case .completed(let value) = outcome else {
      Issue.record("expected a value, got \(outcome)")
      return
    }
    #expect(value == 7)
    #expect(staging.armed.value == 1 && staging.stopped.value == 1)
  }

  @Test(
    "At the deadline the caller is released while the work still runs, and the work is cancelled")
  func expiry() async throws {
    let staging = Staging()
    let gate = StallGate()
    defer { gate.open() }
    let entered = FaultCounter()
    let workCancelled = FaultCounter()
    let race = Task {
      try await raceDeadline(until: staging.deadline, arm: staging.arm) {
        entered.increment()
        // Ignores cancellation, so only the race can release the caller.
        await withTaskCancellationHandler {
          await gate.waitAsync(limit: 60)
        } onCancel: {
          workCancelled.increment()
        }
        return 7
      }
    }
    #expect(await eventually(within: 20) { entered.value == 1 })
    staging.pass()
    let (outcome, _) = try await measure(within: 20) { try await race.value }
    guard case .expired = outcome else {
      Issue.record("expected expiry, got \(outcome)")
      return
    }
    #expect(staging.armed.value == 1 && staging.stopped.value == 1)
    #expect(await eventually(within: 20) { workCancelled.value == 1 })
  }

  @Test("A deadline already passed starts no work and arms no wake-up")
  func passedBeforeStart() async throws {
    let staging = Staging()
    staging.pass()
    let invoked = FaultCounter()
    let outcome = try await raceDeadline(until: staging.deadline, arm: staging.arm) {
      invoked.increment()
      return 7
    }
    guard case .expired = outcome else {
      Issue.record("expected expiry, got \(outcome)")
      return
    }
    #expect(invoked.value == 0 && staging.armed.value == 0)
  }

  @Test("A value or an error committed after the deadline is expiry", arguments: [false, true])
  func lateOutcome(throwing: Bool) async throws {
    let staging = Staging()
    staging.wakes = false
    let outcome = try await raceDeadline(until: staging.deadline, arm: staging.arm) {
      staging.pass()
      if throwing { throw Late() }
      return 7
    }
    guard case .expired = outcome else {
      Issue.record("expected expiry, got \(outcome)")
      return
    }
    #expect(staging.armed.value == 1 && staging.stopped.value == 1)
  }

  @Test(
    "The caller's cancellation releases it at once, also once the deadline has passed",
    arguments: [false, true])
  func cancellation(afterDeadline: Bool) async throws {
    let staging = Staging()
    // No wake-up runs, so only the cancellation can decide the race.
    staging.wakes = false
    let gate = StallGate()
    defer { gate.open() }
    let entered = FaultCounter()
    let race = Task {
      try await raceDeadline(until: staging.deadline, arm: staging.arm) {
        entered.increment()
        await gate.waitAsync(limit: 60)
        return 7
      }
    }
    #expect(await eventually(within: 20) { entered.value == 1 })
    if afterDeadline { staging.pass() }
    race.cancel()
    let (result, _) = try await measure(within: 20) { await resultOf { try await race.value } }
    #expect(throws: CancellationError.self) { try result.get() }
    #expect(staging.armed.value == 1 && staging.stopped.value == 1)
  }

  // MARK: - Reverse-DNS batch

  static let a = "192.0.2.1"
  static let b = "192.0.2.2"
  static let c = "192.0.2.3"

  /// A PTR resolver that answers `answers` at once and holds `gated` addresses until `gate` opens
  /// (ignoring cancellation), counting each address it is asked.
  final class ScriptedPTR: @unchecked Sendable {
    let gate = StallGate()
    private let lock = NSLock()
    private var asked: [String: Int] = [:]
    let answers: [String: ReverseDNSLookupOutcome]
    let gated: Set<String>
    /// The outcome a gated address gets once the gate opens: its answer, or `.cancelled` if its
    /// query was cancelled meanwhile.
    let cancelledQueries = FaultCounter()

    init(_ answers: [String: ReverseDNSLookupOutcome], gated: Set<String> = []) {
      self.answers = answers
      self.gated = gated
    }

    func count(_ address: String) -> Int { lock.withLock { asked[address, default: 0] } }

    var resolver: RDNSCache.Resolver {
      { question, _ in
        let address = [DeadlinePrepTests.a, DeadlinePrepTests.b, DeadlinePrepTests.c].first {
          ReverseDNSQuestion(address: $0) == question
        }
        guard let address else { return .noSuchRecord }
        self.lock.withLock { self.asked[address, default: 0] += 1 }
        if self.gated.contains(address) {
          await self.gate.waitAsync(limit: 60)
          if Task.isCancelled {
            self.cancelledQueries.increment()
            return .cancelled
          }
        }
        return self.answers[address] ?? .noSuchRecord
      }
    }
  }

  @Test("At the deadline a batch returns the answers it has, though the cache keeps none")
  func batchPartialsWithoutCache() async throws {
    let staging = Staging()
    let ptr = ScriptedPTR(
      [Self.a: .answer("a.example"), Self.b: .answer("b.example")], gated: [Self.b])
    defer { ptr.gate.open() }
    let cache = RDNSCache(maxSize: 0, lookupDeadline: 30, resolver: ptr.resolver)
    let kept = FaultCounter()
    let deadline = staging.deadline
    let batch = Task {
      await TestSeams.$observeBatchAnswer.withValue({ _ in kept.increment() }) {
        await cache.batchLookup([Self.a, Self.b], until: deadline)
      }
    }
    // A's answer is in the batch and B's query has been asked; only then does the deadline pass.
    #expect(await eventually(within: 20) { kept.value == 1 && ptr.count(Self.b) == 1 })
    staging.pass()
    let (result, _) = try await measure(within: 20) { await batch.value }
    #expect(result.names == [Self.a: "a.example"])
    #expect(result.cut)
    #expect(await cache.count == 0)
    // B's query still runs: the batch left it.
    #expect(await cache.inFlightCount == 1)
  }

  @Test(
    "Past the deadline a lookup starts no query and joins none; a cached answer still comes back")
  func noQueryAfterDeadline() async throws {
    let staging = Staging()
    let ptr = ScriptedPTR(
      [Self.a: .answer("a.example"), Self.b: .answer("b.example"), Self.c: .answer("c.example")],
      gated: [Self.b])
    defer { ptr.gate.open() }
    let cache = RDNSCache(lookupDeadline: 30, resolver: ptr.resolver)
    // A is cached; B's query is in flight, held at the gate.
    #expect(await cache.lookup(Self.a) == "a.example")
    let holder = Task { await cache.lookup(Self.b) }
    defer { holder.cancel() }
    #expect(await eventually(within: 20) { ptr.count(Self.b) == 1 })
    staging.pass()
    let (result, _) = try await measure(within: 20) {
      await cache.batchLookup([Self.a, Self.b, Self.c], until: staging.deadline)
    }
    #expect(result.names == [Self.a: "a.example"])
    #expect(result.cut)
    #expect(ptr.count(Self.c) == 0 && ptr.count(Self.b) == 1)
    #expect(await cache.inFlightCount == 1)
  }

  @Test("A query a batch left at its deadline runs on, and its answer is applied once")
  func sharedQueryRunsOn() async throws {
    let staging = Staging()
    let ptr = ScriptedPTR([Self.b: .answer("b.example")], gated: [Self.b])
    defer { ptr.gate.open() }
    let cache = RDNSCache(lookupDeadline: 30, resolver: ptr.resolver)
    let batch = Task { await cache.batchLookup([Self.b], until: staging.deadline) }
    #expect(await eventually(within: 20) { ptr.count(Self.b) == 1 })
    staging.pass()
    let (result, _) = try await measure(within: 20) { await batch.value }
    #expect(result.names.isEmpty && result.cut)
    ptr.gate.open()
    #expect(await eventually(within: 20) { await cache.count == 1 })
    #expect(ptr.cancelledQueries.value == 0)
    // The answer is cached: a later lookup asks nothing.
    #expect(await cache.lookup(Self.b) == "b.example")
    #expect(ptr.count(Self.b) == 1)
  }

  @Test("Without a deadline, or with one that does not pass, a batch gives today's result")
  func batchWithoutDeadlineIsToday() async throws {
    let answers: [String: ReverseDNSLookupOutcome] = [
      Self.a: .answer("a.example"), Self.b: .noSuchRecord, Self.c: .timedOut,
    ]
    let ips = [Self.a, Self.b, Self.c, Self.a]
    let today = await RDNSCache(resolver: ScriptedPTR(answers).resolver).batchLookup(ips)
    #expect(today == [Self.a: "a.example"])
    let none = await RDNSCache(resolver: ScriptedPTR(answers).resolver)
      .batchLookup(ips, until: nil)
    #expect(none.names == today && !none.cut)
    let far = await RDNSCache(resolver: ScriptedPTR(answers).resolver)
      .batchLookup(ips, until: Staging().deadline)
    #expect(far.names == today && !far.cut)
  }
}
