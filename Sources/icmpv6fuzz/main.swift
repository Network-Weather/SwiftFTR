import Foundation
@_spi(Fuzz) import SwiftFTR
@_spi(Test) import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

// ICMPv6 parser fuzzer.
//
// Mirrors `icmpfuzz` for the v6 parsers added across Stages 1-2. Feeds random
// buffers (some sized 0..4096 bytes, some shaped vaguely like real packets) to
// the SwiftFTR `@_spi(Fuzz) __fuzz_parseICMPv6` entry point and the
// `@_spi(Test) __parseV6PingMessage` (with random hop-limit and expected
// identifier values). Crashes mean the parser has an unguarded read or
// arithmetic over an attacker-controllable buffer.
//
// Run:
//     ITER=100000 swift run -c release icmpv6fuzz
//
// The default is 50_000 iterations which completes in <1s on an M-series Mac.

@main
struct Fuzzer {
  static func main() {
    var iterations = 50_000
    if let env = ProcessInfo.processInfo.environment["ITER"], let it = Int(env), it > 0 {
      iterations = it
    }

    var hits = 0
    var nils = 0
    var pingHits = 0
    var pingNils = 0
    var rng = SystemRandomNumberGenerator()
    var ss = sockaddr_storage()

    for i in 0..<iterations {
      let len = Int.random(in: 0...4096, using: &rng)
      var buf = [UInt8](repeating: 0, count: len)
      for j in 0..<len { buf[j] = UInt8.random(in: .min ... .max, using: &rng) }

      // Alternate between random sockaddr_storage and plausible AF_INET6 storage.
      if (i & 1) == 0 {
        withUnsafeMutableBytes(of: &ss) { raw in
          for k in 0..<raw.count { raw[k] = UInt8.random(in: .min ... .max, using: &rng) }
        }
      } else {
        var sin6 = sockaddr_in6()
        sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        sin6.sin6_family = sa_family_t(AF_INET6)
        // Randomize the 16-byte address bytes.
        withUnsafeMutableBytes(of: &sin6.sin6_addr) { raw in
          for k in 0..<raw.count { raw[k] = UInt8.random(in: .min ... .max, using: &rng) }
        }
        // Random scope ID — exercises link-local zone-suffix formatting.
        sin6.sin6_scope_id = UInt32.random(in: 0...10, using: &rng)
        _ = withUnsafePointer(to: &sin6) { sp in
          memcpy(&ss, sp, MemoryLayout<sockaddr_in6>.size)
        }
      }

      // Some iterations exercise the low-level parser used in trace.
      buf.withUnsafeBytes { raw in
        if __fuzz_parseICMPv6(buffer: raw, from: ss) { hits &+= 1 } else { nils &+= 1 }
      }

      // Others exercise the higher-level ping parser which takes hopLimit and
      // expectedIdentifier — both attacker-controllable (id from another
      // sender, cmsg from a strange kernel).
      //
      // To exercise the post-identifier-match code paths (not just the
      // identifier-mismatch reject), every ~16 iterations we plant a chosen
      // identifier at the canonical offsets in the buffer where it would
      // appear in a real ICMPv6 echo reply (bytes 4-5) and in a real Time
      // Exceeded message's embedded ICMPv6 header (bytes 8 + 40 + 4..5).
      let hopLimit: Int? = (i & 0b10) == 0 ? Int.random(in: -10...300, using: &rng) : nil
      let plantID = (i & 0xF) == 0
      let expectedID: UInt16
      if plantID, len >= 8 {
        let id = UInt16.random(in: .min ... .max, using: &rng)
        buf[4] = UInt8(id >> 8)
        buf[5] = UInt8(id & 0xFF)
        if len >= 8 + 40 + 8 {
          buf[8 + 40 + 4] = UInt8(id >> 8)
          buf[8 + 40 + 5] = UInt8(id & 0xFF)
        }
        expectedID = id
      } else {
        expectedID = UInt16.random(in: .min ... .max, using: &rng)
      }

      buf.withUnsafeBytes { raw in
        if __parseV6PingMessage(buffer: raw, hopLimit: hopLimit, expectedIdentifier: expectedID)
          != nil
        {
          pingHits &+= 1
        } else {
          pingNils &+= 1
        }
      }
    }

    print(
      "ICMPv6 fuzz done: iterations=\(iterations) "
        + "trace_parser_hits=\(hits) trace_parser_nils=\(nils) "
        + "ping_parser_hits=\(pingHits) ping_parser_nils=\(pingNils)")
  }
}
