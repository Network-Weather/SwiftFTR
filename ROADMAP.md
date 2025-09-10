# SwiftFTR Roadmap

## Current Version: 0.2.0 (September 2025)
- ✅ Core traceroute functionality with ICMP datagram sockets
- ✅ Swift 6.1 concurrency compliance
- ✅ Thread-safe, nonisolated API
- ✅ ASN resolution via DNS (Team Cymru)
- ✅ Hop categorization (LOCAL, ISP, TRANSIT, DESTINATION)
- ✅ Configuration-based API (no environment variables)
- ✅ Comprehensive test suite
- ✅ Enhanced error handling with contextual details
- ✅ CLI improvements with verbose logging and payload size configuration

## Version 0.3.0 - Q4 2025: Caching, rDNS, and Cancellation Support
### Core Library Enhancements
- [ ] Actor-based architecture using Swift 6.1 features
- [ ] Reverse DNS (rDNS) support with caching (86400s default TTL)
- [ ] STUN public IP caching between traces
- [ ] Trace cancellation support for network changes
- [ ] Enhanced data models with hostname fields
- [ ] `networkChanged()` API for cache invalidation
- [ ] Feature parity between CLI and library

**Implementation Details:**
- See [CACHING_PLAN.md](CACHING_PLAN.md) for detailed implementation plan
- Convert SwiftFTR from struct to actor for thread safety
- Add RDNSCache actor with LRU eviction
- TraceHandle for cancellation with Swift Atomics
- Batch rDNS lookups for performance

**Benefits:**
- Eliminate redundant STUN queries (save 100-500ms per trace)
- Cache rDNS lookups for repeated IPs
- Gracefully handle network changes
- Feature parity between CLI and library API
- Thread-safe caching with actor isolation

## Version 0.4.0 - Q1 2026: VPN/Zero Trust/SASE Support
### Enterprise Network Compatibility
- [ ] VPN tunnel detection and classification
- [ ] Split-tunnel VPN handling
- [ ] Zero Trust Network Access (ZTNA) path detection
- [ ] SASE (Secure Access Service Edge) endpoint identification
- [ ] WireGuard and IPSec tunnel awareness
- [ ] Overlay network detection (SD-WAN, VXLAN)
- [ ] Proxy and gateway detection (SOCKS, HTTP CONNECT)

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

## Version 0.5.0 - Q2 2026: Offline ASN Support
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

## Version 0.6.0 - Q3 2026: Enhanced Protocol Support
### Multiple Probe Methods
- [ ] UDP probe support (like traditional traceroute)
- [ ] TCP SYN probe support (for firewall traversal)
- [ ] Configurable probe protocol selection
- [ ] Parallel multi-protocol probing

**Benefits:**
- Better firewall/filter traversal
- More complete path discovery
- Protocol-specific path detection

## Version 0.7.0 - Q4 2026: IPv6 Support
### Full Dual-Stack Support
- [ ] ICMPv6 implementation
- [ ] IPv6 address resolution
- [ ] Dual-stack concurrent tracing
- [ ] IPv6-specific hop classification

**Challenges:**
- Different socket permissions on various platforms
- IPv6 path discovery complexity
- Dual-stack result merging

## Version 0.8.0 - Q1 2027: Advanced Analytics
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

## Version 1.0.0 - Q1 2027: Production Ready
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
1. VPN/Zero Trust/SASE testing and detection (immediate)
2. Swift-IP2ASN integration (Q4 2025)
3. Enterprise network compatibility
4. Performance benchmarking with tunneled traffic
5. Platform compatibility testing

## Dependencies & Integration Points

### Current Dependencies
- Swift 6.1+ (minimum requirement as of v0.2.0)
- macOS 13+ (ICMP datagram socket support)

### Planned Integrations
- **Swift-IP2ASN**: Offline ASN database (v0.4.0)
- **SwiftNIO**: Optional high-performance I/O (v1.0.0)
- **Swift Metrics**: Observability API (v0.7.0)

## Breaking Changes Policy

- Semantic versioning strictly followed
- Deprecation warnings for 2 minor versions
- Migration guides for breaking changes
- Beta releases for major features

## Performance Targets

| Metric | Current (v0.2.0) | v0.7.0 Target | v1.0.0 Target |
|--------|------------------|---------------|---------------|
| Single trace (30 hops) | ~1.0s | ~0.8s | ~0.5s |
| Concurrent traces | 10 | 50 | 100+ |
| Memory per trace | ~5KB | ~3KB | ~2KB |
| ASN lookup time | ~100ms | ~1ms (offline) | ~0.1ms |
| VPN tunnel detection | N/A | <100ms | <50ms |
| SASE endpoint identification | N/A | 95% accuracy | 99% accuracy |

## Success Metrics

- Adoption by 100+ projects by v1.0.0
- 95%+ test coverage maintained
- Zero critical bugs in production
- Sub-second trace completion for 95% of internet destinations
- Full Swift 6 language mode compliance