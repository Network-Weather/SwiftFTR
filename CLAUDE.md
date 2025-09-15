# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Common Development Commands

### Build & Test
```bash
# Build debug
swift build -c debug

# Build release (optimized)
swift build -c release

# Run all tests (with STUN disabled for isolation)
PTR_SKIP_STUN=1 swift test -c debug

# Run specific test
swift test --filter ComprehensiveIntegrationTests/testClassifiedTrace

# Build CLI executable
swift build -c release --product swift-ftr
```

### Code Quality
```bash
# Check formatting (required before push)
swift format lint -r Sources Tests

# Auto-format code
swift format -i -r Sources Tests

# Run periphery to find unused code (if installed)
periphery scan
```

### Documentation
```bash
# Generate DocC documentation
swift package --allow-writing-to-directory docs \
  generate-documentation --target SwiftFTR \
  --output-path docs --transform-for-static-hosting --hosting-base-path SwiftFTR
```

## Architecture Overview

### Core Components

**SwiftFTR Actor** (`Sources/SwiftFTR/Traceroute.swift`)
- Main actor coordinating all traceroute operations
- Manages active traces via `TraceHandle` for cancellation support
- Provides `trace()` and `traceClassified()` public APIs
- Handles network change events to invalidate caches and cancel active traces

**ICMP Module** (`Sources/SwiftFTR/ICMP.swift`)
- Low-level ICMP packet handling using `SOCK_DGRAM` socket (no sudo required on macOS)
- Parallel probe strategy: sends all TTL probes in one burst
- Non-blocking socket with `poll(2)` for efficient I/O
- Monotonic clock timing for accurate RTT measurements

**Classification System** (`Sources/SwiftFTR/Segmentation.swift`)
- `TraceClassifier` performs ASN-based hop categorization
- Categories: LOCAL, ISP, TRANSIT, DESTINATION
- Hole-filling algorithm to interpolate missing hops between identical segments
- Uses Team Cymru DNS WHOIS for ASN lookups with caching

**Caching Infrastructure**
- `RDNSCache` (`Sources/SwiftFTR/RDNSCache.swift`): Reverse DNS with 86400s TTL
- `STUNCache` (in `STUN.swift`): Public IP discovery, invalidated on network changes
- `_ASNMemoryCache` (in `ASN.swift`): In-memory ASN lookup cache with 2048 entry capacity

### Key Design Patterns

1. **Actor-based Concurrency**: SwiftFTR is an actor ensuring thread-safe operations without MainActor requirements
2. **Cancellation Support**: Active traces can be cancelled via `TraceHandle` or globally via `networkChanged()`
3. **Dependency Injection**: Resolvers (ASN, DNS) are injectable via configuration for testing
4. **Resource Management**: Single socket per trace, buffer reuse, minimal allocations

### Protocol Extensions

The codebase defines several protocols for extensibility:
- `ASNResolver`: Custom ASN lookup implementations
- `DNSResolver`: Alternative DNS resolution strategies
- All public types conform to `Sendable` for Swift 6 concurrency

## Swift 6 Compliance

This project requires Swift 6.1+ and builds with strict concurrency checking enabled:
- Language mode: Swift 6 (`swiftLanguageModes: [.v6]` in Package.swift)
- All public types are `Sendable`
- No `@MainActor` requirements for library APIs
- Thread-safe from any actor or task context