# Multipath Discovery

Use ``SwiftFTR/SwiftFTR`` to discover ECMP paths and enumerate network topology diversity.

## Overview

Multipath discovery performs Dublin Traceroute-style ECMP (Equal-Cost Multi-Path) enumeration by varying the ICMP flow identifier to reveal different paths through load-balanced network infrastructure.

- ICMP-based multipath discovery using flow identifier variations
- Smart path deduplication for intermittent responders
- Early stopping when no new unique paths are found
- Topology analysis: unique hops, common prefix, divergence point
- JSON serialization support for integration

## Basic Discovery

Discover ECMP paths to a destination:

```swift
import SwiftFTR

let tracer = SwiftFTR()
let config = MultipathConfig(flowVariations: 8, maxPaths: 16)
let topology = try await tracer.discoverPaths(to: "8.8.8.8", config: config)

print("Discovered \(topology.uniquePathCount) unique paths")
print("Total flows probed: \(topology.totalFlows)")

for (index, path) in topology.paths.enumerated() {
    if path.isUnique {
        print("Path \(index + 1): \(path.trace.hops.count) hops")
    }
}
```

## Extract Monitoring Targets

Use multipath discovery to identify all hops for monitoring:

```swift
import SwiftFTR

let tracer = SwiftFTR()
let multipathConfig = MultipathConfig(flowVariations: 8, maxPaths: 16)

// Step 1: Discover all ECMP paths
let topology = try await tracer.discoverPaths(to: "example.com", config: multipathConfig)

// Step 2: Extract unique hops (all IPs discovered across paths)
let uniqueHops = topology.uniqueHops()
print("Found \(uniqueHops.count) unique hops to monitor")

// Step 3: Set up continuous monitoring of each hop
let pingConfig = PingConfig(count: 5, interval: 0.5, timeout: 2.0)

for hop in uniqueHops {
    guard let ip = hop.ip else { continue }

    Task {
        while true {
            let result = try await tracer.ping(to: ip, config: pingConfig)
            print("[\(hop.ttl)] \(ip): Avg RTT \(result.statistics.avgRTT.map { String(format: "%.2f ms", $0 * 1000) } ?? "N/A")")
            try await Task.sleep(nanoseconds: 60_000_000_000)  // 60s
        }
    }
}
```

## Path Analysis

Analyze path topology and detect ECMP divergence:

```swift
import SwiftFTR

let tracer = SwiftFTR()
let config = MultipathConfig(flowVariations: 16, maxPaths: 20)
let topology = try await tracer.discoverPaths(to: "1.1.1.1", config: config)

// Find common path prefix (shared hops before ECMP split)
let commonPrefix = topology.commonPrefix()
print("Common prefix: \(commonPrefix.count) hops")

// Find divergence point (where ECMP splitting begins)
if let divergencePoint = topology.divergencePoint() {
    print("ECMP divergence at TTL \(divergencePoint)")
} else {
    print("No ECMP detected (single path)")
}

// Filter paths through specific IP
let pathsThroughIP = topology.paths(throughIP: "192.0.2.1")
print("Paths through 192.0.2.1: \(pathsThroughIP.count)")

// Filter paths through specific ASN
let pathsThroughASN = topology.paths(throughASN: 13335)  // Cloudflare
print("Paths through AS13335: \(pathsThroughASN.count)")
```

## ECMP Detection

Detect when multiple paths exist and monitor for changes:

```swift
import SwiftFTR

let tracer = SwiftFTR()
let config = MultipathConfig(flowVariations: 8, maxPaths: 16)

func detectECMP() async throws {
    let topology = try await tracer.discoverPaths(to: "example.com", config: config)

    if topology.uniquePathCount > 1 {
        print("✓ ECMP detected: \(topology.uniquePathCount) unique paths")
        if let div = topology.divergencePoint() {
            print("  Divergence at TTL \(div)")
        }
    } else {
        print("✗ No ECMP: single path to destination")
    }
}

// Monitor for path changes
while true {
    try await detectECMP()
    try await Task.sleep(nanoseconds: 300_000_000_000)  // 5 minutes
}
```

## JSON Export

Export topology for external analysis:

```swift
import SwiftFTR
import Foundation

let tracer = SwiftFTR()
let config = MultipathConfig(flowVariations: 8, maxPaths: 16)
let topology = try await tracer.discoverPaths(to: "8.8.8.8", config: config)

let encoder = JSONEncoder()
encoder.outputFormatting = .prettyPrinted
let jsonData = try encoder.encode(topology)

if let jsonString = String(data: jsonData, encoding: .utf8) {
    print(jsonString)
}
```

## Notes

### ICMP vs UDP Multipath

**Current implementation (v0.5.0) uses ICMP-based multipath discovery**, which has important limitations:

- Many ECMP routers **do not hash ICMP ID field** for load balancing decisions
- ICMP-based discovery may find **significantly fewer paths** than UDP-based tools
- UDP varies destination port (5-tuple hashing) which routers actively use for ECMP

**Real-world example:**
- ICMP multipath to 8.8.8.8: **1 unique path**
- UDP multipath (dublin-traceroute) to 8.8.8.8: **7 unique paths**

**When to use:**
- **ICMP multipath**: Accurately reflects diversity of ICMP ping monitoring paths
- **UDP multipath**: Accurately reflects diversity of TCP/UDP application paths (planned v0.5.5)

See `docs/development/ROADMAP.md` for UDP multipath implementation plans.

## Topics

### Configuration

- ``SwiftFTR/MultipathConfig``

### Results

- ``SwiftFTR/NetworkTopology``
- ``SwiftFTR/DiscoveredPath``

### Operations

- ``SwiftFTR/SwiftFTR/discoverPaths(to:config:)``