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
- Dual-stack: ping, traceroute, TCP/UDP probes, and `getPublicIPs()` support IPv4 and IPv6. v4 literals transparently work on v6-only NAT64 networks via system synthesis.
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
   - Enrich classified traces with a configured value or cached IPv4 discovery (STUN, then DNS fallback). The separate `getPublicIPs()` call returns uncached STUN results for v4 and v6 in parallel.
   - Batch‑resolve ASNs. By default (`.hybrid(.embedded)`) the embedded swift-ip2asn database answers first and Team Cymru DNS (`origin.asn.cymru.com` for v4, `origin6.asn.cymru.com` for v6) covers only addresses the database misses; `asnResolverStrategy` selects DNS-only, embedded-only, or a remote database instead. Apply heuristics for PRIVATE and CGNAT ranges.
   - Label each hop as LOCAL, ISP, TRANSIT, or DESTINATION and "hole‑fill" missing stretches between identical segments.

How Fast Is It?
---------------
Classic traceroute often probes sequentially and waits per hop; SwiftFTR probes all hops in one burst and waits once.

- Latency model: Probe transmission and result processing scale with `maxHops`, but all replies share one receive deadline instead of waiting once per hop. The ICMP receive phase is bounded by `maxWaitMs`; hostname resolution and optional rDNS, STUN, and ASN classification perform separate I/O.
- Efficient I/O: Single socket, kqueue-backed `DispatchSourceRead`, reused receive buffer, and monotonic timing reduce overhead and jitter.

If you need tighter runs, lower `maxWaitMs` (for example, to `500`) or cap `maxHops` (for example, at `20`). You can also tune `payloadSize` in advanced scenarios.

Requirements
------------
- Swift 6.1+ (requires Xcode 16.4 or later)
- macOS 13+
- Core ping, traceroute, TCP, and UDP paths support IPv4 and IPv6 (including ICMPv6 Echo per RFC 4443). Multipath discovery remains IPv4-only. On Linux, typical ICMP requires raw sockets (root/CAP_NET_RAW); SwiftFTR targets macOS's ICMP datagram behavior.

Install (SwiftPM)
-----------------
- Xcode: File → Add Package → enter this repository URL → select the `SwiftFTR` product.
- `Package.swift`:

  ```swift
  dependencies: [
      .package(url: "https://github.com/Network-Weather/SwiftFTR.git", from: "0.17.1")
  ],
  targets: [
      .target(name: "YourTarget", dependencies: ["SwiftFTR"])
  ]
  ```

Upgrading
---------
Upgrades within 0.14 through 0.17 are additive at the source level, but read each release's
"Behavior changes" in [CHANGELOG.md](CHANGELOG.md). In particular, since 0.17.0 the default
`asnResolverStrategy` is `.hybrid(.embedded)` rather than `.dns`, so classified traces load the
embedded ASN database and need no network for most lookups; pass `asnResolverStrategy: .dns` to
keep the old behavior.

From 0.13, read the published [Migrating to SwiftFTR 0.14](https://swiftftr.networkweather.com/documentation/swiftftr/migratingto014/)
guide and the [0.14 changelog](CHANGELOG.md#0140--2026-07-22) before updating. Existing direct call
sites remain source-compatible, but exhaustive `DNSError` switches, HTTP timing assumptions,
route-bound bufferbloat tests, and interface classification may require small changes.

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
- Parallel ICMP/ICMPv6 probing with a single receive deadline for all hops
- Streaming API with real-time hop updates via `AsyncThrowingStream`
- ASN-based hop classification: LOCAL, ISP, TRANSIT, VPN, DESTINATION
- v6 hops get full ASN annotations via Team Cymru `origin6.asn.cymru.com` or the embedded swift-ip2asn database
- VPN-aware classification of tunnel-local and exit-side path segments
- Automatic rDNS lookups with 24-hour caching

**Dual-stack IPv4 / IPv6**
- Ping, traceroute, TCP probes, and UDP probes accept v4 literals, v6 literals, and hostnames through the same entry points
- `PreferredFamily { .v4, .v6, .auto }` lets callers force a family; default `.auto` lets the OS decide
- v4 literals on v6-only NAT64 networks transparently use the gateway's synthesized v6 mapping (RFC 6147)
- IPv6 formatting uses `inet_ntop`; link-local paths retain a `%zone` suffix when macOS supplies a scope ID
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
- Traceroute and ping honor global interface/source-address settings; ping also supports a per-operation override
- TCP, UDP, and DNS probes expose operation-level binding; HTTP/HTTPS probes follow system routing
- Supported socket-backed diagnostics accept family-matched IPv4 or IPv6 source addresses (link-local `%zone` honored)
- Bufferbloat accepts binding only for baseline-only latency (`loadDuration: 0`); loaded tests reject any effective binding before network work

**Public IP Discovery**
- `getPublicIPs()` is an uncached, STUN-only call that runs IPv4 and IPv6 in parallel and returns whichever families succeeded
- `discoverPublicIPWithHostname()` performs fresh IPv4 discovery on each call: STUN first, then an unbound Akamai DNS-whoami fallback, plus optional system-routed rDNS
- Classified trace honors `SwiftFTRConfig.publicIP`; otherwise its `SwiftFTR` actor caches discovered IPv4 until invalidation. Multipath also honors the override and reuses an actor-cached value when available

**Architecture**
- Actor-based design for thread safety
- Works from any actor or task (no `@MainActor` required)
- Network change API for cache invalidation and trace cancellation

Use It as a Library
-------------------
```swift
import SwiftFTR

// Configure defaults for supported socket-backed diagnostics
let config = SwiftFTRConfig(
    maxHops: 40,        // Max TTL to probe
    maxWaitMs: 1000,    // Timeout in milliseconds
    payloadSize: 56,    // ICMP payload size
    publicIP: nil,      // Auto-detect for classified trace/multipath enrichment
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

// IPv6 works through the same entry point — family auto-detected from the target.
let v6Result = try await tracer.trace(to: "2606:4700:4700::1111")
// Or force a family explicitly:
let v6Config = SwiftFTRConfig(preferredFamily: .v6)
let alwaysV6 = SwiftFTR(config: v6Config)
let googleTrace = try await alwaysV6.trace(to: "google.com")  // prefers AAAA if available

// Dual-stack public-IP discovery:
let publicIPs = await getPublicIPs()
print("v4: \(publicIPs.v4 ?? "n/a"), v6: \(publicIPs.v6 ?? "n/a")")

// With ASN classification
let classified = try await tracer.traceClassified(to: "www.example.com")
for hop in classified.hops {
    print(hop.ttl, hop.ip ?? "*", hop.category.rawValue, hop.asn ?? 0, hop.asName ?? "")
    // Optional hostname from reverse DNS
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

// Per-operation interface binding with names selected by your UI or caller.
func compareRoutes(primaryBSDName: String, alternateBSDName: String) async throws {
    let snapshot = await NetworkInterfaceDiscovery().discover()
    guard let primaryInterface = snapshot.interfaces.first(where: { $0.name == primaryBSDName }),
          let alternateInterface = snapshot.interfaces.first(where: { $0.name == alternateBSDName }),
          primaryInterface.isUp, alternateInterface.isUp
    else {
        return
    }

    let boundTracer = SwiftFTR(config: SwiftFTRConfig(interface: primaryInterface.name))

    // The first call inherits the global selection; the second overrides it.
    async let primary = boundTracer.ping(to: "1.1.1.1")
    async let alternate = boundTracer.ping(
        to: "1.1.1.1",
        config: PingConfig(interface: alternateInterface.name)
    )
    let (primaryResult, alternateResult) = try await (primary, alternate)
    print("Primary loss: \(Int(primaryResult.statistics.packetLoss * 100))%")
    print("Alternate loss: \(Int(alternateResult.statistics.packetLoss * 100))%")
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
- **Thread Safety**: The `SwiftFTR` actor protects shared state, while operations designed for parallel use keep independent per-operation state. Its async API can be called from any actor or task.
- **Public IP enrichment**: `SwiftFTRConfig(publicIP:)` overrides discovery for classified trace and multipath enrichment; it does not change `getPublicIPs()` or `discoverPublicIPWithHostname()`.
- **ASN Lookups**: `traceClassified` resolves ASNs with `SwiftFTRConfig.asnResolverStrategy`, which defaults to `.hybrid(.embedded)`: the embedded database loaded once per process (about 15 MB), with Team Cymru DNS only for addresses it does not cover. Use `.dns` for DNS-only lookups, `.embedded` for no network at all, or `.remote(bundledPath:url:)` for an updatable database. Results are cached in memory.
- **Timeout Behavior**: `maxWaitMs` bounds the ICMP receive phase of `trace`. Resolution and optional STUN, rDNS, or ASN enrichment have their own I/O and timeout behavior.
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
.build/release/swift-ftr trace example.com -m 40 -t 1.0
```

Options:
- `-m, --max-hops N`: Max TTL/hops to probe (default 40)
- `-t, --timeout SEC`: Overall wait after sending probes (default 1.0)
- `-i, --interface IFACE`: Use an exact BSD name reported by `swift-ftr interfaces`
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
- `-I, --interface IFACE`: Network interface to use
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

### Other subcommands
- `probe tcp|udp|http|dns ...`: one-shot reachability probes (for example `swift-ftr probe tcp example.com 443`, `swift-ftr probe dns 1.1.1.1 example.com`)
- `bufferbloat`: latency under load (`--target`, `--baseline`, `--load`, `--load-type`, `--streams`, `--no-rpm`, `--json`)
- `interfaces`: list network interfaces and the exact BSD names that `-i/--interface` accepts (`--vpn-only`, `--physical-only`, `--include-inactive`, `--json`)

Every subcommand prints its full option list with `--help`.

Configuration and Flags
-----------------------
- Use `SwiftFTRConfig(publicIP: ...)` to bypass discovery for classified trace and multipath enrichment only; the standalone public-IP APIs ignore this value.
- Validate an exact caller-selected name and family-matched address against `NetworkInterfaceDiscovery`; never infer a physical adapter's role from its BSD-name suffix.
- Traceroute, streaming/classified trace, and IPv4-only multipath use the global `SwiftFTRConfig` binding. Ping supports IPv4 and IPv6; each non-`nil` operation-level binding independently overrides its global counterpart.
- Actor DNS query helpers inherit globals unless the call overrides them. The numeric DNS server—not A versus AAAA record type—selects the IPv4 or IPv6 transport. Standalone DNS query functions and DNS/TCP/UDP probes use only their function arguments or operation config.
- `getPublicIPs()` accepts operation-level bindings for parallel IPv4/IPv6 STUN. `discoverPublicIPWithHostname()` applies globals to its IPv4 STUN attempt, but its DNS-whoami fallback and rDNS lookup use system routing.
- Bufferbloat honors route binding only for baseline latency (`loadDuration: 0`); loaded tests reject effective binding.
- HTTP/HTTPS probes use URLSession and do not support either binding option.
- Socket binding controls the documented probe sockets only. Hostname resolution, system rDNS, DNS-whoami fallback, and Team Cymru ASN lookups are not bound by these settings.
- CLI: `--public-ip x.y.z.w`, `--verbose`, `--payload-size`, `--max-hops`, `--timeout`, `-i/--interface`, `-s/--source`.

Design Details
--------------
- Socket: ICMP `SOCK_DGRAM` on macOS (no privileges) with `O_NONBLOCK` and `DispatchSource` readiness handling.
- Probing: One Echo Request per TTL; identifier is constant per run, sequence equals TTL for easy correlation.
- Matching: Echo Reply and Time Exceeded handlers pull out embedded id/seq from the packet to map to the original probe.
- Timing: RTT is measured with `CLOCK_MONOTONIC` to avoid wall‑clock jumps.
- Classification: ASN lookups from the embedded database with Team Cymru DNS fallback by default, with caching; PRIVATE and CGNAT ranges are recognized without lookups; missing stretches are “hole‑filled” between identical segment classes.

Testing
-------
- Unit tests: `swift test`. Some suites use the live network; for an offline, deterministic run set both gates: `SKIP_NETWORK_TESTS=1 PTR_SKIP_STUN=1 swift test -c debug`. See [TESTING.md](docs/development/TESTING.md).
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
API reference is generated by DocC from `Sources/SwiftFTR/SwiftFTR.docc` and published at
[swiftftr.networkweather.com](https://swiftftr.networkweather.com/). Design records,
investigations and plans under `docs/` are indexed in [docs/README.md](docs/README.md), and
contributor and release-process notes in [docs/development/README.md](docs/development/README.md).
Every tracked Markdown file has exactly one entry in one of these indexes; check with
`orphan-audit` from the repo root.

### Project
- [Changelog](CHANGELOG.md): release-by-release notes of new API, behavior changes, fixes and dependency changes, newest first. (updated 2026-11-21; update when: a PR merges to `main` or a release is cut)
- [Roadmap](ROADMAP.md): forward-looking work, stack-ranked by priority, with the goal and constraints of each item. (updated 2026-11-21; update when: a PR completes or reprioritizes a roadmap item)
- [Benchmarks](BENCHMARKS.md): measured ping throughput, embedded ASN database load cost and memory, and ASN resolver strategy timings, each with its release, date and command. (updated 2026-11-21; update when: a release changes the ASN database, resolver defaults or the ping I/O path, or a benchmark is re-run)
- [Contributing](CONTRIBUTING.md): development setup, formatting, testing, documentation, commit style and the maintainer release checklist. (updated 2026-11-21; update when: the build, test, CI or release procedure changes)
- [Security policy](SECURITY.md): supported versions, how to report a vulnerability, response timeline and the library's security-relevant design choices. (updated 2026-11-21; update when: a release line is added or dropped from support, or the reporting channel changes)
- [Code of Conduct](CODE_OF_CONDUCT.md): Contributor Covenant 2.0 terms and the enforcement contact. (updated 2025-09-08; update when: the enforcement contact or Covenant version changes)
- [Agent guidance](CLAUDE.md): commands, architecture overview, environment variables, conventions and merge/release duties for coding agents working in this repo. (updated 2026-11-21; update when: a command, environment variable, core component or repo convention changes)

### API guides (DocC articles)
- [SwiftFTR](Sources/SwiftFTR/SwiftFTR.docc/SwiftFTR.md): DocC landing page with the feature overview, quick samples, configuration and network-change controls, and the Topics map of the public API. (updated 2026-11-21; update when: a public type or `SwiftFTR` method is added or removed, or a `SwiftFTRConfig` default changes)
- [Tracing](Sources/SwiftFTR/SwiftFTR.docc/Tracing.md): basic and classified traceroute, per-trace options, hop outcomes and enrichment bounds. (updated 2026-11-21; update when: `trace` or `traceClassified` signatures, `TraceOptions`, or ASN and enrichment defaults change)
- [Streaming traceroute](Sources/SwiftFTR/SwiftFTR.docc/StreamingTrace.md): `traceStream` usage, `StreamingTraceConfig` defaults, retry and early-completion behavior. (updated 2026-11-21; update when: `StreamingTraceConfig` or the emission rules for streaming hops change)
- [Ping](Sources/SwiftFTR/SwiftFTR.docc/Ping.md): `ping(to:config:)` usage, statistics semantics and concurrent pinging. (updated 2026-11-21; update when: `PingConfig`, `PingStatistics` or ping concurrency behavior changes)
- [Probing](Sources/SwiftFTR/SwiftFTR.docc/Probing.md): the TCP, UDP, HTTP and DNS probe functions, their results, errors and binding behavior. (updated 2026-11-21; update when: a probe function, config or result type changes, or HTTP probes gain route binding)
- [Bufferbloat](Sources/SwiftFTR/SwiftFTR.docc/Bufferbloat.md): `testBufferbloat` usage, load generation, grading and RPM calculation, video-call severity and baseline-only bound mode. (updated 2026-11-21; update when: grading thresholds, the RPM method, default load endpoints or `BufferbloatConfig` change)
- [Multipath](Sources/SwiftFTR/SwiftFTR.docc/Multipath.md): `discoverPaths` usage, topology analysis, ICMP-versus-UDP limitations and the IPv4-only restriction. (updated 2026-11-21; update when: multipath gains UDP or IPv6 support, or `MultipathConfig` or `NetworkTopology` change)
- [Interface binding](Sources/SwiftFTR/SwiftFTR.docc/InterfaceBinding.md): which operations honor interface and source-address binding, resolution order and binding errors. (updated 2026-11-21; update when: an operation gains or loses binding support, or HTTP probes become bindable)
- [Migrating to 0.14](Sources/SwiftFTR/SwiftFTR.docc/MigratingTo014.md): upgrade guide from 0.13 to 0.14 covering new `DNSError` cases, behavior and CLI changes, plus runtime changes in later releases. (updated 2026-11-21; update when: a later release changes a behavior it describes, or 0.13 adopters no longer need it)

### Reference and examples
- [Examples](docs/guides/EXAMPLES.md): worked Swift examples for each feature area, including trace, hop outcomes, configuration, network-change lifecycle, streaming, DNS, ping, multipath, bufferbloat, SwiftUI, concurrency, errors and ASN strategies. (updated 2026-11-21; update when: a public API used in a sample changes shape, or a release adds a feature area with no example)
- [Condensed API reference](docs/reference/AI_REFERENCE.md): public types, method signatures, defaults, enum and error cases and CLI flags with short snippets, sized to load whole into an agent's context. (updated 2026-11-21; update when: a release changes a public signature, default, enum case or CLI flag)

### Tools and fixtures
- [hop-monitor](Sources/hop-monitor/README.md): the demo CLI that traces a path and then pings every hop continuously, with its output, statistics and limits. (updated 2026-11-21; update when: `Sources/hop-monitor/main.swift` changes its arguments, limits or statistics)
- [Integration package](IntegrationPackage/README.md): the external-consumer package that imports SwiftFTR by path, what it checks and how CI builds and runs it. (updated 2026-11-21; update when: the package's checks change or a workflow stops building or running it)

### GitHub configuration
- [Workflows](.github/WORKFLOWS.md): what each GitHub Actions workflow triggers on, runs and produces, and how they depend on each other. (updated 2026-11-21; update when: a file under `.github/workflows/` is added, removed or changes its triggers or jobs)
- [Pull request template](.github/pull_request_template.md): the summary, change type, testing commands and checklist every PR body starts from. (updated 2026-07-21; update when: the required pre-merge checks change)
- [Bug report template](.github/ISSUE_TEMPLATE/bug_report.md): the environment, reproduction and log fields requested for bug issues. (updated 2026-11-21; update when: the CLI's options or the information needed to triage a bug change)
- [Feature request template](.github/ISSUE_TEMPLATE/feature_request.md): the motivation, proposal and alternatives fields requested for feature issues. (updated 2025-09-08; update when: the project changes how it takes feature proposals)

Generate and view the docs:

- Xcode: Product → Build Documentation (or use the Documentation sidebar).
- SwiftPM plugin (Xcode 16.4+/Swift 6.1+):
  ```bash
  swift package --allow-writing-to-directory docc \
    generate-documentation --target SwiftFTR \
    --output-path docc --transform-for-static-hosting \
    --warnings-as-errors
  open docc/index.html
  ```

Formatting & Hooks
------------------
- Lint formatting locally before pushing:
  ```bash
  swift format lint --strict -r Sources Tests
  ```
- Optional: install repo hooks so pushes fail on formatting issues:
  ```bash
  git config core.hooksPath .githooks
  ```

Prior Art & Related Tools
-------------------------

SwiftFTR builds on decades of traceroute technique, and other tools may fit your
needs better than an embeddable Swift library.

Lineage and techniques:

- Van Jacobson's original `traceroute` (1987) established TTL-stepped probing.
- [Paris traceroute](https://paris-traceroute.net) (Augustin et al., IMC 2006)
  showed that holding flow-identifying header fields constant keeps probes on a
  single path under ECMP load balancing, and that varying them enumerates paths.
- [Dublin Traceroute](https://dublin-traceroute.net) (Andrea Barberio) extended
  Paris-style probing with NAT detection. SwiftFTR's multipath discovery
  (`discoverPaths`) is modeled on its approach.
- Unprivileged operation relies on Darwin's ICMP datagram sockets
  (`SOCK_DGRAM` + `IPPROTO_ICMP`/`IPPROTO_ICMPV6`), which permit echo probes
  without root.
- Public-IP discovery speaks STUN
  ([RFC 8489](https://datatracker.ietf.org/doc/html/rfc8489)).

Data and services:

- Default ASN classification uses the database embedded in
  [swift-ip2asn](https://github.com/network-weather/swift-ip2asn), built from
  [iptoasn.com](https://iptoasn.com) data, and falls back to [Team Cymru's
  IP-to-ASN mapping service](https://www.team-cymru.com/ip-asn-mapping) over DNS
  for addresses the database does not cover.

Peer tools doing analogous work:

- [mtr](https://github.com/traviscross/mtr) — combined traceroute and
  continuous ping monitoring (C, cross-platform).
- [trippy](https://github.com/fujiapple852/trippy) — traceroute TUI and
  analysis (Rust).
- [scamper](https://www.caida.org/catalog/software/scamper/) — CAIDA's
  research-grade Internet measurement tool.
- [dublin-traceroute](https://github.com/insomniacslk/dublin-traceroute) — the
  C++/Python original.
- [ftr](https://github.com/dweekly/ftr) — sibling project: parallel traceroute
  as a Rust CLI.

SwiftFTR's niche among these: an embeddable Swift 6 library — actor-based async
API, unprivileged sockets, and classification/enrichment (ASN, reverse DNS,
VPN/segment labeling) for applications rather than terminals.

License
-------
MIT — see LICENSE.

Versioning & Releases
---------------------
- Semantic Versioning. See CHANGELOG.md for release notes.
- To consume via SwiftPM, use the `0.17.1` tag or a later compatible release.

Contributing
------------
See CONTRIBUTING.md for development setup, formatting, testing, docs, and release guidance.

Code of Conduct
---------------
This project adheres to a Code of Conduct. By participating, you agree to abide by its terms. See CODE_OF_CONDUCT.md.
