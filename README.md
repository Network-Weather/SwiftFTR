SwiftFTR
========

[![CI](https://github.com/Network-Weather/SwiftFTR/actions/workflows/ci.yml/badge.svg)](https://github.com/Network-Weather/SwiftFTR/actions/workflows/ci.yml)
[![Docs](https://github.com/Network-Weather/SwiftFTR/actions/workflows/docs.yml/badge.svg)](https://swiftftr.networkweather.com/)
[![Swift 6.1](https://img.shields.io/badge/Swift-6.1-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue.svg)](https://developer.apple.com/macos/)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Fast, parallel traceroute for Swift on macOS — no sudo required. SwiftFTR uses ICMP datagram sockets with async/await to probe every hop at once, then classifies the path into segments like LOCAL, ISP, TRANSIT, and DESTINATION.

[API Documentation](https://swiftftr.networkweather.com/) — generated via DocC and published by GitHub Pages.

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
- Swift 6.1+ (requires Xcode 16.4 or later)
- macOS 13+
- IPv4 only at the moment (ICMPv4 Echo). On Linux, typical ICMP requires raw sockets (root/CAP_NET_RAW); SwiftFTR targets macOS’s ICMP datagram behavior.

Install (SwiftPM)
-----------------
- Xcode: File → Add Package → enter this repository URL → select the `SwiftFTR` product.
- `Package.swift`:

  ```swift
  dependencies: [
      .package(url: "https://github.com/Network-Weather/SwiftFTR.git", from: "0.1.0")
  ],
  targets: [
      .target(name: "YourTarget", dependencies: ["SwiftFTR"]) 
  ]
  ```

Swift 6.1 Compliance
--------------------
SwiftFTR is fully compliant with Swift 6.1 concurrency requirements:
- ✅ All public value types are `Sendable`
- ✅ API works without `@MainActor` requirements
- ✅ Thread-safe usage from any actor or task
- ✅ Builds under Swift 6 language mode with strict concurrency checks

New in v0.3.0
-------------
- **Trace Cancellation**: Cancel in-flight traces when network conditions change
- **rDNS Support**: Automatic reverse DNS lookups with built-in caching (86400s TTL)
- **STUN Caching**: Public IP discovery results are cached until network changes
- **Network Change API**: Call `networkChanged()` to invalidate caches and cancel active traces
- **Actor-based Architecture**: SwiftFTR is now an actor for better concurrency safety

Use It as a Library
-------------------
```swift
import SwiftFTR

// Configure once, use everywhere
let config = SwiftFTRConfig(
    maxHops: 30,        // Max TTL to probe
    maxWaitMs: 1000,    // Timeout in milliseconds  
    payloadSize: 56,    // ICMP payload size
    publicIP: nil,      // Auto-detect via STUN
    enableLogging: false // Set true for debugging
)

let tracer = SwiftFTR(config: config)

// Basic trace - can be called from any actor context
let result = try await tracer.trace(to: "1.1.1.1")
for hop in result.hops {
    let addr = hop.ipAddress ?? "*"
    let rtt  = hop.rtt.map { String(format: "%.3f ms", $0 * 1000) } ?? "timeout"
    print("\(hop.ttl)\t\(addr)\t\(rtt)")
}

// With ASN classification
let classified = try await tracer.traceClassified(to: "www.example.com")
for hop in classified.hops {
    print(hop.ttl, hop.ip ?? "*", hop.category.rawValue, hop.asn ?? 0, hop.asName ?? "")
    // New: hostname from reverse DNS
    if let hostname = hop.hostname {
        print("  Hostname: \(hostname)")
    }
}

// Handle network changes (e.g., WiFi to cellular, VPN connect/disconnect)
await tracer.networkChanged()  // Cancels active traces and clears caches
```

📚 **[See comprehensive examples](docs/guides/EXAMPLES.md)** including SwiftUI integration, error handling, concurrent traces, and more.

Notes for Embedding
-------------------
- **Thread Safety**: SwiftFTR is fully thread-safe and `nonisolated`. Call from any actor, task, or queue.
- **Public IP**: Configure via `SwiftFTRConfig(publicIP: "x.y.z.w")` to bypass STUN discovery.
- **ASN Lookups**: `traceClassified` uses DNS‑based Team Cymru with caching. Inject custom `ASNResolver` for offline lookups.
- **Timeout Behavior**: Operations complete within configured `maxWaitMs`, guaranteed non-blocking.
- **Error Handling**: Detailed `TracerouteError` with context about failures (permissions, network, platform).
- **SwiftUI Ready**: No MainActor requirements - integrate directly into SwiftUI views and view models.

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

Configuration and Flags
-----------------------
- Prefer `SwiftFTRConfig(publicIP: ...)` to bypass STUN discovery when desired.
- CLI: `--public-ip x.y.z.w`, `--verbose`, `--payload-size`, `--max-hops`, `--timeout`.

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
- SwiftPM plugin (Xcode 16.4+/Swift 6.1+):
  ```bash
  swift package --allow-writing-to-directory docs \
    generate-documentation --target SwiftFTR \
    --output-path docs --transform-for-static-hosting --hosting-base-path SwiftFTR
  open docs/index.html
  ```

Formatting & Hooks
------------------
- Lint formatting locally before pushing:
  ```bash
  swift format lint -r Sources Tests
  ```
- Optional: install repo hooks so pushes fail on formatting issues:
  ```bash
  git config core.hooksPath .githooks
  ```

License
-------
MIT — see LICENSE.

Versioning & Releases
---------------------
- Semantic Versioning. See CHANGELOG.md for release notes.
- To consume via SwiftPM, use the `0.1.0` tag or later.

Contributing
------------
See CONTRIBUTING.md for development setup, formatting, testing, docs, and release guidance.

Code of Conduct
---------------
This project adheres to a Code of Conduct. By participating, you agree to abide by its terms. See CODE_OF_CONDUCT.md.
