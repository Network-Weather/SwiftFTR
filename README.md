SwiftFTR
========

Massively parallel, async/await traceroute library for macOS using ICMP datagram sockets (no sudo required). Fires one ICMP Echo probe per TTL up to a hop limit, then concurrently collects ICMP Time Exceeded and Echo Reply messages.

Highlights
- No sudo: uses `SOCK_DGRAM` with `IPPROTO_ICMP` on macOS.
- Parallel send: adjusts `IP_TTL` per send on a single socket.
- Async/await API: simple `trace` that returns structured hops.
- IPv4 focus: macOS 13+; Linux likely requires raw sockets.
- Segmentation: classifies hops as `LOCAL`/`ISP`/`TRANSIT`/`DESTINATION` with hole‑filling.

Performance
- Monotonic RTT timing (avoids wall‑clock jumps).
- Reused receive buffers to reduce allocations.
- In‑memory ASN cache for repeated lookups.
- Optional concurrent reverse DNS (CLI) for faster output.

Requirements
- Swift 6
- macOS 13+

Installation (SwiftPM)
- In Xcode: Add Package → enter the repository URL → choose SwiftFTR.
- Or in `Package.swift`:
  - dependencies: `.package(url: "https://github.com/your-org/SwiftFTR.git", from: "0.1.0"),`
  - targets: `"SwiftFTR"` in your target’s dependencies.

Quick Start (Library)
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

CLI Usage
Build and run the included sample executable:
```
swift build -c release
.build/release/swift-ftr 1.1.1.1 30 1

# JSON with ASN-based categories and STUN public IP discovery
.build/release/swift-ftr --json www.nic.br 30 1
```

Environment
- `PTR_SKIP_STUN=1`: disable STUN public IP discovery (tests/CI isolation).
- `PTR_PUBLIC_IP=x.y.z.w`: override public IP used for ISP‑ASN matching.

Notes
- Targets macOS’s ICMP datagram behavior. Other platforms may vary.
- Sends one probe per TTL; you can extend to multi‑probe per TTL by varying `sequence` and aggregating.
- Socket is non‑blocking and polled (`poll(2)`), parsing embedded echo headers to match replies.
- Classification uses Team Cymru WHOIS (best‑effort, short timeouts). Heuristics fall back when data is unavailable.

Testing
- XCTest: `swift test -c debug` (CI sets `PTR_SKIP_STUN=1`).
- Lightweight runner: `.build/debug/ptrtests` (no XCTest requirement).

Fuzzing
- Random fuzzer (macOS):
  - Build: `swift build -c release -Xswiftc -sanitize=address -Xswiftc -sanitize=undefined`
  - Run: `.build/release/icmpfuzz` (override iterations with `ITER=200000`)
- Corpus + libFuzzer (Linux):
  - Generate corpus: `swift run genseeds FuzzCorpus/icmp`
  - Build: `swift build -c release -Xswiftc -sanitize=fuzzer,address,undefined`
  - Run: `.build/release/icmpfuzzer FuzzCorpus/icmp -max_total_time=30`

Documentation
- DocC bundle included at `Sources/SwiftFTR/SwiftFTR.docc`.

License
- MIT — see LICENSE.

Versioning & Releases
- Semantic Versioning. See CHANGELOG.md for release notes.
- To consume via SwiftPM, use the `0.1.0` tag or later.
