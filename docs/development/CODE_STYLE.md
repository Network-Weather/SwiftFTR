# SwiftFTR Code Style Guide

## Swift Format

SwiftFTR uses `swift-format` for automated code formatting. Run before committing:

```bash
swift format lint -r Sources Tests
swift format -i -r Sources Tests  # Auto-fix
```

## Naming Convention Exceptions

We intentionally deviate from Swift naming conventions in specific cases:

### 1. JSON API Field Names (CLI Output)

**Location:** `Sources/swift-ftr/main.swift`
**Pattern:** Snake_case property names in Codable structs

```swift
struct Root: Codable {
    let target_ip: String      // ⚠️ snake_case for JSON compatibility
    let public_ip: String?
    let country_code: String?
    let asn_info: HopASN?
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
public func LLVMFuzzerTestOneInput(_ data: UnsafePointer<UInt8>, _ size: Int) -> Int32
```

**Reason:** `LLVMFuzzerTestOneInput` is a required entry point name for libFuzzer integration. Cannot be changed.

### 3. Internal Implementation Details

**Location:** `Sources/SwiftFTR/DNS.swift`, `Sources/SwiftFTR/ICMP.swift`

```swift
@_spi(Testing)  // Private implementation for testing
public func __dnsEncodeQName(_ name: String) -> [UInt8]?

@_spi(Testing)
public func __parseICMPMessage(_ data: [UInt8]) -> ParsedICMP?
```

**Reason:** Double-underscore prefix (`__`) signals these are internal/private implementation details exposed only for testing via `@_spi(Testing)`. This naming convention is common in low-level systems programming and clearly indicates "do not use directly."

## Pre-Existing Technical Debt

Some warnings exist in code written before v0.5.0 and are not part of this release:

- `Sources/ptrtests/main.swift:123` - Line length
- `Sources/swift-ftr/main.swift` - JSON field names (see above)

## Format Warnings We Fix

New code in v0.5.0 follows all swift-format recommendations:
- ✅ Line length limits
- ✅ Proper line breaks between declarations
- ✅ camelCase for all Swift-only code
- ✅ Trailing newlines

## CI Enforcement

GitHub Actions runs `swift format lint` on every push. PRs must pass formatting checks to merge.

## Summary

**Rule:** Follow swift-format recommendations **except** for:
1. JSON API field names (backwards compatibility)
2. External integration requirements (libFuzzer)
3. Internal `__` prefixed testing utilities (systems programming convention)

All new Swift code should use standard camelCase naming.