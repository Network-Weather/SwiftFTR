# SwiftFTR Examples

## Table of Contents
- [Basic Usage](#basic-usage)
- [Configuration Options](#configuration-options)
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
    maxWaitMs: 2000,       // Max wait time in milliseconds (default: 2000)
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
    func resolve(ipv4Addr: String, timeout: TimeInterval) -> ASNInfo? {
        // Your custom resolution logic
        // Could use a local database, API, etc.
        return ASNInfo(asn: 13335, name: "CLOUDFLARENET", prefix: "1.1.1.0/24")
    }
    
    func resolve(ipv4Addrs: [String], timeout: TimeInterval) -> [String: ASNInfo] {
        var results: [String: ASNInfo] = [:]
        for addr in ipv4Addrs {
            if let info = resolve(ipv4Addr: addr, timeout: timeout) {
                results[addr] = info
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