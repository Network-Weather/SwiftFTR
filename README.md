SwiftFTR
========

Massively parallel, async/await traceroute library for macOS using ICMP datagram sockets (no sudo required). It fires one ICMP Echo probe per TTL up to a hop limit, as fast as possible, then concurrently collects ICMP Time Exceeded and Echo Reply messages to map the path.

Key points
- No sudo: uses `SOCK_DGRAM` with `IPPROTO_ICMP` (macOS supports this for ping/traceroute style operations).
- Parallel send: issues all TTL probes rapidly on a single socket by updating `IP_TTL` per send.
- Async/await friendly: single async `trace` API returning structured hop results.
- IPv4 only, macOS-focused.
- Route segmentation: classifies hops into `LOCAL`, `ISP`, `TRANSIT`, `DESTINATION` with hole-filling for non-responsive hops.

Swift version
- Swift 6, macOS 13+

Library API
- `SwiftFTR().trace(to:maxHops:timeout:payloadSize:)` → `TraceResult` (default `maxHops=30`, `timeout=1.0s`)
- `SwiftFTR().traceClassified(to:maxHops:timeout:payloadSize:resolver:)` → `ClassifiedTrace` with ASN/category info
- `TraceResult` contains `hops: [TraceHop]`, each with `ttl`, `host` (or `nil` on timeout), `rtt`, and a `reachedDestination` flag for echo replies.

Example (CLI)
Build and run the included sample executable:

```
swift build -c release
.build/release/swift-ftr 1.1.1.1 30 1

# JSON with ASN-based categories and STUN public IP discovery
.build/release/swift-ftr --json www.nic.br 30 1
```

Programmatic usage
```
import SwiftFTR

let tracer = SwiftFTR()
let result = try await tracer.trace(to: "1.1.1.1", maxHops: 30, timeout: 1)
for hop in result.hops {
    print(hop.ttl, hop.host ?? "*", hop.rtt ?? 0)
}

// With classification
let classified = try await tracer.traceClassified(to: "www.nic.br")
for hop in classified.hops {
    print(hop.ttl, hop.ip ?? "*", hop.category, hop.asn.map(String.init) ?? "-")
}
```

Notes
- This implementation targets macOS’s ICMP datagram behavior. Other platforms may require adjustments (e.g., raw sockets on Linux typically need root).
- The traceroute sends one probe per TTL. You can adapt it to send multiple probes per TTL by issuing additional packets with incremented `sequence` numbers and tracking them in the same dictionaries.
- The socket is set `O_NONBLOCK` and we use `poll(2)` to drive receive without blocking. Incoming ICMP Time Exceeded packets include the embedded original header, which we parse to match the original `identifier`/`sequence`.
- Only IPv4 is implemented.
- Hop classification: `LOCAL` (RFC1918/link-local), `ISP` (CGNAT or same ASN as your public IP via STUN), `TRANSIT` (public IP with ASN different from ISP and destination), `DESTINATION` (same ASN as destination). ASN lookup uses Team Cymru’s WHOIS service in batch mode (best-effort, may be rate-limited). When ASN data isn’t available, classification falls back to `LOCAL`/`ISP (CGNAT)`/`TRANSIT` heuristics.

Classification details
- Input signals: hop IPs (from ICMP Time Exceeded/Echo Reply), destination IP ASN, and client public IP ASN (via STUN). All lookups are best-effort with short timeouts.
- Rules per hop (in order):
  - Private/link-local → `LOCAL`.
  - CGNAT (100.64/10) → `ISP`.
  - If ASN known and equals client ASN → `ISP`.
  - Else if ASN known and equals destination ASN → `DESTINATION`.
  - Else (public IP, ASN unknown or different) → `TRANSIT`.
- Hole filling (timeouts): consecutive non-responsive hops between two hops that share the same category (not `UNKNOWN`) inherit that category. If both sides also share the same ASN, the holes inherit that ASN as well.

JSON schema (CLI `--json`)
- Top-level: `destinationHost`, `destinationIP`, optional `publicIP`, optional `clientASN`, `destinationASN`, and `hops`.
- `hops[n]`: `{ ttl: Int, ip: String?, rtt: Double?, asn: Int?, asName: String?, category: "LOCAL"|"ISP"|"TRANSIT"|"DESTINATION"|"UNKNOWN" }`

Environment toggles (for tests/CI)
- `PTR_SKIP_STUN=1`: disable STUN lookup (keeps runtime isolated/offline).
- `PTR_PUBLIC_IP=x.y.z.w`: override public IP used for ISP-ASN matching (bypasses STUN). Combine with a resolver that knows this IP to set client ASN.

Fuzzing
- Quick random fuzzer (macOS-friendly): `icmpfuzz` builds without libFuzzer and hammers the parser with randomized inputs under ASan/UBSan.
  - Build: `swift build -c release -Xswiftc -sanitize=address -Xswiftc -sanitize=undefined`
  - Run: `.build/release/icmpfuzz` (override iterations with `ITER=200000`)
- Corpus-based and libFuzzer harness (Linux): `icmpfuzzer` provides a libFuzzer entrypoint when built on Linux with `-sanitize=fuzzer`.
  - Generate seed corpus: `swift run genseeds FuzzCorpus/icmp`
  - Linux build (Swift 6 toolchain): `swift build -c release -Xswiftc -sanitize=fuzzer,address,undefined`
  - Run: `.build/release/icmpfuzzer FuzzCorpus/icmp -max_total_time=30` (libFuzzer options)
  - On macOS, the same binary acts as a corpus replayer: `.build/release/icmpfuzzer FuzzCorpus/icmp`

Testing
- Lightweight test runner (no XCTest):
  - Build: `swift build -c debug`
  - Run: `.build/debug/ptrtests` (returns non-zero on failure)
  - What it covers: ICMP parsing (Echo Reply, Time Exceeded w/ embedded echo), classification rules (LOCAL/ISP/TRANSIT/DESTINATION, CGNAT handling, hole-filling). Uses env vars to avoid network.

License
- No license specified. Add one if you plan to distribute.
