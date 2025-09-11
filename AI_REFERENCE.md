# SwiftFTR Complete API Reference for AI Agents

## Overview
SwiftFTR is a Swift library for performing fast, parallel traceroute operations on macOS without requiring sudo privileges. It uses ICMP datagram sockets, provides ASN classification, reverse DNS lookups, and includes caching mechanisms.

## Core Requirements
- **Platform**: macOS 13.0+
- **Swift**: 6.1+
- **Permissions**: No sudo required (uses SOCK_DGRAM)
- **Concurrency**: Actor-based architecture with Swift 6 strict concurrency

## Installation

### Swift Package Manager
```swift
dependencies: [
    .package(url: "https://github.com/Network-Weather/SwiftFTR.git", from: "0.3.0")
]
```

## Primary Types and Structures

### 1. SwiftFTR (Main Actor)
The primary entry point for all traceroute operations. Thread-safe actor with built-in caching.

```swift
public actor SwiftFTR {
    // Initialize with optional configuration
    public init(config: SwiftFTRConfig = SwiftFTRConfig())
    
    // Perform basic traceroute
    public func trace(to host: String) async throws -> TraceResult
    
    // Perform traceroute with ASN classification
    public func traceClassified(
        to host: String,
        resolver: ASNResolver? = nil
    ) async throws -> ClassifiedTrace
    
    // Handle network changes (cancels traces, clears caches)
    public func networkChanged() async
    
    // Get cached public IP if available
    public var publicIP: String? { get }
    
    // Clear all caches
    public func clearCaches() async
    
    // Invalidate just public IP cache
    public func invalidatePublicIP()
}
```

### 2. SwiftFTRConfig (Configuration)
Configuration for traceroute behavior and caching.

```swift
public struct SwiftFTRConfig: Sendable {
    public let maxHops: Int           // Maximum TTL to probe (default: 30)
    public let maxWaitMs: Int          // Timeout in milliseconds (default: 1000)
    public let payloadSize: Int        // ICMP payload size in bytes (default: 56)
    public let publicIP: String?       // Override public IP (default: nil, auto-detect)
    public let enableLogging: Bool     // Enable debug logging (default: false)
    public let noReverseDNS: Bool      // Disable rDNS lookups (default: false)
    public let rdnsCacheTTL: TimeInterval?  // rDNS cache TTL seconds (default: 86400)
    public let rdnsCacheSize: Int?     // Max rDNS cache entries (default: 1000)
    
    public init(
        maxHops: Int = 30,
        maxWaitMs: Int = 1000,
        payloadSize: Int = 56,
        publicIP: String? = nil,
        enableLogging: Bool = false,
        noReverseDNS: Bool = false,
        rdnsCacheTTL: TimeInterval? = nil,
        rdnsCacheSize: Int? = nil
    )
}
```

### 3. TraceResult (Basic Output)
Result from a basic traceroute operation.

```swift
public struct TraceResult: Sendable {
    public let destination: String     // Target hostname/IP as provided
    public let maxHops: Int            // Maximum TTL probed
    public let reached: Bool           // Whether destination responded
    public let hops: [TraceHop]        // Ordered hop results
    public let duration: TimeInterval  // Total trace duration in seconds
}
```

### 4. TraceHop (Individual Hop)
Information about a single hop in the traceroute path. Each hop represents a router or device that responded to the ICMP probe.

```swift
public struct TraceHop: Sendable {
    public let ttl: Int                // Time-to-live value (1-based)
    public let ipAddress: String?      // Responder IP (nil if timeout)
    public let rtt: TimeInterval?      // Round-trip time in seconds
    public let reachedDestination: Bool // Is this the final destination?
    public let hostname: String?       // Reverse DNS hostname if available
    
    public init(
        ttl: Int,
        ipAddress: String?,
        rtt: TimeInterval?,
        reachedDestination: Bool,
        hostname: String? = nil
    )
}
```

**Field Details:**
- `ttl`: The hop number in sequence (1 = first hop, usually your router)
- `ipAddress`: IP address that responded, `nil` means no response (timeout)
- `rtt`: Round-trip time in seconds (multiply by 1000 for milliseconds)
- `reachedDestination`: `true` only for the final hop if it matches the target
- `hostname`: Reverse DNS name if rDNS is enabled and lookup succeeded

**Sample TraceHop Data:**
```swift
// Hop 1: Local router
TraceHop(
    ttl: 1,
    ipAddress: "192.168.1.1",
    rtt: 0.002341,  // 2.341 ms
    reachedDestination: false,
    hostname: "router.local"
)

// Hop 5: ISP router
TraceHop(
    ttl: 5,
    ipAddress: "68.85.123.45",
    rtt: 0.012567,  // 12.567 ms
    reachedDestination: false,
    hostname: "ae-5-5.cr1.sfo1.example-isp.net"
)

// Hop 8: Timeout (no response)
TraceHop(
    ttl: 8,
    ipAddress: nil,
    rtt: nil,
    reachedDestination: false,
    hostname: nil
)

// Final hop: Destination reached
TraceHop(
    ttl: 12,
    ipAddress: "142.250.185.78",
    rtt: 0.025123,  // 25.123 ms
    reachedDestination: true,
    hostname: "sea30s10-in-f14.1e100.net"
)
```

### 5. ClassifiedTrace (Enhanced Output)
Result from traceClassified with ASN and categorization.

```swift
public struct ClassifiedTrace: Sendable, Codable {
    public let destinationHost: String      // Original target
    public let destinationIP: String        // Resolved destination IP
    public let destinationHostname: String? // rDNS of destination
    public let publicIP: String?            // Client's public IP
    public let publicHostname: String?      // rDNS of public IP
    public let clientASN: Int?              // Client's ASN
    public let clientASName: String?        // Client's AS name
    public let destinationASN: Int?         // Destination's ASN
    public let destinationASName: String?   // Destination's AS name
    public let hops: [ClassifiedHop]        // Classified hop data
}
```

### 6. ClassifiedHop (Enhanced Hop)
Hop with ASN and category information. This includes network ownership and path segmentation data.

```swift
public struct ClassifiedHop: Sendable, Codable {
    public let ttl: Int                // Time-to-live value
    public let ip: String?             // Responder IP address
    public let rtt: TimeInterval?      // Round-trip time in seconds
    public let asn: Int?               // Autonomous System Number
    public let asName: String?         // AS organization name
    public let category: HopCategory   // Classification category
    public let hostname: String?       // Reverse DNS hostname
}
```

**Complete Sample of Classified Trace Data:**
```swift
// Full trace from residential network to google.com
ClassifiedTrace(
    destinationHost: "google.com",
    destinationIP: "142.250.185.78",
    destinationHostname: "sea30s10-in-f14.1e100.net",
    publicIP: "73.162.XXX.XXX",
    publicHostname: "c-73-162-xxx-xxx.hsd1.ca.comcast.net",
    clientASN: 7922,
    clientASName: "COMCAST-7922",
    destinationASN: 15169,
    destinationASName: "GOOGLE",
    hops: [
        // LOCAL segment (home network)
        ClassifiedHop(
            ttl: 1,
            ip: "192.168.1.1",
            rtt: 0.002145,  // 2.145 ms
            asn: nil,       // Private IP has no ASN
            asName: nil,
            category: .local,
            hostname: "router.asus.com"
        ),
        
        // ISP segment (Comcast network)
        ClassifiedHop(
            ttl: 2,
            ip: "100.64.0.1",  // CGNAT address
            rtt: 0.008234,
            asn: nil,
            asName: nil,
            category: .isp,
            hostname: nil
        ),
        ClassifiedHop(
            ttl: 3,
            ip: "68.85.221.161",
            rtt: 0.009876,
            asn: 7922,
            asName: "COMCAST-7922",
            category: .isp,
            hostname: "po-303-1215-rur01.santaclara.ca.sfba.comcast.net"
        ),
        ClassifiedHop(
            ttl: 4,
            ip: "68.86.143.93",
            rtt: 0.011234,
            asn: 7922,
            asName: "COMCAST-7922", 
            category: .isp,
            hostname: "ae-236-rar01.santaclara.ca.sfba.comcast.net"
        ),
        ClassifiedHop(
            ttl: 5,
            ip: "69.241.75.194",
            rtt: 0.012567,
            asn: 7922,
            asName: "COMCAST-7922",
            category: .isp,
            hostname: "be-33651-cr01.sunnyvale.ca.ibone.comcast.net"
        ),
        
        // TRANSIT segment (interconnection)
        ClassifiedHop(
            ttl: 6,
            ip: "96.110.32.225",
            rtt: 0.014234,
            asn: 7922,
            asName: "COMCAST-7922",
            category: .transit,
            hostname: "be-2211-pe11.529bryant.ca.ibone.comcast.net"
        ),
        ClassifiedHop(
            ttl: 7,
            ip: nil,  // No response
            rtt: nil,
            asn: nil,
            asName: nil,
            category: .transit,
            hostname: nil
        ),
        ClassifiedHop(
            ttl: 8,
            ip: "108.170.241.97",
            rtt: 0.021456,
            asn: 15169,
            asName: "GOOGLE",
            category: .transit,
            hostname: nil
        ),
        ClassifiedHop(
            ttl: 9,
            ip: "142.251.65.205",
            rtt: 0.023123,
            asn: 15169,
            asName: "GOOGLE",
            category: .transit,
            hostname: nil
        ),
        
        // DESTINATION segment (Google's network)
        ClassifiedHop(
            ttl: 10,
            ip: "142.250.185.78",
            rtt: 0.024567,
            asn: 15169,
            asName: "GOOGLE",
            category: .destination,
            hostname: "sea30s10-in-f14.1e100.net"
        )
    ]
)
```

**Category Segmentation Explained:**
- **LOCAL**: Private IP ranges (192.168.x.x, 10.x.x.x, 172.16-31.x.x) - your local network
- **ISP**: Hops within your Internet Service Provider's network (same ASN as your public IP)
- **TRANSIT**: Intermediate networks between ISP and destination, includes peering points
- **DESTINATION**: Hops within the destination's AS network
- **UNKNOWN**: Hops that couldn't be classified (no ASN data or timeouts)

### 7. HopCategory (Classification)
Categories for hop classification.

```swift
public enum HopCategory: String, Sendable, Codable {
    case local = "LOCAL"           // Private/local network
    case isp = "ISP"              // Internet Service Provider
    case transit = "TRANSIT"       // Transit provider
    case destination = "DESTINATION" // Target network
    case unknown = "UNKNOWN"       // Unclassified
}
```

### 8. TracerouteError (Error Types)
Possible errors during traceroute operations.

```swift
public enum TracerouteError: Error, CustomStringConvertible {
    case resolutionFailed(host: String, details: String?)
    case socketCreateFailed(errno: Int32, details: String)
    case setsockoptFailed(option: String, errno: Int32)
    case sendFailed(errno: Int32)
    case invalidConfiguration(reason: String)
    case platformNotSupported(details: String)
    case cancelled  // Trace was cancelled via TraceHandle
}
```

### 9. ASNResolver (Protocol)
Protocol for ASN resolution implementations.

```swift
public protocol ASNResolver {
    func resolve(ipv4Addrs: [String], timeout: TimeInterval) throws -> [String: ASNInfo]
}
```

### 10. ASNInfo (ASN Data)
Information about an Autonomous System.

```swift
public struct ASNInfo: Sendable, Codable {
    public let asn: Int           // AS number
    public let name: String?      // Organization name
    public let prefix: String?    // IP prefix
    public let countryCode: String? // Country code
    public let registry: String?  // Regional registry
}
```

### 11. CachingASNResolver
ASN resolver with in-memory caching.

```swift
public struct CachingASNResolver: ASNResolver {
    public init(base: ASNResolver)
    public func resolve(ipv4Addrs: [String], timeout: TimeInterval) throws -> [String: ASNInfo]
}
```

### 12. CymruDNSResolver
DNS-based ASN resolver using Team Cymru.

```swift
public struct CymruDNSResolver: ASNResolver {
    public init()
    public func resolve(ipv4Addrs: [String], timeout: TimeInterval = 1.0) throws -> [String: ASNInfo]
}
```

### 13. TraceHandle (Cancellation)
Actor for managing trace cancellation.

```swift
public actor TraceHandle {
    public var isCancelled: Bool { get }
    public func cancel()
}
```

## Working with Trace Results

### Understanding the Data Structure
When you perform a trace, the data comes back in a hierarchical structure. Here's how to interpret and work with it:

```swift
// Basic trace result structure
let result = try await tracer.trace(to: "example.com")

// Access key information
print("Target: \(result.destination)")
print("Reached: \(result.reached)")
print("Total hops: \(result.hops.count)")
print("Time taken: \(result.duration) seconds")

// Iterate through hops
for hop in result.hops {
    if let ip = hop.ipAddress {
        let ms = (hop.rtt ?? 0) * 1000
        print("Hop \(hop.ttl): \(ip) - \(String(format: "%.2f ms", ms))")
        
        if let hostname = hop.hostname {
            print("  Hostname: \(hostname)")
        }
        
        if hop.reachedDestination {
            print("  ✓ Destination reached!")
        }
    } else {
        print("Hop \(hop.ttl): * (timeout)")
    }
}

// Find specific information
let responseCount = result.hops.filter { $0.ipAddress != nil }.count
let timeoutCount = result.hops.filter { $0.ipAddress == nil }.count
let avgRTT = result.hops.compactMap { $0.rtt }.reduce(0, +) / Double(responseCount)

print("\nStatistics:")
print("Responses: \(responseCount)/\(result.hops.count)")
print("Timeouts: \(timeoutCount)")
print("Average RTT: \(String(format: "%.2f ms", avgRTT * 1000))")
```

### Working with Classified/Segmented Data
The classified trace provides network segment analysis:

```swift
let classified = try await tracer.traceClassified(to: "netflix.com")

// Group hops by category
let segments = Dictionary(grouping: classified.hops) { $0.category }

// Analyze each segment
for category in HopCategory.allCases {
    if let hops = segments[category] {
        print("\n\(category.rawValue) segment:")
        print("  Hops: \(hops.map { $0.ttl }.sorted())")
        
        // Get unique ASNs in this segment
        let asns = Set(hops.compactMap { $0.asn })
        for asn in asns {
            let asName = hops.first { $0.asn == asn }?.asName ?? "Unknown"
            print("  AS\(asn): \(asName)")
        }
        
        // Calculate segment latency
        if let firstRTT = hops.first?.rtt,
           let lastRTT = hops.last?.rtt {
            let segmentLatency = (lastRTT - firstRTT) * 1000
            print("  Segment latency: \(String(format: "%.2f ms", segmentLatency))")
        }
    }
}

// Identify network transitions
var transitions: [(from: String, to: String, atHop: Int)] = []
for i in 1..<classified.hops.count {
    let prevHop = classified.hops[i-1]
    let currHop = classified.hops[i]
    
    if prevHop.asn != currHop.asn,
       let prevASN = prevHop.asn,
       let currASN = currHop.asn {
        let from = prevHop.asName ?? "AS\(prevASN)"
        let to = currHop.asName ?? "AS\(currASN)"
        transitions.append((from: from, to: to, atHop: currHop.ttl))
    }
}

print("\nNetwork transitions:")
for transition in transitions {
    print("  Hop \(transition.atHop): \(transition.from) → \(transition.to)")
}
```

### Detecting Network Issues
Use trace data to identify potential problems:

```swift
func analyzeTraceForIssues(_ result: TraceResult) -> [String] {
    var issues: [String] = []
    
    // Check for excessive timeouts
    let timeouts = result.hops.filter { $0.ipAddress == nil }.count
    let timeoutRate = Double(timeouts) / Double(result.hops.count)
    if timeoutRate > 0.3 {
        issues.append("High timeout rate: \(Int(timeoutRate * 100))%")
    }
    
    // Check for routing loops (same IP appearing multiple times)
    let ipCounts = result.hops.compactMap { $0.ipAddress }
        .reduce(into: [:]) { counts, ip in counts[ip, default: 0] += 1 }
    for (ip, count) in ipCounts where count > 1 {
        issues.append("Possible routing loop: \(ip) appears \(count) times")
    }
    
    // Check for high latency jumps
    let rtts = result.hops.compactMap { $0.rtt }
    for i in 1..<rtts.count {
        let jump = (rtts[i] - rtts[i-1]) * 1000
        if jump > 50 {  // 50ms jump
            let hopNum = result.hops.firstIndex { $0.rtt == rtts[i] }! + 1
            issues.append("Large latency increase at hop \(hopNum): +\(String(format: "%.1f", jump))ms")
        }
    }
    
    // Check if destination was reached
    if !result.reached {
        issues.append("Destination not reached within \(result.maxHops) hops")
    }
    
    return issues
}

// Usage
let issues = analyzeTraceForIssues(result)
if !issues.isEmpty {
    print("Potential issues detected:")
    for issue in issues {
        print("  ⚠️ \(issue)")
    }
}
```

## Complete Usage Examples

### Example 1: Basic Traceroute
```swift
import SwiftFTR

// Initialize tracer with default config
let tracer = SwiftFTR()

// Perform basic trace
do {
    let result = try await tracer.trace(to: "google.com")
    
    print("Tracing to \(result.destination)")
    print("Reached: \(result.reached)")
    print("Duration: \(result.duration) seconds")
    
    for hop in result.hops {
        let ip = hop.ipAddress ?? "*"
        let hostname = hop.hostname ?? ""
        let rtt = hop.rtt.map { String(format: "%.3f ms", $0 * 1000) } ?? "timeout"
        print("\(hop.ttl)\t\(ip)\t\(hostname)\t\(rtt)")
    }
} catch {
    print("Trace failed: \(error)")
}
```

### Example 2: Traceroute with Custom Configuration
```swift
let config = SwiftFTRConfig(
    maxHops: 20,           // Limit to 20 hops
    maxWaitMs: 2000,       // 2 second timeout
    payloadSize: 64,       // 64 byte payload
    publicIP: nil,         // Auto-detect public IP
    enableLogging: true,   // Enable debug logs
    noReverseDNS: false,   // Enable rDNS lookups
    rdnsCacheTTL: 3600,    // 1 hour cache
    rdnsCacheSize: 500     // Cache up to 500 entries
)

let tracer = SwiftFTR(config: config)
let result = try await tracer.trace(to: "1.1.1.1")
```

### Example 3: Classified Traceroute with ASN
```swift
let tracer = SwiftFTR()

do {
    let classified = try await tracer.traceClassified(to: "cloudflare.com")
    
    print("Target: \(classified.destinationHost) (\(classified.destinationIP))")
    print("Public IP: \(classified.publicIP ?? "unknown")")
    print("Client AS: AS\(classified.clientASN ?? 0) - \(classified.clientASName ?? "unknown")")
    print("Destination AS: AS\(classified.destinationASN ?? 0) - \(classified.destinationASName ?? "unknown")")
    
    for hop in classified.hops {
        let ip = hop.ip ?? "*"
        let asInfo = hop.asn.map { "AS\($0)" } ?? ""
        let category = hop.category.rawValue
        let hostname = hop.hostname ?? ""
        print("\(hop.ttl)\t\(ip)\t\(hostname)\t\(category)\t\(asInfo)")
    }
} catch {
    print("Classification failed: \(error)")
}
```

### Example 4: Handling Network Changes
```swift
let tracer = SwiftFTR()

// When network changes (e.g., WiFi to cellular)
await tracer.networkChanged()

// This will:
// 1. Cancel all active traces
// 2. Clear public IP cache
// 3. Clear rDNS cache
// 4. Force fresh lookups on next trace
```

### Example 5: Concurrent Traces
```swift
let tracer = SwiftFTR()
let targets = ["google.com", "cloudflare.com", "github.com"]

// Run traces concurrently
let results = await withTaskGroup(of: (String, Result<TraceResult, Error>).self) { group in
    for target in targets {
        group.addTask {
            do {
                let result = try await tracer.trace(to: target)
                return (target, .success(result))
            } catch {
                return (target, .failure(error))
            }
        }
    }
    
    var allResults: [(String, Result<TraceResult, Error>)] = []
    for await result in group {
        allResults.append(result)
    }
    return allResults
}

for (target, result) in results {
    switch result {
    case .success(let trace):
        print("\(target): \(trace.hops.count) hops, reached: \(trace.reached)")
    case .failure(let error):
        print("\(target): failed - \(error)")
    }
}
```

### Example 6: Custom ASN Resolver
```swift
// Use caching resolver with custom base
let baseResolver = CymruDNSResolver()
let cachingResolver = CachingASNResolver(base: baseResolver)

let tracer = SwiftFTR()
let classified = try await tracer.traceClassified(
    to: "example.com",
    resolver: cachingResolver
)
```

### Example 7: Trace with Cancellation
```swift
let tracer = SwiftFTR()

// Start trace in a task
let traceTask = Task {
    do {
        let result = try await tracer.trace(to: "slow-server.com")
        return result
    } catch TracerouteError.cancelled {
        print("Trace was cancelled")
        return nil
    }
}

// Cancel after 500ms if needed
Task {
    try await Task.sleep(nanoseconds: 500_000_000)
    traceTask.cancel()
}

let result = await traceTask.value
```

### Example 8: JSON Serialization
```swift
let tracer = SwiftFTR()
let classified = try await tracer.traceClassified(to: "apple.com")

// Encode to JSON
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let jsonData = try encoder.encode(classified)
let jsonString = String(data: jsonData, encoding: .utf8)!
print(jsonString)

// Decode from JSON
let decoder = JSONDecoder()
let decoded = try decoder.decode(ClassifiedTrace.self, from: jsonData)
```

### Example 9: Error Handling
```swift
let tracer = SwiftFTR()

do {
    let result = try await tracer.trace(to: "invalid..hostname")
} catch let error as TracerouteError {
    switch error {
    case .resolutionFailed(let host, let details):
        print("DNS failed for \(host): \(details ?? "unknown")")
    case .socketCreateFailed(let errno, let details):
        print("Socket error \(errno): \(details)")
    case .cancelled:
        print("Trace was cancelled")
    case .invalidConfiguration(let reason):
        print("Bad config: \(reason)")
    default:
        print("Error: \(error.description)")
    }
} catch {
    print("Unexpected error: \(error)")
}
```

### Example 10: Cache Management
```swift
let tracer = SwiftFTR()

// Check cached public IP
if let publicIP = await tracer.publicIP {
    print("Cached public IP: \(publicIP)")
}

// Force public IP refresh
await tracer.invalidatePublicIP()

// Clear all caches
await tracer.clearCaches()

// Network change (comprehensive reset)
await tracer.networkChanged()
```

## Utility Functions

### IP Classification
```swift
// Check if IP is private (RFC1918)
public func isPrivateIPv4(_ ipStr: String) -> Bool

// Check if IP is CGNAT (RFC6598)
public func isCGNATIPv4(_ ipStr: String) -> Bool

// Perform reverse DNS lookup
public func reverseDNS(_ ip: String) -> String?

// Convert sockaddr_in to IP string
public func ipString(_ addr: sockaddr_in) -> String

// Resolve hostname to IPv4
public func resolveIPv4(host: String, enableLogging: Bool = false) throws -> sockaddr_in
```

### STUN Public IP Discovery
```swift
public struct STUNPublicIP: Sendable {
    public let ip: String
}

// Discover public IP via STUN
public func stunGetPublicIPv4(
    timeout: TimeInterval = 1.0,
    server: String = "stun.cloudflare.com",
    port: UInt16 = 3478
) throws -> STUNPublicIP
```

## Performance Characteristics

### Time Complexity
- **Single trace**: O(1) with respect to hop count (parallel probing)
- **Wall time**: Bounded by configured timeout (typically ~1 second)

### Memory Usage
- **Per trace**: ~5KB base + hop data
- **ASN cache**: Configurable, default unbounded
- **rDNS cache**: Configurable, default 1000 entries with LRU eviction

### Caching Behavior
- **ASN lookups**: Cached indefinitely in memory
- **rDNS lookups**: Cached with TTL (default 86400 seconds)
- **Public IP**: Cached until network change
- **Cache invalidation**: Via networkChanged() or clearCaches()

## Thread Safety and Concurrency

### Actor Isolation
- SwiftFTR is an actor - all methods require `await`
- TraceHandle is an actor for cancellation
- RDNSCache is an internal actor

### Concurrent Operations
- Multiple traces can run concurrently
- rDNS batch lookups are parallelized
- ASN lookups are batched

### Sendable Conformance
- All public types conform to Sendable
- Safe to pass between actor boundaries
- No data races under Swift 6 strict concurrency

## Network Protocols Used

### ICMP
- **Type**: ICMP Echo Request (Type 8)
- **Socket**: SOCK_DGRAM with IPPROTO_ICMP
- **Permissions**: No root required on macOS

### DNS
- **ASN lookups**: TXT queries to origin.asn.cymru.com
- **rDNS lookups**: PTR queries for reverse DNS

### STUN
- **Protocol**: RFC 5389 STUN Binding Request
- **Server**: Default stun.cloudflare.com:3478
- **Purpose**: Public IP discovery behind NAT

## Best Practices

### 1. Reuse SwiftFTR Instance
```swift
// Good: Create once, use many times
let tracer = SwiftFTR()
for target in targets {
    let result = try await tracer.trace(to: target)
}

// Avoid: Creating new instance each time
for target in targets {
    let tracer = SwiftFTR()  // Inefficient
    let result = try await tracer.trace(to: target)
}
```

### 2. Handle Network Changes
```swift
// Monitor network changes
NotificationCenter.default.publisher(for: .networkChanged)
    .sink { _ in
        Task {
            await tracer.networkChanged()
        }
    }
```

### 3. Use Appropriate Timeout
```swift
// Fast network: shorter timeout
let config = SwiftFTRConfig(maxWaitMs: 500)

// Slow/distant targets: longer timeout
let config = SwiftFTRConfig(maxWaitMs: 3000)
```

### 4. Batch Operations
```swift
// Good: Concurrent traces
await withTaskGroup(of: TraceResult?.self) { group in
    for target in targets {
        group.addTask {
            try? await tracer.trace(to: target)
        }
    }
}
```

### 5. Error Recovery
```swift
func traceWithRetry(to host: String, retries: Int = 3) async throws -> TraceResult {
    for attempt in 1...retries {
        do {
            return try await tracer.trace(to: host)
        } catch TracerouteError.sendFailed where attempt < retries {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            continue
        }
    }
    throw TracerouteError.sendFailed(errno: 0)
}
```

## Limitations

### Platform Support
- **macOS only**: Requires macOS 13.0+
- **IPv4 only**: IPv6 not yet supported
- **ICMP only**: No UDP/TCP probe support

### Network Restrictions
- May be blocked by firewalls
- ICMP rate limiting may affect results
- Some routers don't respond to ICMP

### Performance Limits
- Maximum 255 hops (IP TTL limit)
- Single socket per trace
- DNS lookups may be slow

## Debugging

### Enable Logging
```swift
let config = SwiftFTRConfig(enableLogging: true)
let tracer = SwiftFTR(config: config)
```

### Check Socket Permissions
```swift
// Will throw socketCreateFailed if no permission
do {
    _ = try await tracer.trace(to: "1.1.1.1")
} catch TracerouteError.socketCreateFailed(let errno, let details) {
    print("Socket error \(errno): \(details)")
}
```

### Verify DNS Resolution
```swift
do {
    let addr = try resolveIPv4(host: "example.com", enableLogging: true)
    print("Resolved to: \(ipString(addr))")
} catch {
    print("Resolution failed: \(error)")
}
```

## Integration with SwiftUI

### ObservableObject Pattern
```swift
@MainActor
class TraceViewModel: ObservableObject {
    @Published var hops: [TraceHop] = []
    @Published var isTracing = false
    @Published var error: Error?
    
    private let tracer = SwiftFTR()
    
    func trace(to host: String) async {
        isTracing = true
        error = nil
        hops = []
        
        do {
            let result = try await tracer.trace(to: host)
            hops = result.hops
        } catch {
            self.error = error
        }
        
        isTracing = false
    }
}
```

### SwiftUI View
```swift
struct TraceView: View {
    @StateObject private var viewModel = TraceViewModel()
    @State private var destination = ""
    
    var body: some View {
        VStack {
            HStack {
                TextField("Destination", text: $destination)
                Button("Trace") {
                    Task {
                        await viewModel.trace(to: destination)
                    }
                }
                .disabled(viewModel.isTracing)
            }
            
            List(viewModel.hops, id: \.ttl) { hop in
                HStack {
                    Text("#\(hop.ttl)")
                    Text(hop.ipAddress ?? "*")
                    Spacer()
                    if let rtt = hop.rtt {
                        Text(String(format: "%.1f ms", rtt * 1000))
                    }
                }
            }
            
            if let error = viewModel.error {
                Text("Error: \(error.localizedDescription)")
                    .foregroundColor(.red)
            }
        }
    }
}
```

## CLI Usage (swift-ftr)

The library includes a CLI tool:

```bash
# Build
swift build -c release

# Basic trace
.build/release/swift-ftr google.com

# With options
.build/release/swift-ftr example.com \
    --max-hops 20 \
    --timeout 2.0 \
    --payload-size 64 \
    --json \
    --no-rdns \
    --public-ip 1.2.3.4
```

## Environment Variables (CLI Only)

- `PTR_PUBLIC_IP`: Override public IP detection
- `PTR_SKIP_STUN`: Skip STUN discovery (set to 1)
- `PTR_VERBOSE`: Enable verbose output

## Testing

### Unit Testing
```swift
import XCTest
@testable import SwiftFTR

class SwiftFTRTests: XCTestCase {
    func testBasicTrace() async throws {
        let tracer = SwiftFTR()
        let result = try await tracer.trace(to: "1.1.1.1")
        XCTAssertTrue(result.hops.count > 0)
        XCTAssertTrue(result.hops.first?.ttl == 1)
    }
}
```

### Integration Testing
```swift
func testNetworkChange() async throws {
    let tracer = SwiftFTR()
    
    // First trace
    _ = try await tracer.trace(to: "google.com")
    let publicIP1 = await tracer.publicIP
    
    // Simulate network change
    await tracer.networkChanged()
    
    // Second trace
    _ = try await tracer.trace(to: "google.com")
    let publicIP2 = await tracer.publicIP
    
    // Public IP should be re-discovered
    XCTAssertNotNil(publicIP2)
}
```

## Migration from v0.2.0 to v0.3.0

### Actor-based API
```swift
// Old (v0.2.0)
let tracer = SwiftFTR()
let result = try await tracer.trace(to: "example.com")

// New (v0.3.0) - Same API, but SwiftFTR is now an actor
let tracer = SwiftFTR()
let result = try await tracer.trace(to: "example.com")
```

### New Features in v0.3.0
- Trace cancellation support
- rDNS with caching
- STUN public IP caching
- Network change handling
- Actor-based architecture

## Summary

SwiftFTR provides a comprehensive, production-ready traceroute implementation for macOS with:
- No sudo requirements
- Parallel probing for speed
- ASN classification
- rDNS support
- Caching for performance
- Thread-safe actor design
- Swift 6 concurrency compliance

Use it for network diagnostics, monitoring, path analysis, and understanding internet routing from Swift applications.