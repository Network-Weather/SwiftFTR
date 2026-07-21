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
swift format lint -r Sources Tests

# Auto-format code
swift format format --in-place -r Sources Tests
```

### Documentation
```bash
swift package --allow-writing-to-directory docs \
  generate-documentation --target SwiftFTR \
  --output-path docs --transform-for-static-hosting --hosting-base-path SwiftFTR
```

## Architecture Overview

SwiftFTR is a fast, parallel traceroute library for macOS using ICMP datagram sockets (no sudo). It also provides ping, TCP/UDP/DNS/HTTP probing, multipath discovery, and streaming traceroute APIs.

### Core Components

**SwiftFTR Actor** (`Sources/SwiftFTR/Traceroute.swift`)
- Main `actor` coordinating all operations; thread-safe without `@MainActor`
- Manages active traces via `TraceHandle` for cancellation support
- Public APIs: `trace()`, `traceClassified()`, `traceStream()`, `ping()`, `discoverPaths()`, plus probe APIs
- `networkChanged()` invalidates all caches and cancels active traces

**ICMP Module** (`Sources/SwiftFTR/ICMP.swift`)
- `SOCK_DGRAM` + `IPPROTO_ICMP` socket (no root required on macOS)
- Parallel probe: sends all TTL probes in one burst, listens with `DispatchSourceRead` (kqueue-backed)
- Monotonic clock (`CLOCK_MONOTONIC`) timing for accurate RTT
- `@_spi(Testing)` exposes `__parseICMPMessage` for unit tests

**Classification System** (`Sources/SwiftFTR/Segmentation.swift`)
- `TraceClassifier` categorizes hops: LOCAL, ISP, TRANSIT, VPN, DESTINATION
- Hole-filling algorithm interpolates missing hops between identical segments
- VPN-aware classification for tunnel and exit node detection

**ASN Resolution** (`Sources/SwiftFTR/ASN.swift`, `HybridASNResolver.swift`, `LocalASNResolver.swift`)
- Multiple strategies via `ASNResolverStrategy`: `.dns` (Team Cymru), `.embedded` (SwiftIP2ASN local DB), `.remote(bundledPath:url:)`, `.hybrid(source, fallbackTimeout:)`
- `_ASNMemoryCache`: in-memory cache with 2048 entry capacity

**Probe Modules** — each in its own file:
- `Ping.swift`: ICMP echo with statistics (min/avg/max RTT, jitter, packet loss)
- `TCPProbe.swift`: Port state detection (open/closed/filtered)
- `UDPProbe.swift`: Connected-socket with ICMP unreachable detection
- `DNS.swift`: Direct server queries with 11 record types; `@_spi(Testing)` exposes `__dnsEncodeQName`
- `HTTPProbe.swift`: Web server reachability via URLSession
- `StreamingTrace.swift`: `AsyncThrowingStream`-based real-time hop delivery
- `Multipath.swift`: Dublin Traceroute-style ECMP path enumeration

**Caching Infrastructure**
- `RDNSCache` (`RDNSCache.swift`): Reverse DNS with 86400s TTL
- `SwiftFTR.cachedPublicIP`: Public-address enrichment for classified trace/multipath, invalidated on network change
- `_ASNMemoryCache` (in `ASN.swift`): LRU-style IP-to-ASN cache

### Key Design Patterns

1. **Actor-based Concurrency**: `SwiftFTR` is an `actor`, thread-safe from any context
2. **Cancellation**: Via `TraceHandle` per-trace or `networkChanged()` globally
3. **Dependency Injection**: Resolvers (ASN, DNS) are injectable via `SwiftFTRConfig` for testing
4. **Per-Operation Interface Binding**: Override global interface on individual operations (ping, trace, etc.)
5. **Resource Management**: Single socket per trace, buffer reuse, minimal allocations

## Environment Variables

| Variable | Effect |
|---|---|
| `PTR_SKIP_STUN=1` | Skip the public-IP integration-test subset using this legacy gate; no runtime effect |
| `SKIP_NETWORK_TESTS=1` | Skip the remaining live-network tests; set both variables for an offline run |
| `SWIFTFTR_VERBOSE_HTTP_TIMING=1` | Verbose HTTP probe timing logs |
| `SWIFTFTR_DEBUG_MULTIPATH` | Debug output for multipath discovery |

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
  - `__`-prefixed `@_spi(Testing)` helpers (internal testing exposure)
- **Commits**: Conventional Commits with scopes (`feat(tracer):`, `fix(dns):`, `docs:`)
- **Dependencies**: SwiftPM only — `swift-argument-parser`, `swift-docc-plugin`, `swift-ip2asn`

## Downstream consumer

NetworkWeather (NWX, `~/dev/nwx`) is the primary SwiftFTR consumer. For non-trivial API changes:

1. Read the `project-nwx-downstream-contracts` memory before designing. It captures the contracts NWX depends on (single dest-string entry points, canonical address form, link-local scope preservation, family-agnostic errors, concurrent-ping safety, unprivileged sockets only).
2. Surface the relevant constraints up front in your plan, not during PR review.
3. Save new constraints to that memory as you discover them.

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
