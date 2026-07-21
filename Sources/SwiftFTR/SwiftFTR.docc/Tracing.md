# Tracing

Use ``SwiftFTR/SwiftFTR`` to perform a parallel traceroute to an IPv4 or IPv6 host.

## Basic Trace

```swift
import SwiftFTR

let config = SwiftFTRConfig(maxHops: 40, maxWaitMs: 1_000)
let tracer = SwiftFTR(config: config)
let result = try await tracer.trace(to: "8.8.8.8")
print(result.hops)
```

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

- Classification performs best-effort ASN lookups with short timeouts; results may be incomplete.
- Set ``SwiftFTR/SwiftFTRConfig/publicIP`` to use a known public address and bypass discovery for
  classified-trace enrichment.
