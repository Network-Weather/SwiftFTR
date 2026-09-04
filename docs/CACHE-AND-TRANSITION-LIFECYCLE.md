# Cache and network-transition lifecycle

## Status

Implemented in 0.17.0, except for sharing an `RDNSCache` between tracer
instances, which is tracked in [ROADMAP.md](../ROADMAP.md). This document is
the design of record for the lifecycle contract: what the actor caches, what
invalidates it, and which controls callers get. Scope is the SwiftFTR library
contract only. How a caller decides
what invalidates it, and which controls callers get. How a caller decides
*when* to invoke these controls — network identity heuristics, revalidation
policy, telemetry — is caller policy and out of scope.

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

`networkChanged()` remains the conservative composition — cancel everything,
invalidate everything — for callers without finer-grained evidence.

## What exists today

Verified against the current sources.

- `networkChanged()` bumps the cache generation, clears the cached public IP,
  snapshots and cancels active traces, and clears the entire rDNS cache as one
  operation (`Traceroute.swift`).
- `invalidatePublicIP()` and `clearCaches()` have existed since v0.3.0. Public-IP
  invalidation is already independently callable; selective rDNS eviction and
  cancellation-without-invalidation are not.
- `SwiftFTRConfig.publicIP` is an immutable, authoritative override: when set,
  classified traces bypass public-IP discovery entirely. It is configuration,
  not a cache.
- Public-IP discovery is generation-guarded: a result that arrives after an
  invalidation is neither returned nor cached
  (`effectivePublicIPForClassification`).
- `RDNSCache` holds entries for 86400 s with LRU eviction at 1000 entries,
  caches negative results, and has a stall breaker: after two consecutive
  lookups that consume their full deadline, further lookups are suppressed
  until `clear()` runs. `clear()` also generation-guards against in-flight
  lookups repopulating the cache.
- The ASN cache is capacity-bounded (2048 entries) with **no TTL**; entries
  live until evicted or the cache is reset.
- The address-scope classifier (`IPAddressScope` in `Utils.swift`) already
  distinguishes global, private (RFC 1918 and IPv6 ULA), carrier-grade NAT
  (RFC 6598 `100.64.0.0/10`), link-local, and loopback for both families. It
  is currently internal.
- Blocking syscalls (STUN, resolver work) run on a process-global bounded
  executor (`Utils.swift`). Work belonging to a discarded actor still occupies
  its slots until it completes.

## Why the current shape is wrong

`networkChanged()` couples three actions — trace cancellation, public-IP
invalidation, and full rDNS eviction — that callers legitimately need under
different conditions. A caller that can tell a local roam from a WAN change
has only two options today, both bad:

- **Over-invalidate.** Call `networkChanged()` for every transition. TTL-valid
  global rDNS and ASN enrichment are discarded on events that cannot have
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
| Discovered public IP | current generation | `invalidatePublicIP()`, `clearCaches()`, `networkChanged()` |
| Globally routable rDNS | IP address | 86400 s TTL or LRU capacity; should survive local transitions |
| Network-scoped rDNS (private, CGNAT, link-local, ULA, loopback) | IP address | `invalidateNetworkScopedRDNS()`; `networkChanged()` |
| ASN results | globally routable address | Capacity only (no TTL); local transitions must not clear it |

Anything keyed on the caller's understanding of network identity — which
gateway it is behind, whether a WAN lease changed, how confident it is in a
path — is caller state. The library's contract is only that each control above
does exactly what it says and nothing more.

## The controls

All four additions are additive; the pre-existing overloads remain
source-compatible.

### `cancelActiveTraces()`

```swift
public func cancelActiveTraces() async
```

The cancellation half of `networkChanged()`, with its existing
generation-safe behavior: snapshot current handles, remove them before
awaiting their cancellation, and leave traces registered after the snapshot
for a later call. It must not touch the rDNS, public-IP, or ASN caches.

### `invalidateNetworkScopedRDNS()`

```swift
public func invalidateNetworkScopedRDNS() async
```

Evicts cached rDNS entries — positive and negative — whose address is not
globally routable, using the library's existing scope classifier so there is
exactly one definition of "network-scoped". Global entries and their TTLs are
untouched: one network's `192.168.1.1` hostname must not appear on another
network, but an Internet hostname does not become wrong because the WiFi
association changed.

Two semantics need care in the implementation:

- **In-flight lookups.** The current generation guard is cache-wide: `clear()`
  rejects every in-flight result. Selective eviction needs a scope-aware
  equivalent — an in-flight lookup for a scoped address must not repopulate
  the cache after eviction, while an in-flight global lookup should complete
  and cache normally.
- **Stall breaker.** This call resets the stall breaker. The breaker exists
  because the resolver on the current network path was stalling, and a
  network transition is precisely the event most likely to have fixed it —
  the same rationale `clear()` already documents. Tying the reset to whether
  scoped entries happened to be evicted would make suppression effectively
  permanent for callers that migrate off `networkChanged()`, because
  suppressed lookups never populate the cache in the first place.

### `seedPublicIP(_:source:)`

```swift
public enum PublicIPSource: Sendable {
    case validatedCallerCache
    case gatewayReported
}

public func seedPublicIP(
    _ address: String,
    source: PublicIPSource
) async -> Bool
```

A dynamic, actor-isolated way to provide a known-valid public IP so the next
classified trace can skip discovery — distinct from the `publicIP` config
override, which suppresses discovery permanently. The method must:

- accept only syntactically valid, globally routable addresses, using the
  library's scope classifier ("not RFC 1918" is insufficient — CGNAT space is
  neither private nor publicly routable, and the check must reject every
  non-global range for the address family);
- reject placeholder strings by construction — there is no way to seed
  `"unknown"`;
- associate the value with the cache generation current at the call, and
  report acceptance to the caller;
- preserve the existing discovery path when a seed is rejected.

**Ordering requirement**: a seed applies to the generation current when it is
made. A caller that invalidates (bumping the generation) after validating a
value but before seeding it would seed a stale value into the new generation.
Callers must therefore order invalidate-then-seed for the same transition; if
that ordering cannot be guaranteed, a generation-token variant is the
fallback (see Open decisions).

If this API is not added, callers should accept one bounded discovery per
measurement context rather than reconstruct the actor with an override.

### Per-operation trace options

```swift
public struct TraceOptions: Sendable {
    public var maxHops: Int?
}

public func traceClassified(
    to host: String,
    vpnContext: VPNContext? = nil,
    resolver: ASNResolver? = nil,
    options: TraceOptions = .init()
) async throws -> ClassifiedTrace
```

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
  rejects in-flight scoped results, allows in-flight global results, and
  resets the stall breaker.
- `seedPublicIP` rejects non-global addresses (including CGNAT), rejects
  malformed input, and a rejected seed leaves discovery behavior unchanged.
- A seed made before an invalidation does not survive it.
- `TraceOptions.maxHops` outside `1...255` throws the existing configuration
  error; a valid value bounds exactly that operation.
- No cancellation path leaves an orphaned task holding a blocking-I/O
  executor slot beyond its deadline.

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
- What `PublicIPSource` is for. `seedPublicIP` requires it and then discards it:
  a gateway-reported address and a caller-validated one are cached identically,
  and nothing reads the source back. Either the library should persist it and act
  on the difference — a lower-trust source might be treated as a hint that expires
  sooner, or might not satisfy classification on its own — or the parameter should
  be dropped, since a required argument that does nothing misleads the caller.
  Resolve this before the seeding API is considered settled.
- Whether a gateway-reported WAN value should be seedable at all, or only usable
  by callers to decide that a revalidation is redundant.
