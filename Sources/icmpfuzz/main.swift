import Foundation
@_spi(Fuzz) import ParallelTraceroute

@main
struct Fuzzer {
    static func main() {
        var iterations = 50_000
        if let env = ProcessInfo.processInfo.environment["ITER"], let it = Int(env), it > 0 { iterations = it }
        var hits = 0, nils = 0
        var rng = SystemRandomNumberGenerator()
        var ss = sockaddr_storage()
        for i in 0..<iterations {
            let len = Int.random(in: 0...4096, using: &rng)
            var buf = [UInt8](repeating: 0, count: len)
            for j in 0..<len { buf[j] = UInt8.random(in: .min ... .max, using: &rng) }

            // Alternate between random sockaddr and plausible AF_INET sockaddr
            if (i & 1) == 0 {
                withUnsafeMutableBytes(of: &ss) { raw in
                    for k in 0..<raw.count { raw[k] = UInt8.random(in: .min ... .max, using: &rng) }
                }
            } else {
                var sin = sockaddr_in()
                sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                sin.sin_family = sa_family_t(AF_INET)
                sin.sin_addr = in_addr(s_addr: arc4random())
                withUnsafePointer(to: &sin) { sp in memcpy(&ss, sp, MemoryLayout<sockaddr_in>.size) }
            }

            buf.withUnsafeBytes { raw in
                if __fuzz_parseICMP(buffer: raw, from: ss) { hits &+= 1 } else { nils &+= 1 }
            }
        }
        print("Fuzz done: iterations=\(iterations) hits=\(hits) nils=\(nils)")
    }
}
