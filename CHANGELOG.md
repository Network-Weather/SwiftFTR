Changelog
=========

All notable changes to this project are documented here. This project follows Semantic Versioning.

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
