# SwiftFTR Roadmap

## Current Version: 0.6.0 (October 2025)
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
- ✅ Concurrency modernization: Actor-based ASN cache, async ASNResolver protocol (v0.5.3)
- ✅ Multipath parallelism: 5x speedup via batched parallel flow execution (v0.5.3)
- ✅ Multi-protocol probing: TCP, UDP, DNS, HTTP/HTTPS reachability testing (completed in v0.6.0)

## Version 0.6.1 - Q4 2025: UDP Traceroute ⚡ HIGH PRIORITY
### Traditional UDP Traceroute Support
- [ ] UDP traceroute with varying TTL (like traditional `traceroute` command)
- [ ] Support for custom destination ports
- [ ] Proper handling of ICMP Time Exceeded messages
- [ ] Optional raw packet crafting via /dev/bpf (if sudo available)
- [ ] Graceful fallback when raw sockets unavailable

**Why This is Important:**
- Many firewalls block ICMP but allow UDP
- Industry-standard `traceroute` uses UDP by default
- Better traversal through NAT and firewalls
- Complementary to ICMP traceroute for comprehensive path discovery

**Implementation Approaches:**
1. **Connected UDP Socket** (no root, simpler):
   - Similar to UDP probe implementation
   - Set TTL via IP_TTL socket option
   - Limited by kernel behavior for ICMP error delivery

2. **Raw Socket** (requires root, full control):
   - Craft UDP packets with custom TTL
   - Full control over packet structure
   - Better compatibility with traditional traceroute

3. **BPF (Berkeley Packet Filter)** (experimental):
   - Write packets to /dev/bpf
   - May work without root on macOS
   - Requires experimentation

**Use Cases:**
- Firewalls that block ICMP but allow UDP
- NAT traversal testing
- Comparison with ICMP paths
- Matching behavior of standard `traceroute` command

**Technical Details:**
```swift
// Future API
let config = TraceConfig(
    protocol: .udp,           // .icmp (default), .udp, .tcp
    destinationPort: 33434,   // For UDP
    maxHops: 30
)

let result = try await ftr.trace(to: "example.com", config: config)
```

**Success Criteria:**
- UDP traceroute discovers paths blocked to ICMP
- Performance comparable to ICMP traceroute
- Clear documentation of privilege requirements
- Works on macOS without sudo (if possible)

## Version 0.6.2 - Q4 2025: QUIC Probe Support
### HTTP/3 and QUIC Handshake Probing
- [ ] QUIC handshake probe for HTTP/3 server detection
- [ ] Initial packet construction (Version Negotiation)
- [ ] Handshake completion detection
- [ ] Connection ID validation
- [ ] QUIC version support detection (v1, draft-29, etc.)

**Why This is Important:**
- QUIC/HTTP/3 is rapidly becoming the dominant web protocol (30%+ of top 1M sites)
- Firewalls may treat QUIC differently than traditional UDP
- CDNs and cloud providers heavily use QUIC (Cloudflare, Google, Facebook)
- QUIC probes reveal modern web infrastructure that HTTP/1.1 probes miss

**Use Cases:**
- Detect HTTP/3 support on web servers
- Identify QUIC-capable CDN edges
- Test firewall QUIC traversal (some filter QUIC, allow traditional UDP)
- Monitor QUIC connection establishment latency
- Validate QUIC version compatibility

**Implementation:**
```swift
// Future API
public func quicProbe(
  host: String,
  port: Int = 443,
  timeout: TimeInterval = 3.0
) async throws -> QUICProbeResult

// Result includes QUIC-specific details
struct QUICProbeResult {
  let isReachable: Bool
  let rtt: TimeInterval?
  let versions: [QUICVersion]?  // Supported versions
  let connectionID: Data?
  let error: String?
}
```

**Technical Details:**
- Send QUIC Initial packet (type 0x00) with Version Negotiation
- Parse Server Hello or Version Negotiation response
- UDP-based (similar to existing UDP probe)
- No TLS stack required for handshake detection
- Can detect QUIC even if HTTP/3 negotiation fails

**Benefits:**
- Detect next-generation web infrastructure
- Complementary to HTTP/HTTPS probes
- Identify CDN routing behavior (some CDNs prefer QUIC)
- Test enterprise QUIC filtering policies

**Challenges:**
- QUIC packets have complex header format (variable-length fields)
- Version negotiation may require multiple round-trips
- Connection ID generation must follow spec
- Some networks aggressively filter UDP/443

## Version 0.7.0 - Q1 2026: Enhanced Network Classification
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

## Version 0.8.0 - Q2 2026: Offline ASN Support
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

## Version 0.9.0 - Q3 2026: TCP Traceroute
### TCP-Based Path Discovery
- [ ] TCP SYN traceroute with varying TTL
- [ ] TCP-based path discovery for firewall traversal
- [ ] Configurable destination ports (80, 443, etc.)
- [ ] Parallel multi-protocol path discovery (ICMP + UDP + TCP)

**Benefits:**
- Better firewall/filter traversal (TCP port 80/443 rarely blocked)
- Most complete path discovery (combine ICMP, UDP, TCP)
- Protocol-specific path detection
- Enterprise network compatibility

## Version 0.9.5 - Q4 2026: IPv6 Support
### Full Dual-Stack Support
- [ ] ICMPv6 implementation
- [ ] IPv6 address resolution
- [ ] Dual-stack concurrent tracing
- [ ] IPv6-specific hop classification

**Challenges:**
- Different socket permissions on various platforms
- IPv6 path discovery complexity
- Dual-stack result merging

## Version 0.11.0 - Q1 2027: Advanced Analytics
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
1. **UDP traceroute** (Q4 2025) ⚡ **HIGHEST PRIORITY**
2. **UDP-based multipath discovery** (Q4 2025) ⚡ **HIGH PRIORITY**
3. VPN/Zero Trust/SASE testing and detection (Q1 2026)
4. Swift-IP2ASN integration (Q2 2026)
5. Enterprise network compatibility testing
6. BPF experimentation for raw packet writing without root

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