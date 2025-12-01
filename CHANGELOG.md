Changelog
=========

All notable changes to this project are documented here. This project follows Semantic Versioning.

0.10.0 — 2025-12-01
-------------------
### Major Features

**VPN-Aware Trace Classification**
- NEW: VPN interface detection and classification for accurate path analysis
- NEW: `HopCategory.vpn` for all hops through a VPN tunnel
- NEW: `VPNContext` struct for passing VPN state to classification
- NEW: Automatic VPN context detection from interface name (utun*, ipsec*, ppp*, etc.)
- NEW: Tailscale hostname detection via `.ts.net` suffix

**Network Interface Discovery**
- NEW: `NetworkInterfaceDiscovery` actor for enumerating system network interfaces
- NEW: `NetworkInterface` struct with type, addresses, MTU, and status
- NEW: `NetworkInterfaceSnapshot` with filtered views (physical, VPN, active)
- NEW: `InterfaceType` enum: wifi, ethernet, vpnTunnel, vpnIPSec, vpnPPP, bridge, loopback, other
- NEW: CLI `swift-ftr interfaces` subcommand with `--json`, `--vpn-only`, `--physical-only` options

**Classification Improvements**
- CGNAT IPs (100.64.0.0/10) classified as VPN when tracing through VPN interface
- All private IPs after VPN hops classified as VPN (exit node LAN is part of VPN solution)
- Tailscale hostnames (.ts.net) always classified as VPN
- Simple category model: VPN segment covers everything until traffic exits to the public internet

**Use Cases**
- WFH diagnostics: Check BOTH VPN path AND direct residential path
- Multi-interface monitoring: Enumerate WiFi, Ethernet, and VPN interfaces separately
- Tailscale exit node tracing: Correctly identify VPN hops vs ISP CGNAT

**Usage Example**:
```swift
let tracer = SwiftFTR()

// Discover available interfaces
let snapshot = await tracer.discoverInterfaces()
for iface in snapshot.vpnInterfaces {
  print("\(iface.name): \(iface.ipv4Addresses)")
}

// Trace with automatic VPN detection (uses config.interface)
let trace = try await tracer.traceClassified(to: "example.com")

// Or provide explicit VPN context
let vpnContext = VPNContext(traceInterface: "utun3", isVPNTrace: true, vpnLocalIPs: [])
let trace = try await tracer.traceClassified(to: "example.com", vpnContext: vpnContext)

// VPN hops include tunnel endpoint + exit node's local network
for hop in trace.hops where hop.category == .vpn {
  print("VPN: \(hop.hostname ?? hop.ip ?? "?")")
}
```

### Defaults
- CHANGED: Default `maxHops` increased from 30 to 40 (parallel probes make this essentially free)

### Testing
- 22 new tests for network interface discovery and classification
- 7 new tests for VPN-aware trace classification
- All 143 tests passing

### Compatibility
- No breaking changes to existing APIs
- New `vpnContext` parameter in `traceClassified()` is optional with default `nil`
- VPN context auto-detected when `SwiftFTRConfig.interface` is set to a VPN interface

0.9.0 — 2025-11-24
------------------
### Major Features

**Offline ASN Resolution**
- NEW: Local IP-to-ASN lookups via Swift-IP2ASN integration (no network required)
- Configurable via `SwiftFTRConfig(asnResolverStrategy:)`:
  - `.dns` (default): Team Cymru DNS WHOIS queries (backward compatible)
  - `.embedded`: Use bundled ~3.4MB database (ships with Swift-IP2ASN)
  - `.remote(bundledPath:url:)`: Download database with bundled fallback for mobile apps
  - `.hybrid(source:fallbackTimeout:)`: Local DB first, DNS fallback for missing IPs
- New `LocalASNResolver` actor with lazy loading and task deduplication
- New `HybridASNResolver` struct for best of both worlds
- `preloadASNDatabase()` API to eliminate first-lookup latency

**Performance Characteristics** (benchmarked on M1 Mac):
| Strategy | Load Time | Lookup (10 IPs) | Memory | Notes |
|----------|-----------|-----------------|--------|-------|
| `.dns` | N/A | 2.7ms cold | +1.4 MB | Network per query |
| `.embedded` | 51ms | 0.07ms | +30 MB | 40x faster lookups |
| `.hybrid` | 48ms | 0.05ms | +30 MB | Best coverage |
| `.remote` | 332ms (download) | 0.02ms | +30 MB | One-time download |

**Tradeoffs**:
- Local DB adds ~30MB memory but provides 40x faster lookups
- DNS misses some IPs (no Cymru record); local DB has 100% coverage
- For memory-constrained apps, use `.dns` (default)

**Usage Example**:
```swift
// Offline mode - fast, private, no network
let config = SwiftFTRConfig(asnResolverStrategy: .embedded)
let tracer = SwiftFTR(config: config)

// Hybrid mode - local DB with DNS fallback
let config = SwiftFTRConfig(asnResolverStrategy: .hybrid(.embedded, fallbackTimeout: 1.0))
let tracer = SwiftFTR(config: config)

// Mobile app - download database with bundled fallback
let bundlePath = Bundle.main.path(forResource: "ip2asn", ofType: "ultra")
let config = SwiftFTRConfig(asnResolverStrategy: .remote(bundledPath: bundlePath, url: nil))
let tracer = SwiftFTR(config: config)
await tracer.preloadASNDatabase() // Preload for instant lookups
```

### Dependencies
- Added Swift-IP2ASN v0.2.1 for local ASN database support

### Testing
- 10 new tests for LocalASNResolver and HybridASNResolver
- Tests cover embedded DB lookups, performance, preload, IP filtering, and config strategies
- Fixed flaky ActorSchedulingTests: changed from absolute timing thresholds to relative comparison (detached vs actor-bound) which is robust under parallel test execution
- All 122 tests passing (verified with 10 consecutive runs)

0.8.1 — 2025-11-24
------------------
### Performance Improvements

**Parallel ASN Resolution**
- `CymruDNSResolver.resolve()` now executes DNS queries in parallel with bounded concurrency (max 8)
- Two-phase resolution: parallel origin ASN lookups, then deduplicated AS name lookups
- **Performance**: 5-10x faster ASN resolution for typical traces (40s worst case → 5s)
- Uses actor-based semaphore for rate limiting to avoid overwhelming DNS servers
- Blocking DNS calls wrapped in `Task.detached` to prevent cooperative thread pool starvation

**Improved Reverse DNS Handling**
- `RDNSCache` now uses `runDetachedBlockingIO` for consistency with other blocking I/O patterns

### Documentation

**Cleanup**
- Consolidated AI assistant context files (AGENTS.md, GEMINI.md) into CLAUDE.md
- Removed obsolete planning documents
- Updated SECURITY.md with current supported versions (0.7.x, 0.8.x)

0.8.0 — 2025-11-09
------------------
### What's New

**Massive Ping Scalability**
- Refactored `ping()` to use event-driven I/O (kqueue/epoll) via `DispatchSource`
- Eliminated thread starvation issues when running many concurrent pings
- **Performance**: 35x throughput improvement (573 pings/sec vs 16 pings/sec in v0.7.0)
- **Efficiency**: Efficient resource usage (~17KB per ping) with zero thread starvation
- Zero external dependencies (uses `libdispatch` standard library)
- Fully thread-safe and robust against race conditions

**DNS Queries with Rich Metadata**
- Query DNS records with `tracer.dns.a()`, `tracer.dns.aaaa()`, `tracer.dns.reverseIPv4()`
- Get structured results with TTL, RTT (0.1ms precision), server, and timestamp
- Support for 11 record types: A, AAAA, PTR, TXT, MX, NS, CNAME, SOA, SRV, CAA, HTTPS
- Query your gateway for its hostname to detect network devices (UniFi, NETGEAR, cable modems)

**Example**:
```swift
let tracer = SwiftFTR()

// Get IPv4 addresses with metadata
let result = try await tracer.dns.a(hostname: "google.com")
print("RTT: \(result.rttMs)ms")
for record in result.records {
  if case .ipv4(let addr) = record.data {
    print("\(addr) (TTL: \(record.ttl)s)")
  }
}

// Reverse DNS your gateway
let ptr = try await tracer.dns.reverseIPv4(ip: "10.1.10.1")
// Might return: "Docsis-Gateway.hsd1.ca.comcast.net"

// Check mail servers
let mx = try await tracer.dns.query(name: "gmail.com", type: .mx)
for record in mx.records {
  if case .mx(let priority, let exchange) = record.data {
    print("Priority \(priority): \(exchange)")
  }
}

// Certificate authority authorization
let caa = try await tracer.dns.query(name: "google.com", type: .caa)
// Returns which CAs can issue certificates

// HTTP/3 service discovery
let https = try await tracer.dns.query(name: "cloudflare.com", type: .https)
// Returns ALPN protocols and connection hints
```

### Migration from 0.7.0

Since 0.7.1 was never shipped, this is the first DNS API for SwiftFTR.

### What You Get
- **No subprocesses**: Pure Swift DNS queries, no `Process()` or `/usr/bin/host` hacks
- **High precision**: 0.1ms RTT measurement using `mach_absolute_time()`
- **Full metadata**: TTL, timestamps, record priorities, not just bare IP strings
- **Modern records**: CAA for certificate authorities, HTTPS for HTTP/3 discovery
- **Type safety**: Structured `DNSRecordData` enum, not string parsing

0.7.0 — 2025-11-05
------------------
### Major Features
- **NEW**: Per-operation interface and source IP binding
  - Added `interface` and `sourceIP` parameters to `PingConfig`, `TCPProbeConfig`, `DNSProbeConfig`, and `BufferbloatConfig`
  - Operation-level config overrides global `SwiftFTRConfig` settings
  - Maximum flexibility for multi-interface monitoring (WiFi + Ethernet + VPN scenarios)
  - **Use case**: NWX hop monitoring can now bind pings to specific interface per-operation
  - **Benefits**: Eliminates 83% packet loss during interface transitions
  - **API**: `ping(to: "1.1.1.1", config: PingConfig(interface: "en14"))` - per-operation override
  - **Backward compatible**: nil values default to global SwiftFTRConfig settings

### Implementation Details
- **Ping**: `PingExecutor.applyBindings()` now reads operation-level config with fallback to global
- **TCP Probe**: Added interface/source IP binding after socket creation using `IP_BOUND_IF` and `bind()`
- **DNS Probe**: Added interface/source IP binding after socket creation for UDP DNS queries
- **Bufferbloat**: Passes interface/sourceIP through to underlying ping operations
- **Override semantics**: Operation config takes precedence, then global config, then system default
- **Platform support**: macOS uses `IP_BOUND_IF`, returns clear error on unsupported platforms

### Breaking Changes
- **BREAKING**: `ASNResolver` protocol is now async
  - `func resolve(ipv4Addrs:timeout:)` now requires `async throws`
  - All custom ASNResolver implementations must be updated
  - `TraceClassifier.classify()` is now async

### Performance Improvements
- **PERFORMANCE**: Multipath flow discovery now runs in parallel
  - Batched parallel execution using `withThrowingTaskGroup`
  - **5x speedup**: 10 flows complete in 1.20s vs 6.06s (sequential)
  - Maintains early stopping support with batch size of 5
  - 30% improvement in multipath performance tests (10.4s → 7.1s)

### Refactoring
- **MODERNIZED**: ASN cache converted to Swift 6 actor-based architecture
  - Replaced `_ASNMemoryCache` class+NSLock with actor
  - Eliminated `@unchecked Sendable` patterns
  - Compiler-enforced thread safety throughout ASN resolution pipeline
  - No performance impact (safety improvement only)

### Testing
- **ENHANCED**: Added concurrency bottleneck reproduction tests
  - Test suite to measure and verify concurrency improvements
  - Baseline metrics documented in `docs/development/Concurrency-Bottleneck-Baseline.md`

### Documentation
- Updated API reference with async signatures
- Updated examples for async ASNResolver implementations
- Documented concurrency modernization results

0.6.0 — 2025-10-14
------------------
### Major Features
- **NEW**: Multi-protocol probing for network reachability testing
  - TCP SYN probe: Tests TCP port reachability without full connection
  - UDP probe: Connected-socket approach detects ICMP Port Unreachable (no root required)
  - DNS probe: Direct DNS query testing to verify DNS server availability
  - HTTP/HTTPS probe: Web server reachability testing with any response code = success
  - All probes return structured results with RTT, error details, and response types

### Implementation Details
- **TCP Probe (`tcpProbe()`)**:
  - Non-blocking socket with `select()` for timeout handling
  - Returns success for both connection success AND RST (port reachable, connection refused)
  - Use case: Nodes that block ICMP but respond to TCP
- **UDP Probe (`udpProbe()`)**:
  - Uses connected UDP socket to receive ICMP errors via `errno`
  - No raw sockets required - works without sudo on macOS
  - Detects ICMP Port Unreachable (ECONNREFUSED) as positive signal
  - Comprehensive error handling: EAGAIN, EHOSTUNREACH, ENETUNREACH, EHOSTDOWN
  - Use case: Testing if node processes UDP traffic
- **DNS Probe (`dnsProbe()`)**:
  - Manual DNS packet construction with proper encoding
  - Returns success for ANY response (NOERROR, NXDOMAIN, SERVFAIL)
  - Timeout on no response only
  - Use case: Testing if node acts as DNS server
- **HTTP/HTTPS Probe (`httpProbe()`)**:
  - URLSession-based with configurable timeout
  - Treats any HTTP response code (200, 404, 500) as success
  - SSL/TLS errors count as reachable (certificate invalid but server responds)
  - Use case: Web servers, proxies, gateways with web UI

### Testing
- Comprehensive test suite with Swift Testing framework (not XCTest)
- Network tests gated with `SKIP_NETWORK_TESTS` for CI/CD compatibility
- Tests organized into focused suites: TCPProbeTests, UDPProbeTests, DNSProbeTests, HTTPProbeTests
- Concurrency tests verify parallel probe execution
- All tests pass locally with real network targets

### Technical Details
- All probes use async/await patterns
- No blocking I/O - probes stay fully async
- Proper timeout handling with non-blocking sockets
- Structured error types with detailed messages
- All result types are `Codable` and `Sendable` (Swift 6 compliant)

### Use Cases
- **Multi-protocol node monitoring**: Discover which protocols each network node responds to
- **ICMP-blocking nodes**: Use TCP/UDP/HTTP probes when ICMP is filtered
- **Service-specific testing**: Test DNS servers, web servers, or custom UDP services
- **Gateway detection**: Probe gateway with HTTP to fingerprint vendor/model

### Compatibility
- No breaking changes to existing traceroute API
- All new features are additive (new probe functions)
- Swift 6.1 strict concurrency compliance maintained
- Works on macOS 13+ without sudo/root privileges

0.5.3 — 2025-10-04
------------------
### Bug Fixes
- **FIXED**: Ping operations now exit immediately when all responses received
  - Removed unconditional timeout sleep that delayed returns even when all packets arrived
  - Removed unnecessary +1s deadline buffer in receiver task
  - Significant performance improvement for multi-destination monitoring (e.g., hop-monitor)
  - PingParallelismTests completion spread: 2s → 63ms

### Code Quality
- Fixed linter warnings (line length, import ordering)
- Improved test code formatting

### Testing
- **ENHANCED**: Major test coverage improvements
  - Added comprehensive Bufferbloat test suite (16 structure tests, 2 integration tests)
  - Added STUN test suite (10 error handling tests, 5 network integration tests)
  - Coverage improvements: Bufferbloat 10.5% → 84.8% (+74.3%), STUN 61.5% → 63.3% (+1.8%)
  - Overall project coverage: 73.0% → 84.7% (+11.7%)
  - All network-dependent tests now conditional via `SKIP_NETWORK_TESTS` env var
  - CI skips network tests (fast, isolated), local runs include them (comprehensive)
  - Test count: 71 → 78 tests

### Documentation
- Added concurrent ping execution examples to DocC
- Updated README with parallel ping usage pattern
- Documented 6.4x speedup performance characteristics

0.5.2 — 2025-10-03
------------------
### Performance Improvements
- **FIXED**: `ping()` now runs in parallel, not serially
  - Changed `ping()` from actor-isolated to `nonisolated` method
  - Changed internal `PingExecutor` from actor to struct
  - **Performance**: 6.4x speedup for concurrent ping operations
  - Multiple concurrent `ping()` calls now execute truly in parallel
  - Before: 20 concurrent pings would take ~7.2s (serialized)
  - After: 20 concurrent pings take ~1.1s (parallel, 54ms spread)

### Testing
- Added `PingParallelismTests` demonstrating concurrent execution with high-RTT target
- Test: 20 concurrent pings to Tanzania (360ms RTT)
- Verifies completion spread <500ms for parallel operations
- All 45 tests passing

### Technical Details
- `PingExecutor` converted to struct (no mutable state, doesn't need actor isolation)
- Each ping operation creates its own socket for true independence
- `ResponseCollector` remains actor for thread-safe response handling
- No breaking changes to public API

0.5.1 — 2025-10-02
------------------
### Major Features
- **NEW**: Bufferbloat detection with RPM scoring
  - `testBufferbloat()` method with `BufferbloatConfig` and `BufferbloatResult`
  - Measures network responsiveness under saturating load
  - Detects latency spikes that impact video call quality (Zoom/Teams)
  - A-F grading based on latency increase under load
  - RPM (Round-trips Per Minute) scoring per IETF draft-ietf-ippm-responsiveness
  - Video call impact assessment (jitter and latency thresholds)
  - Supports upload, download, and bidirectional load testing
  - CLI: `swift-ftr bufferbloat` subcommand with configurable duration and load type

### Implementation Details
- **Efficient single-session ping architecture**
  - Uses PingExecutor's multi-ping capability (one socket + one Task per phase)
  - Baseline phase: measures idle latency (default 5s)
  - Load phase: parallel TCP streams while measuring latency (default 10s)
  - Load generation: URLSession with 4 parallel upload/download streams
- **Test duration:** ~15 seconds (5s baseline + 10s load by default)
- **Grading scale:** A (<25ms), B (25-75ms), C (75-150ms), D (150-300ms), F (>300ms)
- **RPM tiers:** Excellent (>6000), Good (1000-6000), Fair (300-1000), Poor (<300)

### CLI Updates
- Added `swift-ftr bufferbloat` subcommand
  - Options: `--target`, `--baseline`, `--load`, `--load-type`, `--streams`, `--no-rpm`, `--json`
  - Human-readable output with grade, latency increase, RPM score, video call impact
  - JSON output for programmatic analysis

### Documentation
- DocC documentation for all bufferbloat APIs
- Examples demonstrating WFH network troubleshooting
- Explains video conferencing sensitivity to bufferbloat

### Testing
- All 44 existing tests pass
- Real network validation with multiple configurations
- Tested with 2s-15s durations and various load types

### Compatibility
- No breaking changes to existing APIs
- All new features are additive (bufferbloat method)
- Swift 6.1 strict concurrency compliance maintained

0.5.0 — 2025-09-29
------------------
### Major Features
- **NEW**: Ping API for ICMP echo monitoring
  - `ping()` method with `PingConfig`, `PingResult`, and `PingStatistics`
  - Single ping, multiple pings, or continuous monitoring workflows
  - Configurable count, interval, timeout, and payload size
  - Statistics: min/avg/max RTT, packet loss, standard deviation, jitter
  - CLI: `swift-ftr ping <host>` subcommand with `--count`, `--interval`, `--timeout`, `--json`
- **NEW**: Multipath discovery (Dublin Traceroute-style ECMP enumeration)
  - `discoverPaths()` method with `MultipathConfig` and `NetworkTopology` result
  - ECMP path enumeration using ICMP ID field variations
  - Smart path deduplication for intermittent hop responders
  - Early stopping when no new unique paths found (configurable threshold)
  - Utility methods: `uniqueHops()`, `commonPrefix()`, `divergencePoint()`
  - CLI: `swift-ftr multipath <host>` subcommand with `--flows`, `--max-paths`, `--early-stop`, `--json`

### Improvements
- **ENHANCED**: Flow identifier control for reproducible traces
  - Optional `flowID` parameter in `trace()` and `traceClassified()` methods
  - Stable flow identifiers enable consistent path discovery
  - Used internally by multipath discovery for ECMP enumeration

### Technical Details
- ICMP-based multipath using ICMP ID field variation (16-bit space)
- Path deduplication via signature-based comparison of hop sequences
- `NetworkTopology` struct with `Codable` support for JSON export
- Comprehensive test suite: 44 tests across 12 suites
- Integration tests validate real network behavior with ECMP targets

### Known Limitations
- **ICMP multipath may discover fewer paths than UDP-based tools**
  - Many ECMP routers do not hash ICMP ID field for load balancing
  - UDP-based tools vary destination port (5-tuple hashing)
  - Testing: ICMP found 1 path to 8.8.8.8, UDP (dublin-traceroute) found 7 paths
  - Use case: ICMP accurately reflects ping diversity, UDP reflects TCP/UDP app diversity
  - **UDP multipath support planned for v0.5.5** (high priority, see ROADMAP.md)

### Documentation
- **ENHANCED**: Updated `docs/guides/EXAMPLES.md` with v0.5.0 features
  - 4 ping examples: basic, continuous monitoring, fast reachability, concurrent
  - 6 multipath examples: basic discovery, monitoring workflow, path analysis, ECMP detection
  - Key example: Extract unique hops from multipath for monitoring (NWX use case)
  - ICMP vs UDP limitation explanation with reference to ROADMAP
- **ENHANCED**: Updated `docs/development/ROADMAP.md`
  - Added v0.5.5 UDP-based multipath discovery section (high priority)
  - Documented ICMP limitations with real-world test results
  - Implementation plan for raw UDP socket support

### CLI Updates
- Added `swift-ftr ping <host>` subcommand
  - Options: `-c/--count`, `-i/--interval`, `-t/--timeout`, `--payload-size`, `--json`
  - Human-readable and JSON output formats
- Added `swift-ftr multipath <host>` subcommand
  - Options: `--flows`, `--max-paths`, `--early-stop`, `-m/--max-hops`, `-t/--timeout`, `--json`
  - Displays discovered paths, divergence point, unique path count

### Compatibility
- No breaking changes to existing traceroute API
- All new features are additive (ping and multipath methods)
- Swift 6.1 strict concurrency compliance maintained
- All 44 tests passing (15 multipath unit, 7 multipath integration, 22 ping)

0.4.0 — 2025-09-15
------------------
### Major Features
- **NEW**: Network interface selection support
  - Specify interface via `SwiftFTRConfig(interface:)` or CLI `-i/--interface`
  - Binds both ICMP and STUN sockets to selected interface
  - Early validation with detailed error messages
  - No silent fallbacks - explicit failure if interface unavailable
- **NEW**: Source IP binding capability
  - Specify source IP via `SwiftFTRConfig(sourceIP:)` or CLI `-s/--source`
  - Precise control when interface has multiple IPs
  - Works in conjunction with interface selection
  - Validates IP format and binding capability

### Improvements
- **ENHANCED**: Context-aware hop classification
  - Fixed private IP classification after public IPs
  - ISP internal routing (10.x.x.x) now correctly identified
  - Tracks first public hop and ASN context
  - Better handling of CGNAT and ISP infrastructure
- **ENHANCED**: Error reporting with OS-level details
  - All binding errors include errno values
  - Contextual error messages for troubleshooting
  - Interface validation errors provide suggestions
  - Source IP errors explain common causes

### Technical Details
- Uses `IP_BOUND_IF` socket option on macOS for interface binding
- Uses `bind()` system call for source IP selection
- Interface names converted via `if_nametoindex()`
- Both ICMP and STUN sockets honor interface/IP selection

### CLI Updates
- Added `-i/--interface` parameter (e.g., `-i en0`)
- Added `-s/--source` parameter (e.g., `-s 192.168.1.100`)
- Help text includes usage examples for both options

0.3.0 — 2025-09-10
------------------
### Major Features
- **NEW**: Actor-based architecture for thread safety
  - SwiftFTR converted from struct to actor
  - TraceHandle actor for cancellation support
  - RDNSCache actor for reverse DNS lookups
- **NEW**: Comprehensive caching system
  - Reverse DNS lookups cached with configurable TTL (default: 86400s)
  - STUN public IP cached until network changes
  - LRU eviction for memory efficiency
- **NEW**: Trace cancellation support
  - Cancel in-flight traces via TraceHandle
  - Responsive 100ms polling intervals
  - Automatic resource cleanup
- **NEW**: Network change management
  - `networkChanged()` API to handle network transitions
  - Cancels active traces and clears all caches
  - Ideal for mobile/laptop network changes
- **NEW**: Enhanced data models
  - Added `hostname` field to TraceHop
  - Added hostname fields to ClassifiedTrace
  - rDNS data integrated throughout

### Configuration
- **NEW**: rDNS configuration options
  - `noReverseDNS`: Disable rDNS lookups
  - `rdnsCacheTTL`: Configure cache TTL
  - `rdnsCacheSize`: Set maximum cache entries

### Code Quality
- **NEW**: Periphery integration for unused code detection
  - Added `.periphery.yml` configuration
  - Removed 109 lines of unused CymruWhoisResolver
  - Removed deprecated `host` property from TraceHop

### Documentation
- **NEW**: Comprehensive AI_REFERENCE.md (1000+ lines) - see docs/reference/
  - Complete API documentation
  - Real-world data samples
  - Usage patterns and best practices
- **NEW**: PERIPHERY_ANALYSIS.md documenting code cleanup - see docs/development/

### Performance
- rDNS lookups: ~50ms uncached → ~0ms cached
- STUN discovery: ~200ms uncached → ~0ms cached
- Memory-efficient with LRU cache eviction

### Compatibility
- No breaking changes - fully backward compatible
- Maintains Swift 6.1 strict concurrency compliance
- All 44 tests passing

0.2.0 — 2025-09-08
-------------------
- **BREAKING**: Minimum Swift version now 6.1 (was 5.10)
  - Package now builds exclusively in Swift 6 language mode
  - Requires Xcode 16.4 or later
- **BREAKING**: Removed all environment variable dependencies in favor of configuration API
  - Replaced `PTR_SKIP_STUN` and `PTR_PUBLIC_IP` with `SwiftFTRConfig` struct
  - All configuration now passed explicitly via `SwiftFTRConfig` initialization
- **NEW**: Configuration-based API with `SwiftFTRConfig` struct
  - `maxHops`: Maximum TTL to probe (default: 30)
  - `maxWaitMs`: Timeout in milliseconds (default: 1000)
  - `payloadSize`: ICMP payload size in bytes (default: 56)
  - `publicIP`: Override public IP detection (optional)
  - `enableLogging`: Enable debug logging (default: false)
- **NEW**: Enhanced CLI with additional flags
  - `--verbose`: Enable verbose debug logging
  - `--payload-size`: Configure ICMP payload size
  - `--public-ip`: Override public IP (replaces PTR_PUBLIC_IP env var)
  - Removed `--no-stun` flag (now implied when `--public-ip` is set)
- **NEW**: Swift 6.1 full compliance
  - All types marked `Sendable`
  - All public methods marked `nonisolated`
  - Thread-safe without MainActor requirements
  - Strict concurrency checking passes with no warnings
- **NEW**: Comprehensive test suite additions
  - Configuration tests validating no environment variable dependency
  - Thread safety tests with concurrent tracers
  - Integration tests accounting for real-world network topology
- **NEW**: Enhanced error handling with detailed error messages
  - `TracerouteError` now includes contextual details for debugging
  - Platform-specific error messages for better troubleshooting
- **NEW**: Documentation improvements
  - Added EXAMPLES.md with SwiftUI integration examples - see docs/guides/
  - Added MIGRATION.md guide for v0.1.0 to v0.2.0 transition
  - Updated ROADMAP.md with Swift-IP2ASN integration plans - see docs/development/
- **FIXED**: Test reliability improvements
  - Tests now account for missing TRANSIT segments in direct ISP peering
  - Integration tests only run on self-hosted runners
  - Removed rigid network topology assumptions

0.1.0 — 2025-09-05
-------------------
- Initial public release of SwiftFTR.
- Async/await traceroute over ICMP datagram sockets (no sudo on macOS).
- Monotonic RTT timing and receive buffer reuse for performance.
- ASN-based classification with hole-filling and CGNAT/PRIVATE heuristics.
- STUN-based public IP discovery with `PTR_SKIP_STUN` and `PTR_PUBLIC_IP` overrides.
- DNS-based ASN resolver (Team Cymru WHOIS) with in-memory caching.
- CLI tool (`swift-ftr`) with plain text or JSON output and optional reverse DNS.
- DocC documentation, XCTest suite, CI for macOS, and MIT license.
