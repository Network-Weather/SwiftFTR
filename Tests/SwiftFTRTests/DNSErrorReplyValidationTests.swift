import Foundation
@_spi(Test) import SwiftFTR
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// A DNS error reply (non-zero RCODE) is held to the same structural check as a NOERROR reply:
/// the question and answer records its header declares must be present before its response code
/// is believed. Each incomplete reply below is paired with a well-formed reply of the same RCODE,
/// built by hand in the shapes real resolvers send (RFC 1035 §4.1, RFC 2308 §2), so a fix that
/// rejected every error reply fails the controls.
@Suite("DNS error reply validation")
struct DNSErrorReplyValidationTests {
  /// Long enough that only an operation that is not going to return reaches it.
  static let watchdog: TimeInterval = 20
  /// Every reply below is sent at once, so no query waits out this timeout; one that did would
  /// trip the watchdog.
  static let longTimeout: TimeInterval = 30

  enum Verdict: Equatable {
    case serverError(Int)
    case malformed
  }

  enum Shape: String, CaseIterable, CustomTestStringConvertible, Sendable {
    // Well-formed replies, which must keep their response code.
    /// NXDOMAIN with the question echoed and the zone's SOA in the authority section.
    case nxdomainWithSOA
    /// NXDOMAIN reached through a CNAME: the CNAME in the answer section, the SOA of the target's
    /// zone in the authority section (RFC 2308 §2.1).
    case nxdomainCNAMEChain
    /// SERVFAIL with the question echoed and nothing else.
    case servfailQuestionOnly
    /// REFUSED with the question echoed.
    case refusedQuestionEchoed
    /// REFUSED as a header alone, QDCOUNT 0.
    case refusedHeaderOnly

    // Incomplete replies, which are malformed whatever their response code says.
    /// NXDOMAIN declaring one answer record that is not there (the case issue #119 reports).
    case nxdomainMissingAnswer
    /// NXDOMAIN whose declared answer record stops inside its RDATA.
    case nxdomainTruncatedAnswer
    /// SERVFAIL declaring a question that is not there.
    case servfailMissingQuestion
    /// REFUSED declaring a question that stops inside its name.
    case refusedTruncatedQuestion
    /// REFUSED with the question echoed but one declared answer record missing.
    case refusedMissingAnswer

    var testDescription: String { rawValue }

    var verdict: Verdict {
      switch self {
      case .nxdomainWithSOA, .nxdomainCNAMEChain: return .serverError(3)
      case .servfailQuestionOnly: return .serverError(2)
      case .refusedQuestionEchoed, .refusedHeaderOnly: return .serverError(5)
      default: return .malformed
      }
    }

    /// The reply to `query`, built byte by byte.
    func reply(to query: [UInt8]) -> [UInt8] {
      let question = Array(query.dropFirst(12))
      // The query's name is at offset 12; its parent zone starts after the first label.
      let zone = UInt8(12 + 1 + Int(query[12]))
      let soa = DNSErrorReplyValidationTests.soaRecord(zonePointer: zone)
      let cname = DNSErrorReplyValidationTests.cnameRecord(zonePointer: zone)

      func message(rcode: UInt8, qd: UInt16, an: UInt16, ns: UInt16, _ body: [UInt8]) -> [UInt8] {
        DNSErrorReplyValidationTests.header(
          id: query, rcode: rcode, qd: qd, an: an, ns: ns, ar: 0) + body
      }

      switch self {
      case .nxdomainWithSOA:
        return message(rcode: 3, qd: 1, an: 0, ns: 1, question + soa)
      case .nxdomainCNAMEChain:
        return message(rcode: 3, qd: 1, an: 1, ns: 1, question + cname + soa)
      case .servfailQuestionOnly:
        return message(rcode: 2, qd: 1, an: 0, ns: 0, question)
      case .refusedQuestionEchoed:
        return message(rcode: 5, qd: 1, an: 0, ns: 0, question)
      case .refusedHeaderOnly:
        return message(rcode: 5, qd: 0, an: 0, ns: 0, [])
      case .nxdomainMissingAnswer:
        return message(rcode: 3, qd: 1, an: 1, ns: 0, question)
      case .nxdomainTruncatedAnswer:
        return message(rcode: 3, qd: 1, an: 1, ns: 0, question + cname.dropLast(3))
      case .servfailMissingQuestion:
        return message(rcode: 2, qd: 1, an: 0, ns: 0, [])
      case .refusedTruncatedQuestion:
        return message(rcode: 5, qd: 1, an: 0, ns: 0, Array(question.prefix(4)))
      case .refusedMissingAnswer:
        return message(rcode: 5, qd: 1, an: 1, ns: 0, question)
      }
    }
  }

  /// A response header carrying `query`'s transaction ID, QR and RD+RA set, opcode QUERY.
  static func header(
    id query: [UInt8], rcode: UInt8, qd: UInt16, an: UInt16, ns: UInt16, ar: UInt16
  ) -> [UInt8] {
    func be(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    return Array(query.prefix(2)) + [0x81, 0x80 | rcode] + be(qd) + be(an) + be(ns) + be(ar)
  }

  /// The zone's SOA, owner a pointer to the zone name in the question, as an authority record.
  static func soaRecord(zonePointer zone: UInt8) -> [UInt8] {
    let mname: [UInt8] = [2] + Array("ns".utf8) + [0xC0, zone]
    let rname: [UInt8] = [10] + Array("hostmaster".utf8) + [0xC0, zone]
    // serial, refresh, retry, expire, minimum
    let numbers: [UInt8] = [
      0x78, 0x9A, 0xBC, 0xDE, 0, 0, 0x1C, 0x20, 0, 0, 0x0E, 0x10, 0, 0x09, 0x3A, 0x80, 0, 0,
      0x0E, 0x10,
    ]
    let rdata = mname + rname + numbers
    return [0xC0, zone, 0, 6, 0, 1, 0, 0, 0x0E, 0x10, 0, UInt8(rdata.count)] + rdata
  }

  /// A CNAME for the query's name (owner a pointer to it) to `alias.` under its zone.
  static func cnameRecord(zonePointer zone: UInt8) -> [UInt8] {
    let rdata: [UInt8] = [5] + Array("alias".utf8) + [0xC0, zone]
    return [0xC0, 0x0C, 0, 5, 0, 1, 0, 0, 0, 60, 0, UInt8(rdata.count)] + rdata
  }

  static func server(_ shape: Shape) throws -> LoopbackUDPResponder {
    try LoopbackUDPResponder(accepts: .dnsQuery(named: "nx.example")) { query in
      // A query too short to carry a name gets no reply; none of the clients below sends one.
      guard query.count > 13 else { return nil }
      return (shape.reply(to: query), 0)
    }
  }

  static func verdict(of error: any Error) -> Verdict? {
    switch error {
    case DNSError.serverError(let rcode): return .serverError(rcode)
    case DNSError.malformedResponse: return .malformed
    default: return nil
    }
  }

  @Test(
    "The SPI query reports a well-formed error reply's RCODE and an incomplete one as malformed",
    arguments: Shape.allCases)
  func spiQuery(shape: Shape) async throws {
    let server = try Self.server(shape)
    defer { server.stop() }

    let (result, _) = try await measure(within: Self.watchdog) {
      await Result.capture {
        try await __dnsQuery(
          server: "127.0.0.1", port: server.port, name: "nx.example", type: 1,
          timeout: Self.longTimeout)
      }
    }
    switch result {
    case .success(let answers):
      Issue.record("expected \(shape.verdict), got \(answers.count) answers")
    case .failure(let error):
      #expect(Self.verdict(of: error) == shape.verdict, "threw \(error)")
    }
  }

  @Test("The public query method reports the same verdict", arguments: Shape.allCases)
  func publicQuery(shape: Shape) async throws {
    let server = try Self.server(shape)
    defer { server.stop() }

    let (result, _) = try await measure(within: Self.watchdog) {
      await Result.capture {
        try await TestSeams.$dnsServerPort.withValue(server.port) {
          try await SwiftFTR().dns.query(
            name: "nx.example", type: .a, server: "127.0.0.1", timeout: Self.longTimeout)
        }
      }
    }
    switch result {
    case .success(let reply):
      Issue.record("expected \(shape.verdict), got \(reply.records.count) records")
    case .failure(let error):
      #expect(Self.verdict(of: error) == shape.verdict, "threw \(error)")
    }
  }

  @Test(
    "dnsProbe answers a well-formed error reply and calls an incomplete one malformed",
    arguments: Shape.allCases)
  func probe(shape: Shape) async throws {
    let server = try Self.server(shape)
    defer { server.stop() }

    let (result, _) = try await measure(within: Self.watchdog) {
      try await TestSeams.$dnsServerPort.withValue(server.port) {
        try await dnsProbe(server: "127.0.0.1", query: "nx.example", timeout: Self.longTimeout)
      }
    }
    // Either way a DNS server sent a reply with the query's ID, so it is reachable and timed.
    #expect(result.isReachable)
    let rtt = try #require(result.rtt)
    #expect(result.elapsed == rtt)
    switch shape.verdict {
    case .serverError(let rcode):
      #expect(result.outcome == .answered)
      #expect(result.responseCode == rcode)
      #expect(result.error == nil)
    case .malformed:
      #expect(result.outcome == .malformedReply)
      #expect(result.responseCode == nil)
      #expect(result.error == "Malformed response")
    }
  }
}
