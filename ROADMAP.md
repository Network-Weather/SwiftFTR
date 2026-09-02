# SwiftFTR Roadmap

Forward-looking work, stack-ranked top-to-bottom by priority. For what has already shipped, see [CHANGELOG.md](CHANGELOG.md).

## Priority Queue

### IPv6 hardening
Remaining v6 follow-ups: happy-eyeballs racing (RFC 8305), v6-capable CI runner. Detailed plan in [`docs/IPV6.md`](docs/IPV6.md).

### Enterprise Proxy & VPN Telemetry
**Goal**: Measure performance in locked-down corporate environments where direct internet access is blocked.
- **Proxy Tunneling**: Support HTTP CONNECT and SOCKS5 tunneling to reach external targets.
- **Segmented Timing**: Measure latency at each hop of the chain:
    1. VPN Ingress (time to reach VPN gateway).
    2. Proxy Access (time to TCP connect/handshake with the proxy).
    3. Target Access (time to TLS handshake with target *through* the tunnel).
- **Use Case**: Debugging "slowness" in corporate networks—is it the VPN, the Zscaler proxy, or the actual target?

### Enhanced Network Classification
**Goal**: Go beyond simple ASN labeling to identify sophisticated network types.
- **SASE/SSE**: Identify Zscaler, Netskope, and Prisma Access gateways.
- **Cloud/CDN**: Distinguish between AWS/GCP/Azure backbone transit and edge delivery nodes.
- **New Categories**: `.cdn`, `.cloud`, `.proxy`.

### System DNS Discovery (Split-DNS Aware)
**Goal**: Accurately identify the *effective* system DNS configuration, which is notoriously complex on macOS/iOS.
- **Problem**: Standard APIs (`res_ninit`) often return stale or incomplete data in complex VPN/Split-DNS scenarios.
- **Solution**: Deep interrogation of system resolver state (potentially using `SystemConfiguration` or patterns used by Chromium/Tailscale) to find the true resolver for a given domain.
- **Benefit**: Diagnostics that match the user's actual browsing experience, respecting enterprise split-tunnel DNS rules.

### QUIC & HTTP/3 Probing
**Goal**: Detect modern web infrastructure and test next-generation protocol support.
- **QUIC Handshake**: Send QUIC Initial packets (Version Negotiation) to detect HTTP/3 support without a full stack.
- **Use Cases**: Identify QUIC-capable CDN edges (Cloudflare, Google), test firewall QUIC filtering policies, and validate UDP/443 reachability.

### TCP Traceroute
**Goal**: Maximum firewall traversal capability.
- **Method**: Send TCP SYN packets with varying TTL to ports 80/443.
- **Use Case**: Discover paths through strict firewalls that block ICMP and UDP but allow web traffic.

### UDP Traceroute & Multipath
**Goal**: Match industry-standard tools (like `traceroute` and `dublin-traceroute`) that use UDP by default for better firewall traversal and ECMP visibility.
- **UDP Traceroute**: Send UDP probes with varying TTL. Handles ICMP Time Exceeded errors correctly.
- **UDP Multipath**: Leverage UDP port variation (5-tuple hashing) to discover ECMP paths that ICMP probes miss.
- **NAT Traversal**: UDP is often better at punching through NATs and firewalls than ICMP.
- **Implementation**: Requires raw sockets (`SOCK_RAW`) or experimental `IP_TTL` on connected UDP sockets. May require elevated privileges (sudo) or specific entitlements.
- **Reality check**: macOS sandbox restrictions make this harder than expected; TCP traceroute may be more practical.

---

### Shared expensive state across tracer instances

Raised by Network Weather, 2026-09-01, from a survey of its own SwiftFTR usage.

`SwiftFTRConfig` fixes `interface`, `publicIP` and `maxHops` at `init`, and `trace`,
`traceStream` and `discoverPaths` accept no per-call override. That is correct for
interface binding, which is a socket property that must be set before use and which
`validateForOperation()` checks per operation. The consequence is that a consumer needing
several binding contexts must hold several tracers, and Network Weather holds one per
interface per trace for topology discovery.

The cost is not the instances, it is what each one rebuilds. `init` constructs a fresh
`LocalASNResolver`, an actor whose `loadState` is per-instance with no shared store, so
every tracer pays the 35-40 ms embedded-database load that `preloadASNDatabase()` exists
to avoid, and holds its own copy while alive. The rDNS cache is per-instance for the same
reason.

`traceClassified(to:vpnContext:resolver:)` already solves this for classified traces:
`effectiveResolver = resolver ?? asnResolver` lets a consumer own one preloaded resolver
and pass it in. Three changes would finish the idea:

- Accept `resolver:` on `trace` and `traceStream` as well, so the escape hatch is
  consistent rather than available on one entry point. A consumer currently cannot share
  a resolver with an unclassified trace at all.
- Allow an `RDNSCache` to be supplied at construction the way a resolver can be supplied
  per call, so sibling tracers share hostname lookups instead of each starting cold. Keep
  per-instance as the default, since a cold cache per trace is sometimes what a caller
  wants.
- Document the instance cost in `SwiftFTRConfig`, naming which state is per-instance and
  which can be shared. A consumer holding several tracers has no way to discover today
  that it is paying for several ASN databases.

Deliberately not proposed: moving `interface` or `publicIP` to per-call parameters. It
would require partitioning every cache by binding context and moving validation off the
config, which is a large change to save allocating a small struct. The binding-at-
construction model is the right one.

## Future & Research

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

## Contributing

We welcome contributions! If you want to help, the **Priority Queue** is the best place to start. Please open an issue to discuss implementation details before starting large features.
