// swift-ip2asn 0.4.0 v6 lookup spike.
//
// Validates that `UltraCompactDatabase.lookup(_ ipString:)` correctly dispatches
// v6 strings to `lookupV6(hi:lo:)` against the bundled `ip2asn-v2.ultra` dataset
// before LocalASNResolver and Traceroute integration depend on it.
//
// Run:
//     swift run ip2asnv6probe

import Foundation
import SwiftIP2ASN

@main
struct IP2ASNv6Probe {
  static func main() async {
    print("Loading embedded ip2asn database (0.4.0, dual-stack ULT2 format)…")
    let db: UltraCompactDatabase
    do {
      db = try EmbeddedDatabase.loadUltraCompact()
    } catch {
      fputs("FATAL: failed to load embedded DB: \(error)\n", stderr)
      exit(1)
    }
    print("Loaded.\n")

    let cases: [(String, String)] = [
      // (address, what we expect AS-wise — hand-verified from public ASN data)
      ("2606:4700:4700::1111", "Cloudflare AS13335"),
      ("2606:4700:4700::1001", "Cloudflare AS13335"),
      ("2001:4860:4860::8888", "Google AS15169"),
      ("2001:4860:4860::8844", "Google AS15169"),
      ("2a00:1450:4001::1", "Google AS15169"),
      ("2620:fe::fe", "Quad9 AS19281"),
      ("2606:2800:220:1::1", "Edgecast AS15133"),
      // Loopback/link-local — expect nil.
      ("::1", "nil (loopback)"),
      ("fe80::1", "nil (link-local)"),
      // Likely-unallocated — expect nil.
      ("ffff:ffff:ffff:ffff::1", "nil (multicast/unallocated)"),
      // IPv4 fast-path through the same API — sanity check that v6 bump didn't
      // break the v4 lookup path.
      ("1.1.1.1", "Cloudflare AS13335 (v4 sanity)"),
      ("8.8.8.8", "Google AS15169 (v4 sanity)"),
    ]

    var v6Hits = 0
    var v6Misses = 0
    var v4Hits = 0

    for (addr, expectation) in cases {
      let result = db.lookup(addr)
      let isV6 = addr.contains(":")
      let resultStr: String
      switch result {
      case .some(let (asn, name)):
        resultStr = "AS\(asn) (\(name ?? "<no name>"))"
        if isV6 { v6Hits += 1 } else { v4Hits += 1 }
      case .none:
        resultStr = "nil"
        if isV6 { v6Misses += 1 }
      }
      print("  \(addr.padding(toLength: 30, withPad: " ", startingAt: 0)) → \(resultStr)")
      print("    (expected: \(expectation))")
    }

    print("")
    print("Summary: v6 hits=\(v6Hits), v6 nil=\(v6Misses), v4 hits=\(v4Hits)")
    if v6Hits == 0 {
      fputs(
        "WARN: zero v6 hits — either the bundled DB lacks v6 data or lookup() doesn't dispatch v6.\n",
        stderr)
      exit(2)
    }
    print("OK: v6 lookups are functional via UltraCompactDatabase.lookup(_:).")
  }
}
