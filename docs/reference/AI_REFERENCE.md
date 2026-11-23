# SwiftFTR API Reference for AI Agents

A condensed, code-checked reference to SwiftFTR's public API, meant to be loaded whole into an
agent's context. The DocC catalog (`Sources/SwiftFTR/SwiftFTR.docc`) and the doc comments in
`Sources/SwiftFTR` are authoritative; worked examples live in
[docs/guides/EXAMPLES.md](../guides/EXAMPLES.md).

## Overview

SwiftFTR is a Swift library for fast, parallel traceroute on macOS without sudo. It uses
unprivileged ICMP datagram sockets (`SOCK_DGRAM` with `IPPROTO_ICMP` / `IPPROTO_ICMPV6`), sends
every TTL probe in one burst, and waits once. On top of that it provides ASN-based hop
classification, reverse DNS, streaming traceroute, ping, TCP/UDP/HTTP/DNS probes, ECMP multipath
discovery, bufferbloat testing, and network-interface discovery.

## Core Requirements

- **Platform**: macOS 13+
- **Toolchain**: Swift 6.1+ / Xcode 16.4+ (package uses swift-tools-version 6.0, Swift 6 language mode)
- **Permissions**: No sudo or entitlements; datagram ICMP sockets only
- **Concurrency**: `SwiftFTR` is an `actor`; all public types are `Sendable`; nothing requires `@MainActor`
- **Address families**: IPv4 and IPv6 for trace, streaming trace, ping, TCP/UDP probes and DNS.
  Multipath discovery is IPv4 only.
- **Dependencies**: `swift-ip2asn` (SwiftIP2ASN, `from: "0.5.2"`) for the embedded ASN database,
  `swift-argument-parser` for the CLI, `swift-docc-plugin` for documentation

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/Network-Weather/SwiftFTR.git", from: "0.18.1")
]
```

The library exposes `swiftFTRVersion` (a `String`, currently `"0.18.1"`).

## Primary Types

### 1. SwiftFTR (main actor)

```swift
@available(macOS 13.0, *)
public actor SwiftFTR {
    public init(config: SwiftFTRConfig = SwiftFTRConfig())

    // Traceroute
    public func trace(to host: String) async throws -> TraceResult
    public func trace(to host: String, options: TraceOptions) async throws -> TraceResult
    public func traceClassified(
        to host: String,
        vpnContext: VPNContext? = nil,
        resolver: ASNResolver? = nil
    ) async throws -> ClassifiedTrace
    public func traceClassified(
        to host: String,
        vpnContext: VPNContext? = nil,
        resolver: ASNResolver? = nil,
        options: TraceOptions
    ) async throws -> ClassifiedTrace
    public nonisolated func traceStream(
        to host: String,
        config: StreamingTraceConfig = .default
    ) -> AsyncThrowingStream<StreamingHop, Error>

    // Other measurements
    public nonisolated func ping(to target: String, config: PingConfig = PingConfig()) async throws -> PingResult
    public func discoverPaths(to target: String, config: MultipathConfig = MultipathConfig()) async throws -> NetworkTopology
    public func testBufferbloat(config: BufferbloatConfig = BufferbloatConfig()) async throws -> BufferbloatResult
    public nonisolated var dns: DNSQueries { get }

    // Discovery
    public nonisolated func discoverInterfaces() async -> NetworkInterfaceSnapshot
    public func discoverPublicIPWithHostname() async throws -> (ip: String, hostname: String?)
    public func preloadASNDatabase() async

    // Network-transition lifecycle and caches
    public func networkChanged() async            // cancel operations + clear public IP + clear rDNS
    public func cancelActiveTraces() async        // cancel only; caches preserved
    public func invalidateNetworkScopedRDNS() async  // evict non-global rDNS entries only
    @discardableResult
    public func seedPublicIP(_ address: String, source: PublicIPSource) -> Bool
    public func invalidatePublicIP()
    public func clearCaches() async               // public IP + rDNS
    public var publicIP: String? { get }          // configured override, else cached value
}
```

Notes:
- `ping(to:config:)` is `nonisolated` (and `@concurrent` on Swift 6.2+ compilers), so concurrent
  pings from one instance run in parallel, each on its own socket.
- `networkChanged()` and `cancelActiveTraces()` end every `trace`, `traceClassified`,
  `traceStream` and `discoverPaths` in flight with `TracerouteError.cancelled`. For `trace`,
  `traceClassified` and `discoverPaths` that holds even if the caller cancelled too; a stream
  throws it only if the tracer ends the stream first, and otherwise a consumer that cancelled sees
  iteration end normally. `ping` and the probe functions are not tied to the tracer and keep
  running.
- `networkChanged()` does not clear the ASN cache; ASN data is not network-scoped.
- `seedPublicIP` accepts only syntactically valid, globally routable IPv4/IPv6 addresses and
  returns `false` otherwise (private, CGNAT, link-local, loopback, multicast, documentation and
  benchmark ranges, IPv6 outside `2000::/3` other than `64:ff9b::/96` (including site-local
  `fec0::/10`), a `64:ff9b::/96` address embedding a rejected IPv4 address, zone-suffixed strings
  and strings containing a NUL are rejected). Every address and destination string the library
  parses is rejected if it contains a NUL: as an address it is invalid, as a destination it throws
  `TracerouteError.resolutionFailed`. A seed is discarded by the next `invalidatePublicIP()`,
  `clearCaches()` or `networkChanged()`. `PublicIPSource` has cases `.validatedCallerCache` and
  `.gatewayReported`; the library does not retain the source.
- `discoverPublicIPWithHostname()` discovers IPv4 via STUN through the configured interface, with
  an unbound DNS fallback, and ignores `SwiftFTRConfig.publicIP`.

### 2. SwiftFTRConfig

```swift
public struct SwiftFTRConfig: Sendable {
    public static let defaultPublicIPDiscoveryTimeout: TimeInterval  // 6.0
    public static let defaultRDNSLookupTimeout: TimeInterval         // 5.0

    public let maxHops: Int                       // default 40
    public let maxWaitMs: Int                     // default 1000; receive window after the send burst
    public let payloadSize: Int                   // default 56
    public let publicIP: String?                  // permanent override for classified/multipath enrichment
    public let enableLogging: Bool                // default false
    public let noReverseDNS: Bool                 // default false
    public let rdnsCacheTTL: TimeInterval?        // nil = 86400 s
    public let rdnsCacheSize: Int?                // nil = 1000 entries
    public let rdnsLookupTimeout: TimeInterval?   // nil or invalid = 5 s per lookup (lookups run concurrently)
    public let publicIPDiscoveryTimeout: TimeInterval?  // nil or invalid = 6 s per attempt
    public let interface: String?                 // BSD name, e.g. from NetworkInterfaceDiscovery
    public let sourceIP: String?                  // must be assigned to the interface; family must match destination
    public let asnResolverStrategy: ASNResolverStrategy  // default .hybrid(.embedded)
    public let preferredFamily: PreferredFamily   // default .auto

    public init(
        maxHops: Int = 40,
        maxWaitMs: Int = 1000,
        payloadSize: Int = 56,
        publicIP: String? = nil,
        enableLogging: Bool = false,
        noReverseDNS: Bool = false,
        rdnsCacheTTL: TimeInterval? = nil,
        rdnsCacheSize: Int? = nil,
        rdnsLookupTimeout: TimeInterval? = nil,
        publicIPDiscoveryTimeout: TimeInterval? = nil,
        interface: String? = nil,
        sourceIP: String? = nil,
        asnResolverStrategy: ASNResolverStrategy = .hybrid(.embedded),
        preferredFamily: PreferredFamily = .auto
    )
}
```

Arguments must be passed in declaration order. Values are validated when an operation starts:
`maxHops` outside 1...255, `maxWaitMs` below 1, `payloadSize` outside 0...65507, a negative or
non-finite `rdnsCacheTTL`, a negative `rdnsCacheSize`, or a non-positive hybrid `fallbackTimeout`
throws `TracerouteError.invalidConfiguration(reason:)`. The two enrichment budgets never throw: a
`rdnsLookupTimeout` or `publicIPDiscoveryTimeout` that is zero, negative, non-finite or out of
range is replaced by its default (5 s and 6 s respectively). `interface`, `sourceIP` and `publicIP`
are fixed per instance, so a host that needs several binding contexts holds several
`SwiftFTR` instances. `maxHops` is the instance default; `TraceOptions(maxHops:)` overrides it for one call. Each instance owns its rDNS cache, cached public IP and active traces; the
DNS-based ASN cache is shared process-wide, and a loaded ASN database is shared by
every live resolver for the same source.

### 3. TraceOptions

```swift
public struct TraceOptions: Sendable, Equatable {
    public var maxHops: Int?   // nil = config.maxHops; otherwise 1...255
    public init(maxHops: Int? = nil)
}
```

### 4. PreferredFamily

```swift
public enum PreferredFamily: Sendable, Codable {
    case auto   // names and literals both go through getaddrinfo; the first answer is probed
    case v4     // IPv4 literal used as is; IPv6 literal or no IPv4 address throws resolutionFailed
    case v6     // IPv6 literal used as is; IPv4 literal or no IPv6 address throws resolutionFailed
}
```

`.auto` does not force a literal's family. On an IPv6-only NAT64 network the system resolver
synthesizes an IPv6 address for an IPv4 literal, so tracing `1.1.1.1` can probe, and report in
`resolvedIP`, an IPv6 address. On dual-stack networks an IPv4 literal comes back unchanged. Use
`.v4` or `.v6` to pin the family.

### 5. TraceResult and TraceHop

```swift
public struct TraceResult: Sendable {
    public let destination: String     // as provided by the caller
    public let resolvedIP: String?     // numeric address actually probed (nil only for hand-built results)
    public let maxHops: Int
    public let reached: Bool
    public let hops: [TraceHop]        // TTL 1 up to the destination's TTL, or maxHops if not reached
    public let duration: TimeInterval  // seconds
}

public struct TraceHop: Sendable {
    public let ttl: Int                // 1-based
    public let ipAddress: String?      // canonical inet_ntop form; link-local keeps its %zone suffix
    public let rtt: TimeInterval?      // seconds
    public let reachedDestination: Bool
    public let hostname: String?       // rDNS, when enabled and successful
    public let outcome: HopOutcome     // authoritative; the other fields are consistent with it

    public init(ttl: Int, ipAddress: String?, rtt: TimeInterval?, reachedDestination: Bool,
                hostname: String? = nil)                          // infers .replied / .timedOut
    public init(ttl: Int, ipAddress: String?, rtt: TimeInterval?, reachedDestination: Bool,
                hostname: String? = nil, outcome: HopOutcome)
}
```

### 6. HopOutcome and ICMPUnreachableReason

```swift
public enum HopOutcome: Sendable, Equatable, Codable {
    case notSent(errno: Int32)    // probe never left the host (transient send pressure)
    case timedOut                 // sent, no answer before the deadline
    case unreachable(code: UInt8) // ICMP Destination Unreachable; address and RTT are set
    case replied                  // Time Exceeded, or Echo Reply from the destination

    public var didReceiveReply: Bool { get }                    // true for .unreachable, .replied
    public var unreachableReason: ICMPUnreachableReason? { get } // IPv4 code table lookup for .unreachable
}

public enum ICMPUnreachableReason: UInt8, Sendable, CaseIterable {
    case network, host, protocolUnreachable, port, fragmentationNeeded, sourceRouteFailed,
         networkUnknown, hostUnknown, sourceHostIsolated, networkProhibited, hostProhibited,
         networkUnreachableForTOS, hostUnreachableForTOS, administrativelyProhibited  // codes 0...13
    public var displayName: String { get }
    public var isAdministrative: Bool { get }  // networkProhibited, hostProhibited, administrativelyProhibited
}
```

`.unreachable(code:)` carries the code exactly as received: an ICMP code on an IPv4 trace, an
ICMPv6 code on an IPv6 trace. `ICMPUnreachableReason` names the IPv4 codes only, so
`unreachableReason` is meaningful only when the trace's `resolvedIP` is IPv4; on an IPv6 trace,
read the numeric code.

The trace socket is non-blocking. When a send hits transient buffer pressure (`EAGAIN`,
`EWOULDBLOCK` or `ENOBUFS`) the burst retries it within a shared 250 ms budget; a probe still
unsent when that budget runs out is reported as `.notSent` and the trace continues. If every probe
failed that way, the trace throws `sendFailed` instead. Any other send error (for example
`ENETDOWN` or `EHOSTUNREACH`) aborts the trace immediately with `sendFailed(errno:)`, even if
earlier TTLs were already sent.

### 7. ClassifiedTrace and ClassifiedHop

```swift
public struct ClassifiedTrace: Sendable, Codable {
    public let destinationHost: String
    public let destinationIP: String
    public let destinationHostname: String?
    public let publicIP: String?
    public let publicHostname: String?
    public let clientASN: Int?
    public let clientASName: String?
    public let destinationASN: Int?
    public let destinationASName: String?
    public let hops: [ClassifiedHop]
}

public struct ClassifiedHop: Sendable, Codable {
    public let ttl: Int
    public let ip: String?
    public let rtt: TimeInterval?
    public let asn: Int?
    public let asName: String?
    public let category: HopCategory
    public let hostname: String?
    public let outcome: HopOutcome
    // init(ttl:ip:rtt:asn:asName:category:hostname:) infers outcome;
    // init(ttl:ip:rtt:asn:asName:category:hostname:outcome:) takes it explicitly.
}
```

`traceClassified` gets the client's public IP from `config.publicIP`, then the actor cache (which
`seedPublicIP` populates), then fresh IPv4 discovery (STUN, then a DNS TXT query to
`whoami.ds.akahelp.net`). Each discovery attempt is bounded by `publicIPDiscoveryTimeout`, and
there can be two: one before the trace, and, if that one finds no address, a second during
classification. With an empty cache and stalled discovery, a classified trace can therefore spend
up to twice `publicIPDiscoveryTimeout` on public-IP discovery. If both fail or time out,
classification proceeds without a public IP.

### 8. HopCategory

```swift
public enum HopCategory: String, Sendable, Codable {   // not CaseIterable
    case local = "LOCAL"
    case isp = "ISP"
    case transit = "TRANSIT"
    case destination = "DESTINATION"
    case unknown = "UNKNOWN"
    case vpn = "VPN"
}
```

How the classifier assigns categories (`Sources/SwiftFTR/Segmentation.swift`), checked in this
order for each hop with an address:

1. **Exact matches**: a hop whose address equals the destination IP is DESTINATION; one that is
   among the effective VPN context's `vpnLocalIPs` is VPN. These win over every rule below.
2. **Non-VPN trace**:
   - private, link-local, loopback, multicast and unspecified addresses are LOCAL before the
     first public hop and ISP after it. Reserved documentation ranges such as 203.0.113.0/24
     count as public here, although public-IP validation rejects them;
   - CGNAT (100.64.0.0/10) is ISP;
   - a public address whose ASN equals the client's ASN (from the public IP) is ISP; this is
     checked before the destination ASN, so when client and destination share an ASN, an
     intermediate public hop in it is ISP;
   - otherwise a public address whose ASN equals the destination's ASN is DESTINATION;
   - any other public address, or one with no ASN data, is TRANSIT.
3. **VPN trace**: the effective context is the `VPNContext` passed to the call, or, when none is
   passed, one derived from the configured `interface` (a VPN trace when its name starts with
   `utun`, `ipsec`, `ppp`, `tun`, `tap`, `wg`, `gpd` or `ztun`). An explicit context is used as
   given, so `VPNContext(isVPNTrace: false)` on a `utun` interface is a non-VPN trace. When the
   effective context says VPN:
   - private, link-local, loopback, multicast, unspecified and CGNAT addresses are VPN;
   - a public address whose ASN equals the destination's ASN is DESTINATION;
   - every other public address is TRANSIT, including one in the client's ASN: the client ASN
     does not produce ISP on a VPN trace.

Hops with no address are UNKNOWN. A run of them between two hops of the same category takes that
category (and the ASN, if both sides share it).

### 9. VPNContext

```swift
public struct VPNContext: Sendable {
    public let traceInterface: String?
    public let isVPNTrace: Bool
    public let vpnLocalIPs: Set<String>
    public init(traceInterface: String? = nil, isVPNTrace: Bool = false, vpnLocalIPs: Set<String> = [])
    public static func forInterface(_ name: String?) -> VPNContext
}
```

### 10. TracerouteError

```swift
public enum TracerouteError: Error, CustomStringConvertible {
    case resolutionFailed(host: String, details: String?)
    case socketCreateFailed(errno: Int32, details: String)
    case setsockoptFailed(option: String, errno: Int32)
    case interfaceBindFailed(interface: String, errno: Int32, details: String?)
    case sourceIPBindFailed(sourceIP: String, errno: Int32, details: String?)
    case sendFailed(errno: Int32)
    case invalidConfiguration(reason: String)
    case platformNotSupported(details: String)
    case cancelled
}
```

The same cases cover IPv4 and IPv6. DNS APIs throw `DNSError` instead (see below).

### 11. ASN resolution

```swift
public enum ASNResolverStrategy: Sendable {
    case dns                                                    // Team Cymru DNS, cached in memory
    case embedded                                               // SwiftIP2ASN database only; no network
    case remote(bundledPath: String? = nil, url: URL? = nil)    // remote database, optional bundled fallback
    case hybrid(LocalASNSource, fallbackTimeout: TimeInterval = 1.0)  // local first, DNS for misses (default: .hybrid(.embedded))
}

public enum LocalASNSource: Sendable {
    case embedded
    case bundled(String)                                 // path to an app-provided .ultra file
    case remote(bundledPath: String?, url: URL?)
}

public protocol ASNResolver: Sendable {
    func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo]
}

public struct ASNInfo: Sendable, Hashable, Codable {
    public let asn: Int
    public let name: String
    public let prefix: String?
    public let countryCode: String?
    public let registry: String?
    public init(asn: Int, name: String, prefix: String? = nil, countryCode: String? = nil, registry: String? = nil)
}

public struct CymruDNSResolver: ASNResolver {            // origin.asn.cymru.com / origin6.asn.cymru.com TXT
    public init()
    public func resolve(ipv4Addrs: [String], timeout: TimeInterval = 1.0) async throws -> [String: ASNInfo]
}
public struct CachingASNResolver: ASNResolver { public init(base: ASNResolver) }
public actor LocalASNResolver: ASNResolver { public init(source: LocalASNSource = .embedded); public func preload() async }
public struct HybridASNResolver: ASNResolver {
    public init(source: LocalASNSource, fallbackTimeout: TimeInterval = 1.0)
    public func preload() async
}
```

Despite the parameter name `ipv4Addrs`, the built-in resolvers accept IPv6 strings too; only
globally routable addresses get ASN data. Resolvers for the same local source that are alive at
the same time share one loaded copy of the database: about 15 MB, with first-load process
footprint around 50 MB. The process-wide store holds that copy weakly, so it is released when the
last resolver using it goes away, and the next resolver loads it again. Call `preloadASNDatabase()`
early to move the load off the first classified trace, and keep that tracer alive for as long as
the database should stay resident. A
`resolver:` passed to `traceClassified` overrides the configured strategy for that call.

### 12. StreamingTraceConfig and StreamingHop

```swift
public struct StreamingTraceConfig: Sendable {
    public let probeTimeout: TimeInterval    // default 10.0
    public let retryAfter: TimeInterval?     // default 4.0; nil disables re-probing
    public let emitTimeouts: Bool            // default true: placeholders for silent TTLs at the end
    public let maxHops: Int                  // default 40
    public init(probeTimeout: TimeInterval = 10.0, retryAfter: TimeInterval? = 4.0,
                emitTimeouts: Bool = true, maxHops: Int = 40)
    public static let `default`: StreamingTraceConfig
}

public struct StreamingHop: Sendable, Equatable {
    public let ttl: Int
    public let ipAddress: String?
    public let rtt: TimeInterval?
    public let reachedDestination: Bool
    public let outcome: HopOutcome
}
```

Hops arrive in arrival order, not TTL order; streaming hops carry no rDNS or ASN data. The trace is
cancelled when the stream terminates: when the task iterating it is cancelled, or when the stream
and its iterator are released. Breaking out of a `for try await` loop over
`tracer.traceStream(...)` written inline releases the stream and so stops the trace. Breaking out
of a loop over a stream held in a variable does not: the producer keeps its socket open and keeps
re-probing until the stream finishes or is released. To stop a trace explicitly, cancel the
consuming task or call `cancelActiveTraces()`.

### 13. Ping

```swift
public struct PingConfig: Sendable {
    public init(count: Int = 5, interval: TimeInterval = 1.0, timeout: TimeInterval = 2.0,
                payloadSize: Int = 56, interface: String? = nil, sourceIP: String? = nil,
                preferredFamily: PreferredFamily = .auto)
    // timeout: reply window after the last request; an earlier request's reply counts until then.
    // Only the first reply to each request sent counts; strays and duplicates are ignored.
}
public struct PingResult: Sendable, Codable {
    public let target: String
    public let resolvedIP: String
    public let responses: [PingResponse]
    public let statistics: PingStatistics
}
public struct PingResponse: Sendable, Codable {
    public let sequence: Int
    public let rtt: TimeInterval?
    public let ttl: Int?              // IPv4 TTL or IPv6 hop limit
    public let timestamp: Date
    public var didTimeout: Bool { get }
}
public struct PingStatistics: Sendable, Codable {
    public let sent: Int
    public let received: Int
    public let packetLoss: Double     // 0.0...1.0
    public let minRTT, avgRTT, maxRTT, jitter: TimeInterval?
}
```

### 14. Probes (free functions)

```swift
public func tcpProbe(host: String, port: Int, timeout: TimeInterval = 2.0) async throws -> TCPProbeResult
public func tcpProbe(config: TCPProbeConfig) async throws -> TCPProbeResult
// TCPProbeConfig(host:port:timeout:interface:sourceIP:preferredFamily:)
// TCPProbeResult: host, resolvedIP, port, isReachable, connectionState, rtt, error, timestamp
// TCPConnectionState: .open, .closed, .filtered, .error

public func udpProbe(host: String, port: Int, timeout: TimeInterval = 2.0, payload: Data = Data()) async throws -> UDPProbeResult
public func udpProbe(config: UDPProbeConfig) async throws -> UDPProbeResult
// UDPProbeResult: host, resolvedIP, port, isReachable, rtt,
//   responseType ("udp_reply", "icmp_port_unreachable", "timeout"), error, timestamp

public func httpProbe(url: String, timeout: TimeInterval = 2.0) async throws -> HTTPProbeResult
public func httpProbe(config: HTTPProbeConfig) async throws -> HTTPProbeResult
// HTTPProbeConfig(url:timeout:followRedirects:)  (no interface binding; uses URLSession)
// HTTPProbeResult: url, isReachable, statusCode, rtt, networkRTT, tcpHandshakeRTT, error, timestamp
// Headers then a stalled body: reported at the timeout as isReachable == true, error starting
//   "Timeout: ", rtt to the first response byte, statusCode only if body bytes followed the
//   headers (URLSession withholds the response until then). No response byte: "Timeout", unreachable.

public func dnsProbe(server: String, query: String = "example.com", timeout: TimeInterval = 2.0) async throws -> DNSProbeResult
public func dnsProbe(config: DNSProbeConfig) async throws -> DNSProbeResult
// DNSProbeResult: server, query, outcome, isReachable, rtt (send to reply; set when reachable),
//   elapsed, responseCode, error, timestamp
//   isReachable: any DNS answer (responseCode set, NXDOMAIN included), or responseCode nil with
//   error for a malformed reply; false for silence, a refused port and local errors
//   A reply missing question or answer records its header declares is malformed whatever its
//   RCODE (checked before the RCODE); authority and additional sections are not checked
//   Only a datagram carrying the query's transaction ID, and not echoing another question
//   (name compared case-insensitively, type, class), is a reply; others (wrong ID, another
//   question, under 2 bytes, empty) are ignored until the timeout, so only such datagrams ->
//   .timedOut. A reply with no question section (QDCOUNT 0) is still a reply
//   outcome: DNSProbeOutcome, a struct with static members (switch needs `default`):
//     .answered, .refused, .timedOut, .malformedReply, .unreachable, .failed; JSON: raw string
//   elapsed: send to whatever came back from the network; nil when nothing did (timedOut,
//     failed, and unreachable from connect/send: EHOSTUNREACH, EHOSTDOWN, ENETUNREACH, ENETDOWN)
//   init without outcome/elapsed, and JSON without "outcome", derive both from the other fields
//   Throws CancellationError when the calling task is cancelled
//   switch r.outcome { case .refused: ...; case .timedOut: ...; default: ... }
```

### 15. DNS

```swift
public struct DNSQueries: Sendable {          // via tracer.dns
    // server nil = "8.8.8.8"; timeout nil = 3.0 s;
    // interface/sourceIP nil = the tracer's config values
    public func a(hostname: String, server: String? = nil, timeout: TimeInterval? = nil,
                  interface: String? = nil, sourceIP: String? = nil) async throws -> DNSQueryResult
    public func aaaa(hostname:server:timeout:interface:sourceIP:) async throws -> DNSQueryResult
    public func reverseIPv4(ip:server:timeout:interface:sourceIP:) async throws -> DNSQueryResult
    public func reverseIPv6(ip:server:timeout:interface:sourceIP:) async throws -> DNSQueryResult
    public func txt(hostname:server:timeout:interface:sourceIP:) async throws -> DNSQueryResult
    public func query(name: String, type: DNSRecordType, server: String? = nil, timeout: TimeInterval? = nil,
                      interface: String? = nil, sourceIP: String? = nil) async throws -> DNSQueryResult
}

public struct DNSQueryResult: Sendable { query, queryType, server, records: [DNSRecord], rttMs: Double, timestamp }
public struct DNSRecord: Sendable { name, type: DNSRecordType, recordClass, ttl: UInt32, data: DNSRecordData }
public enum DNSRecordType: UInt16, Sendable {   // raw values are the DNS wire type codes
    case a = 1, ns = 2, cname = 5, soa = 6, ptr = 12, mx = 15, txt = 16, aaaa = 28, srv = 33,
         https = 65, caa = 257
}
public enum DNSRecordData: Sendable {
    case ipv4(String), ipv6(String), hostname(String)          // hostname: PTR, NS, CNAME
    case mx(priority: UInt16, exchange: String)
    case txt([String])
    case srv(priority: UInt16, weight: UInt16, port: UInt16, target: String)
    case soa(primaryNS: String, adminEmail: String, serial: UInt32, refresh: UInt32, retry: UInt32,
             expire: UInt32, minimumTTL: UInt32)
    case caa(flags: UInt8, tag: String, value: String)
    case https(priority: UInt16, target: String, svcParams: Data)
    case raw(Data)
}

public enum DNSError: Error, Sendable {
    case invalidIP(String), invalidHostname(String), invalidTimeout(TimeInterval)
    case socketCreationFailed, setsockoptFailed(option: String, errno: Int32), bindFailed(String)
    case sendFailed, timeout, malformedResponse, noRecords, serverError(rcode: Int)
}
// malformedResponse: a datagram with the query's transaction ID that is not valid DNS. One with
// another ID, too short to carry one, or echoing another question (another name, type or class;
// the name compared case-insensitively) is ignored; only such datagrams end as timeout.

// Standalone functions with an explicit server:
public func reverseDNS(ip: String, server: String, timeout: TimeInterval = 2.0,
                       interface: String? = nil, sourceIP: String? = nil) async throws -> ReverseDNSResult
public func reverseIPv6(ip:server:timeout:interface:sourceIP:) async throws -> ReverseDNSResult
public func queryA(hostname: String, server: String, timeout: TimeInterval = 2.0,
                   interface: String? = nil, sourceIP: String? = nil) async throws -> AQueryResult
public func queryAAAA(hostname:server:timeout:interface:sourceIP:) async throws -> AAAAQueryResult
// ReverseDNSResult: ip, server, hostname?, rtt, timestamp
// AQueryResult / AAAAQueryResult: hostname, server, addresses: [String], rtt, timestamp
```

`reverseIPv6` exists both as a `DNSQueries` method (returns `DNSQueryResult`) and as a free
function with a required `server:` (returns `ReverseDNSResult`). The one-argument
`reverseDNS(_:)` below is a different, system-resolver function.

### 16. Multipath

```swift
public struct MultipathConfig: Sendable {
    public init(flowVariations: Int = 8, maxPaths: Int = 16, earlyStopThreshold: Int = 3,
                timeoutMs: Int = 2000, maxHops: Int = 40)
}
public struct NetworkTopology: Sendable, Codable {
    public let destination: String
    public let destinationIP: String
    public let sourceAdapter: String?
    public let sourceIP: String?
    public let publicIP: String?
    public let paths: [DiscoveredPath]
    public let uniquePathCount: Int
    public let discoveryDuration: TimeInterval
    public func uniqueHops() -> [ClassifiedHop]
    public func divergencePoint() -> Int?
    public func commonPrefix() -> [ClassifiedHop]
    public func paths(throughIP ip: String) -> [DiscoveredPath]
    public func paths(throughASN asn: Int) -> [DiscoveredPath]
}
public struct DiscoveredPath: Sendable, Codable {
    public let flowIdentifier: FlowIdentifier   // icmpID: UInt16, variation: Int
    public let trace: ClassifiedTrace
    public let fingerprint: String
    public let isUnique: Bool
}
```

Multipath varies the ICMP identifier, so it can find fewer paths than UDP-based tools whose
probes are hashed on ports. IPv4 destinations and source addresses only; an IPv6 preference or
source throws `invalidConfiguration`.

### 17. Bufferbloat

```swift
public struct BufferbloatConfig: Sendable {
    public init(target: String = "1.1.1.1", baselineDuration: TimeInterval = 5.0,
                loadDuration: TimeInterval = 10.0, loadType: LoadType = .bidirectional,
                parallelStreams: Int = 4, pingInterval: TimeInterval = 0.1, calculateRPM: Bool = true,
                uploadURL: String? = nil, downloadURL: String? = nil,
                interface: String? = nil, sourceIP: String? = nil)
}
public enum LoadType: String, Sendable, Codable {   // raw and Codable values are capitalized
    case upload = "Upload", download = "Download", bidirectional = "Bidirectional"
}
public struct BufferbloatResult: Sendable, Codable {
    target, loadType, baseline: LatencyMeasurements, loaded: LatencyMeasurements,
    latencyIncrease: LatencyIncrease, rpm: RPMScore?, grade: BufferbloatGrade,
    videoCallImpact: VideoCallImpact, pingResults: [BufferbloatPingResult], loadDetails: LoadGenerationDetails
}
// LatencyMeasurements: sampleCount, minMs, avgMs, maxMs, p50Ms, p95Ms, p99Ms, jitterMs
// LatencyIncrease: absoluteMs, percentageIncrease, p99IncreaseMs
// RPMScore: workingRPM, idleRPM, grade: RPMGrade (.poor, .fair, .good, .excellent)
// BufferbloatGrade (Comparable): .a, .b, .c, .d, .f
// VideoCallImpact: impactsVideoCalls, severity (.none, .minor, .moderate, .severe), description
// TestPhase: .baseline, .rampUp, .sustained, .rampDown
```

`loadDuration: 0` gives a baseline-only measurement; only `baseline` is meaningful then. A loaded
test with an interface or source-IP binding (per-operation or global) throws, because URLSession
cannot bind the load traffic to that route.

### 18. Network interfaces

```swift
public actor NetworkInterfaceDiscovery {
    public init()
    public func discover() -> NetworkInterfaceSnapshot
    public static func isVPNInterface(_ name: String) -> Bool
    public static func classifyInterface(_ name: String) -> InterfaceType
}
public struct NetworkInterfaceSnapshot: Sendable, Codable {
    public let interfaces: [NetworkInterface]
    public let timestamp: Date
    public var physicalInterfaces: [NetworkInterface] { get }
    public var vpnInterfaces: [NetworkInterface] { get }
    public var activeInterfaces: [NetworkInterface] { get }
    public func interface(named name: String) -> NetworkInterface?
}
public struct NetworkInterface: Sendable, Codable, Identifiable {
    name, type: InterfaceType, ipv4Addresses: [String], ipv6Addresses: [String], isUp, isPointToPoint, mtu: Int?
}
public enum InterfaceType: String { case wifi, ethernet, vpnTunnel, vpnIPSec, vpnPPP, bridge, loopback, other }
```

### 19. Public IP discovery and utilities

```swift
public struct PublicIPs: Sendable {
    public let v4: String?
    public let v6: String?
    public var any: String? { get }   // v6 ?? v4
}
// STUN-only, both families in parallel; failed families are nil. Ignores SwiftFTRConfig.publicIP.
public func getPublicIPs(stunTimeout: TimeInterval = 0.8, interface: String? = nil,
                         sourceIP: String? = nil, enableLogging: Bool = false) async -> PublicIPs

public func isPrivateIPv4(_ ip: String) -> Bool   // RFC 1918 or 169.254/16; strict parsing
public func isCGNATIPv4(_ ip: String) -> Bool     // 100.64.0.0/10; strict parsing
public func reverseDNS(_ ip: String) -> String?   // blocking getnameinfo, IPv4 or IPv6
public func reverseIPv6Nibbles(_ ip: String) -> String?
```

STUN servers: `stun.l.google.com:19302` and `stun.cloudflare.com:3478`.

### 20. TraceHandle

`public actor TraceHandle` (`isCancelled`, `cancel()`) is the internal cancellation token for each
trace. Callers do not receive one; cancel through task cancellation, `cancelActiveTraces()` or
`networkChanged()`.

## Working with Results

### Basic trace

```swift
import SwiftFTR

let tracer = SwiftFTR()
let result = try await tracer.trace(to: "example.com")

print("Target: \(result.destination) (\(result.resolvedIP ?? "?"))")
print("Reached: \(result.reached), hops: \(result.hops.count), \(result.duration)s")
let isIPv4 = !(result.resolvedIP ?? "").contains(":")  // reason names cover IPv4 codes only

for hop in result.hops {
    switch hop.outcome {
    case .replied, .unreachable:
        let ms = (hop.rtt ?? 0) * 1000
        var line = "\(hop.ttl)\t\(hop.ipAddress ?? "?")\t\(String(format: "%.2f ms", ms))"
        if let hostname = hop.hostname { line += "\t\(hostname)" }
        if case .unreachable(let code) = hop.outcome {
            if isIPv4, let reason = hop.outcome.unreachableReason {
                line += "\t!\(reason.displayName)"
            } else {
                line += "\t!unreachable (code \(code))"
            }
        }
        print(line)
    case .timedOut:
        print("\(hop.ttl)\t*")
    case .notSent(let errno):
        print("\(hop.ttl)\tnot sent (errno \(errno))")
    }
}
```

### Classified trace and segments

```swift
let classified = try await tracer.traceClassified(to: "cloudflare.com")

print("Public IP: \(classified.publicIP ?? "unknown")")
print("Client AS\(classified.clientASN.map(String.init) ?? "?") \(classified.clientASName ?? "")")
print("Destination AS\(classified.destinationASN.map(String.init) ?? "?") \(classified.destinationASName ?? "")")

// HopCategory is not CaseIterable; list the order explicitly.
let order: [HopCategory] = [.local, .vpn, .isp, .transit, .destination, .unknown]
let segments = Dictionary(grouping: classified.hops) { $0.category }
for category in order {
    guard let hops = segments[category] else { continue }
    let asns = Set(hops.compactMap { $0.asn }).sorted()
    print("\(category.rawValue): TTLs \(hops.map { $0.ttl }), ASNs \(asns)")
}

// ASN transitions along the path
var previous: ClassifiedHop?
for hop in classified.hops where hop.asn != nil {
    if let p = previous, p.asn != hop.asn {
        print("TTL \(hop.ttl): \(p.asName ?? "AS\(p.asn!)") -> \(hop.asName ?? "AS\(hop.asn!)")")
    }
    previous = hop
}
```

### Sample classified data

Illustrative values, consistent with the classifier's rules above (the client and destination
ASNs drive ISP and DESTINATION):

```swift
ClassifiedTrace(
    destinationHost: "google.com",
    destinationIP: "142.250.185.78",
    destinationHostname: "sea30s10-in-f14.1e100.net",
    publicIP: "73.162.0.10",
    publicHostname: "c-73-162-0-10.hsd1.ca.comcast.net",
    clientASN: 7922,
    clientASName: "COMCAST-7922",
    destinationASN: 15169,
    destinationASName: "GOOGLE",
    hops: [
        ClassifiedHop(ttl: 1, ip: "192.168.1.1", rtt: 0.0021, asn: nil, asName: nil,
                      category: .local, hostname: "router.lan"),
        ClassifiedHop(ttl: 2, ip: "100.64.0.1", rtt: 0.0082, asn: nil, asName: nil,
                      category: .isp),                            // CGNAT
        ClassifiedHop(ttl: 3, ip: "68.85.221.161", rtt: 0.0099, asn: 7922, asName: "COMCAST-7922",
                      category: .isp),
        ClassifiedHop(ttl: 4, ip: "96.110.32.225", rtt: 0.0142, asn: 7922, asName: "COMCAST-7922",
                      category: .isp),
        ClassifiedHop(ttl: 5, ip: nil, rtt: nil, asn: nil, asName: nil,
                      category: .unknown),                        // between ISP and DESTINATION: not filled
        ClassifiedHop(ttl: 6, ip: "108.170.241.97", rtt: 0.0215, asn: 15169, asName: "GOOGLE",
                      category: .destination),
        ClassifiedHop(ttl: 7, ip: "142.250.185.78", rtt: 0.0246, asn: 15169, asName: "GOOGLE",
                      category: .destination, hostname: "sea30s10-in-f14.1e100.net"),
    ]
)
```

A third-party network between the client's and destination's ASNs would appear as TRANSIT.

### Detecting path issues

```swift
func analyze(_ result: TraceResult) -> [String] {
    var issues: [String] = []

    let silent = result.hops.filter { !$0.outcome.didReceiveReply }.count
    if !result.hops.isEmpty, Double(silent) / Double(result.hops.count) > 0.3 {
        issues.append("\(silent) of \(result.hops.count) hops did not answer")
    }

    let notSent = result.hops.filter { if case .notSent = $0.outcome { true } else { false } }
    if !notSent.isEmpty {
        issues.append("\(notSent.count) probes never left the host (send pressure)")
    }

    // ICMPUnreachableReason names IPv4 codes; report ICMPv6 codes numerically.
    let isIPv4 = !(result.resolvedIP ?? "").contains(":")
    for hop in result.hops {
        guard case .unreachable(let code) = hop.outcome else { continue }
        if isIPv4, let reason = hop.outcome.unreachableReason {
            issues.append("TTL \(hop.ttl): \(reason.displayName)\(reason.isAdministrative ? " (policy)" : "")")
        } else {
            issues.append("TTL \(hop.ttl): unreachable (code \(code))")
        }
    }

    let answered = result.hops.filter { $0.rtt != nil }
    for (prev, next) in zip(answered, answered.dropFirst()) {
        let jumpMs = (next.rtt! - prev.rtt!) * 1000
        if jumpMs > 50 { issues.append("+\(Int(jumpMs)) ms at TTL \(next.ttl)") }
    }

    if !result.reached { issues.append("Destination not reached within \(result.maxHops) hops") }
    return issues
}
```

## Usage Patterns

### Configuration

```swift
let config = SwiftFTRConfig(
    maxHops: 20,
    maxWaitMs: 2000,
    payloadSize: 64,
    enableLogging: true,
    rdnsCacheTTL: 3600,
    rdnsCacheSize: 500,
    asnResolverStrategy: .embedded   // no network for ASN lookups
)
let tracer = SwiftFTR(config: config)
await tracer.preloadASNDatabase()
let classified = try await tracer.traceClassified(to: "1.1.1.1")

// Per-call hop budget without a new instance
let short = try await tracer.trace(to: "1.1.1.1", options: TraceOptions(maxHops: 8))
```

### Concurrent traces

```swift
let tracer = SwiftFTR()
let targets = ["google.com", "cloudflare.com", "github.com"]

let results = await withTaskGroup(of: (String, Result<TraceResult, Error>).self) { group in
    for target in targets {
        group.addTask {
            do { return (target, .success(try await tracer.trace(to: target))) }
            catch { return (target, .failure(error)) }
        }
    }
    var all: [(String, Result<TraceResult, Error>)] = []
    for await item in group { all.append(item) }
    return all
}
```

### Cancellation

```swift
let tracer = SwiftFTR()

let traceTask = Task { () -> TraceResult? in
    do {
        return try await tracer.trace(to: "example.com")
    } catch {
        // Cancelling this task throws CancellationError; networkChanged() or
        // cancelActiveTraces() throws TracerouteError.cancelled (also when both happened).
        print("Trace ended: \(error)")
        return nil
    }
}

Task {
    try await Task.sleep(nanoseconds: 500_000_000)
    traceTask.cancel()
}

let result = await traceTask.value
```

### Network transitions

`networkChanged()` is the conservative reset. When the caller knows only part of the network
state changed, compose the finer controls instead of replacing the actor:

```swift
import Network
import SwiftFTR

let tracer = SwiftFTR()
let monitor = NWPathMonitor()
monitor.pathUpdateHandler = { _ in
    Task {
        // Conservative: cancel traces, drop public IP and rDNS caches.
        await tracer.networkChanged()

        // Or, finer-grained:
        // await tracer.cancelActiveTraces()
        // await tracer.invalidateNetworkScopedRDNS()
        // await tracer.invalidatePublicIP()
        // _ = await tracer.seedPublicIP(knownWANAddress, source: .gatewayReported)
    }
}
monitor.start(queue: DispatchQueue(label: "path-monitor"))
```

### Custom ASN resolver

```swift
struct StaticResolver: ASNResolver {
    func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
        var out: [String: ASNInfo] = [:]
        for ip in ipv4Addrs where ip == "1.1.1.1" {
            out[ip] = ASNInfo(asn: 13335, name: "CLOUDFLARENET", prefix: "1.1.1.0/24")
        }
        return out
    }
}

let classified = try await SwiftFTR().traceClassified(to: "1.1.1.1", resolver: StaticResolver())
// Or the built-ins: CachingASNResolver(base: CymruDNSResolver()), LocalASNResolver(),
// HybridASNResolver(source: .embedded)
```

### Error handling

```swift
do {
    _ = try await tracer.trace(to: "invalid..hostname")
} catch let error as TracerouteError {
    switch error {
    case .resolutionFailed(let host, let details):
        print("DNS failed for \(host): \(details ?? "unknown")")
    case .socketCreateFailed(let errno, let details):
        print("Socket error \(errno): \(details)")
    case .interfaceBindFailed(let iface, _, let details):
        print("Cannot bind \(iface): \(details ?? "")")
    case .invalidConfiguration(let reason):
        print("Bad config: \(reason)")
    case .cancelled:
        print("Cancelled")
    default:
        print(error.description)
    }
}
```

### JSON

`ClassifiedTrace`, `ClassifiedHop`, `HopOutcome`, `PingResult`, `NetworkTopology`,
`BufferbloatResult` and the probe results are `Codable`. `TraceResult` and `TraceHop` are not.

```swift
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(try await tracer.traceClassified(to: "apple.com"))
let decoded = try JSONDecoder().decode(ClassifiedTrace.self, from: data)
```

### SwiftUI

```swift
import SwiftUI
import SwiftFTR

@MainActor
final class TraceViewModel: ObservableObject {
    @Published var hops: [TraceHop] = []
    @Published var isTracing = false
    @Published var error: Error?
    private let tracer = SwiftFTR()

    func trace(to host: String) async {
        isTracing = true
        defer { isTracing = false }
        error = nil
        do { hops = try await tracer.trace(to: host).hops } catch { self.error = error }
    }
}

struct TraceView: View {
    @StateObject private var model = TraceViewModel()
    @State private var destination = ""

    var body: some View {
        VStack {
            HStack {
                TextField("Destination", text: $destination)
                Button("Trace") { Task { await model.trace(to: destination) } }
                    .disabled(model.isTracing)
            }
            List(model.hops, id: \.ttl) { hop in
                HStack {
                    Text("#\(hop.ttl)")
                    Text(hop.ipAddress ?? "*")
                    Spacer()
                    if let rtt = hop.rtt { Text(String(format: "%.1f ms", rtt * 1000)) }
                }
            }
        }
    }
}
```

## Performance and Caching

- **Probe phase**: all TTLs are sent in one burst, then the trace waits once for replies, for up
  to `maxWaitMs` (less if the destination and every earlier hop answer first). The receive window
  does not grow with hop count. The burst itself can take up to 250 ms more when sends hit
  transient buffer pressure, and that time is not counted against `maxWaitMs`.
- **rDNS phase**: lookups run concurrently, each bounded by `rdnsLookupTimeout` (default 5 s).
  Results are cached per instance (TTL 86400 s, 1000 entries by default). Multipath flows use
  the instance's rDNS cache and ASN resolver, so they follow the same settings.
- **Public IP** (classified trace and multipath only): each discovery attempt is bounded by
  `publicIPDiscoveryTimeout` (default 6 s), and a classified trace makes up to two attempts (before
  the trace, then again during classification if the first found nothing). An address found by
  the first attempt is cached per instance until invalidated; one found only by the second is
  returned in that result and not cached, so the next trace discovers again. Multipath reuses an existing cached value but does not
  write its own discoveries back; with no cached value, each flow discovers on its own, each
  attempt bounded by the instance's `publicIPDiscoveryTimeout`.
- **ASN**: the embedded database answers locally (microseconds per lookup once loaded; it reloads
  if every resolver holding it has been released). DNS-based results are cached process-wide with
  a soft cap of 2048 entries. ASN caches
  are not cleared by `networkChanged()`.

## Protocols Used

- **ICMP / ICMPv6** Echo Request over `SOCK_DGRAM` sockets; no root on macOS.
- **DNS**: Team Cymru TXT (`origin.asn.cymru.com`, `origin6.asn.cymru.com`) for `.dns` and
  `.hybrid` misses; PTR for reverse DNS; `whoami.ds.akahelp.net` TXT as the public-IP fallback.
- **STUN** (RFC 5389 Binding Request) for public-IP discovery.
- **TCP connect / UDP / HTTP(S)** for the probe APIs.

## Limitations

- macOS only.
- Multipath is IPv4 only and ICMP-based.
- ICMP may be filtered or rate-limited; many routers do not answer, so holes in a path are normal.
- Traces do not run on GitHub-hosted runners (ICMP is unavailable there).
- Maximum 255 hops (IP TTL limit).

## CLI (swift-ftr)

```bash
swift build -c release --product swift-ftr

# trace is the default subcommand
.build/release/swift-ftr example.com
.build/release/swift-ftr trace 1.1.1.1 -m 20 -t 2.0 --json --no-rdns --public-ip 203.0.113.7
.build/release/swift-ftr trace -i en0 -s 192.168.1.10 -p 64 --verbose google.com

.build/release/swift-ftr stream 1.1.1.1 --retry-after 3      # or --no-retry
.build/release/swift-ftr ping 1.1.1.1 -c 10 --json
.build/release/swift-ftr probe tcp example.com 443
.build/release/swift-ftr probe udp 8.8.8.8 53 --payload 00
.build/release/swift-ftr probe http https://example.com --follow-redirects
.build/release/swift-ftr probe dns 1.1.1.1 example.com
.build/release/swift-ftr multipath 8.8.8.8 --flows 8 --max-paths 16 --early-stop 3
.build/release/swift-ftr bufferbloat --load-type upload --streams 8
.build/release/swift-ftr interfaces --vpn-only --json
```

Trace flags: `--json`, `--no-rdns`, `--public-ip IP`, `-i/--interface`, `-s/--source`,
`-p/--payload-size` (default 56), `--verbose`, `-m/--max-hops` (default 40), `-t/--timeout`
seconds (default 1.0). `--public-ip` bypasses discovery for classified-trace enrichment. Run
`swift-ftr <subcommand> --help` for the rest.

## Testing

```bash
# Offline, deterministic run
SKIP_NETWORK_TESTS=1 PTR_SKIP_STUN=1 swift test -c debug
```

Tests that hit the network should not assume particular hop counts, ASN assignments, or that a
TRANSIT segment exists.
