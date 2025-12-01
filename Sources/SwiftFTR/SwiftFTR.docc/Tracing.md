# Tracing

Use ``SwiftFTR/SwiftFTR`` to perform a parallel traceroute to an IPv4 host.

## Basic Trace

```swift
import SwiftFTR

let tracer = SwiftFTR()
let result = try await tracer.trace(to: "8.8.8.8", maxHops: 40, timeout: 1.0)
print(result.hops)
```

## Classified Trace

```swift
import SwiftFTR

let tracer = SwiftFTR()
let classified = try await tracer.traceClassified(to: "www.example.com", maxHops: 40, timeout: 1.0)
for hop in classified.hops {
    print(hop.ttl, hop.ip ?? "*", hop.category, hop.asn ?? -1)
}
```

## Notes

- Classification performs best-effort ASN lookups with short timeouts; results may be incomplete.
- STUN-based public IP discovery can be disabled with `PTR_SKIP_STUN=1` or overridden via `PTR_PUBLIC_IP`.

