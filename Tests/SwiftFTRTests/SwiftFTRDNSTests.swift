@_spi(Test) import SwiftFTR
import XCTest

final class SwiftFTRDNSTests: XCTestCase {
  func testParseSingleTXTAnswer() {
    // Build a minimal DNS response with one TXT answer: id=0x1234, QD=1, AN=1
    var msg = Data()
    func a16(_ v: UInt16) {
      var b = v.bigEndian
      withUnsafeBytes(of: &b) { msg.append(contentsOf: $0) }
    }
    func a32(_ v: UInt32) {
      var b = v.bigEndian
      withUnsafeBytes(of: &b) { msg.append(contentsOf: $0) }
    }

    a16(0x1234)  // ID
    a16(0x8180)  // Flags: standard response, no error
    a16(1)  // QDCOUNT
    a16(1)  // ANCOUNT
    a16(0)  // NSCOUNT
    a16(0)  // ARCOUNT

    // Question: name = AS15169.asn.cymru.com, TXT, IN
    let qname = __dnsEncodeQName("AS15169.asn.cymru.com")
    msg.append(contentsOf: qname)
    a16(16)  // QTYPE TXT
    a16(1)  // QCLASS IN

    // Answer: name pointer to 0x0c (start of qname), TXT, IN, TTL, RDLENGTH, RDATA
    // Name pointer: 0xC0 0x0C
    msg.append(0xC0)
    msg.append(0x0C)
    a16(16)  // type TXT
    a16(1)  // class IN
    a32(60)  // ttl
    // RDATA: one character-string with length+data
    let payload = "AS15169 | GOOGLE, US | US | arin"
    var rdata = Data()
    let bytes = Array(payload.utf8)
    rdata.append(UInt8(bytes.count))
    rdata.append(contentsOf: bytes)
    a16(UInt16(rdata.count))
    msg.append(contentsOf: rdata)

    guard let answers = __dnsParseTXTAnswers(message: msg) else {
      return XCTFail("Failed to parse DNS TXT answers")
    }
    XCTAssertEqual(answers.count, 1)
    let first = answers[0]
    XCTAssertEqual(first.type, 16)
    XCTAssertEqual(first.klass, 1)
    XCTAssertFalse(first.rdata.isEmpty)
  }

  // MARK: - Parser Tests (0.7.1)

  func testParseA() {
    // Valid A record: 93.184.216.34
    let rdata = Data([93, 184, 216, 34])
    let result = __dnsParseA(rdata: rdata)
    XCTAssertEqual(result, "93.184.216.34")

    // Invalid length
    XCTAssertNil(__dnsParseA(rdata: Data([1, 2, 3])))
    XCTAssertNil(__dnsParseA(rdata: Data([1, 2, 3, 4, 5])))
  }

  func testParseAAAA() {
    // Full IPv6 address: 2607:f8b0:4004:0c07:0000:0000:0000:0064
    // Should compress to: 2607:f8b0:4004:c07::64
    let rdata1 = Data([
      0x26, 0x07, 0xf8, 0xb0,
      0x40, 0x04, 0x0c, 0x07,
      0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x64,
    ])
    let result1 = __dnsParseAAAA(rdata: rdata1)
    XCTAssertEqual(result1, "2607:f8b0:4004:c07::64")

    // Localhost: ::1
    let rdata2 = Data([
      0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x01,
    ])
    let result2 = __dnsParseAAAA(rdata: rdata2)
    XCTAssertEqual(result2, "::1")

    // All zeros: ::
    let rdata3 = Data([
      0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00,
    ])
    let result3 = __dnsParseAAAA(rdata: rdata3)
    XCTAssertEqual(result3, "::")

    // No compression (no consecutive zeros): 2001:db8:1:2:3:4:5:6
    let rdata4 = Data([
      0x20, 0x01, 0x0d, 0xb8,
      0x00, 0x01, 0x00, 0x02,
      0x00, 0x03, 0x00, 0x04,
      0x00, 0x05, 0x00, 0x06,
    ])
    let result4 = __dnsParseAAAA(rdata: rdata4)
    XCTAssertEqual(result4, "2001:db8:1:2:3:4:5:6")

    // Invalid length
    XCTAssertNil(__dnsParseAAAA(rdata: Data([1, 2, 3])))
  }

  func testParsePTR() {
    // Build a minimal DNS response with PTR record
    var msg = Data()
    func a16(_ v: UInt16) {
      var b = v.bigEndian
      withUnsafeBytes(of: &b) { msg.append(contentsOf: $0) }
    }
    func a32(_ v: UInt32) {
      var b = v.bigEndian
      withUnsafeBytes(of: &b) { msg.append(contentsOf: $0) }
    }

    // Header
    a16(0x5678)  // ID
    a16(0x8180)  // Flags
    a16(1)  // QDCOUNT
    a16(1)  // ANCOUNT
    a16(0)  // NSCOUNT
    a16(0)  // ARCOUNT

    // Question: 1.10.1.10.in-addr.arpa, PTR, IN
    let qname = __dnsEncodeQName("1.10.1.10.in-addr.arpa")
    msg.append(contentsOf: qname)
    a16(12)  // QTYPE PTR
    a16(1)  // QCLASS IN

    // Answer: name pointer, PTR, IN, TTL, RDLENGTH, RDATA
    msg.append(0xC0)  // Name compression pointer
    msg.append(0x0C)  // Points to offset 12 (start of qname)
    a16(12)  // type PTR
    a16(1)  // class IN
    a32(3600)  // ttl

    // RDATA: hostname "gateway.example.com" (with compression support)
    let hostname = __dnsEncodeQName("gateway.example.com")
    a16(UInt16(hostname.count))
    let rdataOffset = msg.count  // Track where RDATA starts
    msg.append(contentsOf: hostname)

    // Parse PTR from RDATA
    let rdataBytes = Data(hostname)
    let result = __dnsParsePTR(
      rdata: rdataBytes,
      rdataOffsetInMessage: rdataOffset,
      fullMessage: msg
    )
    XCTAssertEqual(result, "gateway.example.com")

    // Test with invalid offset
    let invalidResult = __dnsParsePTR(
      rdata: rdataBytes,
      rdataOffsetInMessage: 9999,
      fullMessage: msg
    )
    XCTAssertNil(invalidResult)
  }

  func testFormatReverseDNS() {
    // Valid IPv4 addresses
    XCTAssertEqual(__dnsFormatReverseDNS("10.1.10.1"), "1.10.1.10.in-addr.arpa")
    XCTAssertEqual(__dnsFormatReverseDNS("192.168.1.1"), "1.1.168.192.in-addr.arpa")
    XCTAssertEqual(__dnsFormatReverseDNS("8.8.8.8"), "8.8.8.8.in-addr.arpa")

    // Invalid formats
    XCTAssertNil(__dnsFormatReverseDNS("256.1.1.1"))  // Out of range
    XCTAssertNil(__dnsFormatReverseDNS("1.2.3"))  // Too few octets
    XCTAssertNil(__dnsFormatReverseDNS("1.2.3.4.5"))  // Too many octets
    XCTAssertNil(__dnsFormatReverseDNS("abc.def.ghi.jkl"))  // Not numbers
    XCTAssertNil(__dnsFormatReverseDNS(""))  // Empty
  }

  func testFormatReverseDNSIPv6() {
    // Google Public DNS IPv6: 2001:4860:4860::8888
    // Expanded: 2001:4860:4860:0000:0000:0000:0000:8888
    // Nibbles reversed: 8.8.8.8.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.6.8.4.0.6.8.4.1.0.0.2.ip6.arpa
    let result1 = __dnsFormatReverseDNS("2001:4860:4860::8888")
    XCTAssertEqual(
      result1,
      "8.8.8.8.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.6.8.4.0.6.8.4.1.0.0.2.ip6.arpa")

    // Localhost ::1
    let result2 = __dnsFormatReverseDNS("::1")
    XCTAssertEqual(
      result2,
      "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.ip6.arpa")

    // All zeros ::
    let result3 = __dnsFormatReverseDNS("::")
    XCTAssertEqual(
      result3,
      "0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.ip6.arpa")

    // Fully expanded address
    let result4 = __dnsFormatReverseDNS("2001:0db8:0001:0002:0003:0004:0005:0006")
    XCTAssertEqual(
      result4,
      "6.0.0.0.5.0.0.0.4.0.0.0.3.0.0.0.2.0.0.0.1.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa")

    // Invalid IPv6 strings
    XCTAssertNil(__dnsFormatReverseDNS("not-an-ip"))
    XCTAssertNil(__dnsFormatReverseDNS("gggg::1"))
  }

  func testDetectAddressFamily() {
    // IPv4
    XCTAssertEqual(__detectAddressFamily("8.8.8.8"), AF_INET)
    XCTAssertEqual(__detectAddressFamily("192.168.1.1"), AF_INET)
    XCTAssertEqual(__detectAddressFamily("0.0.0.0"), AF_INET)

    // IPv6
    XCTAssertEqual(__detectAddressFamily("::1"), AF_INET6)
    XCTAssertEqual(__detectAddressFamily("2001:4860:4860::8888"), AF_INET6)
    XCTAssertEqual(__detectAddressFamily("fe80::1"), AF_INET6)

    // IPv6 link-local with scope ID
    XCTAssertEqual(__detectAddressFamily("fe80::1%en0"), AF_INET6)
    XCTAssertEqual(__detectAddressFamily("fe80::28d5:b1ff:fe4d:3564%en0"), AF_INET6)

    // Invalid
    XCTAssertEqual(__detectAddressFamily("not-an-ip"), -1)
    XCTAssertEqual(__detectAddressFamily(""), -1)
    XCTAssertEqual(__detectAddressFamily("256.1.1.1"), -1)
  }

  func testParseIPv6Scoped() {
    // Global address without scope
    let r1 = __parseIPv6Scoped("2001:4860:4860::8888")
    XCTAssertEqual(r1.ip, "2001:4860:4860::8888")
    XCTAssertEqual(r1.scopeID, 0)

    // Link-local with interface name (scope ID depends on interface existence)
    let r2 = __parseIPv6Scoped("fe80::1%lo0")
    XCTAssertEqual(r2.ip, "fe80::1")
    // lo0 should always exist on macOS; its index is typically 1
    XCTAssertGreaterThan(r2.scopeID, 0)

    // Numeric zone ID
    let r3 = __parseIPv6Scoped("fe80::1%42")
    XCTAssertEqual(r3.ip, "fe80::1")
    XCTAssertEqual(r3.scopeID, 42)

    // Non-existent interface falls back to numeric parse (which fails -> 0)
    let r4 = __parseIPv6Scoped("fe80::1%nonexistent_iface")
    XCTAssertEqual(r4.ip, "fe80::1")
    XCTAssertEqual(r4.scopeID, 0)
  }

  // MARK: - New Parser Tests (0.8.0)

  func testParseTXT() {
    // Single string
    var rdata1 = Data()
    let str1 = "v=spf1 include:_spf.google.com ~all"
    rdata1.append(UInt8(str1.count))
    rdata1.append(contentsOf: str1.utf8)
    let result1 = __dnsParseTXT(rdata: rdata1)
    XCTAssertEqual(result1?.count, 1)
    XCTAssertEqual(result1?[0], str1)

    // Multiple strings
    var rdata2 = Data()
    let str2a = "first"
    let str2b = "second"
    rdata2.append(UInt8(str2a.count))
    rdata2.append(contentsOf: str2a.utf8)
    rdata2.append(UInt8(str2b.count))
    rdata2.append(contentsOf: str2b.utf8)
    let result2 = __dnsParseTXT(rdata: rdata2)
    XCTAssertEqual(result2?.count, 2)
    XCTAssertEqual(result2?[0], "first")
    XCTAssertEqual(result2?[1], "second")

    // Empty RDATA
    XCTAssertNil(__dnsParseTXT(rdata: Data()))

    // Invalid length
    let invalidRdata = Data([10, 1, 2])  // Claims 10 bytes but only has 2
    XCTAssertNil(__dnsParseTXT(rdata: invalidRdata))
  }

  func testParseMX() {
    // Build minimal DNS message with MX record
    var msg = Data()
    func a16msg(_ v: UInt16) {
      var b = v.bigEndian
      withUnsafeBytes(of: &b) { msg.append(contentsOf: $0) }
    }
    func a16rdata(_ v: UInt16, _ data: inout Data) {
      var b = v.bigEndian
      withUnsafeBytes(of: &b) { data.append(contentsOf: $0) }
    }

    // Header (minimal)
    a16msg(0x0000)  // ID
    a16msg(0x8180)  // Flags
    a16msg(0)  // QDCOUNT
    a16msg(0)  // ANCOUNT
    a16msg(0)  // NSCOUNT
    a16msg(0)  // ARCOUNT

    let headerSize = msg.count
    let rdataOffset = headerSize

    // MX RDATA: priority (2 bytes) + exchange hostname
    var rdata = Data()
    a16rdata(10, &rdata)  // Priority = 10
    let exchange = __dnsEncodeQName("smtp.google.com")
    rdata.append(contentsOf: exchange)

    msg.append(contentsOf: rdata)

    let result = __dnsParseMX(
      rdata: rdata,
      rdataOffsetInMessage: rdataOffset,
      fullMessage: msg
    )
    XCTAssertNotNil(result)
    XCTAssertEqual(result?.0, 10)  // Priority
    XCTAssertEqual(result?.1, "smtp.google.com")  // Exchange

    // Invalid: too short
    XCTAssertNil(__dnsParseMX(rdata: Data([0]), rdataOffsetInMessage: 0, fullMessage: Data()))
  }

  func testParseNS() {
    // Build minimal DNS message
    var msg = Data()
    let nameserver = __dnsEncodeQName("ns1.example.com")
    msg.append(contentsOf: nameserver)

    let result = __dnsParseNS(
      rdata: Data(nameserver),
      rdataOffsetInMessage: 0,
      fullMessage: msg
    )
    XCTAssertEqual(result, "ns1.example.com")
  }

  func testParseCNAME() {
    // Build minimal DNS message
    var msg = Data()
    let canonical = __dnsEncodeQName("www.example.com")
    msg.append(contentsOf: canonical)

    let result = __dnsParseCNAME(
      rdata: Data(canonical),
      rdataOffsetInMessage: 0,
      fullMessage: msg
    )
    XCTAssertEqual(result, "www.example.com")
  }

  func testParseSOA() {
    // Build minimal DNS message with SOA record
    var msg = Data()
    func a32(_ v: UInt32) {
      var b = v.bigEndian
      withUnsafeBytes(of: &b) { msg.append(contentsOf: $0) }
    }

    let primaryNS = __dnsEncodeQName("ns1.example.com")
    let adminEmail = __dnsEncodeQName("admin.example.com")

    msg.append(contentsOf: primaryNS)
    msg.append(contentsOf: adminEmail)
    a32(2_024_010_101)  // Serial
    a32(3600)  // Refresh
    a32(1800)  // Retry
    a32(604800)  // Expire
    a32(86400)  // Minimum TTL

    let result = __dnsParseSOA(
      rdata: msg,
      rdataOffsetInMessage: 0,
      fullMessage: msg
    )
    XCTAssertNotNil(result)
    XCTAssertEqual(result?.primaryNS, "ns1.example.com")
    XCTAssertEqual(result?.adminEmail, "admin.example.com")
    XCTAssertEqual(result?.serial, 2_024_010_101)
    XCTAssertEqual(result?.refresh, 3600)
    XCTAssertEqual(result?.retry, 1800)
    XCTAssertEqual(result?.expire, 604800)
    XCTAssertEqual(result?.minimumTTL, 86400)
  }

  func testParseSRV() {
    // Build minimal DNS message with SRV record
    var msg = Data()
    func a16rdata(_ v: UInt16, _ data: inout Data) {
      var b = v.bigEndian
      withUnsafeBytes(of: &b) { data.append(contentsOf: $0) }
    }

    let headerSize = 0
    let rdataOffset = headerSize

    var rdata = Data()
    a16rdata(10, &rdata)  // Priority
    a16rdata(20, &rdata)  // Weight
    a16rdata(5060, &rdata)  // Port (SIP)
    let target = __dnsEncodeQName("sipserver.example.com")
    rdata.append(contentsOf: target)

    msg.append(contentsOf: rdata)

    let result = __dnsParseSRV(
      rdata: rdata,
      rdataOffsetInMessage: rdataOffset,
      fullMessage: msg
    )
    XCTAssertNotNil(result)
    XCTAssertEqual(result?.priority, 10)
    XCTAssertEqual(result?.weight, 20)
    XCTAssertEqual(result?.port, 5060)
    XCTAssertEqual(result?.target, "sipserver.example.com")

    // Invalid: too short
    XCTAssertNil(
      __dnsParseSRV(rdata: Data([1, 2, 3]), rdataOffsetInMessage: 0, fullMessage: Data()))
  }

  func testParseCAA() {
    // Test issue tag
    var rdata1 = Data()
    rdata1.append(0)  // Flags
    let tag1 = "issue"
    rdata1.append(UInt8(tag1.count))
    rdata1.append(contentsOf: tag1.utf8)
    let value1 = "letsencrypt.org"
    rdata1.append(contentsOf: value1.utf8)

    let result1 = __dnsParseCAA(rdata: rdata1)
    XCTAssertNotNil(result1)
    XCTAssertEqual(result1?.flags, 0)
    XCTAssertEqual(result1?.tag, "issue")
    XCTAssertEqual(result1?.value, "letsencrypt.org")

    // Test issuewild tag
    var rdata2 = Data()
    rdata2.append(0)  // Flags
    let tag2 = "issuewild"
    rdata2.append(UInt8(tag2.count))
    rdata2.append(contentsOf: tag2.utf8)
    let value2 = ";"
    rdata2.append(contentsOf: value2.utf8)

    let result2 = __dnsParseCAA(rdata: rdata2)
    XCTAssertNotNil(result2)
    XCTAssertEqual(result2?.tag, "issuewild")
    XCTAssertEqual(result2?.value, ";")

    // Invalid: too short
    XCTAssertNil(__dnsParseCAA(rdata: Data([0])))

    // Invalid: empty tag
    XCTAssertNil(__dnsParseCAA(rdata: Data([0, 0])))
  }

  func testParseHTTPS() {
    // Build minimal DNS message with HTTPS record
    var msg = Data()
    func a16rdata(_ v: UInt16, _ data: inout Data) {
      var b = v.bigEndian
      withUnsafeBytes(of: &b) { data.append(contentsOf: $0) }
    }

    let headerSize = 0
    let rdataOffset = headerSize

    var rdata = Data()
    a16rdata(1, &rdata)  // Priority
    let target = __dnsEncodeQName(".")  // Alias mode (empty target)
    rdata.append(contentsOf: target)

    // Add some SvcParams (simplified - just raw bytes for testing)
    let svcParams = Data([0x00, 0x01, 0x00, 0x04, 0x68, 0x32, 0x68, 0x33])  // ALPN=h2,h3
    rdata.append(contentsOf: svcParams)

    msg.append(contentsOf: rdata)

    let result = __dnsParseHTTPS(
      rdata: rdata,
      rdataOffsetInMessage: rdataOffset,
      fullMessage: msg
    )
    XCTAssertNotNil(result)
    XCTAssertEqual(result?.priority, 1)
    XCTAssertEqual(result?.target, "")  // Empty target for alias mode
    XCTAssertEqual(result?.svcParams.count, svcParams.count)

    // Test with actual target
    var rdata2 = Data()
    a16rdata(2, &rdata2)  // Priority
    let target2 = __dnsEncodeQName("h3.example.com")
    rdata2.append(contentsOf: target2)

    var msg2 = Data()
    msg2.append(contentsOf: rdata2)

    let result2 = __dnsParseHTTPS(
      rdata: rdata2,
      rdataOffsetInMessage: 0,
      fullMessage: msg2
    )
    XCTAssertNotNil(result2)
    XCTAssertEqual(result2?.priority, 2)
    XCTAssertEqual(result2?.target, "h3.example.com")
  }

}
