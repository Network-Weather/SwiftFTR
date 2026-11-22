# Tracing

Use ``SwiftFTR/SwiftFTR`` to perform a parallel traceroute to an IPv4 or IPv6 host.

## Basic Trace

```swift
import SwiftFTR

let config = SwiftFTRConfig(maxHops: 40, maxWaitMs: 1_000)
let tracer = SwiftFTR(config: config)
let result = try await tracer.trace(to: "8.8.8.8")
print(result.resolvedIP ?? "unresolved", result.reached)
for hop in result.hops {
    print(hop.ttl, hop.ipAddress ?? "*", hop.outcome)
}
```

``SwiftFTR/TraceResult/resolvedIP`` is the exact numeric address that was probed. Each hop's
``SwiftFTR/TraceHop/outcome`` distinguishes a normal reply, a Destination Unreachable report (with
its ICMP code), a probe that timed out, and a probe that never left the host.

## Per-Trace Options

Override the configured `maxHops` for a single trace with ``SwiftFTR/TraceOptions``:

```swift
let short = try await tracer.trace(to: "8.8.8.8", options: TraceOptions(maxHops: 8))
```

Values outside `1...255` throw ``SwiftFTR/TracerouteError/invalidConfiguration(reason:)``.

## Classified Trace

```swift
import SwiftFTR

let config = SwiftFTRConfig(maxHops: 40, maxWaitMs: 1_000)
let tracer = SwiftFTR(config: config)
let classified = try await tracer.traceClassified(to: "www.example.com")
for hop in classified.hops {
    print(hop.ttl, hop.ip ?? "*", hop.category, hop.asn ?? -1)
}
```

## Notes

- ASN lookups default to `.hybrid(.embedded)` (see
  ``SwiftFTR/SwiftFTRConfig/asnResolverStrategy``): the embedded database answers first and DNS is
  consulted only for addresses it does not cover. Non-global addresses are never sent to an ASN
  resolver. Lookups are best-effort, so ASN fields may be `nil`.
- Classification is bounded by its configuration: reverse DNS gives up after
  ``SwiftFTR/SwiftFTRConfig/rdnsLookupTimeout`` and public-IP discovery after
  ``SwiftFTR/SwiftFTRConfig/publicIPDiscoveryTimeout``; hops whose lookups run out of time report
  numerically, and classification proceeds without a public address.
- Set ``SwiftFTR/SwiftFTRConfig/publicIP`` to use a known public address and bypass discovery for
  classified-trace enrichment.
