import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// A loopback UDP server that answers nothing until ``release()``, and from then on answers every
/// request, past and future, with a datagram no STUN client accepts.
///
/// A client blocked in `recv` on its connected socket returns once released, so a stalled STUN
/// attempt gives its executor slot back when the test is done with it.
final class HeldUDPServer: @unchecked Sendable {
  let port: UInt16
  let family: Int32
  let requests = FaultCounter()

  /// Owned by the serve thread, which closes it as it exits.
  private let fd: Int32
  private let lock = NSLock()
  private var stopped = false
  private var released = false
  private var releasedAt: TimeInterval?
  private var clients: [(sockaddr_storage, socklen_t)] = []

  init(family: Int32 = AF_INET) throws {
    self.family = family
    (fd, port) = try bindLoopback(family: family, type: SOCK_DGRAM)
    setReceiveTimeout(fd, seconds: 0.02)
    Thread { [self] in self.serve() }.start()
  }

  deinit { stop() }

  var host: String { family == AF_INET6 ? "::1" : "127.0.0.1" }

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
      lock.unlock()
      requests.increment()
    }
  }
}

/// Public-IP discovery against loopback fixtures only: STUN servers by numeric address through
/// `TestSeams.stunServers`, and the whoami fallback through `TestSeams.whoamiServers` and
/// `TestSeams.dnsServerPort`. Nothing here sends a packet off the host.
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

  /// A whoami TXT answer to `query`, in the form Akamai sends: the string `ip` then the address.
  static func whoamiAnswer(to query: [UInt8], ip: String) -> [UInt8] {
    let address = Array(ip.utf8)
    let rdata: [UInt8] = [2] + Array("ip".utf8) + [UInt8(address.count)] + address
    let record: [UInt8] =
      [0xC0, 0x0C, 0, 16, 0, 1, 0, 0, 0, 60, 0, UInt8(rdata.count)] + rdata
    return FaultInjectionWireTests.dnsResponse(to: query, answers: record)
  }

  static func servers(
    v4: [(host: String, port: UInt16)] = [], v6: [(host: String, port: UInt16)] = []
  ) -> TestSeams.STUNServers {
    { family in family == AF_INET6 ? v6 : v4 }
  }

  /// Runs `body` with STUN pointed at `servers`, the whoami fallback at `whoamiPort` on loopback
  /// (or at nothing), and every blocking attempt on `executor`.
  static func withFixtures<T>(
    servers: @escaping TestSeams.STUNServers, whoamiPort: UInt16? = nil,
    executor: BlockingIOExecutor, _ body: () async throws -> T
  ) async rethrows -> T {
    try await TestSeams.$blockingIOExecutor.withValue(executor) {
      try await TestSeams.$stunServers.withValue(servers) {
        try await TestSeams.$whoamiServers.withValue(whoamiPort == nil ? [] : ["127.0.0.1"]) {
          try await TestSeams.$dnsServerPort.withValue(whoamiPort) { try await body() }
        }
      }
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
    let answer = try LoopbackUDPResponder(family: answering) { request in
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
    for lookup in lookups { _ = try await measure(within: Self.watchdog) { await lookup.value } }

    let ran = try #require(ranAt.value)
    let released = try #require(silent.releaseTime)
    #expect(ran < released, "the unrelated task ran \(ran - released)s after the server answered")
  }

  // MARK: Classified discovery

  @Test("The whoami fallback answers while every executor slot is held")
  func whoamiWithEveryWorkerHeld() async throws {
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.pip-full")
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

    // The STUN attempt queues behind the occupant until its deadline; the whoami query needs no
    // slot. The budget and the DNS timeout both outlive the watchdog.
    let silent = try HeldUDPServer(family: AF_INET)
    defer { silent.stop() }
    let whoami = try LoopbackUDPResponder { query in
      (Self.whoamiAnswer(to: query, ip: "198.51.100.42"), 0)
    }
    defer { whoami.stop() }

    let (found, _) = try await measure(within: Self.watchdog) {
      try await Self.withFixtures(
        servers: Self.servers(v4: [(silent.host, silent.port)]), whoamiPort: whoami.port,
        executor: executor
      ) {
        try await publicIPDiscovery(
          family: .v4,
          stunTimeout: 0.2, dnsTimeout: 3 * Self.watchdog, interface: nil, sourceIP: nil,
          enableLogging: false, budget: 3 * Self.watchdog)
      }
    }
    #expect(found.address == "198.51.100.42")
    #expect(released.value == 0, "discovery waited for the occupant to free its slot")
    #expect(silent.requests.value == 0, "the STUN attempt ran although no slot was free")
    #expect(whoami.requests.value == 1)
  }

  @Test("Stalled STUN attempts and a silent fallback cannot keep discovery past its budget")
  func stalledAttemptsBoundedByBudget() async throws {
    let first = try HeldUDPServer(family: AF_INET)
    let second = try HeldUDPServer(family: AF_INET)
    defer {
      first.stop()
      second.stop()
    }
    let whoami = try LoopbackUDPResponder { _ in nil }
    defer { whoami.stop() }
    // One slot, so a call queued after the stalled attempt runs only once that attempt returns.
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.pip-budget")
    let servers = Self.servers(v4: [(first.host, first.port), (second.host, second.port)])

    // Each attempt and the fallback could each run past the watchdog on their own; only the
    // budget can end discovery inside it. The budget is the one real duration here, and
    // what is checked below must happen inside it: the first attempt sent within STUN's share
    // (four seconds) and the fallback asked in the four after. On a three-core CI runner with the
    // rest of the suite running, a one-second budget ended before the first attempt was sent.
    let outcome = try await measure(within: Self.watchdog) {
      await Self.withFixtures(servers: servers, whoamiPort: whoami.port, executor: executor) {
        do {
          return Result<PublicIPObservation, Error>.success(
            try await publicIPDiscovery(
              family: .v4,
              stunTimeout: Self.longSTUNTimeout, dnsTimeout: Self.longSTUNTimeout,
              interface: nil, sourceIP: nil, enableLogging: false, budget: 8))
        } catch {
          return .failure(error)
        }
      }
    }.0
    #expect(throws: PublicIPDiscoveryTimeout.self) { try outcome.get() }
    #expect(first.releaseTime == nil, "discovery returned only once its first server answered")
    // Each fixture counts a request on its own thread, so wait for the counts.
    let firstAsked = await eventually(within: 10) { first.requests.value == 1 }
    #expect(firstAsked, "the first server was asked \(first.requests.value) times")

    // STUN's share of the budget ends at half of it, so the fallback was asked inside the
    // budget, and the second server never got time.
    #expect(second.requests.value == 0)
    let fallbackAsked = await eventually(within: 10) { whoami.requests.value == 1 }
    #expect(fallbackAsked, "the fallback was asked \(whoami.requests.value) times")

    // The discovery itself ended, not only the wait for it: once the stalled attempt lets go of
    // its slot, nothing goes on to the next server or asks the fallback again.
    first.release()
    _ = try await measure(within: Self.watchdog) {
      try await executor.run(priority: .userInitiated) {}
    }
    let carriedOn = await eventually(within: 1) {
      second.requests.value > 0 || whoami.requests.value > 1
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
    let whoami = try LoopbackUDPResponder { _ in nil }
    defer { whoami.stop() }
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 2, name: "test.pip-deadline")
    let servers = Self.servers(v4: [(first.host, first.port), (second.host, second.port)])

    // No outer race here: only the deadline handed to each step can end this inside the watchdog,
    // since each attempt and each DNS query could run past it alone.
    let outcome = try await measure(within: Self.watchdog) {
      await Self.withFixtures(servers: servers, whoamiPort: whoami.port, executor: executor) {
        do {
          return Result<PublicIPObservation, Error>.success(
            try await getPublicIPv4(
              stunTimeout: Self.longSTUNTimeout, dnsTimeout: Self.longSTUNTimeout,
              deadline: monotonicNow() + 1))
        } catch {
          return .failure(error)
        }
      }
    }.0
    #expect(throws: PublicIPError.self) { try outcome.get() }
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

  @Test("The whoami fallback still answers when STUN server names cannot get an executor slot")
  func whoamiWhenSTUNNamesWaitForSlot() async throws {
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.pip-names")
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

    // Host names, as the built-in servers are, so each lookup queues for the held slot. Their
    // 64-character labels are rejected by the resolver without a query, should a lookup run.
    let names = ["a", "b"].map { String(repeating: $0, count: 64) + ".example" }
    let whoami = try LoopbackUDPResponder { query in
      (Self.whoamiAnswer(to: query, ip: "198.51.100.43"), 0)
    }
    defer { whoami.stop() }

    // The budget and the DNS timeout outlive the watchdog; only STUN's own share of the time,
    // two servers at 0.5 s, can let the fallback in.
    let (found, _) = try await measure(within: Self.watchdog) {
      try await Self.withFixtures(
        servers: Self.servers(v4: names.map { ($0, 3478) }), whoamiPort: whoami.port,
        executor: executor
      ) {
        try await publicIPDiscovery(
          family: .v4,
          stunTimeout: 0.5, dnsTimeout: 3 * Self.watchdog, interface: nil, sourceIP: nil,
          enableLogging: false, budget: 3 * Self.watchdog)
      }
    }
    #expect(found.address == "198.51.100.43")
    #expect(released.value == 0, "the lookups ran, so they were not waiting for the held slot")
    #expect(whoami.requests.value == 1)
  }

  @Test("STUN's share of the discovery budget, and what it leaves the fallback")
  func stunPhaseShare() {
    // The defaults: 6 s budget, two servers.
    #expect(
      stunPhaseDeadline(servers: 2, stunTimeout: 2, dnsTimeout: 3, start: 10, deadline: 16) == 14)
    #expect(
      stunPhaseDeadline(servers: 2, stunTimeout: 0.8, dnsTimeout: 2, start: 10, deadline: 16)
        == 11.6)
    // A budget too small for both: half the DNS timeout is kept for the fallback.
    #expect(
      stunPhaseDeadline(servers: 2, stunTimeout: 2, dnsTimeout: 3, start: 10, deadline: 13) == 11.5)
    // A budget smaller than the DNS timeout: half the budget.
    #expect(
      stunPhaseDeadline(servers: 2, stunTimeout: 2, dnsTimeout: 3, start: 10, deadline: 12) == 11)
    // No overall deadline: STUN's share alone.
    #expect(
      stunPhaseDeadline(servers: 2, stunTimeout: 2, dnsTimeout: 3, start: 10, deadline: nil) == 14)
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

  @Test(
    "A standalone STUN attempt that cannot get an executor slot is abandoned at its own deadline")
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

    // getPublicIPs has no budget, so only each attempt's own deadline, twice the 0.2 s
    // per-server timeout, can end a wait for a slot the occupant holds past the watchdog.
    let (ips, _) = try await measure(within: Self.watchdog) {
      await Self.withFixtures(
        servers: Self.servers(v4: [(silent.host, silent.port), (silent.host, silent.port)]),
        executor: executor
      ) { await getPublicIPs(stunTimeout: 0.2) }
    }
    #expect(ips.v4 == nil)
    #expect(released.value == 0, "an attempt waited for the occupant to free its slot")
    #expect(silent.requests.value == 0, "an attempt ran although no slot was free")
  }

  // MARK: Whoami servers that refuse or cannot be reached

  /// How the first whoami server fails, and the `DNSError` its query throws.
  enum WhoamiFailure: String, CaseIterable, CustomTestStringConvertible, Sendable {
    /// ICMP port unreachable after the send: `connectionRefused`.
    case refused
    /// ICMP host unreachable after the send: `unreachable`.
    case hostUnreachable
    /// This machine has no route, so the send fails: `unreachable`.
    case noRoute
    var testDescription: String { rawValue }
  }

  /// A `recv` whose first call drains the datagram waiting and reports `code`, as the kernel does
  /// once an ICMP error has arrived for the connected socket; later calls are plain `recv`.
  static func firstReceiveFails(with code: Int32) -> TestSeams.ReceiveDatagram {
    let calls = FaultCounter()
    return { fd, buffer in
      calls.increment()
      let received = Darwin.recv(fd, buffer.baseAddress, buffer.count, 0)
      guard calls.value == 1 else { return received }
      Darwin.errno = code
      return -1
    }
  }

  /// A `send` whose first call fails with `code` and sends nothing; later calls are plain `send`.
  static func firstSendFails(with code: Int32) -> TestSeams.SendDatagram {
    let calls = FaultCounter()
    return { fd, bytes in
      calls.increment()
      guard calls.value > 1 else {
        Darwin.errno = code
        return -1
      }
      return Darwin.send(fd, bytes.baseAddress, bytes.count, 0)
    }
  }

  @Test(
    "A whoami server that refuses or cannot be reached is passed over at once for the next",
    arguments: WhoamiFailure.allCases)
  func whoamiFailurePassedOver(failure: WhoamiFailure) async throws {
    let whoami = try LoopbackUDPResponder { query in
      (Self.whoamiAnswer(to: query, ip: "198.51.100.44"), 0)
    }
    defer { whoami.stop() }

    // Each server is asked for longer than the watchdog, so only a failure that ends the first
    // query at once lets the second answer in time.
    let (found, _) = try await measure(within: Self.watchdog) {
      try await TestSeams.$whoamiServers.withValue(["127.0.0.1", "127.0.0.1"]) {
        try await TestSeams.$dnsServerPort.withValue(whoami.port) {
          switch failure {
          case .refused, .hostUnreachable:
            let code = failure == .refused ? ECONNREFUSED : EHOSTUNREACH
            return try await TestSeams.$receiveDatagram.withValue(
              Self.firstReceiveFails(with: code)
            ) {
              try await getPublicIPv4ViaDNS(timeout: 3 * Self.watchdog)
            }
          case .noRoute:
            return try await TestSeams.$sendDatagram.withValue(
              Self.firstSendFails(with: ENETUNREACH)
            ) {
              try await getPublicIPv4ViaDNS(timeout: 3 * Self.watchdog)
            }
          }
        }
      }
    }
    #expect(found.ip == "198.51.100.44")
    // A query that failed after its send reached the responder; one with no route did not.
    let expectedRequests = failure == .noRoute ? 1 : 2
    #expect(whoami.requests.value == expectedRequests)
  }

  @Test("With every whoami server refusing, discovery fails at once instead of timing out")
  func whoamiAllRefused() async throws {
    let refusing = try RefusingUDPPort()
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 1, name: "test.pip-refused")

    // No STUN servers, so the fallback decides. The budget and the DNS timeout outlive the
    // watchdog, so a refusal waited out as silence would fail the test at the watchdog.
    let (thrown, _) = try await measure(within: Self.watchdog) {
      await Self.withFixtures(
        servers: Self.servers(), whoamiPort: refusing.port, executor: executor
      ) {
        await TestSeams.$whoamiServers.withValue(["127.0.0.1", "127.0.0.1"]) { () -> Error? in
          do {
            _ = try await publicIPDiscovery(
              family: .v4,
              stunTimeout: 0.2, dnsTimeout: 3 * Self.watchdog, interface: nil, sourceIP: nil,
              enableLogging: false, budget: 3 * Self.watchdog)
            return nil
          } catch {
            return error
          }
        }
      }
    }
    // A definite failure from both tiers, not the budget running out.
    guard case PublicIPError.allMethodsFailed(_, let dnsError)? = thrown else {
      Issue.record("expected allMethodsFailed, got \(String(describing: thrown))")
      return
    }
    #expect(dnsError.contains("No response from DNS servers"), "\(dnsError)")
  }
}
