# Bufferbloat

Use ``SwiftFTR/SwiftFTR`` to test for bufferbloat and measure network responsiveness under load.

## Overview

Bufferbloat occurs when excessive buffering in network equipment causes high latency during periods of network congestion. This is the #1 cause of video calls freezing when someone starts a large download.

The ``SwiftFTR/SwiftFTR/testBufferbloat(config:)`` API measures:
1. **Baseline latency** — ping RTT on an idle network
2. **Loaded latency** — ping RTT while saturating the connection with parallel URLSession HTTP
   uploads and/or downloads
3. **Latency increase** — the rise in average RTT from baseline to loaded, graded A through F
4. **RPM score** — Round-trips Per Minute, computed as the integer part of 60 divided by the average ping RTT
   in seconds, with the RTT floored at one millisecond (so the score cannot exceed 60,000), and
   graded with the IETF responsiveness thresholds. It is derived from ICMP ping, not from the
   HTTP/TLS transactions that the IETF responsiveness test (and Apple's `networkQuality`) measure,
   so the figures are not directly comparable.

By default the download load comes from `speed.cloudflare.com` and the upload load goes to the
same service's upload endpoint (`https://speed.cloudflare.com/__up`); set `downloadURL` and `uploadURL` on ``BufferbloatConfig`` to use your own
endpoints.

## Quick Test

```swift
import SwiftFTR

let tracer = SwiftFTR()
let result = try await tracer.testBufferbloat()

print("Grade: \(result.grade.rawValue)")           // A, B, C, D, or F
print("Baseline: \(result.baseline.avgMs) ms avg")
print("Loaded: \(result.loaded.avgMs) ms avg")
print("Increase: \(result.latencyIncrease.absoluteMs) ms")  // loaded avg − baseline avg

if let rpm = result.rpm {
    print("Working RPM: \(rpm.workingRPM) (\(rpm.grade.rawValue))")
}
```

## Custom Configuration

The values below are the defaults, except that `pingInterval` (default 0.1 s) is omitted.

```swift
let config = BufferbloatConfig(
    target: "1.1.1.1",             // Ping target
    baselineDuration: 5.0,          // Seconds of idle measurement
    loadDuration: 10.0,             // Seconds of loaded measurement
    loadType: .bidirectional,       // .upload, .download, or .bidirectional
    parallelStreams: 4,             // HTTP streams per direction
    calculateRPM: true              // Compute RPM score
)

let result = try await tracer.testBufferbloat(config: config)
```

## Bound Baseline-Only Measurements

Set `loadDuration` to zero when you need latency measurements bound to an interface or source IP:

```swift
func measureBoundBaseline(interfaceName: String) async throws {
    let snapshot = await NetworkInterfaceDiscovery().discover()
    guard let selectedInterface = snapshot.interface(named: interfaceName),
          selectedInterface.isUp
    else { return }

    let tracer = SwiftFTR(config: SwiftFTRConfig(interface: selectedInterface.name))
    let result = try await tracer.testBufferbloat(
        config: BufferbloatConfig(
            target: "1.1.1.1",
            baselineDuration: 5.0,
            loadDuration: 0
        )
    )

    print("Baseline via \(selectedInterface.name): \(result.baseline.avgMs) ms")
}
```

This mode provides usable `result.baseline` statistics and baseline entries in
`result.pingResults`. It does not perform a loaded phase, so `result.loaded`,
`result.latencyIncrease`, `result.rpm`, and `result.grade` are compatibility placeholders and are
not meaningful. The video-call assessment is derived from the same unavailable loaded metrics and
must not be interpreted either.

A test with `loadDuration > 0` rejects any effective `interface` or `sourceIP` binding, whether it
comes from ``BufferbloatConfig`` or the enclosing ``SwiftFTR/SwiftFTR`` configuration. URLSession
cannot bind the generated HTTP load to that route, and comparing unbound load with bound latency
would not be a valid bufferbloat measurement.

## Grading Scale

The grade is based on the increase in average RTT. A test with no ping replies in either phase is
graded F.

| Grade | Latency Increase | Video Call Severity |
|-------|-------------------|-------------------|
| A     | < 25 ms           | None (when loaded jitter is under 30 ms) |
| B     | 25–75 ms          | Minor (when loaded jitter is under 50 ms) |
| C     | 75–150 ms         | Moderate |
| D     | 150–300 ms        | Severe |
| F     | ≥ 300 ms          | Severe |

## Video Call Impact

The result includes a ``VideoCallImpact`` assessment with severity and a human-readable description.
Severity follows the grade and the loaded-phase jitter as in the table above; an A or B grade with
higher jitter than shown is reported as Moderate. `impactsVideoCalls` is `true` when the grade is D
or F, loaded jitter exceeds 50 ms, or the working RPM is below 1000.

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
- ``BufferbloatPingResult``
- ``TestPhase``
- ``LoadGenerationDetails``

### Responsiveness

- ``RPMScore``
- ``RPMGrade``

### Impact Assessment

- ``VideoCallImpact``
- ``VideoCallSeverity``
