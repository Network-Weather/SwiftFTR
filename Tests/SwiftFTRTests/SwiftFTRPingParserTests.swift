@_spi(Test) import SwiftFTR
import XCTest

/// Unit tests for the wire-format parsing in Ping.swift.
///
/// These exercise the parts of the ICMP echo-reply parser that are
/// reachable without real network I/O, so they can run on any machine
/// regardless of network policy.
final class SwiftFTRPingParserTests: XCTestCase {

  // MARK: - TTL extraction

  /// Regression test for the TTL-offset bug fixed alongside the false-loss
  /// fix: previously the parser read `bytes[icmpOffset + 8]` which lands in
  /// the synthetic ICMP payload ('a' = 0x61 = 97) instead of byte 8 of the
  /// IP header where the IPv4 TTL field actually lives (RFC 791 §3.1).
  func testEchoReplyTTLFromIPHeader() {
    let identifier: UInt16 = 0xABCD
    let sequence: UInt16 = 0x0007
    let expectedTTL: UInt8 = 57  // typical Cloudflare/Google anycast TTL

    // Construct a 20-byte IPv4 header + 8-byte ICMP echo reply + 16-byte payload.
    var pkt = [UInt8](repeating: 0, count: 20 + 8 + 16)
    pkt[0] = 0x45  // version=4, IHL=5 (20 bytes)
    pkt[8] = expectedTTL  // TTL — the field under test
    pkt[9] = 0x01  // protocol = ICMP

    let icmp = 20
    pkt[icmp + 0] = 0  // type = echo reply
    pkt[icmp + 1] = 0  // code
    // checksum (icmp+2..icmp+3) left zero — parser does not validate it
    pkt[icmp + 4] = UInt8(identifier >> 8)
    pkt[icmp + 5] = UInt8(identifier & 0xFF)
    pkt[icmp + 6] = UInt8(sequence >> 8)
    pkt[icmp + 7] = UInt8(sequence & 0xFF)
    // Synthetic 'abcdefghij...' payload starting at icmp+8; this is the same
    // pattern the sender uses and is what the buggy code was returning as TTL.
    for i in 0..<16 { pkt[icmp + 8 + i] = 0x61 + UInt8(i % 26) }

    let parsed = pkt.withUnsafeBytes { raw -> TestParsedPingMessage? in
      __parsePingMessage(buffer: raw, expectedIdentifier: identifier)
    }

    guard let parsed = parsed else {
      XCTFail("parser returned nil")
      return
    }
    switch parsed {
    case .echoReply(let seq, let ttl):
      XCTAssertEqual(seq, sequence)
      XCTAssertEqual(
        ttl, Int(expectedTTL),
        "TTL should be read from IP header byte 8, not from the ICMP payload")
    default:
      XCTFail("expected echoReply, got \(parsed)")
    }
  }

  /// When the kernel hands us an ICMP datagram with no outer IP header
  /// (the typical Darwin SOCK_DGRAM ICMP path), TTL is genuinely
  /// unrecoverable from the buffer. Parser should return nil for TTL
  /// rather than reading garbage from the payload.
  func testEchoReplyTTLIsNilWhenNoIPHeader() {
    let identifier: UInt16 = 0x4242
    let sequence: UInt16 = 0x0001

    // 8-byte ICMP echo reply + small payload. No outer IP header.
    var pkt = [UInt8](repeating: 0, count: 8 + 8)
    pkt[0] = 0  // type = echo reply
    pkt[4] = UInt8(identifier >> 8)
    pkt[5] = UInt8(identifier & 0xFF)
    pkt[6] = UInt8(sequence >> 8)
    pkt[7] = UInt8(sequence & 0xFF)
    for i in 0..<8 { pkt[8 + i] = 0x61 + UInt8(i) }

    let parsed = pkt.withUnsafeBytes { raw -> TestParsedPingMessage? in
      __parsePingMessage(buffer: raw, expectedIdentifier: identifier)
    }

    guard let parsed = parsed else {
      XCTFail("parser returned nil")
      return
    }
    switch parsed {
    case .echoReply(let seq, let ttl):
      XCTAssertEqual(seq, sequence)
      XCTAssertNil(ttl, "TTL must be nil when no IP header is present in the buffer")
    default:
      XCTFail("expected echoReply, got \(parsed)")
    }
  }

  /// Identifier mismatch must be filtered out — replies from other ping
  /// sessions on the host should not appear in our results.
  func testEchoReplyIdentifierMismatchRejected() {
    var pkt = [UInt8](repeating: 0, count: 8)
    pkt[0] = 0
    pkt[4] = 0xDE
    pkt[5] = 0xAD  // identifier 0xDEAD
    pkt[6] = 0x00
    pkt[7] = 0x01

    let parsed = pkt.withUnsafeBytes { raw -> TestParsedPingMessage? in
      __parsePingMessage(buffer: raw, expectedIdentifier: 0xBEEF)
    }
    XCTAssertNil(parsed, "reply with wrong identifier must be filtered")
  }

  // MARK: - ICMPv6 (RFC 4443) parser

  /// ICMPv6 Echo Reply: kernel strips the IPv6 header on SOCK_DGRAM IPPROTO_ICMPV6,
  /// so the buffer arrives starting with the ICMPv6 type byte. Hop limit is
  /// delivered out-of-band via cmsg and passed to the parser as `hopLimit:`.
  func testV6EchoReplyParsesIdentifierSequenceAndHopLimit() {
    let identifier: UInt16 = 0xABCD
    let sequence: UInt16 = 0x002A
    let hopLimit = 57

    // 8-byte ICMPv6 echo reply + 8-byte payload (no IPv6 header — kernel-stripped).
    var pkt = [UInt8](repeating: 0, count: 8 + 8)
    pkt[0] = 129  // ICMPv6 EchoReply
    pkt[1] = 0  // code
    pkt[4] = UInt8(identifier >> 8)
    pkt[5] = UInt8(identifier & 0xFF)
    pkt[6] = UInt8(sequence >> 8)
    pkt[7] = UInt8(sequence & 0xFF)
    for i in 0..<8 { pkt[8 + i] = 0x61 + UInt8(i) }

    let parsed = pkt.withUnsafeBytes { raw -> TestParsedPingMessage? in
      __parseV6PingMessage(
        buffer: raw, hopLimit: hopLimit, expectedIdentifier: identifier)
    }
    guard let parsed = parsed else {
      XCTFail("parser returned nil")
      return
    }
    switch parsed {
    case .echoReply(let seq, let ttl):
      XCTAssertEqual(seq, sequence)
      XCTAssertEqual(ttl, hopLimit, "hop limit must be the cmsg value, not parsed from buffer")
    default:
      XCTFail("expected echoReply, got \(parsed)")
    }
  }

  /// Hop limit cmsg may be absent (e.g. `IPV6_RECVHOPLIMIT` setsockopt failed).
  /// In that case `ttl` is nil — same semantics as v4 with no IP header.
  func testV6EchoReplyNilHopLimitWhenAbsent() {
    let identifier: UInt16 = 0x1234
    let sequence: UInt16 = 0x0001
    var pkt = [UInt8](repeating: 0, count: 8)
    pkt[0] = 129
    pkt[4] = 0x12
    pkt[5] = 0x34
    pkt[6] = 0x00
    pkt[7] = 0x01

    let parsed = pkt.withUnsafeBytes { raw -> TestParsedPingMessage? in
      __parseV6PingMessage(buffer: raw, hopLimit: nil, expectedIdentifier: identifier)
    }
    guard let parsed = parsed else {
      XCTFail("parser returned nil")
      return
    }
    switch parsed {
    case .echoReply(let seq, let ttl):
      XCTAssertEqual(seq, sequence)
      XCTAssertNil(ttl)
    default:
      XCTFail("expected echoReply, got \(parsed)")
    }
  }

  /// ICMPv6 identifier mismatch — filter out replies that don't belong to this socket.
  func testV6EchoReplyIdentifierMismatchRejected() {
    var pkt = [UInt8](repeating: 0, count: 8)
    pkt[0] = 129
    pkt[4] = 0xDE
    pkt[5] = 0xAD
    pkt[6] = 0x00
    pkt[7] = 0x01

    let parsed = pkt.withUnsafeBytes { raw -> TestParsedPingMessage? in
      __parseV6PingMessage(buffer: raw, hopLimit: 64, expectedIdentifier: 0xBEEF)
    }
    XCTAssertNil(parsed, "reply with wrong identifier must be filtered")
  }

  /// ICMPv6 Time Exceeded with embedded IPv6 + Echo Request — verifies the parser
  /// walks past the fixed 40-byte v6 header (no IHL field, unlike v4) and recovers
  /// the original identifier+sequence so traceroute v6 (future stage) can correlate.
  func testV6TimeExceededRecoversOriginalIdentifierAndSequence() {
    let originalID: UInt16 = 0xCAFE
    let originalSeq: UInt16 = 0x000F

    // Outer ICMPv6 TimeExceeded (8 bytes) + embedded IPv6 (40 bytes) + embedded
    // ICMPv6 EchoRequest (8 bytes).
    var pkt = [UInt8](repeating: 0, count: 8 + 40 + 8)
    pkt[0] = 3  // ICMPv6 TimeExceeded
    pkt[1] = 0  // code = hop limit exceeded in transit

    // Embedded IPv6 header at offset 8: version=6 in top nibble of byte 0.
    pkt[8] = 0x60  // version=6, no traffic class
    pkt[8 + 6] = 58  // next header = ICMPv6
    // Source and destination addresses (bytes 8+8..8+39) left zero — parser doesn't inspect.

    // Embedded ICMPv6 EchoRequest at offset 8 + 40 = 48.
    let inner = 48
    pkt[inner + 0] = 128  // EchoRequest
    pkt[inner + 4] = UInt8(originalID >> 8)
    pkt[inner + 5] = UInt8(originalID & 0xFF)
    pkt[inner + 6] = UInt8(originalSeq >> 8)
    pkt[inner + 7] = UInt8(originalSeq & 0xFF)

    let parsed = pkt.withUnsafeBytes { raw -> TestParsedPingMessage? in
      __parseV6PingMessage(buffer: raw, hopLimit: 0, expectedIdentifier: originalID)
    }
    guard let parsed = parsed else {
      XCTFail("parser returned nil")
      return
    }
    switch parsed {
    case .timeExceeded(let seq, _, let code):
      XCTAssertEqual(seq, originalSeq)
      XCTAssertEqual(code, 0)
    default:
      XCTFail("expected timeExceeded, got \(parsed)")
    }
  }
}
