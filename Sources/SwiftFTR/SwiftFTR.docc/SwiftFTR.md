# ``SwiftFTR``

Massively parallel, async/await traceroute for macOS using ICMP datagram sockets (no sudo required).

## Overview

``SwiftFTR`` provides a single-socket, parallel traceroute implementation that sends one ICMP Echo per TTL and collects ICMP Time Exceeded, Destination Unreachable, and Echo Reply messages concurrently.

- IPv4 and IPv6 on macOS 13 and later, using ICMP datagram sockets (`IPPROTO_ICMP` and
  `IPPROTO_ICMPV6`).
- Async/await API returning structured hop results; each hop reports a ``SwiftFTR/HopOutcome``.
- Optional classification into segments (LOCAL, ISP, TRANSIT, VPN, DESTINATION) using ASN lookups
  and heuristics.
- Streaming traceroute, ping, TCP/UDP/HTTP/DNS probes, ECMP multipath discovery, and a
  bufferbloat test.
- STUN-based public IP discovery and configurable classified-trace enrichment.

Upgrading from 0.17? Review <doc:MigratingTo018> for the behavior changes introduced in 0.18.
Upgrading from 0.13 or earlier? Review <doc:MigratingTo014> for the source-level and behavior
changes introduced in 0.14. See the project's CHANGELOG for the releases in between.

## Usage

### Basic tracing

```swift
import SwiftFTR

let tracer = SwiftFTR(config: SwiftFTRConfig(maxHops: 40, maxWaitMs: 1000))
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

### DNS queries

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

- ASN lookups use ``SwiftFTR/SwiftFTRConfig/asnResolverStrategy``, which defaults to
  `.hybrid(.embedded)`: the embedded SwiftIP2ASN database answers first, and Team Cymru DNS is
  consulted only for addresses it does not cover. Pass `.embedded` for no network at all, or `.dns`
  for DNS-only lookups. Call ``SwiftFTR/SwiftFTR/preloadASNDatabase()`` early to move the one-time
  database load off the first classified trace.
- Pass a custom ``SwiftFTR/ASNResolver`` to
  ``SwiftFTR/SwiftFTR/traceClassified(to:vpnContext:resolver:)`` for offline or deterministic
  lookups.
- Set ``SwiftFTR/SwiftFTRConfig/publicIP`` when creating ``SwiftFTR/SwiftFTRConfig`` to override
  public-address discovery for classified trace and multipath enrichment for the lifetime of the
  tracer. Standalone public-IP discovery APIs ignore this value. To supply a known address that a
  later network change should discard, use ``SwiftFTR/SwiftFTR/seedPublicIP(_:source:)`` instead.
- Override `maxHops` for a single trace with ``SwiftFTR/TraceOptions`` via
  ``SwiftFTR/SwiftFTR/trace(to:options:)`` or
  ``SwiftFTR/SwiftFTR/traceClassified(to:vpnContext:resolver:options:)``.

## Reacting to Network Changes

``SwiftFTR/SwiftFTR/networkChanged()`` cancels active traces and clears the cached public IP and
the reverse-DNS cache. ASN results are not network-scoped and are kept. When only part of the
network state changed, call the individual controls instead:

- ``SwiftFTR/SwiftFTR/cancelActiveTraces()`` cancels in-flight traces and keeps all caches.
- ``SwiftFTR/SwiftFTR/invalidateNetworkScopedRDNS()`` evicts only reverse-DNS entries for
  non-global addresses and resets the reverse-DNS stall breaker.
- ``SwiftFTR/SwiftFTR/invalidatePublicIP()`` clears the cached public IP without changing a
  configured ``SwiftFTR/SwiftFTRConfig/publicIP`` override;
  ``SwiftFTR/SwiftFTR/clearCaches()`` clears the public IP and the reverse-DNS cache.
- ``SwiftFTR/SwiftFTR/seedPublicIP(_:source:)`` caches an address that passes the
  library's special-range checks (which do not prove global routability) for the current cache
  generation, with a ``SwiftFTR/PublicIPSource``.

## Topics

### Migration Guides

- <doc:MigratingTo018>
- <doc:MigratingTo014>

### Traceroute APIs

- ``SwiftFTR/SwiftFTR``
- ``SwiftFTR/TraceResult``
- ``SwiftFTR/TraceHop``
- ``SwiftFTR/TraceOptions``
- ``SwiftFTR/HopOutcome``
- ``SwiftFTR/ICMPUnreachableReason``
- ``SwiftFTR/TraceHandle``
- ``SwiftFTR/TracerouteError``
- <doc:Tracing>

### Classification

- ``SwiftFTR/TraceClassifier``
- ``SwiftFTR/ClassifiedTrace``
- ``SwiftFTR/ClassifiedHop``
- ``SwiftFTR/HopCategory``
- ``SwiftFTR/VPNContext``

### Streaming Traceroute

- ``SwiftFTR/StreamingHop``
- ``SwiftFTR/StreamingTraceConfig``
- <doc:StreamingTrace>

### Ping APIs

- ``SwiftFTR/PingConfig``
- ``SwiftFTR/PingResult``
- ``SwiftFTR/PingResponse``
- ``SwiftFTR/PingStatistics``
- ``SwiftFTR/PreferredFamily``
- <doc:Ping>

### Network Probing

- ``tcpProbe(config:)``
- ``udpProbe(config:)``
- ``httpProbe(config:)``
- ``dnsProbe(config:)``
- ``SwiftFTR/TCPProbeConfig``
- ``SwiftFTR/TCPProbeResult``
- ``SwiftFTR/TCPConnectionState``
- ``SwiftFTR/UDPProbeConfig``
- ``SwiftFTR/UDPProbeResult``
- ``SwiftFTR/HTTPProbeConfig``
- ``SwiftFTR/HTTPProbeResult``
- ``SwiftFTR/DNSProbeConfig``
- ``SwiftFTR/DNSProbeResult``
- <doc:Probing>

### Bufferbloat & Responsiveness

- ``SwiftFTR/BufferbloatConfig``
- ``SwiftFTR/BufferbloatResult``
- ``SwiftFTR/BufferbloatGrade``
- ``SwiftFTR/LatencyMeasurements``
- ``SwiftFTR/LatencyIncrease``
- ``SwiftFTR/BufferbloatPingResult``
- ``SwiftFTR/TestPhase``
- ``SwiftFTR/LoadGenerationDetails``
- ``SwiftFTR/LoadType``
- ``SwiftFTR/RPMScore``
- ``SwiftFTR/RPMGrade``
- ``SwiftFTR/VideoCallImpact``
- ``SwiftFTR/VideoCallSeverity``
- <doc:Bufferbloat>

### Multipath Discovery

- ``SwiftFTR/MultipathConfig``
- ``SwiftFTR/NetworkTopology``
- ``SwiftFTR/DiscoveredPath``
- ``SwiftFTR/FlowIdentifier``
- <doc:Multipath>

### DNS Queries

- ``SwiftFTR/DNSQueries``
- ``SwiftFTR/DNSQueryResult``
- ``SwiftFTR/DNSRecord``
- ``SwiftFTR/DNSRecordType``
- ``SwiftFTR/DNSRecordData``
- ``SwiftFTR/DNSError``
- ``SwiftFTR/ReverseDNSResult``
- ``SwiftFTR/AQueryResult``
- ``SwiftFTR/AAAAQueryResult``

### Public IP Discovery

- ``getPublicIPs(stunTimeout:interface:sourceIP:enableLogging:)``
- ``SwiftFTR/PublicIPs``
- ``SwiftFTR/PublicIPSource``
- ``SwiftFTR/PublicIPError``

### ASN Resolution

- ``SwiftFTR/ASNInfo``
- ``SwiftFTR/ASNResolverStrategy``
- ``SwiftFTR/LocalASNSource``
- ``SwiftFTR/ASNResolver``
- ``SwiftFTR/HybridASNResolver``
- ``SwiftFTR/LocalASNResolver``
- ``SwiftFTR/CachingASNResolver``
- ``SwiftFTR/CymruDNSResolver``

### Network Interfaces

- ``SwiftFTR/NetworkInterfaceDiscovery``
- ``SwiftFTR/NetworkInterface``
- ``SwiftFTR/NetworkInterfaceSnapshot``
- ``SwiftFTR/InterfaceType``
- <doc:InterfaceBinding>

### Configuration

- ``SwiftFTR/SwiftFTRConfig``
