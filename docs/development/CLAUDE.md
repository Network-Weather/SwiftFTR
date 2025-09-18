# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SwiftFTR is a fast, parallel ICMP traceroute library for Swift on macOS that requires no sudo privileges. It uses ICMP datagram sockets with async/await to probe every hop concurrently, providing structured results with optional ASN classification.

## Build and Test Commands

### Basic Development
```bash
# Build
swift build -c debug
swift build -c release

# Run tests (disable STUN for isolated testing)
PTR_SKIP_STUN=1 swift test -c debug

# Format check (CI enforced)
swift format lint -r Sources Tests

# Auto-format (optional)
swift format -i -r Sources Tests

# Clean build
swift package clean
```

### CLI Tool
```bash
# Build and run CLI
swift build -c release
.build/release/swift-ftr --help
.build/release/swift-ftr example.com -m 30 -w 1.0
.build/release/swift-ftr --json www.example.com
```

### Documentation
```bash
# Generate DocC documentation
swift package --allow-writing-to-directory docs \
  generate-documentation --target SwiftFTR \
  --output-path docs --transform-for-static-hosting --hosting-base-path SwiftFTR
open docs/index.html
```

### Testing Suite
```bash
# Run comprehensive test suite
./Scripts/run-all-tests.sh

# Run specific test executables
.build/debug/ptrtests
.build/debug/integrationtest

# Run fuzz tests (macOS)
swift build -c release -Xswiftc -sanitize=address -Xswiftc -sanitize=undefined
.build/release/icmpfuzz
```

## Architecture

### Core Components

**SwiftFTR** (`Sources/SwiftFTR/Traceroute.swift`): Main public API providing `trace()` and `traceClassified()` methods. Uses parallel ICMP probing with monotonic timing. Thread-safe and nonisolated for use from any actor.

**ICMP Module** (`Sources/SwiftFTR/ICMP.swift`): Low-level ICMP packet parsing and socket operations. Handles Echo Request/Reply, Time Exceeded, and Destination Unreachable messages.

**Segmentation** (`Sources/SwiftFTR/Segmentation.swift`): Path classification logic that categorizes hops as LOCAL, ISP, TRANSIT, or DESTINATION based on ASN data and heuristics. Includes hole-filling between identical segments.

**ASN Resolution** (`Sources/SwiftFTR/ASN.swift`): Team Cymru DNS WHOIS lookups with in-memory caching. Supports batch resolution and custom resolver injection.

**STUN Client** (`Sources/SwiftFTR/STUN.swift`): Public IP discovery via STUN protocol. Can be disabled via `PTR_SKIP_STUN` environment variable or `SwiftFTRConfig(publicIP:)`.

### Key Design Patterns

- **Single Socket Architecture**: One ICMP datagram socket for all probes, using non-blocking I/O with `poll(2)`
- **Parallel Probing**: Sends all TTL probes in a burst, then enters single receive loop until deadline
- **Monotonic Timing**: Uses `CLOCK_MONOTONIC` for RTT measurements to avoid wall-clock jumps
- **Buffer Reuse**: Single receive buffer and minimal allocations for performance
- **Actor-Safe API**: All public types are `Sendable`, no `@MainActor` requirements

### Configuration

`SwiftFTRConfig` controls behavior:
- `maxHops`: Maximum TTL to probe (default: 30)
- `maxWaitMs`: Timeout in milliseconds (default: 1000)
- `payloadSize`: ICMP payload size (default: 56)
- `publicIP`: Override public IP to skip STUN
- `enableLogging`: Debug logging flag

## Platform Requirements

- Swift 6.2+ (Xcode 26+)
- macOS 13+
- IPv4 only (uses ICMPv4 Echo)
- Requires ICMP datagram socket support (macOS specific, no sudo needed)

## Testing Approach

- Unit tests mock network operations
- Integration tests require network access
- Set `PTR_SKIP_STUN=1` for isolated testing
- Fuzz testing available for ICMP packet parsing
- CLI tool includes `--help`, basic trace, and JSON output tests

## CI/CD Workflows

- **CI** (`.github/workflows/ci.yml`): Format check, build, and test on push/PR
- **Docs** (`.github/workflows/docs.yml`): Auto-publish DocC to GitHub Pages
- **Release**: Tag-based releases with binary artifacts and SBOM

## Important Notes

- Thread-safe library, callable from any actor or task
- No MainActor requirements for SwiftUI integration
- DNS/ASN lookups are injectable for testing
- Formatting enforced via `swift format` in CI
- Optional git hooks available: `git config core.hooksPath .githooks`
- Concurrency defaults follow Swift 6.2 guidance: CLI targets pass `-default-isolation MainActor`, helper APIs use `@concurrent`, and upcoming features `NonisolatedNonsendingByDefault` + `InferIsolatedConformances` stay enabled.
