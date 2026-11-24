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

  // MARK: Servers asked at once

  @Test("A refused port does not delay the other servers")
  func refusedPortDoesNotDelay() async throws {
    let refusing = try RefusingUDPPort()
    let healthy = try Self.answering(Self.mappedX)
    defer { healthy.stop() }
    // Only the refusal ending its attempt at once lets the sweep decide inside the watchdog.
    let found = try await Self.sweep([("127.0.0.1", refusing.port), healthy.server]).get()
    #expect(found.ip == "198.51.100.7")
  }

  @Test("Two servers that agree answer at once, while a server listed first is still silent")
  func twoAgreeAnswerAtOnce() async throws {
    let silent = try HeldUDPServer(family: AF_INET)
    let first = try Self.answering(Self.mappedX)
    let second = try Self.answering(Self.mappedX)
    defer {
      silent.stop()
      first.stop()
      second.stop()
    }
    let found = try await Self.sweep([(silent.host, silent.port), first.server, second.server])
      .get()
    #expect(found.ip == "198.51.100.7")
    #expect(silent.releaseTime == nil, "the sweep answered only once the silent server did")
    #expect(silent.requests.value == 1, "the silent server was not asked alongside the others")
  }

  @Test("A healthy server beside a stalled name lookup yields its address at the deadline")
  func healthyBesideStalledName() async throws {
    let gate = StallGate()
    defer { gate.open() }
    let entered = FaultCounter()
    let stalled: TestSeams.ResolveSTUNServer = { _, _, _ in
      entered.increment()
      gate.wait(limit: 3 * Self.watchdog)
      return nil
    }
    let healthy = try Self.answering(Self.mappedX)
    defer { healthy.stop() }
    let budget: TimeInterval = 2

    let (found, elapsed) = try await measure(within: Self.watchdog) {
      try await TestSeams.$stunServers.withValue({ _ in
        [("stalled.test", 3478), healthy.server]
      }) {
        try await TestSeams.$resolveSTUNServer.withValue(stalled) {
          try await publicIPDiscovery(
            family: .v4, stunTimeout: Self.longTimeout, interface: nil, sourceIP: nil,
            enableLogging: false, budget: budget)
        }
      }
    }
    #expect(found?.address == "198.51.100.7")
    #expect(entered.value == 1)
    // Not early: one answer with another attempt still running is compared at the deadline.
    #expect(elapsed >= budget, "decided after \(elapsed)s, before the \(budget)s deadline")
  }

  enum ReplyOrder: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case xFirst, yFirst
    var testDescription: String { rawValue }
  }

  @Test(
    "Two servers that disagree yield no address, whichever replies first",
    arguments: ReplyOrder.allCases)
  func disagreementYieldsNone(order: ReplyOrder) async throws {
    // The later server answers only once the sweep has read the earlier one's reply.
    let later = StallGate()
    defer { later.open() }
    let x = try Self.answering(Self.mappedX, gate: order == .yFirst ? later : nil)
    let y = try Self.answering(Self.mappedY, gate: order == .xFirst ? later : nil)
    defer {
      x.stop()
      y.stop()
    }
    let earlierPort = order == .xFirst ? x.port : y.port
    let receive: TestSeams.ReceiveDatagram = { fd, buffer in
      let n = recv(fd, buffer.baseAddress, buffer.count, 0)
      var peer = sockaddr_in()
      var length = socklen_t(MemoryLayout<sockaddr_in>.size)
      let named = withUnsafeMutablePointer(to: &peer) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &length) }
      }
      if n >= 20, named == 0, UInt16(bigEndian: peer.sin_port) == earlierPort { later.open() }
      return n
    }

    for ask in ["sweep", "discovery"] {
      let outcome = try await measure(within: Self.watchdog) {
        await TestSeams.$stunServers.withValue({ _ in [x.server, y.server] }) {
          await TestSeams.$receiveDatagram.withValue(receive) {
            do {
              if ask == "sweep" {
                return Result<String, Error>.success(
                  try await stunGetPublicIPWithFallback(family: AF_INET, timeout: Self.longTimeout)
                    .ip)
              }
              return Result<String, Error>.success(
                try await publicIPDiscovery(
                  family: .v4, stunTimeout: Self.longTimeout, interface: nil, sourceIP: nil,
                  enableLogging: false, budget: 3 * Self.watchdog)?.address ?? "none")
            } catch {
              return .failure(error)
            }
          }
        }
      }.0
      var disagreed = false
      if case .failure(STUNError.serversDisagree(let addresses)) = outcome {
        disagreed = Set(addresses) == ["198.51.100.7", "203.0.113.9"]
      }
      #expect(disagreed, "\(ask): \(outcome)")
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
            let found = try await stunGetPublicIPWithFallback(
              family: AF_INET, timeout: 10, deadline: deadline)
            #expect(found.ip == "198.51.100.7")
          }
        }
      }
    }
    // Only the two far-deadline sweeps sent, each to both servers, with one lookup each.
    #expect(sends.value == 4, "sent \(sends.value) requests")
    #expect(lookups.value == 2, "looked up \(lookups.value) names")
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
