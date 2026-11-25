import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// A loopback STUN server that answers each binding request with the datagrams `replies` builds
/// from it, sent in order, once `gate` (when given) has opened. Anything that is not a binding
/// request is a stray (``DatagramFilter``) and is never answered.
final class ScriptedSTUNServer: @unchecked Sendable {
  let port: UInt16
  let family: Int32
  let requests = FaultCounter()

  /// Owned by the serve thread, which closes it as it exits.
  private let fd: Int32
  private let lock = NSLock()
  private var stopped = false

  init(
    family: Int32 = AF_INET, gate: StallGate? = nil,
    replies: @escaping @Sendable (_ request: [UInt8]) -> [[UInt8]]
  ) throws {
    self.family = family
    (fd, port) = try bindLoopback(family: family, type: SOCK_DGRAM)
    setReceiveTimeout(fd, seconds: 0.02)
    Thread { [self] in self.serve(gate: gate, replies: replies) }.start()
  }

  deinit { stop() }

  var host: String { family == AF_INET6 ? "::1" : "127.0.0.1" }
  var server: (host: String, port: UInt16) { (host, port) }

  /// Stops answering without waiting; the serve thread closes the socket within 20 ms.
  func stop() {
    lock.lock()
    stopped = true
    lock.unlock()
  }

  private func serve(gate: StallGate?, replies: ([UInt8]) -> [[UInt8]]) {
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
      let request = Array(buffer.prefix(n))
      guard DatagramFilter.stunBindingRequest.accepts(request) else { continue }
      requests.increment()
      gate?.wait(limit: 60)
      for reply in replies(request) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        _ = reply.withUnsafeBytes { raw in
          withUnsafePointer(to: &source) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
              sendto(fd, raw.baseAddress, raw.count, 0, $0, length)
            }
          }
        }
      }
    }
  }
}

/// STUN on the event-based transport, every server asked at once, and the rule for which answer
/// is believed.
///
/// Servers are loopback fixtures by numeric address (`TestSeams.stunServers`), or names that
/// `TestSeams.resolveSTUNServer` answers without a lookup. Nothing leaves the host. No test bounds
/// a call's duration from above: each runs under ``watchdog``, and every timeout that could end it
/// on the wrong path is ``longTimeout``, past the watchdog.
@Suite("Event-based STUN")
struct EventBasedSTUNTests {
  static let watchdog: TimeInterval = 20
  static let longTimeout: TimeInterval = 60

  static let mappedX: [UInt8] = [198, 51, 100, 7]
  static let mappedY: [UInt8] = [203, 0, 113, 9]

  /// A server answering every request with a binding success mapping `ip`.
  static func answering(_ ip: [UInt8], gate: StallGate? = nil) throws -> ScriptedSTUNServer {
    try ScriptedSTUNServer(family: ip.count == 16 ? AF_INET6 : AF_INET, gate: gate) { request in
      AsyncPublicIPDiscoveryTests.stunSuccess(for: request, ip: ip).map { [$0] } ?? []
    }
  }

  static func sweep(
    _ servers: [(host: String, port: UInt16)], timeout: TimeInterval = longTimeout,
    deadline: TimeInterval? = nil
  ) async throws -> Result<STUNPublicIP, Error> {
    try await measure(within: watchdog) {
      await TestSeams.$stunServers.withValue({ _ in servers }) {
        do {
          return Result<STUNPublicIP, Error>.success(
            try await stunGetPublicIPWithFallback(
              family: AF_INET, timeout: timeout, deadline: deadline))
        } catch {
          return .failure(error)
        }
      }
    }.0
  }

  // MARK: Replies that are not addressed to the request

  enum Foreign: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case empty, tooShort, wrongCookie, wrongTransaction
    var testDescription: String { rawValue }

    func datagram(answering request: [UInt8]) -> [UInt8] {
      var reply = AsyncPublicIPDiscoveryTests.stunSuccess(for: request, ip: mappedY)!
      switch self {
      case .empty: return []
      case .tooShort: return Array(reply.prefix(19))
      case .wrongCookie: reply[4] ^= 0xFF
      case .wrongTransaction: reply[19] ^= 0xFF
      }
      return reply
    }
  }

  @Test("A reply that is not a STUN reply to the request is ignored, and the real one taken")
  func foreignReplyIgnored() async throws {
    for foreign in Foreign.allCases {
      let server = try ScriptedSTUNServer { request in
        [
          foreign.datagram(answering: request),
          AsyncPublicIPDiscoveryTests.stunSuccess(for: request, ip: Self.mappedX)!,
        ]
      }
      defer { server.stop() }
      let (address, length) = loopbackAddress(family: AF_INET, port: server.port)
      let found = try await measure(within: Self.watchdog) {
        try await stunGetPublicIP(
          family: AF_INET, server: address, serverLen: length, serverLabel: "fixture",
          timeout: Self.longTimeout)
      }.0
      #expect(found.ip == "198.51.100.7", "after a \(foreign) datagram")
    }
  }

  @Test("An invalid reply carrying the transaction ID fails that server only, and at once")
  func invalidReplyFailsItsServerOnly() async throws {
    // A binding error response (0x0111) with the request's own transaction ID.
    let invalid = try ScriptedSTUNServer { request in
      var reply = AsyncPublicIPDiscoveryTests.stunSuccess(for: request, ip: Self.mappedY)!
      reply[1] = 0x11
      return [reply]
    }
    let healthy = try Self.answering(Self.mappedX)
    defer {
      invalid.stop()
      healthy.stop()
    }

    let alone = try await Self.sweep([invalid.server])
    #expect {
      try alone.get()
    } throws: { error in
      guard case STUNError.invalidResponse = error else { return false }
      return true
    }
    let beside = try await Self.sweep([invalid.server, healthy.server])
    #expect(try beside.get().ip == "198.51.100.7")
  }

  // MARK: The first answer decides

  @Test("A refused port does not delay the other servers")
  func refusedPortDoesNotDelay() async throws {
    let refusing = try RefusingUDPPort()
    let healthy = try Self.answering(Self.mappedX)
    defer { healthy.stop() }
    // Only the refusal ending its attempt at once lets the sweep decide inside the watchdog.
    let found = try await Self.sweep([("127.0.0.1", refusing.port), healthy.server]).get()
    #expect(found.ip == "198.51.100.7")
  }

  enum ReplyOrder: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case xFirst, yFirst
    var testDescription: String { rawValue }
  }

  /// `servers` asked through `entry` ("sweep" or "discovery"), with a long timeout and deadline.
  static func ask(_ entry: String, _ servers: [(host: String, port: UInt16)]) async -> Result<
    String, Error
  > {
    let list: TestSeams.STUNServers = { _ in servers }
    return await TestSeams.$stunServers.withValue(list) {
      do {
        if entry == "sweep" {
          return .success(
            try await stunGetPublicIPWithFallback(family: AF_INET, timeout: longTimeout).ip)
        }
        return .success(
          try await publicIPDiscovery(
            family: .v4, stunTimeout: longTimeout, interface: nil, sourceIP: nil,
            enableLogging: false, budget: 3 * watchdog)?.address ?? "none")
      } catch {
        return .failure(error)
      }
    }
  }

  @Test(
    "The first answer is returned at once, while a different one is still pending",
    arguments: ReplyOrder.allCases)
  func firstAnswerDecides(order: ReplyOrder) async throws {
    for entry in ["sweep", "discovery"] {
      // Both servers hold their replies; only the earlier one is ever released before the call
      // returns, so the later server's different answer is pending and cannot be consulted.
      let gateX = StallGate()
      let gateY = StallGate()
      defer {
        gateX.open()
        gateY.open()
      }
      let x = try Self.answering(Self.mappedX, gate: gateX)
      let y = try Self.answering(Self.mappedY, gate: gateY)
      defer {
        x.stop()
        y.stop()
      }
      let servers = [x.server, y.server]
      let call = Task { await Self.ask(entry, servers) }
      defer { call.cancel() }
      let bothAsked = await eventually(within: Self.watchdog) {
        x.requests.value == 1 && y.requests.value == 1
      }
      try #require(bothAsked, "\(entry): asked \(x.requests.value), \(y.requests.value)")
      (order == .xFirst ? gateX : gateY).open()
      let found = try await measure(within: Self.watchdog) { await call.value }.0
      let expected = order == .xFirst ? "198.51.100.7" : "203.0.113.9"
      #expect((try? found.get()) == expected, "\(entry): \(found)")
    }
  }

  enum Beside: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case silent, refusing, stalledName
    var testDescription: String { rawValue }
  }

  @Test(
    "A healthy server beside a failing one answers at once, not at the deadline",
    arguments: Beside.allCases)
  func healthyBesideFailing(beside: Beside) async throws {
    // The healthy server answers only once the other server's failure is in force: its request
    // has arrived, its refusal has been read, or its name lookup is stalled.
    let release = StallGate()
    let stall = StallGate()
    defer {
      release.open()
      stall.open()
    }
    let healthy = try Self.answering(Self.mappedX, gate: release)
    let silent = try HeldUDPServer(family: AF_INET)
    let refusing = try RefusingUDPPort()
    defer {
      healthy.stop()
      silent.stop()
    }
    let entered = FaultCounter()
    let stallEnded = FaultCounter()
    let resolve: TestSeams.ResolveSTUNServer = { _, _, _ in
      entered.increment()
      stall.wait(limit: 3 * Self.watchdog)
      stallEnded.increment()
      return nil
    }
    let refusals = FaultCounter()
    let receive: TestSeams.ReceiveDatagram = { fd, buffer in
      let n = recv(fd, buffer.baseAddress, buffer.count, 0)
      let code = errno
      if n < 0, code == ECONNREFUSED { refusals.increment() }
      errno = code
      return n
    }
    let other: (host: String, port: UInt16) =
      switch beside {
      case .silent: (silent.host, silent.port)
      case .refusing: ("127.0.0.1", refusing.port)
      case .stalledName: ("stalled.test", 3478)
      }
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 2, name: "test.stun-beside")

    let call = Task {
      await TestSeams.$blockingIOExecutor.withValue(executor) {
        await TestSeams.$resolveSTUNServer.withValue(resolve) {
          await TestSeams.$receiveDatagram.withValue(receive) {
            await Self.ask("discovery", [other, healthy.server])
          }
        }
      }
    }
    defer { call.cancel() }
    let inForce = await eventually(within: Self.watchdog) {
      guard healthy.requests.value == 1 else { return false }
      switch beside {
      case .silent: return silent.requests.value == 1
      case .refusing: return refusals.value == 1
      case .stalledName: return entered.value == 1
      }
    }
    try #require(inForce, "the \(beside) server's failure never took effect")
    release.open()
    // The deadline is three watchdogs out, so returning inside one is returning before it.
    let found = try await measure(within: Self.watchdog) { await call.value }.0
    #expect((try? found.get()) == "198.51.100.7", "\(found)")
    #expect(stallEnded.value == 0, "the stalled lookup ended before the answer was returned")
  }

  // MARK: One clock for the deadline

  /// A clock that reads `monotonicNow()` plus an offset a test can move, as a system sleep moves
  /// the real one while Dispatch's uptime clock stands still.
  final class MovableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0
    func jump(by seconds: TimeInterval) { lock.withLock { offset += seconds } }
    var now: @Sendable () -> TimeInterval {
      { monotonicNow() + self.lock.withLock { self.offset } }
    }
  }

  @Test("A reply read once the cutoff has passed on its own clock is not taken")
  func replyAfterCutoffNotTaken() async throws {
    let release = StallGate()
    defer { release.open() }
    let server = try Self.answering(Self.mappedX, gate: release)
    defer { server.stop() }
    let clock = MovableClock()
    let replies = FaultCounter()
    let receive: TestSeams.ReceiveDatagram = { fd, buffer in
      let n = recv(fd, buffer.baseAddress, buffer.count, 0)
      if n >= 20 { replies.increment() }
      return n
    }
    let fd = try makeBoundSTUNSocket(
      family: AF_INET, interface: nil, sourceIP: nil, enableLogging: false)
    let (address, length) = loopbackAddress(family: AF_INET, port: server.port)
    let cutoff = monotonicNow() + 3 * Self.watchdog
    let exchange = Task {
      await TestSeams.$monotonicClock.withValue(clock.now) {
        await TestSeams.$receiveDatagram.withValue(receive) {
          await Result {
            try await stunExchange(
              fd: fd, family: AF_INET, server: address, serverLen: length, serverLabel: "fixture",
              timeout: 3 * Self.watchdog, cutoff: cutoff)
          }
        }
      }
    }
    defer { exchange.cancel() }
    try #require(await eventually(within: Self.watchdog) { server.requests.value == 1 })
    // Past the cutoff on the deadline's clock, far short of it on Dispatch's.
    clock.jump(by: 6 * Self.watchdog)
    release.open()
    let outcome = try await measure(within: Self.watchdog) { await exchange.value }.0
    #expect(replies.value == 1, "the reply was never read")
    #expect(throws: STUNError.self) { try outcome.get() }
  }

  @Test("Nothing is sent once the cutoff has passed on its own clock")
  func noSendAfterCutoff() async throws {
    let server = try Self.answering(Self.mappedX)
    defer { server.stop() }
    let clock = MovableClock()
    clock.jump(by: 6 * Self.watchdog)
    let sends = FaultCounter()
    let send: TestSeams.SendDatagram = { fd, bytes in
      sends.increment()
      return Darwin.send(fd, bytes.baseAddress, bytes.count, 0)
    }
    let fd = try makeBoundSTUNSocket(
      family: AF_INET, interface: nil, sourceIP: nil, enableLogging: false)
    let (address, length) = loopbackAddress(family: AF_INET, port: server.port)
    let cutoff = monotonicNow() + 3 * Self.watchdog
    let outcome = try await measure(within: Self.watchdog) {
      await TestSeams.$monotonicClock.withValue(clock.now) {
        await Result {
          try await stunExchange(
            fd: fd, family: AF_INET, server: address, serverLen: length, serverLabel: "fixture",
            timeout: 3 * Self.watchdog, cutoff: cutoff, send: send)
        }
      }
    }.0
    #expect(sends.value == 0, "sent after the cutoff")
    #expect {
      try outcome.get()
    } throws: { error in
      guard case STUNError.sendFailed = error else { return false }
      return true
    }
  }

  // MARK: Entry with no time, or no permission, left

  @Test("A sweep or discovery with no time left, or a cancelled caller, sends nothing")
  func nothingSentWithoutTime() async throws {
    let healthy = try Self.answering(Self.mappedX)
    defer { healthy.stop() }
    let sends = FaultCounter()
    let send: TestSeams.SendDatagram = { fd, bytes in
      sends.increment()
      return Darwin.send(fd, bytes.baseAddress, bytes.count, 0)
    }
    let lookups = FaultCounter()
    let resolve: TestSeams.ResolveSTUNServer = { _, port, family in
      lookups.increment()
      return loopbackAddress(family: family, port: port)
    }
    let servers: TestSeams.STUNServers = { _ in [healthy.server, ("named.test", healthy.port)] }

    let executor = BlockingIOExecutor(maximumConcurrentOperations: 2, name: "test.stun-notime")
    try await TestSeams.$blockingIOExecutor.withValue(executor) {
      try await TestSeams.$stunServers.withValue(servers) {
        try await TestSeams.$sendSTUNRequest.withValue(send) {
          try await TestSeams.$resolveSTUNServer.withValue(resolve) {
            for budget in [0, -1, -TimeInterval.infinity, .nan] {
              await #expect(throws: PublicIPDiscoveryTimeout.self, "budget \(budget)") {
                try await publicIPDiscovery(
                  family: .v4, stunTimeout: 1, interface: nil, sourceIP: nil, enableLogging: false,
                  budget: budget)
              }
            }
            for deadline in [monotonicNow() - 1, -TimeInterval.infinity, .nan] {
              await #expect(throws: STUNError.self, "deadline \(deadline)") {
                try await stunGetPublicIPWithFallback(
                  family: AF_INET, timeout: 1, deadline: deadline)
              }
            }
            let cancelled = await PublicIPResolverTests.cancelledFirst {
              try await stunGetPublicIPWithFallback(family: AF_INET, timeout: 1)
            }
            #expect(throws: CancellationError.self) { try cancelled.get() }
            // A deadline too far out to be an instant is no deadline, not an overflow.
            for deadline in [TimeInterval.infinity, 1e300] {
              let found = try await TestSeams.$stunServers.withValue({ _ in [healthy.server] }) {
                try await stunGetPublicIPWithFallback(
                  family: AF_INET, timeout: 10, deadline: deadline)
              }
              #expect(found.ip == "198.51.100.7")
            }
          }
        }
      }
    }
    // Only the two far-deadline sweeps sent, each to its one server, and nothing was looked up.
    #expect(sends.value == 2, "sent \(sends.value) requests")
    #expect(lookups.value == 0, "looked up \(lookups.value) names")
  }

  @Test("An exchange whose setup outlasts the discovery deadline sends nothing")
  func setupPastDeadlineSendsNothing() async throws {
    let healthy = try Self.answering(Self.mappedX)
    defer { healthy.stop() }
    let budget: TimeInterval = 0.2
    // Making the socket non-blocking is the exchange's first setup step. Held from its own entry
    // until a budget has passed, it ends after the deadline, which was set before it was entered.
    let setups = FaultCounter()
    let fileControl: TestSeams.FileControl = { fd, command, argument in
      if command == F_GETFL {
        setups.increment()
        let entered = monotonicNow()
        while monotonicNow() < entered + budget + 0.05 { usleep(5_000) }
      }
      return fcntl(fd, command, argument)
    }
    let sends = FaultCounter()
    let send: TestSeams.SendDatagram = { fd, bytes in
      sends.increment()
      return Darwin.send(fd, bytes.baseAddress, bytes.count, 0)
    }

    // Its own executor, so no other sweep holds the admission it needs before setup.
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 2, name: "test.stun-setup")
    let outcome = try await measure(within: Self.watchdog) {
      await TestSeams.$blockingIOExecutor.withValue(executor) {
        await TestSeams.$stunServers.withValue({ _ in [healthy.server] }) {
          await TestSeams.$fileControl.withValue(fileControl) {
            await TestSeams.$sendSTUNRequest.withValue(send) {
              do {
                return Result<PublicIPObservation?, Error>.success(
                  try await publicIPDiscovery(
                    family: .v4, stunTimeout: Self.longTimeout, interface: nil, sourceIP: nil,
                    enableLogging: false, budget: budget))
              } catch {
                return .failure(error)
              }
            }
          }
        }
      }
    }.0
    #expect(throws: PublicIPDiscoveryTimeout.self) { try outcome.get() }
    #expect(setups.value == 1, "the exchange's setup ran \(setups.value) times")
    #expect(sends.value == 0, "a request was sent after the discovery deadline")
  }

  @Test("A name lookup with no time left is not submitted to the executor")
  func lookupWithNoTimeLeftNotSubmitted() async throws {
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 2, name: "test.stun-expired")
    let lookups = FaultCounter()
    let resolve: TestSeams.ResolveSTUNServer = { _, port, family in
      lookups.increment()
      return loopbackAddress(family: family, port: port)
    }
    try await TestSeams.$blockingIOExecutor.withValue(executor) {
      for deadline in [monotonicNow() - 1, monotonicNow(), -TimeInterval.infinity, .nan] {
        let found = try await lookUpSTUNServer(
          ("named.test", 3478), family: AF_INET, deadline: deadline, resolve: resolve)
        #expect(found == nil, "deadline \(deadline)")
      }
      #expect(executor.submissions.value == 0, "\(executor.submissions.value) lookups submitted")
      // Positive control: with time left the lookup is submitted and answers.
      let found = try await lookUpSTUNServer(
        ("named.test", 3478), family: AF_INET, deadline: monotonicNow() + Self.watchdog,
        resolve: resolve)
      #expect(found != nil)
      #expect(executor.submissions.value == 1)
    }
    #expect(lookups.value == 1, "\(lookups.value) lookups ran")
  }

  // MARK: The executor's slots

  @Test("With every executor slot held, discovery from servers given by address still answers")
  func answersWithEveryExecutorSlotHeld() async throws {
    let slots = 2
    let executor = BlockingIOExecutor(maximumConcurrentOperations: slots, name: "test.stun-full")
    let gate = StallGate()
    defer { gate.open() }
    let held = FaultCounter()
    for _ in 0..<slots {
      Task {
        try? await executor.run(priority: .userInitiated) {
          held.increment()
          gate.wait(limit: 3 * Self.watchdog)
        }
      }
    }
    try #require(await eventually(within: Self.watchdog) { held.value == slots })
    let first = try Self.answering(Self.mappedX)
    let second = try Self.answering(Self.mappedX)
    defer {
      first.stop()
      second.stop()
    }

    let ips = try await measure(within: Self.watchdog) {
      await TestSeams.$blockingIOExecutor.withValue(executor) {
        await TestSeams.$stunServers.withValue(
          AsyncPublicIPDiscoveryTests.servers(v4: [first.server, second.server])
        ) {
          await getPublicIPs(stunTimeout: Self.longTimeout)
        }
      }
    }.0
    #expect(ips.v4 == "198.51.100.7")
    #expect(held.value == slots, "a blocker let go of its slot")
  }
}
