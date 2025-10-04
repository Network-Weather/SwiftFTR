# SwiftFTR Examples

## Table of Contents
- [Basic Usage](#basic-usage)
- [Configuration Options](#configuration-options)
- [Ping (v0.5.0+)](#ping-v050)
- [Multipath Discovery (v0.5.0+)](#multipath-discovery-v050)
- [Bufferbloat Detection (v0.5.1+)](#bufferbloat-detection-v051)
- [SwiftUI Integration](#swiftui-integration)
- [Concurrent Traces](#concurrent-traces)
- [Error Handling](#error-handling)
- [ASN Classification](#asn-classification)
- [Custom Resolvers](#custom-resolvers)
- [Performance Monitoring](#performance-monitoring)

## Basic Usage

### Simple Trace
```swift
import SwiftFTR

// Create tracer with default configuration
let tracer = SwiftFTR()

// Perform trace
let result = try await tracer.trace(to: "example.com")

// Process results
print("Traced to \(result.destination)")
print("Found \(result.hops.count) hops")
print("Reached destination: \(result.reached)")

for hop in result.hops {
    if let ip = hop.ipAddress {
        let rtt = hop.rtt.map { String(format: "%.2f ms", $0 * 1000) } ?? "timeout"
        print("  \(hop.ttl): \(ip) (\(rtt))")
    } else {
        print("  \(hop.ttl): * * *")
    }
}
```

## Configuration Options

### Custom Configuration
```swift
import SwiftFTR

// Configure all options
let config = SwiftFTRConfig(
    maxHops: 20,           // Maximum TTL to probe (default: 30)
    maxWaitMs: 2000,       // Max wait time in milliseconds (default: 1000)
    payloadSize: 32,       // ICMP payload size in bytes (default: 56)
    publicIP: "1.2.3.4",   // Override public IP (skips STUN)
    enableLogging: true    // Enable debug logging (default: false)
)

let tracer = SwiftFTR(config: config)
```

### Quick Trace with Minimal Hops
```swift
// For local network diagnostics
let localConfig = SwiftFTRConfig(
    maxHops: 5,
    maxWaitMs: 500
)
let localTracer = SwiftFTR(config: localConfig)
let result = try await localTracer.trace(to: "192.168.1.1")
```

### Production Configuration
```swift
// Optimized for production use
let prodConfig = SwiftFTRConfig(
    maxHops: 30,
    maxWaitMs: 1500,
    payloadSize: 56,
    enableLogging: false  // Disable logging in production
)
let prodTracer = SwiftFTR(config: prodConfig)
```

### Network Interface Selection (v0.4.0+)
```swift
// Use specific network interface
let wifiConfig = SwiftFTRConfig(
    maxHops: 30,
    interface: "en0"  // WiFi interface on macOS
)
let wifiTracer = SwiftFTR(config: wifiConfig)

// Use ethernet interface
let ethernetConfig = SwiftFTRConfig(
    maxHops: 30,
    interface: "en1"  // Ethernet interface
)
let ethernetTracer = SwiftFTR(config: ethernetConfig)

// Bind to specific source IP
let sourceIPConfig = SwiftFTRConfig(
    maxHops: 30,
    sourceIP: "192.168.1.100"  // Use specific local IP
)
let sourceTracer = SwiftFTR(config: sourceIPConfig)

// Combine interface and source IP for precise control
let preciseConfig = SwiftFTRConfig(
    maxHops: 30,
    interface: "en0",
    sourceIP: "192.168.1.100"  // Must be an IP on en0
)
let preciseTracer = SwiftFTR(config: preciseConfig)

// Handle interface binding errors
do {
    let result = try await preciseTracer.trace(to: "example.com")
    print("Trace completed via \(preciseConfig.interface ?? "default")")
} catch TracerouteError.interfaceBindFailed(let iface, let errno, let details) {
    print("Failed to bind to interface \(iface): \(details ?? "")")
} catch TracerouteError.sourceIPBindFailed(let ip, let errno, let details) {
    print("Failed to bind to source IP \(ip): \(details ?? "")")
}
```

## Ping (v0.5.0+)

### Basic Ping
```swift
import SwiftFTR

// Create tracer and ping configuration
let tracer = SwiftFTR()
let config = PingConfig(
    count: 5,           // Number of pings (default: 5)
    interval: 1.0,      // Interval between pings in seconds (default: 1.0)
    timeout: 2.0,       // Timeout per ping in seconds (default: 2.0)
    payloadSize: 56     // ICMP payload size (default: 56)
)

// Perform ping
let result = try await tracer.ping(to: "1.1.1.1", config: config)

// Process results
print("PING \(result.target) (\(result.resolvedIP))")
print("Statistics: \(result.statistics.sent) sent, \(result.statistics.received) received, \(Int(result.statistics.packetLoss * 100))% packet loss")

if let avgRTT = result.statistics.avgRTT {
    print("Average RTT: \(String(format: "%.2f", avgRTT * 1000)) ms")
}
if let jitter = result.statistics.jitter {
    print("Jitter: \(String(format: "%.2f", jitter * 1000)) ms")
}
```

### Continuous Ping Monitoring
```swift
import SwiftFTR

actor PingMonitor {
    private let tracer = SwiftFTR()
    private var isRunning = false

    func startMonitoring(target: String, interval: TimeInterval = 60.0) async {
        guard !isRunning else { return }
        isRunning = true

        let config = PingConfig(count: 5, interval: 0.5, timeout: 2.0)

        while isRunning {
            do {
                let result = try await tracer.ping(to: target, config: config)
                analyzeResults(result)

                // Wait before next monitoring cycle
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                print("Ping failed: \(error)")
            }
        }
    }

    func stop() {
        isRunning = false
    }

    private func analyzeResults(_ result: PingResult) {
        let stats = result.statistics

        // Check for high packet loss
        if stats.packetLoss > 0.2 {
            print("⚠️  High packet loss to \(result.target): \(Int(stats.packetLoss * 100))%")
        }

        // Check for high latency
        if let avg = stats.avgRTT, avg > 0.1 {
            print("⚠️  High latency to \(result.target): \(String(format: "%.2f", avg * 1000)) ms")
        }

        // Check for high jitter
        if let jitter = stats.jitter, jitter > 0.05 {
            print("⚠️  High jitter to \(result.target): \(String(format: "%.2f", jitter * 1000)) ms")
        }
    }
}

// Usage
let monitor = PingMonitor()
Task {
    await monitor.startMonitoring(target: "1.1.1.1", interval: 30.0)
}
```

### Fast Ping for Quick Checks
```swift
import SwiftFTR

// Quick reachability check
func isReachable(host: String) async -> Bool {
    let tracer = SwiftFTR()
    let config = PingConfig(count: 3, interval: 0.2, timeout: 1.0)

    do {
        let result = try await tracer.ping(to: host, config: config)
        return result.statistics.received > 0
    } catch {
        return false
    }
}

// Usage
if await isReachable(host: "8.8.8.8") {
    print("Host is reachable")
} else {
    print("Host is unreachable")
}
```

### Concurrent Ping to Multiple Hosts
```swift
import SwiftFTR

func pingMultipleHosts(hosts: [String]) async throws -> [String: PingStatistics] {
    let tracer = SwiftFTR()
    let config = PingConfig(count: 5, interval: 0.5, timeout: 2.0)

    return try await withThrowingTaskGroup(of: (String, PingStatistics).self) { group in
        for host in hosts {
            group.addTask {
                let result = try await tracer.ping(to: host, config: config)
                return (host, result.statistics)
            }
        }

        var results: [String: PingStatistics] = [:]
        for try await (host, stats) in group {
            results[host] = stats
        }
        return results
    }
}

// Usage
let hosts = ["1.1.1.1", "8.8.8.8", "9.9.9.9"]
let results = try await pingMultipleHosts(hosts: hosts)

for (host, stats) in results {
    print("\(host): \(stats.received)/\(stats.sent) received, avg RTT: \(stats.avgRTT.map { String(format: "%.2f ms", $0 * 1000) } ?? "N/A")")
}
```

## Multipath Discovery (v0.5.0+)

### Basic Multipath Discovery
```swift
import SwiftFTR

// Create tracer and multipath configuration
let tracer = SwiftFTR()
let config = MultipathConfig(
    flowVariations: 8,        // Number of flow variations to try (default: 8)
    maxPaths: 16,            // Max unique paths to discover (default: 16)
    earlyStopThreshold: 3,   // Stop after N consecutive duplicates (default: 3)
    timeoutMs: 2000,         // Timeout per flow in ms (default: 2000)
    maxHops: 30              // Maximum TTL to probe (default: 30)
)

// Discover all ECMP paths
let topology = try await tracer.discoverPaths(to: "example.com", config: config)

// Analyze results
print("Discovered \(topology.uniquePathCount) unique path(s)")
print("Discovery took \(String(format: "%.2f", topology.discoveryDuration)) seconds")

if let divergence = topology.divergencePoint() {
    print("⚡ Paths diverge at TTL \(divergence) (ECMP detected)")
} else {
    print("ℹ️  Single path (no ECMP)")
}
```

### Extract Monitoring Targets from Multipath
```swift
import SwiftFTR

// Discover paths and extract unique hops for monitoring
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
            do {
                let result = try await tracer.ping(to: ip, config: pingConfig)

                // Log metrics for this hop
                print("[\(hop.ttl)] \(ip): RTT \(result.statistics.avgRTT.map { String(format: "%.2f ms", $0 * 1000) } ?? "N/A"), loss \(Int(result.statistics.packetLoss * 100))%")

                // Wait 60 seconds before next ping
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                print("[\(hop.ttl)] \(ip): Error - \(error)")
            }
        }
    }
}
```

### Path Analysis and Filtering
```swift
import SwiftFTR

let tracer = SwiftFTR()
let topology = try await tracer.discoverPaths(to: "8.8.8.8", config: MultipathConfig())

// Get common prefix (shared by all paths)
let commonPrefix = topology.commonPrefix()
print("Common path prefix: \(commonPrefix.count) hops")
for hop in commonPrefix {
    print("  TTL \(hop.ttl): \(hop.ip ?? "*")")
}

// Find paths through specific IP
let pathsThroughIP = topology.paths(throughIP: "142.250.160.160")
print("\(pathsThroughIP.count) path(s) traverse 142.250.160.160")

// Find paths through specific ASN
let pathsThroughGoogle = topology.paths(throughASN: 15169)  // Google ASN
print("\(pathsThroughGoogle.count) path(s) traverse Google's network (AS15169)")

// Analyze each unique path
for (index, path) in topology.paths.filter({ $0.isUnique }).enumerated() {
    print("\nPath \(index + 1):")
    print("  Flow ID: 0x\(String(path.flowIdentifier.icmpID, radix: 16))")
    print("  Hops: \(path.trace.hops.count)")
    print("  Fingerprint: \(path.fingerprint)")
}
```

### ECMP Detection and Alerting
```swift
import SwiftFTR

actor ECMPMonitor {
    private let tracer = SwiftFTR()
    private var previousTopology: NetworkTopology?

    func checkForPathChanges(target: String) async throws {
        let config = MultipathConfig(flowVariations: 10, maxPaths: 20)
        let current = try await tracer.discoverPaths(to: target, config: config)

        if let previous = previousTopology {
            // Check if number of paths changed
            if current.uniquePathCount != previous.uniquePathCount {
                print("⚠️  Path count changed: \(previous.uniquePathCount) → \(current.uniquePathCount)")
            }

            // Check if divergence point changed
            let currentDiv = current.divergencePoint()
            let previousDiv = previous.divergencePoint()
            if currentDiv != previousDiv {
                print("⚠️  Divergence point changed: \(previousDiv?.description ?? "none") → \(currentDiv?.description ?? "none")")
            }

            // Check for new or removed hops
            let currentIPs = Set(current.uniqueHops().compactMap { $0.ip })
            let previousIPs = Set(previous.uniqueHops().compactMap { $0.ip })

            let added = currentIPs.subtracting(previousIPs)
            let removed = previousIPs.subtracting(currentIPs)

            if !added.isEmpty {
                print("⚠️  New hops discovered: \(added)")
            }
            if !removed.isEmpty {
                print("⚠️  Hops no longer seen: \(removed)")
            }
        }

        previousTopology = current
    }
}

// Usage: Monitor for path changes every 5 minutes
let monitor = ECMPMonitor()
Task {
    while true {
        try await monitor.checkForPathChanges(target: "example.com")
        try await Task.sleep(nanoseconds: 300_000_000_000)  // 5 minutes
    }
}
```

### Export Topology as JSON
```swift
import SwiftFTR
import Foundation

let tracer = SwiftFTR()
let topology = try await tracer.discoverPaths(to: "example.com", config: MultipathConfig())

// Encode to JSON
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let jsonData = try encoder.encode(topology)

// Save to file or send to API
if let jsonString = String(data: jsonData, encoding: .utf8) {
    print(jsonString)

    // Or write to file
    try jsonString.write(
        toFile: "/tmp/network-topology.json",
        atomically: true,
        encoding: .utf8
    )
}
```

### ICMP Limitation Note
```swift
import SwiftFTR

/*
 * IMPORTANT: SwiftFTR v0.5.0 uses ICMP Echo Request for multipath discovery.
 * Many ECMP routers do not hash ICMP ID fields, so this may find fewer paths
 * than UDP-based tools like dublin-traceroute.
 *
 * The discovered paths accurately represent ICMP routing behavior, which is
 * ideal for ping monitoring. For TCP/UDP application path discovery, a future
 * UDP-based implementation is planned (see ROADMAP.md).
 *
 * Example: UDP may find 7 paths, ICMP may find 1-2 paths to the same destination.
 * Both are correct - they show different protocols' routing behavior.
 */

// For now, understand that multipath results show paths ICMP packets take
let tracer = SwiftFTR()
let topology = try await tracer.discoverPaths(to: "8.8.8.8", config: MultipathConfig())

print("Discovered \(topology.uniquePathCount) ICMP path(s)")
print("Note: UDP-based discovery might find more paths due to port-based ECMP hashing")
```

## Bufferbloat Detection (v0.5.1+)

Bufferbloat detection measures network responsiveness under load. This is critical for diagnosing WFH network issues that cause video calls to freeze.

### Basic Bufferbloat Test

```swift
import SwiftFTR

let tracer = SwiftFTR()
let result = try await tracer.testBufferbloat()

print("Grade: \(result.grade.rawValue)")
print("Latency increase: +\(String(format: "%.1f", result.latencyIncrease.absoluteMs))ms")

if let rpm = result.rpm {
    print("Working RPM: \(rpm.workingRPM) (\(rpm.grade.rawValue))")
}

print("Video Call Impact: \(result.videoCallImpact.severity.rawValue)")
print(result.videoCallImpact.description)
```

### Custom Configuration

```swift
import SwiftFTR

let config = BufferbloatConfig(
    target: "8.8.8.8",
    baselineDuration: 3.0,      // 3s idle measurement
    loadDuration: 5.0,          // 5s load test
    loadType: .upload,          // Upload only (vs .download or .bidirectional)
    parallelStreams: 8,         // More streams = more load
    pingInterval: 0.1,          // Ping every 100ms
    calculateRPM: true
)

let result = try await SwiftFTR().testBufferbloat(config: config)

// Analyze baseline vs loaded latency
print("Baseline: avg=\(String(format: "%.1f", result.baseline.avgMs))ms, " +
      "p95=\(String(format: "%.1f", result.baseline.p95Ms))ms")

print("Under Load: avg=\(String(format: "%.1f", result.loaded.avgMs))ms, " +
      "p95=\(String(format: "%.1f", result.loaded.p95Ms))ms")

print("Jitter: \(String(format: "%.1f", result.loaded.jitterMs))ms")
```

### Interpreting Results

```swift
import SwiftFTR

let result = try await SwiftFTR().testBufferbloat()

// Check bufferbloat severity
switch result.grade {
case .a:
    print("✅ Excellent - minimal bufferbloat")
case .b:
    print("👍 Good - slight latency increase")
case .c:
    print("⚠️ Acceptable - noticeable during video calls")
case .d:
    print("🔴 Poor - video calls will have issues")
case .f:
    print("💥 Critical - enable QoS/SQM on router")
}

// Check RPM score (responsiveness)
if let rpm = result.rpm {
    switch rpm.grade {
    case .excellent:
        print("🚀 Excellent responsiveness (>\(rpm.workingRPM) RPM)")
    case .good:
        print("✅ Good responsiveness (\(rpm.workingRPM) RPM)")
    case .fair:
        print("⚠️ Fair responsiveness (\(rpm.workingRPM) RPM)")
    case .poor:
        print("🔴 Poor responsiveness (\(rpm.workingRPM) RPM)")
    }
}

// Video call readiness
if !result.videoCallImpact.impactsVideoCalls {
    print("📹 Video calls will work well")
} else {
    print("📹 Video calls may have issues: \(result.videoCallImpact.description)")
}
```

### Analyzing Individual Pings

```swift
import SwiftFTR

let result = try await SwiftFTR().testBufferbloat()

// Group by phase
let baseline = result.pingResults.filter { $0.phase == .baseline }
let sustained = result.pingResults.filter { $0.phase == .sustained }

print("Baseline phase: \(baseline.count) pings")
print("Sustained load phase: \(sustained.count) pings")

// Find worst latency spike
if let worst = result.pingResults.compactMap({ $0.rtt }).max() {
    print("Peak latency: \(String(format: "%.1f", worst * 1000))ms")
}

// Calculate packet loss
let totalPings = result.pingResults.count
let successfulPings = result.pingResults.filter { $0.rtt != nil }.count
let packetLoss = 1.0 - (Double(successfulPings) / Double(totalPings))
print("Packet loss: \(String(format: "%.1f", packetLoss * 100))%")
```

### JSON Export for Analysis

```swift
import SwiftFTR
import Foundation

let result = try await SwiftFTR().testBufferbloat()

// Export to JSON
let encoder = JSONEncoder()
encoder.outputFormatting = .prettyPrinted
encoder.dateEncodingStrategy = .iso8601

let jsonData = try encoder.encode(result)
try jsonData.write(to: URL(fileURLWithPath: "bufferbloat_result.json"))

print("Results exported to bufferbloat_result.json")
```

### Load Type Comparison

```swift
import SwiftFTR

let tracer = SwiftFTR()

// Test upload bufferbloat
let uploadConfig = BufferbloatConfig(loadType: .upload, loadDuration: 10.0)
let uploadResult = try await tracer.testBufferbloat(config: uploadConfig)

// Test download bufferbloat
let downloadConfig = BufferbloatConfig(loadType: .download, loadDuration: 10.0)
let downloadResult = try await tracer.testBufferbloat(config: downloadConfig)

// Test bidirectional
let bidirConfig = BufferbloatConfig(loadType: .bidirectional, loadDuration: 10.0)
let bidirResult = try await tracer.testBufferbloat(config: bidirConfig)

print("Upload bufferbloat: \(uploadResult.grade.rawValue) " +
      "(+\(String(format: "%.1f", uploadResult.latencyIncrease.absoluteMs))ms)")

print("Download bufferbloat: \(downloadResult.grade.rawValue) " +
      "(+\(String(format: "%.1f", downloadResult.latencyIncrease.absoluteMs))ms)")

print("Bidirectional bufferbloat: \(bidirResult.grade.rawValue) " +
      "(+\(String(format: "%.1f", bidirResult.latencyIncrease.absoluteMs))ms)")
```

### Understanding RPM (Round-trips Per Minute)

```swift
import SwiftFTR

let result = try await SwiftFTR().testBufferbloat()

if let rpm = result.rpm {
    // RPM = 60 / avg_rtt_seconds
    // Higher is better - measures responsiveness under load

    print("Working RPM: \(rpm.workingRPM)")
    print("Idle RPM: \(rpm.idleRPM)")

    // RPM thresholds (IETF spec):
    // Excellent: >6000 RPM (<10ms RTT)
    // Good: 1000-6000 RPM (10-60ms RTT)
    // Fair: 300-1000 RPM (60-200ms RTT)
    // Poor: <300 RPM (>200ms RTT)

    let degradation = Double(rpm.idleRPM - rpm.workingRPM) / Double(rpm.idleRPM) * 100
    print("Responsiveness degradation: \(String(format: "%.1f", degradation))%")
}
```

### WFH Network Troubleshooting

```swift
import SwiftFTR

// Diagnose why video calls freeze during uploads
let tracer = SwiftFTR()

print("Testing network for video call quality...")
let result = try await tracer.testBufferbloat(
    config: BufferbloatConfig(loadType: .bidirectional, loadDuration: 10.0)
)

// Check Zoom/Teams requirements:
// - <150ms latency
// - <50ms jitter
// - Stable connection

let meetsZoomReqs = result.loaded.avgMs < 150 && result.loaded.jitterMs < 50

if meetsZoomReqs {
    print("✅ Network meets Zoom/Teams requirements")
} else {
    print("❌ Network fails video call requirements:")
    if result.loaded.avgMs >= 150 {
        print("  - Latency too high: \(String(format: "%.1f", result.loaded.avgMs))ms (need <150ms)")
    }
    if result.loaded.jitterMs >= 50 {
        print("  - Jitter too high: \(String(format: "%.1f", result.loaded.jitterMs))ms (need <50ms)")
    }

    // Suggest remediation
    if result.grade >= .d {
        print("\n💡 Recommendation: Enable Smart Queue Management (SQM) or QoS on your router")
        print("   This will eliminate bufferbloat and fix video call freezing")
    }
}
```

## SwiftUI Integration

### Basic SwiftUI View
```swift
import SwiftUI
import SwiftFTR

struct TracerouteView: View {
    @State private var destination = "1.1.1.1"
    @State private var isTracing = false
    @State private var results: [TraceHop] = []
    @State private var errorMessage: String?
    
    // SwiftFTR is thread-safe and doesn't require MainActor
    private let tracer = SwiftFTR(config: SwiftFTRConfig(maxHops: 15))
    
    var body: some View {
        VStack {
            HStack {
                TextField("Destination", text: $destination)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                Button("Trace") {
                    Task {
                        await performTrace()
                    }
                }
                .disabled(isTracing || destination.isEmpty)
            }
            .padding()
            
            if isTracing {
                ProgressView("Tracing...")
                    .padding()
            }
            
            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .padding()
            }
            
            List(results, id: \.ttl) { hop in
                HopRow(hop: hop)
            }
        }
    }
    
    // This method doesn't need @MainActor
    func performTrace() async {
        isTracing = true
        errorMessage = nil
        results = []
        
        do {
            let result = try await tracer.trace(to: destination)
            results = result.hops
        } catch {
            errorMessage = "Error: \(error.localizedDescription)"
        }
        
        isTracing = false
    }
}

struct HopRow: View {
    let hop: TraceHop
    
    var body: some View {
        HStack {
            Text("#\(hop.ttl)")
                .frame(width: 40)
                .foregroundColor(.secondary)
            
            Text(hop.ipAddress ?? "* * *")
                .frame(maxWidth: .infinity, alignment: .leading)
            
            if let rtt = hop.rtt {
                Text(String(format: "%.1f ms", rtt * 1000))
                    .foregroundColor(.green)
            } else {
                Text("timeout")
                    .foregroundColor(.orange)
            }
        }
        .font(.system(.body, design: .monospaced))
    }
}
```

### Advanced SwiftUI with Classification
```swift
import SwiftUI
import SwiftFTR

@MainActor
class TracerouteViewModel: ObservableObject {
    @Published var hops: [ClassifiedHop] = []
    @Published var isLoading = false
    @Published var publicIP: String?
    @Published var destinationASN: String?
    
    private let tracer = SwiftFTR()
    
    func trace(to destination: String) async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let result = try await tracer.traceClassified(to: destination)
            hops = result.hops
            publicIP = result.publicIP
            if let asn = result.destinationASN, let name = result.destinationASName {
                destinationASN = "AS\(asn) (\(name))"
            }
        } catch {
            print("Trace failed: \(error)")
        }
    }
}

struct ClassifiedTracerouteView: View {
    @StateObject private var viewModel = TracerouteViewModel()
    @State private var destination = "cloudflare.com"
    
    var body: some View {
        NavigationView {
            VStack {
                // Input section
                HStack {
                    TextField("Destination", text: $destination)
                    Button("Trace") {
                        Task {
                            await viewModel.trace(to: destination)
                        }
                    }
                    .disabled(viewModel.isLoading)
                }
                .padding()
                
                // Info section
                if let publicIP = viewModel.publicIP {
                    Label("Your IP: \(publicIP)", systemImage: "network")
                }
                if let destASN = viewModel.destinationASN {
                    Label("Destination: \(destASN)", systemImage: "server.rack")
                }
                
                // Results
                List(viewModel.hops, id: \.ttl) { hop in
                    ClassifiedHopRow(hop: hop)
                }
            }
            .navigationTitle("Network Path Analyzer")
        }
    }
}

struct ClassifiedHopRow: View {
    let hop: ClassifiedHop
    
    var categoryColor: Color {
        switch hop.category {
        case .local: return .blue
        case .isp: return .green
        case .transit: return .orange
        case .destination: return .red
        case .unknown: return .gray
        }
    }
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("#\(hop.ttl)")
                    .frame(width: 30)
                
                Text(hop.category.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(categoryColor.opacity(0.2))
                    .foregroundColor(categoryColor)
                    .cornerRadius(4)
                
                Spacer()
                
                if let rtt = hop.rtt {
                    Text(String(format: "%.1f ms", rtt * 1000))
                }
            }
            
            Text(hop.ip ?? "* * *")
                .font(.system(.caption, design: .monospaced))
            
            if let asn = hop.asn, let name = hop.asName {
                Text("AS\(asn) - \(name)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
```

## Concurrent Traces

### Parallel Traces to Multiple Destinations
```swift
import SwiftFTR

func traceMultipleDestinations() async throws {
    let tracer = SwiftFTR(config: SwiftFTRConfig(maxHops: 10))
    
    let destinations = [
        "1.1.1.1",      // Cloudflare
        "8.8.8.8",      // Google
        "9.9.9.9",      // Quad9
        "208.67.222.222" // OpenDNS
    ]
    
    // Run traces concurrently
    try await withThrowingTaskGroup(of: (String, TraceResult).self) { group in
        for dest in destinations {
            group.addTask {
                let result = try await tracer.trace(to: dest)
                return (dest, result)
            }
        }
        
        // Collect results
        for try await (dest, result) in group {
            print("\(dest): \(result.hops.count) hops, reached: \(result.reached)")
        }
    }
}
```

### Rate-Limited Concurrent Traces
```swift
import SwiftFTR

actor RateLimitedTracer {
    private let tracer = SwiftFTR()
    private let maxConcurrent = 3
    private var activeTraces = 0
    
    func trace(to destination: String) async throws -> TraceResult {
        // Wait if too many concurrent traces
        while activeTraces >= maxConcurrent {
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        
        activeTraces += 1
        defer { activeTraces -= 1 }
        
        return try await tracer.trace(to: destination)
    }
}

// Usage
let rateLimited = RateLimitedTracer()
let destinations = Array(1...20).map { "host\($0).example.com" }

for dest in destinations {
    Task {
        let result = try await rateLimited.trace(to: dest)
        print("Completed: \(dest)")
    }
}
```

## Error Handling

### Comprehensive Error Handling
```swift
import SwiftFTR

func robustTrace(to destination: String) async {
    let tracer = SwiftFTR()
    
    do {
        let result = try await tracer.trace(to: destination)
        processResult(result)
    } catch TracerouteError.resolutionFailed(let host, let details) {
        print("Failed to resolve '\(host)'")
        if let details = details {
            print("Details: \(details)")
        }
    } catch TracerouteError.socketCreateFailed(let errno, let details) {
        print("Socket creation failed (errno: \(errno))")
        print("Details: \(details)")
        print("This may indicate:")
        print("- Missing network permissions")
        print("- Unsupported platform")
        print("- Sandbox restrictions")
    } catch TracerouteError.setsockoptFailed(let option, let errno) {
        print("Failed to set socket option '\(option)' (errno: \(errno))")
    } catch TracerouteError.sendFailed(let errno) {
        print("Failed to send probe (errno: \(errno))")
    } catch {
        print("Unexpected error: \(error)")
    }
}
```

### Retry Logic
```swift
import SwiftFTR

func traceWithRetry(
    to destination: String,
    maxRetries: Int = 3
) async throws -> TraceResult {
    let tracer = SwiftFTR()
    var lastError: Error?
    
    for attempt in 1...maxRetries {
        do {
            return try await tracer.trace(to: destination)
        } catch {
            lastError = error
            print("Attempt \(attempt) failed: \(error)")
            
            if attempt < maxRetries {
                // Exponential backoff
                let delay = UInt64(pow(2.0, Double(attempt)) * 1_000_000_000)
                try await Task.sleep(nanoseconds: delay)
            }
        }
    }
    
    throw lastError ?? TracerouteError.invalidConfiguration(reason: "All retries failed")
}
```

## ASN Classification

### Custom ASN Resolver
```swift
import SwiftFTR

// Implement custom resolver
struct MyCustomResolver: ASNResolver {
    func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
        // Your custom resolution logic
        // Could use a local database, API, etc.
        var results: [String: ASNInfo] = [:]
        for addr in ipv4Addrs {
            // Example: lookup from local database or API
            if addr == "1.1.1.1" {
                results[addr] = ASNInfo(asn: 13335, name: "CLOUDFLARENET", prefix: "1.1.1.0/24")
            }
        }
        return results
    }
}

// Use custom resolver
let tracer = SwiftFTR()
let classified = try await tracer.traceClassified(
    to: "example.com",
    resolver: MyCustomResolver()
)
```

### Caching Resolver
```swift
import SwiftFTR

// Use the built-in caching resolver
let baseResolver = CymruDNSResolver()
let cachingResolver = CachingASNResolver(base: baseResolver)

let tracer = SwiftFTR()
let result = try await tracer.traceClassified(
    to: "example.com",
    resolver: cachingResolver
)

// Subsequent traces will use cached ASN data
let result2 = try await tracer.traceClassified(
    to: "another.com",
    resolver: cachingResolver  // Reuses cached entries
)
```

## Performance Monitoring

### Trace Performance Metrics
```swift
import SwiftFTR
import os.log

private let logger = Logger(subsystem: "com.example.app", category: "Network")

struct TraceMetrics {
    let destination: String
    let hopCount: Int
    let duration: TimeInterval
    let reached: Bool
    let timeouts: Int
}

func traceWithMetrics(to destination: String) async throws -> TraceMetrics {
    let tracer = SwiftFTR(config: SwiftFTRConfig(
        maxHops: 30,
        maxWaitMs: 2000,
        enableLogging: false
    ))
    
    let startTime = Date()
    let result = try await tracer.trace(to: destination)
    let duration = Date().timeIntervalSince(startTime)
    
    let timeouts = result.hops.filter { $0.ipAddress == nil }.count
    
    let metrics = TraceMetrics(
        destination: destination,
        hopCount: result.hops.count,
        duration: duration,
        reached: result.reached,
        timeouts: timeouts
    )
    
    // Log metrics
    logger.info("""
        Trace metrics for \(destination):
        - Hops: \(metrics.hopCount)
        - Duration: \(String(format: "%.3f", metrics.duration))s
        - Reached: \(metrics.reached)
        - Timeouts: \(metrics.timeouts)
        """)
    
    // Alert if performance degrades
    if metrics.duration > 3.0 {
        logger.warning("Slow trace to \(destination): \(metrics.duration)s")
    }
    
    if Double(metrics.timeouts) / Double(metrics.hopCount) > 0.3 {
        logger.warning("High timeout rate to \(destination): \(metrics.timeouts)/\(metrics.hopCount)")
    }
    
    return metrics
}
```

### Continuous Monitoring
```swift
import SwiftFTR

actor NetworkMonitor {
    private let tracer = SwiftFTR(config: SwiftFTRConfig(maxHops: 20))
    private var history: [String: [TraceResult]] = [:]
    private let maxHistoryPerHost = 10
    
    func monitor(host: String) async throws -> TraceResult {
        let result = try await tracer.trace(to: host)
        
        // Store history
        var hostHistory = history[host] ?? []
        hostHistory.append(result)
        if hostHistory.count > maxHistoryPerHost {
            hostHistory.removeFirst()
        }
        history[host] = hostHistory
        
        // Detect changes
        if hostHistory.count >= 2 {
            let previous = hostHistory[hostHistory.count - 2]
            detectPathChanges(current: result, previous: previous)
        }
        
        return result
    }
    
    private func detectPathChanges(current: TraceResult, previous: TraceResult) {
        let currentIPs = Set(current.hops.compactMap { $0.ipAddress })
        let previousIPs = Set(previous.hops.compactMap { $0.ipAddress })
        
        let added = currentIPs.subtracting(previousIPs)
        let removed = previousIPs.subtracting(currentIPs)
        
        if !added.isEmpty || !removed.isEmpty {
            print("Path change detected!")
            print("  Added: \(added)")
            print("  Removed: \(removed)")
        }
    }
    
    func getStatistics(for host: String) -> (avgHops: Double, avgDuration: Double)? {
        guard let hostHistory = history[host], !hostHistory.isEmpty else {
            return nil
        }
        
        let avgHops = Double(hostHistory.map { $0.hops.count }.reduce(0, +)) / Double(hostHistory.count)
        let avgDuration = hostHistory.map { $0.duration }.reduce(0, +) / Double(hostHistory.count)
        
        return (avgHops, avgDuration)
    }
}

// Usage
let monitor = NetworkMonitor()

// Monitor continuously
Task {
    while true {
        let result = try await monitor.monitor(host: "example.com")
        
        if let stats = await monitor.getStatistics(for: "example.com") {
            print("Average hops: \(stats.avgHops), Average duration: \(stats.avgDuration)s")
        }
        
        try await Task.sleep(nanoseconds: 60_000_000_000) // 1 minute
    }
}
```

## Testing & Debugging

### Mock Tracer for Testing
```swift
import SwiftFTR

class MockTracer {
    func trace(to destination: String) async throws -> TraceResult {
        // Return predictable test data
        let hops = [
            TraceHop(ttl: 1, ipAddress: "192.168.1.1", rtt: 0.001, reachedDestination: false),
            TraceHop(ttl: 2, ipAddress: "10.0.0.1", rtt: 0.005, reachedDestination: false),
            TraceHop(ttl: 3, ipAddress: "1.1.1.1", rtt: 0.010, reachedDestination: true)
        ]
        
        return TraceResult(
            destination: destination,
            maxHops: 30,
            reached: true,
            hops: hops,
            duration: 0.016
        )
    }
}

// Use in tests
func testMyNetworkFeature() async throws {
    let mockTracer = MockTracer()
    let result = try await mockTracer.trace(to: "test.com")
    XCTAssertEqual(result.hops.count, 3)
    XCTAssertTrue(result.reached)
}
```

### Debug Logging
```swift
import SwiftFTR
import os.log

extension Logger {
    static let network = Logger(subsystem: "com.example.app", category: "Network")
}

func debugTrace(to destination: String) async throws {
    let config = SwiftFTRConfig(
        maxHops: 10,
        maxWaitMs: 2000,
        enableLogging: true  // Enable SwiftFTR's internal logging
    )
    
    let tracer = SwiftFTR(config: config)
    
    Logger.network.debug("Starting trace to \(destination)")
    
    do {
        let result = try await tracer.trace(to: destination)
        
        Logger.network.debug("""
            Trace completed:
            - Destination: \(result.destination)
            - Hops: \(result.hops.count)
            - Reached: \(result.reached)
            - Duration: \(result.duration)
            """)
        
        for hop in result.hops {
            if let ip = hop.ipAddress, let rtt = hop.rtt {
                Logger.network.debug("  Hop \(hop.ttl): \(ip) (\(rtt * 1000)ms)")
            }
        }
    } catch {
        Logger.network.error("Trace failed: \(error)")
        throw error
    }
}
```