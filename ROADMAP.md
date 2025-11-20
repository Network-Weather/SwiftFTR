# SwiftFTR Roadmap

This roadmap outlines the development direction for SwiftFTR. It is prioritized by value and impact rather than strict timelines or version numbers.

## 📍 Current Stable State (v0.8.0)
- **Core**: Parallel traceroute with ICMP datagram sockets (no sudo required on macOS).
- **Scalability**: Massively parallel `ping` architecture using `kqueue`/`epoll` (C10k ready).
- **DNS**: Full-featured DNS client supporting 11 record types (A, AAAA, PTR, TXT, MX, NS, CNAME, SOA, SRV, CAA, HTTPS) with high-precision timing.
- **Reachability**: Multi-protocol probing (TCP SYN, UDP connected, HTTP/S).
- **Monitoring**: Bufferbloat testing, Multipath (ECMP) discovery, and network interface binding.
- **Architecture**: Fully async/await, Swift 6 strict concurrency compliant, actor-based.

---

## 🚀 Priority Queue (Next Up)

These features are the primary focus for upcoming releases, ranked by priority.

### 1. UDP Traceroute & Multipath ⚡
**Goal**: Match industry-standard tools (like `traceroute` and `dublin-traceroute`) that use UDP by default for better firewall traversal and ECMP visibility.
- **UDP Traceroute**: Send UDP probes with varying TTL. Handles ICMP Time Exceeded errors correctly.
- **UDP Multipath**: Leverage UDP port variation (5-tuple hashing) to discover ECMP paths that ICMP probes miss.
- **NAT Traversal**: UDP is often better at punching through NATs and firewalls than ICMP.
- **Implementation**: Requires raw sockets (`SOCK_RAW`) or experimental `IP_TTL` on connected UDP sockets. May require elevated privileges (sudo) or specific entitlements.

### 2. Offline ASN Support
**Goal**: Enable fast, private, and offline network classification.
- **Integration**: Bundle or integrate `Swift-IP2ASN` for local IP-to-ASN lookups.
- **Hybrid Mode**: Check local DB first, fallback to DNS (Team Cymru) if needed.
- **Benefits**: Air-gapped support, sub-millisecond classification, privacy (no WHOIS queries sent).

### 3. QUIC & HTTP/3 Probing
**Goal**: Detect modern web infrastructure and test next-generation protocol support.
- **QUIC Handshake**: Send QUIC Initial packets (Version Negotiation) to detect HTTP/3 support without a full stack.
- **Use Cases**: Identify QUIC-capable CDN edges (Cloudflare, Google), test firewall QUIC filtering policies, and validate UDP/443 reachability.

### 4. Enterprise Proxy & VPN Telemetry
**Goal**: Measure performance in locked-down corporate environments where direct internet access is blocked.
- **Proxy Tunneling**: Support HTTP CONNECT and SOCKS5 tunneling to reach external targets.
- **Segmented Timing**: Measure latency at each hop of the chain:
    1. VPN Ingress (time to reach VPN gateway).
    2. Proxy Access (time to TCP connect/handshake with the proxy).
    3. Target Access (time to TLS handshake with target *through* the tunnel).
- **Use Case**: Debugging "slowness" in corporate networks—is it the VPN, the Zscaler proxy, or the actual target?

### 5. System DNS Discovery (Split-DNS Aware)
**Goal**: Accurately identify the *effective* system DNS configuration, which is notoriously complex on macOS/iOS.
- **Problem**: Standard APIs (`res_ninit`) often return stale or incomplete data in complex VPN/Split-DNS scenarios.
- **Solution**: Deep interrogation of system resolver state (potentially using `SystemConfiguration` or patterns used by Chromium/Tailscale) to find the true resolver for a given domain.
- **Benefit**: Diagnostics that match the user's actual browsing experience, respecting enterprise split-tunnel DNS rules.

### 6. Enhanced Network Classification
**Goal**: Go beyond simple ASN labeling to identify sophisticated network types.
- **VPN/Overlay**: specific detection heuristics for WireGuard, Tailscale, ZeroTier, and OpenVPN tunnels.
- **SASE/SSE**: Identify Zscaler, Netskope, and Prisma Access gateways.
- **Cloud/CDN**: Distinguish between AWS/GCP/Azure backbone transit and edge delivery nodes.
- **New Categories**: `.vpn`, `.overlay`, `.cdn`, `.cloud`, `.cgnat`, `.proxy`.

### 7. TCP Traceroute
**Goal**: Maximum firewall traversal capability.
- **Method**: Send TCP SYN packets with varying TTL to ports 80/443.
- **Use Case**: Discover paths through strict firewalls that block ICMP and UDP but allow web traffic.

### 8. IPv6 Support
**Goal**: Full feature parity for IPv6 networks.
- **Scope**: ICMPv6 Echo, IPv6 traceroute, and AAAA record support in all tools.
- **Challenges**: Different socket options and header structures compared to IPv4.

---

## 🔮 Future & Research

Ideas that are valuable but not yet scheduled.

### Advanced Analytics
- **Path Change Detection**: Alert when a route shifts (route flapping).
- **Jitter/Loss Analysis**: Per-hop quality metrics.
- **MTU Discovery**: Path MTU detection (PMTUD) without relying on ICMP Packet Too Big.

### Production Ready / Enterprise
- **Metrics Export**: OpenTelemetry or Prometheus exposition format.
- **Distributed Tracing**: Coordination format for running traces from multiple vantage points.
- **Linux Support**: First-class Linux support (handling capability requirements for raw sockets).

### Research
- **Machine Learning**: Anomaly detection for latency spikes.
- **BPF (Berkeley Packet Filter)**: Experiment with sending raw packets via `/dev/bpf` on macOS to bypass root requirements.

---

## 🤝 Contributing

We welcome contributions! If you want to help, the **Priority Queue** is the best place to start. Please open an issue to discuss implementation details before starting large features like UDP support.
