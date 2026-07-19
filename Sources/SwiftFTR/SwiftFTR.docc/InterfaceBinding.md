# Interface and Source IP Binding

Control which network interface supported SwiftFTR operations use.

## Overview

SwiftFTR supports binding selected socket-backed operations to specific network interfaces, giving you routing control in multi-interface scenarios like:

- Simultaneous WiFi and Ethernet connections
- VPN tunnel selection
- Multi-homed servers
- Network testing and troubleshooting

Support varies by API. Traceroute uses the global ``SwiftFTRConfig`` setting, ping supports global
and per-operation settings, and TCP, UDP, and DNS probes expose operation-level settings. HTTP
probes follow system routing because URLSession does not expose interface binding.

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

The examples below use these discovered values. Ping and the DNS query helpers inherit global
interface and source-IP settings when an operation does not override them. Standalone TCP, UDP,
and DNS probes use only their operation config; a `nil` binding lets the system select the route.

## Binding Levels

Some SwiftFTR APIs provide both global and per-operation binding with a clear resolution order.

### Global Binding

Set a default interface for supported operations launched through a ``SwiftFTR/SwiftFTR`` instance, including traceroute, ping, and the DNS query helpers:

```swift
import SwiftFTR

let config = SwiftFTRConfig(
    interface: wifiInterface.name,
    sourceIP: wifiInterface.ipv4Addresses.first
)
let ftr = SwiftFTR(config: config)

// Traceroute and ping use the configured interface.
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

For APIs that expose both global and operation settings, SwiftFTR resolves interface and source IP binding in this priority order:

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

Binding support is not uniform across every transport:

- Traceroute and streaming traceroute use ``SwiftFTR/SwiftFTRConfig/interface`` and ``SwiftFTR/SwiftFTRConfig/sourceIP``.
- Ping uses the global settings and supports overrides through ``SwiftFTR/PingConfig``.
- The DNS query helpers use global settings and support call-level overrides. The standalone DNS probe uses ``SwiftFTR/DNSProbeConfig``.
- The standalone TCP and UDP probes use ``SwiftFTR/TCPProbeConfig`` and ``SwiftFTR/UDPProbeConfig``.
- Bufferbloat applies its binding settings only to latency pings; its HTTP load traffic follows system routing.
- HTTP probes don't expose binding settings.

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

### UDP Probe

```swift
import SwiftFTR

let result = try await udpProbe(
    config: UDPProbeConfig(
        host: "1.1.1.1",
        port: 53,
        timeout: 2.0,
        interface: wifiInterface.name,
        sourceIP: wifiInterface.ipv4Addresses.first,
        preferredFamily: .v4
    )
)

print("UDP probe via \(wifiInterface.name): \(result.isReachable ? "reachable" : "unreachable")")
```

When `sourceIP` is set, its address family must match the resolved destination family. Use
``SwiftFTR/UDPProbeConfig/preferredFamily`` to request IPv4, IPv6, or automatic selection.

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

### HTTP Probe

HTTP and HTTPS probes use URLSession and do not support interface or source-IP binding. Their
traffic follows the system-selected route.

### Bufferbloat Test

Interface and source-IP binding are supported only for a baseline-only latency measurement. A
loaded bufferbloat test rejects effective per-operation or global bindings because its URLSession
load traffic cannot be bound to the same route.

```swift
import SwiftFTR

let ftr = SwiftFTR()
let result = try await ftr.testBufferbloat(
    config: BufferbloatConfig(
        target: "1.1.1.1",
        baselineDuration: 3.0,
        loadDuration: 0,
        interface: wifiInterface.name
    )
)

print("Baseline latency via \(wifiInterface.name): \(result.baseline.avgMs) ms")
```

Only `result.baseline` and baseline entries in `result.pingResults` are usable in this mode.
`result.loaded`, `result.latencyIncrease`, `result.rpm`, and `result.grade` require a loaded phase
and are not meaningful for this result.

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
- IP must be a valid IPv4 or IPv6 address; link-local IPv6 addresses may include a `%zone` suffix

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

## URLSession Limitation

HTTP/HTTPS probes and bufferbloat load generation use URLSession. URLSession's public API does not
provide an interface or source-IP binding option, so those requests follow the system-selected
route. SwiftFTR does not claim that setting a global binding changes URLSession traffic.

## Bufferbloat Limitation

Loaded bufferbloat tests cannot be bound to an interface or source IP. SwiftFTR uses
`URLSession` to generate HTTP load, and its public API does not support binding a request to a
specific route. Binding only the latency probes would compare traffic from potentially different
routes and produce a misleading grade, so ``SwiftFTR/SwiftFTR/testBufferbloat(config:)`` throws
``SwiftFTR/TracerouteError/invalidConfiguration(reason:)`` before starting network work.

Interface binding remains available for a baseline-only latency measurement. The baseline
statistics and baseline ping samples are usable, but loaded statistics, latency increase, RPM,
grade, and the derived video-call assessment are not meaningful without a loaded phase:

```swift
import SwiftFTR

let ftr = SwiftFTR()
let config = BufferbloatConfig(
    target: "1.1.1.1",
    baselineDuration: 3.0,
    loadDuration: 0,
    interface: wifiInterface.name
)
let result = try await ftr.testBufferbloat(config: config)
print("Baseline latency via \(wifiInterface.name): \(result.baseline.avgMs) ms")
```

## Implementation Details

SwiftFTR uses macOS's `IP_BOUND_IF` and `IPV6_BOUND_IF` socket options for interface binding:

- Socket option 25 (`IP_BOUND_IF`) is Darwin-specific
- Takes interface index from `if_nametoindex()`
- Applied after `socket()` but before network operations
- Applied to ICMP, DNS, TCP, and UDP sockets by the APIs listed above
- Requires valid interface name and index

The binding applies to ping, traceroute, TCP, UDP, and DNS sockets. It does not apply to
URLSession-backed HTTP/HTTPS probes or bufferbloat load requests.
Loaded bufferbloat tests reject route-specific configurations because binding only their latency
probes would invalidate the measurement.

## Platform Support

- **macOS**: Supported socket operations use `IP_BOUND_IF` / `IPV6_BOUND_IF`
- **Linux**: Not yet supported (would require `SO_BINDTODEVICE`)

## Topics

### Configuration

- ``SwiftFTR/SwiftFTRConfig/interface``
- ``SwiftFTR/SwiftFTRConfig/sourceIP``
- ``SwiftFTR/PingConfig/interface``
- ``SwiftFTR/PingConfig/sourceIP``
- ``SwiftFTR/TCPProbeConfig/interface``
- ``SwiftFTR/TCPProbeConfig/sourceIP``
- ``SwiftFTR/UDPProbeConfig/interface``
- ``SwiftFTR/UDPProbeConfig/sourceIP``
- ``SwiftFTR/DNSProbeConfig/interface``
- ``SwiftFTR/DNSProbeConfig/sourceIP``
- ``SwiftFTR/BufferbloatConfig/interface``
- ``SwiftFTR/BufferbloatConfig/sourceIP``

### Error Handling

- ``SwiftFTR/TracerouteError/interfaceBindFailed(interface:errno:details:)``
- ``SwiftFTR/TracerouteError/sourceIPBindFailed(sourceIP:errno:details:)``
- ``SwiftFTR/TracerouteError/invalidConfiguration(reason:)``
