# SwiftFTR 0.5.0 - Multipath Discovery Implementation Plan

This document outlines the implementation plan for SwiftFTR 0.5.0, which adds dedicated ping support and multipath discovery capabilities. This work can proceed in parallel with NWX application development.

**Repository:** https://github.com/Network-Weather/SwiftFTR
**Branch:** `feature/multipath-0.5.0`
**Target Release:** SwiftFTR 0.5.0
**Current Version:** 0.4.0

---

## Overview & Motivation

### The Problem
Current SwiftFTR limitations for continuous network monitoring:
1. **No dedicated ping API** - Must use traceroute which is inefficient for single-hop monitoring
2. **ECMP blindness** - Cannot discover multiple equal-cost paths due to load balancing
3. **Middleware packet loss false positives** - Many routers rate-limit ICMP TTL Exceeded but respond reliably to ping

### The Solution
Add three key capabilities:
1. **Dedicated Ping API** - Efficient ICMP Echo Request/Reply for single-target monitoring
2. **Paris Traceroute** - Flow identifier consistency for stable path tracing
3. **ECMP Path Enumeration** - Systematic variation to discover all load-balanced paths

---

## Core Design Principles

### 1. API Compatibility
- **Breaking changes are acceptable** - We're the primary user
- Maintain clean, intuitive API design
- Follow Swift 6.1 concurrency best practices
- Keep all APIs nonisolated and Sendable

### 2. Performance
- Efficient for continuous monitoring use cases
- Minimal allocations and memory footprint
- Support concurrent operations
- Batch operations where beneficial

### 3. Testing
- **Target: 60% test coverage** (will grow to 85% over time)
- Focus on critical paths first
- Use mocks for network operations where appropriate
- Real network integration tests for validation

### 4. Code Quality
- **Mandatory:** Follow SwiftFTR formatting policies (`swift format`)
- **Mandatory:** Pass all existing tests
- **Mandatory:** Document public APIs with DocC comments
- **Recommended:** Add examples to documentation

---

## Feature 1: Dedicated Ping API

### Motivation
Ping is more efficient and reliable than traceroute for monitoring known hops:
- Single packet pair (Echo Request/Reply) vs full TTL sweep
- Most middleware boxes respond reliably to ping even when rate-limiting TTL Exceeded
- Essential for continuous per-hop monitoring

### API Design

```swift
/// Configuration for ping operations
public struct PingConfig: Sendable {
    /// Number of pings to send
    public let count: Int

    /// Interval between pings in seconds
    public let interval: TimeInterval

    /// Timeout for each ping in seconds
    public let timeout: TimeInterval

    /// ICMP payload size (default: 56 bytes)
    public let payloadSize: Int

    /// Optional: bind to specific network interface
    public let interface: String?

    /// Optional: bind to specific source IP
    public let sourceIP: String?

    public init(
        count: Int = 5,
        interval: TimeInterval = 1.0,
        timeout: TimeInterval = 2.0,
        payloadSize: Int = 56,
        interface: String? = nil,
        sourceIP: String? = nil
    )
}

/// Result from a ping operation
public struct PingResult: Sendable {
    /// Target hostname or IP
    public let target: String

    /// Resolved IP address
    public let resolvedIP: String

    /// Individual ping responses
    public let responses: [PingResponse]

    /// Statistics computed from responses
    public let statistics: PingStatistics
}

/// Individual ping response
public struct PingResponse: Sendable {
    /// Sequence number of this ping
    public let sequence: Int

    /// Round-trip time in seconds (nil if timeout)
    public let rtt: TimeInterval?

    /// TTL from response packet
    public let ttl: Int?

    /// Timestamp when ping was sent
    public let timestamp: Date
}

/// Computed ping statistics
public struct PingStatistics: Sendable {
    /// Total packets sent
    public let sent: Int

    /// Total packets received
    public let received: Int

    /// Packet loss percentage (0.0 - 1.0)
    public let packetLoss: Double

    /// Minimum RTT (nil if no responses)
    public let minRTT: TimeInterval?

    /// Average RTT (nil if no responses)
    public let avgRTT: TimeInterval?

    /// Maximum RTT (nil if no responses)
    public let maxRTT: TimeInterval?

    /// Jitter (standard deviation of RTT, nil if <2 responses)
    public let jitter: TimeInterval?
}

// SwiftFTR API Extension
extension SwiftFTR {
    /// Ping a target host
    ///
    /// - Parameters:
    ///   - target: Hostname or IP address to ping
    ///   - config: Ping configuration
    /// - Returns: Ping result with statistics
    /// - Throws: `TracerouteError` on failure
    public func ping(to target: String, config: PingConfig = PingConfig()) async throws -> PingResult
}
```

### Implementation Plan

#### Step 1: Core Ping Module
**File:** `Sources/SwiftFTR/Ping.swift`

```swift
/// Internal ping implementation
actor PingExecutor {
    private let config: SwiftFTRConfig

    func ping(to target: String, config: PingConfig) async throws -> PingResult {
        // 1. Resolve target to IP
        // 2. Create ICMP socket (reuse ICMP.swift utilities)
        // 3. Bind to interface/sourceIP if specified
        // 4. Send Echo Requests with interval
        // 5. Collect Echo Replies with timeout
        // 6. Compute statistics
        // 7. Return PingResult
    }
}
```

**Key Implementation Details:**
- Reuse existing ICMP socket code from `ICMP.swift`
- Use monotonic timing for accurate RTT
- Non-blocking I/O with poll(2)
- Proper sequence number handling
- Timeout handling per ping
- Graceful handling of interface binding failures

#### Step 2: Update SwiftFTR Actor
**File:** `Sources/SwiftFTR/Traceroute.swift`

Add ping method to main SwiftFTR actor:
```swift
public actor SwiftFTR {
    // ... existing code ...

    public func ping(to target: String, config: PingConfig = PingConfig()) async throws -> PingResult {
        let executor = PingExecutor(config: self.config)
        return try await executor.ping(to: target, config: config)
    }
}
```

#### Step 3: CLI Support
**File:** `Sources/swift-ftr/main.swift`

Add ping subcommand:
```bash
swift-ftr ping example.com -c 10 -i 0.5 -t 2.0
swift-ftr ping 8.8.8.8 --interface en0 --count 20
```

#### Step 4: Tests
**File:** `Tests/SwiftFTRTests/PingTests.swift`

Test cases:
- Basic ping to reachable host
- Ping with packet loss (mock)
- Ping timeout handling
- Interface binding
- Statistics calculation
- Jitter calculation
- Target: 60% coverage

---

## Feature 2: Paris Traceroute (Flow Consistency)

### Motivation
Traditional traceroute varies flow identifiers unintentionally, causing ECMP load balancers to send probes down different paths. This makes it impossible to get a coherent view of a single path.

Paris Traceroute keeps flow identifiers consistent to trace a single stable path through ECMP networks.

### Implementation Approach

#### Flow Identifier Components
For ICMP:
- **Identifier field** (16 bits) - Keep constant per trace
- **Sequence field** (16 bits) - Use TTL value (current behavior)
- **Checksum** - Computed from identifier + sequence

For UDP (future):
- **Source port** - Keep constant per trace
- **Destination port** - Use TTL + base port
- **Checksum** - Standard UDP checksum

#### Changes Required

**File:** `Sources/SwiftFTR/ICMP.swift`

Current behavior (varies unintentionally):
```swift
// Currently uses process PID as identifier (varies per run)
let identifier = UInt16(ProcessInfo.processInfo.processIdentifier & 0xFFFF)
```

Paris Traceroute behavior (stable per trace):
```swift
// Use stable identifier per trace session
struct ProbeIdentifiers {
    let icmpIdentifier: UInt16  // Stable for this trace
    let udpSourcePort: UInt16   // Stable for this trace

    static func generate() -> ProbeIdentifiers {
        // Generate stable but unique identifiers
        // Could use: hash of (timestamp + random), clamped to 16 bits
        let id = UInt16.random(in: 1...UInt16.max)
        return ProbeIdentifiers(icmpIdentifier: id, udpSourcePort: id)
    }
}
```

**File:** `Sources/SwiftFTR/Traceroute.swift`

Update trace methods to use stable identifiers:
```swift
public actor SwiftFTR {
    // Generate identifiers once per trace
    private func performTrace(to target: String) async throws -> TraceResult {
        let identifiers = ProbeIdentifiers.generate()
        // Pass identifiers through to probe generation
        // ...
    }
}
```

#### Testing
- Verify identifier stays constant across all probes in a trace
- Validate checksum computation with stable identifier
- Compare paths traced with/without flow consistency (if ECMP available)

---

## Feature 3: ECMP Path Enumeration (Dublin Traceroute)

### Motivation
ECMP load balancing creates multiple equal-cost paths. We need to discover ALL paths, not just one, to:
1. Understand full network topology
2. Detect when different paths have different performance
3. Identify which path specific traffic will take

### Implementation Approach

Dublin Traceroute systematically varies flow identifiers while keeping other parameters constant. By trying different flow IDs, we can force packets down different ECMP paths.

#### API Design

```swift
/// Configuration for multipath discovery
public struct MultipathConfig: Sendable {
    /// Number of different flow identifiers to try per TTL
    public let flowIDVariations: Int

    /// Maximum paths to discover before stopping
    public let maxPaths: Int

    /// Standard traceroute config
    public let traceConfig: SwiftFTRConfig

    public init(
        flowIDVariations: Int = 8,
        maxPaths: Int = 16,
        traceConfig: SwiftFTRConfig
    )
}

/// Multiple discovered paths
public struct MultipathResult: Sendable {
    /// Target being traced
    public let target: String

    /// All discovered paths (each is a ClassifiedTrace)
    public let paths: [DiscoveredPath]

    /// Path fingerprints for deduplication
    public let uniquePaths: Int
}

/// A single discovered path with its flow identifier
public struct DiscoveredPath: Sendable {
    /// Flow identifier that produced this path
    public let flowIdentifier: FlowIdentifier

    /// The classified trace for this path
    public let trace: ClassifiedTrace

    /// Path fingerprint for deduplication
    public let fingerprint: String
}

/// Flow identifier that can be varied
public struct FlowIdentifier: Sendable, Hashable {
    public let icmpID: UInt16
    public let icmpSeq: UInt16  // Per hop
    public let udpSrcPort: UInt16?
    public let udpDstPort: UInt16?  // Per hop
}

// SwiftFTR API Extension
extension SwiftFTR {
    /// Discover multiple paths to target (ECMP enumeration)
    ///
    /// - Parameters:
    ///   - target: Hostname or IP to trace
    ///   - config: Multipath discovery configuration
    /// - Returns: All discovered paths
    /// - Throws: `TracerouteError` on failure
    public func discoverPaths(
        to target: String,
        config: MultipathConfig
    ) async throws -> MultipathResult
}
```

#### Implementation Plan

**File:** `Sources/SwiftFTR/Multipath.swift` (NEW)

```swift
/// Dublin Traceroute implementation - ECMP path enumeration
actor MultipathDiscovery {
    private let config: SwiftFTRConfig

    /// Discover all ECMP paths to target
    func discoverPaths(to target: String, multipathConfig: MultipathConfig) async throws -> MultipathResult {
        var discoveredPaths: [DiscoveredPath] = []
        var seenFingerprints: Set<String> = []

        // Try different flow identifiers
        for variation in 0..<multipathConfig.flowIDVariations {
            // Generate unique flow identifier for this variation
            let flowID = generateFlowID(variation: variation)

            // Run trace with this flow ID (using Paris Traceroute consistency)
            let trace = try await runTraceWithFlowID(to: target, flowID: flowID)

            // Compute path fingerprint
            let fingerprint = computePathFingerprint(trace)

            // If this is a new path, add it
            if !seenFingerprints.contains(fingerprint) {
                seenFingerprints.insert(fingerprint)
                discoveredPaths.append(DiscoveredPath(
                    flowIdentifier: flowID,
                    trace: trace,
                    fingerprint: fingerprint
                ))

                // Stop if we've found max paths
                if discoveredPaths.count >= multipathConfig.maxPaths {
                    break
                }
            }
        }

        return MultipathResult(
            target: target,
            paths: discoveredPaths,
            uniquePaths: discoveredPaths.count
        )
    }

    /// Generate flow identifier for given variation
    private func generateFlowID(variation: Int) -> FlowIdentifier {
        // Strategy: vary ICMP ID systematically
        // Could also vary UDP ports if implementing UDP probes
        let baseID = UInt16.random(in: 1...0xF000)
        let variedID = baseID &+ UInt16(variation)

        return FlowIdentifier(
            icmpID: variedID,
            icmpSeq: 0,  // Will be set per hop
            udpSrcPort: nil,
            udpDstPort: nil
        )
    }

    /// Compute fingerprint of path for deduplication
    private func computePathFingerprint(_ trace: ClassifiedTrace) -> String {
        // Fingerprint = sequence of responding IP addresses
        let hops = trace.hops.compactMap { $0.ip }.joined(separator: ",")
        return hops
    }

    /// Run trace with specific flow identifier
    private func runTraceWithFlowID(to target: String, flowID: FlowIdentifier) async throws -> ClassifiedTrace {
        // Similar to existing trace logic but with specified flow ID
        // Reuse ICMP and classification infrastructure
        // ...
    }
}
```

#### Testing
- Mock ECMP environment with multiple paths
- Verify path deduplication works correctly
- Test with single-path network (should find 1 path)
- Test with known multi-path network
- Validate flow ID generation doesn't collide

---

## Feature 4: Enhanced Interface Selection

### Current State
SwiftFTR 0.4.0 supports interface binding via `interface` config parameter.

### Enhancement
Make interface enumeration and selection easier for applications:

```swift
/// Network interface information
public struct NetworkInterface: Sendable {
    public let name: String  // e.g., "en0"
    public let displayName: String  // e.g., "Wi-Fi"
    public let address: String?  // IPv4 address
    public let isUp: Bool
    public let isLoopback: Bool
}

extension SwiftFTR {
    /// Get all available network interfaces
    public static func availableInterfaces() -> [NetworkInterface]
}
```

**Implementation:** Minimal wrapper around `getifaddrs()` from `<ifaddrs.h>`

---

## Implementation Timeline

### Week 1: Ping API Foundation
- [ ] Implement PingExecutor actor
- [ ] Add ping() method to SwiftFTR
- [ ] Implement PingResult and statistics computation
- [ ] Basic tests (reachable host, timeout, statistics)
- [ ] CLI ping subcommand

**Deliverable:** Working ping API with 60% test coverage

### Week 2: Paris Traceroute & Multipath Discovery
- [ ] Implement stable flow identifier generation
- [ ] Update ICMP probe generation to use stable identifiers
- [ ] Implement MultipathDiscovery actor
- [ ] Add discoverPaths() method to SwiftFTR
- [ ] Path fingerprinting and deduplication
- [ ] Tests for multipath discovery

**Deliverable:** Multipath enumeration working

### Week 3: Integration, Testing & Documentation
- [ ] Enhanced interface selection API
- [ ] CLI enhancements for multipath
- [ ] Comprehensive integration tests
- [ ] Performance profiling and optimization
- [ ] DocC documentation updates
- [ ] Example code
- [ ] Release notes

**Deliverable:** SwiftFTR 0.5.0 ready for release

---

## Testing Strategy

### Unit Tests (60% coverage target)
- Ping statistics calculation
- Flow identifier generation
- Path fingerprinting
- Deduplication logic
- Configuration validation

### Integration Tests
- Real network ping tests (to well-known hosts)
- Paris Traceroute flow consistency validation
- Multipath discovery on ECMP network (if available)
- Interface binding validation

### Performance Tests
- Ping overhead vs raw ICMP
- Memory allocation profiling
- Concurrent operation stress testing

---

## Documentation Requirements

### API Documentation (DocC)
- [ ] Ping API documentation with examples
- [ ] Multipath discovery documentation with examples
- [ ] Flow identifier explanation
- [ ] When to use ping vs traceroute
- [ ] ECMP and multipath concepts

### Examples
```swift
// Example 1: Simple ping
let ftr = SwiftFTR(config: .default)
let result = try await ftr.ping(to: "8.8.8.8", config: .init(count: 10))
print("Packet loss: \(result.statistics.packetLoss * 100)%")
print("Avg latency: \(result.statistics.avgRTT! * 1000) ms")

// Example 2: Discover ECMP paths
let multipathConfig = MultipathConfig(flowIDVariations: 16, maxPaths: 8)
let paths = try await ftr.discoverPaths(to: "www.example.com", config: multipathConfig)
print("Found \(paths.uniquePaths) distinct paths")
for path in paths.paths {
    print("Path via \(path.trace.hops.first?.ip ?? "unknown")")
}

// Example 3: Ping on specific interface
let pingConfig = PingConfig(count: 5, interface: "en0")
let result = try await ftr.ping(to: "1.1.1.1", config: pingConfig)
```

---

## Migration Guide

Since we're the primary user and breaking changes are acceptable, no formal migration guide needed. However, document API changes:

### Breaking Changes in 0.5.0
- Flow identifiers now stable within a trace (may change existing behavior if code relies on identifier values)
- New Ping API (additive, not breaking)
- New Multipath API (additive, not breaking)

---

## CLI Enhancements

### New Commands
```bash
# Ping command
swift-ftr ping <target> [options]
  -c, --count <n>           Number of pings (default: 5)
  -i, --interval <seconds>  Interval between pings (default: 1.0)
  -t, --timeout <seconds>   Timeout per ping (default: 2.0)
  --interface <name>        Network interface to use
  --json                    Output JSON format

# Multipath discovery
swift-ftr multipath <target> [options]
  --flows <n>               Number of flow variations to try (default: 8)
  --max-paths <n>           Max paths to discover (default: 16)
  -m, --max-hops <n>        Max TTL (default: 30)
  --json                    Output JSON format

# List interfaces
swift-ftr interfaces
```

---

## Success Criteria

### Functional
- ✅ Ping API returns accurate latency/jitter/loss metrics
- ✅ Paris Traceroute produces consistent paths
- ✅ Multipath discovery finds multiple ECMP paths
- ✅ Interface binding works correctly
- ✅ All existing tests pass
- ✅ 60% test coverage achieved

### Quality
- ✅ Passes `swift format` checks
- ✅ DocC documentation complete
- ✅ Examples compile and run
- ✅ No compiler warnings under Swift 6

### Performance
- ✅ Ping overhead <10ms vs raw ICMP
- ✅ Multipath discovery <10 seconds for typical networks
- ✅ Memory usage <5MB per operation

---

## Dependencies & Coordination

### NWX Integration
SwiftFTR 0.5.0 will be consumed by NWX multipath monitoring:
- NWX will use `ping()` for continuous hop monitoring
- NWX will use `discoverPaths()` for topology discovery
- Coordinate on timing: NWX needs SwiftFTR 0.5.0 by Week 3 of their Sprint 3

### No External Dependencies
SwiftFTR remains dependency-free except:
- Swift Standard Library
- Darwin/Foundation (for sockets, time)
- Swift Testing (test framework)

---

## Release Process

### Pre-Release Checklist
- [ ] All tests passing
- [ ] Code formatted (`swift format -i -r Sources Tests`)
- [ ] Documentation built successfully
- [ ] Examples tested
- [ ] Performance profiled
- [ ] CHANGELOG.md updated
- [ ] Version bumped to 0.5.0 in Package.swift

### Release Steps
1. Create release branch `release/0.5.0` from `feature/multipath-0.5.0`
2. Final testing and validation
3. Merge to `main`
4. Tag release `v0.5.0`
5. Create GitHub release with notes
6. Update NWX dependency to SwiftFTR 0.5.0

---

## Questions & Clarifications

### Open Questions
1. **UDP Probes**: Should we implement UDP probes in 0.5.0 or defer to 0.6.0?
   - **Recommendation:** Defer to 0.6.0 - ICMP is sufficient for MVP

2. **TCP SYN Probes**: Needed for firewall traversal?
   - **Recommendation:** Defer to 0.6.0 - not critical for initial deployment

3. **Path Persistence**: Should we cache discovered paths?
   - **Recommendation:** No - let NWX handle caching at application level

### Assumptions
- ECMP testing can be done on real networks (may need VPN or specific ISP)
- Interface binding works on all target macOS versions (13+)
- No Linux support needed yet (macOS only for now)

---

*This plan can be executed independently by another agent/developer while NWX application development proceeds in parallel.*