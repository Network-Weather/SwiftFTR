# Migration Guide: Environment Variables to Configuration API

## Overview
SwiftFTR has been updated to remove all environment variable dependencies in favor of a configuration-based API. This provides better type safety, clearer API contracts, and easier testing.

## Changes Made

### Library API Changes

#### Before (Environment Variables)
```swift
// Set environment variables
setenv("PTR_SKIP_STUN", "1", 1)
setenv("PTR_PUBLIC_IP", "203.0.113.1", 1)

// Create tracer with implicit config from environment
let tracer = SwiftFTR()
let result = try await tracer.trace(to: "example.com")
```

#### After (Configuration API)
```swift
// Create explicit configuration
let config = SwiftFTRConfig(
    maxHops: 30,
    maxWaitMs: 1000,
    payloadSize: 56,
    publicIP: "203.0.113.1",  // Replaces PTR_PUBLIC_IP
    enableLogging: false
)

// Create tracer with configuration
let tracer = SwiftFTR(config: config)
let result = try await tracer.trace(to: "example.com")
```

### CLI Changes

#### Before
```bash
# Using environment variables
PTR_SKIP_STUN=1 swift-ftr example.com
PTR_PUBLIC_IP=203.0.113.1 swift-ftr example.com
```

#### After
```bash
# Using command-line flags
swift-ftr --public-ip 203.0.113.1 example.com
swift-ftr --verbose example.com
swift-ftr --payload-size 128 example.com
```

### Removed Environment Variables
- `PTR_SKIP_STUN` - Now implied when `publicIP` is set in config
- `PTR_PUBLIC_IP` - Use `SwiftFTRConfig.publicIP` or `--public-ip` flag

### New Configuration Options
- `maxHops`: Maximum TTL to probe (default: 30)
- `maxWaitMs`: Timeout in milliseconds (default: 1000)
- `payloadSize`: ICMP payload size in bytes (default: 56)
- `publicIP`: Override public IP detection (optional)
- `enableLogging`: Enable debug logging (default: false)

## Benefits

1. **Type Safety**: Configuration is validated at compile time
2. **Thread Safety**: Each tracer instance has its own configuration
3. **Testability**: Easy to create test configurations without modifying process environment
4. **Clarity**: API contract is explicit in the configuration structure
5. **Swift 6.1 Compliance**: Fully `Sendable` and `nonisolated` for modern concurrency

## Testing Your Migration

After migrating, you can verify correct behavior with:

```swift
// Test that environment variables are ignored
unsetenv("PTR_SKIP_STUN")
unsetenv("PTR_PUBLIC_IP")

let config = SwiftFTRConfig(publicIP: "203.0.113.1")
let tracer = SwiftFTR(config: config)
let result = try await tracer.traceClassified(to: "example.com")

// Should use configured public IP, not environment
assert(result.publicIP == "203.0.113.1")
```

## Version Compatibility

- SwiftFTR 0.1.0+: Configuration API only
- Previous versions: Environment variables (deprecated)

## Support

For questions or issues with migration, please open an issue on GitHub.