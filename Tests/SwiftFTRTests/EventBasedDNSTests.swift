import Foundation
@_spi(Test) import SwiftFTR
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// DNS queries over the event-based UDP transport (`UDPExchange`), against loopback fixtures.
///
/// The stage gate is the first test: with every blocking-I/O worker held, a query still answers.
/// The rest cover the transport contract: refusals and empty datagrams, send pressure, setup
/// failure, cancellation, and that the socket is closed exactly once on every way out.
@Suite("Event-based DNS")
struct EventBasedDNSTests {
  /// Long enough that only an operation that is not going to return reaches it.
  static let watchdog: TimeInterval = 20

  // MARK: Stage gate

  @Test("With every blocking-I/O worker held, DNS queries and dnsProbe still answer")
  func answersWithEveryWorkerHeld() async throws {
    let server = try LoopbackUDPResponder { query in
      (FaultInjectionWireTests.dnsResponse(to: query, answers: FaultInjectionWireTests.aRecord), 0)
    }
    defer { server.stop() }
    let held = await HeldExecutor.fill()
    defer { held.release() }

    let (outcome, _) = try await measure(within: Self.watchdog) {
      try await TestSeams.$blockingIOExecutor.withValue(held.executor) {
        try await TestSeams.$dnsServerPort.withValue(server.port) {
          let query = try await SwiftFTR().dns.a(
            hostname: "gate.example", server: "127.0.0.1", timeout: 5)
          let probe = try await dnsProbe(server: "127.0.0.1", query: "gate.example", timeout: 5)
          return (query, probe)
        }
      }
    }

    // Both answered while every worker was still held, so neither waited for one, and no wait
    // for a worker can be part of the round-trip times they report.
    #expect(held.finished.value == 0)
    #expect(held.started.value == HeldExecutor.slots)
    let (query, probe) = outcome
    #expect(query.records.first.map { "\($0.data)" } == "\(DNSRecordData.ipv4("192.0.2.9"))")
    #expect(probe.isReachable)
    #expect(probe.responseCode == 0)
    #expect(probe.rtt != nil)
    #expect(server.requests.value == 2)
  }

  @Test("Round-trip time runs from sending the query to reading the reply")
  func roundTripTimeCoversTheExchange() async throws {
    let delay: TimeInterval = 0.2
    let server = try LoopbackUDPResponder { query in
      (
        FaultInjectionWireTests.dnsResponse(to: query, answers: FaultInjectionWireTests.aRecord),
        delay
      )
    }
    defer { server.stop() }

    let (query, probe) = try await TestSeams.$dnsServerPort.withValue(server.port) {
      (
        try await SwiftFTR().dns.a(hostname: "rtt.example", server: "127.0.0.1", timeout: 5),
        try await dnsProbe(server: "127.0.0.1", query: "rtt.example", timeout: 5)
      )
    }
    // Lower bounds only: the reply cannot arrive before the responder sends it.
    #expect(query.rttMs >= delay * 1000)
    #expect(try #require(probe.rtt) >= delay)
  }

  // MARK: Behavior changes

  @Test(
    "A refused port is reported at once as a refusal, not as silence",
    arguments: [AF_INET, AF_INET6])
  func refusedPort(family: Int32) async throws {
    let refusing = try RefusingUDPPort(family: family)
    let server = family == AF_INET6 ? "::1" : "127.0.0.1"
    // A refusal is answered at once; waiting out this timeout would mean it was not seen.
    let timeout: TimeInterval = 10

    let (outcome, _) = try await measure(within: timeout / 2) {
      try await TestSeams.$dnsServerPort.withValue(refusing.port) {
        let probe = try await dnsProbe(server: server, query: "refused.example", timeout: timeout)
        let thrown = await Self.error {
          try await SwiftFTR().dns.a(hostname: "refused.example", server: server, timeout: timeout)
        }
        return (probe, thrown)
      }
    }
    withExtendedLifetime(refusing) {}

    let (probe, thrown) = outcome
    // The host answered that nothing listens on the port: reachable host, no DNS server.
    #expect(probe.isReachable)
    #expect(probe.rtt != nil)
    #expect(probe.responseCode == nil)
    #expect(probe.error?.contains("refused") == true, "\(probe.error ?? "nil")")
    #expect(Self.isSendFailed(thrown), "\(String(describing: thrown))")
  }

  @Test("An empty datagram is a malformed reply: dnsProbe reports the server reachable")
  func emptyDatagram() async throws {
    let server = try LoopbackUDPResponder { _ in ([], 0) }
    defer { server.stop() }
    let timeout: TimeInterval = 10

    let (outcome, _) = try await measure(within: timeout / 2) {
      try await TestSeams.$dnsServerPort.withValue(server.port) {
        let probe = try await dnsProbe(
          server: "127.0.0.1", query: "empty.example", timeout: timeout)
        let thrown = await Self.error {
          try await SwiftFTR().dns.a(
            hostname: "empty.example", server: "127.0.0.1", timeout: timeout)
        }
        return (probe, thrown)
      }
    }

    let (probe, thrown) = outcome
    #expect(probe.isReachable)
    #expect(probe.rtt != nil)
    #expect(probe.error == "Malformed response")
    #expect(Self.isMalformed(thrown), "\(String(describing: thrown))")
  }

  // MARK: Send

  enum SendPressure: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case wouldBlock, noBufferSpace
    var errno: Int32 { self == .wouldBlock ? EAGAIN : ENOBUFS }
    var testDescription: String { rawValue }
  }

  @Test(
    "Send pressure is retried with the whole datagram and the query answers",
    arguments: SendPressure.allCases)
  func sendPressureIsRetried(pressure: SendPressure) async throws {
    let server = try LoopbackUDPResponder { query in
      (FaultInjectionWireTests.dnsResponse(to: query, answers: FaultInjectionWireTests.aRecord), 0)
    }
    defer { server.stop() }
    let attempts = FaultCounter()
    let failures = 3
    let send: TestSeams.SendDatagram = { fd, bytes in
      attempts.increment()
      guard attempts.value > failures else {
        Darwin.errno = pressure.errno
        return -1
      }
      return Darwin.send(fd, bytes.baseAddress, bytes.count, 0)
    }

    let (answers, _) = try await measure(within: Self.watchdog) {
      try await TestSeams.$sendDatagram.withValue(send) {
        try await __dnsQuery(
          server: "127.0.0.1", port: server.port, name: "pressure.example", type: 1, timeout: 5)
      }
    }
    #expect(answers.first?.rdata == Data([192, 0, 2, 9]))
    #expect(attempts.value == failures + 1)
    #expect(server.requests.value == 1)
  }

  enum SendFault: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case wouldBlockForever, noBufferSpaceForever, shortCount
    var testDescription: String { rawValue }
  }

  @Test(
    "A send that never leaves whole fails as a send failure, within the timeout",
    arguments: SendFault.allCases)
  func sendFailure(fault: SendFault) async throws {
    let server = try LoopbackUDPResponder { _ in nil }
    defer { server.stop() }
    let send: TestSeams.SendDatagram = { fd, bytes in
      switch fault {
      case .wouldBlockForever:
        Darwin.errno = EAGAIN
        return -1
      case .noBufferSpaceForever:
        Darwin.errno = ENOBUFS
        return -1
      case .shortCount:
        return Darwin.send(fd, bytes.baseAddress, bytes.count - 1, 0)
      }
    }
    let timeout: TimeInterval = 0.3

    let (thrown, _) = try await measure(within: Self.watchdog) {
      await TestSeams.$sendDatagram.withValue(send) {
        await Self.error {
          try await __dnsQuery(
            server: "127.0.0.1", port: server.port, name: "send.example", type: 1, timeout: timeout)
        }
      }
    }
    #expect(Self.isSendFailed(thrown), "\(String(describing: thrown))")
    if fault != .shortCount { #expect(server.requests.value == 0) }
  }

  // MARK: Setup

  @Test("A failure to make the socket non-blocking is reported, and nothing is sent")
  func nonBlockingFailure() async throws {
    let server = try LoopbackUDPResponder { _ in nil }
    defer { server.stop() }
    let fileControl: TestSeams.FileControl = { fd, command, argument in
      guard command == F_SETFL else { return fcntl(fd, command, argument) }
      Darwin.errno = EINVAL
      return -1
    }

    let thrown = await TestSeams.$fileControl.withValue(fileControl) {
      await Self.error {
        try await __dnsQuery(
          server: "127.0.0.1", port: server.port, name: "setup.example", type: 1, timeout: 1)
      }
    }
    guard case DNSError.setsockoptFailed(let option, let code)? = thrown else {
      Issue.record("expected setsockoptFailed, got \(String(describing: thrown))")
      return
    }
    #expect(option == "O_NONBLOCK")
    #expect(code == EINVAL)
    #expect(server.requests.value == 0)
  }

  // MARK: Cancellation and descriptor ownership

  @Test("Cancelling a query returns while the server is still silent")
  func cancellationWhileSilent() async throws {
    let server = try LoopbackUDPResponder { _ in nil }
    defer { server.stop() }
    let timeout: TimeInterval = 30
    let task = Task {
      try await TestSeams.$dnsServerPort.withValue(server.port) {
        try await SwiftFTR().dns.a(
          hostname: "cancel.example", server: "127.0.0.1", timeout: timeout)
      }
    }
    #expect(await eventually(within: Self.watchdog) { server.requests.value > 0 })
    task.cancel()

    let (thrown, _) = try await measure(within: Self.watchdog) {
      await Self.error { try await task.value }
    }
    #expect(thrown is CancellationError, "\(String(describing: thrown))")
  }

  enum Exit: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case answered, timedOut, refused, malformed, cancelled, setupFailed
    var testDescription: String { rawValue }
  }

  @Test("The socket is closed exactly once, before the caller resumes", arguments: Exit.allCases)
  func descriptorClosedOnce(exit: Exit) async throws {
    let server = try LoopbackUDPResponder { query in
      switch exit {
      case .answered:
        return (
          FaultInjectionWireTests.dnsResponse(to: query, answers: FaultInjectionWireTests.aRecord),
          0
        )
      case .malformed: return ([0xDE, 0xAD], 0)
      default: return nil
      }
    }
    defer { server.stop() }
    let refusing = exit == .refused ? try RefusingUDPPort() : nil
    defer { withExtendedLifetime(refusing) {} }
    let port = refusing?.port ?? server.port
    let ledger = DescriptorLedger(failSetup: exit == .setupFailed)
    let timeout: TimeInterval = exit == .timedOut ? 0.2 : 30

    let query = Task {
      await ledger.install {
        await Self.error {
          try await __dnsQuery(
            server: "127.0.0.1", port: port, name: "ledger.example", type: 1, timeout: timeout)
        }
      }
    }
    if exit == .cancelled {
      #expect(await eventually(within: Self.watchdog) { server.requests.value > 0 })
      query.cancel()
    }
    let (thrown, _) = try await measure(within: Self.watchdog) { await query.value }

    switch exit {
    case .answered: #expect(thrown == nil, "\(String(describing: thrown))")
    case .timedOut: #expect(Self.isTimeout(thrown), "\(String(describing: thrown))")
    case .refused: #expect(Self.isSendFailed(thrown), "\(String(describing: thrown))")
    case .malformed: #expect(Self.isMalformed(thrown), "\(String(describing: thrown))")
    case .cancelled: #expect(thrown is CancellationError, "\(String(describing: thrown))")
    case .setupFailed: #expect(thrown != nil)
    }

    // Read as soon as the query returned: the close happens before the caller is resumed.
    let record = ledger.snapshot
    #expect(record.closedDescriptors.count == 1, "closes: \(record.closedDescriptors)")
    if exit == .setupFailed {
      // Setup still owned the socket, so it closed it: the one it configured, and nothing else.
      #expect(record.closedDescriptors == record.configuredDescriptors)
      #expect(record.sentFromPorts.isEmpty)
    } else {
      // The socket that sent the query, identified by its bound local port, is the one closed.
      #expect(record.sentFromPorts.count == 1)
      #expect(record.closedPorts == record.sentFromPorts)
    }
  }

  // MARK: Helpers

  static func error<T>(_ body: () async throws -> T) async -> Error? {
    do {
      _ = try await body()
      return nil
    } catch {
      return error
    }
  }

  static func isSendFailed(_ error: Error?) -> Bool {
    if case DNSError.sendFailed? = error { return true }
    return false
  }

  static func isMalformed(_ error: Error?) -> Bool {
    if case DNSError.malformedResponse? = error { return true }
    return false
  }

  static func isTimeout(_ error: Error?) -> Bool {
    if case DNSError.timeout? = error { return true }
    return false
  }
}

/// A private blocking-I/O executor with every slot held by a blocker that waits on a gate, so a
/// test can show an operation finished without a worker.
final class HeldExecutor: Sendable {
  static let slots = 2

  let executor = BlockingIOExecutor(maximumConcurrentOperations: slots, name: "test.held-executor")
  let started = FaultCounter()
  let finished = FaultCounter()
  private let gate = StallGate()

  private init() {}

  /// Returns once every slot is held.
  static func fill(limit: TimeInterval = 60) async -> HeldExecutor {
    let held = HeldExecutor()
    for _ in 0..<slots {
      Task {
        try? await held.executor.run(priority: .userInitiated) {
          held.started.increment()
          held.gate.wait(limit: limit)
          held.finished.increment()
        }
      }
    }
    while held.started.value < slots { try? await Task.sleep(nanoseconds: 5_000_000) }
    return held
  }

  func release() { gate.open() }
}

/// Records which sockets a `UDPExchange` configured, sent from and closed, by descriptor and by
/// bound local port (fstat reports inode 0 for sockets, so it cannot tell them apart).
final class DescriptorLedger: @unchecked Sendable {
  struct Record {
    var configuredDescriptors: [Int32] = []
    var sentFromPorts: [UInt16] = []
    var closedDescriptors: [Int32] = []
    var closedPorts: [UInt16] = []
  }

  private let lock = NSLock()
  private var record = Record()
  private let failSetup: Bool

  init(failSetup: Bool = false) { self.failSetup = failSetup }

  var snapshot: Record {
    lock.lock()
    defer { lock.unlock() }
    return record
  }

  func install<T>(_ body: () async throws -> T) async rethrows -> T {
    let fileControl: TestSeams.FileControl = { [self] fd, command, argument in
      if command == F_SETFL {
        update { $0.configuredDescriptors.append(fd) }
        if failSetup {
          Darwin.errno = EINVAL
          return -1
        }
      }
      return fcntl(fd, command, argument)
    }
    let send: TestSeams.SendDatagram = { [self] fd, bytes in
      let sent = Darwin.send(fd, bytes.baseAddress, bytes.count, 0)
      let code = Darwin.errno
      if sent == bytes.count, let port = Self.localPort(fd) {
        update { $0.sentFromPorts.append(port) }
      }
      Darwin.errno = code
      return sent
    }
    let close: TestSeams.CloseDescriptor = { [self] fd in
      let port = Self.localPort(fd)
      update {
        $0.closedDescriptors.append(fd)
        if let port { $0.closedPorts.append(port) }
      }
      return Darwin.close(fd)
    }
    return try await TestSeams.$fileControl.withValue(fileControl) {
      try await TestSeams.$sendDatagram.withValue(send) {
        try await TestSeams.$closeDescriptor.withValue(close) { try await body() }
      }
    }
  }

  private func update(_ change: (inout Record) -> Void) {
    lock.lock()
    change(&record)
    lock.unlock()
  }

  static func localPort(_ fd: Int32) -> UInt16? {
    var address = sockaddr_storage()
    var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let result = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    guard result == 0 else { return nil }
    let port = withUnsafeBytes(of: address) {
      UInt16(bigEndian: $0.load(fromByteOffset: 2, as: UInt16.self))
    }
    return port == 0 ? nil : port
  }
}
