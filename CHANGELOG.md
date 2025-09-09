Changelog
=========

All notable changes to this project are documented here. This project follows Semantic Versioning.

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
  - Added EXAMPLES.md with SwiftUI integration examples
  - Added MIGRATION.md guide for v0.1.0 to v0.2.0 transition
  - Updated ROADMAP.md with Swift-IP2ASN integration plans
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
