import Foundation
import Testing

@testable import SwiftFTR

/// ``ReverseDNSLookup`` against the real system daemon.
///
/// The offline tests ask only for the names of 127.0.0.1 and ::1, which the daemon answers from
/// its local records ("localhost", from the hosts file) without sending a query: its log shows
/// the answer delivered on the local-only interface and no query sent. Any other address,
/// including other 127.x addresses and link-local ones, can make the daemon send a query, so
/// none is asked for here outside the live test. The live comparison with
/// `getnameinfo` asks for public resolver addresses and is skipped when `SKIP_NETWORK_TESTS` is
/// set.
@Suite
struct ReverseDNSLookupDaemonTests {
  static let watchdog: TimeInterval = 60
  static let loopback = ["127.0.0.1", "::1"]

  @Test("Loopback addresses are answered by the daemon, started and deallocated on their queue")
  func loopbackAnswers() async throws {
    let counting = CountingDNSService()
    for address in Self.loopback {
      let (outcome, _) = try await measure(within: Self.watchdog) {
        await counting.install { await ReverseDNSLookup.lookup(address, timeout: 120) }
      }
      #expect(outcome == .answer("localhost"), "\(address)")
    }
    try await Self.expectQuiet(counting, started: 2)
  }

  @Test("With every blocking-I/O worker held, a reverse lookup still answers")
  func answersWithEveryWorkerHeld() async throws {
    let held = await HeldExecutor.fill()
    defer { held.release() }
    let (outcome, _) = try await measure(within: Self.watchdog) {
      await TestSeams.$blockingIOExecutor.withValue(held.executor) {
        await ReverseDNSLookup.lookup("127.0.0.1", timeout: 120)
      }
    }
    // Answered while every worker was still held, so the lookup needed none.
    #expect(held.finished.value == 0)
    #expect(outcome == .answer("localhost"))
  }

  /// Deallocating a `DNSServiceRef` off its callback queue while callbacks are in flight crashed
  /// a stress loop in four of four runs (docs/BLOCKING-IO.md). This loop makes the races that
  /// would expose it: lookups that are answered, cancelled at varying moments around the start
  /// and the reply, and given deadlines that expire around them, many at once.
  @Test("Stress: answers, cancellations and deadlines racing the daemon's callbacks")
  func stress() async throws {
    let counting = CountingDNSService()
    let iterations = 3000
    let limiter = _ConcurrencySemaphore(maxConcurrent: 32)
    let tally = OutcomeTally()
    let (_, elapsed) = try await measure(within: 300) {
      await counting.install {
        // In waves smaller than the limiter, so a lookup starts when it is created and the
        // cancellation and deadline times below are measured from its start.
        for wave in stride(from: 0, to: iterations, by: 24) {
          await withTaskGroup(of: Void.self) { group in
            for i in wave..<min(wave + 24, iterations) {
              let address = Self.loopback[i % 2]
              let step = (i / 3) % 25
              switch i % 3 {
              case 0:
                group.addTask {
                  tally.add(
                    await ReverseDNSLookup.lookup(address, timeout: 120, limiter: limiter),
                    as: "answered")
                }
              case 1:
                // Cancelled after 0 to 24 ms: before the start, during it, or racing the reply.
                group.addTask {
                  let task = Task {
                    await ReverseDNSLookup.lookup(address, timeout: 120, limiter: limiter)
                  }
                  try? await Task.sleep(nanoseconds: UInt64(step) * 1_000_000)
                  task.cancel()
                  tally.add(await task.value, as: "cancelled")
                }
              default:
                // A deadline of 1 to 25 ms, which fires around the start and the reply.
                group.addTask {
                  let timeout = 0.001 * Double(1 + step)
                  tally.add(
                    await ReverseDNSLookup.lookup(address, timeout: timeout, limiter: limiter),
                    as: "deadline")
                }
              }
            }
          }
        }
      }
    }
    let counts = tally.counts
    print(
      "rDNS stress: \(iterations) lookups in \(String(format: "%.1f", elapsed)) s: \(counts)")
    #expect(counts.values.reduce(0, +) == iterations)
    let expected: Set<String> = [
      "answered answer", "cancelled answer", "cancelled cancelled", "deadline answer",
      "deadline timedOut",
    ]
    #expect(Set(counts.keys).isSubset(of: expected), "\(counts)")
    // Every lookup resumed exactly once, with an outcome its group allows. How the racing groups
    // split between their two outcomes depends on the daemon's speed, so it is printed above and
    // not asserted; the orders themselves are forced, and asserted, against the fake daemon in
    // ReverseDNSLookupTests.
    for group in ["answered", "cancelled", "deadline"] {
      let total = counts.filter { $0.key.hasPrefix(group + " ") }.values.reduce(0, +)
      #expect(total == iterations / 3, "\(group): \(counts)")
    }
    let snapshot = try await Self.expectQuiet(counting, started: nil)
    #expect(snapshot.maxLive <= 32)
  }

  @Test("The limiter bounds the daemon connections open at once")
  func limiterBoundsDescriptors() async throws {
    // The first starts wait until four references are open, so the overlap is certain.
    let counting = CountingDNSService(holdUntilLive: 4)
    let limiter = _ConcurrencySemaphore(maxConcurrent: 4)
    let count = 64
    let (outcomes, _) = try await measure(within: Self.watchdog) {
      await counting.install {
        await withTaskGroup(of: ReverseDNSLookupOutcome.self) { group in
          for i in 0..<count {
            group.addTask {
              await ReverseDNSLookup.lookup(Self.loopback[i % 2], timeout: 120, limiter: limiter)
            }
          }
          var all: [ReverseDNSLookupOutcome] = []
          for await outcome in group { all.append(outcome) }
          return all
        }
      }
    }
    #expect(outcomes.allSatisfy { $0 == .answer("localhost") })
    let snapshot = try await Self.expectQuiet(counting, started: count)
    // Each reference held a descriptor of its own, and no more than four were open at once.
    #expect(snapshot.fds == count)
    #expect(snapshot.maxLive == 4, "the cap was reached and never exceeded")
  }

  @Test(
    "Live: the daemon's PTR answer matches getnameinfo",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")))
  func matchesGetnameinfo() async throws {
    try await NetworkTestGate.shared.withPermit {
      for address in ["1.1.1.1", "8.8.8.8", "127.0.0.1", "::1"] {
        let system = await Self.getnameinfoOffPool(address)
        let (outcome, _) = try await measure(within: Self.watchdog) {
          await ReverseDNSLookup.lookup(address, timeout: 120)
        }
        if let system {
          #expect(outcome == .answer(system), "\(address)")
        } else {
          Issue.record("getnameinfo found no name for \(address); the lookup said \(outcome)")
        }
      }
    }
  }

  /// Waits until every reference started has been deallocated, then checks each was started
  /// and deallocated on a lookup queue, and returns the counts.
  @discardableResult
  static func expectQuiet(_ counting: CountingDNSService, started: Int?) async throws
    -> (started: Int, deallocated: Int, live: Int, maxLive: Int, offQueue: Int, fds: Int)
  {
    try await waitBounded("every reference deallocated", within: watchdog) {
      _ = await eventually(within: 120) {
        let s = counting.snapshot
        return s.live == 0 && s.started == s.deallocated
      }
    }
    let snapshot = counting.snapshot
    if let started { #expect(snapshot.started == started) }
    #expect(snapshot.deallocated == snapshot.started)
    #expect(snapshot.live == 0)
    #expect(snapshot.offQueue == 0)
    return snapshot
  }

  /// `getnameinfo` on a thread of its own, so the blocking call holds no cooperative thread.
  static func getnameinfoOffPool(_ address: String) async -> String? {
    await withCheckedContinuation { continuation in
      Thread.detachNewThread { continuation.resume(returning: reverseDNS(address)) }
    }
  }
}

/// Counts outcomes by kind, from any thread.
final class OutcomeTally: @unchecked Sendable {
  private let lock = NSLock()
  private var byKind: [String: Int] = [:]

  func add(_ outcome: ReverseDNSLookupOutcome, as group: String) {
    var kind: String
    switch outcome {
    case .answer(let name): kind = name == "localhost" ? "answer" : "answer \(name)"
    case .noSuchRecord: kind = "noSuchRecord"
    case .error(let error): kind = "error \(error)"
    case .timedOut: kind = "timedOut"
    case .cancelled: kind = "cancelled"
    }
    kind = group + " " + kind
    lock.lock()
    byKind[kind, default: 0] += 1
    lock.unlock()
  }

  var counts: [String: Int] {
    lock.lock()
    defer { lock.unlock() }
    return byKind
  }
}
