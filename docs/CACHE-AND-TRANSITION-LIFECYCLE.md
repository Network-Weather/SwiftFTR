# Cache and network-transition lifecycle

## Status

Implemented in 0.17.0, except for sharing an `RDNSCache` between tracer
instances, which is tracked in [ROADMAP.md](../ROADMAP.md). This document is
the design of record for the lifecycle contract: what the actor caches, what
invalidates it, and which controls callers get. Scope is the SwiftFTR library
contract only. How a caller decides *when* to invoke these controls — network
identity heuristics, revalidation policy, telemetry — is caller policy and out
of scope.

## Decision summary

A caller should keep a long-lived `SwiftFTR` actor for a measurement context.
A network transition must not require replacing that actor merely to cancel
active work or refresh cached discovery state.

The library's lifecycle controls are therefore independently callable:

- cancelling active traces: `cancelActiveTraces()`;
- invalidating the discovered public IP: `invalidatePublicIP()`;
- evicting only network-scoped rDNS entries: `invalidateNetworkScopedRDNS()`;
- seeding a validated public IP without suppressing discovery:
  `seedPublicIP(_:source:)`; and
- supplying a per-operation hop budget: `TraceOptions`.

`networkChanged()` remains the conservative composition — cancel every active
trace and invalidate the reverse-DNS cache and the public IP, though not the ASN
cache — for callers without finer-grained evidence.

## Current behavior

As of 0.18.0, in `Traceroute.swift`, `RDNSCache.swift`, `ASN.swift` and
`Utils.swift`.

- The public-IP cache holds one `PublicIPObservation` per address family (address, family,
  source), each with its own generation.
- `networkChanged()` bumps both public-IP generations, clears both cached public IPs,
  snapshots and cancels every registered operation (`trace`, `traceClassified`,
  `traceStream` and `discoverPaths`; each throws `TracerouteError.cancelled`), and
  clears the entire rDNS cache. It does not clear the ASN cache. `ping` and the
  probes are not registered and keep running.
- `clearCaches()` bumps both generations and clears both public IPs and the whole
  rDNS cache; `invalidatePublicIP()` bumps both generations and clears only the
  public IPs. Neither cancels traces.
- `SwiftFTRConfig.publicIP` is an immutable, authoritative override: when set to a
  globally routable address, classified traces of its family bypass public-IP
  discovery entirely. It is configuration, not a cache.
- A classified trace asks the `SwiftFTRConfig.publicIPResolver` strategy at most
  once, after its probes. An answer that arrives after an invalidation or a seed of
  its family, or after the request deadline, is neither returned nor cached
  (`effectivePublicIP(for:ask:)`, `askWithinDeadline`).
- `RDNSCache` holds entries for 86400 s, evicting the oldest-inserted entry at 1000 entries
  (both configurable through `SwiftFTRConfig`). It caches answers only: no such record, an
  error and a cancellation are asked again next time. An address whose question was asked and
  timed out (unicast or link-local) is held off for ten minutes (David, 2026-11-24: "10 minutes is a reasonable in-memory cache of no response for a reverse DNS lookup"): its lookup
  returns nil at once without asking and without touching the breaker. Holdoffs are bounded by
  the cache size (oldest inserted evicted), expire by the monotonic clock, and `clear()` and
  `invalidateNetworkScoped()` drop every one, global addresses included. It has a stall breaker:
  after two consecutive unicast lookups of different addresses that were asked and got no answer
  by their deadline, further lookups are suppressed while that count stays at two or more (one
  address counts once per run of stalls, proposed by an agent, not yet confirmed by David,
  2026-11-24). An open breaker never closes by time, holdoffs expired or not. Lookups of one
  address share one query (David, 2026-11-24: "Build share lookups"): a lookup that arrives while a query for its address is
  in flight waits for it, so each address has at most one query at a time and its one outcome
  is applied once, whoever is still waiting. A query is never cancelled because a caller left;
  it is bounded by its own timeout. One identity, one write rule (David, 2026-11-24: "Let's go with one identity, one write rule"): a lookup's
  identity is the PTR question built once from the caller's string (name and interface index),
  which keys every table, says whether the address is global with or without a zone, and is
  what the daemon is asked; and a query writes (answer, holdoff, stall, reset of the count) only
  if it is still the current query for its key when it ends. `clear()` and
  `invalidateNetworkScoped()` drop every query in flight, so a lookup after them starts fresh
  and a query from before them writes nothing and gives its waiters `nil`; a global address
  looked up just before is asked again afterwards. A lookup that never got to ask in time and
  a link-local lookup (asked by multicast) do not count. `clear()` and
  `invalidateNetworkScoped()` reset it, and so does a lookup that was already in flight being
  answered, or told there is no such record.
- The ASN cache is capacity-bounded (2048 entries) with **no TTL**; entries
  live until evicted or the cache is reset.
- The address-scope classifier (`IPAddressScope` in `Utils.swift`)
  distinguishes global, private (RFC 1918 and IPv6 ULA), carrier-grade NAT
  (RFC 6598 `100.64.0.0/10`), link-local, and loopback for both families. It
  is internal; `invalidateNetworkScopedRDNS()` and `seedPublicIP(_:source:)`
  both use it.
- Blocking syscalls submitted through `runDetachedBlockingIO` in `Utils.swift`
  (system reverse DNS and public-IP discovery for classified traces and
  multipath) run on a process-global executor bounded at eight concurrent
  operations. DNS queries, `dnsProbe` and Team Cymru ASN lookups do not use it:
  each is a non-blocking UDP exchange that holds no thread. The standalone
  `getPublicIPs()` calls STUN directly and is not bounded by it either. An operation whose
  caller is cancelled or times out while it is still queued is dropped without
  running; one already running holds its slot until the system call returns,
  even though its caller has been released.

## Why the controls are separate

Before 0.17.0 the transition controls were `networkChanged()`, `clearCaches()`
and `invalidatePublicIP()`. There was no way to cancel traces without
invalidating, and no way to evict only part of the rDNS cache: `networkChanged()`
couples trace cancellation, public-IP invalidation and full rDNS eviction, which
callers legitimately need under different conditions. A
caller that can tell a local roam from a WAN change had only two options, both
bad:

- **Over-invalidate.** Call `networkChanged()` for every transition. TTL-valid
  global rDNS is discarded on events that cannot have
  changed them, and names disappear exactly when the caller is comparing
  paths.
- **Replace the actor.** Recreate `SwiftFTR` with a new config to change
  `maxHops` or carry a known public IP forward. This risks orphaned tasks
  holding the process-global blocking-I/O executor, and it pushes transient
  observations into the immutable `publicIP` override — where a stale value,
  or a failure sentinel such as `"unknown"`, silently disables discovery for
  the actor's whole lifetime.

The correct boundary is the trace operation and its cache policy, not the
actor lifetime.

## Cache classes and invalidation rules

The library-owned state and what may invalidate it:

| Data | Key | Invalidated by |
|---|---|---|
| Active trace handles | cache generation | `networkChanged()`; `cancelActiveTraces()` |
| Discovered or seeded public IP | address family, current generation of that family | `invalidatePublicIP()`, `clearCaches()`, `networkChanged()`; a seed replaces its own family only |
| Globally routable rDNS | IP address | 86400 s TTL or oldest-inserted capacity eviction; should survive local transitions |
| Network-scoped rDNS (private, CGNAT, link-local, ULA, loopback) | IP address | `invalidateNetworkScopedRDNS()`; `networkChanged()` |
| ASN results | globally routable address | Capacity only (no TTL); local transitions must not clear it |

Anything keyed on the caller's understanding of network identity — which
gateway it is behind, whether a WAN lease changed, how confident it is in a
path — is caller state. The library's contract is only that each control above
does exactly what it says and nothing more.

## The controls

All four additions are additive; the pre-existing overloads remain
source-compatible. Signatures below are the shipped ones.

### `cancelActiveTraces()`

```swift
public func cancelActiveTraces() async
```

The cancellation half of `networkChanged()`, with its generation-safe
behavior: snapshot current handles, remove them before awaiting their
cancellation, and leave traces registered after the snapshot for a later call.
It does not touch the rDNS, public-IP, or ASN caches.

### `invalidateNetworkScopedRDNS()`

```swift
public func invalidateNetworkScopedRDNS() async
```

Evicts cached rDNS entries (answers; nothing else is cached) whose address is not
globally routable, using the library's existing scope classifier so there is
exactly one definition of "network-scoped". Global entries and their TTLs are
untouched: one network's `192.168.1.1` hostname must not appear on another
network, but an Internet hostname does not become wrong because the WiFi
association changed.

Two semantics the implementation holds to:

- **In-flight lookups.** Every lookup in flight is dropped, global ones included,
  so none repopulates the cache after eviction and their callers get no hostname;
  a global address looked up just before is asked again afterwards.
- **Stall breaker.** This call resets the stall breaker. The breaker exists
  because the resolver on the current network path was stalling, and a
  network transition is precisely the event most likely to have fixed it —
  the same rationale `clear()` already documents. Tying the reset to whether
  scoped entries happened to be evicted would make suppression effectively
  permanent for callers that migrate off `networkChanged()`, because
  suppressed lookups never populate the cache in the first place.

### `seedPublicIP(_:source:)`

```swift
public enum PublicIPSource: Sendable, Equatable {
    case validatedCallerCache
    case gatewayReported
}

@discardableResult
public func seedPublicIP(
    _ address: String,
    source: PublicIPSource
) -> Bool
```

It is a synchronous actor method, so callers outside the actor `await` it.

A dynamic, actor-isolated way to provide a known-valid public IP so the next
classified trace can skip discovery — distinct from the `publicIP` config
override, which suppresses discovery permanently. The method:

- accepts only syntactically valid addresses that the IANA IPv4 and IPv6
  special-purpose registries do not mark as not globally reachable, and, for
  IPv6, only addresses in the `2000::/3` unicast space or the NAT64 prefix
  `64:ff9b::/96` (so deprecated site-local `fec0::/10` is rejected). "Not RFC
  1918" is insufficient: CGNAT space is neither private nor publicly routable.
  Acceptance does not prove the address is announced or is the host's own;
- rejects placeholder strings by construction — there is no way to seed
  `"unknown"`;
- stores the canonical (`inet_ntop`) form with its source in the slot of its own
  address family, bumps that family's generation so an older in-flight question
  cannot overwrite the seed, and returns whether the address was accepted. A trace
  that uses the seed reports the source as `ClassifiedTrace.publicIPSource`;
- leaves the discovery path unchanged when a seed is rejected.

**Ordering requirement**: a seed applies to the generation current when it is
made. A caller that invalidates (bumping the generation) after validating a
value but before seeding it would seed a stale value into the new generation.
Callers must therefore order invalidate-then-seed for the same transition; if
that ordering cannot be guaranteed, a generation-token variant is the
fallback (see Open decisions).

### Per-operation trace options

```swift
public struct TraceOptions: Sendable, Equatable {
    public var maxHops: Int?
    public init(maxHops: Int? = nil)
}

public func trace(to host: String, options: TraceOptions) async throws -> TraceResult

public func traceClassified(
    to host: String,
    vpnContext: VPNContext? = nil,
    resolver: ASNResolver? = nil,
    options: TraceOptions
) async throws -> ClassifiedTrace
```

These are overloads: the pre-existing `trace(to:)` and
`traceClassified(to:vpnContext:resolver:)` remain and pass `TraceOptions()`.

There is no universal correct `maxHops`; a caller that tracks path stability
can bound probe cost per trace. The override is validated against the
existing `1...255` range and applies only to that operation. The library
provides the mechanism; when to shorten a budget, how much headroom to add,
and when to retry at full budget are caller policy.

## What the tests hold to

`networkChanged()` stays equivalent to the composition of cancellation,
public-IP invalidation, and full rDNS eviction, so callers that only ever call
it see no behavior change. Beyond that, library-level tests demonstrate:

- `cancelActiveTraces()` cancels the snapshot generation, leaves
  later-registered traces tracked, and leaves every cache intact.
- `invalidateNetworkScopedRDNS()` evicts private/CGNAT/link-local/ULA/loopback
  entries (positive and negative), preserves global entries and their TTLs,
  drops every lookup in flight, and resets the stall breaker.
- `seedPublicIP` rejects non-global addresses (including CGNAT), rejects
  malformed input, and a rejected seed leaves discovery behavior unchanged.
- A seed made before an invalidation does not survive it.
- `TraceOptions.maxHops` outside `1...255` throws the existing configuration
  error; a valid value bounds exactly that operation.
- Cancellation drops queued work and releases the caller; a system call that
  is already running keeps its blocking-I/O executor slot until it returns.

## Open decisions

- Whether `seedPublicIP` should take a generation token instead of relying on
  the documented invalidate-then-seed ordering.
- Whether CGNAT-range (`100.64.0.0/10`) rDNS entries should stay network-scoped
  for eviction. They are evicted today. Overlay networks assign stable addresses
  from this range, so evicting them on every local transition re-pays lookups for
  addresses that did not change. The alternatives are retaining them or making
  the scope set configurable.
- Whether the ASN cache should gain a TTL while this area is open, or remain
  capacity-only.
- Whether `seedPublicIP` should accept a typed address once the library has a
  public address representation; today the public surface is string
  presentations.
- Whether the library should act on a seed's `PublicIPSource`. It is kept and
  reported beside the address, but a gateway-reported address and a
  caller-validated one are otherwise treated alike; a lower-trust source might be
  treated as a hint that expires sooner, or might not satisfy classification on its
  own.
- Whether a gateway-reported WAN value should be seedable at all, or only usable
  by callers to decide that a revalidation is redundant.
