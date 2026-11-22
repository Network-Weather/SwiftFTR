# Blocking I/O: one owner per request, one deadline per operation

Sequenced plan for the ROADMAP item "Robustness under network and DNS failure, proven by tests".
Stage: product. Status: plan, reviewed once (see Review record); nothing below has shipped.
Completed stages get struck through as they land.

## Why

SwiftFTR runs inside software that is diagnosing a broken network, so a resolver that never
answers or a link that drops mid-operation is its normal operating condition. The roadmap goal is
that every public operation returns or throws within a time the caller can work out from its
configuration. This plan covers the trace family, ping, the TCP, UDP and DNS probes and public-IP
discovery. What it leaves unbounded is listed under Out of scope.

Three things stand between the code and that goal.

**The bridge to blocking calls keeps producing races.** `BlockingIOExecutor.run` (`Utils.swift`)
carries reverse DNS, DNS and ASN queries, and public-IP discovery during a classified trace onto
eight worker slots. Four objects can each end a request: the operation's block, the deadline
timer, the task-cancellation handler, and the completion-block backstop in
`BlockingIOCancellationBridge`. `ContinuationBox` guarantees the caller is resumed once. It does
not guarantee the caller is resumed with the right answer, because the code that knows why a
request ended and the code that wakes the caller are different code. 0.17.1 fixed three defects
in this bridge. The next review round, on the queue deadline added in #95, found a fourth of the
same kind: a request whose queue deadline expired can be reported as `CancellationError`.
Patching each interleaving as a reviewer finds it has not converged, so the design changes.

**Some blocking work never goes through the bridge.**

- `resolveHost` calls `getaddrinfo` synchronously. In `performTrace` and `performStreamingTrace`
  that blocks the `SwiftFTR` actor, so `cancelActiveTraces()` and `networkChanged()` wait behind
  it. `ping` is `nonisolated` and the TCP and UDP probes are free functions; for those the blocked
  resource is a thread of Swift's cooperative pool.
- Standalone `getPublicIPs` runs blocking family sweeps in plain `Task` closures, and
  `stunGetPublicIPWithFallback` resolves every server name before trying the first endpoint, so
  one stalled name withholds an alternative that already resolved.
- The receive handlers for trace, streaming trace and ping drain their socket in `while true` on
  the serial queue that also delivers their deadline timer and cancellation, so a socket that
  stays readable with irrelevant replies can starve both.

**`traceClassified` has no overall deadline (#84).** Each phase has its own bound; their sum does
not, and a caller that gives up cannot tell which phase it was waiting on.

The alternative considered was to keep the current executor and add event-order tests around it.
That would catch regressions but leaves four owners of one decision, which is the cause.

## What stays

- `OperationQueue` as the bounded worker transport, with eight slots.
- The task-local test seams (`TestSeams.swift`), the loopback fixtures and the offline
  fault-injection battery from #94.
- Source compatibility for existing calls. The one proposed exception is a new error case; see
  Decisions. New options are added as separate initializer overloads so existing initializer
  calls keep their exact function type.
- The downstream contracts in `CLAUDE.md`: single destination-string entry points, canonical
  address form, zone-suffix preservation, family-agnostic errors, concurrent-ping safety,
  unprivileged sockets.
- Graceful degradation, the 0.15.0 contract: a trace whose probes succeeded returns its hops even
  when enrichment does not finish.

## Stages

Each stage is one pull request under about 2,000 changed lines, reviewed by Codex before merge,
with tests shown to fail without the change. A stage that outgrows the cap is split, not
overridden.

The order puts the fixes that do not depend on the executor first, so a second-pass blocker on
the executor rewrite cannot strand them or the release.

### Independent Fixes

The part of #95 that does not touch the executor's internals (about 1,700 of its 1,773 changed
lines; 69 are in `Utils.swift`):

- A network change ends every operation in flight, including a trace's reverse-DNS wave and
  `discoverPaths`, which now throws `TracerouteError.cancelled`.
- `discoverPaths` honors `publicIPDiscoveryTimeout`.
- A cancelled reverse-DNS lookup is not cached as a miss.
- A STUN timeout under one microsecond no longer waits forever.
- Invalid DNS inputs are reported before queueing, including a source address of the wrong
  family.

Carried in from review:

- `discoverPaths` returning a stale topology after cancellation. `main` already checks
  cancellation just before building the topology; another check nearer the `return` only narrows
  the window. The fix is a commit rule: validate the originating network generation and publish
  the result in one non-suspending step on the owning actor. A result committed before the
  invalidation may succeed. Test both orders with a gate at publication.
- Three weak tests: the public-IP stall test asserts that discovery was entered; the cancellation
  helper gets a watchdog and asserts the cancellation source; liveness tests stop using the
  unguarded `measure {}`.
- The two follow-ups recorded on #95: ping under a non-transient send fault, and a valid reply
  behind random datagrams still being processed.

Left for Request State Machine: the DNS queue deadline and the tests that depend on it.

This stage starts the upgrade guide (see Upgrade guide).

### Receive Loop Bounds

`TraceReceiveOperation.handleRead`, `StreamingTraceReceiveOperation.handleRead` and
`PingOperation.handleRead` each drain in `while true` on the serial queue that delivers their
timer and their cancellation resume.

- Bound the datagrams handled per callback, and inside the loop check both the finished flag and
  the absolute deadline. For streaming, the retry timer must not be starved either.
- Check both `fcntl` calls that set `O_NONBLOCK` on the trace paths, as `Ping.swift` does.
- Keep descriptor ownership through cleanup. Resuming the caller early while a callback still
  uses the descriptor would let `defer { close(fd) }` race it. The trace paths also close the
  descriptor right after cancelling the read source, where ping and the TCP and UDP probes close
  it in the source's cancel handler; align the trace paths with those.

Tests: a loopback socket kept readable with well-formed replies carrying a foreign identifier
(malformed packets end the drain at once, so they do not exercise this), for all three handlers;
an injected `fcntl` failure, which needs a new seam.

### Release 0.18.0

After the two stages above. Bump `Version.swift`, consolidate `Unreleased` into a section
organized by user-visible value with "Behavior changes" first, finish the upgrade guide for what
shipped, tag the release-prep merge commit. Tagging and publishing need David's explicit go.

### Request State Machine

Replace `ContinuationBox`, `BlockingIOCancellationBridge` and `DeadlineTimerBox` with one
`Request<T>` per call, allocated before the cancellation handler is installed so the handler, the
submitter, the worker and the timer hold the same object. One lock. The decision logic is a
value type, `RequestState.step(event, now) -> (RequestState, effects)`, and the production
`Request` calls that same function under its lock; there is no second model.

Caller state and worker state are tracked separately, because a released caller with a worker
still running is a normal combination.

- Caller: `pending`, then `finished(reason)`, where reason is one of `completed`, `cancelled`,
  `expiredBeforeStart`, `expiredWhileRunning`. Once set it never changes.
- Worker: `created`, `queued`, `running`, `exited`.

| Event | Decided under the lock, with `now` read under the lock |
|---|---|
| Attach continuation | If the caller is already finished, deliver the stored outcome. Otherwise hold the continuation. |
| Submit | If the caller is already finished, do not enqueue and do not arm a timer. Otherwise the worker becomes `queued` and a timer is armed for the earliest applicable deadline. |
| Worker start | If the caller is finished, exit without running the body. If `now` is at or past the queue deadline or the overall deadline, commit `expiredBeforeStart` itself and resume the caller; do not wait for the timer. Otherwise the worker becomes `running`, the queue deadline stops applying, and the timer is re-armed for the overall deadline if there is one. |
| Worker return | The worker becomes `exited` and the slot is released, always. If the caller is pending: `completed` when `now` is before the overall deadline, otherwise `expiredWhileRunning`. If the caller is finished, the result is discarded. |
| Timer fires | If an applicable deadline has been reached, commit the matching expiry reason. If none has (an early fire), re-arm. |
| Cancel | If the caller is pending and no applicable deadline has been reached at `now`, commit `cancelled`. If one has been reached, commit the expiry reason: the deadline came first, and only the timer was late. |

Rules that go with the table:

- One clock for decisions and timers. Today `monotonicNow()` reads `CLOCK_MONOTONIC` and Dispatch
  timers run on the uptime clock, which have different epochs and behave differently across
  sleep. The executor takes absolute instants on the uptime clock, not relative seconds.
- `finish` drops the body closure under the lock, so a request that ended while queued releases
  what it captured even though `OperationQueue` keeps the cancelled operation until a worker is
  free. Operation and timer closures hold the request weakly; the call frame holds it strongly
  for the duration of the await.
- The continuation is resumed and timers and operations are cancelled after the lock is released.
  A timer source is created only when it will be resumed. A finished request never acquires a
  live timer.
- No `completionBlock`. Slot accounting is in the execution block's `defer`.
- Every request carries a deadline: the `nil` default on `BlockingIOExecutor.run` and
  `runDetachedBlockingIO` goes away, so a request that waits forever does not compile. That is
  what bounds queued work without a separate queue limit.
- Counters for pressure are kept here: queued, running, and running after the caller finished (a
  subset of running). They are internal until Overall Deadline decides the public shape.

The DNS queue deadline from #95 lands here with its call sites in `DNS.swift` and its
public-facing regression test (a query that never gets a worker throws `DNSError.timeout`; a
query that started is not cut off).

Tests, in four layers:

1. The transition function, exhaustively over short event histories with a manual instant,
   including equality at each deadline. An oracle checks the outcome, body run count at most one,
   resume count exactly one.
2. The real `Request` and executor with an injected clock and timer driver, on the real
   `OperationQueue`, real continuation and real cancellation handler. Workers are gated with
   semaphores. Retention is asserted with weak references while the workers are still held, not
   after they drain.
3. A conformance test that pins the `OperationQueue` behavior the design relies on: a cancelled
   queued operation stays counted and keeps its block until a worker frees.
4. A short stress run on the real queue, under Thread Sanitizer.

A mutation manifest starts here: a checked-in list pairing each invariant with a deliberate
mutation of the transition function and the test that must fail for the named reason. First
entries: drop a cancellation that arrives before attach; report cancellation on queue expiry;
allow start after expiry; suppress the timer (in a history with no later event to rescue it);
do not re-arm an early timer; report cancellation when cancel arrives after the deadline; keep
the body after finish. Tests that can hang, trap or leak run in a child process a parent can
kill; swift-testing exit tests are the first thing to try for that.

If the rewrite plus its tests passes about 1,500 lines, the mutation runner and child-process
harness move to their own pull request directly after.

### Overload Is Not A Network Observation

- `reverseDNS(_:using:)` collapses every `getnameinfo` failure to `nil`. Add an internal variant
  that keeps the status, and carry typed outcomes to `RDNSCache`: answer, confirmed no name
  (`EAI_NONAME`), transient failure, resolver timeout (`expiredWhileRunning`), no worker in time
  (`expiredBeforeStart`), cancelled.
- Cache only an answer or a confirmed no name. Only a resolver timeout counts toward the stall
  breaker; only an answer or confirmed no name resets it. A slow success no longer counts as a
  stall.
- `traceClassified` builds its second reverse-DNS wave from every hop without a hostname. Once
  timeouts stop being cached, that would re-query each failed hop for another full budget. The
  second wave is limited to addresses the first wave did not attempt.
- Cap enrichment (reverse DNS and Cymru ASN queries) below the eight slots, so stalled lookups
  cannot hold every worker. This must land before forward resolution shares the queue. The cap's
  value is chosen in this stage from a test that stalls enrichment and measures a forward lookup;
  six of eight is the starting proposal, not a measured number.

The public optional hostname is unchanged. DNS queries keep mapping queue expiry to
`DNSError.timeout`.

### Resolution Off The Actor

- Split `resolveHost` in `Hostname.swift`. A literal address must not need a shared worker.
  Forced-family literals already take a fast path with no `getaddrinfo`. In `.auto` mode a
  literal still goes through `getaddrinfo` so the system can synthesize a NAT64 address; that
  call stays, off the actor, on a path that cannot be starved by the shared slots. Unverified,
  and to be measured first in this stage: whether `getaddrinfo` on a literal can block on a dead
  resolver, and whether `AI_NUMERICHOST` keeps NAT64 synthesis.
- Names go through one async adapter onto the executor, with a deadline. Results are identical
  to today: first system-selected address, zone suffix kept, forced-family mismatch enforced.
  The adapter reads `TestSeams.resolveHost` on the async side before submitting, because a worker
  thread cannot see task-locals.
- A resolution that expired before a worker picked it up is reported as that, not as
  `resolutionFailed`, which would present a busy pool as a DNS answer.
- Cancellation maps consistently: a trace cancelled during resolution throws what a trace
  cancelled during probing throws. `TraceHandle` cancellation and task cancellation both reach
  the resolution, and the first reverse-DNS batch in `performTrace`.
- The TCP and UDP probes spend one budget: resolution time comes out of `config.timeout`, and
  the probe gets what is left, so the worst case is not doubled.
- `discoverPaths` resolves the destination once and passes the address to its flows.
- STUN: coordinate asynchronously and submit each blocking attempt as its own request. Public-IP
  discovery is currently called inside a `runDetachedBlockingIO` closure; it is lifted out so no
  executor worker ever waits on another executor request. An endpoint is tried as soon as its
  name resolves; a family that succeeded is returned at the cap even while a losing lookup is
  still stalled. `resolveSTUNServer` gets a seam. First-ready selection can change which server
  supplies the address; the changelog says so.

Tests: with a trace's resolver gated shut and shown to have been entered, `cancelActiveTraces()`
returns and the victim trace finishes, while the gate stays shut. With all eight workers held, a
literal `trace` and `ping` still return. With at least core-count pings stuck in resolution, an
unrelated async task still runs. A healthy STUN endpoint beside a stalled name yields an address,
in both classified and standalone discovery.

### Overall Deadline

The #84 contract, for `traceClassified` and `discoverPaths` (including the per-flow pipeline in
`performClassifiedTraceWithFlowID`).

- One absolute deadline on the executor's clock, started on entry to the actor-isolated method.
  Time spent waiting to enter the actor is not counted; after Resolution Off The Actor, nothing
  blocks the actor for long.
- The default is the sum of the caps of the phases that are active for this call (skipping
  disabled reverse DNS, a configured or cached public IP, an embedded ASN database), plus a
  stated scheduling allowance. So by default it fires only when a phase overran its own cap. A
  caller-supplied total replaces the default.
- A phase may tighten the deadline and never resets it. At a phase's own cap, enrichment degrades
  as now. Classification gets its own cap, and when it expires the trace is returned with ASN
  data missing.
- Phase changes and the final return read the clock under the same lock as expiry, and commit
  expiry for the outgoing phase when the deadline has passed. A late timer cannot blame the next
  phase or lose to a late result. When a phase cap equals the overall cap, the overall expiry is
  the reported one.
- Hops are never discarded. If the overall deadline passes after the probe window, the measured
  hops are returned (see Decisions for how).
- `TraceHandle` is an actor reached through `Task { await handle.cancel() }`, and
  `withTraceCancellation` hard-codes `TracerouteError.cancelled`. Naming the right phase needs a
  synchronous cancel source that carries a reason: caller, network change, or deadline. This is
  a second small state machine and is budgeted as part of this stage, built on the same pattern
  as `RequestState`.
- Public-IP discovery that was attempted and got no answer is remembered for the rest of the
  call, so the classifier does not start it again.
- Work left behind has an owner. The shared ASN load in `_ASNMemoryCache` is cancelled when its
  last waiter leaves; each subscriber's wait has its own deadline; the count of abandoned
  resolver calls is bounded. An injected `ASNResolver` that ignores cancellation cannot be
  stopped: the caller is released and the documentation says so.
- Executor pressure becomes readable.

What the library promises: the deadline decision is made at the deadline and the caller is
resumed promptly, subject to scheduling. It cannot stop a `getaddrinfo` already in the kernel.

Tests: a caller-tightened total with phases that each finish inside their own cap but whose sum
exceeds it; expiry in each phase names that phase; two subscribers to one ASN load with
different deadlines; repeated expiry against a gated resolver leaves a bounded number of calls
behind.

## Gates

A stage is done when these pass on its branch, with the output in the PR body:

```bash
swift format lint --strict -r Sources Tests
SKIP_NETWORK_TESTS=1 PTR_SKIP_STUN=1 swift test -c debug          # twice in a row
SKIP_NETWORK_TESTS=1 PTR_SKIP_STUN=1 swift test -c release
swift package diagnose-api-breaking-changes v0.17.1 --products SwiftFTR
swift package --allow-writing-to-directory docc generate-documentation --target SwiftFTR \
  --output-path docc --transform-for-static-hosting --warnings-as-errors
~/.claude/bin/orphan-audit
~/.claude/bin/codex-review --base origin/main                     # SHIP, within three rounds
```

- The release-mode run is there because optimized builds shorten object lifetimes, which is how
  a weakly held request would be freed early.
- After 0.18.0 the API check also runs against `v0.18.0`. If the new error case is accepted, it
  goes in a breakage allowlist file passed to the check, and nothing else does.
- From Request State Machine onward: the stress test passes under
  `swift test --sanitize=thread --filter <the stress suite>`, and the mutation manifest runner
  reports every mutant killed by its named test for the named reason. A mutant that fails to
  compile or fails an unrelated test earns no credit. Both commands are filled in here when the
  suites exist.

If a second review pass on any stage finds a new blocker, the stage stops and the decision goes
to David.

## Upgrade guide

`Sources/SwiftFTR/SwiftFTR.docc/MigratingTo018.md`, a DocC article like `MigratingTo014.md`,
written for both people and coding agents updating a consumer from 0.17.

- It starts in Independent Fixes and each later pull request that changes behavior adds its
  entry in the same change.
- Each entry has the same shape: what changed, what a caller sees, and what to change, with
  before-and-after code an agent can apply mechanically.
- Release gate: every line under "Behavior changes" in the changelog section being released has
  a matching entry. Stages that ship after 0.18.0 get their own guide for that release.

## Decisions for David

Each has a recommended default. Work proceeds on the default until he says otherwise. None blocks
Independent Fixes or Receive Loop Bounds.

1. **Overall deadline on by default?** Recommended: yes, with the default equal to the sum of
   the active phase caps plus an allowance, and a caller-supplied total that replaces it. All
   three reviewers said yes on that condition. What changes for an existing caller: a call that
   used to return very late now ends at the deadline, and a caller that retries on error may
   retry sooner.
2. **What happens to the hops when the overall deadline passes after probing?** Recommended:
   return the `ClassifiedTrace` with enrichment missing and a field naming the phase that ran
   out, and throw only when the deadline passes before the probe window completes. The
   alternative is to throw and carry the partial trace in the error.
3. **Shape of the deadline error.** The reviewers split.
   - A new `TracerouteError` case (Fable, Gemini; the author's recommendation): callers route on
     `TracerouteError`, so a separate type would fall into a generic catch at run time with no
     warning, while a new case breaks exhaustive switches at compile time, which is the louder
     signal. 0.14 added `DNSError` cases in a minor release. The phase payload would be a struct
     with static members, so a later phase is not a second break.
   - A separate type such as `TraceDeadlineExceeded` (Codex): it keeps existing code compiling,
     which is the source-compatibility rule as stated.
4. **Executor pressure as public API?** Recommended: yes, a read-only snapshot, since #84 asks
   for it to tell a slow network from a busy library.
5. **When to cut 0.18.0.** Recommended: after Independent Fixes and Receive Loop Bounds.
6. **Forward-resolution budget.** There is no configuration to derive one from today. A slow but
   working resolver succeeds now and would fail once resolution has a deadline. Recommended: a
   new `SwiftFTRConfig` option for traces, defaulting to 10 seconds, with probes spending from
   their existing `timeout`. The 10 seconds is a proposal, not a measurement.

## Out of scope

Still unbounded after this plan, or deliberately deferred. Roadmap, not this plan:

- Replacing `getaddrinfo` and `getnameinfo` with DNS-SD, which would free the worker slot as
  well as the caller. It needs resolver parity shown on real networks first.
- Non-blocking sockets with Dispatch sources for direct DNS, the Cymru TXT queries and STUN.
- The public synchronous `reverseDNS(_:)`, direct `TraceClassifier.classify` with an
  uncooperative resolver, and `preloadASNDatabase()` with a remote source.
- `testBufferbloat`, whose load generation uses `URLSession.shared` and is awaited without
  cancellation after the ping phase ends.
- The `swift-ftr` CLI's own synchronous `reverseDNS` and `getaddrinfo` calls.
- Collapsing the multipath per-flow pipeline onto the shared classified-trace implementation,
  which would also fix the configuration it drops (#91).
- Coalescing identical in-flight forward lookups.
- The UDP probe's receive loop, which has the same shape as the three fixed in Receive Loop
  Bounds and has not been read closely.
- Address Sanitizer, scheduled soak runs, DNS and STUN parser fuzzing.
- Root cause of the production timeouts in #84. This plan gives the instrumentation to find it;
  56 of 59 reported calls returned within five seconds of cancellation, so a blocked resolver is
  not established as the cause.

## Review record

Reviewed once, on 2026-11-22, by Codex (`gpt-6.2-astra`, high), Gemini (`gemini-4-carbon-high`)
and Claude Fable 5.2 (high), each without sight of the others.

Folded in:

- The first draft said ping and the TCP and UDP probes resolve on the actor. They do not (all
  three). Its test "a ping to a literal completes" passed on `main` already.
- Moving resolution onto the shared slots would have made literal traces wait behind stalled
  reverse lookups, the #84 pattern (Fable, Gemini). Hence the literal path, the enrichment cap,
  and Overload landing before Resolution.
- The transition table was too thin to implement: no submit transition, no clock read at worker
  return, no rule for a cancel after the deadline, two clocks (all three).
- Receive Loop Bounds before Overall Deadline (all three), and ping's handler included (Gemini).
- Only 69 lines of #95 are in the executor, so its other fixes ship first (Fable).
- Finish reasons, absolute instants and pressure counters belong in the state machine from the
  start, or it is reopened three times (Fable, Gemini).
- A pure transition function cannot see the libdispatch trap or a leak, so the tests run the
  real queue with an injected clock and timers, plus Thread Sanitizer (all three).
- Hops must survive the overall deadline (Fable, Gemini, Codex).
- Nested executor use in STUN, the task-local seam on worker threads, doubled probe budgets, the
  repeated reverse-DNS wave, lost `getnameinfo` status, ownership of abandoned ASN work, the
  `discoverPaths` commit rule (Codex, Gemini).

Declined, with the reason:

- One instant type across every probe file (Gemini). The executor and the overall deadline use
  one clock; the probes' RTT timing is separate and not part of this plan.
- A bound on queued work (Codex). Making a deadline mandatory on every request bounds it.
- Starting the deadline before actor entry (Codex raised the choice). It would need the public
  methods to change isolation, which breaks the API check.

Unverified claims this plan repeats: that a stalled `getnameinfo` holds a slot for about 30
seconds (repo comments and an earlier measurement, not re-measured); the 161-of-1,000
stale-topology figure (Codex's measurement). Fable measured `CLOCK_MONOTONIC` running 7.6 ppm
slower than the Dispatch clock on one machine and did not observe an early timer fire.
