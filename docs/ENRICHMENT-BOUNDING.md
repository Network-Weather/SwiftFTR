# Bounding and cancelling the enrichment phase

Implementation plan for the ROADMAP item "Bounded, cancellable enrichment".
Evidence and measurements: [`BUG2-INVESTIGATION.md`](BUG2-INVESTIGATION.md).

## What is broken

`traceClassified()` can exceed a downstream 60-second watchdog while ignoring
cancellation. The probe path is not implicated. The exposure is the enrichment
phase, which runs every blocking syscall through one process-global 8-slot
`BlockingIOExecutor` (`Utils.swift`).

Three properties compound:

1. **Cancellation is not honored.** `runDetachedBlockingIO`'s doc comment states
   this as a deliberate choice: never cancelling is how it guarantees exact-once
   continuation resumption. The goal is right; the mechanism is too blunt.
2. **Two primitives have no deadline of SwiftFTR's own.**
   - `getaddrinfo` at `STUN.swift:123`, inside the per-server loop at `:405`.
     `stunTimeout` covers the socket recv, not name resolution.
   - `getnameinfo` via `reverseDNS(_:)` at `Utils.swift:288`, which is what
     `RDNSCache` uses by default. Note `DNS.swift:1080` already has a *bounded*
     PTR implementation; the unbounded one is the one wired up.

   Measured: each stalls 30.0s when DNS packets are dropped silently.
3. **Priority inversion.** rDNS enqueues at `.background`; probe, ASN, and STUN
   work enqueues higher. `OperationQueue` serves strictly by priority, so a
   steady stream of higher-priority work defers rDNS without bound.

## Changes

### 1. Cancellation-aware executor, without losing exact-once resumption

Wrap the continuation in a lock-protected once-only resume box. On cancellation:
call `BlockOperation.cancel()` so a not-yet-started operation never runs, and
resume the caller with `CancellationError`. When the operation later finishes, it
finds the box already resumed and discards its result rather than resuming twice.

This keeps the property the current design was protecting — the continuation is
resumed exactly once on every path — while making cancellation prompt.

### 2. Caller-side deadline

Add an optional `deadline:` to `runDetachedBlockingIO`. When it elapses, the
caller is resumed with a timeout error through the same once-box. Apply to the
rDNS path and to STUN discovery.

This bounds what the *caller* waits for. It does not interrupt the syscall — see
Residual exposure.

### 3. Stop enqueueing after cancellation

Check `Task.isCancelled` between enrichment steps in the classify path, so a
cancelled trace stops submitting further work instead of queueing a full rDNS
wave that nobody will read.

### 4. rDNS circuit breaker

After N consecutive rDNS timeouts, skip the remaining lookups for that batch.
Turns a worst-case 5-wave, 150s rDNS phase into a single timeout. Reverse DNS is
cosmetic enrichment; degrading it to numeric addresses is the correct trade.

### 5. Priority

Raise rDNS above `.background`, or give it a reserved share of the queue, so it
cannot be starved indefinitely by concurrent probe traffic.

## Residual exposure, deliberately not fixed here

A syscall that has **already started** still occupies its executor slot until it
returns — up to 30s for a stalled resolver. The caller is freed, but the slot is
not. Eliminating this means not calling `getnameinfo` at all, which requires
knowing the effective system resolver — the "System DNS Discovery (Split-DNS
Aware)" roadmap item. The circuit breaker (4) is the mitigation until then.

## Acceptance

`traceClassified` returns or throws within a configuration-derived bound under a
blackholed resolver, and a cancelled trace terminates promptly during enrichment
as it already does during the probe phase. Tests assert wall-clock upper bounds
under an injected stalling resolver rather than depending on live network state.
