# Probing

Use ``SwiftFTR/SwiftFTR`` to test network reachability with TCP, UDP, HTTP, and DNS probes.

## Overview

SwiftFTR provides four probe types for testing reachability without requiring elevated privileges. Each probe type is designed for a different use case and returns structured results with timing information.

- **TCP Probe**: Port state detection — distinguishes open (SYN-ACK), closed (RST), and filtered (timeout)
- **UDP Probe**: Connected-socket trick with ICMP unreachable detection
- **HTTP Probe**: Web server reachability via URLSession, including TLS timing
- **DNS Probe**: Direct DNS server queries with 11 record types

All probes share a common pattern: configure, call, and inspect the result. Each returns a `Codable` result struct with `isReachable`, RTT, and protocol-specific details.

## TCP Probe

Test whether a TCP port is open, closed, or filtered:

```swift
import SwiftFTR

let config = TCPProbeConfig(host: "example.com", port: 443, timeout: 2.0)
let result = try await tcpProbe(config: config)

switch result.connectionState {
case .open:     print("Port open (SYN-ACK received)")
case .closed:   print("Port closed (RST received — host reachable)")
case .filtered: print("Port filtered (no response)")
case .error:    print("Error: \(result.error ?? "unknown")")
}
```

Key behavior: A closed port (RST) still means the host is reachable — `isReachable` is `true` for both `.open` and `.closed`.

## UDP Probe

Test UDP reachability using a connected socket:

```swift
import SwiftFTR

let config = UDPProbeConfig(host: "8.8.8.8", port: 53, timeout: 2.0)
let result = try await udpProbe(config: config)

print("Reachable: \(result.isReachable)")
if let rtt = result.rtt {
    print("RTT: \(String(format: "%.1f", rtt * 1000)) ms")
}
```

UDP probing uses the connected-socket trick: after `connect()`, the kernel routes ICMP Port Unreachable messages back as socket errors, detectable without raw sockets.

## HTTP Probe

Test HTTP/HTTPS server reachability with optional redirect following:

```swift
import SwiftFTR

let config = HTTPProbeConfig(url: "https://example.com", timeout: 5.0, followRedirects: true)
let result = try await httpProbe(config: config)

print("Reachable: \(result.isReachable)")
if let status = result.statusCode {
    print("HTTP Status: \(status)")
}
if let tcpRTT = result.tcpHandshakeRTT {
    print("TCP Handshake: \(String(format: "%.1f", tcpRTT * 1000)) ms")
}
```

Any HTTP response (even 4xx/5xx) counts as reachable — the probe tests network connectivity, not content availability.

## DNS Probe

Test DNS server reachability by sending a query:

```swift
import SwiftFTR

let config = DNSProbeConfig(server: "1.1.1.1", query: "example.com", timeout: 2.0)
let result = try await dnsProbe(config: config)

print("Reachable: \(result.isReachable)")
if let rcode = result.responseCode {
    print("Response code: \(rcode)")  // 0 = NOERROR, 3 = NXDOMAIN
}
```

Any DNS response (even NXDOMAIN) means the server is reachable. Only timeouts and network errors indicate unreachability.

## Interface Binding

All probe types support binding to a specific network interface:

```swift
// TCP probe through VPN
let config = TCPProbeConfig(
    host: "internal.corp.example.com",
    port: 443,
    interface: "utun3"
)
let result = try await tcpProbe(config: config)
```

## Topics

### TCP Probing

- ``TCPProbeConfig``
- ``TCPProbeResult``
- ``TCPConnectionState``

### UDP Probing

- ``UDPProbeConfig``
- ``UDPProbeResult``

### HTTP Probing

- ``HTTPProbeConfig``
- ``HTTPProbeResult``

### DNS Probing

- ``DNSProbeConfig``
- ``DNSProbeResult``
