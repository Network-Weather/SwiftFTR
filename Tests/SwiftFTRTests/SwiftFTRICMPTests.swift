@_spi(Test) import SwiftFTR
import XCTest

final class SwiftFTRICMPTests: XCTestCase {
  func testParseEchoReply() {
    // Build a minimal ICMP echo reply: type=0, code=0, checksum dummy, id=0x1234, seq=0x0102
    var pkt = [UInt8](repeating: 0, count: 8)
    pkt[0] = 0  // echo reply
    pkt[1] = 0  // code
    pkt[2] = 0
    pkt[3] = 0  // checksum zero for test; parser does not validate checksum
    pkt[4] = 0x12
    pkt[5] = 0x34
    pkt[6] = 0x01
    pkt[7] = 0x02

    var ss = sockaddr_storage()
    var sin = sockaddr_in()
    sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    sin.sin_family = sa_family_t(AF_INET)
    sin.sin_addr = in_addr(s_addr: 0x0102_0304)
    _ = withUnsafePointer(to: &sin) { sp in
      memcpy(&ss, sp, MemoryLayout<sockaddr_in>.size)
    }

    let ok = pkt.withUnsafeBytes { raw -> Bool in
      guard let parsed = __parseICMPMessage(buffer: raw, from: ss) else { return false }
      switch parsed.kind {
      case .echoReply(let id, let seq):
        return id == 0x1234 && seq == 0x0102
      default:
        return false
      }
    }
    XCTAssertTrue(ok)
  }

  func testParseTimeExceededWithEmbeddedEcho() {
    // Outer ICMP: Time Exceeded (11), code 0, 8-byte header
    var pkt: [UInt8] = [0x0B, 0x00, 0x00, 0x00, 0, 0, 0, 0]
    // Embedded IPv4 header (minimal 20 bytes, IHL=5)
    var iphdr = [UInt8](repeating: 0, count: 20)
    iphdr[0] = 0x45  // v4, ihl=5
    iphdr[9] = 1  // protocol ICMP
    // Embedded original ICMP Echo Request (8 bytes)
    var inner = [UInt8](repeating: 0, count: 8)
    inner[0] = 8  // echo request
    inner[4] = 0xBE
    inner[5] = 0xEF  // id
    inner[6] = 0x00
    inner[7] = 0x03  // seq
    pkt.append(contentsOf: iphdr)
    pkt.append(contentsOf: inner)

    var ss = sockaddr_storage()
    var sin = sockaddr_in()
    sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    sin.sin_family = sa_family_t(AF_INET)
    sin.sin_addr = in_addr(s_addr: 0x0808_0808)
    _ = withUnsafePointer(to: &sin) { sp in memcpy(&ss, sp, MemoryLayout<sockaddr_in>.size) }

    let ok = pkt.withUnsafeBytes { raw -> Bool in
      guard let parsed = __parseICMPMessage(buffer: raw, from: ss) else { return false }
      switch parsed.kind {
      case .timeExceeded(let id, let seq):
        return id == 0xBEEF && seq == 0x0003
      default:
        return false
      }
    }
    XCTAssertTrue(ok)
  }

  func testParseDestUnreachableWithEmbeddedEcho() {
    // Outer ICMP: Destination Unreachable (3)
    var pkt: [UInt8] = [0x03, 0x01, 0x00, 0x00, 0, 0, 0, 0]
    var iphdr = [UInt8](repeating: 0, count: 20)
    iphdr[0] = 0x45
    iphdr[9] = 1
    var inner = [UInt8](repeating: 0, count: 8)
    inner[0] = 8  // echo request
    inner[4] = 0x12
    inner[5] = 0x34
    inner[6] = 0x56
    inner[7] = 0x78
    pkt.append(contentsOf: iphdr)
    pkt.append(contentsOf: inner)

    var ss = sockaddr_storage()
    var sin = sockaddr_in()
    sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    sin.sin_family = sa_family_t(AF_INET)
    sin.sin_addr = in_addr(s_addr: 0x7F00_0001)
    _ = withUnsafePointer(to: &sin) { sp in memcpy(&ss, sp, MemoryLayout<sockaddr_in>.size) }

    let ok = pkt.withUnsafeBytes { raw -> Bool in
      guard let parsed = __parseICMPMessage(buffer: raw, from: ss) else { return false }
      switch parsed.kind {
      case .destinationUnreachable(let id, let seq):
        return id == 0x1234 && seq == 0x5678
      default:
        return false
      }
    }
    XCTAssertTrue(ok)
  }

  func testParseV4ErrorDoesNotCorrelateMalformedQuotedPacket() {
    var packet: [UInt8] = [0x0B, 0x00, 0x00, 0x00, 0, 0, 0, 0]
    var ipHeader = [UInt8](repeating: 0, count: 20)
    ipHeader[0] = 0x45
    ipHeader[9] = 1
    var inner = [UInt8](repeating: 0, count: 8)
    inner[0] = 8
    inner[4] = 0xBE
    inner[5] = 0xEF
    inner[7] = 3
    packet.append(contentsOf: ipHeader)
    packet.append(contentsOf: inner)

    var source = sockaddr_storage()
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    _ = withUnsafePointer(to: &address) { pointer in
      memcpy(&source, pointer, MemoryLayout<sockaddr_in>.size)
    }

    let corruptions: [(offset: Int, value: UInt8)] = [
      (8, 0x44),  // Invalid embedded IHL.
      (8 + 9, 17),  // Embedded protocol is UDP.
      (8 + 20, 0),  // Embedded ICMP is an Echo Reply.
      (8 + 20 + 1, 1),  // Embedded Echo Request has a nonzero code.
    ]
    for corruption in corruptions {
      var malformed = packet
      malformed[corruption.offset] = corruption.value
      let parsed = malformed.withUnsafeBytes { raw in
        __parseICMPMessage(buffer: raw, from: source)
      }
      guard case .some(.timeExceeded(let id, let sequence)) = parsed?.kind else {
        XCTFail("expected an uncorrelated Time Exceeded result")
        continue
      }
      XCTAssertNil(id)
      XCTAssertNil(sequence)
    }
  }

  func testParseV6ErrorDoesNotCorrelateNonICMPv6Quote() {
    var packet = [UInt8](repeating: 0, count: 8 + 40 + 8)
    packet[0] = 3
    packet[8] = 0x60
    packet[8 + 6] = 58  // Embedded next header is ICMPv6.
    let innerICMP = 8 + 40
    packet[innerICMP] = 128
    packet[innerICMP + 4] = 0xBE
    packet[innerICMP + 5] = 0xEF

    var source = sockaddr_storage()
    var address = sockaddr_in6()
    address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    address.sin6_family = sa_family_t(AF_INET6)
    _ = withUnsafePointer(to: &address) { pointer in
      memcpy(&source, pointer, MemoryLayout<sockaddr_in6>.size)
    }

    let valid = packet.withUnsafeBytes { raw in
      __parseICMPv6Message(buffer: raw, hopLimit: 64, from: source)
    }
    guard case .some(.timeExceeded(let validID, _)) = valid?.kind else {
      XCTFail("expected a correlated Time Exceeded result")
      return
    }
    XCTAssertEqual(validID, 0xBEEF)

    var malformed = packet
    malformed[8 + 6] = 17  // Embedded next header is UDP.
    let parsed = malformed.withUnsafeBytes { raw in
      __parseICMPv6Message(buffer: raw, hopLimit: 64, from: source)
    }
    guard case .some(.timeExceeded(let id, let sequence)) = parsed?.kind else {
      XCTFail("expected an uncorrelated Time Exceeded result")
      return
    }
    XCTAssertNil(id)
    XCTAssertNil(sequence)
  }
}
