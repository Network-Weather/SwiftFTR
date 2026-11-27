import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// Forward resolution runs in an executor slot, its wait ends at one deadline, and cancellation
/// releases the caller during it (docs/BLOCKING-IO.md, Resolution Off The Actor; finding 5 in
/// docs/ROBUSTNESS-TESTING.md). Every stalled lookup waits on a gate that holds for `hold`, three
/// times the `watchdog`, so a call that returns within the watchdog returned while it was shut.
@Suite("Resolution off the actor")
struct ResolutionOffActorTests {
  static let watchdog: TimeInterval = 20
  static let hold: TimeInterval = 60

  /// A resolution seam that counts its entries, waits on `gate`, then fails.
  static func stalling(_ gate: StallGate, entered: FaultCounter) -> TestSeams.ResolveHost {
    { host, _ in
      entered.increment()
      gate.wait(limit: hold)
      throw TracerouteError.resolutionFailed(host: host, details: "stalled")
    }
  }

  /// An ICMP socket factory that counts its calls and makes nothing, so no test here can send.
  static func noSockets(_ count: FaultCounter) -> TestSeams.MakeICMPSocket {
    { _ in
      count.increment()
      throw TracerouteError.socketCreateFailed(errno: EPERM, details: "test: no sockets")
    }
  }

  static func isTimeout(_ error: Error) -> Bool {
    if case TracerouteError.resolutionFailed(_, let details) = error {
      return details == "timed out"
    }
    return false
  }

  enum Operation: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case trace, stream
    var testDescription: String { rawValue }
  }

  enum Canceller: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case callerTask, cancelActiveTraces, networkChanged
    var testDescription: String { rawValue }
  }

  // MARK: Off the actor, and released at once

  @Test(
    "A stalled forward resolution does not hold the tracer or its cancellation",
    arguments: Operation.allCases, Canceller.allCases)
  func forwardResolutionStall(operation: Operation, canceller: Canceller) async throws {
    let gate = StallGate()
    defer { gate.open() }
    let entered = FaultCounter()
    let sockets = FaultCounter()
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 2, name: "test.rdo-stall")
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 4, maxWaitMs: 1000, noReverseDNS: true))
    let stall = Self.stalling(gate, entered: entered)

    try await TestSeams.$blockingIOExecutor.withValue(executor) {
      try await TestSeams.$makeICMPSocket.withValue(Self.noSockets(sockets)) {
        try await TestSeams.$resolveHost.withValue(stall) {
          let task = Task { () async throws -> Int in
            switch operation {
            case .trace:
              _ = try await tracer.trace(to: "slow-resolver.test")
              return 0
            case .stream:
              var count = 0
              for try await _ in tracer.traceStream(to: "slow-resolver.test") { count += 1 }
              return count
            }
          }
          #expect(await eventually(within: Self.watchdog) { entered.value > 0 })

          // The cancellation itself is inside the watchdog: the tracer's because it is a call on
          // the actor a stalled resolution would hold, the caller's because the trace must return.
          let (outcome, _) = try await measure(within: Self.watchdog) {
            switch canceller {
            case .callerTask: task.cancel()
            case .cancelActiveTraces: await tracer.cancelActiveTraces()
            case .networkChanged: await tracer.networkChanged()
            }
            return await task.result
          }
          switch (operation, canceller, outcome) {
          case (.stream, .callerTask, .success(let hops)):
            #expect(hops == 0)
          case (.trace, .callerTask, .failure(let error)):
            #expect(error is CancellationError, "\(error)")
          case (_, .cancelActiveTraces, .failure(TracerouteError.cancelled)),
            (_, .networkChanged, .failure(TracerouteError.cancelled)):
            break
          default:
            Issue.record("\(operation) / \(canceller): \(outcome)")
          }
        }
      }
    }
    #expect(sockets.value == 0, "a trace cancelled during resolution went on to make its socket")
    #expect(await eventually(within: Self.watchdog) { await tracer.activeTraces.isEmpty })
  }

  @Test("Pings waiting on resolution hold no cooperative thread")
  func resolutionHoldsNoPoolThread() async throws {
    let gate = StallGate()
    defer { gate.open() }
    let entered = FaultCounter()
    let released = FaultCounter()
    let sockets = FaultCounter()
    let count = ProcessInfo.processInfo.activeProcessorCount + 2
    let executor = BlockingIOExecutor(maximumConcurrentOperations: count, name: "test.rdo-pool")
    let stall: TestSeams.ResolveHost = { host, _ in
      entered.increment()
      gate.wait(limit: Self.hold)
      released.increment()
      throw TracerouteError.resolutionFailed(host: host, details: "stalled")
    }
    let tracer = offlineTracer(SwiftFTRConfig())

    let pings = TestSeams.$blockingIOExecutor.withValue(executor) {
      TestSeams.$makeICMPSocket.withValue(Self.noSockets(sockets)) {
        TestSeams.$resolveHost.withValue(stall) {
          (0..<count).map { index in
            Task {
              _ = try? await tracer.ping(to: "stall-\(index).test", config: PingConfig(count: 1))
            }
          }
        }
      }
    }
    // Every ping is inside its lookup. Were those lookups on the cooperative pool, this wait and
    // the task below could run only once the gate gave up.
    #expect(await eventually(within: Self.watchdog) { entered.value == count })
    let ranWhileShut = try await measure(within: Self.watchdog) {
      await Task { released.value == 0 }.value
    }.0
    #expect(ranWhileShut, "an unrelated task ran only after the stalled lookups let go")
    gate.open()
    for ping in pings { await ping.value }
    #expect(sockets.value == 0)
  }

  // MARK: Literals and the full-executor gate

  @Test("With every main-executor slot held, a trace and pings to literal destinations complete")
  func literalsCompleteWithFullExecutor() async throws {
    let held = await HeldExecutor.fill(limit: Self.hold)
    defer { held.release() }
    let lane = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.rdo-lane")
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 1))
    defer { network.stop() }
    let auto = offlineTracer(SwiftFTRConfig(maxHops: 2, maxWaitMs: 2000, noReverseDNS: true))
    let forced = offlineTracer(
      SwiftFTRConfig(maxHops: 2, maxWaitMs: 2000, noReverseDNS: true, preferredFamily: .v4))
    let mainBefore = held.executor.submissions.value
    let laneBefore = lane.submissions.value
    // A clock that never moves, so a lookup queued behind the held slots would wait out the
    // watchdog rather than reach its deadline.
    let frozen: @Sendable () -> TimeInterval = { 1_000 }

    try await TestSeams.$blockingIOExecutor.withValue(held.executor) {
      try await TestSeams.$literalLookupExecutor.withValue(lane) {
        try await TestSeams.$monotonicClock.withValue(frozen) {
          try await network.install {
            let (results, _) = try await measure(within: Self.watchdog) {
              let traces = [
                try await auto.trace(to: "127.0.0.1"), try await forced.trace(to: "127.0.0.1"),
              ]
              let pings = [
                try await auto.ping(to: "127.0.0.1", config: PingConfig(count: 1)),
                try await auto.ping(to: "192.0.2.1", config: PingConfig(count: 1)),
              ]
              return (traces.map(\.reached), pings.map(\.statistics.received))
            }
            #expect(results.0 == [true, true])
            #expect(results.1 == [1, 1])
          }
        }
      }
    }
    #expect(held.executor.submissions.value - mainBefore == 0, "a literal waited for a main slot")
    // Only the non-loopback `.auto` literal needs the resolver, for NAT64.
    #expect(lane.submissions.value - laneBefore == 1)
    #expect(held.finished.value == 0)
  }

  @Test("Inline answers equal the resolver's, and only resolver inputs reach the seam")
  func inlineParity() async throws {
    let inline = [
      "127.0.0.1", "127.1.2.3", "::1", "::", "2001:db8::5", "2606:4700:4700::1111", "fd00::1",
      "::ffff:192.0.2.1", "64:ff9b::c000:201",
    ]
    let resolver = [
      "192.0.2.1", "10.0.0.1", "fe80::1", "fe80:1::1", "ff02::1", "fec0::1", "::1%lo0",
    ]
    // Literals only, so `getaddrinfo` asks no DNS server. Run on a thread of its own: it blocks.
    let mismatches = try await onOwnThread { () -> [String] in
      var found: [String] = []
      for host in inline {
        guard let mine = try inlineResolution(host: host, prefer: .auto) else {
          found.append("\(host): not answered inline")
          continue
        }
        let system = try blockingResolution(host: host, prefer: .auto, substitute: nil)
        var a = mine.address
        var b = system.address
        let sameBytes =
          mine.addressLen == system.addressLen
          && memcmp(&a, &b, Int(mine.addressLen)) == 0
        if !sameBytes || mine.canonical != system.canonical || mine.family != system.family {
          found.append("\(host): inline \(mine.canonical) vs getaddrinfo \(system.canonical)")
        }
      }
      for host in resolver where try inlineResolution(host: host, prefer: .auto) != nil {
        found.append("\(host): answered inline")
      }
      return found
    }
    #expect(mismatches.isEmpty, "\(mismatches)")

    let consulted = FaultCounter()
    let seam: TestSeams.ResolveHost = { host, prefer in
      consulted.increment()
      return try blockingResolution(host: "127.0.0.1", prefer: .v4, substitute: nil)
    }
    let forcedAndInline =
      inline.map { ($0, PreferredFamily.auto) } + [
        ("192.0.2.1", .v4), ("::1", .v6), ("::1", .v4), ("192.0.2.1", .v6), ("bad\u{0}name", .auto),
      ]
    TestSeams.$resolveHost.withValue(seam) {
      for (host, prefer) in forcedAndInline { _ = try? resolveHost(host: host, prefer: prefer) }
    }
    #expect(consulted.value == 0, "an input answered without a resolver reached the seam")
    TestSeams.$resolveHost.withValue(seam) {
      _ = try? resolveHost(host: "fe80:1::1", prefer: .auto)
      _ = try? resolveHost(host: "name.test", prefer: .v4)
    }
    #expect(consulted.value == 2)
  }

  // MARK: One deadline

  @Test("A lookup that outlives its deadline releases the ping while it is still running")
  func deadlineEndsTheWait() async throws {
    let gate = StallGate()
    defer { gate.open() }
    let entered = FaultCounter()
    let clock = MovableClock()
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.rdo-deadline")
    let tracer = offlineTracer(SwiftFTRConfig())

    let outcome = try await TestSeams.$blockingIOExecutor.withValue(executor) {
      try await TestSeams.$monotonicClock.withValue(clock.now) {
        try await TestSeams.$resolveHost.withValue(Self.stalling(gate, entered: entered)) {
          let task = Task { try await tracer.ping(to: "gated.test", config: PingConfig(count: 1)) }
          #expect(await eventually(within: Self.watchdog) { entered.value == 1 })
          return try await measure(within: Self.watchdog) {
            clock.jump(by: forwardResolutionLimit + 1)
            return await task.result
          }.0
        }
      }
    }
    guard case .failure(let error) = outcome, Self.isTimeout(error) else {
      Issue.record("expected the resolution timeout, got \(outcome)")
      return
    }
  }

  @Test("A lookup still queued at its deadline times out and is never run")
  func deadlineWhileQueued() async throws {
    let held = await HeldExecutor.fill(limit: Self.hold)
    defer { held.release() }
    let entered = FaultCounter()
    let clock = MovableClock()
    let seam: TestSeams.ResolveHost = { host, _ in
      entered.increment()
      throw TracerouteError.resolutionFailed(host: host, details: "ran")
    }
    let tracer = offlineTracer(SwiftFTRConfig())
    let before = held.executor.submissions.value

    let outcome = try await TestSeams.$blockingIOExecutor.withValue(held.executor) {
      try await TestSeams.$monotonicClock.withValue(clock.now) {
        try await TestSeams.$resolveHost.withValue(seam) {
          let task = Task { try await tracer.ping(to: "queued.test", config: PingConfig(count: 1)) }
          #expect(
            await eventually(within: Self.watchdog) { held.executor.submissions.value > before })
          return try await measure(within: Self.watchdog) {
            clock.jump(by: forwardResolutionLimit + 1)
            return await task.result
          }.0
        }
      }
    }
    if case .failure(let error) = outcome, Self.isTimeout(error) {
    } else {
      Issue.record("expected the resolution timeout, got \(outcome)")
    }
    held.release()
    // A sentinel queued after the expired lookup runs only once the workers have reached it.
    _ = try await held.executor.run(priority: .userInitiated) {}
    #expect(entered.value == 0, "a lookup whose wait had ended was run")
  }

  @Test(
    "An outcome that arrives after the deadline is a timeout, value or error",
    arguments: [false, true])
  func lateOutcomeIsTimeout(throwing: Bool) async throws {
    let clock = MovableClock()
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.rdo-late")
    let late: TestSeams.ResolveHost = { host, _ in
      clock.jump(by: 30)
      if throwing { throw TracerouteError.resolutionFailed(host: host, details: "late NXDOMAIN") }
      return try blockingResolution(host: "127.0.0.1", prefer: .v4, substitute: nil)
    }
    let outcome = await TestSeams.$blockingIOExecutor.withValue(executor) {
      await TestSeams.$monotonicClock.withValue(clock.now) {
        await TestSeams.$resolveHost.withValue(late) {
          let now = DiscoveryClock.current
          return await resultOf {
            try await resolveDestination(
              "late.test", prefer: .auto, until: now.now() + 20, clock: now)
          }
        }
      }
    }
    if case .failure(let error) = outcome, Self.isTimeout(error) {
    } else {
      Issue.record("expected the resolution timeout, got \(outcome)")
    }
  }

  // MARK: Cancellation

  @Test(
    "A ping cancelled during its lookup reports the cancellation, even when the lookup then fails")
  func pingCancelledDuringLookup() async throws {
    let gate = StallGate()
    defer { gate.open() }
    let entered = FaultCounter()
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.rdo-cancel")
    let tracer = offlineTracer(SwiftFTRConfig())

    let outcome = try await TestSeams.$blockingIOExecutor.withValue(executor) {
      try await TestSeams.$resolveHost.withValue(Self.stalling(gate, entered: entered)) {
        let task = Task { try await tracer.ping(to: "gated.test", config: PingConfig(count: 1)) }
        #expect(await eventually(within: Self.watchdog) { entered.value == 1 })
        return try await measure(within: Self.watchdog) {
          task.cancel()
          gate.open()  // the lookup now fails; the cancellation still decides
          return await task.result
        }.0
      }
    }
    if case .failure(let error) = outcome, error is CancellationError {
    } else {
      Issue.record("expected CancellationError, got \(outcome)")
    }
  }

  @Test("A ping cancelled while its lookup is queued is released and the lookup never runs")
  func pingCancelledWhileQueued() async throws {
    let held = await HeldExecutor.fill(limit: Self.hold)
    defer { held.release() }
    let entered = FaultCounter()
    let seam: TestSeams.ResolveHost = { host, _ in
      entered.increment()
      throw TracerouteError.resolutionFailed(host: host, details: "ran")
    }
    let tracer = offlineTracer(SwiftFTRConfig())
    let before = held.executor.submissions.value

    let outcome = try await TestSeams.$blockingIOExecutor.withValue(held.executor) {
      try await TestSeams.$resolveHost.withValue(seam) {
        let task = Task { try await tracer.ping(to: "queued.test", config: PingConfig(count: 1)) }
        #expect(
          await eventually(within: Self.watchdog) { held.executor.submissions.value > before })
        return try await measure(within: Self.watchdog) {
          task.cancel()
          return await task.result
        }.0
      }
    }
    if case .failure(let error) = outcome, error is CancellationError {
    } else {
      Issue.record("expected CancellationError, got \(outcome)")
    }
    held.release()
    _ = try await held.executor.run(priority: .userInitiated) {}
    #expect(entered.value == 0, "a withdrawn lookup was run")
  }

  @Test("A trace cancelled before probing makes no socket", arguments: ["127.0.0.1", "::1"])
  func handoffCheck(host: String) async throws {
    let sockets = FaultCounter()
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 2, maxWaitMs: 1000, noReverseDNS: true))
    let outcome = await TestSeams.$makeICMPSocket.withValue(Self.noSockets(sockets)) {
      let task = Task { () async throws -> TraceResult in
        withUnsafeCurrentTask { $0?.cancel() }
        return try await tracer.trace(to: host)
      }
      return await task.result
    }
    if case .failure(let error) = outcome, error is CancellationError {
    } else {
      Issue.record("expected CancellationError, got \(outcome)")
    }
    #expect(sockets.value == 0, "a cancelled trace made its socket after resolving \(host)")
  }

  // MARK: Probes spend one budget

  /// Counts `fcntl` calls, which the TCP and UDP probes make on their socket right after creating it.
  static func countingFileControl(_ count: FaultCounter) -> TestSeams.FileControl {
    { fd, command, argument in
      count.increment()
      return fcntl(fd, command, argument)
    }
  }

  @Test("A probe whose lookup outlives its timeout reports the failure and sets up no socket")
  func probeResolutionTimeout() async throws {
    let clock = MovableClock()
    let configured = FaultCounter()
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.rdo-probe")
    let late: TestSeams.ResolveHost = { _, _ in
      clock.jump(by: 61)
      return try blockingResolution(host: "127.0.0.1", prefer: .v4, substitute: nil)
    }
    let (tcp, udp) = try await TestSeams.$blockingIOExecutor.withValue(executor) {
      try await TestSeams.$monotonicClock.withValue(clock.now) {
        try await TestSeams.$fileControl.withValue(Self.countingFileControl(configured)) {
          try await TestSeams.$resolveHost.withValue(late) {
            try await measure(within: Self.watchdog) {
              (
                try await tcpProbe(config: TCPProbeConfig(host: "late.test", port: 9, timeout: 60)),
                try await udpProbe(config: UDPProbeConfig(host: "late.test", port: 9, timeout: 60))
              )
            }.0
          }
        }
      }
    }
    #expect(tcp.connectionState == .error && !tcp.isReachable && tcp.rtt == nil)
    #expect(tcp.error == "Failed to resolve hostname" && tcp.resolvedIP == "late.test")
    #expect(!udp.isReachable && udp.rtt == nil && udp.responseType == nil)
    #expect(udp.error == "Failed to resolve hostname" && udp.resolvedIP == "late.test")
    #expect(configured.value == 0, "a probe set up a socket with none of its timeout left")
  }

  @Test("A UDP probe waits only for what resolution left of its timeout")
  func probeSpendsOneBudget() async throws {
    let clock = MovableClock()
    let silent = try bindLoopback(family: AF_INET, type: SOCK_DGRAM)
    defer { close(silent.fd) }
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.rdo-budget")
    let slow: TestSeams.ResolveHost = { _, _ in
      clock.jump(by: 59.5)
      return try blockingResolution(host: "127.0.0.1", prefer: .v4, substitute: nil)
    }
    // The timeout outlasts the watchdog, so a probe given all of it fails the watchdog.
    let result = try await TestSeams.$blockingIOExecutor.withValue(executor) {
      try await TestSeams.$monotonicClock.withValue(clock.now) {
        try await TestSeams.$resolveHost.withValue(slow) {
          try await measure(within: Self.watchdog) {
            try await udpProbe(
              config: UDPProbeConfig(host: "silent.test", port: Int(silent.port), timeout: 60))
          }.0
        }
      }
    }
    #expect(result.responseType == "timeout", "\(result)")
    #expect(result.resolvedIP == "127.0.0.1")
  }
}
