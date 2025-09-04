import Foundation

@inline(__always)
func inetChecksum(_ data: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    var i = 0
    while i + 1 < data.count {
        let word = (UInt16(data[i]) << 8) | UInt16(data[i+1])
        sum &+= UInt32(word)
        i += 2
    }
    if i < data.count {
        sum &+= UInt32(UInt16(data[i]) << 8)
    }
    while (sum >> 16) != 0 { sum = (sum & 0xFFFF) &+ (sum >> 16) }
    return ~UInt16(sum & 0xFFFF)
}

func echoReply(id: UInt16, seq: UInt16, payloadLen: Int) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: 8 + max(0, payloadLen))
    p[0] = 0     // type: echo reply
    p[1] = 0     // code
    p[2] = 0; p[3] = 0
    p[4] = UInt8(id >> 8); p[5] = UInt8(id & 0xFF)
    p[6] = UInt8(seq >> 8); p[7] = UInt8(seq & 0xFF)
    for i in 0..<payloadLen { p[8+i] = UInt8(97 + (i % 26)) }
    let cks = inetChecksum(p)
    p[2] = UInt8(cks >> 8); p[3] = UInt8(cks & 0xFF)
    return p
}

func timeExceededWithEmbeddedEcho(id: UInt16, seq: UInt16) -> [UInt8] {
    // Outer ICMP header (type 11), then embed IPv4 header + 8 bytes of original ICMP echo request
    var inner = [UInt8](repeating: 0, count: 8)
    inner[0] = 8; inner[1] = 0; inner[2] = 0; inner[3] = 0
    inner[4] = UInt8(id >> 8); inner[5] = UInt8(id & 0xFF)
    inner[6] = UInt8(seq >> 8); inner[7] = UInt8(seq & 0xFF)
    let innerCks = inetChecksum(inner)
    inner[2] = UInt8(innerCks >> 8); inner[3] = UInt8(innerCks & 0xFF)

    // Minimal IPv4 header: version=4, ihl=5, proto=1 (ICMP)
    var ip = [UInt8](repeating: 0, count: 20)
    ip[0] = 0x45
    ip[2] = 0; ip[3] = 28 // total length 28
    ip[8] = 64            // TTL 64
    ip[9] = 1             // protocol ICMP
    ip[12] = 1; ip[13] = 2; ip[14] = 3; ip[15] = 4 // src
    ip[16] = 5; ip[17] = 6; ip[18] = 7; ip[19] = 8 // dst

    var outer = [UInt8](repeating: 0, count: 8)
    outer[0] = 11; outer[1] = 0
    outer[2] = 0; outer[3] = 0
    outer += ip
    outer += inner
    let cks = inetChecksum(outer)
    outer[2] = UInt8(cks >> 8); outer[3] = UInt8(cks & 0xFF)
    return outer
}

func destUnreachWithEmbeddedEcho(id: UInt16, seq: UInt16) -> [UInt8] {
    var inner = [UInt8](repeating: 0, count: 8)
    inner[0] = 8; inner[1] = 0; inner[2] = 0; inner[3] = 0
    inner[4] = UInt8(id >> 8); inner[5] = UInt8(id & 0xFF)
    inner[6] = UInt8(seq >> 8); inner[7] = UInt8(seq & 0xFF)
    let innerCks = inetChecksum(inner)
    inner[2] = UInt8(innerCks >> 8); inner[3] = UInt8(innerCks & 0xFF)

    var ip = [UInt8](repeating: 0, count: 20)
    ip[0] = 0x45
    ip[2] = 0; ip[3] = 28
    ip[8] = 64
    ip[9] = 1
    ip[12] = 9; ip[13] = 9; ip[14] = 9; ip[15] = 9
    ip[16] = 7; ip[17] = 7; ip[18] = 7; ip[19] = 7

    var outer = [UInt8](repeating: 0, count: 8)
    outer[0] = 3; outer[1] = 1 // host unreachable
    outer[2] = 0; outer[3] = 0
    outer += ip
    outer += inner
    let cks = inetChecksum(outer)
    outer[2] = UInt8(cks >> 8); outer[3] = UInt8(cks & 0xFF)
    return outer
}

@main
struct GenSeeds {
    static func main() throws {
        let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "FuzzCorpus/icmp"
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        func write(_ name: String, _ data: [UInt8]) throws {
            let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
            try Data(data).write(to: url)
        }

        try write("echo-reply.bin", echoReply(id: 0xBEEF, seq: 1, payloadLen: 32))
        try write("time-exceeded-embed-echo.bin", timeExceededWithEmbeddedEcho(id: 0x1234, seq: 0x5678))
        try write("dest-unreach-embed-echo.bin", destUnreachWithEmbeddedEcho(id: 0x9999, seq: 0x0001))
        try write("truncated-4bytes.bin", [0x0B, 0x00, 0x00, 0x00])
        try write("random-ascii.bin", Array("hello icmp!".utf8))
        print("Seeds written to \(outDir)")
    }
}

