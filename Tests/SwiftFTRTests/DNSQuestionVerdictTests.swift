import Foundation
@_spi(Test) import SwiftFTR
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// Every shape a reply's first question can take, with the verdict each caller gives it: the
/// event-based query, `dnsProbe`, and the TXT lookup behind the whoami fallback. Each datagram carries the query's
/// transaction ID. The question matcher and the validator read the first question by one rule
/// (`DNSClient.firstQuestion`), so a datagram is either ignored as an answer to another question
/// or decides the query, never both.
@Suite("DNS first-question verdicts")
struct DNSQuestionVerdictTests {
  typealias Foreign = DNSForeignReplyTests

  static let watchdog: TimeInterval = 20

  enum Verdict: String, Sendable {
    /// Decides the query with its answer records.
    case answered
    /// Decides the query with RCODE 5 (REFUSED).
    case refused
    /// Decides the query as `malformedResponse`.
    case malformed
    /// Ignored: the query waits to its deadline.
    case ignored
  }

  enum Shape: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case matching, otherCase, otherName, otherType
    case pointerIntoHeader, pointerLoop, reservedLabel40, reservedLabel80
    case labelPastEnd, nameOver255, missingTerminator, typeClassCutShort
    case twoQuestionsFirstMatching, twoQuestionsFirstOther, noQuestionTrailingBytes

    var testDescription: String { rawValue }

    var verdict: Verdict {
      switch self {
      case .matching, .otherCase, .twoQuestionsFirstMatching: .answered
      case .noQuestionTrailingBytes: .refused
      case .otherName, .otherType, .twoQuestionsFirstOther: .ignored
      default: .malformed
      }
    }

    /// What `DNSClient.firstQuestion` reports for the datagram.
    var reading: String {
      switch verdict {
      case .answered, .ignored: "readable"
      case .refused: "absent"
      case .malformed: "unreadable"
      }
    }

    /// The reply to `query`, carrying its transaction ID.
    func datagram(_ query: [UInt8]) -> [UInt8] {
      // A name of at least one label, so it has a byte 1 to change below.
      guard let typeOffset = DNSQuestionMatchTests.questionTypeOffset(query), typeOffset > 14
      else { return [] }
      let name = Array(query[12..<typeOffset])
      let typeClass = Array(query[typeOffset..<typeOffset + 4])
      var otherName = name
      otherName[1] = otherName[1] == UInt8(ascii: "x") ? UInt8(ascii: "y") : UInt8(ascii: "x")
      let answer = Foreign.txtRecord

      func header(questions: UInt16, answers: UInt16, rcode: UInt8 = 0) -> [UInt8] {
        Array(query.prefix(2)) + [0x81, 0x80 | rcode, 0, UInt8(questions), 0, UInt8(answers)]
          + [0, 0, 0, 0]
      }
      let refusedHeader = header(questions: 1, answers: 0, rcode: 5)

      switch self {
      case .matching:
        return header(questions: 1, answers: 1) + name + typeClass + answer
      case .otherCase:
        let upper = name.map { (0x61...0x7A).contains($0) ? $0 - 0x20 : $0 }
        return header(questions: 1, answers: 1) + upper + typeClass + answer
      case .otherName:
        return header(questions: 1, answers: 1) + otherName + typeClass + answer
      case .otherType:
        return header(questions: 1, answers: 1) + name + [0, 28] + typeClass.suffix(2) + answer
      case .pointerIntoHeader:
        // Points at header byte 4, the zero high byte of QDCOUNT, which reads as the root name.
        return refusedHeader + [0xC0, 0x04] + typeClass
      case .pointerLoop:
        return refusedHeader + [0xC0, 0x0C] + typeClass
      case .reservedLabel40:
        return refusedHeader + [0x41, 0x61, 0] + typeClass
      case .reservedLabel80:
        return refusedHeader + [0x81, 0x61, 0] + typeClass
      case .labelPastEnd:
        return refusedHeader + [50] + Array("abc".utf8)
      case .nameOver255:
        // Four 63-byte labels and the root: 257 bytes, with a complete type and class.
        let label: [UInt8] = [63] + [UInt8](repeating: UInt8(ascii: "a"), count: 63)
        // Built in steps: Swift 6.1 cannot type-check the whole sum as one expression.
        var reply: [UInt8] = refusedHeader
        for _ in 0..<4 { reply += label }
        reply += [0]
        reply += typeClass
        return reply
      case .missingTerminator:
        return refusedHeader + [3] + Array("abc".utf8)
      case .typeClassCutShort:
        return refusedHeader + name + Array(typeClass.prefix(2))
      case .twoQuestionsFirstMatching:
        var reply: [UInt8] = header(questions: 2, answers: 1)
        reply += name + typeClass
        reply += name + typeClass
        reply += answer
        return reply
      case .twoQuestionsFirstOther:
        var reply: [UInt8] = header(questions: 2, answers: 1)
        reply += otherName + typeClass
        reply += name + typeClass
        reply += answer
        return reply
      case .noQuestionTrailingBytes:
        return header(questions: 0, answers: 0, rcode: 5) + [0xDE, 0xAD, 0xBE, 0xEF]
      }
    }
  }

  /// An ignored reply waits out this timeout; any other must be decided long before it.
  static func timeout(_ shape: Shape) -> TimeInterval { shape.verdict == .ignored ? 0.3 : 30 }

  // MARK: The shared reading

  @Test(
    "The first question is read the same way for matching and for validation",
    arguments: Shape.allCases)
  func reading(shape: Shape) throws {
    let query = try #require(Self.sampleQuery)
    let reading =
      switch DNSClient.firstQuestion(shape.datagram(query)) {
      case .absent: "absent"
      case .unreadable: "unreadable"
      case .readable: "readable"
      }
    #expect(reading == shape.reading)
  }

  /// A query for question.example, type A, laid out as the client builds one.
  static let sampleQuery: [UInt8]? = {
    var header: [UInt8] = [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
    header += [8] + Array("question".utf8) + [7] + Array("example".utf8) + [0]
    return header + [0, 1, 0, 1]
  }()

  // MARK: Event-based query and dnsProbe

  @Test(
    "Each first-question shape gets its verdict from the query and dnsProbe",
    arguments: Shape.allCases)
  func eventPathAndProbe(shape: Shape) async throws {
    let peer = try ScriptedDNSPeer { query in [(shape.datagram(query), 0)] }
    defer { peer.stop() }
    let timeout = Self.timeout(shape)

    let ((thrown, probe), elapsed) = try await measure(within: Self.watchdog) {
      try await TestSeams.$dnsServerPort.withValue(peer.port) {
        let thrown = await EventBasedDNSTests.error {
          try await __dnsQuery(
            server: "127.0.0.1", port: peer.port, name: "question.example", type: 1,
            timeout: timeout)
        }
        let probe = try await dnsProbe(
          server: "127.0.0.1", query: "question.example", timeout: timeout)
        return (thrown, probe)
      }
    }
    let detail = "\(String(describing: thrown)); probe \(probe.outcome) \(probe.error ?? "")"
    switch shape.verdict {
    case .answered:
      #expect(thrown == nil, "\(detail)")
      #expect(probe.outcome == .answered && probe.isReachable && probe.responseCode == 0)
    case .refused:
      if case DNSError.serverError(rcode: 5)? = thrown {
      } else {
        Issue.record("expected serverError(5): \(detail)")
      }
      #expect(probe.outcome == .answered && probe.isReachable && probe.responseCode == 5)
    case .malformed:
      #expect(EventBasedDNSTests.isMalformed(thrown), "\(detail)")
      #expect(probe.outcome == .malformedReply && probe.isReachable, "\(detail)")
    case .ignored:
      #expect(EventBasedDNSTests.isTimeout(thrown), "\(detail)")
      #expect(probe.outcome == .timedOut && !probe.isReachable, "\(detail)")
      // Both waited out their deadlines.
      #expect(elapsed >= 2 * timeout * 0.95, "ended after \(elapsed)s")
    }
  }

  @Test("The scripted peer answers its query after a short and an empty stray queued ahead of it")
  func peerIgnoresStrays() async throws {
    // The shape script reads the query's question, so a stray shorter than one handed to it
    // would end the test process (#169).
    let gate = StallGate()
    defer { gate.open() }
    let name = "question.example"
    let peer = try ScriptedDNSPeer(accepts: .dnsQuery(named: name), readsAfter: gate) { query in
      [(Shape.matching.datagram(query), 0)]
    }
    defer { peer.stop() }
    #expect(Strays.send(to: peer.port))
    try #require(await eventually(within: 10) { peer.queued >= 2 }, "queued: \(peer.queued)")
    gate.open()

    let (answers, _) = try await measure(within: Self.watchdog) {
      try await __dnsQuery(server: "127.0.0.1", port: peer.port, name: name, type: 1, timeout: 10)
    }
    #expect(!answers.isEmpty)
    #expect(peer.requests.value == 1)
    #expect(peer.ignored.value >= 2, "ignored: \(peer.ignored.value)")
  }

  // MARK: TXT lookups

  @Test(
    "Each first-question shape gets its verdict from the TXT lookup the whoami fallback makes",
    arguments: Shape.allCases)
  func txtLookup(shape: Shape) async throws {
    let peer = try ScriptedDNSPeer { query in [(shape.datagram(query), 0)] }
    defer { peer.stop() }
    let timeout = Self.timeout(shape)

    let (strings, elapsed) = try await measure(within: Self.watchdog) {
      await TestSeams.$dnsServerPort.withValue(peer.port) {
        await DNSClient.queryTXT(name: "question.example", timeout: timeout, servers: ["127.0.0.1"])
      }
    }
    switch shape.verdict {
    case .answered:
      #expect(strings == ["ok"])
    case .refused, .malformed:
      // Decided at once without strings; a reply ignored would have run to the watchdog.
      #expect(strings == nil)
    case .ignored:
      #expect(strings == nil)
      #expect(elapsed >= timeout * 0.95, "ended after \(elapsed)s")
    }
  }
}
