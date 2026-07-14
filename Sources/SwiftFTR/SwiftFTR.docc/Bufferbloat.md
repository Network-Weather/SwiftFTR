# Bufferbloat

Use ``SwiftFTR/SwiftFTR`` to test for bufferbloat and measure network responsiveness under load.

## Overview

Bufferbloat occurs when excessive buffering in network equipment causes high latency during periods of network congestion. This is the #1 cause of video calls freezing when someone starts a large download.

The ``SwiftFTR/SwiftFTR/testBufferbloat(config:)`` API measures:
1. **Baseline latency** — ping RTT on an idle network
2. **Loaded latency** — ping RTT while saturating the connection with parallel TCP streams
3. **Latency increase** — the difference, graded A through F
4. **RPM score** — Round-trips Per Minute, the Apple/IETF responsiveness metric

## Quick Test

```swift
import SwiftFTR

let tracer = SwiftFTR()
let result = try await tracer.testBufferbloat()

print("Grade: \(result.grade.rawValue)")           // A, B, C, D, or F
print("Baseline: \(result.baseline.p50Ms) ms")
print("Loaded: \(result.loaded.p50Ms) ms")
print("Increase: \(result.latencyIncrease.absoluteMs) ms")

if let rpm = result.rpm {
    print("Working RPM: \(rpm.workingRPM) (\(rpm.grade.rawValue))")
}
```

## Custom Configuration

```swift
let config = BufferbloatConfig(
    target: "1.1.1.1",             // Ping target
    baselineDuration: 5.0,          // Seconds of idle measurement
    loadDuration: 10.0,             // Seconds of loaded measurement
    loadType: .bidirectional,       // .upload, .download, or .bidirectional
    parallelStreams: 4,             // TCP streams per direction
    calculateRPM: true             // Compute RPM score
)

let result = try await tracer.testBufferbloat(config: config)
```

> Important: `BufferbloatConfig.interface` and `sourceIP` bind the baseline and loaded latency pings only. The HTTP upload/download load follows system routing, so these settings do not make the complete test interface-specific.

## Grading Scale

| Grade | Latency Increase | Video Call Impact |
|-------|-------------------|-------------------|
| A     | < 25 ms           | Excellent — no issues expected |
| B     | 25–75 ms          | Good — occasional minor glitches possible |
| C     | 75–150 ms         | Fair — noticeable quality degradation |
| D     | 150–300 ms        | Poor — frequent freezing and audio drops |
| F     | ≥ 300 ms          | Failing — calls essentially unusable under load |

## Video Call Impact

The result includes a ``VideoCallImpact`` assessment with severity and a human-readable description:

```swift
let impact = result.videoCallImpact
print("Severity: \(impact.severity.rawValue)")
print("Description: \(impact.description)")
```

## Topics

### Configuration

- ``BufferbloatConfig``
- ``LoadType``

### Results

- ``BufferbloatResult``
- ``BufferbloatGrade``
- ``LatencyMeasurements``
- ``LatencyIncrease``

### Responsiveness

- ``RPMScore``
- ``RPMGrade``

### Impact Assessment

- ``VideoCallImpact``
- ``VideoCallSeverity``
