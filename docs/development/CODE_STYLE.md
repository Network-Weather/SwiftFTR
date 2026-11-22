# SwiftFTR Code Style Guide

## Swift Format

SwiftFTR uses `swift-format` for automated code formatting. Run before committing:

```bash
swift format lint --strict -r Sources Tests
swift format format --in-place -r Sources Tests  # Auto-fix
```

## Naming Convention Exceptions

We intentionally deviate from Swift naming conventions in specific cases:

### 1. JSON API Field Names (CLI Output)

**Location:** `Sources/swift-ftr/main.swift`
**Pattern:** Snake_case property names in Codable structs

```swift
// swift-format-ignore: AlwaysUseLowerCamelCase
struct Root: Codable {
    let target_ip: String      // ⚠️ snake_case for JSON compatibility
    let public_ip: String?
    ...
}
struct HopObj: Codable {
    let asn_info: HopASN?
    let rtt_ms: Double?
    ...
}
```

**Reason:** JSON output format is part of SwiftFTR's public API. External tools and scripts depend on these exact field names. Changing to camelCase would break backwards compatibility for users parsing JSON output.

**Alternative Considered:** Use `CodingKeys` to map Swift camelCase to JSON snake_case:
```swift
let targetIP: String  // Swift property
enum CodingKeys: String, CodingKey {
    case targetIP = "target_ip"  // JSON key
}
```

**Decision:** Rejected - adds complexity and makes the code harder to read. The property names are only used within the JSON encoding context, so the snake_case style is acceptable.

### 2. External Integration Requirements

**Location:** `Sources/icmpfuzzer/ICMPFuzzer.swift`

```swift
@_cdecl("LLVMFuzzerTestOneInput")  // ⚠️ Required by libFuzzer
public func LLVMFuzzerTestOneInput(_ dataPtr: UnsafePointer<UInt8>, _ size: Int) -> Int32
```

**Reason:** `LLVMFuzzerTestOneInput` is a required entry point name for libFuzzer integration. Cannot be changed.

### 3. Internal Implementation Details

**Location:** `Sources/SwiftFTR/DNS.swift`, `Sources/SwiftFTR/ICMP.swift`

```swift
@_spi(Test)  // Private implementation for testing
public func __dnsEncodeQName(_ name: String) -> [UInt8]

@_spi(Test)
public func __parseICMPMessage(buffer: UnsafeRawBufferPointer, from saStorage: sockaddr_storage)
  -> TestParsedICMP?
```

Tests and internal tools reach them with `@_spi(Test) import SwiftFTR`. The fuzzers also use a
separate `@_spi(Fuzz)` surface.

**Reason:** Double-underscore prefix (`__`) signals these are internal/private implementation details exposed only for testing via `@_spi(Test)`. This naming convention is common in low-level systems programming and clearly indicates "do not use directly."

## Format Diagnostics

The current tree passes strict formatting. Intentional naming exceptions use narrow, local
`swift-format-ignore` directives so new diagnostics still fail CI.

## CI Enforcement

The CI workflow runs `swift format lint --strict -r Sources Tests` on every push to `main` and every
PR, before any build or test job. The optional pre-push hook in `.githooks/pre-push` runs the same
command locally (`git config core.hooksPath .githooks`).

## Summary

**Rule:** Follow swift-format recommendations **except** for:
1. JSON API field names (backwards compatibility)
2. External integration requirements (libFuzzer)
3. Internal `__` prefixed testing utilities (systems programming convention)

All new Swift code should use standard camelCase naming.
