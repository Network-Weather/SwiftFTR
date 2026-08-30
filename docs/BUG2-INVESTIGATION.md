# BUG 2 investigation: traceClassified() not completing within 60s

Investigation notes, 2026-08-30. Code audited at HEAD (e5b1cea). Verified that
`git diff 46de63af..HEAD -- Sources/SwiftFTR/` touches only a docc file, so this
audit applies exactly to the 0.14.0 code NWX ships.

## Part 1: Static audit

### 1a. Continuation exit paths — `TraceReceiveOperation` (used by `trace()` → `traceClassified()`)

`Traceroute.swift` (HEAD): continuation created at performTrace, handed to
`operation.start(continuation:)`.

| # | Exit path | Resumed exactly once? | Notes |
|---|-----------|----------------------|-------|
| 1 | `start()` called after `cancel()` already ran (`isFinished` set) | Yes — `resume(throwing: .cancelled)` inline | continuation never stored |
| 2 | Deadline timer fires → `finish()` | Yes — `resume(returning:)` | `isFinished` flag + NSLock guards double-entry; timer is one-shot `schedule(deadline:)` |
| 3 | Early completion in `handleRead()` → `finish()` | Yes | same guard |
| 4 | `cancel()` (task cancel, TraceHandle cancel, networkChanged) | Yes — takes continuation under lock, resumes on serial queue | second `cancel()`/`finish()` sees `isFinished` and returns |
| 5 | `setupSources()` after cancel | No resume needed — continuation already consumed by `cancel()` | `checkFinishedSync()` guard |

`StreamingTraceReceiveOperation` (not on the traceClassified path — traceClassified
uses `trace()`/`TraceReceiveOperation`) has the identical structure plus retry
timer; `handleRetry()` never touches the continuation; yield-rejection calls
`cancel()` which resumes. Same table applies.

**Conclusion: no statically reachable path drops either continuation.** Both
classes route every exit through `finish()`/`cancel()`, which are mutually
exclusive via `isFinished` under NSLock, and `start()` handles pre-cancellation.
The one-shot deadline timer fires regardless of network state, so the probe
phase is bounded by `maxWaitMs` even under total blackhole (verified dynamically,
Part 2). Hypothesis 1 is NOT supported by the source.

### 1b. Enrichment path: deadline & cancellation audit

`traceClassified()` sequence (all cold-cache):

| Step | Call | Deadline? | Cancellable? |
|------|------|-----------|--------------|
| 1 | `effectivePublicIPForClassification` → `discoverPublicIP()` → `runDetachedBlockingIO { getPublicIPv4(stun 2.0, dns 3.0) }` | Partially. STUN socket send/recv bounded by SO_SNDTIMEO/SO_RCVTIMEO (2.0s); DNS-whoami bounded (SO_RCVTIMEO, 2 servers × 3.0s). **BUT: `getaddrinfo(host)` for each of 3 STUN hostnames has NO deadline** — bounded only by the system resolver | **No.** `runDetachedBlockingIO` documents: "cancelling the caller does not resume it early" |
| 2 | `trace(to:)` → `resolveHost` (`getaddrinfo`) | No app deadline; runs synchronously **on the SwiftFTR actor** (a cooperative-pool thread) | No |
| 3 | probe send + `TraceReceiveOperation` | Yes — `maxWaitMs` one-shot timer | Yes — prompt via `operation.cancel()` |
| 4 | rDNS `rdnsCache.batchLookup` (up to maxHops IPs) → per IP `runDetachedBlockingIO(.background) { getnameinfo }` | **No deadline on `getnameinfo`** — bounded only by system resolver | **No** (same executor caveat); `try Task.checkCancellation()` only AFTER the whole batch returns |
| 5 | second rDNS batch for dest/public IP | same as 4 | same |
| 6 | `classifier.classify` → **if step 1 returned nil, ANOTHER `getPublicIPv4(stun 0.8, dns 2.0)`** — 3 more `getaddrinfo` calls | same as 1 | No |
| 7 | Cymru ASN resolve (NWX uses default `.dns` strategy) | Yes — per-query SO_RCVTIMEO 1.5s, literal-IP servers (no getaddrinfo), 8-wide semaphore | queued through same executor; not cancellable but bounded |

### 1c. The shared bottleneck: `BlockingIOExecutor` (Utils.swift:359-431)

Every blocking op above (STUN discovery, every getnameinfo, every Cymru query,
plus **all** `DNSClient` probe queries from anywhere else in the host app) is
funneled through ONE process-global OperationQueue with
`maxConcurrentOperationCount = 8`. Properties (from source, and the code's own
doc comment):

- Queued operations are not removed on cancellation; a running synchronous
  syscall is never interrupted. The awaiting task stays suspended until its op
  runs and finishes.
- rDNS ops enqueue at `.background` QoS; OperationQueue serves higher
  queuePriority first, so background rDNS ops can be pushed arbitrarily far back
  by a stream of `.userInitiated` ops (Cymru/DNS probes) from concurrent
  measurements.
- Therefore a single `traceClassified()`'s wall time includes the queue wait for
  *every* op it enqueues, behind whatever else the process (NWX runs many
  concurrent measurements) has queued.

### 1d. Worst-case arithmetic (network "up but broken", e.g. DNS unresponsive)

Let G = one `getaddrinfo`/`getnameinfo` stall time with an unresponsive system
resolver. **G is not measured.** Part 2d measured only the healthy-network
baseline (sub-millisecond); establishing G needs the sudo pf test in Part 4.
The arithmetic below is therefore parameterized on G, and asserts no value for
it. It shows the shape of the exposure, not a number.

- Step 1: 3 STUN hostnames × G (serial, one blocking op) → 3G.
- Step 4: ceil(hops/8) waves × G if getnameinfo stalls: 40 hops → 5G.
- Step 6 (only when step 1 failed): 3 more × G.

So the enrichment phase crosses NWX's 60s watchdog once G exceeds roughly 8
seconds on the STUN path alone. Whether a dead resolver actually stalls that
long on macOS is the open question.

None of it cancellable. The NWX watchdog fires at 60s, cancels the group; the
traceClassified task remains suspended inside `runDetachedBlockingIO` — which is
exactly the field signature: "did not complete within 60 seconds" + apparent
hang, with no crash and no error from SwiftFTR.

**This is not an unbounded hang** (system resolver eventually gives up; ops
eventually drain) but it is unbounded *relative to the trace's configuration*,
easily exceeds 60s, and ignores cancellation. Telemetry cannot distinguish
"never returned" from "returned after 60s" — NWX stops awaiting at the watchdog.

### 1e. Production configuration facts (read from NWX source)

- Destination is the literal `"1.1.1.1"` (`MeasurementManager.swift:112`), so
  `resolveHost` never calls `getaddrinfo` for the destination. The remaining
  `getaddrinfo` exposure is the 3 STUN hostnames; `getnameinfo` exposure is
  per-hop rDNS.
- The watchdog tracer's config uses `publicIP: cachedPublicIP`,
  `noReverseDNS: false`, default ASN strategy `.dns` (Cymru).
- **On every network change NWX sets `cachedPublicIP = nil` and clears its rDNS
  caches** (`MeasurementManager.swift:2092`, `:3342`). So the first
  traceClassified after a network transition — precisely when the resolver is
  most likely degraded — always runs full STUN discovery plus a cold rDNS wave
  through the blocking-IO executor.
- NWX runs continuous concurrent measurements (DNS probes, pings, topology
  discovery) in the same process; their DNSClient/STUN calls share the same
  8-slot executor at `.userInitiated` priority, outranking rDNS's `.background`.

## Part 2: Dynamic results (Tests/SwiftFTRTests/Bug2HangInvestigationTests.swift)

Run on 2026-08-30, macOS, healthy network, `swift test --filter Bug2HangInvestigationTests`.

### 2a. Probe phase bounded under silence — PASS
traceClassified to 203.0.113.1 (no replies past local segment), maxWaitMs=1500,
enrichment pinned off: completed in **1.506s**. The deadline timer fires with an
idle network; the receive state machine does not hang under blackhole.

### 2b. Prompt cancellation in probe phase + no fd leak — PASS
Cancel at 100ms × 3 iterations: terminated at **0.104s / 0.106s / 0.107s** with
`TracerouteError.cancelled`; fd count 4 before and after (no socket leak, and no
"CONTINUATION MISUSE" runtime warning, i.e. no dropped/double-resumed
continuation). Hypothesis 1 not reproduced.

### 2c. Blocking-IO executor starvation — REPRODUCED (test fails as designed)
8 sleeper ops (6s each) occupy the executor; traceClassified with publicIP=nil
started, cancelled at 0.1s: **did not terminate until 5.49s** — exactly when the
first executor slot freed. Un-cancelled variant (2c-bis): **6.54s** wall for a
trace whose config-derived budget is ~1–2s. Scale sleeper duration to realistic
degraded-resolver stalls and the 60s watchdog fires with the task still
suspended and immune to cancellation. This is the field signature.

### 2d. Resolver primitive baselines — healthy network
getaddrinfo(stun hostnames): 0.5–1.1ms each; getnameinfo(8.8.8.8): 0.5ms.
The degraded-resolver stall magnitude (the G in 1d) is **not yet measured** —
needs a pf rule blocking port 53 (sudo; see Part 3).

### 2e. Cooperative-pool saturation — NOT reproduced
10 busy-spin `.userInitiated` tasks (= activeProcessorCount) spinning 4s while
traceClassified runs: trace completed in **1.01s**, essentially unimpeded, on
this machine/Swift runtime. Plain equal-priority pool saturation did not delay
the trace. (A host-app *blocking syscall pinning cooperative threads*, as in
the pre-1.3.0 NWX SSDP loop, is a different and stronger condition — not
reproducible from inside SwiftFTR's test suite.) Hypothesis 3, in the
busy-tasks form, is not supported.

### 2f. Priority starvation inside the executor — REPRODUCED
A `.background` op (rDNS's priority) submitted BEFORE 24 `.userInitiated` ops
(DNS/Cymru/STUN's priority) ran only after **2.19s** — i.e. after the entire
later-submitted higher-priority backlog drained (predicted FIFO time: ~0.7s).
OperationQueue serves strictly by priority, so a steady stream of probe queries
from the host app defers an in-flight trace's rDNS phase without bound.

## Part 3: Ranked assessment

1. **SUPPORTED — Hypothesis 2 (blocking/undeadlined enrichment), sharpened:**
   the enrichment phase is a chain of non-cancellable blocking ops
   (`runDetachedBlockingIO`) through one process-global 8-slot queue, where
   (a) `getaddrinfo` (STUN hostnames ×3, twice if discovery fails once) and
   `getnameinfo` (per hop) have no deadline of SwiftFTR's own,
   (b) queue waits behind the host app's other SwiftFTR calls are unbounded,
   (c) rDNS ops are additionally starved by priority (2f), and
   (d) cancellation is explicitly not honored while queued or running (2c).
   NWX's post-network-change cache clearing guarantees the worst-case path runs
   exactly when the resolver is most likely broken. 60s is reachable without
   any SwiftFTR bug in the probe path, and telemetry cannot distinguish "hung
   forever" from "returned after >60s" because NWX abandons the await.
2. **NOT SUPPORTED — Hypothesis 1 (dropped continuation):** every exit path of
   both receive operations resumes exactly once (audit table 1a); dynamic
   cancel/blackhole tests terminate promptly with no leaked fd or continuation.
3. **NOT SUPPORTED (in testable form) — Hypothesis 3 (cooperative-pool
   starvation):** busy-task saturation did not delay the trace (2e). The
   pre-1.3.0 NWX SSDP thread-pinning variant remains possible for old-version
   clients but is untestable from here; getting `app_version` into NWX `log.*`
   telemetry remains the cheap discriminator.

## Part 4: Follow-ups requiring approval (sudo)

Not run — ask before executing:

1. Degraded-resolver magnitude (fills in G from 1d):
   `sudo pfctl -E && echo "block drop out quick proto udp from any to any port 53
   block drop out quick proto tcp from any to any port 53" | sudo pfctl -f -`
   then time `getaddrinfo("stun.l.google.com")` / `getnameinfo("8.8.8.8")` and a
   full `traceClassified(to: "1.1.1.1")` with cold caches; restore with
   `sudo pfctl -f /etc/pf.conf` (and `sudo pfctl -d` if pf was disabled before).
   NOTE: this blackholes DNS for the whole machine while active.
2. Full blackhole mid-trace / during STUN: same pattern with
   `block drop out quick proto icmp from any to any` and
   `block drop out quick proto udp from any to any port {3478, 19302}`.
3. Mid-trace interface loss: `sudo ifconfig en0 down` (restore: `up`), while a
   traceClassified is in flight.

## Fix directions implied (not implemented here)

- Wrap each blocking primitive in its own deadline (e.g. run getnameinfo with a
  watchdog, or replace with the in-package DNSClient PTR query which already has
  SO_RCVTIMEO — `DNS.swift` has a full resolver; rDNS could stop using
  getnameinfo entirely).
- Resolve STUN hostnames via bounded DNSClient, or ship literal IPs with
  hostname fallback.
- Make `runDetachedBlockingIO` cancellation-aware at least for *queued* (not
  yet started) operations, and check `Task.isCancelled` between enrichment
  steps so a cancelled traceClassified stops enqueueing further work.
- Consider per-instance or per-category executor budgets so one slow category
  (rDNS) can't absorb the queue, and revisit priority inversion between rDNS
  and probe queries.
