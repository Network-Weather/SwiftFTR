# Ping

Use ``SwiftFTR/SwiftFTR`` to send ICMP echo requests for network reachability and latency monitoring.

## Overview

The ping functionality provides ICMP echo request/reply support with comprehensive statistics including RTT measurements, packet loss tracking, and jitter analysis.

- Single or multiple ICMP echo requests
- Configurable count, interval, timeout, and payload size
- Statistics: min/avg/max RTT, packet loss percentage, standard deviation, jitter
- Async/await API with structured results

## Basic Ping

Send a single ICMP echo request:

```swift
import SwiftFTR

let tracer = SwiftFTR()
let config = PingConfig(count: 1, timeout: 2.0)
let result = try await tracer.ping(to: "1.1.1.1", config: config)

if let rtt = result.roundTripTimes.first {
    print("RTT: \(rtt * 1000) ms")
} else {
    print("No response")
}
```

## Multiple Pings with Statistics

Send multiple pings and collect statistics:

```swift
import SwiftFTR

let tracer = SwiftFTR()
let config = PingConfig(count: 5, interval: 1.0, timeout: 2.0)
let result = try await tracer.ping(to: "8.8.8.8", config: config)

print("Sent: \(result.statistics.sent)")
print("Received: \(result.statistics.received)")
print("Packet loss: \(Int(result.statistics.packetLoss * 100))%")

if let avg = result.statistics.avgRTT {
    print("Avg RTT: \(String(format: "%.2f ms", avg * 1000))")
}
if let jitter = result.statistics.jitter {
    print("Jitter: \(String(format: "%.2f ms", jitter * 1000))")
}
```

## Continuous Monitoring

Monitor network health continuously:

```swift
import SwiftFTR

let tracer = SwiftFTR()
let config = PingConfig(count: 5, interval: 0.5, timeout: 2.0)

while true {
    let result = try await tracer.ping(to: "example.com", config: config)

    if result.statistics.packetLoss > 0.2 {
        print("⚠️ High packet loss: \(Int(result.statistics.packetLoss * 100))%")
    }

    if let avg = result.statistics.avgRTT, avg > 0.1 {
        print("⚠️ High latency: \(String(format: "%.2f ms", avg * 1000))")
    }

    try await Task.sleep(nanoseconds: 60_000_000_000)  // 60s
}
```

## Fast Reachability Check

Quickly check if a host is reachable:

```swift
import SwiftFTR

let tracer = SwiftFTR()
let config = PingConfig(count: 3, interval: 0.2, timeout: 1.0)
let result = try await tracer.ping(to: "1.1.1.1", config: config)

let isReachable = result.statistics.received > 0
print(isReachable ? "✓ Host reachable" : "✗ Host unreachable")
```

## Topics

### Configuration

- ``SwiftFTR/PingConfig``

### Results

- ``SwiftFTR/PingResult``
- ``SwiftFTR/PingStatistics``

### Operations

- ``SwiftFTR/SwiftFTR/ping(to:config:)``