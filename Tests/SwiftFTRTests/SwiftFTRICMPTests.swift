import XCTest
@_spi(Test) import SwiftFTR

final class SwiftFTRICMPTests: XCTestCase {
    func testParseEchoReply() {
        // Build a minimal ICMP echo reply: type=0, code=0, checksum dummy, id=0x1234, seq=0x0102
        var pkt = [UInt8](repeating: 0, count: 8)
        pkt[0] = 0 // echo reply
        pkt[1] = 0 // code
        pkt[2] = 0; pkt[3] = 0 // checksum zero for test; parser does not validate checksum
        pkt[4] = 0x12; pkt[5] = 0x34
        pkt[6] = 0x01; pkt[7] = 0x02

        var ss = sockaddr_storage()
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_addr = in_addr(s_addr: 0x01020304)
        withUnsafePointer(to: &sin) { sp in
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
}

