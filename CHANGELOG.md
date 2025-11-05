Changelog
=========

All notable changes to this project are documented here. This project follows Semantic Versioning.

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
