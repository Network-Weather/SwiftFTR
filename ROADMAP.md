# SwiftFTR Roadmap

Forward-looking work, stack-ranked top-to-bottom by priority. For what has already shipped, see [CHANGELOG.md](CHANGELOG.md).

## Priority Queue

### Robustness under network and DNS failure, proven by tests
**Goal**: Every public operation returns or throws within a time the caller can work out from its
configuration, whatever fails underneath it and at whatever point: a resolver that never answers,
a network that drops mid-operation, a peer that accepts and then goes silent.

- **Why this is first** (David, 2026-11-21): the library runs inside software that is itself
  diagnosing a broken network, so the failing network is its normal operating condition, not an
  edge case.
- **The fault-injection battery exists** ([docs/ROBUSTNESS-TESTING.md](docs/ROBUSTNESS-TESTING.md)).
  What remains is the findings it left open, each with a disabled or missing test named there.
- **Sequenced plan**: [docs/BLOCKING-IO.md](docs/BLOCKING-IO.md) orders the work into stages, each one
  pull request, with the gates each must pass.
- **Known unbounded waits** (#84): `traceClassified` has no overall deadline, and forward
  resolution runs `getaddrinfo` synchronously on the actor where it can be neither bounded nor
  cancelled; a 5 s resolver stall made `cancelActiveTraces()` wait 5 s (finding 5). An overall
  deadline whose error names the phase that was running is the requested API; a resolution
  budget is what moving `getaddrinfo` onto the executor needs; a way to read executor pressure
  (queued and running operations) is the companion.
- **Standalone `getPublicIPs` has no overall bound** (finding 9): each STUN attempt is bounded by
  `stunTimeout`, but resolving the server names has no deadline, so a stalled resolver holds the
  call for as long as `getaddrinfo` takes unless the caller cancels. Needs a budget the public
  signature does not have, for example a new overload.
- **A `.remote` ASN download is bounded only by URLSession's 60 s default** (finding 7, from code
  reading). Decide between failing classification fast and loading in the background, and make
  the SwiftIP2ASN cache directory injectable so a test can stage it without touching the user's.
- **Report an HTTP status as soon as the headers arrive** (#122, finding 27): URLSession withholds
  the response until body bytes follow it, so a server that stalls after its headers is reported
  only at the timeout, and without its status if no body byte came. Fixing it means reading the
  status line from the connection, for example with the Network.framework transport in
  [docs/development/HTTPProbe-Production-Roadmap.md](docs/development/HTTPProbe-Production-Roadmap.md),
  while keeping URLSession's system routing for the existing API.
- **Measure ping RTTs from the kernel's arrival stamp**: ping already reads it for every reply to
  judge whether the reply came after its request, but still times the reply when the read handler
  takes it, so a busy queue or a long read batch adds to the RTT. Using the stamp would remove that,
  and it is the same clock as the send stamp.
- **A tripwire that keeps the offline selection offline**: nothing stops a new test from reaching
  the network with `SKIP_NETWORK_TESTS=1` set (the #92 sweep found 20 that did). A test-only flag
  in `TestSeams`, set when that variable is, would make the real forward resolver, ICMP socket,
  public-IP discovery, `getnameinfo`, DNS send and URLSession paths record a test issue when
  entered without a substitute. It needs a check on each real path in `Sources/`, so it waits for a
  release that may touch them. Running the suite under `sandbox-exec` with outbound network denied
  catches only leaks whose test then fails: 2 of the 20.

### Share the reverse-DNS cache across tracer instances
**Goal**: Sibling tracers reuse hostname lookups instead of each starting cold, without one
instance's network change evicting another's entries.

- **Problem**: `interface` is fixed at construction, so a caller needing several binding contexts
  holds several tracers, and each owns a private `RDNSCache`. The local ASN database is already
  shared per process; reverse DNS is the remaining per-instance cost, and it is the expensive one
  on a cold network because each lookup can stall.
- **Blocker, and why this did not ship with the rest of the lifecycle work**: eviction is
  per-instance today. `networkChanged()` on one tracer would clear a shared cache for all of them,
  which is wrong when the instances are bound to different interfaces that changed independently.
  Sharing needs eviction scoped to the network a cache entry was observed on, not to the actor
  that happens to call it.
- **Approach**: accept an `RDNSCache` at construction the way `traceClassified` accepts a
  resolver, keeping per-instance as the default. Gate it on scoping eviction by network identity
  so a shared cache cannot be cleared out from under a sibling.
- **Design context**: [Cache and network-transition lifecycle](docs/CACHE-AND-TRANSITION-LIFECYCLE.md)
  describes the cache classes and their invalidation rules.

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

### A direct DNS echo for public-IP discovery
**Goal**: Find the public address on networks that block STUN, without trusting a resolver.

- **What it is**: a query sent straight to an operator's authoritative server, which answers with
  the address it saw the query come from (for example a TXT query for `o-o.myaddr.l.google.com`
  to Google's name servers, or a class CH TXT query for `whoami.cloudflare` to 1.1.1.1). It does
  not go through the resolver the network handed out, whose own address can differ from the
  user's.
- **Why it is not in the library's resolver** (David, 2026-11-23, decision 16 in
  [docs/BLOCKING-IO.md](docs/BLOCKING-IO.md)): a gateway, captive portal or DNS proxy that
  intercepts port 53 can forge the reply, and nothing in the packet shows it. The library's
  resolver is STUN only; a host app can supply its own.
- **What it needs**: class CH support in the DNS client, strict reply checks, a decision on
  pinning operator addresses, and a rule for when an echo is believed (two independent operators
  agreeing, or only alongside a STUN answer).

### IPv6 hardening
Remaining v6 follow-ups: happy-eyeballs racing (RFC 8305), v6-capable CI runner. Detailed plan in [`docs/IPV6.md`](docs/IPV6.md).

### Swift 6.4 adoption pass
**Goal**: Take the 6.4 concurrency ergonomics where they simplify teardown, and stay warning-clean.

- **Gate met**: Swift 6.4 has shipped (Swift 6.4.2 with Xcode 27.2 as of 2026-11-21). A clean
  debug build under 6.4.2 on that date produced no compiler warnings.
- **SE-0520 warning triage**: compile under 6.4 and address new warnings on discarded throwing
  Tasks (grep on 2026-08-31 found most Task creations assigned or inside task groups, so
  expected fallout is small). Consider typed-throws `Task` where it clarifies error contracts.
- **SE-0493 async `defer` + SE-0504 `withTaskCancellationShield`**: candidates for socket
  close/drain paths where cancellation must not skip cleanup (`TraceHandle` cancellation,
  blocking-IO teardown). Adopt only where they replace existing multi-exit-path cleanup
  boilerplate, not wholesale.
- **SE-0518 `~Sendable`**: consider explicit sendability annotations on public types to lock
  the "all public types are Sendable" contract into the source rather than inference.
- **SE-0509 SBOM**: add `swift package generate-sbom` to the release checklist.
- **Constraint**: raising `swift-tools-version` above 6.0 raises the minimum toolchain for
  every consumer. Any adoption that forces a bump is a deliberate,
  consumer-visible decision, not a side effect.

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
