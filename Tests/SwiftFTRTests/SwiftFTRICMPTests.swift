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
        iphdr[0] = 0x45 // v4, ihl=5
        iphdr[9] = 1    // protocol ICMP
        // Embedded original ICMP Echo Request (8 bytes)
        var inner = [UInt8](repeating: 0, count: 8)
        inner[0] = 8 // echo request
        inner[4] = 0xBE; inner[5] = 0xEF // id
        inner[6] = 0x00; inner[7] = 0x03 // seq
        pkt.append(contentsOf: iphdr)
        pkt.append(contentsOf: inner)

        var ss = sockaddr_storage()
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_addr = in_addr(s_addr: 0x08080808)
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
        var iphdr = [UInt8](repeating: 0, count: 20); iphdr[0] = 0x45; iphdr[9] = 1
        var inner = [UInt8](repeating: 0, count: 8)
        inner[0] = 8 // echo request
        inner[4] = 0x12; inner[5] = 0x34
        inner[6] = 0x56; inner[7] = 0x78
        pkt.append(contentsOf: iphdr)
        pkt.append(contentsOf: inner)

        var ss = sockaddr_storage()
        var sin = sockaddr_in(); sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); sin.sin_family = sa_family_t(AF_INET); sin.sin_addr = in_addr(s_addr: 0x7F000001)
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
}
