import Foundation
@_spi(Test) import SwiftFTR

struct TestFailure: Error, CustomStringConvertible { let description: String }

@discardableResult
func assert(_ cond: @autoclosure () -> Bool, _ msg: String) throws -> Bool {
    if !cond() { throw TestFailure(description: msg) }
    return true
}

func inetChecksum(_ data: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    var i = 0
    while i + 1 < data.count {
        let word = (UInt16(data[i]) << 8) | UInt16(data[i+1])
        sum &+= UInt32(word)
        i += 2
    }
    if i < data.count { sum &+= UInt32(UInt16(data[i]) << 8) }
    while (sum >> 16) != 0 { sum = (sum & 0xFFFF) &+ (sum >> 16) }
    return ~UInt16(sum & 0xFFFF)
}

func makeEchoReply(id: UInt16, seq: UInt16, payloadLen: Int) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: 8 + max(0, payloadLen))
    p[0] = 0; p[1] = 0
    p[2] = 0; p[3] = 0
    p[4] = UInt8(id >> 8); p[5] = UInt8(id & 0xFF)
    p[6] = UInt8(seq >> 8); p[7] = UInt8(seq & 0xFF)
    let c = inetChecksum(p); p[2] = UInt8(c >> 8); p[3] = UInt8(c & 0xFF)
    return p
}

func makeTimeExceededEmbedEcho(id: UInt16, seq: UInt16) -> [UInt8] {
    var inner = [UInt8](repeating: 0, count: 8)
    inner[0] = 8; inner[1] = 0; inner[2] = 0; inner[3] = 0
    inner[4] = UInt8(id >> 8); inner[5] = UInt8(id & 0xFF)
    inner[6] = UInt8(seq >> 8); inner[7] = UInt8(seq & 0xFF)
    let ic = inetChecksum(inner); inner[2] = UInt8(ic >> 8); inner[3] = UInt8(ic & 0xFF)
    var ip = [UInt8](repeating: 0, count: 20)
    ip[0] = 0x45; ip[9] = 1
    var outer = [UInt8](repeating: 0, count: 8)
    outer[0] = 11
    outer += ip
    outer += inner
    let oc = inetChecksum(outer); outer[2] = UInt8(oc >> 8); outer[3] = UInt8(oc & 0xFF)
    return outer
}

func testICMPParsing() throws {
    var ss = sockaddr_storage()
    var sin = sockaddr_in()
    sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    sin.sin_family = sa_family_t(AF_INET)
    sin.sin_addr = in_addr(s_addr: UInt32(0x01020304).bigEndian)
    _ = withUnsafePointer(to: &sin) { sp in memcpy(&ss, sp, MemoryLayout<sockaddr_in>.size) }

    let id: UInt16 = 0xBEEF
    let seq: UInt16 = 0x0102
    let pkt = makeEchoReply(id: id, seq: seq, payloadLen: 16)
    pkt.withUnsafeBytes { raw in
        if let parsed = __parseICMPMessage(buffer: raw, from: ss) {
            switch parsed.kind {
            case .echoReply(let pid, let pseq):
                precondition(pid == id && pseq == seq)
            default:
                fatalError("expected echoReply")
            }
        } else { fatalError("parse failed") }
    }

    let te = makeTimeExceededEmbedEcho(id: id, seq: seq)
    te.withUnsafeBytes { raw in
        if let parsed = __parseICMPMessage(buffer: raw, from: ss) {
            switch parsed.kind {
            case .timeExceeded(let oid, let oseq):
                precondition(oid == id && oseq == seq)
            default:
                fatalError("expected timeExceeded")
            }
        } else { fatalError("parse failed") }
    }
}

struct StubResolver: ASNResolver {
    let map: [String: ASNInfo]
    func resolve(ipv4Addrs: [String], timeout: TimeInterval) throws -> [String : ASNInfo] {
        var out: [String:ASNInfo] = [:]
        for ip in ipv4Addrs { if let v = map[ip] { out[ip] = v } }
        return out
    }
}

func testClassification() throws {
    // Build synthetic trace with gaps and mix of IPs
    let hops: [TraceHop] = [
        .init(ttl: 1, host: "192.168.1.1", rtt: 0.001, reachedDestination: false), // LOCAL
        .init(ttl: 2, host: "100.64.1.2", rtt: 0.005, reachedDestination: false),  // CGNAT -> ISP
        .init(ttl: 3, host: nil, rtt: nil, reachedDestination: false),              // gap
        .init(ttl: 4, host: nil, rtt: nil, reachedDestination: false),              // gap
        .init(ttl: 5, host: "9.9.9.9", rtt: 0.010, reachedDestination: false),     // ISP (AS12345)
        .init(ttl: 6, host: "203.0.113.1", rtt: 0.020, reachedDestination: false), // no ASN -> TRANSIT
        .init(ttl: 7, host: "5.5.5.4", rtt: 0.030, reachedDestination: false),     // DEST ASN (AS555)
        .init(ttl: 8, host: "5.5.5.5", rtt: 0.040, reachedDestination: true),      // destination
    ]
    let tr = TraceResult(destination: "example.com", maxHops: 30, reached: true, hops: hops)
    let destIP = "5.5.5.5"
    let stub = StubResolver(map: [
        "9.9.9.9": ASNInfo(asn: 12345, name: "ISP-AS"),
        "5.5.5.4": ASNInfo(asn: 555, name: "DEST-AS"),
        "5.5.5.5": ASNInfo(asn: 555, name: "DEST-AS"),
        "203.0.113.45": ASNInfo(asn: 12345, name: "ISP-AS") // public IP override ASN
    ])
    setenv("PTR_SKIP_STUN", "1", 1)
    setenv("PTR_PUBLIC_IP", "203.0.113.45", 1)
    defer { unsetenv("PTR_SKIP_STUN"); unsetenv("PTR_PUBLIC_IP") }
    let cls = try TraceClassifier().classify(trace: tr, destinationIP: destIP, resolver: stub, timeout: 0.2)
    // Expectations
    try assert(cls.hops[0].category == HopCategory.local, "TTL1 should be LOCAL")
    try assert(cls.hops[1].category == HopCategory.isp, "TTL2 CGNAT should be ISP")
    try assert(cls.hops[2].category == HopCategory.isp && cls.hops[3].category == HopCategory.isp, "Gaps 3-4 sandwiched should be ISP")
    // ASN may be unknown if only one side reports; category suffices
    try assert(cls.hops[5].category == HopCategory.transit, "No ASN public IP should be TRANSIT")
    try assert(cls.hops[6].category == HopCategory.destination, "TTL7 same ASN as destination should be DESTINATION")
}

@main
struct Runner {
    static func main() {
        var passed = 0
        var failed = 0
        func run(_ name: String, _ f: () throws -> Void) {
            do { try f(); print("[PASS]", name); passed += 1 } catch { print("[FAIL]", name, "-", error); failed += 1 }
        }
        run("ICMP parsing", testICMPParsing)
        run("Classification", testClassification)
        print("Summary: passed=\(passed) failed=\(failed)")
        if failed > 0 { exit(1) }
    }
}
