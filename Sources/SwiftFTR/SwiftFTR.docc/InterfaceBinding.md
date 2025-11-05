# Interface and Source IP Binding

Control which network interface SwiftFTR uses for network operations.

## Overview

SwiftFTR supports binding operations to specific network interfaces, giving you precise control over routing in multi-interface scenarios like:

- Simultaneous WiFi and Ethernet connections
- VPN tunnel selection
- Multi-homed servers
- Network testing and troubleshooting

Interface binding is available at two levels: global (set at initialization) and per-operation (override for specific calls).

## Binding Levels

SwiftFTR provides two levels of interface binding with a clear resolution order.

### Global Binding

Set a default interface for all operations:

```swift
import SwiftFTR

let config = SwiftFTRConfig(
    interface: "en0",              // Bind to en0 (WiFi)
    sourceIP: "192.168.1.100"      // Optional: specific source IP
)
let ftr = SwiftFTR(config: config)

// All operations use en0
let trace = try await ftr.trace(to: "1.1.1.1")
let ping = try await ftr.ping(to: "8.8.8.8")
```

### Per-Operation Binding

Override the global interface for specific operations:

```swift
import SwiftFTR

let ftr = SwiftFTR(config: SwiftFTRConfig(interface: "en0"))

// Use global interface (en0)
let wifiPing = try await ftr.ping(to: "1.1.1.1")

// Override to use Ethernet for this operation only
let ethPing = try await ftr.ping(
    to: "1.1.1.1",
    config: PingConfig(interface: "en14")
)

// Back to global interface (en0)
let wifiPing2 = try await ftr.ping(to: "8.8.8.8")
```

## Resolution Order

SwiftFTR resolves interface and source IP binding in this priority order:

**Operation Config → Global Config → System Default**

```swift
import SwiftFTR

// Example 1: Operation override wins
let ftr1 = SwiftFTR(config: SwiftFTRConfig(interface: "en0"))
let result1 = try await ftr1.ping(
    to: "1.1.1.1",
    config: PingConfig(interface: "en14")  // Uses en14, not en0
)

// Example 2: Global config used when no operation override
let result2 = try await ftr1.ping(to: "1.1.1.1")  // Uses en0

// Example 3: System routing used when neither specified
let ftr2 = SwiftFTR()
let result3 = try await ftr2.ping(to: "1.1.1.1")  // Uses system routing
```

## Supported Operations

All probe operations support per-operation interface binding.

### Ping

```swift
import SwiftFTR

let ftr = SwiftFTR()
let result = try await ftr.ping(
    to: "1.1.1.1",
    config: PingConfig(
        count: 5,
        interface: "en14"
    )
)

print("Ping via en14: \(result.statistics.avgRTT ?? 0)ms")
```

### TCP Probe

```swift
import SwiftFTR

let result = try await tcpProbe(
    config: TCPProbeConfig(
        host: "example.com",
        port: 443,
        timeout: 2.0,
        interface: "en0"
    )
)

print("TCP probe via en0: \(result.isReachable ? "reachable" : "unreachable")")
```

### DNS Probe

```swift
import SwiftFTR

let result = try await dnsProbe(
    config: DNSProbeConfig(
        server: "1.1.1.1",
        query: "example.com",
        timeout: 2.0,
        interface: "en14"
    )
)

print("DNS probe via en14: \(result.isReachable ? "reachable" : "unreachable")")
```

### Bufferbloat Test

```swift
import SwiftFTR

let ftr = SwiftFTR()
let result = try await ftr.testBufferbloat(
    config: BufferbloatConfig(
        target: "1.1.1.1",
        baselineDuration: 3.0,
        loadDuration: 5.0,
        interface: "en0"
    )
)

print("Bufferbloat via en0: \(result.grade.rawValue)")
```

## Multi-Interface Monitoring

Monitor network quality across multiple interfaces simultaneously:

```swift
import SwiftFTR

let ftr = SwiftFTR()

// Concurrent monitoring via WiFi and Ethernet
async let wifiResult = ftr.ping(
    to: "1.1.1.1",
    config: PingConfig(count: 10, interval: 0.5, interface: "en0")
)
async let ethResult = ftr.ping(
    to: "1.1.1.1",
    config: PingConfig(count: 10, interval: 0.5, interface: "en14")
)

let (wifi, ethernet) = try await (wifiResult, ethResult)

// Compare results
print("WiFi:     \(wifi.statistics.avgRTT.map { String(format: "%.1fms", $0 * 1000) } ?? "N/A")")
print("Ethernet: \(ethernet.statistics.avgRTT.map { String(format: "%.1fms", $0 * 1000) } ?? "N/A")")

if let wifiRTT = wifi.statistics.avgRTT,
   let ethRTT = ethernet.statistics.avgRTT {
    let faster = wifiRTT < ethRTT ? "WiFi" : "Ethernet"
    print("\(faster) is faster by \(abs(wifiRTT - ethRTT) * 1000)ms")
}
```

## Finding Interface Names

Use `ifconfig` to list available network interfaces:

```bash
ifconfig | grep "^[a-z]"
```

Common interface naming conventions on macOS:

- **en0**: Primary WiFi or Ethernet interface
- **en1-en14**: Additional Ethernet/WiFi interfaces
- **utun0-N**: VPN tunnels
- **bridge0**: Virtual bridge interfaces
- **lo0**: Loopback (localhost)

Query interface names programmatically:

```swift
import Foundation

#if canImport(Darwin)
func listInterfaces() -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
    process.arguments = ["-l"]

    let pipe = Pipe()
    process.standardOutput = pipe

    try? process.run()
    process.waitUntilExit()

    guard let data = try? pipe.fileHandleForReading.readToEnd(),
          let output = String(data: data, encoding: .utf8)
    else {
        return []
    }

    return output.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: " ")
        .map(String.init)
}

let interfaces = listInterfaces()
print("Available interfaces: \(interfaces)")
#endif
```

## Source IP Binding

Bind to a specific source IP address on an interface (useful for multi-IP interfaces):

```swift
import SwiftFTR

// Bind to specific source IP on WiFi interface
let result = try await SwiftFTR().ping(
    to: "1.1.1.1",
    config: PingConfig(
        count: 5,
        interface: "en0",
        sourceIP: "192.168.1.100"  // Must be assigned to en0
    )
)

// Source IP without interface (uses system routing)
let result2 = try await SwiftFTR().ping(
    to: "1.1.1.1",
    config: PingConfig(
        count: 5,
        sourceIP: "192.168.1.100"
    )
)
```

**Requirements**:
- Source IP must be assigned to the network interface
- Interface must be up and reachable
- IP must be valid IPv4 address

## Error Handling

Handle interface and source IP binding errors:

```swift
import SwiftFTR

let ftr = SwiftFTR()

do {
    let result = try await ftr.ping(
        to: "1.1.1.1",
        config: PingConfig(interface: "nonexistent999")
    )
} catch TracerouteError.interfaceBindFailed(let iface, let errno, let details) {
    print("Failed to bind to interface '\(iface)'")
    print("Error code: \(errno)")
    if let details = details {
        print("Details: \(details)")
    }
    // Common causes:
    // - Interface does not exist
    // - Interface is down
    // - Permission denied
} catch {
    print("Other error: \(error)")
}

do {
    let result = try await ftr.ping(
        to: "1.1.1.1",
        config: PingConfig(
            interface: "en0",
            sourceIP: "192.0.2.1"  // IP not assigned to en0
        )
    )
} catch TracerouteError.sourceIPBindFailed(let ip, let errno, let details) {
    print("Failed to bind to source IP '\(ip)'")
    print("Error code: \(errno)")
    if let details = details {
        print("Details: \(details)")
    }
    // Common causes:
    // - IP not assigned to any interface
    // - IP not assigned to specified interface
    // - Permission denied
} catch {
    print("Other error: \(error)")
}
```

Common error scenarios:

- **Interface not found**: Interface name is incorrect or interface is down
- **Permission denied**: App lacks network entitlements (rare on macOS)
- **IP not assigned**: Source IP is not configured on the interface
- **Interface index not found**: Interface exists but `if_nametoindex()` failed

## Bufferbloat Comparison Example

Compare bufferbloat quality across interfaces:

```swift
import SwiftFTR

let ftr = SwiftFTR()

// Test WiFi
let wifiConfig = BufferbloatConfig(
    target: "1.1.1.1",
    baselineDuration: 3.0,
    loadDuration: 5.0,
    interface: "en0"
)
let wifiResult = try await ftr.testBufferbloat(config: wifiConfig)

// Test Ethernet
let ethConfig = BufferbloatConfig(
    target: "1.1.1.1",
    baselineDuration: 3.0,
    loadDuration: 5.0,
    interface: "en14"
)
let ethResult = try await ftr.testBufferbloat(config: ethConfig)

// Compare
print("WiFi Bufferbloat:")
print("  Grade: \(wifiResult.grade.rawValue)")
print("  Latency increase: +\(String(format: "%.1f", wifiResult.latencyIncrease.percentageIncrease))%")

print("\nEthernet Bufferbloat:")
print("  Grade: \(ethResult.grade.rawValue)")
print("  Latency increase: +\(String(format: "%.1f", ethResult.latencyIncrease.percentageIncrease))%")

// Determine better interface
if wifiResult.grade < ethResult.grade {
    print("\n✅ WiFi has better bufferbloat performance")
} else if ethResult.grade < wifiResult.grade {
    print("\n✅ Ethernet has better bufferbloat performance")
} else {
    print("\n🤝 Both interfaces perform similarly")
}
```

## Implementation Details

SwiftFTR uses macOS's `IP_BOUND_IF` socket option for interface binding:

- Socket option 25 (`IP_BOUND_IF`) is macOS/iOS specific
- Takes interface index from `if_nametoindex()`
- Applied after `socket()` but before network operations
- Works for `SOCK_DGRAM` (ICMP, DNS) and `SOCK_STREAM` (TCP)
- Requires valid interface name and index

The binding is applied consistently across all probe types, ensuring predictable routing behavior.

## Platform Support

- **macOS**: Full support via `IP_BOUND_IF` socket option
- **iOS**: Full support (requires network entitlements)
- **Linux**: Not yet supported (would require `SO_BINDTODEVICE`)

## Topics

### Configuration

- ``SwiftFTR/SwiftFTRConfig/interface``
- ``SwiftFTR/SwiftFTRConfig/sourceIP``
- ``SwiftFTR/PingConfig/interface``
- ``SwiftFTR/PingConfig/sourceIP``
- ``SwiftFTR/TCPProbeConfig/interface``
- ``SwiftFTR/TCPProbeConfig/sourceIP``
- ``SwiftFTR/DNSProbeConfig/interface``
- ``SwiftFTR/DNSProbeConfig/sourceIP``
- ``SwiftFTR/BufferbloatConfig/interface``
- ``SwiftFTR/BufferbloatConfig/sourceIP``

### Error Handling

- ``SwiftFTR/TracerouteError/interfaceBindFailed(interface:errno:details:)``
- ``SwiftFTR/TracerouteError/sourceIPBindFailed(sourceIP:errno:details:)``
