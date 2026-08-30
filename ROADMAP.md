# SwiftFTR Roadmap

Forward-looking work, stack-ranked top-to-bottom by priority. For what has already shipped, see [CHANGELOG.md](CHANGELOG.md).

## Priority Queue

### Retry transient send errors instead of aborting the trace
**Goal**: A momentarily full send buffer must not destroy an entire traceroute.

- **Problem**: The trace socket is non-blocking, and all `maxHops` probes are sent in one
  unpaced burst. `sendTraceProbe` throws `TracerouteError.sendFailed(errno:)` on any
  negative `sendto` return, so a single `EAGAIN` — the kernel saying "buffer full, try
  again in a moment" — aborts the whole measurement. This is the most common traceroute
  failure in NWX production telemetry (~80 events/week across at least 4 clients).
- **Approach**: Classify `EAGAIN`/`EWOULDBLOCK`/`ENOBUFS` as transient and retry them
  against a budget shared across the whole burst, not per-probe — with `maxHops: 40` and
  `maxWaitMs: 1000` as defaults, a per-probe budget would blow the receive deadline.
  Wait for writability with `poll(POLLOUT)`; `ENOBUFS` reflects the interface queue rather
  than the socket buffer, so it needs a short sleep instead, as `poll` reports the socket
  writable immediately.
- **Every other errno keeps failing fast.** NWX maps `EHOSTUNREACH`, `ENETDOWN`, and
  `ENETUNREACH` to offline states it acts on, and must keep receiving them promptly.
- **On budget exhaustion, throw as today.** Degrading to a skipped probe is the better
  end state but is not safe to ship until a caller can distinguish "we never sent" from
  "the router ignored us" — see the hop outcome model below, which unblocks it.
- **Also**: audit the ping send path. It does not abort, but it silently drops the probe
  on any send error, so transient pressure quietly shrinks the sample rather than
  reporting anything.
- **Acceptance**: a test that forces the condition deterministically (shrink `SO_SNDBUF`
  via `setsockopt`, then send a burst) fails before the change and passes after.

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
- **Unblocks**: skipping a probe whose send budget is exhausted, rather than failing the
  trace, because `.notSent` makes the skip legible instead of a phantom unresponsive hop.

### Bounded, cancellable enrichment
**Goal**: `traceClassified()` completes, or throws, within a bound derived from its own
configuration — and honors cancellation while doing it.

- **Problem**: 5 distinct clients tripped NWX's 60-second watchdog (~10 occurrences).
  The probe path is not at fault: every exit path of both receive operations resumes its
  continuation exactly once, and cancellation during the probe phase terminates in ~0.105s
  with no leaked socket. The exposure is the enrichment phase — STUN, per-hop rDNS, and
  ASN lookups all run as blocking operations on one process-global 8-slot
  `BlockingIOExecutor`, which has three compounding properties:
  1. **Cancellation is not honored.** Queued operations are not removed when a task is
     cancelled, and a running syscall is never interrupted. A `traceClassified` cancelled
     at 0.1s was measured returning at 5.49s — exactly when an executor slot freed. That
     is the field signature: the watchdog fires, the task stays suspended.
  2. **No SwiftFTR deadline on `getaddrinfo` (3 STUN hostnames) or `getnameinfo`
     (per hop).** Only the STUN and DNS *sockets* set `SO_RCVTIMEO`.
  3. **Priority inversion.** rDNS enqueues at background priority while probe, ASN, and
     STUN work enqueues higher; `OperationQueue` serves strictly by priority. A background
     operation submitted first was measured running only after 24 later, higher-priority
     operations (2.19s against a ~0.7s FIFO prediction). A host app issuing continuous
     probe traffic defers an in-flight trace's rDNS phase without bound.
- **Why it lands on real users**: NWX clears `cachedPublicIP` and its rDNS caches on every
  network change, so the first trace after a transition — exactly when a resolver is most
  likely degraded — always runs full STUN discovery plus a cold rDNS wave.
- **Approach**:
  - Give every blocking primitive its own deadline. rDNS can stop calling `getnameinfo`
    altogether and use the in-package `DNSClient` PTR path, which already sets a socket
    timeout. Resolve STUN hostnames the same bounded way, or ship literal addresses with
    a hostname fallback.
  - Make `runDetachedBlockingIO` cancellation-aware for at least not-yet-started
    operations, and check `Task.isCancelled` between enrichment steps so a cancelled trace
    stops enqueueing further work.
  - Revisit executor sizing and the rDNS/probe priority inversion so one slow category
    cannot absorb the queue.
- **Acceptance**: `traceClassified` returns or throws within a configuration-derived bound
  under network blackhole, blackhole during STUN, mid-trace interface loss, and executor
  saturation; a cancelled trace terminates promptly in the enrichment phase as it already
  does in the probe phase.
- **Open measurement**: the stall magnitude of a single `getaddrinfo`/`getnameinfo`
  against a dead resolver is still unmeasured; it needs a pf rule blocking port 53 and
  therefore sudo. Worst-case arithmetic in
  [`docs/BUG2-INVESTIGATION.md`](docs/BUG2-INVESTIGATION.md) is parameterized on it.
- **Cheapest open discriminator, NWX-side**: `log.*` telemetry carries no `app_version`,
  so it is not yet possible to tell whether the reporting clients predate the NWX 1.3.0
  fix for its own cooperative-thread-pinning SSDP loop. Adding that field settles whether
  any residual host-app contribution remains.

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
