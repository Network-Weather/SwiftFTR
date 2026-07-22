# Migrating to SwiftFTR 0.14

Adopt stricter validation, exact endpoint identity, UDP route binding, and the revised probe
semantics introduced in SwiftFTR 0.14.

## Overview

SwiftFTR 0.14 is source-compatible for ordinary 0.13 call sites. Compatibility overloads retain
the callable 0.13 initializer and free-function shapes for ``TraceResult``, ``UDPProbeConfig``, and
`udpProbe`. The deliberate source-level migration is the addition of two ``DNSError`` cases, which
affects exhaustive switches.

The release also makes several behavior corrections that can change application results without
requiring source edits:

- invalid numeric, range, duration, and size configuration is reported at a throwing operation
  boundary instead of trapping during initialization;
- HTTP reachability completes at response headers rather than after downloading a response body;
- reverse DNS without a PTR record returns `nil` rather than the numeric input;
- physical Wi-Fi/Ethernet roles come from operating-system metadata, never a numbered BSD-name
  heuristic;
- loaded bufferbloat tests reject route binding that URLSession load traffic cannot honor; and
- pending network work observes structured cancellation more promptly.

## Update the package

Change the SwiftPM requirement and refresh dependency resolution:

```swift
dependencies: [
  .package(
    url: "https://github.com/Network-Weather/SwiftFTR.git",
    from: "0.14.0"
  )
]
```

SwiftFTR 0.14 requires SwiftIP2ASN 0.4.1 or later in the compatible 0.x line. That release includes
the July 2026 dual-stack database and disk-cache recovery fixes. Xcode and SwiftPM may retain an
older resolved version until you update package dependencies.

## Handle the new DNS errors

``DNSError`` adds ``DNSError/invalidTimeout(_:)`` and
``DNSError/setsockoptFailed(option:errno:)``. Add both cases to exhaustive switches. If your code
intentionally groups DNS failures, an ordinary `default` handles current and future cases.
`@unknown default` is useful only after every currently known case has been covered; it does not
replace the new known cases.

```swift
do {
  _ = try await SwiftFTR().dns.a(
    hostname: "example.com",
    timeout: 2
  )
} catch let error as DNSError {
  switch error {
  case .invalidTimeout(let value):
    print("Invalid DNS timeout: \(value)")
  case .setsockoptFailed(let option, let errorCode):
    print("Could not configure \(option): \(errorCode)")
  default:
    print("DNS query failed: \(error)")
  }
}
```

DNS now rejects non-finite and non-positive timeouts, malformed QNAME/PTR inputs, forged or
mismatched UDP responses, truncated UDP replies, and out-of-bounds compressed names. DNS-over-TCP
fallback is not implemented, so a reply with the truncation bit set fails rather than retrying over
TCP.

## Expect numeric validation when operations start

Public configuration initializers retain invalid numeric, range, duration, and size values so they
remain nonthrowing. A throwing operation validates the fields documented for that API before doing
network work and reports ``TracerouteError/invalidConfiguration(reason:)``:

```swift
let configuration = SwiftFTRConfig(maxHops: 0)
let tracer = SwiftFTR(config: configuration)

do {
  _ = try await tracer.trace(to: "example.com")
} catch TracerouteError.invalidConfiguration(let reason) {
  print("Invalid SwiftFTR configuration: \(reason)")
}
```

Apply the same expectation to the numeric and bounded inputs documented by streaming trace, ping,
TCP and UDP probes, bufferbloat, and multipath. Host resolution, route binding, and source-address
errors retain each API's existing error or result channel. Validate user-entered values before
constructing a long-lived client when you want immediate UI feedback.

## Use the address that was actually probed

``TraceResult/resolvedIP`` is the exact numeric endpoint selected before probes were sent. Use it
instead of resolving the destination hostname again for correlation, logging, or downstream
metadata:

```swift
let trace = try await SwiftFTR().trace(to: "example.com")
if let endpoint = trace.resolvedIP {
  print("Probed numeric endpoint: \(endpoint)")
}
```

The compatibility initializer used by manually constructed 0.13-style results leaves
``TraceResult/resolvedIP`` as `nil`.

## Adopt UDP route binding

``UDPProbeConfig`` and `udpProbe` accept an exact BSD interface name and a family-matched source
address. Discover interfaces at runtime, retain the caller's exact selection, and validate that the
address is still assigned immediately before probing:

```swift
enum RouteSelectionError: Error {
  case unavailable
  case addressNotAssigned
}

func probeUDP(
  host: String,
  port: Int,
  payload: Data,
  interfaceName: String,
  sourceIP: String
) async throws -> UDPProbeResult {
  let snapshot = await NetworkInterfaceDiscovery().discover()
  guard let selected = snapshot.interface(named: interfaceName), selected.isUp else {
    throw RouteSelectionError.unavailable
  }
  guard (selected.ipv4Addresses + selected.ipv6Addresses).contains(sourceIP) else {
    throw RouteSelectionError.addressNotAssigned
  }

  return try await udpProbe(
    host: host,
    port: port,
    payload: payload,
    interface: selected.name,
    sourceIP: sourceIP
  )
}
```

Choose a destination whose resolved family matches `sourceIP`. If probing a protocol such as DNS,
provide a valid protocol payload; an empty `Data` value intentionally sends a zero-byte datagram.

An empty `Data` value now sends a true zero-byte datagram. SwiftFTR 0.13 substituted one NUL byte,
so update fixtures or servers that depended on the old payload.

Binding applies to the UDP socket after hostname resolution. It does not bind hostname resolution,
system reverse DNS, Team Cymru ASN queries, DNS-whoami fallback, or URLSession traffic.

## Stop inferring interface roles

``NetworkInterfaceDiscovery`` uses macOS SystemConfiguration metadata to identify physical Wi-Fi
and Ethernet adapters. VPN, loopback, and bridge names retain their documented semantic
classification; an otherwise-unrecognized BSD name without authoritative physical metadata is
classified as ``InterfaceType/other``. Never infer a physical Wi-Fi/Ethernet role from a numbered
name.

Present discovered metadata to the caller and store the exact selected BSD name. Revalidate the
selection after a network change because interfaces and assigned addresses may disappear.

## Update HTTP timing assumptions

`httpProbe` now completes as soon as HTTP response headers arrive and cancels the body transfer.
``HTTPProbeResult/rtt`` therefore measures through header receipt, not full response-body download.
``HTTPProbeResult/networkRTT`` and ``HTTPProbeResult/tcpHandshakeRTT`` remain best-effort URLSession
metrics and may be `nil` when Foundation omits timing data after the intentional cancellation.

Only absolute HTTP and HTTPS URLs with a host and a finite positive timeout are accepted. Any HTTP
status remains evidence of reachability, including 4xx and 5xx responses.

`httpProbe` uses its result channel for invalid URL/timeout, network failure, timeout, and
cancellation outcomes rather than throwing them. Check ``HTTPProbeResult/isReachable`` and
``HTTPProbeResult/error``; a canceled probe currently reports `error == "Cancelled"`.

The public HTTP probe still uses URLSession and system routing. SwiftFTR 0.14 contains a dormant
internal exact-interface HTTPS experiment, but it is not wired into `httpProbe` and is not public
API.

## Revisit route-bound bufferbloat tests

A loaded bufferbloat run now rejects an effective interface or source-address binding. URLSession
cannot guarantee that generated HTTP load follows the route-bound ping socket, so accepting that
configuration would compare different paths.

Choose one of these modes:

- remove interface and source-address binding for a loaded bufferbloat test; or
- set `loadDuration` to zero for a bound baseline-only latency measurement.

For a baseline-only result, only ``BufferbloatResult/baseline`` and baseline entries in
``BufferbloatResult/pingResults`` are meaningful. Do not interpret loaded statistics, latency
increase, RPM, grade, or video-call assessment.

## Keep multipath on IPv4

Multipath discovery remains IPv4-only. SwiftFTR 0.14 rejects a forced IPv6 family or IPv6 source
address before launching flow workers. Use `.v4` or `.auto` with an IPv4-capable destination and
source address.

## Treat missing PTR records as missing data

`reverseDNS(_:)` now returns `nil` when no PTR hostname exists. If presentation code intentionally
wants a numeric fallback, add it at the call site:

```swift
let displayName = reverseDNS(address) ?? address
```

This prevents numeric addresses from being cached or serialized as if they were hostnames.

## Handle cancellation separately

TCP and UDP probes, multipath discovery, and bufferbloat work now tear down and join pending work
when their task is canceled. Do not interpret cancellation as an ordinary timeout or unreachable
result:

```swift
do {
  _ = try await tcpProbe(host: "example.com", port: 443)
} catch is CancellationError {
  // The owning task no longer needs the measurement.
}
```

Selected legacy DNS, STUN/public-IP enrichment, ASN, and cached-rDNS operations run on a bounded
Dispatch-backed executor. After submission, canceling the caller neither dequeues nor interrupts a
synchronous operation, and the caller remains suspended until it finishes. Configured socket
timeouts bound operations that have one. Hostname resolution through `resolveHost` and the public
`reverseDNS` helper remain synchronous at their call sites.

## Review classification changes

Trace classification now handles IPv6 unique-local, link-local, loopback, unspecified, and
multicast addresses, IPv4-mapped IPv6, CGNAT, and VPN-local addresses consistently. Non-global
addresses are no longer sent to ASN resolvers, and exact destination identity takes precedence over
ASN heuristics. If your application snapshots categories, update expected results for non-global
and VPN paths.

## Update CLI automation

- `swift-ftr --version` prints the package release version. Trace JSON continues to include the same
  value in its `version` field.
- `swift-ftr ping` uses `-i` for interval and `-I` for interface. Long options are unchanged.
- Trace JSON now honors `--no-rdns`.
- `swift-ftr interfaces` shows active interfaces by default; add `--include-inactive` to include
  down interfaces.

## Migration checklist

- Handle both new ``DNSError`` cases.
- Replace secondary hostname resolution with ``TraceResult/resolvedIP`` where endpoint identity
  matters.
- Revisit HTTP RTT thresholds and optional URLSession metrics.
- Remove binding from loaded bufferbloat tests or make them baseline-only.
- Confirm multipath inputs remain IPv4-compatible.
- Treat a missing PTR record as `nil`, adding an explicit display fallback if wanted.
- Discover and validate exact interfaces dynamically; do not infer physical roles from BSD names.
- Handle cancellation according to each API's contract; legacy HTTP reports a `"Cancelled"`
  result while TCP/UDP probes throw `CancellationError`.
- Refresh SwiftPM resolution so SwiftIP2ASN 0.4.1 is selected.
