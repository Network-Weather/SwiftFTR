# Testing Guide for SwiftFTR

## Overview

SwiftFTR's tests live in `Tests/SwiftFTRTests`. Most suites use Swift Testing (`import Testing`, `@Test`); some older ones use XCTest. CI runs the offline subset on every PR and every push to `main`; live-network tests run locally or on the self-hosted runner.

## Test Categories

### 1. Unit Tests
Offline and deterministic, as CI runs them:
```bash
SKIP_NETWORK_TESTS=1 PTR_SKIP_STUN=1 swift test -c debug
```
Drop the variables to include the live-network suites (`swift test`).

#### Environment gates

These variables only select tests; they do not change library or CLI behavior.

| Variable | Effect |
|---|---|
| `SKIP_NETWORK_TESTS=1` | Skip the live-network tests; set together with `PTR_SKIP_STUN` for an offline run |
| `PTR_SKIP_STUN=1` | Skip the public-IP (STUN) integration subset, a legacy gate |
| `SKIP_IPV6_TESTS=1` | Force-skip the IPv6 integration tests (`IPv6Reachability.swift`) |
| `FORCE_IPV6_TESTS=1` | Run the IPv6 integration tests without probing for a v6 path |

Live-network suites take a permit from `NetworkTestGate.shared.withPermit` so they do not
interfere with one another.

### 2. Integration Tests
An executable that exercises the library end to end against the live network:
```bash
swift run integrationtest
```

### 3. Stress Tests
Edge cases and load (`Tests/SwiftFTRTests/StressTests.swift`; several need the network):
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

It needs the network. This script will:
- Run all unit tests (`swift test --enable-code-coverage`, including live-network suites)
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
    "$(swift build --show-bin-path)/SwiftFTRTests.xctest/Contents/MacOS/SwiftFTRTests" \
    -instr-profile "$(swift test --show-codecov-path | xargs dirname)/default.profdata" \
    -ignore-filename-regex="Tests|.build"
```

Generate HTML coverage report:
```bash
xcrun llvm-cov show \
    "$(swift build --show-bin-path)/SwiftFTRTests.xctest/Contents/MacOS/SwiftFTRTests" \
    -instr-profile "$(swift test --show-codecov-path | xargs dirname)/default.profdata" \
    -format=html \
    -output-dir=coverage-report \
    -ignore-filename-regex="Tests|.build"
open coverage-report/index.html
```

## CI/CD Pipeline

### Cloud Runners (GitHub-hosted)
`ci.yml` runs on every PR and every push to `main` (details in
[.github/WORKFLOWS.md](../../.github/WORKFLOWS.md)):

1. **Format lint** - `swift format lint --strict -r Sources Tests`
2. **Builds** - debug and release
3. **Offline tests** - `swift test -c debug` with `SKIP_NETWORK_TESTS=1 PTR_SKIP_STUN=1`
4. **External consumers** - builds `IntegrationPackage` and `TestLibraryUsage`
5. **Documentation** - DocC with `--warnings-as-errors`

### Self-Hosted Runners Only
`local-integration-tests.yml` (runner labels `self-hosted`, `macos`, `traceroute`; manual
trigger or the `test-integration` PR label) runs:

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
- Swift 6.1+
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
Add to `Tests/SwiftFTRTests/`. Prefer Swift Testing for new suites; this XCTest form also
works. A test that touches the network must be skippable with `SKIP_NETWORK_TESTS`:
```swift
func testNewFeature() async throws {
    try XCTSkipIf(ProcessInfo.processInfo.environment["SKIP_NETWORK_TESTS"] != nil)
    let config = SwiftFTRConfig(maxHops: 5)
    let tracer = SwiftFTR(config: config)

    let result = try await NetworkTestGate.shared.withPermit {
        try await tracer.trace(to: "1.1.1.1")
    }
    XCTAssertNotNil(result)
}
```

### Integration Tests
There is no separate integration-test target: live-network tests also live in
`Tests/SwiftFTRTests/`, gated on `SKIP_NETWORK_TESTS` and wrapped in `NetworkTestGate`. For
example:
```swift
func testComplexScenario() async throws {
    try XCTSkipIf(ProcessInfo.processInfo.environment["SKIP_NETWORK_TESTS"] != nil)
    // Test that combines multiple features
    let config = SwiftFTRConfig(
        maxHops: 10,
        publicIP: "1.2.3.4"
    )
    let tracer = SwiftFTR(config: config)

    let classified = try await NetworkTestGate.shared.withPermit {
        try await tracer.traceClassified(to: "8.8.8.8")
    }
    XCTAssertEqual(classified.publicIP, "1.2.3.4")
}
```

## Testing Checklist for PRs

Before submitting a PR, ensure:

- [ ] Offline tests pass: `SKIP_NETWORK_TESTS=1 PTR_SKIP_STUN=1 swift test -c debug`
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
4. **IPv6**: v6 integration tests run only when a real v6 path is detected (`IPv6Reachability`); GitHub-hosted runners have none, so they skip there

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