import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Fileprivate helper so tests can call an SPI wrapper without exposing the type.
fileprivate func _encodeQName(_ name: String) -> [UInt8] {
    var out: [UInt8] = []
    for label in name.trimmingCharacters(in: CharacterSet(charactersIn: ".")).split(separator: ".") {
        let lb = Array(label.utf8)
        guard lb.count < 64 else { continue }
        out.append(UInt8(lb.count))
        out.append(contentsOf: lb)
    }
    out.append(0) // terminator
    return out
}

struct DNSClient {
    struct Answer {
        let name: String
        let type: UInt16
        let klass: UInt16
        let ttl: UInt32
        let rdata: Data
    }

    static func queryTXT(name: String, timeout: TimeInterval = 1.0, servers: [String]? = nil) -> [String]? {
        let svrList = servers ?? dnsServersFromEnvOrDefault()
        for server in svrList {
            if let res = queryTXTOnce(name: name, timeout: timeout, server: server) {
                return res
            }
        }
        return nil
    }

    private static func dnsServersFromEnvOrDefault() -> [String] {
        if let env = ProcessInfo.processInfo.environment["PTR_DNS"], !env.isEmpty {
            return env.split(separator: ",").map { String($0) }
        }
        return ["1.1.1.1", "8.8.8.8"]
    }

    private static func queryTXTOnce(name: String, timeout: TimeInterval, server: String) -> [String]? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if fd < 0 { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: __darwin_suseconds_t((timeout - floor(timeout)) * 1_000_000))
        _ = withUnsafePointer(to: &tv) { p in setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, p, socklen_t(MemoryLayout<timeval>.size)) }
        _ = withUnsafePointer(to: &tv) { p in setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, p, socklen_t(MemoryLayout<timeval>.size)) }

        var dst = sockaddr_in()
        dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = in_port_t(53).bigEndian
        let ok = server.withCString { cs in inet_pton(AF_INET, cs, &dst.sin_addr) }
        if ok != 1 { return nil }

        var msg = Data()
        let id = UInt16.random(in: 0...UInt16.max)
        func append16(_ v: UInt16) { var b = v.bigEndian; withUnsafeBytes(of: &b) { msg.append(contentsOf: $0) } }
        func append32(_ v: UInt32) { var b = v.bigEndian; withUnsafeBytes(of: &b) { msg.append(contentsOf: $0) } }

        // Header
        append16(id)               // ID
        append16(0x0100)           // RD
        append16(1)                // QDCOUNT
        append16(0)                // ANCOUNT
        append16(0)                // NSCOUNT
        append16(0)                // ARCOUNT

        // Question
        msg.append(contentsOf: _encodeQName(name))
        append16(16)               // QTYPE TXT
        append16(1)                // QCLASS IN

        let sent: ssize_t = msg.withUnsafeBytes { raw in
            withUnsafePointer(to: &dst) { aptr in
                aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
                    sendto(fd, raw.baseAddress!, raw.count, 0, saptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent <= 0 { return nil }

        var buf = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in(); var fromlen: socklen_t = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) { aptr -> ssize_t in
            aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
                recvfrom(fd, &buf, buf.count, 0, saptr, &fromlen)
            }
        }
        if n <= 0 { return nil }
        let data = Data(buf.prefix(Int(n)))

        guard let answers = parseAnswers(message: data) else { return nil }
        var out: [String] = []
        for ans in answers where ans.type == 16 && ans.klass == 1 {
            // TXT RDATA: one or more <character-string>; join all chunks into a single string per answer
            var offset = 0
            let bytes = [UInt8](ans.rdata)
            var chunks: [String] = []
            while offset < bytes.count {
                let ln = Int(bytes[offset]); offset += 1
                guard offset + ln <= bytes.count else { break }
                let s = String(decoding: bytes[offset..<(offset+ln)], as: UTF8.self)
                chunks.append(s)
                offset += ln
            }
            if !chunks.isEmpty { out.append(chunks.joined()) }
        }
        return out.isEmpty ? nil : out
    }

    private static func parseAnswers(message: Data) -> [Answer]? {
        if message.count < 12 { return nil }
        let bytes = [UInt8](message)
        func r16(_ off: Int) -> UInt16 { return (UInt16(bytes[off]) << 8) | UInt16(bytes[off+1]) }
        func r32(_ off: Int) -> UInt32 { return (UInt32(bytes[off]) << 24) | (UInt32(bytes[off+1]) << 16) | (UInt32(bytes[off+2]) << 8) | UInt32(bytes[off+3]) }
        let id = r16(0)
        _ = id
        let qd = Int(r16(4))
        let an = Int(r16(6))
        var off = 12
        for _ in 0..<qd {
            guard let _ = parseName(bytes, &off) else { return nil }
            off += 4 // type+class
            if off > bytes.count { return nil }
        }
        var answers: [Answer] = []
        for _ in 0..<an {
            guard parseName(bytes, &off) != nil else { return nil }
            if off + 10 > bytes.count { return nil }
            let typ = r16(off); let cls = r16(off+2); let ttl = r32(off+4); let rdlen = Int(r16(off+8))
            off += 10
            if off + rdlen > bytes.count { return nil }
            let rdata = Data(bytes[off..<(off+rdlen)])
            off += rdlen
            answers.append(Answer(name: "", type: typ, klass: cls, ttl: ttl, rdata: rdata))
        }
        return answers
    }

    // Returns (name, newOffset)
    private static func parseName(_ bytes: [UInt8], _ offset: inout Int) -> (String, Int)? {
        var labels: [String] = []
        var off = offset
        var jumpedTo: Int? = nil
        var loops = 0
        while true {
            if loops > 255 { return nil } // prevent infinite loops
            loops += 1
            if off >= bytes.count { return nil }
            let len = Int(bytes[off])
            if len == 0 { off += 1; break }
            if (len & 0xC0) == 0xC0 { // pointer
                if off + 1 >= bytes.count { return nil }
                let ptr = ((len & 0x3F) << 8) | Int(bytes[off+1])
                if jumpedTo == nil { jumpedTo = off + 2 }
                off = ptr
                continue
            } else {
                if off + 1 + len > bytes.count { return nil }
                let s = String(decoding: bytes[(off+1)..<(off+1+len)], as: UTF8.self)
                labels.append(s)
                off += 1 + len
            }
        }
        if let j = jumpedTo { offset = j } else { offset = off }
        let name = labels.joined(separator: ".")
        return (name, off)
    }

}

// SPI: lightweight wrappers for tests (avoid exposing DNSClient or internals)
@_spi(Test)
public struct __TXTAnswer: Sendable {
    public let type: UInt16
    public let klass: UInt16
    public let rdata: Data
}

@_spi(Test)
public func __dnsEncodeQName(_ name: String) -> [UInt8] { _encodeQName(name) }

@_spi(Test)
public func __dnsParseTXTAnswers(message: Data) -> [__TXTAnswer]? {
    // Minimal independent parser for TXT answers (sufficient for tests).
    // This mirrors parseAnswers enough for tests.
    let bytes = [UInt8](message)
    if bytes.count < 12 { return nil }
    func r16(_ off: Int) -> UInt16 { return (UInt16(bytes[off]) << 8) | UInt16(bytes[off+1]) }
    func r32(_ off: Int) -> UInt32 { return (UInt32(bytes[off]) << 24) | (UInt32(bytes[off+1]) << 16) | (UInt32(bytes[off+2]) << 8) | UInt32(bytes[off+3]) }
    let qd = Int(r16(4)); let an = Int(r16(6))
    var off = 12
    // skip questions
    for _ in 0..<qd {
        // skip qname
        while off < bytes.count {
            let len = Int(bytes[off]); off += 1
            if len == 0 { break }
            if (len & 0xC0) == 0xC0 { off += 1; break }
            off += len
        }
        off += 4
        if off > bytes.count { return nil }
    }
    var out: [__TXTAnswer] = []
    for _ in 0..<an {
        // skip name
        if off >= bytes.count { return nil }
        let b0 = Int(bytes[off])
        if (b0 & 0xC0) == 0xC0 { off += 2 } else {
            while off < bytes.count {
                let len = Int(bytes[off]); off += 1
                if len == 0 { break }
                off += len
            }
        }
        if off + 10 > bytes.count { return nil }
        let typ = r16(off); let cls = r16(off+2); _ = r32(off+4); let rdlen = Int(r16(off+8)); off += 10
        if off + rdlen > bytes.count { return nil }
        let rdata = Data(bytes[off..<(off+rdlen)])
        off += rdlen
        out.append(__TXTAnswer(type: typ, klass: cls, rdata: rdata))
    }
    return out
}
