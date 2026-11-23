import Foundation
@_spi(Test) import SwiftFTR
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// A DNS query ignores a datagram that carries its transaction ID but echoes a different question,
/// as it ignores one with another ID, and keeps waiting to the same deadline. The name is compared
/// without regard to ASCII case; a reply with no question section, or one whose question cannot be
/// read, is judged as before.
@Suite("DNS ignores replies that echo another question")
struct DNSQuestionMatchTests {
  typealias Foreign = DNSForeignReplyTests

  static let watchdog: TimeInterval = 20

  /// The end of the query's first question name: the offset of its QTYPE.
  static func questionTypeOffset(_ message: [UInt8]) -> Int {
    var offset = 12
    while message[offset] != 0 { offset += 1 + Int(message[offset]) }
    return offset + 1
  }

  /// How a reply's echoed question differs from the query's.
  enum Echo: String, CaseIterable, CustomTestStringConvertible, Sendable {
    /// Another name of the same length, so the answer's compression pointer still lands on it.
    case otherName
    /// The same name, asked for AAAA instead of A.
    case otherType
    /// The same name and type in the CHAOS class.
    case otherClass

    /// `reply` (whose question is the query's) with its question changed.
    func apply(_ reply: [UInt8]) -> [UInt8] {
      var copy = reply
      let typeOffset = DNSQuestionMatchTests.questionTypeOffset(reply)
      switch self {
      case .otherName:
        copy[13] = copy[13] == UInt8(ascii: "x") ? UInt8(ascii: "y") : UInt8(ascii: "x")
      case .otherType: copy[typeOffset + 1] = 28
      case .otherClass: copy[typeOffset + 3] = 3
      }
      return copy
    }
    var testDescription: String { rawValue }
  }

  // MARK: Another question, then the reply

  @Test(
    "A reply echoing another question is ignored, and the query's own reply answers it",
    arguments: Echo.allCases, Foreign.families)
  func otherQuestionThenValid(echo: Echo, family: Int32) async throws {
    let delay: TimeInterval = 0.2
    let peer = try ScriptedDNSPeer(family: family) { query in
      [(echo.apply(Foreign.answer(query, last: 1)), 0), (Foreign.answer(query, last: 2), delay)]
    }
    defer { peer.stop() }

    let (result, _) = try await measure(within: Self.watchdog) {
      try await TestSeams.$dnsServerPort.withValue(peer.port) {
        try await SwiftFTR().dns.a(
          hostname: "question.example", server: Foreign.loopback(family), timeout: 5)
      }
    }
    #expect(
      result.records.first.map { "\($0.data)" } == "\(DNSRecordData.ipv4("192.0.2.2"))",
      "the reply to another question was taken")
    #expect(result.rttMs >= delay * 1000, "rttMs \(result.rttMs)")
    #expect(
      await eventually(within: Self.watchdog) { peer.sent.value == 2 }, "sent: \(peer.sent.value)")
  }

  // MARK: Another question only

  @Test(
    "A server that echoes only another question times out, and is not reachable",
    arguments: Echo.allCases)
  func otherQuestionOnly(echo: Echo) async throws {
    let count = 3
    let peer = try ScriptedDNSPeer { query in
      (0..<count).map { _ in (echo.apply(Foreign.answer(query, last: 1)), 0) }
    }
    defer { peer.stop() }
    let timeout: TimeInterval = 2

    let (thrown, _) = try await Foreign.waitsOutForeign(count: count, timeout: timeout) {
      await EventBasedDNSTests.error {
        try await __dnsQuery(
          server: "127.0.0.1", port: peer.port, name: "question.example", type: 1,
          timeout: timeout)
      }
    }
    #expect(EventBasedDNSTests.isTimeout(thrown), "\(String(describing: thrown))")

    let (probe, _) = try await Foreign.waitsOutForeign(count: count, timeout: timeout) {
      try await TestSeams.$dnsServerPort.withValue(peer.port) {
        try await dnsProbe(server: "127.0.0.1", query: "question.example", timeout: timeout)
      }
    }
    #expect(probe.outcome == .timedOut)
    #expect(!probe.isReachable)
    #expect(probe.error == "Timeout - no response")
  }

  // MARK: Replies that still decide the query

  @Test("A reply echoing the name in another letter case answers the query")
  func otherCaseAnswers() async throws {
    let peer = try ScriptedDNSPeer { query in
      var reply = Foreign.answer(query, last: 7)
      let end = Self.questionTypeOffset(reply) - 1
      for i in 13..<end where (0x61...0x7A).contains(reply[i]) { reply[i] -= 0x20 }
      return [(reply, 0)]
    }
    defer { peer.stop() }
    // Waiting out this timeout would mean the reply was ignored.
    let timeout: TimeInterval = 30

    let (answers, _) = try await measure(within: Self.watchdog) {
      try await __dnsQuery(
        server: "127.0.0.1", port: peer.port, name: "Question.Example", type: 1, timeout: timeout)
    }
    #expect(answers.first?.rdata == Data([192, 0, 2, 7]))
  }

  @Test("A reply with no question section still decides the query at once")
  func noQuestionDecides() async throws {
    // REFUSED, with QDCOUNT 0 and nothing after the header, as some servers send it.
    let peer = try ScriptedDNSPeer { query in
      var header = Array(query.prefix(12))
      header[2] = 0x81
      header[3] = 0x85
      header[4] = 0
      header[5] = 0
      return [(header, 0)]
    }
    defer { peer.stop() }
    let timeout: TimeInterval = 30

    let (outcome, _) = try await measure(within: Self.watchdog) {
      try await TestSeams.$dnsServerPort.withValue(peer.port) {
        let thrown = await EventBasedDNSTests.error {
          try await __dnsQuery(
            server: "127.0.0.1", port: peer.port, name: "refused.example", type: 1,
            timeout: timeout)
        }
        let probe = try await dnsProbe(
          server: "127.0.0.1", query: "refused.example", timeout: timeout)
        return (thrown, probe)
      }
    }
    let (thrown, probe) = outcome
    if case DNSError.serverError(rcode: 5)? = thrown {
    } else {
      Issue.record("expected serverError(rcode: 5), got \(String(describing: thrown))")
    }
    #expect(probe.outcome == .answered)
    #expect(probe.isReachable)
    #expect(probe.responseCode == 5)
  }

  @Test("A reply whose question is cut short still ends the query at once as malformed")
  func unreadableQuestionIsMalformed() async throws {
    // The header declares one question; the datagram ends inside its name.
    let peer = try ScriptedDNSPeer { query in
      var reply = Array(query.prefix(15))
      reply[2] = 0x81
      reply[3] = 0x80
      return [(reply, 0)]
    }
    defer { peer.stop() }
    let timeout: TimeInterval = 30

    let (thrown, _) = try await measure(within: Self.watchdog) {
      await EventBasedDNSTests.error {
        try await __dnsQuery(
          server: "127.0.0.1", port: peer.port, name: "short.example", type: 1, timeout: timeout)
      }
    }
    #expect(EventBasedDNSTests.isMalformed(thrown), "\(String(describing: thrown))")
  }

  // MARK: A stream that never stops

  static func endlessOtherQuestion(family: Int32 = AF_INET) throws -> ScriptedDNSPeer {
    try ScriptedDNSPeer(
      family: family, feed: { Echo.otherName.apply(Foreign.answer($0, last: 1)) },
      script: { _ in [] })
  }

  @Test(
    "Replies echoing another question that never stop do not hold off the deadline",
    arguments: Foreign.families)
  func endlessOtherQuestionDeadline(family: Int32) async throws {
    let peer = try Self.endlessOtherQuestion(family: family)
    defer { peer.stop() }
    let reads = FaultCounter()
    let timeout: TimeInterval = 0.3

    let (thrown, elapsed) = try await measure(within: Self.watchdog) {
      await TestSeams.$fileControl.withValue(Foreign.leaveBlocking) {
        await TestSeams.$receiveDatagram.withValue(Foreign.countingReceive(reads)) {
          await EventBasedDNSTests.error {
            try await __dnsQuery(
              server: Foreign.loopback(family), port: peer.port, name: "endless.example",
              type: 1, timeout: timeout)
          }
        }
      }
    }
    let flow = peer.keptFeeding(since: 0, limit: Foreign.neverDryTimeout)

    #expect(flow.ok, "the socket was not kept fed while the query waited: \(flow.detail)")
    #expect(reads.value >= 10, "the query read only \(reads.value) datagrams")
    #expect(EventBasedDNSTests.isTimeout(thrown), "\(String(describing: thrown))")
    #expect(elapsed >= timeout * 0.95, "ended after \(elapsed)s against a \(timeout)s timeout")
  }

  // MARK: Blocking path

  @Test("The blocking TXT query ignores a reply echoing another question and takes its own")
  func blockingOtherQuestionThenValid() async throws {
    let peer = try ScriptedDNSPeer { query in
      // The reply to the other question says "no"; the query's own says "ok".
      let other = FaultInjectionWireTests.dnsResponse(
        to: query, answers: [0xC0, 0x0C, 0, 16, 0, 1, 0, 0, 0, 60, 0, 3, 2] + Array("no".utf8))
      let reply = FaultInjectionWireTests.dnsResponse(to: query, answers: Foreign.txtRecord)
      return [(Echo.otherName.apply(other), 0), (reply, 0)]
    }
    defer { peer.stop() }

    let strings = try await Foreign.onOwnThread(port: peer.port) {
      DNSClient.queryTXTBlocking(name: "blocking.example", timeout: 5, servers: ["127.0.0.1"])
    }.value
    #expect(strings == ["ok"])
    #expect(
      await eventually(within: Self.watchdog) { peer.sent.value == 2 }, "sent: \(peer.sent.value)")
  }

  @Test("The blocking TXT query fed replies echoing another question gives up at its deadline")
  func blockingEndlessOtherQuestion() async throws {
    let peer = try Self.endlessOtherQuestion()
    defer { peer.stop() }
    let timeout: TimeInterval = 0.3

    let call = try await Foreign.onOwnThread(port: peer.port) {
      DNSClient.queryTXTBlocking(name: "blocking.example", timeout: timeout, servers: ["127.0.0.1"])
    }
    let (strings, elapsed) = (call.value, call.elapsed)
    let flow = peer.keptFeeding(since: 0, minimum: 10, limit: timeout)

    #expect(flow.ok, "the socket was not kept fed while the query waited: \(flow.detail)")
    #expect(strings == nil, "the reply to another question was taken")
    #expect(elapsed >= timeout * 0.95, "ended after \(elapsed)s against a \(timeout)s timeout")
  }
}
