# Interface and Source IP Binding

Control which network interface SwiftFTR uses for network operations.

## Overview

SwiftFTR supports binding operations to specific network interfaces, giving you precise control over routing in multi-interface scenarios like:

- Simultaneous WiFi and Ethernet connections
- VPN tunnel selection
- Multi-homed servers
- Network testing and troubleshooting

Interface binding is available at two levels: global (set at initialization) and per-operation (override for specific calls).

## Selecting Interface Names

Discover interfaces at runtime and select by the operating system's reported type. BSD names are identifiers only; their numeric suffix does not identify WiFi or Ethernet hardware.

```swift
import SwiftFTR

let interfaceSnapshot = await NetworkInterfaceDiscovery().discover()

enum InterfaceSelectionError: Error {
    case unavailable(InterfaceType)
}

func requireInterface(
    _ type: InterfaceType,
    from snapshot: NetworkInterfaceSnapshot
) throws -> NetworkInterface {
    guard let interface = snapshot.physicalInterfaces.first(where: { $0.type == type }) else {
        throw InterfaceSelectionError.unavailable(type)
    }
    return interface
}

let wifiInterface = try requireInterface(.wifi, from: interfaceSnapshot)
let ethernetInterface = try requireInterface(.ethernet, from: interfaceSnapshot)
```

The examples below use these discovered values. A `nil` operation-level interface inherits the global configuration; system routing is used only when both operation-level and global interface values are `nil`.

## Binding Levels

SwiftFTR provides two levels of interface binding with a clear resolution order.

### Global Binding

Set a default interface for all operations:

```swift
import SwiftFTR

let config = SwiftFTRConfig(
    interface: wifiInterface.name,
    sourceIP: wifiInterface.ipv4Addresses.first
)
let ftr = SwiftFTR(config: config)

// All operations use the selected interface when one was found.
let trace = try await ftr.trace(to: "1.1.1.1")
let ping = try await ftr.ping(to: "8.8.8.8")
```

### Per-Operation Binding

Override the global interface for specific operations:

```swift
import SwiftFTR

let ftr = SwiftFTR(config: SwiftFTRConfig(interface: wifiInterface.name))

// Use the global interface selection.
let wifiPing = try await ftr.ping(to: "1.1.1.1")

// Override to use Ethernet for this operation only
let ethPing = try await ftr.ping(
    to: "1.1.1.1",
    config: PingConfig(interface: ethernetInterface.name)
)

// Back to the global interface selection.
let wifiPing2 = try await ftr.ping(to: "8.8.8.8")
```

## Resolution Order

SwiftFTR resolves interface and source IP binding in this priority order:

**Operation Config → Global Config → System Default**

```swift
import SwiftFTR

// Example 1: Operation override wins
let ftr1 = SwiftFTR(config: SwiftFTRConfig(interface: wifiInterface.name))
let result1 = try await ftr1.ping(
    to: "1.1.1.1",
    config: PingConfig(interface: ethernetInterface.name)
)

// Example 2: Global config used when no operation override
let result2 = try await ftr1.ping(to: "1.1.1.1")

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
        interface: ethernetInterface.name
    )
)

print("Ping via selected interface: \(result.statistics.avgRTT ?? 0)ms")
```

### TCP Probe

```swift
import SwiftFTR

let result = try await tcpProbe(
    config: TCPProbeConfig(
        host: "example.com",
        port: 443,
        timeout: 2.0,
        interface: wifiInterface.name
    )
)

print("TCP probe via selected interface: \(result.isReachable ? "reachable" : "unreachable")")
```

### DNS Probe

```swift
import SwiftFTR

let result = try await dnsProbe(
    config: DNSProbeConfig(
        server: "1.1.1.1",
        query: "example.com",
        timeout: 2.0,
        interface: ethernetInterface.name
    )
)

print("DNS probe via selected interface: \(result.isReachable ? "reachable" : "unreachable")")
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
        interface: wifiInterface.name
    )
)

print("Bufferbloat via selected interface: \(result.grade.rawValue)")
```

## Multi-Interface Monitoring

Monitor network quality across multiple interfaces simultaneously:

```swift
import SwiftFTR

let ftr = SwiftFTR()

// Concurrent monitoring via WiFi and Ethernet
async let wifiResult = ftr.ping(
    to: "1.1.1.1",
    config: PingConfig(count: 10, interval: 0.5, interface: wifiInterface.name)
)
async let ethResult = ftr.ping(
    to: "1.1.1.1",
    config: PingConfig(count: 10, interval: 0.5, interface: ethernetInterface.name)
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

Query interface names and system-reported types programmatically:

```swift
import SwiftFTR

let snapshot = await NetworkInterfaceDiscovery().discover()
for interface in snapshot.interfaces {
    print(interface.name, interface.type.rawValue, interface.isUp)
}
```

Do not derive a physical interface's role from its BSD name. Names can change with hardware, OS configuration, and network topology.

## Source IP Binding

Bind to a specific source IP address on an interface (useful for multi-IP interfaces):

```swift
import SwiftFTR

// Bind to an address reported for the selected interface.
let result = try await SwiftFTR().ping(
    to: "1.1.1.1",
    config: PingConfig(
        count: 5,
        interface: wifiInterface.name,
        sourceIP: wifiInterface.ipv4Addresses.first
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
            interface: wifiInterface.name,
            sourceIP: "192.0.2.1"  // Documentation-only address, normally unassigned
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
    interface: wifiInterface.name
)
let wifiResult = try await ftr.testBufferbloat(config: wifiConfig)

// Test Ethernet
let ethConfig = BufferbloatConfig(
    target: "1.1.1.1",
    baselineDuration: 3.0,
    loadDuration: 5.0,
    interface: ethernetInterface.name
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
