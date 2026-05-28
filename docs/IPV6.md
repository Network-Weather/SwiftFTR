# IPv6 Support in SwiftFTR

Forward-looking plan for full IPv6 feature parity in SwiftFTR. Updated as stages land.

## Goal & non-goals

**Goal**: Feature parity with the existing IPv4 surface across `ping`, `trace`, TCP/UDP/HTTP probes, STUN, and ASN classification — without breaking the `String`-based public API that callers (notably [NetworkWeather](https://networkweather.com)) already depend on.

**Non-goals**:
- 6to4 / Teredo / ISATAP — native v4/v6 only.
- Dedicated IPv6-only build mode — SwiftFTR remains dual-stack.
- Dropping or de-emphasizing IPv4 support.

## Architectural principles

All of these are NWX downstream contracts. Changing any of them in a stage past Stage 1 requires explicit alignment.

- **Single dest-string entry point.** `tracer.ping(to: "1.1.1.1")` and `tracer.ping(to: "2606:4700:4700::1111")` both go through the same `ping(to:config:)` method. The library detects the family from the resolved address and dispatches. No `pingV4`/`pingV6` API split.
- **`PreferredFamily` opt-in.** Optional `preferredFamily: .v4 | .v6 | .auto` (default `.auto`) on `PingConfig` (and later `SwiftFTRConfig`). `.auto` uses the literal's family for IP literals and the first `getaddrinfo(AF_UNSPEC)` answer for hostnames.
- **Canonical-form contract.** Every address SwiftFTR emits (`PingResult.resolvedIP`, `TraceHop.ipAddress`, `ParsedICMP.sourceAddress`) is the `inet_ntop` canonical form. Round-tripping `String → resolve → String` is stable for any input. NWX uses these strings as dictionary keys; inconsistency would silently break lookups.
- **Link-local scope IDs preserved.** When a hop or reply source is link-local (`fe80::/10`), the emitted string includes the zone suffix (`fe80::xxxx%en0`) via `if_indextoname(sin6_scope_id)`. Never strip. Multiple link-local hops on different interfaces must not collide on string keys.
- **Hop limit in the same `ttl` field.** `PingResponse.ttl: Int?` carries the IPv4 TTL for v4 replies and the IPv6 hop limit for v6 replies. Same field, same units (1–255). No new `hopLimit` field added.
- **Interface binding works identically.** `SwiftFTRConfig(interface: "en0")` binds v6 sockets via `IPV6_BOUND_IF` and produces source-address-selected output on that interface, mirroring the v4 `IP_BOUND_IF` path.
- **Concurrent-ping safety.** Each `ping()` call allocates its own ephemeral socket — no shared identifier/sequence space, safe to call concurrently from a shared `SwiftFTR` instance.
- **Unprivileged sockets only.** `SOCK_DGRAM IPPROTO_ICMPV6` (no setuid, no entitlements) — same model as the existing v4 `SOCK_DGRAM IPPROTO_ICMP` path. Documented if a stage ever needs a raw socket.
- **Family-agnostic errors.** Single `TracerouteError` covers both families; cases like `.resolutionFailed`, `.bindFailed`, `.sendFailed` apply equally to both. Family captured in error context, not in the error type.

## Sequenced stages

Independently shippable PRs, in priority order. Each stage builds on the patterns the previous stages established.

### Stage 1 — `ping()` over ICMPv6 *(shipped first in this trajectory)*

- ICMPv6 codec (`makeICMPv6EchoRequest`, `parseICMPv6Message`) alongside the existing v4 in `ICMP.swift`.
- Dual-stack `resolveHost(host:prefer:)` in `Ping.swift` returning `ResolvedHost { family, sockaddr_storage, canonical }`.
- `AF_INET6 / SOCK_DGRAM / IPPROTO_ICMPV6` socket creation with `IPV6_UNICAST_HOPS` (outgoing) and `IPV6_RECVHOPLIMIT` (so the kernel delivers hop limit on `recvmsg` as ancillary data).
- `applyBindings` honors `IPV6_BOUND_IF` for v6 interface binding and `parseIPv6Scoped` for link-local source IP.
- `PingOperation.handleRead` uses `recvmsg` for v6 (to extract the hop-limit cmsg) and the existing `recvfrom` for v4.
- New `PreferredFamily` enum and `PingConfig.preferredFamily` field.
- Spike executable `Tests/TestSupport/icmpv6probe/` validates Darwin's SOCK_DGRAM ICMPv6 behavior before the integration code depends on it.
- Unit tests for the v6 parser on synthetic buffers (always run, no network).
- Network-gated integration test (`testIPv6PingReachable`) cross-checking against `/sbin/ping6`.
- `IPv6Reachability` gate so v6 tests skip cleanly on v4-only CI runners.

### Stage 2 — Traceroute over ICMPv6

- ICMPv6 Time Exceeded handling in `Traceroute.swift`'s two receive paths (currently at lines ~1335 and ~1562).
- Embedded IPv6 + ICMPv6 packet parsing for Time Exceeded / Destination Unreachable — different layout from v4 (fixed 40-byte v6 header, no IHL field; reuses the parser added in Stage 1).
- `IPV6_UNICAST_HOPS` cycling per probe (analogue of v4's `IP_TTL` cycling).
- Streaming v6 traceroute (`StreamingTrace.swift`).
- Flip `StressTests.testIPv6TraceStillUnsupported` to assert success.
- Cross-check against `/usr/sbin/traceroute6 2606:4700:4700::1111`.
- **`VPNContext.forInterface(_:)` and `TraceClassifier` need to handle dual-stack-source / v4-only-tunnel.** NWX's `SplitTunnelManager` and `TopologyDiscoveryManager` both pass a `VPNContext` to `traceClassified`. When the tunnel interface (typically a `utun*`) is v4-only but the physical interface is dual-stack, a v6 trace bound to `en0` will traverse a different path than `VPNContext` was constructed to describe. The classifier needs to know which family each hop carried and resolve the VPN-vs-direct decision per-hop rather than once-per-trace. This is the place where most real-world VPN setups will surface dual-stack edge cases — flagged here so Stage 2 doesn't ship a v6 trace that silently misclassifies.

### Stage 3 — TCP / UDP probes over IPv6

- Dual-stack `resolveHostname` in `TCPProbe.swift` and `UDPProbe.swift` (currently both `AF_INET`-only at file scope).
- `sockaddr_in6` `connect()` paths for both.
- HTTPProbe needs no work — `URLSession` is already v6-aware via the OS resolver.
- Probe integration tests gain v6 cases under the same `IPv6Reachability` gate.

### Stage 4 — STUN over IPv6 + dual-stack public-IP discovery

- Add v6 STUN servers to the rotation in `STUN.swift` (Cloudflare's STUN servers are reachable over v6).
- Surface separate v4 / v6 public IPs (or a merged set) from the classifier. May require an additive `PublicIP` struct.
- `TraceClassifier`'s VPN detection logic needs to handle v6 hops — straightforward since address classification is already string-based.

### Stage 5 — Resolver consolidation

Pure refactor, no behavior change. Replace the 4 duplicated `resolveIPv4` / `resolveHostname` helpers (`Ping.swift`, `Traceroute.swift`, `TCPProbe.swift`, `UDPProbe.swift`) with one dual-stack helper in `Utils.swift` or a new `Hostname.swift`. Trivially-reviewable once every caller path is already v6-aware.

### Stage 6 — `swift-ip2asn` 0.4.0 + IPv6 ASN labels

- Bump `swift-ip2asn` floor to `0.4.0` (dual-stack `UltraCompactDatabase.lookup`).
- Switch `RemoteDatabase` URL to `https://pkgs.networkweather.com/db/ip2asn-v2.ultra` (dual-stack DB; legacy v4-only file stays at `/db/ip2asn.ultra` for older clients).
- Verify `LocalASNResolver` returns sane ASNs for v6 hops on real traces.
- This is the stage that completes the 0.13.0 release train.

### Stage 7 — Hardening

- Add a CI matrix entry for a v6-capable runner (self-hosted, or GitHub's `larger-resource` runners when they offer v6).
- Enable `testIPv6PingReachable` and the v6 trace integration tests on that runner.
- Extend `icmpfuzz` to fuzz the v6 parsers.
- v6 variant of `ResourceBenchmark` (memory and per-call cost).
- Audit `getaddrinfo` AF_UNSPEC behavior under DNS64 environments (NAT64 transparency — see "Known limitations" below).

## Testing strategy

- **Pure-unit parser tests always run.** Synthetic buffers exercise the wire-format edge cases. No network reachability required; pass on any CI runner.
- **Network-gated tests use `NetworkTestGate.shared.withPermit`** to bound concurrent network I/O across the suite.
- **v6 tests additionally use `IPv6Reachability.isAvailable()`** — the test is enabled only when both `SKIP_NETWORK_TESTS` is unset *and* a real v6 path is detected. Skip is silent and explicit.
- **Cross-checks fail closed.** When SwiftFTR loss exceeds a threshold and the `/sbin/ping6` cross-check is unavailable (or its output can't be parsed), the test fails via `Issue.record` rather than silently passing on missing evidence.

### Environment variables

| Variable | Effect |
|---|---|
| `PTR_SKIP_STUN=1` | Skip STUN public-IP discovery (used in tests for isolation) |
| `SKIP_NETWORK_TESTS=1` | Skip all tests that touch the network (any family) |
| `SKIP_IPV6_TESTS=1` | Force-skip v6 integration tests (e.g. to test the skip path locally) |
| `FORCE_IPV6_TESTS=1` | Force-run v6 integration tests without probing (use only if your environment is guaranteed) |

## CI/CD considerations

GitHub-hosted macOS runners do **not** have public IPv6 reachability today. The v6 integration tests will skip cleanly there via `IPv6Reachability.isAvailable() == false`. Other test surfaces (unit tests, parser tests, v4 integration tests) run unaffected.

To exercise the v6 paths in CI:

- **Recommended**: a self-hosted macOS runner on a dual-stack network. The existing matrix can gain a `runs-on: self-hosted` row that picks up the v6 tests automatically (no env-var changes needed — the reachability probe just succeeds).
- **Alternative**: GitHub's `larger-resource` macOS runners if/when they offer v6 — at the time of writing they do not.
- **Local development**: the spike (`swift run icmpv6probe 2606:4700:4700::1111`) is the single most useful diagnostic; if it fails, integration tests will too. Cloudflare WARP provides a workable v6 path on otherwise v4-only home networks.

## Known limitations & open questions

- **NAT64 transparency** (Stage 7): `ping(to: "1.1.1.1")` on a pure-v6 network with DNS64/NAT64 should "just work" via the gateway's synthesized v6 address (typically under `64:ff9b::/96`). Stage 1 doesn't implement this — a v4 literal is treated as v4 and creates a v4 socket. Workaround: pass the hostname, not the literal. The `getaddrinfo(AF_UNSPEC)` path will return the NAT64-synthesized v6 address transparently.
- **Happy-eyeballs**: `.auto` for hostnames currently takes the first `getaddrinfo` answer without racing v4 and v6 connects. RFC 8305 happy-eyeballs is deferred — most callers either pin a family (`.v4` / `.v6`) or accept the OS's resolver preference.
- **Should the `ttl` field on `PingResponse` become `hopCount` (or split into a separate `hopLimit`)?** Currently overloaded: v4 TTL or v6 hop limit. Documented dual meaning. Splitting would be source-breaking; revisit only if it causes real consumer confusion.

## Known-good v6 test endpoints

NWX-validated, used in SwiftFTR's tests and the spike:

- `2606:4700:4700::1111` — Cloudflare DNS (the v6 1.1.1.1).
- `2606:4700:4700::1001` — Cloudflare DNS secondary.
- `2001:4860:4860::8888` — Google DNS.
- `2001:4860:4860::8844` — Google DNS secondary.

For local-loop and link-local testing:

- `::1` — loopback. **Caveat**: Darwin returns the Echo *Request* unchanged (type 128) on loopback rather than synthesizing an Echo Reply (type 129). Integration tests prefer a non-loopback target.
- `fe80::1%en0` — link-local on a specific interface, for `interface:` binding tests.

## References

- [RFC 4443 — ICMPv6](https://datatracker.ietf.org/doc/html/rfc4443) (Echo Request 128, Echo Reply 129, Destination Unreachable 1, Time Exceeded 3)
- [RFC 791 §3.1](https://datatracker.ietf.org/doc/html/rfc791#section-3.1) (IPv4 TTL field) and [RFC 8200 §3](https://datatracker.ietf.org/doc/html/rfc8200#section-3) (IPv6 Hop Limit field)
- [RFC 3542](https://datatracker.ietf.org/doc/html/rfc3542) — Advanced Sockets API for IPv6 (the `IPV6_HOPLIMIT` cmsg type)
- [RFC 8305](https://datatracker.ietf.org/doc/html/rfc8305) — Happy Eyeballs v2 (deferred)
- [RFC 6147](https://datatracker.ietf.org/doc/html/rfc6147) — DNS64 (relevant to NAT64 transparency)
