# StreamingTrace

Use ``SwiftFTR/SwiftFTR/traceStream(to:config:)`` for real-time traceroute with hop-by-hop delivery.

## Overview

The streaming traceroute API emits hops as ICMP responses arrive, rather than waiting for all probes to complete. This is ideal for interactive UIs where you want to show progress, or for long-running traces where early results are valuable.

Key differences from ``SwiftFTR/SwiftFTR/trace(to:)``:
- Hops are emitted in **arrival order**, not TTL order
- Each hop is delivered as a ``StreamingHop`` via `AsyncThrowingStream`
- Unresponsive TTLs are automatically retried after a configurable delay
- Timeout placeholders are emitted at the end for any TTLs that never responded

## Basic Usage

```swift
import SwiftFTR

let tracer = SwiftFTR()

for try await hop in tracer.traceStream(to: "1.1.1.1") {
    if let ip = hop.ipAddress, let rtt = hop.rtt {
        print("TTL \(hop.ttl): \(ip) - \(String(format: "%.1f", rtt * 1000))ms")
    } else {
        print("TTL \(hop.ttl): *")
    }

    if hop.reachedDestination {
        print("  <-- destination reached")
    }
}
```

## Custom Configuration

```swift
let config = StreamingTraceConfig(
    probeTimeout: 15.0,    // Total timeout for the trace
    retryAfter: 5.0,       // Retry unresponsive TTLs after 5s
    emitTimeouts: true,    // Emit timeout placeholders at end
    maxHops: 30            // Maximum TTL to probe
)

for try await hop in tracer.traceStream(to: "example.com", config: config) {
    // Process each hop as it arrives
}
```

## Retry Strategy

The streaming trace uses a two-phase strategy:

1. **Initial phase**: All probes are sent immediately. Responses arrive and are yielded as they come in.
2. **Retry phase**: After `retryAfter` seconds (default 4s), any TTLs before the destination that haven't responded are re-probed. This helps with rate-limited routers or packet loss.

Set `retryAfter` to `nil` to disable retry:

```swift
let config = StreamingTraceConfig(retryAfter: nil)
```

## Sorted Results

Since hops arrive in network order, sort by TTL if you need sequential ordering:

```swift
var hops: [StreamingHop] = []

for try await hop in tracer.traceStream(to: "1.1.1.1") {
    hops.append(hop)
}

let sorted = hops.sorted { $0.ttl < $1.ttl }
for hop in sorted {
    print("\(hop.ttl): \(hop.ipAddress ?? "*")")
}
```

## Early Completion

The stream completes early when:
- The destination is reached **and** all earlier TTLs have responded
- The overall `probeTimeout` expires

This means fast traces to nearby destinations complete in well under the timeout.

## Topics

### Configuration

- ``StreamingTraceConfig``

### Results

- ``StreamingHop``

### Operations

- ``SwiftFTR/SwiftFTR/traceStream(to:config:)``
