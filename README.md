SwiftFTR
========

[![CI](https://github.com/Network-Weather/SwiftFTR/actions/workflows/ci.yml/badge.svg)](https://github.com/Network-Weather/SwiftFTR/actions/workflows/ci.yml)
[![Docs](https://github.com/Network-Weather/SwiftFTR/actions/workflows/docs.yml/badge.svg)](https://swiftftr.networkweather.com/)
[![Swift 6.1](https://img.shields.io/badge/Swift-6.1-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue.svg)](https://developer.apple.com/macos/)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Fast, parallel traceroute for Swift on macOS — no sudo required, full IPv4 and IPv6 support. SwiftFTR uses ICMP datagram sockets with async/await to probe every hop at once, then classifies the path into segments like LOCAL, ISP, TRANSIT, and DESTINATION.

[API Documentation](https://swiftftr.networkweather.com/) — generated via DocC and published by GitHub Pages.

Why SwiftFTR?
-------------
- No sudo: Uses `SOCK_DGRAM` with `IPPROTO_ICMP` / `IPPROTO_ICMPV6` on macOS, so you can run traceroute‑style measurements from apps, tests, and CI without elevated privileges.
- Parallel by design: Sends one ICMP Echo per TTL up to your max hop in a tight loop, then listens for all responses concurrently.
- Simple async API: A single `trace(...)` call returns structured hops; `traceClassified(...)` adds ASN‑based labeling. The same entry point accepts IPv4 or IPv6 targets — family is detected automatically.
- Dual-stack: ping, traceroute, TCP/UDP probes, and STUN-based public-IP discovery all work over IPv4 and IPv6 through the same APIs. v4 literals transparently work on v6-only NAT64 networks via system synthesis.
- Production‑friendly: Monotonic RTT timing, buffer reuse, and an in‑memory ASN cache minimize noise and allocations.

How It Works
------------
1) Resolve destination via a dual-stack `getaddrinfo` (with `AI_V4MAPPED | AI_ADDRCONFIG`) so v4 literals on v6-only NAT64 networks transparently get a synthesized v6 mapping.
2) Open an ICMP/ICMPv6 datagram socket — `SOCK_DGRAM` with `IPPROTO_ICMP` or `IPPROTO_ICMPV6` depending on the resolved family. Set non‑blocking mode.
3) For TTL = 1…maxHops:
   - Set `IP_TTL` (v4) or `IPV6_UNICAST_HOPS` (v6) to the current TTL and send an Echo Request with a stable identifier and sequence (seq = TTL).
   - Record send time in a small map keyed by `sequence`.
4) Register a `DispatchSourceRead` (kqueue-backed on macOS) and handle packets until a global deadline:
   - For v6, `recvmsg` is used so the reply's hop limit arrives via cmsg ancillary data (the kernel strips the IPv6 header from `SOCK_DGRAM` deliveries).
   - Parse each incoming datagram as one of: Echo Reply, Time Exceeded, or Destination Unreachable.
   - Match replies back to the original probe using the identifier/sequence embedded in the payload.
   - Compute RTT with a monotonic clock and place the hop at `ttl - 1`.
   - Stop early once the destination responded and all earlier hops are either filled or have timed out.
5) Optional classification (when using `traceClassified`):
   - Detect the client's public IP via STUN with DNS fallback (or use `PTR_PUBLIC_IP`, or disable via `PTR_SKIP_STUN`). `getPublicIPs()` returns both v4 and v6 in parallel for callers that want a dual-stack view.
   - Batch‑resolve ASNs using Team Cymru DNS (`origin.asn.cymru.com` for v4, `origin6.asn.cymru.com` for v6) or the embedded local database via swift-ip2asn 0.4.0. Apply heuristics for PRIVATE and CGNAT ranges.
   - Label each hop as LOCAL, ISP, TRANSIT, or DESTINATION and "hole‑fill" missing stretches between identical segments.

How Fast Is It?
---------------
Classic traceroute often probes sequentially and waits per hop; SwiftFTR probes all hops in one burst and waits once.

- Time complexity: O(1) with respect to hop count. Wall‑clock time is bounded by your chosen `timeout` (for example, `timeout = 1.0` typically completes in about ~1 second rather than ~30 seconds for 30 sequential probes).
- Efficient I/O: Single socket, kqueue-backed `DispatchSourceRead`, reused receive buffer, and monotonic timing reduce overhead and jitter.

If you need even tighter runs, lower `timeout` (e.g., `0.5`) or cap `maxHops` (e.g., `20`). You can also tune `payloadSize` in advanced scenarios.

Requirements
------------
- Swift 6.1+ (requires Xcode 16.4 or later)
- macOS 13+
- IPv4 and IPv6 supported across all surfaces (ICMPv4 Echo, ICMPv6 Echo per RFC 4443). On Linux, typical ICMP requires raw sockets (root/CAP_NET_RAW); SwiftFTR targets macOS's ICMP datagram behavior.

Install (SwiftPM)
-----------------
- Xcode: File → Add Package → enter this repository URL → select the `SwiftFTR` product.
- `Package.swift`:

  ```swift
  dependencies: [
      .package(url: "https://github.com/Network-Weather/SwiftFTR.git", from: "0.13.0")
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

Key Features
------------
**Traceroute**
- Parallel ICMP/ICMPv6 probing with O(1) time complexity (~1 second for 30 hops)
- Streaming API with real-time hop updates via `AsyncThrowingStream`
- ASN-based hop classification: LOCAL, ISP, TRANSIT, VPN, DESTINATION
- v6 hops get full ASN annotations via Team Cymru `origin6.asn.cymru.com` or the embedded swift-ip2asn database
- VPN-aware classification for tunnel and exit node detection
- Automatic rDNS lookups with 24-hour caching

**Dual-stack IPv4 / IPv6 (v0.13.0)**
- Every diagnostic accepts v4 literals, v6 literals, and hostnames through the same entry points
- `PreferredFamily { .v4, .v6, .auto }` lets callers force a family; default `.auto` lets the OS decide
- v4 literals on v6-only NAT64 networks transparently use the gateway's synthesized v6 mapping (RFC 6147)
- All emitted addresses are in `inet_ntop` canonical form; link-local addresses keep their `%zone` suffix
- A caller-selected BSD interface name binds v6 sockets via `IPV6_BOUND_IF`

**Network Probing**
- **Ping**: ICMP/ICMPv6 echo with statistics (min/avg/max RTT, jitter, packet loss)
- **TCP Probe**: Port state detection (open/closed/filtered) over v4 or v6
- **UDP Probe**: Connected-socket with ICMP/ICMPv6 unreachable detection
- **DNS Probe**: Direct server queries with 11 record types (A, AAAA, TXT, MX, etc.)
- **HTTP/HTTPS Probe**: Web server reachability testing

**Multipath Discovery**
- Dublin Traceroute-style ECMP path enumeration (v4)
- Smart deduplication and divergence point detection
- Flow identifier control for reproducible traces

**Interface & Binding**
- Per-operation interface binding (WiFi, Ethernet, VPN) — `IP_BOUND_IF` (v4) / `IPV6_BOUND_IF` (v6)
- Source IP binding for multi-homed hosts, v4 or v6 (link-local `%zone` honored)
- Resolution order: Operation → Global → System Default

**Public IP Discovery**
- STUN over both v4 and v6 with multi-server fallback (Google, Cloudflare)
- `getPublicIPs()` runs both families in parallel and returns whichever succeeded
- DNS-based fallback via Akamai whoami (v4 only — works behind captive portals)
- Results cached until network change

**Architecture**
- Actor-based design for thread safety
- Works from any actor or task (no `@MainActor` required)
- Network change API for cache invalidation and trace cancellation

Use It as a Library
-------------------
```swift
import SwiftFTR

// Discover names at runtime; BSD names do not imply WiFi or Ethernet.
let interfaceSnapshot = await NetworkInterfaceDiscovery().discover()
let selectedInterface = interfaceSnapshot.physicalInterfaces.first { $0.type == .wifi }

// Configure once, use everywhere
let config = SwiftFTRConfig(
    maxHops: 40,        // Max TTL to probe
    maxWaitMs: 1000,    // Timeout in milliseconds
    payloadSize: 56,    // ICMP payload size
    publicIP: nil,      // Auto-detect via STUN (with DNS fallback)
    enableLogging: false, // Set true for debugging
    interface: selectedInterface?.name // Optional: caller-selected interface
)

let tracer = SwiftFTR(config: config)

// Basic trace - can be called from any actor context
let result = try await tracer.trace(to: "1.1.1.1")
for hop in result.hops {
    let addr = hop.ipAddress ?? "*"
    let rtt  = hop.rtt.map { String(format: "%.3f ms", $0 * 1000) } ?? "timeout"
    print("\(hop.ttl)\t\(addr)\t\(rtt)")
}

// IPv6 works through the same entry point — family auto-detected from the target.
let v6Result = try await tracer.trace(to: "2606:4700:4700::1111")
// Or force a family explicitly:
let v6Config = SwiftFTRConfig(preferredFamily: .v6)
let alwaysV6 = SwiftFTR(config: v6Config)
let google = try await alwaysV6.trace(to: "google.com")  // prefers AAAA if available

// Dual-stack public-IP discovery (v0.13.0):
let publicIPs = await getPublicIPs()
print("v4: \(publicIPs.v4 ?? "n/a"), v6: \(publicIPs.v6 ?? "n/a")")

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

// Ping API
let pingConfig = PingConfig(count: 5, interval: 1.0, timeout: 2.0)
let pingResult = try await tracer.ping(to: "1.1.1.1", config: pingConfig)
print("Packet loss: \(Int(pingResult.statistics.packetLoss * 100))%")
if let avg = pingResult.statistics.avgRTT {
    print("Avg RTT: \(String(format: "%.2f ms", avg * 1000))")
}

// Concurrent pings: Multiple pings execute in parallel, not serially
async let cf = tracer.ping(to: "1.1.1.1", config: pingConfig)
async let goog = tracer.ping(to: "8.8.8.8", config: pingConfig)
let (cloudflare, google) = try await (cf, goog)
// 20 concurrent pings: ~1.1s (parallel) vs ~7.2s (if serialized) = 6.4x speedup

// Multipath Discovery (ECMP enumeration)
let multipathConfig = MultipathConfig(flowVariations: 8, maxPaths: 16)
let topology = try await tracer.discoverPaths(to: "8.8.8.8", config: multipathConfig)
print("Found \(topology.uniquePathCount) unique paths")
for hop in topology.uniqueHops() {
    print("Discovered hop at TTL \(hop.ttl): \(hop.ip ?? "*")")
}

// Per-Operation Interface Binding
// Override global interface for specific operations
let interfaces = await NetworkInterfaceDiscovery().discover()
if let wifiInterface = interfaces.physicalInterfaces.first(where: { $0.type == .wifi }),
   let ethernetInterface = interfaces.physicalInterfaces.first(where: { $0.type == .ethernet }) {
    let boundTracer = SwiftFTR(config: SwiftFTRConfig(interface: wifiInterface.name))

    // Use the caller-selected global interface.
    let wifiPing = try await boundTracer.ping(to: "1.1.1.1")

    // Override to use Ethernet for this operation only.
    let ethPing = try await boundTracer.ping(
        to: "1.1.1.1",
        config: PingConfig(interface: ethernetInterface.name)
    )

    // Concurrent multi-interface monitoring.
    async let wifi = boundTracer.ping(
        to: "1.1.1.1",
        config: PingConfig(interface: wifiInterface.name)
    )
    async let ethernet = boundTracer.ping(
        to: "1.1.1.1",
        config: PingConfig(interface: ethernetInterface.name)
    )
    let (wifiResult, ethResult) = try await (wifi, ethernet)
    print("WiFi loss: \(Int(wifiResult.statistics.packetLoss * 100))%")
    print("Ethernet loss: \(Int(ethResult.statistics.packetLoss * 100))%")
}

// DNS API with rich metadata
// IPv4 address lookup
let aResult = try await tracer.dns.a(hostname: "google.com")
print("Server: \(aResult.server), RTT: \(aResult.rttMs)ms")
for record in aResult.records {
  if case .ipv4(let addr) = record.data {
    print("  \(addr) (TTL: \(record.ttl)s)")
  }
}

// IPv6 address lookup
let aaaaResult = try await tracer.dns.aaaa(hostname: "google.com")
for record in aaaaResult.records {
  if case .ipv6(let addr) = record.data {
    print("  \(addr)")
  }
}

// Reverse DNS lookup
let ptrResult = try await tracer.dns.reverseIPv4(ip: "8.8.8.8")
for record in ptrResult.records {
  if case .hostname(let name) = record.data {
    print("  8.8.8.8 → \(name)")
  }
}

// MX records (mail exchange)
let mxResult = try await tracer.dns.query(name: "google.com", type: .mx)
for record in mxResult.records {
  if case .mx(let priority, let exchange) = record.data {
    print("  Priority \(priority): \(exchange)")
  }
}

// TXT records (SPF, DKIM, etc.)
let txtResult = try await tracer.dns.txt(hostname: "google.com")
for record in txtResult.records {
  if case .text(let strings) = record.data {
    for str in strings {
      print("  \(str)")
    }
  }
}

// CAA records (certificate authority authorization)
let caaResult = try await tracer.dns.query(name: "google.com", type: .caa)
for record in caaResult.records {
  if case .caa(let flags, let tag, let value) = record.data {
    print("  \(tag): \(value)")
  }
}

// HTTPS records (HTTP/3 service binding)
let httpsResult = try await tracer.dns.query(name: "cloudflare.com", type: .https)
for record in httpsResult.records {
  if case .https(let priority, let target, _) = record.data {
    print("  Priority \(priority): \(target)")
  }
}

// Supports 11 DNS record types:
// A, AAAA, PTR, TXT, MX, NS, CNAME, SOA, SRV, CAA, HTTPS

// Streaming Traceroute API
// Get hops as they arrive (not sorted by TTL)
for try await hop in tracer.traceStream(to: "1.1.1.1") {
    if let ip = hop.ipAddress, let rtt = hop.rtt {
        print("TTL \(hop.ttl): \(ip) - \(String(format: "%.1f", rtt * 1000))ms")
    } else {
        print("TTL \(hop.ttl): *")
    }
    if hop.reachedDestination {
        print("  <-- destination")
    }
}

// With custom config
let streamConfig = StreamingTraceConfig(
    probeTimeout: 15.0,    // Total timeout
    retryAfter: 5.0,       // Retry unresponsive TTLs after 5s
    emitTimeouts: true,    // Emit timeout placeholders at end
    maxHops: 30
)
for try await hop in tracer.traceStream(to: "example.com", config: streamConfig) {
    // Process each hop as it arrives
}
```

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
```

### Traceroute (default command)
```bash
.build/release/swift-ftr trace example.com -m 40 -w 1.0
```

Options:
- `-m, --max-hops N`: Max TTL/hops to probe (default 40)
- `-w, --timeout SEC`: Overall wait after sending probes (default 1.0)
- `-i, --interface IFACE`: Use a BSD interface name reported by the operating system
- `-s, --source IP`: Bind to specific source IP address
- `-p, --payload-size N`: ICMP payload size in bytes (default 56)
- `--json`: Emit JSON with ASN categories and public IP
- `--no-rdns`: Disable reverse DNS lookups
- `--public-ip IP`: Override public IP (bypasses STUN)
- `--verbose`: Enable debug logging

### Ping
```bash
.build/release/swift-ftr ping 1.1.1.1 -c 10 -i 1.0
```

Options:
- `-c, --count N`: Number of pings (default 5)
- `-i, --interval SEC`: Interval between pings (default 1.0)
- `-t, --timeout SEC`: Timeout per ping (default 2.0)
- `--payload-size N`: ICMP payload size (default 56)
- `--interface IFACE`: Network interface to use
- `--json`: Output JSON format

### Multipath Discovery
```bash
.build/release/swift-ftr multipath 8.8.8.8 --flows 8 --max-paths 16
```

Options:
- `--flows N`: Number of flow variations (default 8)
- `--max-paths N`: Max unique paths to find (default 16)
- `--early-stop N`: Stop after N flows with no new paths (default 3)
- `-m, --max-hops N`: Max TTL to probe (default 40)
- `-t, --timeout SEC`: Timeout per flow in seconds (default 2.0)
- `--json`: Output JSON format

### Streaming Traceroute
```bash
.build/release/swift-ftr stream 1.1.1.1 -m 30 --timeout 15
```

Options:
- `-m, --max-hops N`: Max TTL to probe (default 30)
- `-t, --timeout SEC`: Total timeout for trace (default 10.0)
- `--retry-after SEC`: Retry unresponsive TTLs after this time (default 4.0)
- `--no-retry`: Disable automatic retry of unresponsive TTLs

Configuration and Flags
-----------------------
- Prefer `SwiftFTRConfig(publicIP: ...)` to bypass STUN discovery when desired.
- Pass a name returned by `NetworkInterfaceDiscovery` to `SwiftFTRConfig(interface:)` to bind a specific interface.
- Use `SwiftFTRConfig(sourceIP: "192.168.1.100")` to bind to a specific source IP.
- CLI: `--public-ip x.y.z.w`, `--verbose`, `--payload-size`, `--max-hops`, `--timeout`, `-i/--interface`, `-s/--source`.

Design Details
--------------
- Socket: ICMP `SOCK_DGRAM` on macOS (no privileges) with `O_NONBLOCK` and `DispatchSource` readiness handling.
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
- [`docs/IPV6.md`](docs/IPV6.md) — sequenced plan and architectural contracts for IPv6 feature parity (ping, traceroute, probes, STUN, ASN).

Generate and view the docs:

- Xcode: Product → Build Documentation (or use the Documentation sidebar).
- SwiftPM plugin (Xcode 16.4+/Swift 6.1+):
  ```bash
  swift package --allow-writing-to-directory docc \
    generate-documentation --target SwiftFTR \
    --output-path docc --transform-for-static-hosting --hosting-base-path SwiftFTR
  open docc/index.html
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
