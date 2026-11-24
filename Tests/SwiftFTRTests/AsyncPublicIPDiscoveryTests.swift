import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// A loopback UDP server that answers nothing until ``release()``, and from then on answers every
/// STUN binding request, past and future, with a 4-byte datagram that is not a STUN reply, which
/// a STUN client ignores. Any other datagram is a stray (``DatagramFilter``): counted in
/// ``ignored``, never answered.
final class HeldUDPServer: @unchecked Sendable {
  let port: UInt16
  let family: Int32
  let requests = FaultCounter()
  let ignored = FaultCounter()

  /// Owned by the serve thread, which closes it as it exits.
  private let fd: Int32
  private let lock = NSLock()
  private var stopped = false
  private var released = false
  private var releasedAt: TimeInterval?
  private var firstRequestAt: TimeInterval?
  private var clients: [(sockaddr_storage, socklen_t)] = []

  /// - Parameter gate: when given, the serve thread reads nothing until it opens.
  init(family: Int32 = AF_INET, readsAfter gate: StallGate? = nil) throws {
    self.family = family
    (fd, port) = try bindLoopback(family: family, type: SOCK_DGRAM)
    setReceiveTimeout(fd, seconds: 0.02)
    Thread { [self] in
      gate?.wait(limit: 60)
      self.serve()
    }.start()
  }

  deinit { stop() }

  /// Datagrams waiting on the socket (`SO_NUMRCVPKT`), or -1 once stopped.
  var queued: Int32 {
    lock.lock()
    defer { lock.unlock() }
    return stopped ? -1 : queuedDatagrams(fd)
  }

  var host: String { family == AF_INET6 ? "::1" : "127.0.0.1" }

  /// When the first binding request was read, stamped on the serve thread; `nil` until then.
  var firstRequestTime: TimeInterval? {
    lock.lock()
    defer { lock.unlock() }
    return firstRequestAt
  }

  /// When ``release()`` was first called, stamped on the releasing thread; `nil` while held.
  var releaseTime: TimeInterval? {
    lock.lock()
    defer { lock.unlock() }
    return releasedAt
  }

  func release() {
    lock.lock()
    defer { lock.unlock() }
    guard !released else { return }
    released = true
    releasedAt = monotonicNow()
    for (address, length) in clients { answer(address, length) }
    clients = []
  }

  /// Releases every held client, then stops answering, without waiting: the serve thread closes
  /// the socket when it next wakes, within its 20 ms receive timeout. Safe to call from `defer` in
  /// an async test, since it parks no thread.
  func stop() {
    release()
    lock.lock()
    stopped = true
    lock.unlock()
  }

  /// Called with `lock` held, so the descriptor cannot be closed under it.
  private func answer(_ address: sockaddr_storage, _ length: socklen_t) {
    guard !stopped else { return }
    var destination = address
    let garbage: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
    _ = garbage.withUnsafeBytes { raw in
      withUnsafePointer(to: &destination) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          sendto(fd, raw.baseAddress, raw.count, 0, $0, length)
        }
      }
    }
  }

  private func serve() {
    // The serve thread owns `fd`. It closes it under the lock that `answer` checks `stopped`
    // under, and only once `stopped` is set, so nothing sends on the number after it is closed
    // and perhaps handed to another test's socket.
    defer {
      lock.lock()
      close(fd)
      lock.unlock()
    }
    var buffer = [UInt8](repeating: 0, count: 2048)
    while true {
      lock.lock()
      let done = stopped
      lock.unlock()
      if done { return }
      var source = sockaddr_storage()
      var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
      let n = buffer.withUnsafeMutableBytes { raw in
        withUnsafeMutablePointer(to: &source) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &length)
          }
        }
      }
      guard n >= 0 else { continue }
      guard DatagramFilter.stunBindingRequest.accepts(Array(buffer.prefix(n))) else {
        ignored.increment()
        continue
      }
      lock.lock()
      // A request that arrives after `stop()` is neither counted nor answered.
      guard !stopped else {
        lock.unlock()
        return
      }
      if released {
        answer(source, length)
      } else {
        clients.append((source, length))
      }
      firstRequestAt = firstRequestAt ?? monotonicNow()
      lock.unlock()
      requests.increment()
    }
  }
}

/// Public-IP discovery against loopback fixtures only: STUN servers by numeric address through
/// `TestSeams.stunServers`, or by name through `TestSeams.resolveSTUNServer`, which maps each name
/// to a loopback fixture without a lookup. Nothing here sends a packet off the host.
///
/// No test bounds from above how long a call took. Each call runs under ``watchdog``, and every
/// timeout that could end it on the wrong path is set well past the watchdog.
@Suite("Async public-IP discovery")
struct AsyncPublicIPDiscoveryTests {
  static let watchdog: TimeInterval = 20
  /// A per-server STUN timeout, and so an attempt deadline, that outlives the watchdog.
  static let longSTUNTimeout: TimeInterval = 60

  // MARK: Fixtures

  /// A binding success response to `request` mapping `ip`, in the family of `ip`'s length.
  static func stunSuccess(for request: [UInt8], ip: [UInt8]) -> [UInt8]? {
    guard request.count >= 20 else { return nil }
    let transaction = Array(request[8..<20])
    let mask: [UInt8] = [0x21, 0x12, 0xA4, 0x42] + transaction
    let family: UInt8 = ip.count == 16 ? 0x02 : 0x01
    let xored = ip.indices.map { ip[$0] ^ mask[$0] }
    let attribute: [UInt8] =
      [0x00, 0x20, 0x00, UInt8(4 + ip.count), 0x00, family, 0x00, 0x00] + xored
    return [0x01, 0x01, 0x00, UInt8(attribute.count)] + Array(mask.prefix(4)) + transaction
      + attribute
  }

  static func servers(
    v4: [(host: String, port: UInt16)] = [], v6: [(host: String, port: UInt16)] = []
  ) -> TestSeams.STUNServers {
    { family in family == AF_INET6 ? v6 : v4 }
  }

  /// Runs `body` with STUN pointed at `servers` and every blocking attempt on `executor`.
  static func withFixtures<T>(
    servers: @escaping TestSeams.STUNServers, executor: BlockingIOExecutor,
    _ body: () async throws -> T
  ) async rethrows -> T {
    try await TestSeams.$blockingIOExecutor.withValue(executor) {
      try await TestSeams.$stunServers.withValue(servers) { try await body() }
    }
  }

  // MARK: Standalone getPublicIPs

  @Test("Cancelling the caller ends getPublicIPs while its STUN servers are still silent")
  func standaloneCancellation() async throws {
    let silent4 = try HeldUDPServer(family: AF_INET)
    let silent6 = try HeldUDPServer(family: AF_INET6)
    defer {
      silent4.stop()
      silent6.stop()
    }
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 4, name: "test.pip-cancel")
    let servers = Self.servers(
      v4: [(silent4.host, silent4.port)], v6: [(silent6.host, silent6.port)])

    let task = await Self.withFixtures(servers: servers, executor: executor) {
      Task { await getPublicIPs(stunTimeout: Self.longSTUNTimeout) }
    }
    let asked = await eventually(within: Self.watchdog) {
      silent4.requests.value > 0 && silent6.requests.value > 0
    }
    #expect(asked, "both sweeps never reached their server")

    task.cancel()
    let (ips, _) = try await measure(within: Self.watchdog) { await task.value }
    #expect(ips.v4 == nil)
    #expect(ips.v6 == nil)
    let stillSilent = silent4.releaseTime == nil && silent6.releaseTime == nil
    #expect(stillSilent, "getPublicIPs returned only once its servers answered")
  }

  @Test(
    "getPublicIPs returns the family that answered when the other fails",
    arguments: [AF_INET, AF_INET6])
  func partialResult(answering: Int32) async throws {
    let mapped: [UInt8] =
      answering == AF_INET6
      ? [0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x07] : [198, 51, 100, 7]
    let answer = try LoopbackUDPResponder(family: answering, accepts: .stunBindingRequest) {
      request in
      Self.stunSuccess(for: request, ip: mapped).map { ($0, 0) }
    }
    defer { answer.stop() }
    let failing: Int32 = answering == AF_INET6 ? AF_INET : AF_INET6
    let refusing = try RefusingUDPPort(family: failing)
    let host: (Int32) -> String = { $0 == AF_INET6 ? "::1" : "127.0.0.1" }
    let answerServer = (host: host(answering), port: answer.port)
    let refusingServer = (host: host(failing), port: refusing.port)
    let servers =
      answering == AF_INET6
      ? Self.servers(v4: [refusingServer], v6: [answerServer])
      : Self.servers(v4: [answerServer], v6: [refusingServer])
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 4, name: "test.pip-partial")

    let (ips, _) = try await measure(within: Self.watchdog) {
      await Self.withFixtures(servers: servers, executor: executor) {
        await getPublicIPs(stunTimeout: Self.longSTUNTimeout)
      }
    }
    if answering == AF_INET6 {
      #expect(ips.v6 == "2001:db8::7")
      #expect(ips.v4 == nil)
    } else {
      #expect(ips.v4 == "198.51.100.7")
      #expect(ips.v6 == nil)
    }
  }

  @Test("getPublicIPs waiting on silent servers leaves Swift's cooperative pool free")
  func standaloneLeavesPoolFree() async throws {
    // One more call than the pool has threads, each with an attempt stalled in `recv`. An attempt
    // made on a cooperative thread would hold it, and with every thread held no other task runs
    // until the server is released.
    let calls = ProcessInfo.processInfo.activeProcessorCount + 2
    let silent = try HeldUDPServer(family: AF_INET)
    defer { silent.stop() }
    let executor = BlockingIOExecutor(maximumConcurrentOperations: calls, name: "test.pip-pool")
    let servers = Self.servers(v4: [(silent.host, silent.port)])

    // Released from a thread outside the pool, once the unrelated task has run or the watchdog
    // has passed, whichever is first; a starved pool cannot be relied on to release itself.
    let unrelatedRan = DispatchSemaphore(value: 0)
    let ranAt = TimeStamp()
    Thread.detachNewThread {
      _ = unrelatedRan.wait(timeout: .now() + Self.watchdog)
      silent.release()
    }
    defer { unrelatedRan.signal() }

    let lookups = await Self.withFixtures(servers: servers, executor: executor) {
      (0..<calls).map { _ in Task { await getPublicIPs(stunTimeout: Self.longSTUNTimeout) } }
    }
    let allWaiting = await eventually(within: Self.watchdog) { silent.requests.value >= calls }
    #expect(allWaiting, "only \(silent.requests.value) of \(calls) attempts reached the server")

    await Task {
      ranAt.set(monotonicNow())
      unrelatedRan.signal()
    }.value
    // The server's answer is not a STUN reply and is ignored, so the calls end by cancellation.
    #expect(await eventually(within: Self.watchdog) { silent.releaseTime != nil })
    for lookup in lookups { lookup.cancel() }
    for lookup in lookups { _ = try await measure(within: Self.watchdog) { await lookup.value } }

    let ran = try #require(ranAt.value)
    let released = try #require(silent.releaseTime)
    #expect(ran < released, "the unrelated task ran \(ran - released)s after the server answered")
  }

  @Test("A held STUN server counts only binding requests, after strays queued ahead of one")
  func heldServerIgnoresStrays() async throws {
    // Several tests assert this server's exact request count.
    let gate = StallGate()
    defer { gate.open() }
    let silent = try HeldUDPServer(family: AF_INET, readsAfter: gate)
    defer { silent.stop() }
    #expect(Strays.send(to: silent.port))
    try #require(await eventually(within: 10) { silent.queued >= 2 }, "queued: \(silent.queued)")
    gate.open()
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.pip-strays")

    let lookup = await Self.withFixtures(
      servers: Self.servers(v4: [(silent.host, silent.port)]), executor: executor
    ) {
      Task { await getPublicIPs(stunTimeout: Self.longSTUNTimeout) }
    }
    #expect(await eventually(within: Self.watchdog) { silent.requests.value > 0 })
    #expect(silent.requests.value == 1)
    #expect(silent.ignored.value >= 2, "ignored: \(silent.ignored.value)")
    silent.release()
    // Its answer is not a STUN reply, so the call waits on until it is cancelled.
    lookup.cancel()
    let (ips, _) = try await measure(within: Self.watchdog) { await lookup.value }
    #expect(ips.v4 == nil, "the held server's garbage was taken as an answer")
  }

  // MARK: Classified discovery

  @Test("Stalled STUN servers, all asked at once, cannot keep discovery past its budget")
  func stalledAttemptsBoundedByBudget() async throws {
    let first = try HeldUDPServer(family: AF_INET)
    let second = try HeldUDPServer(family: AF_INET)
    defer {
      first.stop()
      second.stop()
    }
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.pip-budget")
    let servers = Self.servers(v4: [(first.host, first.port), (second.host, second.port)])

    // Each attempt could run past the watchdog on its own; only the budget can end discovery
    // inside it. The budget is the one real duration here, and the first attempt must be sent
    // inside it: on a three-core CI runner with the rest of the suite running, a one-second budget
    // ended before the first attempt was sent.
    let outcome = try await measure(within: Self.watchdog) {
      await Self.withFixtures(servers: servers, executor: executor) {
        do {
          return Result<PublicIPObservation?, Error>.success(
            try await publicIPDiscovery(
              family: .v4, stunTimeout: Self.longSTUNTimeout, interface: nil, sourceIP: nil,
              enableLogging: false, budget: 4))
        } catch {
          return .failure(error)
        }
      }
    }.0
    #expect(throws: PublicIPDiscoveryTimeout.self) { try outcome.get() }
    #expect(first.releaseTime == nil, "discovery returned only once its first server answered")
    // Both servers are asked at once, each once. Each fixture counts on its own thread.
    let bothAsked = await eventually(within: 10) {
      first.requests.value == 1 && second.requests.value == 1
    }
    #expect(bothAsked, "asked \(first.requests.value) and \(second.requests.value) times")

    // The discovery itself ended, not only the wait for it: nothing more is sent.
    first.release()
    second.release()
    let carriedOn = await eventually(within: 1) {
      first.requests.value + second.requests.value > 2
    }
    #expect(!carriedOn, "the abandoned discovery went on after its budget")
  }

  @Test("Every step of discovery shares one deadline, so their sum cannot pass it")
  func stepsShareOneDeadline() async throws {
    let first = try HeldUDPServer(family: AF_INET)
    let second = try HeldUDPServer(family: AF_INET)
    defer {
      first.stop()
      second.stop()
    }
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 2, name: "test.pip-deadline")
    let servers = Self.servers(v4: [(first.host, first.port), (second.host, second.port)])

    // No outer race here: only the deadline handed to each step can end this inside the watchdog,
    // since each attempt could run past it alone.
    let outcome = try await measure(within: Self.watchdog) {
      await Self.withFixtures(servers: servers, executor: executor) {
        do {
          return Result<STUNPublicIP, Error>.success(
            try await stunGetPublicIPWithFallback(
              family: AF_INET, timeout: Self.longSTUNTimeout, deadline: monotonicNow() + 1))
        } catch {
          return .failure(error)
        }
      }
    }.0
    #expect(throws: STUNError.self) { try outcome.get() }
    #expect(first.releaseTime == nil, "discovery returned only once its first server answered")
  }

  @Test("A STUN name lookup that cannot get an executor slot is abandoned at the deadline")
  func nameLookupBoundedByDeadline() async throws {
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.pip-lookup")
    let occupant = StallGate()
    defer { occupant.open() }
    let occupied = FaultCounter()
    let released = FaultCounter()
    Task {
      try? await executor.run(priority: .userInitiated) {
        occupied.increment()
        occupant.wait(limit: 3 * Self.watchdog)
        released.increment()
      }
    }
    #expect(await eventually(within: Self.watchdog) { occupied.value > 0 })

    // A name, so it needs the resolver and a slot. Its 64-character label is rejected by the
    // resolver without a query, should the lookup ever run.
    let name = String(repeating: "a", count: 64) + ".example"
    let outcome = try await measure(within: Self.watchdog) {
      await Self.withFixtures(servers: Self.servers(v4: [(name, 3478)]), executor: executor) {
        do {
          return Result<STUNPublicIP, Error>.success(
            try await stunGetPublicIPWithFallback(
              family: AF_INET, timeout: Self.longSTUNTimeout, deadline: monotonicNow() + 0.5))
        } catch {
          return .failure(error)
        }
      }
    }.0
    #expect(throws: STUNError.self) { try outcome.get() }
    #expect(released.value == 0, "the lookup waited for the occupant to free its slot")
  }

  struct DefiniteFailure: Error {}

  @Test("A failure at or after the deadline is a timeout, whichever timer noticed first")
  func discoveryOutcomeIsDeterministic() throws {
    let failed = Result<STUNPublicIP, Error>.failure(DefiniteFailure())
    // Just before the deadline: the definite failure.
    #expect(throws: DefiniteFailure.self) {
      try publicIPDiscoveryOutcome(failed, now: 9.999, deadline: 10, cancelled: false)
    }
    // At and just after it: the budget ran out, also when the discovery child finished first.
    for now in [10.0, 10.001] {
      #expect(throws: PublicIPDiscoveryTimeout.self) {
        try publicIPDiscoveryOutcome(failed, now: now, deadline: 10, cancelled: false)
      }
    }
    // The timer child's own timeout, before the clock read reaches the deadline, stays a timeout.
    #expect(throws: PublicIPDiscoveryTimeout.self) {
      try publicIPDiscoveryOutcome(
        Result<STUNPublicIP, Error>.failure(PublicIPDiscoveryTimeout()), now: 9.999, deadline: 10,
        cancelled: false)
    }
    // The caller's cancellation comes first.
    #expect(throws: CancellationError.self) {
      try publicIPDiscoveryOutcome(failed, now: 10.001, deadline: 10, cancelled: true)
    }
    // An address that was found is kept.
    let found = try publicIPDiscoveryOutcome(
      .success(STUNPublicIP(ip: "198.51.100.1")), now: 10.001, deadline: 10, cancelled: false)
    #expect(found.ip == "198.51.100.1")
  }

  @Test("A standalone STUN attempt needs no executor slot, and still ends at its own timeout")
  func standaloneAttemptBoundedWithoutSlot() async throws {
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.pip-cap")
    let occupant = StallGate()
    defer { occupant.open() }
    let occupied = FaultCounter()
    let released = FaultCounter()
    Task {
      try? await executor.run(priority: .userInitiated) {
        occupied.increment()
        occupant.wait(limit: 3 * Self.watchdog)
        released.increment()
      }
    }
    #expect(await eventually(within: Self.watchdog) { occupied.value > 0 })
    let silent = try HeldUDPServer(family: AF_INET)
    defer { silent.stop() }

    // getPublicIPs has no budget, so only each attempt's own 0.2 s timeout can end it inside the
    // watchdog; the occupant holds the only slot past it.
    let (ips, _) = try await measure(within: Self.watchdog) {
      await Self.withFixtures(
        servers: Self.servers(v4: [(silent.host, silent.port), (silent.host, silent.port)]),
        executor: executor
      ) { await getPublicIPs(stunTimeout: 0.2) }
    }
    #expect(ips.v4 == nil)
    #expect(released.value == 0, "an attempt waited for the occupant to free its slot")
    let asked = await eventually(within: 10) { silent.requests.value == 2 }
    #expect(asked, "\(silent.requests.value) of 2 attempts reached the server without a slot")
  }
}
