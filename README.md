SwiftFTR
========

Fast, parallel traceroute for Swift on macOS — no sudo required. SwiftFTR uses ICMP datagram sockets with async/await to probe every hop at once, then classifies the path into segments like LOCAL, ISP, TRANSIT, and DESTINATION.

Why SwiftFTR?
-------------
- No sudo: Uses `SOCK_DGRAM` with `IPPROTO_ICMP` on macOS, so you can run traceroute‑style measurements from apps, tests, and CI without elevated privileges.
- Parallel by design: Sends one ICMP Echo per TTL up to your max hop in a tight loop, then listens for all responses concurrently.
- Simple async API: A single `trace(...)` call returns structured hops; `traceClassified(...)` adds ASN‑based labeling.
- Production‑friendly: Monotonic RTT timing, buffer reuse, and an in‑memory ASN cache minimize noise and allocations.

How It Works
------------
1) Resolve destination IPv4 address.
2) Open an ICMP datagram socket (`SOCK_DGRAM`, `IPPROTO_ICMP`). Set non‑blocking mode.
3) For TTL = 1…maxHops:
   - Set `IP_TTL` to the current TTL and send an ICMP Echo Request with a stable identifier and sequence (seq = TTL).
   - Record send time in a small map keyed by `sequence`.
4) Enter a single receive loop until a global deadline:
   - Poll the socket and parse each incoming datagram as one of: Echo Reply, Time Exceeded, or Destination Unreachable.
   - Match replies back to the original probe using the identifier/sequence embedded in the payload.
   - Compute RTT with a monotonic clock and place the hop at `ttl - 1`.
   - Stop early once the destination responded and all earlier hops are either filled or have timed out.
5) Optional classification (when using `traceClassified`):
   - Detect the client’s public IP via STUN (or use `PTR_PUBLIC_IP`, or disable via `PTR_SKIP_STUN`).
   - Batch‑resolve ASNs using Team Cymru DNS WHOIS and apply heuristics for PRIVATE and CGNAT ranges.
   - Label each hop as LOCAL, ISP, TRANSIT, or DESTINATION and “hole‑fill” missing stretches between identical segments.

How Fast Is It?
---------------
Classic traceroute often probes sequentially and waits per hop; SwiftFTR probes all hops in one burst and waits once.

- Time complexity: O(1) with respect to hop count. Wall‑clock time is bounded by your chosen `timeout` (for example, `timeout = 1.0` typically completes in about ~1 second rather than ~30 seconds for 30 sequential probes).
- Efficient I/O: Single socket, non‑blocking `poll(2)`, reused receive buffer, and monotonic timing reduce overhead and jitter.

If you need even tighter runs, lower `timeout` (e.g., `0.5`) or cap `maxHops` (e.g., `20`). You can also tune `payloadSize` in advanced scenarios.

- Requirements
--------------
- Swift 5.10+
- macOS 13+
- IPv4 only at the moment (ICMPv4 Echo). On Linux, typical ICMP requires raw sockets (root/CAP_NET_RAW); SwiftFTR targets macOS’s ICMP datagram behavior.

Install (SwiftPM)
-----------------
- Xcode: File → Add Package → enter this repository URL → select the `SwiftFTR` product.
- `Package.swift`:

  ```swift
  // Replace with your repository URL
  dependencies: [
      .package(url: "https://github.com/your-org/SwiftFTR.git", from: "0.1.0")
  ],
  targets: [
      .target(name: "YourTarget", dependencies: ["SwiftFTR"]) 
  ]
  ```

Use It as a Library
-------------------
```swift
import SwiftFTR

let tracer = SwiftFTR()

// Basic trace
let result = try await tracer.trace(to: "1.1.1.1", maxHops: 30, timeout: 1.0)
for hop in result.hops {
    let addr = hop.ipAddress ?? "*"
    let rtt  = hop.rtt.map { String(format: "%.3f ms", $0 * 1000) } ?? "timeout"
    print("\(hop.ttl)\t\(addr)\t\(rtt)")
}
print("duration: \(String(format: "%.3f s", result.duration))")

// With ASN classification and segments
let classified = try await tracer.traceClassified(to: "www.example.com", maxHops: 30, timeout: 1.0)
for hop in classified.hops {
    print(hop.ttl, hop.ip ?? "*", hop.category.rawValue, hop.asn ?? 0, hop.asName ?? "")
}
```

Notes for Embedding
-------------------
- Public IP discovery: Set `PTR_SKIP_STUN=1` to disable STUN in sandboxed/test environments, or set `PTR_PUBLIC_IP=x.y.z.w` to provide a known address.
- ASN lookups: `traceClassified` uses a DNS‑based Team Cymru client by default with a small in‑memory cache. You can inject your own `ASNResolver` implementation.
- Concurrency: All probes are sent quickly; the receiver loop runs until a global deadline so embedding won’t block longer than `timeout`.
- Error handling: Resolution, socket creation, and send errors surface as `TracerouteError` with human‑readable descriptions.

Use It from the CLI
-------------------
Build the bundled executable and run it:

```bash
swift build -c release
.build/release/swift-ftr --help
.build/release/swift-ftr example.com -m 30 -w 1.0
```

Selected options (ArgumentParser-powered):
- `-m, --max-hops N`: Max TTL/hops to probe (default 30)
- `-w, --timeout SEC`: Overall wait after sending probes (default 1.0)
- `--json`: Emit JSON with ASN categories and public IP
- `--no-rdns`: Disable reverse DNS lookups
- `--no-stun`: Skip STUN public IP discovery
- `--public-ip IP`: Override public IP (bypasses STUN)

Example: JSON output
```bash
.build/release/swift-ftr --json www.example.com -m 30 -w 1.0
```

Environment Variables
---------------------
- `PTR_SKIP_STUN=1`: Disable STUN public IP discovery (useful for tests/CI).
- `PTR_PUBLIC_IP=x.y.z.w`: Override public IP used for ISP/ASN matching.

Design Details
--------------
- Socket: ICMP `SOCK_DGRAM` on macOS (no privileges) with `O_NONBLOCK` and `poll(2)`.
- Probing: One Echo Request per TTL; identifier is constant per run, sequence equals TTL for easy correlation.
- Matching: Echo Reply and Time Exceeded handlers pull out embedded id/seq from the packet to map to the original probe.
- Timing: RTT is measured with `CLOCK_MONOTONIC` to avoid wall‑clock jumps.
- Classification: Team Cymru DNS WHOIS lookups with caching; PRIVATE and CGNAT ranges are recognized without lookups; missing stretches are “hole‑filled” between identical segment classes.

Testing
-------
- Unit tests: `swift test`
- Lightweight runner: `.build/debug/ptrtests`

Fuzzing
-------
- Random fuzzer (macOS):
  - Build: `swift build -c release -Xswiftc -sanitize=address -Xswiftc -sanitize=undefined`
  - Run: `.build/release/icmpfuzz` (override iterations with `ITER=200000`)
- Corpus + libFuzzer (Linux):
  - Generate corpus: `swift run genseeds FuzzCorpus/icmp`
  - Build: `swift build -c release -Xswiftc -sanitize=fuzzer,address,undefined`
  - Run: `.build/release/icmpfuzzer FuzzCorpus/icmp -max_total_time=30`

Documentation
-------------
- DocC bundle at `Sources/SwiftFTR/SwiftFTR.docc`.

Generate and view the docs:

- Xcode: Product → Build Documentation (or use the Documentation sidebar).
- SwiftPM plugin (Xcode 15+/Swift 5.9+):
  ```bash
  swift package --allow-writing-to-directory docs \
    generate-documentation --target SwiftFTR \
    --output-path docs --transform-for-static-hosting --hosting-base-path SwiftFTR
  open docs/index.html
  ```

License
-------
MIT — see LICENSE.

Versioning & Releases
---------------------
- Semantic Versioning. See CHANGELOG.md for release notes.
- To consume via SwiftPM, use the `0.1.0` tag or later.
