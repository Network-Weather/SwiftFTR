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
- **Link-local scope IDs preserved.** When a hop or reply source is link-local (`fe80::/10`), the emitted string includes the operating system's zone suffix (`fe80::xxxx%interface-name`) via `if_indextoname(sin6_scope_id)`. Never strip. Multiple link-local hops on different interfaces must not collide on string keys.
- **Hop limit in the same `ttl` field.** `PingResponse.ttl: Int?` carries the IPv4 TTL for v4 replies and the IPv6 hop limit for v6 replies. Same field, same units (1–255). No new `hopLimit` field added.
- **Interface binding works identically.** Passing a name returned by `NetworkInterfaceDiscovery` to `SwiftFTRConfig(interface:)` binds v6 sockets via `IPV6_BOUND_IF` and produces source-address-selected output on that interface, mirroring the v4 `IP_BOUND_IF` path.
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

### ~~Stage 2 — Traceroute over ICMPv6~~ *(shipped)*

Now ships v6 trace, traceClassified, and traceStream via the same entry points as v4. ICMPv6 Time Exceeded handling in both receive paths reuses Stage 1's `parseICMPv6Message`. `IPV6_UNICAST_HOPS` replaces `IP_TTL` for hop cycling, and `IPV6_RECVHOPLIMIT` cmsg surfaces the reply hop limit. File-scope dual-stack helpers (`createTraceSocket`, `setTraceHopLimit`, `recvTraceMessage`, etc.) keep `Traceroute.swift` readable. Spike `traceroute6probe` empirically validated Time Exceeded delivery and embedded-packet parsing against real intermediate routers before integration.

**Folded in from former Stage 6**: `swift-ip2asn` bumped to 0.4.0; `CymruDNSResolver` gained v6 lookups via `origin6.asn.cymru.com` with a new `reverseIPv6Nibbles` helper. v6 hops now get full `[AS… - ASNAME]` annotations identically to v4 traces.

**`VPNContext.vpnLocalIPs` is now populated** (shipped in PR #21 as part of v0.13.0 hardening): `VPNContext.forInterface(_:)` walks `getifaddrs` and collects every v4 and v6 address bound to a VPN-shaped interface (`utun*`, `ipsec*`, `ppp*`, `tun*`, `tap*`, `wg*`, `gpd*`, `ztun*`). The classifier now tags hops that land on a VPN local IP as `.vpn` rather than `.transit`. v6 link-local entries keep their `%zone` suffix so set membership matches what the parsed hops look like.

### ~~Stage 3 — TCP / UDP probes over IPv6~~ *(shipped)*

Dual-stack `tcpProbe(...)` and `udpProbe(...)`: same entry points work for both families, family detected at resolve time, `PreferredFamily` on both configs. `IPV6_BOUND_IF` for v6 interface binding, link-local `%zone` source-IP suffixes preserved. The shared `bindProbeSourceIP` helper in `Hostname.swift` is used by both probes. `HTTPProbe` was already v6-aware via `URLSession` — no work needed. New `testTCPProbeIPv6` / `testUDPProbeIPv6` integration tests gated on `IPv6Reachability`.

### ~~Stage 4 — STUN over IPv6 + dual-stack public-IP discovery~~ *(shipped)*

`STUN.swift` is now dual-stack via a family-parameterized core (`stunGetPublicIP(family:host:port:...)`) that resolves, sockets, binds, sends, and parses XOR-MAPPED-ADDRESS for both v4 (Family 0x01) and v6 (Family 0x02) per RFC 5389 §15.2 — including the v6-specific un-XOR of bytes 4..15 against the transaction ID. `STUNPublicIP` gained a `family` field; new `PublicIPs { v4, v6 }` struct and `public func getPublicIPs() async -> PublicIPs` run both families in parallel via `async let` and return whichever succeeded (never throws). v6 source-IP binding reuses the family-aware `bindProbeSourceIP` helper introduced in Stage 3. Back-compat shims for `stunGetPublicIPv4*` and `getPublicIPv4`; new `stunGetPublicIPv6*` companions added.

### ~~Stage 5 — Resolver consolidation~~ *(shipped)*

`Hostname.swift` is now the single source of truth for: dual-stack `resolveHost(host:prefer:)`, family-aware `bindSourceIP(sockfd:family:sourceIP:)` (renamed from `bindProbeSourceIP`), and new `bindInterface(sockfd:family:ifIndex:)`. The old v4-only `resolveIPv4` in `Traceroute.swift` was deleted after `Multipath.swift` (the last caller) migrated to `resolveHost(host:, prefer: .v4)`. `bindTraceInterface` / `bindTraceSourceIP` became thin wrappers that translate the string-error contract to the typed `TracerouteError` cases trace callers expect. TCP, UDP, STUN all call the shared helpers directly.

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
| `PTR_SKIP_STUN=1` | Skip legacy STUN integration tests; the library runtime ignores it |
| `SKIP_NETWORK_TESTS=1` | Skip non-STUN live-network tests; combine with `PTR_SKIP_STUN=1` for an offline run |
| `SKIP_IPV6_TESTS=1` | Force-skip v6 integration tests (e.g. to test the skip path locally) |
| `FORCE_IPV6_TESTS=1` | Force-run v6 integration tests without probing (use only if your environment is guaranteed) |

## CI/CD considerations

GitHub-hosted macOS runners do **not** have public IPv6 reachability today. The v6 integration tests will skip cleanly there via `IPv6Reachability.isAvailable() == false`. Other test surfaces (unit tests, parser tests, v4 integration tests) run unaffected.

To exercise the v6 paths in CI:

- **Recommended**: a self-hosted macOS runner on a dual-stack network. The existing matrix can gain a `runs-on: self-hosted` row that picks up the v6 tests automatically (no env-var changes needed — the reachability probe just succeeds).
- **Alternative**: GitHub's `larger-resource` macOS runners if/when they offer v6 — at the time of writing they do not.
- **Local development**: the spike (`swift run icmpv6probe 2606:4700:4700::1111`) is the single most useful diagnostic; if it fails, integration tests will too. Cloudflare WARP provides a workable v6 path on otherwise v4-only home networks.

## Known limitations & open questions

- ~~**NAT64 transparency**: `ping(to: "1.1.1.1")` on a pure-v6 network with DNS64/NAT64~~ *(shipped)*. In `.auto` mode (the default), v4 literals go through `getaddrinfo` with `AI_V4MAPPED | AI_ADDRCONFIG` flags so macOS synthesizes a v4-mapped v6 address when on a v6-only NAT64 network. Force modes (`.v4` / `.v6`) keep the `inet_pton` fast path. Dual-stack hosts see unchanged behavior.
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
- A link-local address with the zone returned by system metadata — for example, `fe80::1%interface-name` — for `interface:` binding tests. Do not infer the zone from a BSD name's numeric suffix.

## References

- [RFC 4443 — ICMPv6](https://datatracker.ietf.org/doc/html/rfc4443) (Echo Request 128, Echo Reply 129, Destination Unreachable 1, Time Exceeded 3)
- [RFC 791 §3.1](https://datatracker.ietf.org/doc/html/rfc791#section-3.1) (IPv4 TTL field) and [RFC 8200 §3](https://datatracker.ietf.org/doc/html/rfc8200#section-3) (IPv6 Hop Limit field)
- [RFC 3542](https://datatracker.ietf.org/doc/html/rfc3542) — Advanced Sockets API for IPv6 (the `IPV6_HOPLIMIT` cmsg type)
- [RFC 8305](https://datatracker.ietf.org/doc/html/rfc8305) — Happy Eyeballs v2 (deferred)
- [RFC 6147](https://datatracker.ietf.org/doc/html/rfc6147) — DNS64 (relevant to NAT64 transparency)
