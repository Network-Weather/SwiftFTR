# ``SwiftFTR``

Massively parallel, async/await traceroute for macOS using ICMP datagram sockets (no sudo required).

## Overview

``SwiftFTR`` provides a single-socket, parallel traceroute implementation that sends one ICMP Echo per TTL and collects ICMP Time Exceeded and Echo Reply messages concurrently.

- IPv4, macOS-focused (uses `SOCK_DGRAM` with `IPPROTO_ICMP`).
- Async/await API returning structured hop results.
- Optional classification into segments (LOCAL, ISP, TRANSIT, DESTINATION) using ASN lookups and heuristics.
- STUN-based public IP discovery (can be bypassed via configuration).

## Usage

### Basic tracing

```swift
import SwiftFTR

let tracer = SwiftFTR(config: SwiftFTRConfig(maxHops: 30, maxWaitMs: 1000))
let result = try await tracer.trace(to: "1.1.1.1")
for hop in result.hops {
    print(hop.ttl, hop.ipAddress ?? "*", hop.rtt ?? 0)
}
```

### Classified tracing

```swift
import SwiftFTR

let tracer = SwiftFTR()
let classified = try await tracer.traceClassified(to: "www.nic.br")
for hop in classified.hops {
    print(hop.ttl, hop.ip ?? "*", hop.category, hop.asn.map(String.init) ?? "-")
}
```

### DNS queries (v0.8.0+)

```swift
import SwiftFTR

let tracer = SwiftFTR()

// IPv4 lookup with metadata
let result = try await tracer.dns.a(hostname: "google.com")
print("RTT: \(result.rttMs)ms")
for record in result.records {
    if case .ipv4(let addr) = record.data {
        print("\(addr) (TTL: \(record.ttl)s)")
    }
}

// Reverse DNS
let ptr = try await tracer.dns.reverseIPv4(ip: "8.8.8.8")
for record in ptr.records {
    if case .hostname(let name) = record.data {
        print(name)
    }
}

// Mail servers
let mx = try await tracer.dns.query(name: "gmail.com", type: .mx)
```

## Configuration

- Use ``SwiftFTRConfig(publicIP:)`` to override/bypass STUN public IP discovery.
- Inject a custom ``SwiftFTR/ASNResolver`` for offline or deterministic lookups.

## Topics

### Tracing

- ``SwiftFTR/SwiftFTR``
- ``SwiftFTR/TraceResult``
- ``SwiftFTR/TraceHop``
- <doc:Tracing>

### Classification

- ``SwiftFTR/TraceClassifier``
- ``SwiftFTR/ClassifiedTrace``
- ``SwiftFTR/ClassifiedHop``
- ``SwiftFTR/HopCategory``

### Ping (v0.5.0+)

- ``SwiftFTR/PingConfig``
- ``SwiftFTR/PingResult``
- ``SwiftFTR/PingStatistics``
- <doc:Ping>

### Multipath Discovery (v0.5.0+)

- ``SwiftFTR/MultipathConfig``
- ``SwiftFTR/NetworkTopology``
- ``SwiftFTR/DiscoveredPath``
- <doc:Multipath>

### DNS Queries (v0.8.0+)

- ``SwiftFTR/DNSClient``
- ``SwiftFTR/DNSQueryResult``
- ``SwiftFTR/DNSRecord``
- ``SwiftFTR/DNSRecordType``
- ``SwiftFTR/DNSRecordData``

### Interface Binding (v0.7.0+)

- ``SwiftFTR/SwiftFTRConfig/interface``
- ``SwiftFTR/SwiftFTRConfig/sourceIP``
- <doc:InterfaceBinding>
