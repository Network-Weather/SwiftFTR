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

  private let fd: Int32
  private let lock = NSLock()
  private var stopped = false
  private var released = false
  private var releasedAt: TimeInterval?
  private var clients: [(sockaddr_storage, socklen_t)] = []
  private let loopExited = DispatchSemaphore(value: 0)

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

  func stop() {
    release()
    lock.lock()
    let wasStopped = stopped
    stopped = true
    lock.unlock()
    guard !wasStopped else { return }
    loopExited.wait()
    lock.lock()
    close(fd)
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
    defer { loopExited.signal() }
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
        try await publicIPv4Discovery(
          stunTimeout: 0.2, dnsTimeout: 3 * Self.watchdog, interface: nil, sourceIP: nil,
          enableLogging: false, budget: 3 * Self.watchdog)
      }
    }
    #expect(found.ip == "198.51.100.42")
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
    // budget can end discovery inside it.
    let outcome = try await measure(within: Self.watchdog) {
      await Self.withFixtures(servers: servers, whoamiPort: whoami.port, executor: executor) {
        do {
          return Result<STUNPublicIP, Error>.success(
            try await publicIPv4Discovery(
              stunTimeout: Self.longSTUNTimeout, dnsTimeout: Self.longSTUNTimeout,
              interface: nil, sourceIP: nil, enableLogging: false, budget: 1))
        } catch {
          return .failure(error)
        }
      }
    }.0
    #expect(throws: PublicIPDiscoveryTimeout.self) { try outcome.get() }
    #expect(first.releaseTime == nil, "discovery returned only once its first server answered")
    #expect(first.requests.value == 1)

    // The discovery itself ended, not only the wait for it: once the stalled attempt lets go of
    // its slot, nothing goes on to the next server or the fallback.
    first.release()
    _ = try await measure(within: Self.watchdog) {
      try await executor.run(priority: .userInitiated) {}
    }
    let carriedOn = await eventually(within: 1) {
      second.requests.value > 0 || whoami.requests.value > 0
    }
    #expect(!carriedOn, "the abandoned discovery went on after its budget")
  }
}
