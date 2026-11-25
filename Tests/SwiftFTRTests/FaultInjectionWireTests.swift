import Foundation
@_spi(Test) import SwiftFTR
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// STUN, DNS, TCP, UDP and HTTP against loopback servers that misbehave on purpose.
///
/// Each group starts with a positive control showing the client accepts a well-formed answer from
/// the fixture, so the failure cases test the client rather than a fixture nobody can reach.
///
/// No test bounds how long a call took from above. Every call runs under ``watchdog``, far past
/// the client's timeout, and a slow fixture answers only after the watchdog, so a client that
/// waited for the answer, or for nothing, trips it.
@Suite("FaultInjection: wire protocols")
struct FaultInjectionWireTests {
  /// How long a call may run before it is reported as waiting for an answer it should have given
  /// up on: 50 of the 0.3 s timeouts the fault tests use, so a timeout that never fires, or fires
  /// two orders of magnitude late, trips it, while no correct call comes near it.
  static let watchdog: TimeInterval = 15

  /// When a slow fixture answers: after the watchdog, so a client that waited for the answer
  /// trips the watchdog rather than racing it.
  static let lateAnswer: TimeInterval = 2 * watchdog

  /// The timeout of a call the fixture must answer: generous, since the answer ends it, so a slow
  /// loopback on a loaded host cannot turn an answer into a timeout. Inside ``watchdog``.
  static let answeredTimeout: TimeInterval = 10

  // MARK: STUN

  /// A binding success response echoing the request's transaction ID and mapping `ip`.
  static func stunSuccess(for request: [UInt8], ip: [UInt8]) -> [UInt8]? {
    guard request.count >= 20 else { return nil }
    let cookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]
    let xored = (0..<4).map { ip[$0] ^ cookie[$0] }
    let attribute: [UInt8] = [0x00, 0x20, 0x00, 0x08, 0x00, 0x01, 0x00, 0x00] + xored
    return [0x01, 0x01, 0x00, UInt8(attribute.count)] + cookie + Array(request[8..<20]) + attribute
  }

  enum STUNFault: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case silent, empty, garbage, wrongCookie, wrongTransaction, slow
    /// Carries the request's transaction ID, so it fails the exchange rather than being ignored.
    case wrongMessageType
    var testDescription: String { rawValue }
  }

  /// The outcome of a STUN exchange with `server`, or `nil` if it was still running after
  /// ``watchdog``.
  static func runSTUN(server: LoopbackUDPResponder, timeout: TimeInterval) async
    -> Result<STUNPublicIP, Error>?
  {
    let (address, length) = server.address
    do {
      return try await measure(within: watchdog) {
        do {
          return Result<STUNPublicIP, Error>.success(
            try await stunGetPublicIP(
              family: AF_INET, server: address, serverLen: length, serverLabel: "fixture",
              timeout: timeout))
        } catch {
          return .failure(error)
        }
      }.0
    } catch {
      return nil
    }
  }

  @Test("STUN accepts a well-formed binding response from the fixture")
  func stunPositiveControl() async throws {
    let server = try LoopbackUDPResponder(accepts: .stunBindingRequest) { request in
      Self.stunSuccess(for: request, ip: [198, 51, 100, 7]).map { ($0, 0) }
    }
    defer { server.stop() }
    let result = await Self.runSTUN(server: server, timeout: Self.answeredTimeout)
    #expect(try result?.get().ip == "198.51.100.7")
  }

  @Test("STUN gives up within its timeout on a faulty server", arguments: STUNFault.allCases)
  func stunFaults(fault: STUNFault) async throws {
    let server = try LoopbackUDPResponder(accepts: .stunBindingRequest) { request in
      var reply = Self.stunSuccess(for: request, ip: [198, 51, 100, 7])!
      switch fault {
      case .silent: return nil
      case .empty: return ([], 0)
      case .garbage: return ([0xDE, 0xAD, 0xBE, 0xEF], 0)
      case .wrongCookie: reply[4] ^= 0xFF
      case .wrongTransaction: reply[8] ^= 0xFF
      case .slow: return (reply, Self.lateAnswer)
      case .wrongMessageType: reply[1] = 0x11
      }
      return (reply, 0)
    }
    defer { server.stop() }
    let timeout: TimeInterval = 0.3
    let result = await Self.runSTUN(server: server, timeout: timeout)

    let unwrapped = try #require(result, "STUN never returned from a \(fault) server")
    #expect(throws: STUNError.self) { try unwrapped.get() }
    // Bounded completion only: a 0.3 s exchange may end before its queue first runs and sends.
    // With long timeouts, `EventBasedSTUNTests.foreignReplyIgnored` and
    // `invalidReplyFailsItsServerOnly` show each malformed kind of reply read and handled. An
    // exchange never sends more than one request.
    #expect(server.requests.value <= 1, "requests: \(server.requests.value)")
  }

  @Test("A sub-microsecond STUN timeout is still a timeout, not an unbounded wait")
  func stunTinyTimeout() async throws {
    let server = try LoopbackUDPResponder(accepts: .stunBindingRequest) { _ in nil }
    defer { server.stop() }
    // The failure is a wait with no end, so any finite watchdog tells them apart.
    let (address, length) = server.address
    let outcome = try await measure(within: 5) {
      try? await stunGetPublicIP(
        family: AF_INET, server: address, serverLen: length, serverLabel: "fixture",
        timeout: 0.000_000_5)
    }.0
    #expect(outcome == nil)
  }

  // MARK: DNS

  enum DNSFault: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case silent, nxdomain, servfail, garbage, oversized, compressionLoop, overstatedAnswerCount
    case slow
    var testDescription: String { rawValue }
  }

  /// A response to `query` with `rcode`, carrying `answers` raw answer records and claiming
  /// `answerCount` of them.
  static func dnsResponse(
    to query: [UInt8], rcode: UInt8 = 0, answerCount: UInt16 = 1, answers: [UInt8]
  ) -> [UInt8] {
    // A fixture's filter hands its script only well-formed queries; anything shorter than a
    // header gets an empty reply rather than an index out of range.
    guard query.count >= 12 else { return [] }
    var header = Array(query.prefix(12))
    header[2] = 0x81
    header[3] = 0x80 | rcode
    header[6] = UInt8(answerCount >> 8)
    header[7] = UInt8(answerCount & 0xFF)
    return header + Array(query.dropFirst(12)) + answers
  }

  /// The name every DNS test here asks for, and the only one its fixture answers.
  static let dnsName = "fault.example"

  static let aRecord: [UInt8] = [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 9]

  /// The outcome of a DNS query, or `nil` if it was still running after ``watchdog``.
  static func runDNS(port: UInt16, timeout: TimeInterval) async -> Result<[__DNSAnswer], Error>? {
    let outcome = try? await measure(within: watchdog) {
      await Result.capture {
        try await __dnsQuery(
          server: "127.0.0.1", port: port, name: dnsName, type: 1, timeout: timeout)
      }
    }
    return outcome?.0
  }

  @Test("DNS accepts a well-formed answer from the fixture")
  func dnsPositiveControl() async throws {
    let server = try LoopbackUDPResponder(accepts: .dnsQuery(named: Self.dnsName)) { query in
      (Self.dnsResponse(to: query, answers: Self.aRecord), 0)
    }
    defer { server.stop() }
    let result = await Self.runDNS(port: server.port, timeout: Self.answeredTimeout)
    let answers = try #require(try result?.get())
    #expect(answers.first?.rdata == Data([192, 0, 2, 9]))
  }

  @Test("DNS fails within its timeout on a faulty server", arguments: DNSFault.allCases)
  func dnsFaults(fault: DNSFault) async throws {
    let server = try LoopbackUDPResponder(accepts: .dnsQuery(named: Self.dnsName)) { query in
      switch fault {
      case .silent: return nil
      case .nxdomain: return (Self.dnsResponse(to: query, rcode: 3, answerCount: 0, answers: []), 0)
      case .servfail: return (Self.dnsResponse(to: query, rcode: 2, answerCount: 0, answers: []), 0)
      // Junk whose first two bytes are not the query's transaction ID.
      case .garbage: return ([query[0] ^ 0x80, query[1], 0x02], 0)
      case .oversized:
        // Larger than the client's receive buffer, so it arrives truncated mid-record.
        let record = Self.aRecord
        let many = (0..<400).flatMap { _ in record }
        return (Self.dnsResponse(to: query, answerCount: 400, answers: many), 0)
      case .compressionLoop:
        // The answer's owner name is a pointer to itself.
        let offset = UInt16(query.count)
        let loop: [UInt8] = [0xC0 | UInt8(offset >> 8), UInt8(offset & 0xFF)]
        return (
          Self.dnsResponse(
            to: query, answers: loop + [0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 9]), 0
        )
      case .overstatedAnswerCount:
        return (Self.dnsResponse(to: query, answerCount: 50, answers: Self.aRecord), 0)
      case .slow: return (Self.dnsResponse(to: query, answers: Self.aRecord), Self.lateAnswer)
      }
    }
    defer { server.stop() }
    // A fault the fixture answers decides the query, so it gets a timeout its answer ends; only
    // silence, junk it ignores and an answer after the watchdog leave the query to time out.
    let timeout: TimeInterval =
      [.silent, .garbage, .slow].contains(fault) ? 0.3 : Self.answeredTimeout
    let result = await Self.runDNS(port: server.port, timeout: timeout)

    let unwrapped = try #require(result, "DNS never returned from a \(fault) server")
    switch fault {
    case .nxdomain, .servfail:
      #expect {
        try unwrapped.get()
      } throws: { error in
        guard case DNSError.serverError(let rcode) = error else { return false }
        return rcode == (fault == .nxdomain ? 3 : 2)
      }
    case .oversized, .overstatedAnswerCount, .compressionLoop:
      // Fewer answer records arrived than the header claims (an oversized reply is cut off at the
      // client's receive buffer), an incomplete answer section is rejected, and so is an owner
      // name that points at itself.
      #expect {
        try unwrapped.get()
      } throws: { error in
        guard case DNSError.malformedResponse = error else { return false }
        return true
      }
    case .silent, .garbage:
      // A datagram without the query's transaction ID is ignored, so junk is silence.
      #expect {
        try unwrapped.get()
      } throws: { error in
        guard case DNSError.timeout = error else { return false }
        return true
      }
    default:
      #expect(throws: DNSError.self) { try unwrapped.get() }
    }
  }

  // MARK: TCP

  @Test("TCP probe reports an accepting listener as open and a refusing port as closed")
  func tcpOpenAndRefused() async throws {
    let listener = try LoopbackTCPServer(behavior: .silent)
    defer { listener.stop() }
    let refusing = try RefusingTCPPort()

    let open = try await tcpProbe(
      config: TCPProbeConfig(
        host: "127.0.0.1", port: Int(listener.port), timeout: Self.answeredTimeout))
    #expect(open.connectionState == .open)

    // A refused connect is answered at once. The timeout outlasts the watchdog, so a probe that
    // did not see the refusal and waited out its timeout trips the watchdog.
    let timeout = 4 * Self.watchdog
    let (closed, _) = try await measure(within: Self.watchdog) {
      try await tcpProbe(
        config: TCPProbeConfig(host: "127.0.0.1", port: Int(refusing.port), timeout: timeout))
    }
    #expect(closed.connectionState == .closed)
  }

  // MARK: UDP

  @Test("UDP probe distinguishes a reply, a closed port and silence, each within its timeout")
  func udpOutcomes() async throws {
    let payload = Data("ping".utf8)
    let echo = try LoopbackUDPResponder(accepts: .payload(Array(payload))) { request in
      (request, 0)
    }
    defer { echo.stop() }
    let silent = try LoopbackUDPResponder(accepts: .payload(Array(payload))) { _ in nil }
    defer { silent.stop() }
    // A port that answers with ICMP port-unreachable, reserved for the whole test.
    let closed = try RefusingUDPPort()
    let closedPort = closed.port
    defer { withExtendedLifetime(closed) {} }

    let replied = try await udpProbe(
      config: UDPProbeConfig(
        host: "127.0.0.1", port: Int(echo.port), timeout: Self.answeredTimeout, payload: payload))
    #expect(replied.responseType == "udp_reply")

    let refused = try await udpProbe(
      config: UDPProbeConfig(
        host: "127.0.0.1", port: Int(closedPort), timeout: Self.answeredTimeout, payload: payload)
    )
    // The host answered that the port is closed: reachable host, unreachable port.
    #expect(refused.responseType == "icmp_port_unreachable", "\(refused.responseType ?? "nil")")
    #expect(refused.isReachable)

    let timeout: TimeInterval = 0.3
    let (quiet, _) = try await measure(within: Self.watchdog) {
      try await udpProbe(
        config: UDPProbeConfig(
          host: "127.0.0.1", port: Int(silent.port), timeout: timeout, payload: payload))
    }
    #expect(quiet.responseType == "timeout")
  }

  // MARK: HTTP

  static let okResponse = Array(
    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8)

  @Test("HTTP probe reads headers from the local fixture")
  func httpPositiveControl() async throws {
    let server = try LoopbackTCPServer(behavior: .respond(response: Self.okResponse, after: 0))
    defer { server.stop() }
    let result = try await httpProbe(
      url: "http://127.0.0.1:\(server.port)/", timeout: Self.answeredTimeout)
    #expect(result.isReachable)
    #expect(result.statusCode == 200)
  }

  @Test("HTTP probe reports a 503 as reachable")
  func httpServerError() async throws {
    let response = Array(
      "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    let server = try LoopbackTCPServer(behavior: .respond(response: response, after: 0))
    defer { server.stop() }
    let result = try await httpProbe(
      url: "http://127.0.0.1:\(server.port)/", timeout: Self.answeredTimeout)
    #expect(result.isReachable)
    #expect(result.statusCode == 503)
  }

  @Test("HTTP probe waits for a slow first byte within its timeout")
  func httpSlowFirstByte() async throws {
    let server = try LoopbackTCPServer(behavior: .respond(response: Self.okResponse, after: 0.4))
    defer { server.stop() }
    let result = try await httpProbe(
      url: "http://127.0.0.1:\(server.port)/", timeout: Self.answeredTimeout)
    #expect(result.isReachable)
    #expect(result.statusCode == 200)
  }

  enum HTTPFault: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case refused, acceptThenSilence, resetMidResponse, closeWithoutResponse, firstByteTooLate
    var testDescription: String { rawValue }
  }

  @Test("HTTP probe reports failure within its timeout", arguments: HTTPFault.allCases)
  func httpFaults(fault: HTTPFault) async throws {
    // A refusal, a reset or a close ends the probe itself, so its timeout outlasts the watchdog: a
    // probe that missed the fault and waited trips it. Only a silent or late server leaves the
    // probe to its own timeout. That timeout starts before the connection exists, so it must
    // outlast connecting: at 0.5 s a loaded host's URLSession gave up before the server accepted
    // (3 of 20 loaded runs). Nothing can start it at the accept instead; the late server still
    // answers only after the watchdog.
    let endsAtTimeout = fault == .acceptThenSilence || fault == .firstByteTooLate
    let timeout: TimeInterval = endsAtTimeout ? 3 : 4 * Self.watchdog
    let server: LoopbackTCPServer?
    let port: UInt16
    // Held until the probe has finished, so the port stays reserved while it is used.
    let refusing = fault == .refused ? try RefusingTCPPort() : nil
    defer { withExtendedLifetime(refusing) {} }
    switch fault {
    case .refused:
      server = nil
      port = refusing!.port
    case .acceptThenSilence:
      server = try LoopbackTCPServer(behavior: .silent)
      port = server!.port
    case .resetMidResponse:
      server = try LoopbackTCPServer(
        behavior: .resetAfter(prefix: Array("HTTP/1.1 200 OK\r\nContent-Le".utf8)))
      port = server!.port
    case .closeWithoutResponse:
      server = try LoopbackTCPServer(behavior: .closeImmediately)
      port = server!.port
    case .firstByteTooLate:
      server = try LoopbackTCPServer(
        behavior: .respond(response: Self.okResponse, after: Self.lateAnswer))
      port = server!.port
    }
    defer { server?.stop() }

    let (result, _) = try await measure(within: Self.watchdog) {
      try await httpProbe(url: "http://127.0.0.1:\(port)/", timeout: timeout)
    }
    #expect(!result.isReachable, "\(fault): \(result.error ?? "no error")")
    #expect(result.statusCode == nil)
    // The server counts the connection on its own thread, which the probe's return can outrun,
    // so wait for the count.
    if fault != .refused {
      #expect(
        await eventually(within: 10) { (server?.accepted.value ?? 0) >= 1 },
        "accepted: \(server?.accepted.value ?? 0)")
    }
  }

  @Test("A cancelled HTTP probe against a silent server returns at once")
  func httpCancellation() async throws {
    let server = try LoopbackTCPServer(behavior: .silent)
    defer { server.stop() }
    let timeout = 4 * Self.watchdog
    let task = Task {
      try await httpProbe(url: "http://127.0.0.1:\(server.port)/", timeout: timeout)
    }
    #expect(await eventually(within: Self.watchdog) { server.accepted.value > 0 })
    // The timeout outlasts the watchdog, so a probe that returns was ended by its cancellation.
    // Cancelling runs the probe's cancellation handler, so it is inside the watchdog too.
    let (result, _) = try await measure(within: Self.watchdog) {
      task.cancel()
      return try await task.value
    }
    #expect(!result.isReachable)
  }

  /// A response whose server sends `head` and then nothing more, holding the connection open
  /// until the test stops it (#122).
  enum HeadersThenStall: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case contentLength, contentLengthAndType, chunked, chunkedAndType, connectionClose
    case smallFirstChunk, smallFirstChunkAndType, noBody, partialStatusLine
    var testDescription: String { rawValue }

    var head: String {
      let ok = "HTTP/1.1 200 OK\r\n"
      let length = "Content-Length: 100000\r\n"
      let type = "Content-Type: application/octet-stream\r\n"
      let chunked = "Transfer-Encoding: chunked\r\n"
      switch self {
      case .contentLength: return ok + length + "\r\n"
      case .contentLengthAndType: return ok + length + type + "\r\n"
      case .chunked: return ok + chunked + "\r\n"
      case .chunkedAndType: return ok + chunked + type + "\r\n"
      case .connectionClose: return ok + length + "Connection: close\r\n\r\n"
      case .smallFirstChunk: return ok + length + "\r\n0123456789"
      case .smallFirstChunkAndType: return ok + length + type + "\r\n0123456789"
      // What a server sends for a HEAD request, or a GET with an empty body, on a kept-alive
      // connection: the response is complete, and the connection stays open.
      case .noBody: return ok + "Content-Length: 0\r\n\r\n"
      case .partialStatusLine: return "HTTP/1.1 200 O"
      }
    }

    /// Whether URLSession hands the response to the delegate as soon as `head` arrives. It
    /// does so only once it has body bytes, and, without a usable `Content-Type`, enough of them
    /// to sniff a type from (measured with a delegate that logged every callback), so every
    /// other case is still waiting when the probe's timeout fires.
    var deliveredPromptly: Bool { self == .smallFirstChunkAndType || self == .noBody }

    /// The status the probe can report once its timeout fires: URLSession's metrics carry the
    /// parsed response only after body bytes have followed the headers.
    var statusAtTimeout: Int? { self == .smallFirstChunk ? 200 : nil }

    /// Whether `head` holds complete response headers, which the probe should report at once.
    var headersComplete: Bool { self != .partialStatusLine }
  }

  @Test(
    "HTTP probe against a server that stalls after its headers",
    arguments: HeadersThenStall.allCases)
  func httpHeadersThenStall(stall: HeadersThenStall) async throws {
    // Stopping the server, after the probe has returned, is what ends the stall.
    let server = try LoopbackTCPServer(behavior: .respondThenHold(response: Array(stall.head.utf8)))
    defer { server.stop() }
    let url = "http://127.0.0.1:\(server.port)/"

    if stall.deliveredPromptly {
      // The timeout outlasts the watchdog, so a probe that returns was ended by the headers.
      let timeout = 4 * Self.watchdog
      let (result, _) = try await measure(within: Self.watchdog) {
        try await httpProbe(url: url, timeout: timeout)
      }
      #expect(result.isReachable)
      #expect(result.statusCode == 200)
      #expect(result.error == nil)
      return
    }

    // URLSession has not told the delegate, so only the timeout can end the probe. It is long
    // enough for loopback bytes to arrive first; the result must still say the server answered.
    let (result, _) = try await measure(within: Self.watchdog) {
      try await httpProbe(url: url, timeout: 3)
    }
    #expect(result.isReachable, "\(result.error ?? "no error")")
    #expect(result.statusCode == stall.statusAtTimeout)
    #expect(result.error?.hasPrefix("Timeout: ") == true, "\(result.error ?? "no error")")
    #expect(result.rtt != nil)
    #expect(server.accepted.value == 1)

    guard stall.headersComplete else { return }
    // What the probe should report, and cannot while it reads responses through URLSession: the
    // status, as soon as the headers arrive.
    withKnownIssue("#122: URLSession withholds the response until body bytes arrive") {
      #expect(result.statusCode == 200)
      #expect(result.error == nil)
    }
  }
}

extension Result where Failure == Error {
  /// The value `body` returns, or the error it throws.
  static func capture(_ body: () async throws -> Success) async -> Self {
    do {
      return .success(try await body())
    } catch {
      return .failure(error)
    }
  }
}

final class ResultBox<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Result<T, Error>?

  var value: Result<T, Error>? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }

  func set(_ result: Result<T, Error>) {
    lock.lock()
    stored = result
    lock.unlock()
  }
}
