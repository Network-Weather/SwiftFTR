# Interface and Source IP Binding

Control which network interface supported SwiftFTR operations use.

## Overview

SwiftFTR supports binding selected socket-backed operations to specific network interfaces, giving you routing control in multi-interface scenarios like:

- Simultaneous Wi-Fi and Ethernet connections
- VPN tunnel selection
- Multi-homed servers
- Network testing and troubleshooting

Binding applies to the sockets created by the supported operation. It does not bind hostname
resolution, system reverse DNS, Team Cymru ASN queries, or URLSession traffic.

| API | Binding source | Address families | Important scope |
| --- | --- | --- | --- |
| Trace, streaming trace, classified trace | Global ``SwiftFTRConfig`` only | IPv4 and IPv6 | Probe sockets only; hostname resolution, rDNS, and Cymru queries use system routing. |
| Multipath discovery | Global ``SwiftFTRConfig`` only | IPv4 only | IPv6 destinations and source addresses are rejected. |
| Ping | ``PingConfig`` values independently override global values; each `nil` value inherits its global counterpart | IPv4 and IPv6 | Probe socket only. |
| Actor DNS query helpers (`tracer.dns`) | Call-level values independently override global values | IPv4 and IPv6 DNS transports | The numeric DNS server selects the transport family; record type does not. An AAAA query therefore uses IPv4 by default because the default server is `8.8.8.8`. |
| Standalone DNS query functions and DNS/TCP/UDP probes | Function arguments or operation config only | IPv4 and IPv6 | They do not inherit ``SwiftFTRConfig``; hostname resolution for TCP/UDP remains system-routed. |
| ``getPublicIPs(stunTimeout:interface:sourceIP:enableLogging:)`` | Function arguments only | Parallel IPv4 and IPv6 STUN | A source address is applied only to its matching family. |
| ``SwiftFTR/discoverPublicIPWithHostname()`` | Global config for IPv4 STUN | IPv4 | DNS-whoami fallback and the optional rDNS lookup are system-routed. |
| Bufferbloat | Operation values override globals | IPv4 and IPv6 baseline ping | Binding is accepted only when `loadDuration == 0`; loaded tests reject any effective binding. |
| HTTP/HTTPS probe | None | URLSession-selected | Interface and source-address binding are unavailable. |

## Selecting Interface Names

Discover interfaces at runtime, present the operating system's metadata to the caller, and pass
back the exact BSD name the caller selected. BSD names are identifiers only; their numeric suffix
does not identify Wi-Fi or Ethernet hardware. Select a source address explicitly too—do not use
the first address when the interface has several.

```swift
import SwiftFTR

enum InterfaceSelectionError: Error {
    case unavailable(String)
    case addressNotAssigned(String)
}

struct SelectedRoute {
    let interface: NetworkInterface
    let sourceIP: String?
}

func validateRouteSelection(
    interfaceName: String,
    sourceIP: String?,
    from snapshot: NetworkInterfaceSnapshot
) throws -> SelectedRoute {
    guard let interface = snapshot.interface(named: interfaceName), interface.isUp else {
        throw InterfaceSelectionError.unavailable(interfaceName)
    }
    let assignedAddresses = interface.ipv4Addresses + interface.ipv6Addresses
    if let sourceIP, !assignedAddresses.contains(sourceIP) {
        throw InterfaceSelectionError.addressNotAssigned(sourceIP)
    }
    return SelectedRoute(interface: interface, sourceIP: sourceIP)
}
```

Call this validator with the exact interface name and optional source address selected by your UI.
The examples below call two validated results `selectedRoute` and `alternateRoute`. A `nil`
binding lets the system select the route.

## Binding Levels

Some SwiftFTR APIs provide both global and per-operation binding with a clear resolution order.

### Global Binding

Set a default interface for supported operations launched through a ``SwiftFTR/SwiftFTR`` instance, including traceroute, ping, and the DNS query helpers:

```swift
import SwiftFTR

let config = SwiftFTRConfig(
    interface: selectedRoute.interface.name
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

let ftr = SwiftFTR(config: SwiftFTRConfig(interface: selectedRoute.interface.name))

// Use the global interface selection.
let primaryPing = try await ftr.ping(to: "1.1.1.1")

// Override with the caller's alternate selection for this operation only.
let alternatePing = try await ftr.ping(
    to: "1.1.1.1",
    config: PingConfig(interface: alternateRoute.interface.name)
)

// Back to the global interface selection.
let primaryPing2 = try await ftr.ping(to: "8.8.8.8")
```

## Resolution Order

For APIs that expose both global and operation settings, SwiftFTR resolves interface and source IP binding in this priority order:

**Operation Config → Global Config → System Default**

```swift
import SwiftFTR

// Example 1: Operation override wins
let ftr1 = SwiftFTR(config: SwiftFTRConfig(interface: selectedRoute.interface.name))
let result1 = try await ftr1.ping(
    to: "1.1.1.1",
    config: PingConfig(interface: alternateRoute.interface.name)
)

// Example 2: Global config used when no operation override
let result2 = try await ftr1.ping(to: "1.1.1.1")

// Example 3: System routing used when neither specified
let ftr2 = SwiftFTR()
let result3 = try await ftr2.ping(to: "1.1.1.1")  // Uses system routing
```

## Supported Operations

The matrix above is authoritative. The examples below show the operation-level forms.

### Ping

```swift
import SwiftFTR

let ftr = SwiftFTR()
let result = try await ftr.ping(
    to: "1.1.1.1",
    config: PingConfig(
        count: 5,
        interface: alternateRoute.interface.name
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
        interface: selectedRoute.interface.name
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
        interface: selectedRoute.interface.name,
        preferredFamily: .v4
    )
)

print("UDP probe via \(selectedRoute.interface.name): \(result.isReachable ? "reachable" : "unreachable")")
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
        interface: selectedRoute.interface.name
    )
)

print("DNS probe via selected interface: \(result.isReachable ? "reachable" : "unreachable")")
```

The DNS server must be a numeric address. Its family selects the UDP transport independently of
the record type: an AAAA query sent to `8.8.8.8` travels over IPv4, while the same query sent to an
IPv6 DNS server travels over IPv6.

### Public IP Discovery

Use the standalone dual-stack API when the caller needs operation-level route selection:

```swift
let publicIPs = await getPublicIPs(
    interface: selectedRoute.interface.name,
    sourceIP: selectedRoute.sourceIP
)
print(publicIPs.v4 as Any, publicIPs.v6 as Any)
```

``SwiftFTR/discoverPublicIPWithHostname()`` instead inherits the actor's global binding and first
tries bound IPv4 STUN. If STUN fails, its DNS-whoami fallback drops that binding; the optional
reverse-DNS lookup is also system-routed.

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
        interface: selectedRoute.interface.name
    )
)

print("Baseline latency via \(selectedRoute.interface.name): \(result.baseline.avgMs) ms")
```

Only `result.baseline` and baseline entries in `result.pingResults` are usable in this mode.
`result.loaded`, `result.latencyIncrease`, `result.rpm`, and `result.grade` require a loaded phase
and are not meaningful for this result.

## Multi-Interface Monitoring

Monitor network quality across multiple interfaces simultaneously:

```swift
import SwiftFTR

let ftr = SwiftFTR()

// Concurrent monitoring via two exact caller-selected routes.
async let primaryResult = ftr.ping(
    to: "1.1.1.1",
    config: PingConfig(count: 10, interval: 0.5, interface: selectedRoute.interface.name)
)
async let alternateResult = ftr.ping(
    to: "1.1.1.1",
    config: PingConfig(count: 10, interval: 0.5, interface: alternateRoute.interface.name)
)

let (primary, alternate) = try await (primaryResult, alternateResult)

// Compare results
print("Primary:   \(primary.statistics.avgRTT.map { String(format: "%.1fms", $0 * 1000) } ?? "N/A")")
print("Alternate: \(alternate.statistics.avgRTT.map { String(format: "%.1fms", $0 * 1000) } ?? "N/A")")

if let primaryRTT = primary.statistics.avgRTT,
   let alternateRTT = alternate.statistics.avgRTT {
    let faster = primaryRTT < alternateRTT ? "primary" : "alternate"
    print("The \(faster) route is faster by \(abs(primaryRTT - alternateRTT) * 1000)ms")
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

func pingFromSelectedIPv4(_ route: SelectedRoute) async throws {
    guard let sourceIP = route.sourceIP,
          route.interface.ipv4Addresses.contains(sourceIP)
    else {
        throw InterfaceSelectionError.addressNotAssigned(route.sourceIP ?? "")
    }

    // Bind to the exact interface and address selected by the caller.
    let result = try await SwiftFTR().ping(
        to: "1.1.1.1",
        config: PingConfig(
            count: 5,
            interface: route.interface.name,
            sourceIP: sourceIP,
            preferredFamily: .v4
        )
    )

    // Source IP without an explicit interface (the system selects the route).
    let result2 = try await SwiftFTR().ping(
        to: "1.1.1.1",
        config: PingConfig(
            count: 5,
            sourceIP: sourceIP,
            preferredFamily: .v4
        )
    )
}
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
// Longer than Darwin's interface-name limit, so this cannot accidentally name real hardware.
let impossibleInterfaceName = String(repeating: "x", count: 64)

do {
    let result = try await ftr.ping(
        to: "1.1.1.1",
        config: PingConfig(interface: impossibleInterfaceName)
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
            interface: selectedRoute.interface.name,
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

## Implementation Details

SwiftFTR uses macOS's `IP_BOUND_IF` and `IPV6_BOUND_IF` socket options for interface binding:

- Socket option 25 (`IP_BOUND_IF`) is Darwin-specific
- Takes interface index from `if_nametoindex()`
- Applied after `socket()` but before network operations
- Applied to ICMP, DNS, TCP, and UDP sockets by the APIs listed above
- Requires valid interface name and index

The binding applies only to the ping, traceroute, TCP, UDP, DNS, and STUN sockets identified in the
support matrix. It does not apply to prerequisite hostname resolution, system rDNS, Team Cymru
queries, DNS-whoami fallback, URLSession-backed HTTP/HTTPS probes, or bufferbloat load requests.

## Platform Support

- **macOS 13 and later**: Supported socket operations use Darwin's `IP_BOUND_IF` / `IPV6_BOUND_IF`
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
