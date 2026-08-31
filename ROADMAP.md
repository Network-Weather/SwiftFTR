# SwiftFTR Roadmap

Forward-looking work, stack-ranked top-to-bottom by priority. For what has already shipped, see [CHANGELOG.md](CHANGELOG.md).

## Priority Queue

### Per-hop outcome model
**Goal**: Let a caller tell apart the four things that can actually happen at a hop.

- **Problem**: `TraceHop` encodes outcome implicitly through `nil` fields, and it collapses
  distinctions the library already parses. `.timeExceeded` and `.destinationUnreachable`
  currently construct identical hops — an address, an RTT, `reachedDestination: false` —
  so "this router forwarded me" and "this router refused" are indistinguishable
  downstream. The ICMP code is parsed and then discarded: `ParsedICMP.Kind` carries a code
  only on `.other`. The ping parser keeps it, so the trace path is the outlier.
- **Approach**: add a `HopOutcome` enum covering the four real outcomes — probe never sent
  (with errno), sent and nothing returned, an ICMP error returned (with code and timing),
  and a normal reply (Time Exceeded from an intermediate hop, or Echo Reply at the
  destination). Thread the ICMP code through the v4 and v6 trace parsers.
- **Additive, not a migration.** The enum becomes authoritative; `ipAddress`, `rtt`, and
  `reachedDestination` stay and are documented as derived. Purer designs move the timing
  onto the enum's associated values so illegal states are unrepresentable, but that breaks
  the primary downstream consumer for little gain.
- **Reach**: `TraceHop`, the classified and streaming hop types, and the CLI's snake_case
  JSON output, which carries a stated backward-compatibility obligation.
- **Deliberately out of scope**: a fifth outcome for replies arriving after the deadline,
  which currently collapse into the timeout case. Only meaningful for the streaming API;
  add it if a consumer asks.
- **Unblocks a pending behavior change**: transient send-pressure retry currently throws when its
  shared burst budget is exhausted, losing the whole trace. Skipping just that probe would be
  better, but is only honest once `.notSent(errno:)` exists — until then a skipped probe is
  indistinguishable from an unresponsive router, and the caller cannot tell that we never sent.

### STUN server list provides no actual redundancy
**Goal**: Make public-IP discovery fail over to a genuinely different endpoint.

- **Problem**: `stunServers` lists multiple Google hostnames, and discovery walks them serially,
  paying a `getaddrinfo` for each. Measured 2026-08-30: `stun.l.google.com` and
  `stun1.l.google.com` both resolve to `74.125.250.129` — the same address. The list costs 3x the
  DNS work of one server while providing no IP-level failover, and against an unresponsive
  resolver each of those lookups stalls 30s.
- **Approach**: pick endpoints operated by different providers so failover means something, and
  resolve them concurrently rather than serially. Two servers on distinct networks beat three
  hostnames pointing at one address.
- **Note**: verify the duplication still holds before acting — Google's records carry a ~150s TTL
  and are geo-steered, so a different vantage point may resolve them differently.

### Literal-IP STUN endpoints
**Goal**: Remove DNS from public-IP discovery entirely, rather than bounding its cost.

- **Rationale**: discovery exists to find our public address; it does not need a name lookup to do
  it. A literal address makes a dead resolver cost nothing here instead of costing the configured
  budget.
- **Constraint — the address must be anycast, not geo-DNS-steered.** Google's STUN records carry a
  ~150s TTL and resolve to a nearby edge, so pinning one sampled in any single location both bets
  against the operator's stated intent and sends every other region to a distant address.
  `stun.cloudflare.com` has the opposite profile: a ~24h TTL on `162.159.207.0` (v4) and
  `2606:4700:49::` (v6), both anycast, both verified answering STUN binding requests on
  2026-08-30.
- **Trade-off, and why this needs a decision rather than an implementation**: measured from
  Redwood City, the Cloudflare anycast v4 answered in 103ms against Google's 14ms. Pinning trades
  everyday latency for failure-mode robustness, and adds a default third-party dependency. Worth
  measuring from more than one vantage point first.
- **Shape if adopted**: literal addresses as the fast path, hostnames as fallback, and a comment
  on the pin stating the condition under which it should be revisited.

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
