# Cache and network-transition lifecycle

## Status

Proposal. This design deliberately separates cancellation, route-sensitive
state, and globally valid enrichment caches before a consumer changes a
tracer-replacement implementation.

## Decision summary

An application should keep a long-lived `SwiftFTR` actor for a measurement context. A
network transition must not require replacing that actor merely to cancel
active work or refresh public-IP discovery.

SwiftFTR needs independently callable controls for:

- cancelling active traces;
- invalidating its discovered public-IP value;
- evicting only network-scoped rDNS entries; and
- supplying a per-trace hop budget.

The application owns the policy for when a public IP is still believable. SwiftFTR owns
the mechanics of bounded discovery, trace cancellation, and TTL-based rDNS
caching. An application must not write a prior observation into the immutable
`SwiftFTRConfig.publicIP` override.

## Why the current shape is wrong

`SwiftFTRConfig` is intentionally immutable. Its `publicIP` field is an
authoritative override: when set, classified traces bypass public-IP
discovery. A consumer that takes a public-IP observation, stores it in its own
cache, then recreates a tracer with that observation as config. This creates
four problems.

- A transient observation becomes a permanent configuration value until the
  next actor replacement. A failed observation represented as `"unknown"`
  must never be an override.
- `networkChanged()` currently combines cancellation, public-IP invalidation,
  and full rDNS eviction. A consumer can need those actions under different policies.
- Replacing an actor is easy to get wrong. A task holding the old actor can
  continue consuming SwiftFTR's process-global blocking-I/O executor unless
  it was explicitly cancelled first.
- The current cached-hop optimization only affects a later actor recreation,
  not necessarily the trace that established the new depth. It is therefore
  accidental policy rather than a reliable per-path optimization.

The correct boundary is a trace operation and its cache policy, not the actor
lifetime.

## Cache classes and invalidation rules

| Data | Owner | Key | Invalidated by |
|---|---|---|---|
| Active trace handles | SwiftFTR | actor generation | Explicit transition cancellation |
| Discovered public IP | SwiftFTR | current measurement context | Application skepticism policy |
| Public-IP history and provenance | Application | path identity | Time, conflicting trusted evidence, or identity change |
| Globally routable rDNS | SwiftFTR | IP address | Its normal TTL or capacity policy |
| Private, link-local, ULA, and loopback rDNS | SwiftFTR | IP address plus local-network scope | Local path identity change |
| ASN results | SwiftFTR | globally routable IP prefix/address | Normal TTL or capacity policy, not local roaming |
| Observed destination TTL | Application | path identity and route mode | Failed bounded trace, material route change, or age policy |

The important distinction is that a WiFi association change is not proof that
an Internet hostname, ASN, or WAN address has changed. Conversely, an
unchanged gateway MAC is strong evidence of a familiar local gateway but is
not proof that its WAN lease has not changed.

## Path identity

An application should create an explicit `PathIdentity` rather than treating one signal
as universal truth. A direct-path identity should contain:

- normalized physical gateway MAC, when available;
- route mode, at minimum direct versus VPN;
- a stable VPN exit identity when traffic is routed through a VPN; and
- enough local context to distinguish unknown gateways, such as primary
  interface type and gateway address.

SSID and BSSID are useful transition evidence, but neither should be the
public-IP cache key. A user can roam between APs behind the same gateway, and
the same SSID can exist behind different gateways.

When the gateway MAC is absent or uncertain, the application should use a short-lived,
low-confidence identity rather than optimistically inheriting the prior
network's public IP.

## Public-IP policy

### Sources and trust

An application should retain public-IP observations with source, observation time,
validation time, and path identity. Source priority is:

1. A gateway-reported WAN value that passes a globally-routable-address check.
2. Interface-bound reflection or STUN discovery.
3. A previously validated observation for the same path identity.

"Non-private" is insufficient for source acceptance. RFC 6598 carrier-grade
NAT space (`100.64.0.0/10`) is not RFC 1918 private space but is not publicly
routable. The validator must reject every non-global range applicable to the
address family.

Router data is strong evidence, not absolute proof. A gateway can report a
WAN value that is stale, CGNAT, tunnel-facing, or otherwise not the address an
external observer sees. Where a reflection result conflicts with it, the application must
record the disagreement and prefer the result appropriate to the claim being
made.

### Revalidation

An application should not re-run STUN for every trace. It should invalidate SwiftFTR's
discovered public IP before the next suitable classified trace when any of the
following occurs:

- `PathIdentity` changes;
- a gateway integration reports a different globally routable WAN value;
- the application observes a WAN reconnect, lease renewal, or equivalent vendor signal;
- the value has exceeded a named maximum validation age; or
- a material path discontinuity is observed despite the same local gateway.

The validation age is a product policy, not a library constant. It should be
instrumented and selected from field data. A periodic revalidation trace must
be coalesced with scheduled measurement work rather than create an additional
network burst.

When an existing value remains credible, it may be shown by the application as a cached
observation, with its age and provenance retained internally. It must not be
passed through `SwiftFTRConfig.publicIP`, because that field suppresses the
library's discovery path.

### Required SwiftFTR support

SwiftFTR needs a dynamic, actor-isolated cache-seeding API if an application wants to use
a validated value to avoid discovery after process start. It must be distinct
from the immutable config override and must not accept placeholder strings.

```swift
public enum PublicIPSource: Sendable {
    case validatedCallerCache
    case gatewayReported
}

public func seedPublicIP(
    _ address: IPAddress,
    source: PublicIPSource
) async
```

The exact public address type should follow existing SwiftFTR address APIs;
this snippet establishes semantics, not a final spelling. The method must:

- accept only syntactically valid, globally routable addresses;
- associate the value with the current cache generation;
- preserve the existing discovery result when the seed is rejected; and
- expose no mechanism for a caller to seed `"unknown"`.

If this API is not added, the application should accept one bounded discovery on a new
measurement context rather than reconstructing the actor with an override.

## rDNS policy

The existing 24-hour TTL is a good default for globally routable rDNS. It
should survive a local network transition. Clearing it on every WiFi or VPN
event repeats blocking resolver work and causes names to disappear precisely
when an application is trying to compare paths.

Network-scoped addresses are different. At a minimum, a local transition
should evict cached entries for:

- IPv4 RFC 1918, link-local, loopback, and carrier-grade NAT ranges;
- IPv6 link-local, unique-local, and loopback ranges; and
- any address classes SwiftFTR already labels as local/private.

This prevents a hostname for one network's `192.168.1.1` from being displayed
on another network using the same address. Negative results for global
addresses should also remain TTL-cached, otherwise a temporary resolver
failure becomes repeated work.

### Required SwiftFTR support

Add a public operation with explicit semantics, for example:

```swift
public func invalidateNetworkScopedRDNS() async
```

The classification belongs inside SwiftFTR so applications and the library share one
definition of network-scoped addresses. The operation must not reset the
global rDNS stall breaker unless it actually removed a scoped in-flight or
cached entry.

## Active-work cancellation

An application must cancel its own scheduled burst tasks first, then cancel the active
SwiftFTR traces that those tasks may have already started. This is necessary
even if it subsequently chooses to invalidate no caches.

SwiftFTR should expose the cancellation half of `networkChanged()` separately:

```swift
public func cancelActiveTraces() async
```

It should preserve the current generation-safe behavior: snapshot current
handles, remove them before awaiting their cancellation, and leave traces
registered after the snapshot for a later transition. It must not clear rDNS,
public-IP, or ASN caches.

`networkChanged()` remains a convenient conservative API for general callers.
Applications use the smaller operations when they have richer path evidence and
different cache lifetimes.

## Hop-budget policy

There is no universal correct value for `maxHops`. An application should choose it per
trace according to confidence in the current path.

- A new or low-confidence `PathIdentity` uses a full named discovery budget.
- A stable identity may use the last destination TTL plus named headroom.
- A bounded trace that does not reach the destination, or exhibits a material
  path discontinuity, triggers one coalesced full-budget revalidation trace.
- Direct and VPN paths keep independent observations and budgets.

The full budget, headroom, minimum bounded budget, observation age, and
revalidation cooldown must be named application constants and recorded in telemetry.
They are product tuning values, not defaults hidden in SwiftFTR.

SwiftFTR should accept this at operation scope rather than requiring a new
actor:

```swift
public struct TraceOptions: Sendable {
    public var maxHops: Int?
}

public func traceClassified(
    to destination: String,
    vpnContext: VPNContext? = nil,
    options: TraceOptions = .init()
) async throws -> ClassifiedTrace
```

The override must be validated against a library-defined safe range and apply
only to that operation. Existing API overloads remain source-compatible.

## Application transition sequence

For a confirmed path transition, an application should perform the following in order:

1. Enter the existing measurement perturbation/quiescence window.
2. Cancel scheduled burst and periodic work that was derived from the old path.
3. Call `await tracer.cancelActiveTraces()`.
4. Compare the new and prior `PathIdentity`.
5. If public-IP skepticism is warranted, call
   `await tracer.invalidatePublicIP()` and mark its record for
   revalidation.
6. If local-network scope changed, call
   `await tracer.invalidateNetworkScopedRDNS()`.
7. Clear application-only path interpretation, hop-depth, and health-window state.
8. Schedule one fresh trace after the perturbation window, using the chosen
   per-trace hop budget.

No step creates a new SwiftFTR actor. Actor recreation remains appropriate
only for a genuine change to immutable library policy, such as a user-selected
rDNS timeout, cache capacity, or resolver strategy.

## Migration plan

- Add the three cache/cancellation APIs and operation-scoped trace options to
  SwiftFTR as additive APIs, with deterministic unit tests.
- Preserve `networkChanged()` as the conservative composition of cancellation,
  public-IP invalidation, and full rDNS eviction for existing callers.
- Update consumers to construct their tracer with stable policy only, never
  with a cached observation in `publicIP`.
- Introduce `PathIdentity` and provenance-aware public-IP records in the
  application layer.
- Gate adaptive hop budgets behind telemetry and compare their destination
  reach rate, additional full-budget retries, elapsed time, and packet cost
  against full-budget control traces.
- Remove tracer-replacement workarounds once the application uses the new operations.

## Acceptance and telemetry

The implementation is not complete when it compiles. It must demonstrate:

- A WiFi roam behind the same gateway preserves a validated public IP and
  globally routable rDNS, while old active traces are cancelled.
- A different gateway identity invalidates public-IP discovery and local rDNS,
  then produces fresh evidence before the application changes health state.
- A WAN-address change reported by a gateway causes revalidation even when the
  gateway MAC stays the same.
- A private `192.168.1.1` rDNS result cannot leak across local networks.
- A global rDNS result survives a local transition until its TTL expires.
- A bounded hop-budget miss causes exactly one coalesced full-budget retry.
- No cancellation path causes fallback public-IP work or an orphaned trace to
  occupy the blocking-I/O executor.

Application telemetry should record path-identity confidence, public-IP source and
age, invalidation reason, selected hop budget, trace completion state, and
whether a full-budget retry was required. It must not emit raw gateway MACs,
public IPs, SSIDs, or hostnames in telemetry.

## Open decisions

- Choose the public-IP maximum validation age from observed WAN churn and
  product latency tolerance.
- Define the exact `PathIdentity` fallback when no gateway MAC is available.
- Decide whether a validated gateway-reported WAN value may seed SwiftFTR, or
  only suppress an otherwise redundant revalidation.
- Define a safe public API for IP-address validation consistent with SwiftFTR's
  existing address representation.
- Measure the cost and reach-rate effect of adaptive hop budgets before making
  them the default.
