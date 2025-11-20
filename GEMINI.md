# SwiftFTR - Gemini Context

This document provides essential context and instructions for working on the SwiftFTR project.

## Project Overview

**SwiftFTR** is a fast, parallel traceroute implementation for macOS, written in Swift 6.1. It uses native ICMP datagram sockets (`SOCK_DGRAM`, `IPPROTO_ICMP`) to perform measurements without requiring `sudo` or elevated privileges.

*   **Core Philosophy:** Parallel execution, async/await API, type safety, and production-readiness.
*   **Key Features:**
    *   Sudo-less execution on macOS 13+.
    *   Parallel probing (sends all probes in a burst).
    *   ASN-based hop classification (LOCAL, ISP, TRANSIT, DESTINATION).
    *   Built-in STUN for public IP detection.
    *   Swift 6 strict concurrency compliance (Actor-based).

## Development Environment

*   **Language:** Swift 6.1+
*   **Platform:** macOS 13+ (Ventura or later)
*   **Tools:** Xcode 16.4+ or equivalent Swift toolchain.

## Common Commands

### Building
```bash
# Build debug version (fast iteration)
swift build -c debug

# Build release version (optimized, for performance testing/shipping)
swift build -c release

# Build specifically the CLI tool
swift build -c release --product swift-ftr
```

### Testing
```bash
# Run all unit tests
swift test

# Run tests skipping network-dependent STUN checks (Recommended for CI/Offline)
PTR_SKIP_STUN=1 swift test

# Run a specific test case
swift test --filter <TestName>
```

### Running the CLI
```bash
# Run the built release binary
.build/release/swift-ftr trace example.com

# Run via swift run (slower startup)
swift run swift-ftr trace example.com
```

### Code Quality & Formatting
**Strict formatting is enforced.**
```bash
# Check for formatting issues (run before pushing)
swift format lint -r Sources Tests

# Automatically fix formatting issues
swift format -i -r Sources Tests
```

### Documentation
```bash
# Generate DocC documentation
swift package --allow-writing-to-directory docc \
  generate-documentation --target SwiftFTR \
  --output-path docc --transform-for-static-hosting
```

## Project Structure

*   **`Package.swift`**: Defines the package, dependencies, and targets.
*   **`Sources/`**
    *   **`SwiftFTR/`**: The core library.
        *   `Traceroute.swift`: Main actor, coordinates traces.
        *   `ICMP.swift`: Low-level socket handling (`SOCK_DGRAM`).
        *   `Segmentation.swift`: ASN/Hop classification logic.
        *   `DNS.swift`, `STUN.swift`: Network helpers.
    *   **`swift-ftr/`**: The CLI executable entry point.
    *   **`hop-monitor/`**: Ancillary monitoring tool.
*   **`Tests/`**
    *   **`SwiftFTRTests/`**: Unit and integration tests.

## Architecture & Design

*   **Concurrency:** The project uses Swift's structured concurrency. `SwiftFTR` is an `actor` to ensure thread safety. All public types are `Sendable`.
*   **Networking:**
    *   Uses a single non-blocking socket with `poll(2)` for efficient I/O.
    *   Probes are sent in a tight loop (parallel) rather than sequentially.
    *   RTT is measured using `CLOCK_MONOTONIC`.
*   **Classification:**
    *   Uses Team Cymru DNS WHOIS for ASN lookups.
    *   Logic handles "hole-filling" (interpolating missing hops).
    *   Distinguishes between private IPs, CGNAT, and public ASNs.

## Coding Conventions

1.  **Swift 6 Compliance:** All code must compile under Swift 6 language mode with strict concurrency checks. Use `Sendable` for shared types.
2.  **Formatting:** Adhere strictly to `swift-format` rules.
3.  **Naming:**
    *   Standard Swift `camelCase`.
    *   **Exception:** JSON properties in CLI output (`Sources/swift-ftr`) may use `snake_case` for API compatibility.
    *   **Exception:** Fuzzing entry points (`LLVMFuzzerTestOneInput`).
4.  **Documentation:** Public APIs must have documentation comments (`///`).
5.  **Tests:**
    *   Do not depend on live network access for unit tests (use mocks/fakes).
    *   Integration tests may access the network but should be robust.

## Contribution Workflow

1.  **Commits:** Use **Conventional Commits** (e.g., `feat: ...`, `fix: ...`, `docs: ...`).
2.  **Pull Requests:**
    *   Ensure `swift format lint` passes.
    *   Ensure `PTR_SKIP_STUN=1 swift test` passes.
    *   Update documentation if changing public APIs.
