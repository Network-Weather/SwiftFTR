import Foundation
@_spi(Test) import SwiftFTR
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// `DNSProbeResult.outcome` and `elapsed` for every way `dnsProbe` ends, against loopback
/// fixtures, and their derivation from the fields that predate them.
@Suite("DNS probe outcome")
struct DNSProbeOutcomeTests {
  /// Long enough that only an operation that is not going to return reaches it.
  static let watchdog: TimeInterval = 20

  /// Every probe below either answers, is refused, or is failed by a seam at once, so it never
  /// waits out this timeout; a probe that did would trip the watchdog.
  static let longTimeout: TimeInterval = 30

  static func probe(
    port: UInt16, server: String = "127.0.0.1", timeout: TimeInterval = longTimeout
  ) async throws -> DNSProbeResult {
    try await measure(within: watchdog) {
      try await TestSeams.$dnsServerPort.withValue(port) {
        try await dnsProbe(server: server, query: "outcome.example", timeout: timeout)
      }
    }.0
  }

  static func answering(rcode: UInt8 = 0, family: Int32 = AF_INET) throws -> LoopbackUDPResponder {
    try LoopbackUDPResponder(family: family) { query in
      (
        FaultInjectionWireTests.dnsResponse(
          to: query, rcode: rcode, answerCount: rcode == 0 ? 1 : 0,
          answers: rcode == 0 ? FaultInjectionWireTests.aRecord : []),
        0
      )
    }
  }

  // MARK: One test per outcome

  @Test("A DNS answer is answered, with rtt and elapsed equal", arguments: [UInt8(0), 3])
  func answered(rcode: UInt8) async throws {
    let server = try Self.answering(rcode: rcode)
    defer { server.stop() }

    let result = try await Self.probe(port: server.port)
    #expect(result.outcome == .answered)
    #expect(result.isReachable)
    #expect(result.responseCode == Int(rcode))
    #expect(result.error == nil)
    let rtt = try #require(result.rtt)
    #expect(result.elapsed == rtt)
  }

  @Test("A refused port is refused, with elapsed and no rtt", arguments: [AF_INET, AF_INET6])
  func refused(family: Int32) async throws {
    let refusing = try RefusingUDPPort(family: family)
    let result = try await Self.probe(
      port: refusing.port, server: family == AF_INET6 ? "::1" : "127.0.0.1")
    withExtendedLifetime(refusing) {}

    #expect(result.outcome == .refused)
    #expect(!result.isReachable)
    #expect(result.rtt == nil)
    #expect(result.elapsed != nil)
    #expect(result.responseCode == nil)
    #expect(
      result.error
        == "Connection refused - the host is up but no DNS server is listening on this port")
  }

  @Test("Silence until the timeout is timedOut, with no timing")
  func timedOut() async throws {
    let server = try LoopbackUDPResponder { _ in nil }
    defer { server.stop() }

    let result = try await Self.probe(port: server.port, timeout: 0.3)
    #expect(result.outcome == .timedOut)
    #expect(!result.isReachable)
    #expect(result.rtt == nil)
    #expect(result.elapsed == nil)
    #expect(result.responseCode == nil)
    #expect(result.error == "Timeout - no response")
  }

  @Test("An empty datagram is malformedReply, reachable, with rtt and elapsed equal")
  func malformedReply() async throws {
    let server = try LoopbackUDPResponder { _ in ([], 0) }
    defer { server.stop() }

    let result = try await Self.probe(port: server.port)
    #expect(result.outcome == .malformedReply)
    #expect(result.isReachable)
    #expect(result.responseCode == nil)
    #expect(result.error == "Malformed response")
    let rtt = try #require(result.rtt)
    #expect(result.elapsed == rtt)
  }

  /// A `recv` that drains the real reply and then reports `code`, as the kernel does when an ICMP
  /// error has arrived for the connected socket. Loopback cannot produce these errors itself.
  static func receiveFails(with code: Int32) -> TestSeams.ReceiveDatagram {
    { fd, buffer in
      _ = Darwin.recv(fd, buffer.baseAddress, buffer.count, 0)
      Darwin.errno = code
      return -1
    }
  }

  @Test(
    "Host or network unreachable is unreachable, with elapsed and a message naming it",
    arguments: [EHOSTUNREACH, ENETUNREACH])
  func unreachable(code: Int32) async throws {
    let server = try Self.answering()
    defer { server.stop() }

    let result = try await TestSeams.$receiveDatagram.withValue(Self.receiveFails(with: code)) {
      try await Self.probe(port: server.port)
    }
    #expect(result.outcome == .unreachable)
    #expect(!result.isReachable)
    #expect(result.rtt == nil)
    #expect(result.elapsed != nil)
    #expect(result.responseCode == nil)
    let error = try #require(result.error)
    #expect(error.hasPrefix(code == ENETUNREACH ? "Network unreachable" : "Host unreachable"))
    #expect(error.contains(String(cString: strerror(code))), "\(error)")
    #expect(!error.contains("Timeout"))
  }

  enum Failure: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case send, connect, unclassifiedReceive, invalidServer
    var testDescription: String { rawValue }
  }

  @Test(
    "A probe that cannot run to an answer is failed, with no timing", arguments: Failure.allCases)
  func failed(failure: Failure) async throws {
    let server = try Self.answering()
    defer { server.stop() }
    let send: TestSeams.SendDatagram = { _, _ in
      Darwin.errno = EPERM
      return -1
    }

    let result: DNSProbeResult
    switch failure {
    case .send:
      result = try await TestSeams.$sendDatagram.withValue(send) {
        try await Self.probe(port: server.port)
      }
    case .connect:
      result = try await TestSeams.$connectSocket.withValue(Self.connectFails(with: EADDRNOTAVAIL))
      {
        try await Self.probe(port: server.port)
      }
    case .unclassifiedReceive:
      result = try await TestSeams.$receiveDatagram.withValue(Self.receiveFails(with: ECONNRESET)) {
        try await Self.probe(port: server.port)
      }
    case .invalidServer:
      result = try await Self.probe(port: server.port, server: "not-an-address")
    }
    #expect(result.outcome == .failed)
    #expect(!result.isReachable)
    #expect(result.rtt == nil)
    #expect(result.elapsed == nil)
    #expect(result.responseCode == nil)
    let expected =
      switch failure {
      case .send: "Failed to send query - send failed (errno=1: Operation not permitted)"
      case .connect:
        "Failed to send query - connect failed (errno=49: Can't assign requested address)"
      case .unclassifiedReceive:
        "Receive failed - the socket reported an error while waiting for the reply"
          + " (errno=54: Connection reset by peer)"
      case .invalidServer: "Invalid server IP: not-an-address"
      }
    #expect(result.error == expected)
  }

  @Test("Cancelling dnsProbe mid-probe throws CancellationError instead of returning a result")
  func cancellation() async throws {
    let server = try LoopbackUDPResponder { _ in nil }
    defer { server.stop() }
    let task = Task {
      try await TestSeams.$dnsServerPort.withValue(server.port) {
        try await dnsProbe(server: "127.0.0.1", query: "cancel.example", timeout: Self.longTimeout)
      }
    }
    #expect(await eventually(within: Self.watchdog) { server.requests.value > 0 })
    task.cancel()

    let (result, _) = try await measure(within: Self.watchdog) {
      await Result.capture { try await task.value }
    }
    switch result {
    case .success(let probe): Issue.record("returned a result: \(probe.error ?? "nil")")
    case .failure(let error): #expect(error is CancellationError, "\(error)")
    }
  }

  /// A `connect` that fails with `code`, as the kernel does when it has no route to the server.
  static func connectFails(with code: Int32) -> TestSeams.ConnectSocket {
    { _, _, _ in
      Darwin.errno = code
      return -1
    }
  }

  enum Stage: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case connect, send
    var testDescription: String { rawValue }
  }

  @Test(
    "No route at connect or send is unreachable, with no timing, and the query methods still throw sendFailed",
    arguments: Stage.allCases, [EHOSTUNREACH, EHOSTDOWN, ENETUNREACH, ENETDOWN])
  func locallyUnreachable(stage: Stage, code: Int32) async throws {
    let server = try Self.answering()
    defer { server.stop() }
    let send: TestSeams.SendDatagram = { _, _ in
      Darwin.errno = code
      return -1
    }

    let (result, thrown) = try await TestSeams.$connectSocket.withValue(
      stage == .connect ? Self.connectFails(with: code) : nil
    ) {
      try await TestSeams.$sendDatagram.withValue(stage == .send ? send : nil) {
        let result = try await Self.probe(port: server.port)
        let thrown = await EventBasedDNSTests.error {
          try await __dnsQuery(
            server: "127.0.0.1", port: server.port, name: "route.example", type: 1, timeout: 5)
        }
        return (result, thrown)
      }
    }
    #expect(result.outcome == .unreachable)
    #expect(!result.isReachable)
    #expect(result.rtt == nil)
    // Nothing came back from the network.
    #expect(result.elapsed == nil)
    #expect(result.responseCode == nil)
    let error = try #require(result.error)
    let network = code == ENETUNREACH || code == ENETDOWN
    #expect(error.hasPrefix(network ? "Network unreachable" : "Host unreachable"), "\(error)")
    #expect(error.contains("(errno=\(code): \(String(cString: strerror(code))))"), "\(error)")
    #expect(EventBasedDNSTests.isSendFailed(thrown), "\(String(describing: thrown))")
    #expect(server.requests.value == 0)
  }

  @Test("The reported round trip excludes time spent inside the read call")
  func receiveStampPrecedesRead() async throws {
    let server = try Self.answering()
    defer { server.stop() }
    // The reply is already queued when the read event runs; a stall inside the read must not
    // count. Large enough that no real loopback round trip on a loaded machine reaches it.
    let stall: TimeInterval = 2
    let receive: TestSeams.ReceiveDatagram = { fd, buffer in
      usleep(UInt32(stall * 1_000_000))
      return Darwin.recv(fd, buffer.baseAddress, buffer.count, 0)
    }

    let (result, duration) = try await measure(within: Self.watchdog) {
      try await TestSeams.$receiveDatagram.withValue(receive) {
        try await TestSeams.$dnsServerPort.withValue(server.port) {
          try await dnsProbe(server: "127.0.0.1", query: "stamp.example", timeout: Self.longTimeout)
        }
      }
    }
    #expect(duration >= stall, "the stall did not run")
    #expect(result.outcome == .answered)
    let rtt = try #require(result.rtt)
    #expect(rtt < stall, "rtt \(rtt) s includes the \(stall) s stall inside the read")
    #expect(result.elapsed == rtt)
  }

  // MARK: Transport reads

  @Test("An unreachable error read before the request has left is ignored, through the seam")
  func unreachableBeforeTheSendIsIgnored() async throws {
    let server = try Self.answering()
    defer { server.stop() }
    let attempts = FaultCounter()
    let staged = FaultCounter()
    let reads = FaultCounter()
    let preSendReads = FaultCounter()
    // The first send puts a request on the wire, waits for its reply, then reports ENOBUFS, so the
    // reply is readable before the exchange has sent anything.
    let send = EventBasedDNSTests.sendThatLiesFirst(attempts: attempts, staged: staged)
    // The first read consumes that reply and reports EHOSTUNREACH instead.
    let receive: TestSeams.ReceiveDatagram = { fd, buffer in
      reads.increment()
      let received = Darwin.recv(fd, buffer.baseAddress, buffer.count, 0)
      guard reads.value == 1 else { return received }
      if attempts.value == 1 { preSendReads.increment() }
      Darwin.errno = EHOSTUNREACH
      return -1
    }

    let result = try await TestSeams.$sendDatagram.withValue(send) {
      try await TestSeams.$receiveDatagram.withValue(receive) {
        try await Self.probe(port: server.port)
      }
    }
    try #require(staged.value == 1, "the first reply never arrived before the retry")
    try #require(preSendReads.value == 1, "the seam did not see the read before the send")
    #expect(result.outcome == .answered, "\(result.error ?? "nil")")
    #expect(attempts.value == 2)
    #expect(reads.value >= 2)
  }

  /// Datagrams waiting on `fd`, from `SO_NUMRCVPKT`.
  static func queuedDatagrams(_ fd: Int32) -> Int32 {
    var count: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(fd, SOL_SOCKET, SO_NUMRCVPKT, &count, &length) == 0 else { return -1 }
    return count
  }

  static func waitForQueued(_ fd: Int32, _ count: Int32, limit: TimeInterval = 5) -> Bool {
    let giveUp = monotonicNow() + limit
    while monotonicNow() < giveUp {
      if queuedDatagrams(fd) >= count { return true }
      _ = EventBasedDNSTests.waitUntilReadable(fd, limit: 0.01)
    }
    return queuedDatagrams(fd) >= count
  }

  enum Exit: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case answered, timedOut, cancelled
    var testDescription: String { rawValue }
  }

  final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Error?, Never>?
    func set(_ task: Task<Error?, Never>) {
      lock.lock()
      self.task = task
      lock.unlock()
    }
    /// Cancels the task, waiting for it to be set if the seam runs before `set`.
    func cancel(limit: TimeInterval = 5) {
      let giveUp = monotonicNow() + limit
      while monotonicNow() < giveUp {
        lock.lock()
        let task = self.task
        lock.unlock()
        if let task { return task.cancel() }
        usleep(1000)
      }
    }
  }

  @Test(
    "Once the exchange has finished and closed its socket, nothing reads it again",
    arguments: Exit.allCases)
  func noReadAfterFinish(exit: Exit) async throws {
    let server = try Self.answering()
    defer { server.stop() }
    let reads = FaultCounter()
    let queuedAtSend = FaultCounter()
    let closes = FaultCounter()
    let readsAtClose = FaultCounter()
    let box = TaskBox()
    let timeout: TimeInterval = exit == .timedOut ? 0.3 : Self.longTimeout

    // Sends the request twice, so two replies are queued, and waits until both are.
    let send: TestSeams.SendDatagram = { fd, bytes in
      let first = Darwin.send(fd, bytes.baseAddress, bytes.count, 0)
      _ = Darwin.send(fd, bytes.baseAddress, bytes.count, 0)
      if Self.waitForQueued(fd, 2) { queuedAtSend.increment() }
      switch exit {
      case .answered:
        return first
      case .timedOut:
        // Both replies stay queued past the deadline: whichever of the read event and the
        // deadline timer runs first, the exchange times out with them unread.
        usleep(UInt32((timeout + 0.2) * 1_000_000))
        return first
      case .cancelled:
        box.cancel()
        Darwin.errno = ENOBUFS
        return -1
      }
    }
    let receive: TestSeams.ReceiveDatagram = { fd, buffer in
      reads.increment()
      return Darwin.recv(fd, buffer.baseAddress, buffer.count, 0)
    }
    let close: TestSeams.CloseDescriptor = { fd in
      // Taken while the descriptor is still open: every read the exchange made happened by now.
      for _ in 0..<reads.value { readsAtClose.increment() }
      closes.increment()
      return Darwin.close(fd)
    }

    let task = Task {
      await TestSeams.$sendDatagram.withValue(send) {
        await TestSeams.$receiveDatagram.withValue(receive) {
          await TestSeams.$closeDescriptor.withValue(close) {
            await EventBasedDNSTests.error {
              try await __dnsQuery(
                server: "127.0.0.1", port: server.port, name: "finish.example", type: 1,
                timeout: timeout)
            }
          }
        }
      }
    }
    box.set(task)
    let (thrown, _) = try await measure(within: Self.watchdog) { await task.value }

    try #require(queuedAtSend.value == 1, "two replies were never queued at once")
    switch exit {
    case .answered: #expect(thrown == nil, "\(String(describing: thrown))")
    case .timedOut: #expect(EventBasedDNSTests.isTimeout(thrown), "\(String(describing: thrown))")
    case .cancelled: #expect(thrown is CancellationError, "\(String(describing: thrown))")
    }
    #expect(closes.value == 1)
    // The answered exit read the first reply and stopped, leaving the second queued.
    if exit == .answered { #expect(readsAtClose.value == 1) }

    // Absence over a window: any read source event or handler left over would run by now.
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(reads.value == readsAtClose.value, "read \(reads.value - readsAtClose.value) more")
  }

  // MARK: Consumer use

  @Test("A switch over the outcome with a default arm matches the static members")
  func switchWithDefault() {
    func label(_ outcome: DNSProbeOutcome) -> String {
      switch outcome {
      case .answered: "answered"
      case .refused: "refused"
      case .timedOut: "timedOut"
      default: "other"
      }
    }
    #expect(label(.refused) == "refused")
    #expect(label(.unreachable) == "other")
    #expect(label(DNSProbeOutcome(rawValue: "fromALaterRelease")) == "other")
  }

  // MARK: Legacy fields

  struct Legacy: CustomTestStringConvertible, Sendable {
    let isReachable: Bool
    let rtt: TimeInterval?
    let responseCode: Int?
    let error: String?
    let outcome: DNSProbeOutcome
    let elapsed: TimeInterval?
    var testDescription: String { "\(error ?? "no error") -> \(outcome)" }
  }

  static let legacyTable: [Legacy] = [
    Legacy(
      isReachable: true, rtt: 0.01, responseCode: 0, error: nil, outcome: .answered, elapsed: 0.01),
    Legacy(
      isReachable: true, rtt: 0.01, responseCode: 3, error: nil, outcome: .answered, elapsed: 0.01),
    Legacy(
      isReachable: true, rtt: 0.01, responseCode: nil, error: nil, outcome: .answered, elapsed: 0.01
    ),
    Legacy(
      isReachable: true, rtt: 0.01, responseCode: nil, error: "Malformed response",
      outcome: .malformedReply, elapsed: 0.01),
    Legacy(
      isReachable: false, rtt: nil, responseCode: nil,
      error: "Connection refused - the host is up but no DNS server is listening on this port",
      outcome: .refused, elapsed: nil),
    Legacy(
      isReachable: false, rtt: nil, responseCode: nil,
      error: "Host unreachable - the network reported the server's host unreachable (errno=65)",
      outcome: .unreachable, elapsed: nil),
    Legacy(
      isReachable: false, rtt: nil, responseCode: nil,
      error: "Network unreachable - the network reported no route to the server (errno=51)",
      outcome: .unreachable, elapsed: nil),
    Legacy(
      isReachable: false, rtt: nil, responseCode: nil, error: "Timeout - no response",
      outcome: .timedOut, elapsed: nil),
    Legacy(
      isReachable: false, rtt: nil, responseCode: nil, error: nil, outcome: .timedOut, elapsed: nil),
    Legacy(
      isReachable: false, rtt: nil, responseCode: nil, error: "Failed to send query",
      outcome: .failed, elapsed: nil),
    Legacy(
      isReachable: false, rtt: nil, responseCode: nil,
      error: "Unexpected error: CancellationError()",
      outcome: .failed, elapsed: nil),
  ]

  @Test(
    "The initializer without an outcome derives it from the legacy fields", arguments: legacyTable)
  func legacyInitializer(row: Legacy) {
    let result = DNSProbeResult(
      server: "192.0.2.53", query: "legacy.example", isReachable: row.isReachable, rtt: row.rtt,
      responseCode: row.responseCode, error: row.error)
    #expect(result.outcome == row.outcome)
    #expect(result.elapsed == row.elapsed)
    #expect(result.isReachable == row.isReachable)
    #expect(result.rtt == row.rtt)
    #expect(result.responseCode == row.responseCode)
    #expect(result.error == row.error)
  }

  @Test(
    "JSON without an outcome key, as 0.17 wrote it, decodes and derives the outcome",
    arguments: legacyTable)
  func legacyJSON(row: Legacy) throws {
    // The keys and encodings 0.17's synthesized `Codable` wrote; nil fields are omitted.
    var object: [String: Any] = [
      "server": "192.0.2.53", "query": "legacy.example", "isReachable": row.isReachable,
      "timestamp": 785_000_000.0,
    ]
    if let rtt = row.rtt { object["rtt"] = rtt }
    if let responseCode = row.responseCode { object["responseCode"] = responseCode }
    if let error = row.error { object["error"] = error }
    let data = try JSONSerialization.data(withJSONObject: object)

    let result = try JSONDecoder().decode(DNSProbeResult.self, from: data)
    #expect(result.outcome == row.outcome)
    #expect(result.elapsed == row.elapsed)
    #expect(result.isReachable == row.isReachable)
    #expect(result.rtt == row.rtt)
    #expect(result.responseCode == row.responseCode)
    #expect(result.error == row.error)
    #expect(result.timestamp == Date(timeIntervalSinceReferenceDate: 785_000_000))
  }

  @Test("Encoding writes outcome and elapsed, and a round trip keeps every field")
  func roundTrip() throws {
    let outcomes: [DNSProbeOutcome] = [
      .answered, .refused, .timedOut, .malformedReply, .unreachable, .failed,
      DNSProbeOutcome(rawValue: "fromALaterRelease"),
    ]
    for outcome in outcomes {
      // Deliberately inconsistent with the legacy fields, so a decoder that derived the outcome
      // instead of reading it would be caught.
      let original = DNSProbeResult(
        server: "::1", query: "round.example", outcome: outcome, isReachable: false, rtt: nil,
        elapsed: 0.25, responseCode: nil, error: "Timeout - no response",
        timestamp: Date(timeIntervalSinceReferenceDate: 785_000_000))
      let data = try JSONEncoder().encode(original)
      let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(object["outcome"] as? String == outcome.rawValue)
      #expect(object["elapsed"] as? Double == 0.25)

      let decoded = try JSONDecoder().decode(DNSProbeResult.self, from: data)
      #expect(decoded.outcome == outcome)
      #expect(decoded.elapsed == 0.25)
      #expect(decoded.server == original.server)
      #expect(decoded.query == original.query)
      #expect(decoded.isReachable == original.isReachable)
      #expect(decoded.rtt == original.rtt)
      #expect(decoded.responseCode == original.responseCode)
      #expect(decoded.error == original.error)
      #expect(decoded.timestamp == original.timestamp)
    }
  }
}
