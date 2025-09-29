# SwiftFTR v0.5.0 - Ping and Multipath Discovery

**Release Date:** September 29, 2025

## 🎉 Major Features

### Ping API
Efficient ICMP echo monitoring with comprehensive statistics:
- Single or multiple ping requests with configurable intervals
- Statistics: min/avg/max RTT, packet loss percentage, standard deviation, jitter
- Perfect for continuous network health monitoring
- Works from any actor context (fully Swift 6 concurrency compliant)

```swift
let tracer = SwiftFTR()
let config = PingConfig(count: 5, interval: 1.0, timeout: 2.0)
let result = try await tracer.ping(to: "1.1.1.1", config: config)
print("Avg RTT: \(result.statistics.avgRTT! * 1000) ms")
print("Packet loss: \(Int(result.statistics.packetLoss * 100))%")
```

### Multipath Discovery (ECMP Enumeration)
Dublin Traceroute-style path discovery for load-balanced networks:
- Systematically discovers multiple equal-cost paths (ECMP)
- Smart path deduplication for intermittent responders
- Early stopping when no new unique paths are found
- Extract unique hops across all paths for comprehensive monitoring
- Detect ECMP divergence points and common path prefixes

```swift
let tracer = SwiftFTR()
let config = MultipathConfig(flowVariations: 8, maxPaths: 16)
let topology = try await tracer.discoverPaths(to: "8.8.8.8", config: config)
print("Found \(topology.uniquePathCount) unique paths")

// Extract all unique hops for monitoring
for hop in topology.uniqueHops() {
    print("Monitor hop at TTL \(hop.ttl): \(hop.ip ?? "*")")
}
```

### Flow Identifier Control
Optional flow ID parameter for reproducible traces:
- Stable flow identifiers enable consistent path discovery
- Control which ECMP path your trace follows
- Used internally by multipath discovery

```swift
let flowID = FlowIdentifier.generate(variation: 0)
let trace = try await tracer.trace(to: "example.com", flowID: flowID)
```

## 🛠️ CLI Enhancements

### New Ping Subcommand
```bash
swift-ftr ping 1.1.1.1 -c 10 -i 1.0 --json
```

Options: `--count`, `--interval`, `--timeout`, `--payload-size`, `--interface`, `--json`

### New Multipath Subcommand
```bash
swift-ftr multipath 8.8.8.8 -f 8 --max-paths 16 --json
```

Options: `--flows`, `--max-paths`, `--early-stop`, `--max-hops`, `--wait`, `--json`

## 📚 Documentation

- **10 new examples** in `docs/guides/EXAMPLES.md` covering ping and multipath use cases
- **DocC documentation** for Ping and Multipath APIs
- **Updated README** with v0.5.0 features and CLI usage
- **CHANGELOG** with complete technical details

## ⚠️ Known Limitations

### ICMP Multipath Discovery
Current implementation uses ICMP-based multipath discovery, which has important limitations:

- **Many ECMP routers do not hash ICMP ID field** for load balancing decisions
- ICMP-based discovery may find **significantly fewer paths** than UDP-based tools
- Real-world example: ICMP found **1 path** to 8.8.8.8, UDP (dublin-traceroute) found **7 paths**

**When to use:**
- **ICMP multipath**: Accurately reflects diversity of ICMP ping monitoring paths
- **UDP multipath** (planned v0.5.5): Accurately reflects diversity of TCP/UDP application paths

See `docs/development/ROADMAP.md` for UDP multipath implementation plans (v0.5.5, high priority).

## 🔄 Breaking Changes

**None** - All features are additive. Existing traceroute APIs remain unchanged.

## ✅ Testing

- **44 tests** across 12 suites (all passing)
- **15 multipath unit tests** + 7 integration tests
- **22 ping tests** (unit + integration)
- Integration tests validate real network behavior with ECMP targets

## 📦 Installation

Update your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Network-Weather/SwiftFTR.git", from: "0.5.0")
]
```

## 🙏 Acknowledgments

This release implements features critical for the Network Weather Exchange (NWX) project's multipath network monitoring capabilities.

## 🐛 Bug Reports

Report issues at: https://github.com/Network-Weather/SwiftFTR/issues

---

**Full Changelog**: https://github.com/Network-Weather/SwiftFTR/blob/main/CHANGELOG.md