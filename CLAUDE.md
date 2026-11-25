# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Common Development Commands

### Build & Test
```bash
# Build debug
swift build -c debug

# Build release (optimized)
swift build -c release

# Run all tests without live-network integration tests
SKIP_NETWORK_TESTS=1 PTR_SKIP_STUN=1 swift test -c debug

# Run specific test
swift test --filter ComprehensiveIntegrationTests/testClassifiedTrace

# Build CLI executable
swift build -c release --product swift-ftr
```

### Code Quality
```bash
# Check formatting (required before push)
swift format lint --strict -r Sources Tests

# Auto-format code
swift format format --in-place -r Sources Tests
```

### API compatibility
```bash
# Fails on any source break against the last release that the allowlist does not name
# (one exact diagnostic per line, as the tool prints it; no comments). CI runs the same, on
# Xcode 26.3 rather than the minimum toolchain: Swift 6.1.2's command reports every public
# declaration as removed. CI also runs it without the allowlist and requires exactly the
# allowlisted breaks, so the check is shown to discriminate.
swift package diagnose-api-breaking-changes v0.18.1 --products SwiftFTR \
  --breakage-allowlist-path "$PWD/api-breakage-allowlist.txt"
```

### Documentation
```bash
swift package --allow-writing-to-directory docc \
  generate-documentation --target SwiftFTR \
  --output-path docc --transform-for-static-hosting \
  --warnings-as-errors
```

## Architecture Overview

SwiftFTR is a fast, parallel traceroute library for macOS using ICMP datagram sockets (no sudo). It also provides ping, TCP/UDP/DNS/HTTP probing, multipath discovery, and streaming traceroute APIs.

### Core Components

**SwiftFTR Actor** (`Sources/SwiftFTR/Traceroute.swift`)
- Main `actor` coordinating all operations; thread-safe without `@MainActor`
- Manages active traces via `TraceHandle` for cancellation support
- Public APIs: `trace()`, `traceClassified()`, `traceStream()`, `ping()`, `discoverPaths()`, plus probe APIs
- `networkChanged()` cancels active traces and clears the public-IP and rDNS caches (not the ASN cache); finer controls: `cancelActiveTraces()`, `invalidatePublicIP()`, `invalidateNetworkScopedRDNS()`, `seedPublicIP(_:source:)`

**ICMP Module** (`Sources/SwiftFTR/ICMP.swift`)
- `SOCK_DGRAM` + `IPPROTO_ICMP` socket (no root required on macOS)
- Parallel probe: sends all TTL probes in one burst, listens with `DispatchSourceRead` (kqueue-backed)
- Monotonic clock (`CLOCK_MONOTONIC`) timing for accurate RTT
- `@_spi(Test)` exposes `__parseICMPMessage` for unit tests

**Public-IP Resolution** (`Sources/SwiftFTR/PublicIPResolver.swift`)
- `PublicIPResolver` protocol and `SwiftFTRConfig.publicIPResolver` strategy: `.library` (default; `LibraryPublicIPResolver` in `LibraryPublicIPResolver.swift`, STUN only, every socket bound before its server name is resolved; `getPublicIPs` and `discoverPublicIPWithHostname()` ask it too), `.disabled`, `.custom(_:)`
- A classified trace asks once, after its probes, for the family they used: configured address of that family, then seed or cache of that family, then the strategy
- `askWithinDeadline` holds a caller's resolver to the request deadline with a single-resume race; every answer is checked for global scope and family

**Classification System** (`Sources/SwiftFTR/Segmentation.swift`)
- `TraceClassifier` categorizes hops: LOCAL, ISP, TRANSIT, VPN, DESTINATION
- Hole-filling algorithm interpolates missing hops between identical segments
- VPN-aware classification for tunnel and exit node detection

**ASN Resolution** (`Sources/SwiftFTR/ASN.swift`, `HybridASNResolver.swift`, `LocalASNResolver.swift`)
- Multiple strategies via `ASNResolverStrategy`: `.dns` (Team Cymru), `.embedded` (SwiftIP2ASN local DB), `.remote(bundledPath:url:)`, `.hybrid(source, fallbackTimeout:)`
- `_ASNMemoryCache`: in-memory cache with 2048 entry capacity; caches only entries with an AS name
- `CymruDNSResolver`: Team Cymru TXT queries over `UDPExchange`, at most 8 in flight per resolve
- One deadline per `resolve`, taken on entry (`asnDeadline`, on `DiscoveryClock`) and passed down
  unchanged through the internal `PublishingASNResolver` method, which also publishes answers as
  they arrive. Shared work (cache flights, the database load) is a `SharedASNWork`
  (`SharedASNWork.swift`): run once on its own budget, never stopped by a waiter, which waits
  until it ends, its deadline or its cancellation and then reads a snapshot, forwarding what the
  work publishes meanwhile to its own publisher (so stacked resolvers hear it). A passed deadline
  starts nothing but returns what is known without I/O

**Probe Modules** — each in its own file:
- `Ping.swift`: ICMP echo with statistics (min/avg/max RTT, jitter, packet loss)
- `TCPProbe.swift`: Port state detection (open/closed/filtered)
- `UDPProbe.swift`: Connected-socket with ICMP unreachable detection
- `DNS.swift`: Direct server queries with 11 record types over `UDPExchange`; `@_spi(Test)` exposes `__dnsQuery` and `__dnsEncodeQName`. Every query is event-based
- `UDPExchange.swift`: One UDP request/response on a non-blocking connected socket, waited on by Dispatch sources and a deadline timer; holds no thread
- `HTTPProbe.swift`: Web server reachability via URLSession
- `StreamingTrace.swift`: `AsyncThrowingStream`-based real-time hop delivery
- `Multipath.swift`: Dublin Traceroute-style ECMP path enumeration

**Caching Infrastructure**
- `RDNSCache` (`RDNSCache.swift`): Reverse DNS with 86400s TTL
- `ReverseDNSLookup` (`ReverseDNSLookup.swift`): one PTR query through `DNSServiceQueryRecord`, holding no thread, with typed outcomes and a cap on lookups in flight; not yet used by `RDNSCache`, which still calls `getnameinfo` on the executor
- `SwiftFTR.publicIPCache`: One `PublicIPObservation` per address family, with its source, for classified trace/multipath; invalidated on network change
- `_ASNMemoryCache` (in `ASN.swift`): LRU-style IP-to-ASN cache

### Key Design Patterns

1. **Actor-based Concurrency**: `SwiftFTR` is an `actor`, thread-safe from any context
2. **Cancellation**: Via `TraceHandle` per-trace or `networkChanged()` globally
3. **Dependency Injection**: Resolvers (ASN, DNS) are injectable via `SwiftFTRConfig` for testing
4. **Per-Operation Interface Binding**: Override global interface on individual operations (ping, trace, etc.)
5. **Resource Management**: Single socket per trace, buffer reuse, minimal allocations
6. **Blocking I/O**: `BlockingIOExecutor` (`Utils.swift`, eight workers) carries reverse DNS (`getnameinfo`) and STUN server-name resolution (`getaddrinfo`, one request per name, its wait bounded by the discovery deadline and 20 s). STUN exchanges run on `UDPExchange`, every server at once, and hold no slot; DNS queries, DNS probes and Team Cymru lookups do not use it either

## Environment Variables

| Variable | Effect |
|---|---|
| `PTR_SKIP_STUN=1` | Skip the public-IP integration-test subset using this legacy gate; no runtime effect |
| `SKIP_NETWORK_TESTS=1` | Skip the remaining live-network tests; set both variables for an offline run |
| `SKIP_IPV6_TESTS=1` / `FORCE_IPV6_TESTS=1` | Force-skip or force-run the IPv6 integration tests instead of probing for a v6 path |
| `SWIFTFTR_VERBOSE_HTTP_TIMING=1` | Verbose HTTP probe timing logs |
| `SWIFTFTR_DEBUG_MULTIPATH` | Debug output for multipath discovery |
| `SWIFTFTR_RDNS_DESCRIPTOR_STRESS=1` | Also run the reverse-lookup descriptor experiment: the child process lowers its descriptor limit to what is open plus the cap plus two. A measurement that can fail on a valid ordering, so off by default |

## Swift 6 Compliance

- Swift tools version 6.0, language mode Swift 6 (`swiftLanguageModes: [.v6]`)
- Requires Swift 6.1+ / Xcode 16.4+, macOS 13+
- All public types are `Sendable`; no `@MainActor` requirements

## Testing Notes

- **Offline runs**: Use `SKIP_NETWORK_TESTS=1 PTR_SKIP_STUN=1` for deterministic test runs
- **`NetworkTestGate`**: Actor-based concurrency limiter in tests that perform real network I/O
- **Public-IP tests**: The legacy suite is split across both test gates; set both for an offline run
- **ICMP on CI**: Network traces do NOT work on GitHub cloud runners; integration tests require self-hosted runners or local execution
- Tests should not assume specific hop counts, ASN assignments, or that TRANSIT segments exist

## Coding Conventions

- **Formatting**: `swift-format` enforced; pre-push hook at `.githooks/pre-push` (enable with `git config core.hooksPath .githooks`)
- **Naming**: camelCase with documented exceptions:
  - snake_case JSON properties in `Sources/swift-ftr/main.swift` (public API backward compat)
  - `LLVMFuzzerTestOneInput` (libFuzzer requirement)
  - `__`-prefixed `@_spi(Test)` helpers (internal testing exposure)
- **Commits**: Conventional Commits with scopes (`feat(tracer):`, `fix(dns):`, `docs:`)
- **Dependencies**: SwiftPM only — `swift-argument-parser`, `swift-docc-plugin`, `swift-ip2asn`

## Downstream contracts

SwiftFTR has production consumers whose integrations depend on contracts that are easy to break silently: single dest-string entry points, canonical `inet_ntop` address form, link-local zone-suffix preservation, family-agnostic errors, concurrent-ping safety, unprivileged sockets only. For non-trivial API changes, surface the relevant constraints up front in your plan, not during PR review.

A downstream application may be named. Never link or path-reference its private repositories,
and never disclose private information about a consumer: source paths, line numbers, commit
hashes, infrastructure identifiers, customer or usage details. Strip those when recording field
evidence here. (David, 2026-11-22, relaxing the earlier rule that the application itself must not
be named.)

## CI runs on GitHub-hosted runners

This repository is public and accepts pull requests from forks, so its workflows run on
GitHub-hosted macOS runners, never on a self-hosted one: a self-hosted runner would execute a
stranger's pull-request code on a private machine. This is a deliberate exception to the general
rule that CI runs on self-hosted runners. Do not add `runs-on: self-hosted` (or a self-hosted
label) to any workflow here. (David, 2026-11-22.)

## Size the pull request, not just the commits

Plan PR boundaries before the work starts. One Codex review pass covers about 2,000 changed
lines (the `codex-review` wrapper stops above that), so a larger PR cannot be reviewed as a
whole however small its commits are, and its tests and seams go unreviewed. Name the slices up
front (for example: seams and fixtures; tests of existing behavior; each group of fixes with its
tests), open them as stacked PRs, and land each before the next builds on it. Check
`git diff --shortstat` against the base before opening a PR. Put the cap and the slice plan in
every subagent brief: an agent asked for "a branch and a draft PR" will deliver one of each.
(David, 2026-11-21, after the documentation sweep and the fault-injection battery both arrived
as single PRs of about 2,500 lines.)

## After every PR merges

1. Fast-forward main, remove the worktree, delete the local + remote branch.
2. Update `ROADMAP.md` to drop items the PR completed. ROADMAP is forward-only and stack-ranked; no version numbers, no "current state" sections (see `feedback-roadmap-style` memory).
3. Update `CHANGELOG.md` so `Unreleased` reflects what's actually merged. Strip stale "deferred" notes that the PR resolved (see `feedback-changelog-roadmap-discipline` memory).

## When cutting a release

- Consolidate the per-PR `Unreleased` entries into a single coherent release-notes section organized by **user-visible value** (e.g. "New public API", "Behavior changes", "Bug fixes", "Tooling", "Dependencies"), not by implementation stage. The CHANGELOG ships to API consumers; they don't care about your stage numbering.
- Bump `Sources/SwiftFTR/Version.swift`.
- Tag the release-prep merge commit (not the prep commit itself, so the tag points at a stable mainline commit).
- `gh release create v<version>` with notes drawn from the consolidated CHANGELOG section.

## Plan-mode plan file

For non-trivial implementation tasks, the plan file under `~/.claude/plans/` is per-session scratch. For multi-PR efforts spanning sessions, the canonical sequenced plan lives in the repo under `docs/<EFFORT>.md` (e.g. `docs/IPV6.md` for the v6 parity work). Strikethrough completed stages as they ship.
