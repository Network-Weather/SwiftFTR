# Testing Guide for SwiftFTR

## Overview

SwiftFTR includes comprehensive testing to ensure reliability and performance. Tests are automatically run on all pull requests via GitHub Actions.

## Test Categories

### 1. Unit Tests
Standard XCTest unit tests for individual components:
```bash
swift test
```

### 2. Integration Tests
Comprehensive tests that verify the library works correctly as a whole:
```bash
swift run integrationtest
```

### 3. Stress Tests
Tests that push the library to its limits:
```bash
swift test --filter StressAndEdgeCaseTests
```

### 4. Performance Tests
Benchmarks to detect performance regressions:
```bash
swift test --filter testTracePerformance
```

## Running All Tests

Use the comprehensive test script:
```bash
./Scripts/run-all-tests.sh
```

This script will:
- Run all unit tests
- Execute integration tests
- Test the CLI tool
- Verify external package integration
- Generate coverage reports
- Run performance benchmarks

## Test Coverage

Generate coverage reports:
```bash
swift test --enable-code-coverage
xcrun llvm-cov report \
    .build/debug/SwiftFTRPackageTests.xctest/Contents/MacOS/SwiftFTRPackageTests \
    -instr-profile .build/debug/codecov/default.profdata \
    -ignore-filename-regex="Tests|.build"
```

Generate HTML coverage report:
```bash
xcrun llvm-cov show \
    .build/debug/SwiftFTRPackageTests.xctest/Contents/MacOS/SwiftFTRPackageTests \
    -instr-profile .build/debug/codecov/default.profdata \
    -format=html \
    -output-dir=coverage-report \
    -ignore-filename-regex="Tests|.build"
open coverage-report/index.html
```

## CI/CD Pipeline

### Cloud Runners (GitHub-hosted)
Automatically runs on every PR:

1. **Unit Tests** - All XCTest suites (works on cloud runners)
2. **Build Verification** - Ensures all targets compile
3. **Security Checks** - Static analysis for common issues
4. **Documentation Build** - Ensures docs compile

### Self-Hosted Runners Only
Requires self-hosted runner or manual trigger:

1. **Integration Tests** - Full traceroute tests with real network
2. **Stress Tests** - Edge cases requiring actual network access
3. **Performance Tests** - Benchmarks with real network latency
4. **Classification Tests** - ASN resolution and categorization

**Important:** Network traces do NOT work on GitHub cloud runners due to network restrictions. Integration tests that perform actual traceroutes must run on self-hosted runners or locally.

## Setting Up Self-Hosted Runners

To run complete integration tests, set up a self-hosted runner:

```bash
./Scripts/setup-self-hosted-runner.sh
```

Requirements for self-hosted runners:
- macOS 13+ (for ICMP datagram socket support)
- Network access to internet
- Swift 6.2+
- GitHub Actions runner software

## Network Topology Considerations

When writing or running tests, be aware that network topology varies greatly:

1. **Direct Peering**: ISPs may peer directly with destinations (no TRANSIT hops)
2. **Asymmetric Paths**: Return paths may differ from forward paths
3. **Timeouts**: Some hops may not respond to ICMP
4. **CGNAT**: Carrier-grade NAT can affect hop classification
5. **Anycast**: Services like 1.1.1.1 have multiple locations

Tests should NOT assume:
- A specific number of hops
- TRANSIT segments always exist
- All hops respond
- Specific ASN assignments remain constant

## Writing New Tests

### Unit Tests
Add to `Tests/SwiftFTRTests/`:
```swift
func testNewFeature() async throws {
    let config = SwiftFTRConfig(maxHops: 5)
    let tracer = SwiftFTR(config: config)
    
    let result = try await tracer.trace(to: "1.1.1.1")
    XCTAssertNotNil(result)
}
```

### Integration Tests
Add to `Tests/IntegrationTests/`:
```swift
func testComplexScenario() async throws {
    // Test that combines multiple features
    let config = SwiftFTRConfig(
        maxHops: 10,
        publicIP: "1.2.3.4"
    )
    let tracer = SwiftFTR(config: config)
    
    let classified = try await tracer.traceClassified(to: "8.8.8.8")
    XCTAssertEqual(classified.publicIP, "1.2.3.4")
}
```

## Testing Checklist for PRs

Before submitting a PR, ensure:

- [ ] All existing tests pass: `swift test`
- [ ] Integration tests pass: `swift run integrationtest`
- [ ] CLI works: `.build/debug/swift-ftr --help`
- [ ] No memory leaks (run with Address Sanitizer if possible)
- [ ] Performance hasn't regressed significantly
- [ ] New features have corresponding tests
- [ ] Coverage hasn't decreased significantly

## Debugging Test Failures

### Enable verbose logging:
```swift
let config = SwiftFTRConfig(enableLogging: true)
```

### Run specific test:
```bash
swift test --filter testName
```

### Run with sanitizers (macOS):
```bash
swift test -Xswiftc -sanitize=address
swift test -Xswiftc -sanitize=thread
```

### Check for race conditions:
```bash
swift test --parallel --num-workers 8
```

## Known Test Limitations

1. **Network Tests**: Some tests require network access and may fail in restricted environments
2. **Timing Tests**: Performance tests may vary based on system load
3. **ICMP Permissions**: Tests require ICMP datagram socket support (available on macOS without root)
4. **IPv6**: Currently only IPv4 is tested as the library doesn't support IPv6 yet

## Continuous Improvement

We track test metrics including:
- Code coverage percentage
- Test execution time
- Flaky test frequency
- Performance regression trends

Target metrics:
- Unit test coverage: >70%
- Integration test coverage: >80%
- Zero flaky tests
- Performance within 10% of baseline