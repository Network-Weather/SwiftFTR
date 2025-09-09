# SwiftFTR v0.2.0 Release Notes

**Release Date:** September 8, 2025  
**Pull Request:** [#1](https://github.com/Network-Weather/SwiftFTR/pull/1)

## Overview
SwiftFTR v0.2.0 is a major update that replaces environment variable configuration with a type-safe configuration API and achieves full Swift 6.1 compliance. This release improves API ergonomics, thread safety, and testability while maintaining backward compatibility for basic usage.

## Breaking Changes
- **Swift 6.1 minimum**: Package now requires Swift 6.1+ and Xcode 16.4+
- **Environment variables removed**: `PTR_SKIP_STUN` and `PTR_PUBLIC_IP` are no longer supported
- **Configuration API required**: All settings must now be passed via `SwiftFTRConfig` struct

## Key Features

### Configuration API
```swift
let config = SwiftFTRConfig(
    maxHops: 30,        // Maximum TTL to probe
    maxWaitMs: 1000,    // Timeout in milliseconds
    payloadSize: 56,    // ICMP payload size
    publicIP: nil,      // Optional public IP override
    enableLogging: false // Debug logging
)
let tracer = SwiftFTR(config: config)
```

### Swift 6.1 Compliance
- All types marked `Sendable` for safe concurrent access
- All public methods marked `nonisolated` - no MainActor required
- Thread-safe design enables use from any actor or task
- Strict concurrency checking passes with zero warnings

### Enhanced CLI
```bash
swift-ftr example.com --verbose              # Debug logging
swift-ftr example.com --payload-size 128     # Custom payload
swift-ftr example.com --public-ip 1.2.3.4    # Override public IP
```

### Improved Testing
- Configuration tests validate no environment variable dependency
- Thread safety tests with concurrent tracers
- Integration tests account for real-world network topology
- Tests now handle missing TRANSIT segments in direct ISP peering

## Migration Guide
See [MIGRATION.md](MIGRATION.md) for detailed instructions on upgrading from v0.1.0.

## Documentation
- [EXAMPLES.md](EXAMPLES.md) - Comprehensive usage examples including SwiftUI integration
- [ROADMAP.md](ROADMAP.md) - Future development plans including Swift-IP2ASN integration
- [TESTING.md](TESTING.md) - Testing guidelines and CI/CD configuration

## Installation
```swift
dependencies: [
    .package(url: "https://github.com/Network-Weather/SwiftFTR.git", from: "0.2.0")
]
```

## Testing
All 44 tests pass on macOS. Integration tests require self-hosted runners for network access.

```bash
swift test                    # Run all tests
swift test --filter Config   # Run configuration tests only
```

## What's Changed
- Configuration API replacing environment variables by @dewrich in #1
- Swift 6.1 full compliance with Sendable and nonisolated
- Enhanced CLI with verbose logging and payload size options
- Comprehensive test suite additions (44 tests)
- Documentation improvements (EXAMPLES.md, MIGRATION.md, ROADMAP.md)

## Next Steps
The v0.2.0 release sets the foundation for v0.3.0, which will focus on VPN/Zero Trust/SASE support for enterprise network compatibility. Future releases will add offline ASN mapping and IPv6 support.

## Full Changelog
https://github.com/Network-Weather/SwiftFTR/compare/v0.1.0...v0.2.0

## Contributors
This release was developed with assistance from Claude Code.