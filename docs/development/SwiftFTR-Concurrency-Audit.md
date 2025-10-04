# SwiftFTR Concurrency Audit (v0.5.3)

_Date: 2025-10-07_

## Scope

This audit documents the concurrency model in SwiftFTR v0.5.3 prior to the Swift 6.2 modernization. It covers public async APIs, supporting infrastructure (caches, resolvers, helpers), and existing test coverage. Findings highlight current isolation boundaries, blocking operations, parallelism limits, sendability gaps, and cancellation behaviour.

## Primary Async Entry Points

### `SwiftFTR.trace(to:)`
- **Isolation**: Actor-isolated (`SwiftFTR` actor). All socket work executes on the actor via `performTrace`.
- **Blocking work**: DNS resolution (`getaddrinfo`), socket setup, probe send/receive loop (poll/recvfrom) run synchronously on the actor.
- **Parallelism**: Multiple `trace` calls on the same actor serialize. A single actor instance cannot drive concurrent traces.
- **Cancellation**: Cooperative via `TraceHandle` polled each loop iteration; respects `networkChanged()`.
- **Sendability**: Returns `TraceResult`/`TraceHop` (both `Sendable`). Internal `TraceHandle` is an actor; stored in `activeTraces` set.

### `SwiftFTR.traceClassified(to:resolver:)`
- **Isolation**: Actor-isolated. Calls `trace` internally, then performs ASN/rDNS enrichment on actor.
- **Blocking work**: Optional STUN invocation (`discoverPublicIP`) synchronously calls `stunGetPublicIPv4`. ASN lookups use `CymruDNSResolver`, which issues synchronous DNS TXT queries.
- **Parallelism**: Same serialization as `trace`. Classification adds additional blocking time on the actor.
- **Cancellation**: Shares `TraceHandle` flow with `trace`.
- **Sendability**: `ClassifiedTrace`/`ClassifiedHop` conform to `Sendable`. Resolver injection path expects `Sendable` resolvers, but caching resolver uses `_ASNMemoryCache` (see Supporting Infrastructure).

### `SwiftFTR.ping(to:config:)`
- **Isolation**: Marked `nonisolated`. Delegate work to `PingExecutor` struct.
- **Blocking work**: `PingExecutor` handles socket I/O using `poll` and a detached receiver `Task`; no actor serialization.
- **Parallelism**: Multiple pings run concurrently; validated by `PingParallelismTests`.
- **Cancellation**: Receiver task checks `Task.isCancelled`. No explicit external cancellation hook beyond `Task` cancellation.
- **Sendability**: `PingResult`, `PingResponse`, `PingStatistics` are `Sendable`.

### `SwiftFTR.testBufferbloat(config:)`
- **Isolation**: Actor-isolated entry point, but defers to free async helpers (`measureBaseline`, `measureUnderLoad`) that create their own `PingExecutor` instances.
- **Blocking work**: Helpers rely on `PingExecutor`. Load generation runs inside `LoadGenerator` actor with URLSession.
- **Parallelism**: Baseline and load phases run sequentially. Within phases, ping session handles concurrency via `PingExecutor`.
- **Cancellation**: No explicit cancellation surfaces; relies on `Task` cancellation in load generator workers.
- **Sendability**: Result structs/enums are `Sendable`.

### `SwiftFTR.discoverPaths(to:config:)`
- **Isolation**: Actor-isolated public API calling `MultipathDiscovery` actor.
- **Blocking work**: Flow variations executed sequentially inside `MultipathDiscovery.discoverPaths`. Each variation runs `traceClassifiedWithFlowID`, which spins a new `SwiftFTR` actor but awaits completion before launching the next variation.
- **Parallelism**: Effective serialization—no concurrent flow probing.
- **Cancellation**: Relies on cancelling underlying trace via `TraceHandle`. Early-stopping logic breaks loop when no new paths discovered.
- **Sendability**: `NetworkTopology`, `DiscoveredPath`, `FlowIdentifier` are `Sendable`.

## Supporting Infrastructure

### STUN (`STUN.swift`)
- Synchronous UDP socket implementation (`stunGetPublicIPv4`). Called directly from actor (`discoverPublicIP`) and classifier, blocking the actor during STUN discovery.
- Supports interface/source IP binding; shares code with traceroute but lacks async wrapping.

### DNS / ASN Resolution (`DNS.swift`, `ASN.swift`)
- `DNSClient.queryTXT` performs synchronous UDP socket calls with blocking `recvfrom`.
- `CymruDNSResolver.resolve` loops sequentially per IP; no caching beyond `_ASNMemoryCache`.
- `_ASNMemoryCache` uses `NSLock`; declared `@unchecked Sendable`. Reads/writes are synchronous; no backpressure control. Accessed from actor contexts and from classification running on actor.

### Reverse DNS Cache (`RDNSCache.swift`)
- Actor encapsulates hostname caching. `lookup` uses `Task.detached` to run `reverseDNS` (blocking `getnameinfo`) off the actor before caching.
- Batch lookups use `TaskGroup` to launch lookups concurrently; safe but may create many detached tasks.

### Multipath (`Multipath.swift`)
- `MultipathDiscovery` actor runs flow variations in a simple `for` loop; no parallelism. Path merging modifies arrays stored on actor.
- `traceClassifiedWithFlowID` creates a new `SwiftFTR` actor per variation; copies caches opportunistically (public IP) but not RDNS/ASN caches.

### Bufferbloat Load Generator (`Bufferbloat.swift`)
- `LoadGenerator` actor manages `TaskGroup`s per direction. Uses global `URLSession.shared` without specific isolation.
- Pings executed via `PingExecutor`; no reuse of `LoadGenerator` across runs.

### CLI / Tooling
- CLI commands instantiate new `SwiftFTR` instances per command invocation; no long-lived sharing beyond actor caches.

## Sendability & Isolation Notes

- Most public structs/enums conform to `Sendable`. Reference types (`LoadGenerator`, `_ASNMemoryCache`) rely on actors or manual locking.
- Closures passed to task groups and `Task` initialisers aren’t annotated `@Sendable`, relying on compiler inference.
- `SwiftFTR` stores `config` as `nonisolated let`, enabling read-only access without hops.
- No usage of Swift 6.2 `@concurrent` yet.

## Testing Coverage

- `PingParallelismTests` ensures ping concurrency and timing (`Tests/SwiftFTRTests/PingParallelismTests.swift`).
- Stress tests cover rapid sequential traces and some edge cases, but no concurrent trace/classified trace stress suite.
- Multipath tests focus on correctness, not throughput or parallelism.
- Bufferbloat and STUN tests exercise logic but not cancellation under load.

## Key Risks & Opportunities

1. **Actor serialization for traceroute/classification** – Blocks high parallelism scenarios. Opportunity to offload probe execution to session workers.
2. **Blocking STUN/DNS on actor** – Synchronous network I/O can stall the actor, delaying unrelated calls (`trace`, `traceClassified`). Needs async wrappers.
3. **Sequential multipath flow probing** – Limits ECMP discovery speed; refactor to use task groups for parallel flows.
4. **`@unchecked Sendable` cache** – `_ASNMemoryCache` relies on `NSLock` and manual eviction; consider actor or `ManagedCriticalState` for Swift 6.2 compliance.
5. **Cancellation pathways** – `trace` handles cancellation well; bufferbloat and multipath lack explicit cancellation surfaces beyond task cancellation.
6. **Testing gaps** – No tests launching concurrent `traceClassified` calls, no multipath parallel-stress tests, no validation of `networkChanged()` while traces are active.

## Quick Wins

- Wrap STUN/DNS operations with `withCheckedThrowingContinuation` to free the actor during blocking calls.
- Add concurrency stress tests for `trace`/`traceClassified` and `discoverPaths` to expose serialization bottlenecks.
- Replace `_ASNMemoryCache` locking with an actor to eliminate `@unchecked Sendable` reliance.
- Prototype task-group-based multipath exploration to measure expected speedups.

## References
- `Sources/SwiftFTR/Traceroute.swift`
- `Sources/SwiftFTR/Multipath.swift`
- `Sources/SwiftFTR/Ping.swift`
- `Sources/SwiftFTR/Bufferbloat.swift`
- `Sources/SwiftFTR/STUN.swift`
- `Sources/SwiftFTR/DNS.swift`
- `Sources/SwiftFTR/ASN.swift`
- `Sources/SwiftFTR/RDNSCache.swift`
- `Tests/SwiftFTRTests/PingParallelismTests.swift`
