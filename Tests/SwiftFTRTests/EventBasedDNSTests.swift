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

  @Test("Round-trip time includes a sending thread descheduled after the datagram left")
  func roundTripTimeStartsBeforeTheSend() async throws {
    let delay: TimeInterval = 0.2
    let server = try LoopbackUDPResponder { query in
      (
        FaultInjectionWireTests.dnsResponse(to: query, answers: FaultInjectionWireTests.aRecord),
        delay
      )
    }
    defer { server.stop() }
    // The datagram leaves, then the sender stalls until the reply is already waiting.
    let staged = FaultCounter()
    let send: TestSeams.SendDatagram = { fd, bytes in
      let sent = Darwin.send(fd, bytes.baseAddress, bytes.count, 0)
      let code = Darwin.errno
      if Self.waitUntilReadable(fd, limit: 4) { staged.increment() }
      Darwin.errno = code
      return sent
    }
    let query = try await TestSeams.$sendDatagram.withValue(send) {
      try await TestSeams.$dnsServerPort.withValue(server.port) {
        try await SwiftFTR().dns.a(hostname: "stall.example", server: "127.0.0.1", timeout: 5)
      }
    }
    try #require(staged.value == 1, "the reply never arrived while the sender was stalled")
    #expect(query.rttMs >= delay * 1000, "rttMs \(query.rttMs)")
  }

  @Test("A deadline that passes before the first send is a send failure, and nothing is sent")
  func deadlineBeforeTheFirstSend() async throws {
    let server = try LoopbackUDPResponder { _ in nil }
    defer { server.stop() }
    let attempts = FaultCounter()
    let send: TestSeams.SendDatagram = { fd, bytes in
      attempts.increment()
      return Darwin.send(fd, bytes.baseAddress, bytes.count, 0)
    }
    // 1 ns: the deadline is fixed when the exchange is created, and the first attempt runs only
    // after a hop to the exchange's queue, so it always starts after the deadline.
    let timeout: TimeInterval = 1e-9
    let (outcome, _) = try await measure(within: Self.watchdog) {
      try await TestSeams.$sendDatagram.withValue(send) {
        try await TestSeams.$dnsServerPort.withValue(server.port) {
          let thrown = await Self.error {
            try await __dnsQuery(
              server: "127.0.0.1", port: server.port, name: "late.example", type: 1,
              timeout: timeout)
          }
          let probe = try await dnsProbe(
            server: "127.0.0.1", query: "late.example", timeout: timeout)
          return (thrown, probe)
        }
      }
    }
    let (thrown, probe) = outcome
    #expect(Self.isSendFailed(thrown), "\(String(describing: thrown))")
    #expect(!probe.isReachable)
    #expect(probe.error == "Failed to send query")
    #expect(attempts.value == 0)
    // Give a datagram that did leave time to arrive before concluding none did.
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(server.requests.value == 0)
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
    // No DNS server answered, so the probe is unreachable; the message, and for the query
    // methods the error, tell the refusal apart from silence ("Timeout - no response", `timeout`).
    #expect(!probe.isReachable)
    #expect(probe.rtt == nil)
    #expect(probe.responseCode == nil)
    #expect(
      probe.error
        == "Connection refused - the host is up but no DNS server is listening on this port",
      "\(probe.error ?? "nil")")
    #expect(Self.isSendFailed(thrown), "\(String(describing: thrown))")
  }

  @Test("An empty datagram carries no transaction ID: it is ignored, and the query times out")
  func emptyDatagram() async throws {
    let server = try LoopbackUDPResponder { _ in ([], 0) }
    defer { server.stop() }
    let timeout: TimeInterval = 0.3

    let (outcome, _) = try await measure(within: Self.watchdog) {
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
    #expect(await eventually(within: Self.watchdog) { server.requests.value == 2 })
    #expect(probe.outcome == .timedOut)
    #expect(!probe.isReachable)
    #expect(probe.rtt == nil)
    #expect(Self.isTimeout(thrown), "\(String(describing: thrown))")
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

  /// Whether `fd` becomes readable, or has an error pending, within `limit` seconds. `poll` does
  /// not consume the datagram or clear the error, so the exchange still reads it afterwards.
  static func waitUntilReadable(_ fd: Int32, limit: TimeInterval) -> Bool {
    let giveUp = monotonicNow() + limit
    while true {
      var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let remaining = Int32(max(0, (giveUp - monotonicNow()) * 1000))
      let ready = poll(&descriptor, 1, remaining)
      if ready > 0 { return descriptor.revents & Int16(POLLIN | POLLERR) != 0 }
      if ready == 0 || (ready < 0 && errno != EINTR) { return false }
    }
  }

  /// What a ``staleEventSend(_:beforeRealSend:)`` seam observed.
  final class StaleEventStaging: @unchecked Sendable {
    private let lock = NSLock()
    private var state = (attempts: 0, staged: false, deferrals: 0, consumed: false, sent: false)
    /// Retries held back while the staged event is still unread; past this, the seam stops
    /// waiting and the test fails on `consumedBeforeRealSend`.
    static let maxDeferrals = 3000

    var staged: Bool { read { $0.staged } }
    var consumedBeforeRealSend: Bool { read { $0.consumed } }
    var realSendSucceeded: Bool { read { $0.sent } }
    var deferrals: Int { read { $0.deferrals } }

    func update<T>(
      _ change: (inout (attempts: Int, staged: Bool, deferrals: Int, consumed: Bool, sent: Bool)) ->
        T
    ) -> T {
      lock.lock()
      defer { lock.unlock() }
      return change(&state)
    }

    private func read<T>(
      _ get: ((attempts: Int, staged: Bool, deferrals: Int, consumed: Bool, sent: Bool)) -> T
    ) -> T {
      lock.lock()
      defer { lock.unlock() }
      return get(state)
    }
  }

  /// A send seam that makes something readable before the exchange has sent, as a late reply to
  /// an earlier socket on the same port would be. Its first call puts the datagram on the wire,
  /// waits until what that provokes is waiting on the socket, and reports `ENOBUFS`. Retries
  /// keep reporting `ENOBUFS` while that event is still unread; once the read handler has
  /// consumed it, `beforeRealSend` runs and the request really leaves.
  static func staleEventSend(
    _ staging: StaleEventStaging, beforeRealSend: @escaping @Sendable () -> Void = {}
  ) -> TestSeams.SendDatagram {
    { fd, bytes in
      let attempt = staging.update { state -> Int in
        state.attempts += 1
        return state.attempts
      }
      if attempt == 1 {
        _ = Darwin.send(fd, bytes.baseAddress, bytes.count, 0)
        let staged = Self.waitUntilReadable(fd, limit: 5)
        staging.update { $0.staged = staged }
        Darwin.errno = ENOBUFS
        return -1
      }
      let pending = Self.waitUntilReadable(fd, limit: 0)
      let deferred = staging.update { state -> Bool in
        guard pending, !state.sent, state.deferrals < StaleEventStaging.maxDeferrals else {
          return false
        }
        state.deferrals += 1
        return true
      }
      if deferred {
        Darwin.errno = ENOBUFS
        return -1
      }
      beforeRealSend()
      let sent = Darwin.send(fd, bytes.baseAddress, bytes.count, 0)
      let code = Darwin.errno
      staging.update {
        $0.consumed = !pending
        $0.sent = sent == bytes.count
      }
      Darwin.errno = code
      return sent
    }
  }

  @Test("A datagram that arrives before the request has left does not complete the exchange")
  func datagramBeforeTheSendIsIgnored() async throws {
    let replies = FaultCounter()
    let server = try LoopbackUDPResponder { query in
      replies.increment()
      // The stale reply carries 192.0.2.1, the one to the request that left carries 192.0.2.2.
      let last: UInt8 = replies.value == 1 ? 1 : 2
      let record: [UInt8] = [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, last]
      return (FaultInjectionWireTests.dnsResponse(to: query, answers: record), 0)
    }
    defer { server.stop() }
    let staging = StaleEventStaging()

    let (answers, _) = try await measure(within: Self.watchdog) {
      try await TestSeams.$sendDatagram.withValue(Self.staleEventSend(staging)) {
        try await __dnsQuery(
          server: "127.0.0.1", port: server.port, name: "stale.example", type: 1, timeout: 5)
      }
    }
    try #require(staging.staged, "the first reply never arrived before the retry")
    // The stale reply was read and dropped before the request really left, and the answer is the
    // one to that request.
    #expect(staging.consumedBeforeRealSend, "still unread after \(staging.deferrals) retries")
    #expect(staging.realSendSucceeded)
    #expect(answers.first?.rdata == Data([192, 0, 2, 2]))
    #expect(server.requests.value == 2)
  }

  @Test("A refusal that arrives before the request has left does not end the exchange")
  func refusalBeforeTheSendIsIgnored() async throws {
    // Refuses the first datagram, then answers: the real send goes to a server that replies, so
    // its outcome does not depend on Darwin suppressing a second port-unreachable to one peer.
    let port = try RefusingThenAnsweringUDPPort { query in
      FaultInjectionWireTests.dnsResponse(to: query, answers: FaultInjectionWireTests.aRecord)
    }
    defer { port.stop() }
    let staging = StaleEventStaging()
    let send = Self.staleEventSend(staging) { port.startAnswering() }

    let (answers, _) = try await measure(within: Self.watchdog) {
      try await TestSeams.$sendDatagram.withValue(send) {
        try await __dnsQuery(
          server: "127.0.0.1", port: port.port, name: "stale.example", type: 1, timeout: 5)
      }
    }
    try #require(staging.staged, "the first refusal never arrived before the retry")
    // The pending refusal was read and dropped before the request really left, and the outcome is
    // the real send's: an answer, not the refusal.
    #expect(staging.consumedBeforeRealSend, "still pending after \(staging.deferrals) retries")
    #expect(staging.realSendSucceeded)
    #expect(answers.first?.rdata == Data([192, 0, 2, 9]))
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
    /// Every send fails with this errno, so the exchange is waiting to write or backing off.
    case cancelledWhileWaitingToWrite, cancelledWhileBackingOff
    case deadlineWhileWaitingToWrite, deadlineWhileBackingOff

    var sendErrno: Int32? {
      switch self {
      case .cancelledWhileWaitingToWrite, .deadlineWhileWaitingToWrite: EAGAIN
      case .cancelledWhileBackingOff, .deadlineWhileBackingOff: ENOBUFS
      default: nil
      }
    }
    var cancels: Bool {
      [.cancelled, .cancelledWhileWaitingToWrite, .cancelledWhileBackingOff].contains(self)
    }
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
      case .malformed: return (Array(query.prefix(2)) + [0xDE, 0xAD], 0)
      default: return nil
      }
    }
    defer { server.stop() }
    let refusing = exit == .refused ? try RefusingUDPPort() : nil
    defer { withExtendedLifetime(refusing) {} }
    let port = refusing?.port ?? server.port
    let ledger = DescriptorLedger(failSetup: exit == .setupFailed, sendErrno: exit.sendErrno)
    let timeout: TimeInterval =
      [.timedOut, .deadlineWhileWaitingToWrite, .deadlineWhileBackingOff].contains(exit) ? 0.2 : 30

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
    }
    if exit.sendErrno != nil, exit.cancels {
      #expect(await eventually(within: Self.watchdog) { ledger.snapshot.sendAttempts > 1 })
    }
    if exit.cancels { query.cancel() }
    let (thrown, _) = try await measure(within: Self.watchdog) { await query.value }

    switch exit {
    case .answered: #expect(thrown == nil, "\(String(describing: thrown))")
    case .timedOut: #expect(Self.isTimeout(thrown), "\(String(describing: thrown))")
    case .refused: #expect(Self.isSendFailed(thrown), "\(String(describing: thrown))")
    case .malformed: #expect(Self.isMalformed(thrown), "\(String(describing: thrown))")
    case .cancelled, .cancelledWhileWaitingToWrite, .cancelledWhileBackingOff:
      #expect(thrown is CancellationError, "\(String(describing: thrown))")
    case .setupFailed: #expect(thrown != nil)
    case .deadlineWhileWaitingToWrite, .deadlineWhileBackingOff:
      #expect(Self.isSendFailed(thrown), "\(String(describing: thrown))")
    }

    // Read as soon as the query returned: the close happens before the caller is resumed.
    let record = ledger.snapshot
    #expect(record.closedDescriptors.count == 1, "closes: \(record.closedDescriptors)")
    if exit == .setupFailed || exit.sendErrno != nil {
      // The socket that was configured, and nothing else; with every send failing, it was closed
      // once although write sources or backoff timers were created and cancelled along the way.
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
    var sendAttempts = 0
  }

  private let lock = NSLock()
  private var record = Record()
  private let failSetup: Bool
  private let sendErrno: Int32?

  init(failSetup: Bool = false, sendErrno: Int32? = nil) {
    self.failSetup = failSetup
    self.sendErrno = sendErrno
  }

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
      update { $0.sendAttempts += 1 }
      if let sendErrno {
        Darwin.errno = sendErrno
        return -1
      }
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

/// A loopback UDP port that refuses datagrams until ``startAnswering()``, then answers one.
///
/// Until then its socket is connected to another loopback port, so the kernel answers anyone else
/// with ICMP port-unreachable. `startAnswering()` dissolves that association, so the next
/// datagram reaches the socket and is answered with `reply`.
final class RefusingThenAnsweringUDPPort: @unchecked Sendable {
  let port: UInt16
  /// Owned by ``stop()`` until ``startAnswering()``, and by the answering thread after it, which
  /// closes it as it exits.
  private let fd: Int32
  private let reply: @Sendable ([UInt8]) -> [UInt8]
  private let lock = NSLock()
  private var answering = false
  private var stopped = false
  /// How long the answering thread waits for its datagram.
  private let answerWindow: TimeInterval = 5

  init(reply: @escaping @Sendable ([UInt8]) -> [UInt8]) throws {
    let (bound, boundPort) = try bindLoopback(family: AF_INET, type: SOCK_DGRAM)
    var (peer, length) = loopbackAddress(family: AF_INET, port: 9)
    let connected = withUnsafePointer(to: &peer) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(bound, $0, length) }
    }
    guard connected == 0 else {
      let code = errno
      close(bound)
      throw FixtureError.socket("connect", code)
    }
    // Short, so the answering thread sees `stop()` promptly between receives.
    setReceiveTimeout(bound, seconds: 0.02)
    fd = bound
    port = boundPort
    self.reply = reply
  }

  private var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }

  /// Disconnects the socket and answers the next datagram on a thread of its own.
  func startAnswering() {
    lock.lock()
    guard !answering, !stopped else {
      lock.unlock()
      return
    }
    answering = true
    lock.unlock()
    var unspecified = sockaddr()
    unspecified.sa_len = UInt8(MemoryLayout<sockaddr>.size)
    unspecified.sa_family = sa_family_t(AF_UNSPEC)
    _ = connect(fd, &unspecified, socklen_t(MemoryLayout<sockaddr>.size))
    Thread.detachNewThread { [self] in
      defer { close(fd) }
      var buffer = [UInt8](repeating: 0, count: 2048)
      var source = sockaddr_storage()
      var sourceLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
      let giveUp = monotonicNow() + answerWindow
      var received = -1
      while received < 0, !isStopped, monotonicNow() < giveUp {
        sourceLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        received = buffer.withUnsafeMutableBytes { raw in
          withUnsafeMutablePointer(to: &source) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
              recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &sourceLength)
            }
          }
        }
      }
      guard received > 0, !isStopped else { return }
      let answer = reply(Array(buffer.prefix(received)))
      _ = answer.withUnsafeBytes { raw in
        withUnsafePointer(to: &source) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            sendto(fd, raw.baseAddress, raw.count, 0, $0, sourceLength)
          }
        }
      }
    }
  }

  /// Stops without waiting. Before ``startAnswering()`` it closes the socket; after it, the
  /// answering thread closes it as it exits, within its 20 ms receive timeout. Safe to call from
  /// `defer` in an async test, since it parks no thread.
  func stop() {
    lock.lock()
    let wasStopped = stopped
    stopped = true
    let threadOwnsSocket = answering
    lock.unlock()
    if !wasStopped && !threadOwnsSocket { close(fd) }
  }
}
