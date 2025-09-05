# ``SwiftFTR``

Massively parallel, async/await traceroute for macOS using ICMP datagram sockets (no sudo required).

## Overview

``SwiftFTR`` provides a single-socket, parallel traceroute implementation that sends one ICMP Echo per TTL and collects ICMP Time Exceeded and Echo Reply messages concurrently.

- IPv4, macOS-focused (uses `SOCK_DGRAM` with `IPPROTO_ICMP`).
- Async/await API returning structured hop results.
- Optional classification into segments (LOCAL, ISP, TRANSIT, DESTINATION) using ASN lookups and heuristics.
- STUN-based public IP discovery (opt-out via environment).

## Usage

### Basic tracing

```swift
import SwiftFTR

let tracer = SwiftFTR()
let result = try await tracer.trace(to: "1.1.1.1", maxHops: 30, timeout: 1.0)
for hop in result.hops {
    print(hop.ttl, hop.host ?? "*", hop.rtt ?? 0)
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

## Environment toggles

- `PTR_SKIP_STUN=1`: disable STUN lookup (keeps runtime isolated/offline).
- `PTR_PUBLIC_IP=x.y.z.w`: override public IP used for ISP-ASN matching.
- `PTR_DNS=ip,ip,...`: override DNS servers used by the DNS-based ASN resolver.

## Topics

### Tracing

- ``SwiftFTR/SwiftFTR``
- ``SwiftFTR/TraceResult``
- ``SwiftFTR/TraceHop``

### Classification

- ``SwiftFTR/TraceClassifier``
- ``SwiftFTR/ClassifiedTrace``
- ``SwiftFTR/ClassifiedHop``
- ``SwiftFTR/HopCategory``

