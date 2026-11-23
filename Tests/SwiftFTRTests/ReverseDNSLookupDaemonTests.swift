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
      "deadline timedOut", "deadline timedOutBeforeQuery",
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

  /// What this shows is the cap on queries: references from the start call to the deallocate.
  /// The descriptors themselves are closed a moment after the deallocate, on the lookup's queue,
  /// so the bound on open descriptors is checked by ``descriptorLimit()`` in a process of its
  /// own, by counting them.
  @Test("The limiter bounds the queries in flight, each with a daemon connection of its own")
  func limiterBoundsQueries() async throws {
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
    // Each reference held a descriptor of its own, and no more than four were in flight at once.
    #expect(snapshot.fds == count)
    #expect(snapshot.maxLive == 4, "the cap was reached and never exceeded")
  }

  /// The environment variable that makes ``DescriptorLimitChild`` run, in the child process.
  static let childVariable = "SWIFTFTR_RDNS_DESCRIPTOR_CHILD"

  /// In a process of its own, so lowering its descriptor limit cannot touch parallel tests: with
  /// the limit set to the descriptors open plus the cap plus two, far more lookups than the limit
  /// all answer, and the daemon connections open at once, counted from the process's own
  /// descriptor table at every start, never exceed the cap plus two.
  @Test(
    "With the descriptor limit just above the cap, many more lookups than the limit all answer",
    arguments: [1, 4, 16])
  func descriptorLimit(cap: Int) async throws {
    let arguments = CommandLine.arguments
    guard let bundleFlag = arguments.firstIndex(of: "--test-bundle-path"),
      bundleFlag + 1 < arguments.count
    else {
      Issue.record("cannot rerun the test bundle: no --test-bundle-path in \(arguments)")
      return
    }
    // The same runner and bundle, with only the child suite selected, once.
    let dropped: Set<String> = ["--filter", "--skip", "--maximum-repetitions", "--repeat-until"]
    var childArguments: [String] = []
    var index = 1
    while index < arguments.count {
      if dropped.contains(arguments[index]) {
        index += 2
        continue
      }
      childArguments.append(arguments[index])
      index += 1
    }
    childArguments += ["--filter", "DescriptorLimitChild"]
    var environment = ProcessInfo.processInfo.environment
    environment[Self.childVariable] = String(cap)
    environment.removeValue(forKey: "LIBDISPATCH_COOPERATIVE_POOL_STRICT")
    let output = try await Self.runChild(
      executable: arguments[0], arguments: childArguments, environment: environment)
    let report = output.output.split(separator: "\n").first { $0.hasPrefix("DESCRIPTORS ") }
    let reported = report.map(String.init) ?? "none"
    print("rDNS descriptor child (cap \(cap)): \(reported); exit \(output.status)")
    #expect(output.status == 0, "child failed:\n\(output.output.suffix(4000))")
    guard let report else {
      Issue.record("the child printed no DESCRIPTORS line:\n\(output.output.suffix(4000))")
      return
    }
    let fields = Dictionary(
      uniqueKeysWithValues: report.dropFirst("DESCRIPTORS ".count).split(separator: " ").compactMap
      { pair -> (String, Int)? in
        let parts = pair.split(separator: "=")
        guard parts.count == 2, let value = Int(parts[1]) else { return nil }
        return (String(parts[0]), value)
      })
    #expect(fields["failed"] == 0, "\(reported)")
    #expect(fields["answered"] == fields["lookups"], "\(reported)")
    let lookups = fields["lookups"] ?? 0
    let limit = fields["limit"] ?? .max
    #expect(lookups > limit, "\(reported)")
    let maxOpen = fields["maxOpen"] ?? .max
    #expect(maxOpen <= cap + 2, "\(reported)")
  }

  /// Runs a child process to completion off the cooperative pool and returns its exit status
  /// and combined output.
  static func runChild(
    executable: String, arguments: [String], environment: [String: String]
  ) async throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    return await withCheckedContinuation { continuation in
      Thread.detachNewThread {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        continuation.resume(
          returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
      }
    }
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
    case .timedOutBeforeQuery: kind = "timedOutBeforeQuery"
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

/// The child half of ``ReverseDNSLookupDaemonTests/descriptorLimit(cap:)``. It runs only in
/// the child process that test starts, which sets the environment variable to the cap.
@Suite(.serialized)
struct DescriptorLimitChild {
  static let cap = ProcessInfo.processInfo.environment[ReverseDNSLookupDaemonTests.childVariable]
    .flatMap { Int($0) }

  @Test(.enabled(if: cap != nil))
  func lookupsUnderALoweredDescriptorLimit() async throws {
    let cap = try #require(Self.cap)
    let sampler = DescriptorSampler()
    // Everything open now, plus the cap, plus two: a lookup that needed one more descriptor than
    // that would fail to start.
    let limit = DescriptorSampler.highestOpenDescriptor() + 1 + cap + 2
    var original = rlimit()
    getrlimit(RLIMIT_NOFILE, &original)
    var lowered = rlimit(rlim_cur: rlim_t(limit), rlim_max: original.rlim_max)
    #expect(setrlimit(RLIMIT_NOFILE, &lowered) == 0)
    let lookups = max(400, limit * 20)
    let limiter = _ConcurrencySemaphore(maxConcurrent: cap)
    let tally = OutcomeTally()
    await TestSeams.$dnsService.withValue(sampler.calls) {
      await withTaskGroup(of: Void.self) { group in
        for i in 0..<lookups {
          group.addTask {
            let address = ReverseDNSLookupDaemonTests.loopback[i % 2]
            tally.add(
              await ReverseDNSLookup.lookup(address, timeout: 120, limiter: limiter), as: "child")
          }
        }
      }
    }
    let counts = tally.counts
    let answered = counts["child answer"] ?? 0
    print(
      "DESCRIPTORS cap=\(cap) limit=\(limit) lookups=\(lookups) answered=\(answered) "
        + "failed=\(lookups - answered) maxOpen=\(sampler.maxOpen)")
  }
}

/// Counts the daemon connections (Unix-domain sockets) this process has open, from its own
/// descriptor table, each time a lookup's start call returns.
final class DescriptorSampler: @unchecked Sendable {
  private let lock = NSLock()
  private var highest = 0

  var maxOpen: Int {
    lock.lock()
    defer { lock.unlock() }
    return highest
  }

  var calls: DNSServiceCalls {
    let system = DNSServiceCalls.system
    return DNSServiceCalls(
      queryRecord: { [self] flags, interfaceIndex, name, context in
        let result = system.queryRecord(flags, interfaceIndex, name, context)
        let open = Self.openUnixSockets()
        lock.lock()
        highest = max(highest, open)
        lock.unlock()
        return result
      },
      setDispatchQueue: system.setDispatchQueue,
      deallocate: system.deallocate)
  }

  /// This process's open descriptors, from `proc_pidinfo`.
  static func openDescriptors() -> [proc_fdinfo] {
    let pid = getpid()
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return [] }
    let room = Int(size) / MemoryLayout<proc_fdinfo>.stride + 32
    var table = [proc_fdinfo](repeating: proc_fdinfo(), count: room)
    let filled = table.withUnsafeMutableBytes {
      proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
    }
    return Array(table.prefix(max(0, Int(filled) / MemoryLayout<proc_fdinfo>.stride)))
  }

  static func highestOpenDescriptor() -> Int {
    Int(openDescriptors().map(\.proc_fd).max() ?? 0)
  }

  static func openUnixSockets() -> Int {
    let pid = getpid()
    var count = 0
    for descriptor in openDescriptors()
    where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
      var info = socket_fdinfo()
      let size = Int32(MemoryLayout<socket_fdinfo>.size)
      if proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) > 0,
        info.psi.soi_family == AF_UNIX
      {
        count += 1
      }
    }
    return count
  }
}
