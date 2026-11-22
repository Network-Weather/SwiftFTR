# Probing

Test network reachability with TCP, UDP, HTTP, and DNS probes.

## Overview

SwiftFTR provides four probe types for testing reachability without requiring elevated privileges. Each probe type is designed for a different use case and returns structured results with timing information. The probes are module-level functions, so they need no ``SwiftFTR/SwiftFTR`` instance and do not inherit its ``SwiftFTRConfig``.

- **TCP Probe** (``tcpProbe(config:)``): Port state detection — distinguishes open (SYN-ACK), closed (RST), and filtered (timeout)
- **UDP Probe** (``udpProbe(config:)``): Connected-socket trick with ICMP unreachable detection
- **HTTP Probe** (``httpProbe(config:)``): Web server reachability via URLSession, with best-effort network and TCP-handshake timing
- **DNS Probe** (``dnsProbe(config:)``): DNS server reachability; for record lookups across 11 record types, use ``SwiftFTR/SwiftFTR/dns`` instead

All probes share a common pattern: configure, call, and inspect the result. Each returns a `Codable` result struct with `isReachable`, RTT, and protocol-specific details. Each also has a convenience overload taking the host (or URL, or server) and timeout directly, such as `tcpProbe(host:port:timeout:)`.

Invalid numeric settings throw ``SwiftFTR/TracerouteError/invalidConfiguration(reason:)`` from the TCP and UDP probes, and ``SwiftFTR/DNSError`` from the DNS probe. The HTTP probe reports invalid input, failures, and cancellation in its result's `error` field rather than throwing. Cancelling the calling task makes the TCP and UDP probes throw `CancellationError`.

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
The probe stops the transfer after receiving response headers, so large or streaming response bodies are not buffered.

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

The TCP, UDP, and DNS probes support binding to a specific network interface or source IP. The
HTTP probe uses URLSession, whose public API does not expose either binding control.

```swift
func probeVPN(interfaceName: String) async throws {
    let snapshot = await NetworkInterfaceDiscovery().discover()
    guard let vpnInterface = snapshot.interface(named: interfaceName),
          vpnInterface.isUp, vpnInterface.type.isVPN
    else { return }

    let config = TCPProbeConfig(
        host: "internal.corp.example.com",
        port: 443,
        interface: vpnInterface.name
    )
    let result = try await tcpProbe(config: config)
}
```

Use the corresponding `interface` and `sourceIP` properties on ``UDPProbeConfig`` or
``DNSProbeConfig`` for those protocols. ``HTTPProbeConfig`` intentionally has no such properties;
HTTP traffic follows URLSession's system-selected route. TCP and UDP hostname resolution also
uses system routing; the binding begins at the probe socket.

## Topics

### TCP Probing

- ``tcpProbe(config:)``
- ``TCPProbeConfig``
- ``TCPProbeResult``
- ``TCPConnectionState``

### UDP Probing

- ``udpProbe(config:)``
- ``UDPProbeConfig``
- ``UDPProbeResult``

### HTTP Probing

- ``httpProbe(config:)``
- ``HTTPProbeConfig``
- ``HTTPProbeResult``

### DNS Probing

- ``dnsProbe(config:)``
- ``DNSProbeConfig``
- ``DNSProbeResult``
