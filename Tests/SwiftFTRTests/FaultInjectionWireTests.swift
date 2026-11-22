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
/// Time bounds are the moment a slow fixture would have answered, a multiple of the client's
/// timeout: a client that waited for the answer, or for nothing, fails them.
@Suite("FaultInjection: wire protocols")
struct FaultInjectionWireTests {
  /// How much later than the client's timeout a slow fixture answers.
  static let lateFactor: TimeInterval = 10

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
    case silent, garbage, wrongTransaction, slow
    var testDescription: String { rawValue }
  }

  static func runSTUN(server: LoopbackUDPResponder, timeout: TimeInterval) async
    -> (Result<STUNPublicIP, Error>?, TimeInterval)
  {
    let box = ResultBox<STUNPublicIP>()
    let duration = ResultBox<TimeInterval>()
    let (address, length) = server.address
    let returned = await returnsWithin(lateFactor * timeout) {
      // Time the call itself, on the thread that makes it. Timing from the caller would add
      // however long a loaded machine takes to start that thread, which is not STUN's doing.
      let start = monotonicNow()
      box.set(
        Result {
          try stunGetPublicIP(
            family: AF_INET, server: address, serverLen: length, serverLabel: "fixture",
            timeout: timeout)
        })
      duration.set(.success(monotonicNow() - start))
    }
    let elapsed = (try? duration.value?.get()) ?? .infinity
    return (returned ? box.value : nil, elapsed)
  }

  @Test("STUN accepts a well-formed binding response from the fixture")
  func stunPositiveControl() async throws {
    let server = try LoopbackUDPResponder { request in
      Self.stunSuccess(for: request, ip: [198, 51, 100, 7]).map { ($0, 0) }
    }
    defer { server.stop() }
    let (result, _) = await Self.runSTUN(server: server, timeout: 0.5)
    #expect(try result?.get().ip == "198.51.100.7")
  }

  @Test("STUN gives up within its timeout on a faulty server", arguments: STUNFault.allCases)
  func stunFaults(fault: STUNFault) async throws {
    let server = try LoopbackUDPResponder { request in
      switch fault {
      case .silent: return nil
      case .garbage: return ([0xDE, 0xAD, 0xBE, 0xEF], 0)
      case .wrongTransaction:
        var reply = Self.stunSuccess(for: request, ip: [198, 51, 100, 7])!
        reply[8] ^= 0xFF
        return (reply, 0)
      case .slow:
        return Self.stunSuccess(for: request, ip: [198, 51, 100, 7]).map {
          ($0, Self.lateFactor * 0.3)
        }
      }
    }
    defer { server.stop() }
    let timeout: TimeInterval = 0.3
    let (result, elapsed) = await Self.runSTUN(server: server, timeout: timeout)

    let unwrapped = try #require(result, "STUN never returned from a \(fault) server")
    #expect(throws: STUNError.self) { try unwrapped.get() }
    #expect(
      elapsed < Self.lateFactor * timeout, "STUN took \(elapsed)s against a \(timeout)s timeout")
    #expect(server.requests.value == 1)
  }

  @Test("A sub-microsecond STUN timeout is still a timeout, not an unbounded wait")
  func stunTinyTimeout() async throws {
    let server = try LoopbackUDPResponder { _ in nil }
    defer { server.stop() }
    // The failure is a wait with no end, so any finite watchdog tells them apart.
    let (address, length) = server.address
    let returned = await returnsWithin(5) {
      _ = try? stunGetPublicIP(
        family: AF_INET, server: address, serverLen: length, serverLabel: "fixture",
        timeout: 0.000_000_5)
    }
    #expect(returned, "STUN with a 0.5 µs timeout was still waiting after 5 s")
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
    var header = Array(query.prefix(12))
    header[2] = 0x81
    header[3] = 0x80 | rcode
    header[6] = UInt8(answerCount >> 8)
    header[7] = UInt8(answerCount & 0xFF)
    return header + Array(query.dropFirst(12)) + answers
  }

  static let aRecord: [UInt8] = [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 9]

  static func runDNS(port: UInt16, timeout: TimeInterval) async
    -> (Result<[__DNSAnswer], Error>?, TimeInterval)
  {
    let box = ResultBox<[__DNSAnswer]>()
    let duration = ResultBox<TimeInterval>()
    let returned = await returnsWithin(lateFactor * timeout) {
      // Timed on the calling thread, for the reason given in `runSTUN`.
      let start = monotonicNow()
      box.set(
        Result {
          try __dnsQuery(
            server: "127.0.0.1", port: port, name: "fault.example", type: 1, timeout: timeout)
        })
      duration.set(.success(monotonicNow() - start))
    }
    let elapsed = (try? duration.value?.get()) ?? .infinity
    return (returned ? box.value : nil, elapsed)
  }

  @Test("DNS accepts a well-formed answer from the fixture")
  func dnsPositiveControl() async throws {
    let server = try LoopbackUDPResponder { query in
      (Self.dnsResponse(to: query, answers: Self.aRecord), 0)
    }
    defer { server.stop() }
    let (result, _) = await Self.runDNS(port: server.port, timeout: 0.5)
    let answers = try #require(try result?.get())
    #expect(answers.first?.rdata == Data([192, 0, 2, 9]))
  }

  @Test("DNS fails within its timeout on a faulty server", arguments: DNSFault.allCases)
  func dnsFaults(fault: DNSFault) async throws {
    let server = try LoopbackUDPResponder { query in
      switch fault {
      case .silent: return nil
      case .nxdomain: return (Self.dnsResponse(to: query, rcode: 3, answerCount: 0, answers: []), 0)
      case .servfail: return (Self.dnsResponse(to: query, rcode: 2, answerCount: 0, answers: []), 0)
      case .garbage: return ([0x00, 0x01, 0x02], 0)
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
      case .slow: return (Self.dnsResponse(to: query, answers: Self.aRecord), Self.lateFactor * 0.3)
      }
    }
    defer { server.stop() }
    let timeout: TimeInterval = 0.3
    let (result, elapsed) = await Self.runDNS(port: server.port, timeout: timeout)

    let unwrapped = try #require(result, "DNS never returned from a \(fault) server")
    #expect(
      elapsed < Self.lateFactor * timeout, "DNS took \(elapsed)s against a \(timeout)s timeout")
    switch fault {
    case .nxdomain, .servfail:
      #expect {
        try unwrapped.get()
      } throws: { error in
        guard case DNSError.serverError(let rcode) = error else { return false }
        return rcode == (fault == .nxdomain ? 3 : 2)
      }
    case .oversized, .overstatedAnswerCount:
      // Either rejected or the records that did arrive; never a crash or a hang.
      _ = try? unwrapped.get()
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
      config: TCPProbeConfig(host: "127.0.0.1", port: Int(listener.port), timeout: 1))
    #expect(open.connectionState == .open)

    // A refused connect is answered at once; one that waited out its timeout was not seen.
    let timeout: TimeInterval = 10
    let (closed, _) = try await measure(within: timeout / 2) {
      try await tcpProbe(
        config: TCPProbeConfig(host: "127.0.0.1", port: Int(refusing.port), timeout: timeout))
    }
    #expect(closed.connectionState == .closed)
  }

  // MARK: UDP

  @Test("UDP probe distinguishes a reply, a closed port and silence, each within its timeout")
  func udpOutcomes() async throws {
    let echo = try LoopbackUDPResponder { request in (request, 0) }
    defer { echo.stop() }
    let silent = try LoopbackUDPResponder { _ in nil }
    defer { silent.stop() }
    // A port that answers with ICMP port-unreachable, reserved for the whole test.
    let closed = try RefusingUDPPort()
    let closedPort = closed.port
    defer { withExtendedLifetime(closed) {} }

    let payload = Data("ping".utf8)
    let replied = try await udpProbe(
      config: UDPProbeConfig(host: "127.0.0.1", port: Int(echo.port), timeout: 1, payload: payload))
    #expect(replied.responseType == "udp_reply")

    let refused = try await udpProbe(
      config: UDPProbeConfig(host: "127.0.0.1", port: Int(closedPort), timeout: 1, payload: payload)
    )
    // The host answered that the port is closed: reachable host, unreachable port.
    #expect(refused.responseType == "icmp_port_unreachable", "\(refused.responseType ?? "nil")")
    #expect(refused.isReachable)

    let timeout: TimeInterval = 0.3
    let (quiet, _) = try await measure(within: Self.lateFactor * timeout) {
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
    let result = try await httpProbe(url: "http://127.0.0.1:\(server.port)/", timeout: 2)
    #expect(result.isReachable)
    #expect(result.statusCode == 200)
  }

  @Test("HTTP probe reports a 503 as reachable")
  func httpServerError() async throws {
    let response = Array(
      "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    let server = try LoopbackTCPServer(behavior: .respond(response: response, after: 0))
    defer { server.stop() }
    let result = try await httpProbe(url: "http://127.0.0.1:\(server.port)/", timeout: 2)
    #expect(result.isReachable)
    #expect(result.statusCode == 503)
  }

  @Test("HTTP probe waits for a slow first byte within its timeout")
  func httpSlowFirstByte() async throws {
    let server = try LoopbackTCPServer(behavior: .respond(response: Self.okResponse, after: 0.4))
    defer { server.stop() }
    let result = try await httpProbe(url: "http://127.0.0.1:\(server.port)/", timeout: 3)
    #expect(result.isReachable)
    #expect(result.statusCode == 200)
  }

  enum HTTPFault: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case refused, acceptThenSilence, resetMidResponse, closeWithoutResponse, firstByteTooLate
    var testDescription: String { rawValue }
  }

  @Test("HTTP probe reports failure within its timeout", arguments: HTTPFault.allCases)
  func httpFaults(fault: HTTPFault) async throws {
    let timeout: TimeInterval = 0.5
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
        behavior: .respond(response: Self.okResponse, after: Self.lateFactor * timeout))
      port = server!.port
    }
    defer { server?.stop() }

    let (result, _) = try await measure(within: Self.lateFactor * timeout) {
      try await httpProbe(url: "http://127.0.0.1:\(port)/", timeout: timeout)
    }
    #expect(!result.isReachable, "\(fault): \(result.error ?? "no error")")
    #expect(result.statusCode == nil)
    if fault != .refused { #expect((server?.accepted.value ?? 0) >= 1) }
  }

  @Test("A cancelled HTTP probe against a silent server returns at once")
  func httpCancellation() async throws {
    let server = try LoopbackTCPServer(behavior: .silent)
    defer { server.stop() }
    let timeout: TimeInterval = 30
    let task = Task {
      try await httpProbe(url: "http://127.0.0.1:\(server.port)/", timeout: timeout)
    }
    #expect(await eventually(within: 2) { server.accepted.value > 0 })
    task.cancel()
    // Returned well inside its timeout, so the cancellation ended it.
    let (result, _) = try await measure(within: timeout / 6) { try await task.value }
    #expect(!result.isReachable)
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
