# SwiftFTR Roadmap

## Current Version: 0.5.0 (September 2025)
- ✅ Core traceroute functionality with ICMP datagram sockets
- ✅ Swift 6.1 concurrency compliance
- ✅ Thread-safe, nonisolated API
- ✅ ASN resolution via DNS (Team Cymru)
- ✅ Hop categorization (LOCAL, ISP, TRANSIT, DESTINATION)
- ✅ Configuration-based API (no environment variables)
- ✅ Comprehensive test suite
- ✅ Enhanced error handling with contextual details
- ✅ CLI improvements with verbose logging and payload size configuration
- ✅ Actor-based architecture using Swift 6.1 features
- ✅ Reverse DNS (rDNS) support with caching (86400s default TTL)
- ✅ STUN public IP caching between traces
- ✅ Trace cancellation support for network changes
- ✅ Enhanced data models with hostname fields
- ✅ `networkChanged()` API for cache invalidation
- ✅ Feature parity between CLI and library
- ✅ Network interface selection (`-i/--interface` CLI, `interface` config)
- ✅ Source IP binding (`-s/--source` CLI, `sourceIP` config)
- ✅ Context-aware private IP classification (ISP vs LAN)
- ✅ Ping API for ICMP echo monitoring (completed in v0.5.0)
- ✅ Multipath discovery with ECMP enumeration (completed in v0.5.0)
- ✅ Flow identifier control for reproducible traces (completed in v0.5.0)

## Version 0.6.0 - Q1 2026: Enhanced Network Classification
### Sophisticated Network Type Detection
- [ ] VPN/Overlay network detection (Tailscale, WireGuard, ZeroTier)
- [ ] SASE/SSE infrastructure identification
- [ ] Proxy and CDN edge node detection
- [ ] SD-WAN endpoint classification
- [ ] Cloud provider backbone recognition (AWS, Azure, GCP)
- [ ] Split-tunnel VPN handling
- [ ] Zero Trust Network Access (ZTNA) path detection

### New Hop Categories
- [ ] `.vpn` or `.overlay` for VPN/overlay network hops
- [ ] `.proxy` for forward/reverse proxy servers
- [ ] `.cdn` for CDN edge locations
- [ ] `.cloud` for cloud provider internal routing
- [ ] `.cgnat` for carrier-grade NAT (distinct from ISP)

### Detection Heuristics
- [ ] Hostname pattern matching (*.ts.net, *.vpn.*, etc.)
- [ ] CGNAT context analysis (first hop vs. after public IPs)
- [ ] AS name patterns for VPN/SASE providers
- [ ] Cloud provider IP range detection
- [ ] RTT pattern analysis for VPN endpoints
- ✅ Improved private IP classification based on position in path (completed in v0.4.0)

**Benefits:**
- Accurate path discovery through VPN tunnels
- Distinguish between underlay and overlay networks
- Identify security service insertion points
- Better enterprise network visibility

**Challenges:**
- VPNs may encapsulate or drop ICMP packets
- Zero Trust proxies may terminate connections
- SASE solutions add multiple hops that appear as single entities
- Need heuristics to detect tunneled vs native traffic

**Testing Requirements:**
- Test with major VPN providers (NordVPN, ExpressVPN, ProtonVPN)
- Test with enterprise VPNs (Cisco AnyConnect, GlobalProtect, OpenVPN)
- Test with Zero Trust solutions (Cloudflare WARP, Zscaler, Netskope)
- Test with SASE platforms (Prisma Access, Cato Networks)
- Test split-tunnel vs full-tunnel configurations
- Document behavior differences across providers

**Implementation:**
```swift
// Future API
let config = SwiftFTRConfig(
    maxHops: 30,
    tunnelDetection: true,
    probeProtocols: [.icmp, .udp, .tcp] // Multi-protocol for better tunnel traversal
)

// Enhanced classification
enum HopCategory {
    case local
    case vpnTunnel(type: VPNType)
    case saseGateway(provider: String)
    case zeroTrustProxy
    case isp
    case transit
    case destination
}
```

## Version 0.5.5 - Q4 2025: UDP-Based Multipath Discovery ⚡ HIGH PRIORITY
### Enhanced ECMP Path Enumeration
- [ ] UDP probe support for multipath discovery (varying destination port)
- [ ] Parallel ICMP and UDP multipath discovery
- [ ] Protocol-aware path comparison and merging
- [ ] Configurable protocol selection for multipath (ICMP, UDP, or both)
- [ ] Raw socket implementation for UDP traceroute probes
- [ ] Privilege requirement detection and error messages

**Why This is Important:**
Current ICMP-based multipath discovery has significant limitations:
- ECMP routers often **do not hash ICMP ID field** when load balancing
- ICMP discovery found **1 unique path** to 8.8.8.8 in testing
- UDP-based Dublin-traceroute found **7 unique paths** to the same destination
- UDP varies destination port, which ECMP routers actively hash (5-tuple hashing)
- This severely limits visibility into actual TCP/UDP application routing diversity

**Real-World Impact:**
```
Test: Multipath discovery to 8.8.8.8
- ICMP (current): 1 path via 135.180.179.42 → 75.101.33.185 → Google
- UDP (dublin-traceroute): 7 paths via different ISP hops and Google ingress points
- Missing diversity: 6 additional ECMP paths invisible to ICMP probes
```

**Use Cases:**
- ICMP multipath: Accurate for **ping monitoring** path discovery (what ping sees)
- UDP multipath: Accurate for **TCP/UDP application** path discovery (what apps see)
- Combined: Complete picture of network path diversity

**Implementation:**
```swift
// Future API
let config = MultipathConfig(
    flowVariations: 16,
    protocol: .udp,        // .icmp (current), .udp (new), .both
    startPort: 33434,      // For UDP
    maxPaths: 20
)

let topology = try await ftr.discoverPaths(to: "example.com", config: config)
print("UDP found \(topology.uniquePathCount) paths")
```

**Technical Requirements:**
- Raw socket (SOCK_RAW) for sending UDP packets with low TTL
- Requires elevated privileges on macOS (may need sudo or entitlements)
- ICMP Time Exceeded reception (already implemented)
- UDP payload generation (simple random data)
- Port range iteration (33434-33453, Paris consistency within flow)

**Backwards Compatibility:**
- Existing ICMP multipath API unchanged (default behavior)
- New `protocol` field in `MultipathConfig` (default: `.icmp`)
- Existing NetworkTopology structure unchanged
- Add optional `protocol` field to DiscoveredPath for tracking

**Benefits:**
- More complete ECMP topology discovery
- Match UDP-based tools (dublin-traceroute, mtr)
- Better application path prediction
- Full parity with industry-standard multipath tools

**Challenges:**
- Requires raw sockets (elevated privileges)
- macOS raw socket permissions may require entitlements
- Need clear error messages when privileges insufficient
- Testing requires actual ECMP networks

**Success Criteria:**
- Find 5-10x more paths on ECMP networks compared to ICMP
- Match or exceed dublin-traceroute path discovery
- Clear documentation of privilege requirements
- Graceful fallback to ICMP when UDP unavailable

## Version 0.7.0 - Q2 2026: Offline ASN Support
### Swift-IP2ASN Integration
- [ ] Integrate Swift-IP2ASN library for offline IP-to-ASN mapping
- [ ] Hybrid resolution: offline first, fallback to DNS
- [ ] Configurable ASN data source selection
- [ ] Pre-compiled ASN database support
- [ ] Memory-efficient prefix tree implementation

**Benefits:**
- No network dependency for ASN lookups
- Faster classification (no DNS roundtrips)
- Works in air-gapped environments
- Deterministic testing with known ASN data

**Implementation:**
```swift
// Future API
let config = SwiftFTRConfig(
    maxHops: 30,
    asnResolver: .offline(database: ip2asnDB) // or .hybrid, .online
)
```

## Version 0.8.0 - Q3 2026: Enhanced Protocol Support
### Multiple Probe Methods
- [ ] UDP probe support (like traditional traceroute)
- [ ] TCP SYN probe support (for firewall traversal)
- [ ] Configurable probe protocol selection
- [ ] Parallel multi-protocol probing

**Benefits:**
- Better firewall/filter traversal
- More complete path discovery
- Protocol-specific path detection

## Version 0.9.0 - Q4 2026: IPv6 Support
### Full Dual-Stack Support
- [ ] ICMPv6 implementation
- [ ] IPv6 address resolution
- [ ] Dual-stack concurrent tracing
- [ ] IPv6-specific hop classification

**Challenges:**
- Different socket permissions on various platforms
- IPv6 path discovery complexity
- Dual-stack result merging

## Version 0.10.0 - Q1 2027: Advanced Analytics
### Path Analysis Features
- [ ] Path change detection over time
- [ ] Latency variance analysis
- [ ] Packet loss detection per hop
- [ ] MTU discovery along path
- [ ] Asymmetric path detection

### Performance Optimizations
- [ ] Persistent socket connection pooling
- [ ] Batch trace scheduling
- [ ] Result caching with TTL
- [ ] Streaming results API

## Version 1.0.0 - Q2 2027: Production Ready
### Enterprise Features
- [ ] Distributed tracing coordination
- [ ] Metrics export (Prometheus, StatsD)
- [ ] Custom probe payload support
- [ ] Rate limiting and backpressure
- [ ] Comprehensive documentation
- [ ] Performance guarantees

### Platform Expansion
- [ ] Linux support (with capability detection)
- [ ] iOS support (with entitlement requirements)
- [ ] SwiftNIO integration option
- [ ] WebAssembly compilation target

## Research & Future Considerations

### Machine Learning Integration
- Anomaly detection in network paths
- Predictive path failure analysis
- Automatic optimal probe configuration

### Cloud Native Features
- Kubernetes operator for distributed tracing
- Service mesh integration
- OpenTelemetry support

### Security Enhancements
- Encrypted probe payloads
- Authentication for probe responses
- Anti-spoofing measures

## Contributing

We welcome contributions! Priority areas:
1. **UDP-based multipath discovery** (Q4 2025) ⚡ **HIGHEST PRIORITY**
2. VPN/Zero Trust/SASE testing and detection (immediate)
3. Swift-IP2ASN integration (Q1 2026)
4. Enterprise network compatibility
5. Performance benchmarking with tunneled traffic
6. Platform compatibility testing

## Dependencies & Integration Points

### Current Dependencies
- Swift 6.1+ (minimum requirement)
- macOS 13+ (ICMP datagram socket support)
- Swift Concurrency with actors (v0.3.0+)

### Planned Integrations
- **Swift-IP2ASN**: Offline ASN database (v0.7.0)
- **SwiftNIO**: Optional high-performance I/O (v1.0.0)
- **Swift Metrics**: Observability API (v0.10.0)

## Breaking Changes Policy

- Semantic versioning strictly followed
- Deprecation warnings for 2 minor versions
- Migration guides for breaking changes
- Beta releases for major features

## Performance Targets

| Metric | Current (v0.4.0) | v0.8.0 Target | v1.0.0 Target |
|--------|------------------|---------------|---------------|
| Single trace (30 hops) | ~1.0s | ~0.8s | ~0.5s |
| Concurrent traces | 10 | 50 | 100+ |
| Memory per trace | ~5KB | ~3KB | ~2KB |
| ASN lookup time | ~100ms (cached: ~0ms) | ~1ms (offline) | ~0.1ms |
| rDNS lookup time | ~50ms (cached: ~0ms) | ~10ms | ~5ms |
| STUN public IP | ~200ms (cached: ~0ms) | ~100ms | ~50ms |
| VPN tunnel detection | N/A | <100ms | <50ms |
| SASE endpoint identification | N/A | 95% accuracy | 99% accuracy |

## Success Metrics

- Adoption by 100+ projects by v1.0.0
- 95%+ test coverage maintained
- Zero critical bugs in production
- Sub-second trace completion for 95% of internet destinations
- Full Swift 6 language mode compliance