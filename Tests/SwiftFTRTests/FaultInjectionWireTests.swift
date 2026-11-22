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
@Suite("FaultInjection: wire protocols")
struct FaultInjectionWireTests {

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
    let (address, length) = server.address
    let start = monotonicNow()
    let returned = await returnsWithin(timeout + 2) {
      box.set(
        Result {
          try stunGetPublicIP(
            family: AF_INET, server: address, serverLen: length, serverLabel: "fixture",
            timeout: timeout)
        })
    }
    return (returned ? box.value : nil, monotonicNow() - start)
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
      case .slow: return Self.stunSuccess(for: request, ip: [198, 51, 100, 7]).map { ($0, 1.0) }
      }
    }
    defer { server.stop() }
    let timeout: TimeInterval = 0.3
    let (result, elapsed) = await Self.runSTUN(server: server, timeout: timeout)

    let unwrapped = try #require(result, "STUN never returned from a \(fault) server")
    #expect(throws: STUNError.self) { try unwrapped.get() }
    #expect(elapsed < timeout + 0.5, "STUN took \(elapsed)s against a \(timeout)s timeout")
    #expect(server.requests.value == 1)
  }

  @Test("A sub-microsecond STUN timeout is still a timeout, not an unbounded wait")
  func stunTinyTimeout() async throws {
    let server = try LoopbackUDPResponder { _ in nil }
    defer { server.stop() }
    let (result, elapsed) = await Self.runSTUN(server: server, timeout: 0.000_000_5)
    #expect(result != nil, "STUN with a 0.5 µs timeout was still waiting after \(elapsed)s")
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
    let start = monotonicNow()
    let returned = await returnsWithin(timeout + 2) {
      box.set(
        Result {
          try __dnsQuery(
            server: "127.0.0.1", port: port, name: "fault.example", type: 1, timeout: timeout)
        })
    }
    return (returned ? box.value : nil, monotonicNow() - start)
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
      case .slow: return (Self.dnsResponse(to: query, answers: Self.aRecord), 1.0)
      }
    }
    defer { server.stop() }
    let timeout: TimeInterval = 0.3
    let (result, elapsed) = await Self.runDNS(port: server.port, timeout: timeout)

    let unwrapped = try #require(result, "DNS never returned from a \(fault) server")
    #expect(elapsed < timeout + 0.5, "DNS took \(elapsed)s against a \(timeout)s timeout")
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

    let (closed, elapsed) = try await measure {
      try await tcpProbe(
        config: TCPProbeConfig(host: "127.0.0.1", port: Int(refusing.port), timeout: 2))
    }
    #expect(closed.connectionState == .closed)
    #expect(elapsed < 0.5, "a refused connect took \(elapsed)s")
  }

  // MARK: UDP

  @Test("UDP probe distinguishes a reply, a closed port and silence, each within its timeout")
  func udpOutcomes() async throws {
    let echo = try LoopbackUDPResponder { request in (request, 0) }
    defer { echo.stop() }
    let silent = try LoopbackUDPResponder { _ in nil }
    defer { silent.stop() }
    // A port nothing is bound to: bind, read the port, release it.
    let (probeFD, closedPort) = try bindLoopback(family: AF_INET, type: SOCK_DGRAM)
    close(probeFD)

    let payload = Data("ping".utf8)
    let replied = try await udpProbe(
      config: UDPProbeConfig(host: "127.0.0.1", port: Int(echo.port), timeout: 1, payload: payload))
    #expect(replied.responseType == "udp_reply")

    let refused = try await udpProbe(
      config: UDPProbeConfig(host: "127.0.0.1", port: Int(closedPort), timeout: 1, payload: payload)
    )
    #expect(refused.responseType != "udp_reply")

    let timeout: TimeInterval = 0.3
    let (quiet, elapsed) = try await measure {
      try await udpProbe(
        config: UDPProbeConfig(
          host: "127.0.0.1", port: Int(silent.port), timeout: timeout, payload: payload))
    }
    #expect(quiet.responseType == "timeout")
    #expect(elapsed < timeout + 0.5, "silent UDP probe took \(elapsed)s")
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
    switch fault {
    case .refused:
      server = nil
      port = try RefusingTCPPort().port
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
      server = try LoopbackTCPServer(behavior: .respond(response: Self.okResponse, after: 2))
      port = server!.port
    }
    defer { server?.stop() }

    let (result, elapsed) = try await measure {
      try await httpProbe(url: "http://127.0.0.1:\(port)/", timeout: timeout)
    }
    #expect(!result.isReachable, "\(fault): \(result.error ?? "no error")")
    #expect(result.statusCode == nil)
    #expect(elapsed < timeout + 1.0, "\(fault): probe took \(elapsed)s against \(timeout)s")
    if fault != .refused { #expect((server?.accepted.value ?? 0) >= 1) }
  }

  @Test("A cancelled HTTP probe against a silent server returns at once")
  func httpCancellation() async throws {
    let server = try LoopbackTCPServer(behavior: .silent)
    defer { server.stop() }
    let task = Task { try await httpProbe(url: "http://127.0.0.1:\(server.port)/", timeout: 30) }
    #expect(await eventually(within: 2) { server.accepted.value > 0 })
    let cancelledAt = monotonicNow()
    task.cancel()
    let result = try await task.value
    #expect(!result.isReachable)
    #expect(monotonicNow() - cancelledAt < 0.5)
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
