import XCTest
@_spi(Test) import SwiftFTR

final class SwiftFTRDNSTests: XCTestCase {
    func testParseSingleTXTAnswer() {
        // Build a minimal DNS response with one TXT answer: id=0x1234, QD=1, AN=1
        var msg = Data()
        func a16(_ v: UInt16) { var b = v.bigEndian; withUnsafeBytes(of: &b) { msg.append(contentsOf: $0) } }
        func a32(_ v: UInt32) { var b = v.bigEndian; withUnsafeBytes(of: &b) { msg.append(contentsOf: $0) } }

        a16(0x1234) // ID
        a16(0x8180) // Flags: standard response, no error
        a16(1)      // QDCOUNT
        a16(1)      // ANCOUNT
        a16(0)      // NSCOUNT
        a16(0)      // ARCOUNT

        // Question: name = AS15169.asn.cymru.com, TXT, IN
        let qname = __dnsEncodeQName("AS15169.asn.cymru.com")
        msg.append(contentsOf: qname)
        a16(16) // QTYPE TXT
        a16(1)  // QCLASS IN

        // Answer: name pointer to 0x0c (start of qname), TXT, IN, TTL, RDLENGTH, RDATA
        // Name pointer: 0xC0 0x0C
        msg.append(0xC0); msg.append(0x0C)
        a16(16) // type TXT
        a16(1)  // class IN
        a32(60) // ttl
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
}
