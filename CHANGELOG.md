Changelog
=========

All notable changes to this project are documented here. This project follows Semantic Versioning.

Unreleased
----------
### Breaking Changes
- Minimum supported Swift has been raised to 6.2 (requires Xcode 26+) to adopt the "Approachable Concurrency" defaults and stricter Sendable checking.

### Documentation
- Updated README, contributor guides, and DocC content to reference Swift 6.2 best practices and tooling.

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
- Maintains Swift 6.2 strict concurrency compliance
- All 44 tests passing

0.2.0 — 2025-09-08
-------------------
- **BREAKING**: Minimum Swift version now 6.1 (was 5.10) *(superseded; project now targets Swift 6.2 in Unreleased section)*
  - Package now builds exclusively in Swift 6 language mode
  - Requires Xcode 16.4 or later *(original baseline; current requirement is Xcode 26+)*
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
- **NEW**: Swift 6.2 full compliance
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
