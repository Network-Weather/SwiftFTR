# Caching and Cancellation Implementation Plan for SwiftFTR v0.3.0

## Overview
This document outlines the implementation plan for adding comprehensive caching, rDNS support, and cancellation capabilities to SwiftFTR using Swift 6.1 actor-based architecture.

## 1. Core Architecture with Actor-Based Design

### SwiftFTR as Actor
```swift
public actor SwiftFTR {
  private var config: SwiftFTRConfig
  
  // Cache storage
  private var cachedPublicIP: String?
  private let rdnsCache: RDNSCache
  private let asnResolver: ASNResolver
  
  // Active trace tracking
  private var activeTraces: Set<TraceHandle> = []
  
  public init(config: SwiftFTRConfig = SwiftFTRConfig()) {
    self.config = config
    self.rdnsCache = RDNSCache(
      ttl: config.rdnsCacheTTL ?? 86400,
      maxSize: config.rdnsCacheSize ?? 1000
    )
    self.asnResolver = CachingASNResolver(base: CymruDNSResolver())
  }
  
  /// Handle network changes - cancels traces and clears caches
  public func networkChanged() async {
    // Cancel all active traces
    for trace in activeTraces {
      trace.cancel()
    }
    activeTraces.removeAll()
    
    // Clear cached public IP
    cachedPublicIP = nil
    
    // Clear rDNS cache
    await rdnsCache.clear()
    
    // Note: ASN cache could optionally be cleared too
  }
}
```

## 2. Simplified TraceHandle
```swift
public final class TraceHandle: Sendable {
  private let _isCancelled = ManagedAtomic<Bool>(false)
  
  var isCancelled: Bool {
    _isCancelled.load(ordering: .acquiring)
  }
  
  func cancel() {
    _isCancelled.store(true, ordering: .releasing)
  }
}
```

## 3. Enhanced Configuration
```swift
public struct SwiftFTRConfig: Sendable {
  public let maxHops: Int
  public let maxWaitMs: Int
  public let payloadSize: Int
  public let publicIP: String?
  public let enableLogging: Bool
  
  // New rDNS fields
  public let noReverseDNS: Bool
  public let rdnsCacheTTL: TimeInterval?
  public let rdnsCacheSize: Int?
  
  public init(
    maxHops: Int = 30,
    maxWaitMs: Int = 1000,
    payloadSize: Int = 56,
    publicIP: String? = nil,
    enableLogging: Bool = false,
    noReverseDNS: Bool = false,
    rdnsCacheTTL: TimeInterval? = nil,
    rdnsCacheSize: Int? = nil
  ) {
    self.maxHops = maxHops
    self.maxWaitMs = maxWaitMs
    self.payloadSize = payloadSize
    self.publicIP = publicIP
    self.enableLogging = enableLogging
    self.noReverseDNS = noReverseDNS
    self.rdnsCacheTTL = rdnsCacheTTL
    self.rdnsCacheSize = rdnsCacheSize
  }
}
```

## 4. RDNSCache as Actor
```swift
actor RDNSCache {
  private struct CacheEntry {
    let hostname: String?
    let timestamp: ContinuousClock.Instant
  }
  
  private var cache: [String: CacheEntry] = [:]
  private let ttl: Duration
  private let maxSize: Int
  private let clock = ContinuousClock()
  
  init(ttl: TimeInterval = 86400, maxSize: Int = 1000) {
    self.ttl = .seconds(ttl)
    self.maxSize = maxSize
  }
  
  func lookup(_ ip: String) async -> String? {
    let now = clock.now
    
    // Check cache
    if let entry = cache[ip], now < entry.timestamp + ttl {
      return entry.hostname
    }
    
    // Perform lookup in background
    let hostname = await Task.detached(priority: .background) {
      reverseDNS(ip)
    }.value
    
    // Cache result
    cache[ip] = CacheEntry(hostname: hostname, timestamp: now)
    
    // LRU eviction if needed
    if cache.count > maxSize {
      evictOldest()
    }
    
    return hostname
  }
  
  func batchLookup(_ ips: [String]) async -> [String: String] {
    await withTaskGroup(of: (String, String?).self) { group in
      for ip in ips {
        group.addTask {
          await (ip, self.lookup(ip))
        }
      }
      
      var results: [String: String] = [:]
      for await (ip, hostname) in group {
        if let hostname = hostname {
          results[ip] = hostname
        }
      }
      return results
    }
  }
  
  func clear() {
    cache.removeAll()
  }
  
  private func evictOldest() {
    if let oldest = cache.min(by: { $0.value.timestamp < $1.value.timestamp }) {
      cache.removeValue(forKey: oldest.key)
    }
  }
}
```

## 5. Enhanced Data Models
```swift
public struct TraceHop: Sendable {
  public let ttl: Int
  public let ipAddress: String?
  public let rtt: TimeInterval?
  public let reachedDestination: Bool
  public let hostname: String?  // New field
}

public struct ClassifiedHop: Sendable, Codable {
  public let ttl: Int
  public let ip: String?
  public let rtt: TimeInterval?
  public let asn: Int?
  public let asName: String?
  public let category: HopCategory
  public let hostname: String?  // New field
}

public struct ClassifiedTrace: Sendable, Codable {
  public let destinationHost: String
  public let destinationIP: String
  public let destinationHostname: String?  // New field
  public let publicIP: String?
  public let publicHostname: String?        // New field
  public let clientASN: Int?
  public let clientASName: String?
  public let destinationASN: Int?
  public let destinationASName: String?
  public let hops: [ClassifiedHop]
}
```

## 6. Trace Implementation with Cancellation
```swift
extension SwiftFTR {
  /// Perform trace with cancellation support
  public func trace(to host: String) async throws -> TraceResult {
    let handle = TraceHandle()
    
    // Register active trace
    activeTraces.insert(handle)
    defer { activeTraces.remove(handle) }
    
    // Run trace in a task so we can check cancellation
    return try await withTaskCancellationHandler {
      try await performTrace(to: host, handle: handle)
    } onCancel: {
      handle.cancel()
    }
  }
  
  private func performTrace(to host: String, handle: TraceHandle) async throws -> TraceResult {
    // ... existing setup code ...
    
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
    defer { close(fd) }
    
    // ... send probes ...
    
    // Modified receive loop with cancellation checks
    recvLoop: while monotonicNow() < deadline {
      // Check if cancelled
      if handle.isCancelled {
        throw TracerouteError.cancelled
      }
      
      // Use short poll timeout for responsive cancellation
      var fds = Darwin.pollfd(fd: fd, events: Int16(Darwin.POLLIN), revents: 0)
      let pollTimeout = min(100, Int32(max(0, (deadline - monotonicNow()) * 1000)))
      let rv = withUnsafeMutablePointer(to: &fds) { p in 
        Darwin.poll(p, 1, pollTimeout) 
      }
      
      if rv == 0 { continue }  // Timeout - check cancellation and continue
      if rv < 0 { break }      // Error
      
      // ... existing receive logic ...
    }
    
    // Perform rDNS lookups if enabled
    var finalHops = /* create hops array */
    
    if !config.noReverseDNS {
      let ips = finalHops.compactMap { $0.ipAddress }
      let hostnames = await rdnsCache.batchLookup(ips)
      
      finalHops = finalHops.map { hop in
        TraceHop(
          ttl: hop.ttl,
          ipAddress: hop.ipAddress,
          rtt: hop.rtt,
          reachedDestination: hop.reachedDestination,
          hostname: hop.ipAddress.flatMap { hostnames[$0] }
        )
      }
    }
    
    return TraceResult(
      destination: host,
      maxHops: config.maxHops,
      reached: reachedTTL != nil,
      hops: finalHops,
      duration: Date().timeIntervalSince(startWall)
    )
  }
}
```

## 7. Enhanced traceClassified with Public IP Caching
```swift
extension SwiftFTR {
  public func traceClassified(
    to host: String,
    resolver: ASNResolver? = nil
  ) async throws -> ClassifiedTrace {
    // Get or discover public IP
    let effectivePublicIP: String? = if let configIP = config.publicIP {
      configIP
    } else if let cached = cachedPublicIP {
      cached
    } else if let discovered = try? await discoverPublicIP() {
      cachedPublicIP = discovered
      discovered
    } else {
      nil
    }
    
    // Perform base trace (includes rDNS if enabled)
    let tr = try await trace(to: host)
    
    // Resolve destination IP
    let destAddr = try resolveIPv4(host: host, enableLogging: config.enableLogging)
    let destIP = ipString(destAddr)
    
    // Collect IPs for batch operations
    var allIPs = Set(tr.hops.compactMap { $0.ipAddress })
    allIPs.insert(destIP)
    if let pip = effectivePublicIP { allIPs.insert(pip) }
    
    // Get hostnames (either from trace or via rDNS)
    var hostnameMap: [String: String] = [:]
    if !config.noReverseDNS {
      // Get any missing hostnames
      let ipsNeedingRDNS = allIPs.filter { ip in
        !tr.hops.contains { $0.ipAddress == ip && $0.hostname != nil }
      }
      if !ipsNeedingRDNS.isEmpty {
        let additionalHostnames = await rdnsCache.batchLookup(Array(ipsNeedingRDNS))
        hostnameMap = additionalHostnames
      }
      
      // Add hostnames from trace
      for hop in tr.hops {
        if let ip = hop.ipAddress, let hostname = hop.hostname {
          hostnameMap[ip] = hostname
        }
      }
    }
    
    // ASN lookups
    let effectiveResolver = resolver ?? asnResolver
    let asnMap = try? effectiveResolver.resolve(ipv4Addrs: Array(allIPs), timeout: 1.5)
    
    // Classification logic
    let classifier = TraceClassifier()
    // ... perform classification ...
    
    // Build result with hostnames
    let classifiedHops = tr.hops.map { hop in
      // ... build ClassifiedHop with hostname from hostnameMap ...
    }
    
    return ClassifiedTrace(
      destinationHost: host,
      destinationIP: destIP,
      destinationHostname: hostnameMap[destIP],
      publicIP: effectivePublicIP,
      publicHostname: effectivePublicIP.flatMap { hostnameMap[$0] },
      clientASN: /* from classification */,
      clientASName: /* from classification */,
      destinationASN: /* from classification */,
      destinationASName: /* from classification */,
      hops: classifiedHops
    )
  }
  
  private func discoverPublicIP() async throws -> String {
    try stunGetPublicIPv4(timeout: 0.8).ip
  }
}
```

## 8. Simple Public API
```swift
extension SwiftFTR {
  /// Get the effective public IP (configured or cached)
  public var publicIP: String? {
    config.publicIP ?? cachedPublicIP
  }
  
  /// Clear all caches (convenience method)
  public func clearCaches() async {
    cachedPublicIP = nil
    await rdnsCache.clear()
  }
}
```

## 9. TracerouteError Addition
```swift
public enum TracerouteError: Error {
  // ... existing cases ...
  case cancelled
}
```

## Usage Example
```swift
// Create tracer
let tracer = SwiftFTR(config: SwiftFTRConfig(
  noReverseDNS: false,
  rdnsCacheTTL: 86400
))

// Perform trace
let result = try await tracer.trace(to: "example.com")

// On network change (e.g., from Network.framework callback)
await tracer.networkChanged()

// Subsequent traces will re-discover public IP and use fresh caches
let newResult = try await tracer.trace(to: "google.com")
```

## Implementation Steps

1. **Convert SwiftFTR to actor** - Thread-safe by design with Swift 6.1
2. **Create RDNSCache actor** - Concurrent-safe caching with Swift 6.1 Clock API
3. **Add TraceHandle with atomics** - Simple cancellation using Swift Atomics
4. **Extend data models** - Add hostname fields throughout
5. **Implement trace with cancellation** - Check handle.isCancelled in poll loop
6. **Add rDNS to trace methods** - Batch lookups with caching
7. **Implement networkChanged()** - Single method to handle all cleanup
8. **Add STUN caching** - Simple cached field, cleared on network change
9. **Update tests** - Test cancellation, caching, and network changes
10. **Update documentation** - Document new APIs and usage patterns

## Benefits

- **Simplicity**: Single `networkChanged()` method handles everything
- **Thread Safety**: Actor isolation guarantees safety without manual locking
- **Modern Swift**: Uses Swift 6.1 features like actors and Clock API
- **Clean API**: No complex setters, just one network change handler
- **Performance**: All caching benefits with minimal complexity
- **Feature Parity**: Core library matches CLI capabilities with rDNS support

## Migration Guide

### For Library Users

The changes are mostly additive, but there are some important considerations:

1. **SwiftFTR is now an actor** - All methods must be called with `await`
2. **New configuration options** - Add `noReverseDNS`, `rdnsCacheTTL`, `rdnsCacheSize` as needed
3. **Enhanced data models** - `TraceHop` and `ClassifiedHop` now include `hostname` field
4. **Network change handling** - Call `await tracer.networkChanged()` when network changes

### Example Migration

Before:
```swift
let tracer = SwiftFTR()
let result = try await tracer.trace(to: "example.com")
```

After:
```swift
let tracer = SwiftFTR(config: SwiftFTRConfig(
  noReverseDNS: false  // Enable rDNS
))
let result = try await tracer.trace(to: "example.com")
// Access hostnames via result.hops[].hostname

// On network change:
await tracer.networkChanged()
```