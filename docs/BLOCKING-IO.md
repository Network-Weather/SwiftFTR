# Blocking I/O: one owner per request, one deadline per operation

Sequenced plan for the ROADMAP item "Robustness under network and DNS failure, proven by tests".
Stage: product. Status: plan, nothing below has shipped. Completed stages get struck through as
they land.

## Why

SwiftFTR runs inside software that is diagnosing a broken network, so a resolver that never
answers or a link that drops mid-operation is its normal operating condition. The promise the
library has to keep is the roadmap goal: every public operation returns or throws within a time
the caller can work out from its configuration.

Two things stand between the code and that promise.

**The bridge to blocking calls keeps producing races.** `BlockingIOExecutor` (`Utils.swift`)
carries reverse DNS, DNS and ASN queries, and public-IP discovery during a classified trace onto
eight worker slots. Four objects can each end a request: the operation's block, the deadline
timer, the task-cancellation handler, and the completion-block backstop in
`BlockingIOCancellationBridge`. `ContinuationBox` guarantees the caller is resumed once. It does
not guarantee the caller is resumed with the right answer, because the code that knows why a
request ended and the code that wakes the caller are different code. 0.17.1 fixed three defects
in this bridge (a libdispatch trap, a stranded caller, leaked queued operations). The next review
round, on the queue deadline added in #95, found a fourth of the same kind: a request whose queue
deadline expired can be reported as `CancellationError`. Patching each interleaving as a reviewer
finds it has not converged, so the design changes.

**A correct bridge still leaves public operations unbounded**, because some blocking work never
goes through it:

- `resolveHost` calls `getaddrinfo` synchronously on the `SwiftFTR` actor from trace, streaming
  trace, ping, and the TCP and UDP probes. While it blocks, nothing else can enter the actor, so
  `cancelActiveTraces()` and `networkChanged()` wait too.
- Standalone `getPublicIPs` runs its blocking family sweeps in plain `Task` closures, and STUN
  resolves every server name before trying the first endpoint, so one stalled name withholds an
  alternative that already resolved.
- `traceClassified` has no overall deadline (#84). Each phase has its own bound; their sum does
  not, and a caller that gives up cannot tell which phase it was waiting on.

The alternative considered was to keep the current executor and add event-order tests around it.
That would catch regressions but leaves four owners of one decision, which is the cause.

## What stays

- `OperationQueue` as the bounded worker transport, with eight slots. Nothing measured says a
  different number is better.
- The task-local test seams (`TestSeams.swift`), the loopback fixtures and the offline
  fault-injection battery from #94. They found real defects in the assembled library.
- Every public signature. `swift package diagnose-api-breaking-changes v0.17.1` reports no
  breaking change at each stage. New enum cases are the one exception; see Decisions.
- The downstream contracts in `CLAUDE.md`: single destination-string entry points, canonical
  address form, zone-suffix preservation, family-agnostic errors, concurrent-ping safety,
  unprivileged sockets.

## Stages

Each stage is one pull request under about 2,000 changed lines, reviewed by Codex before merge,
and lands with tests that were shown to fail without the change.

### Request State Machine

Replace `ContinuationBox`, `BlockingIOCancellationBridge` and the per-call use of
`DeadlineTimerBox` with one `Request<T>` object per call, allocated before the cancellation
handler is installed so the handler, the submitter, the worker and the timer all hold the same
object. It has one lock and one `finish` transition.

| Event | Decided under the request's lock |
|---|---|
| Continuation installed | Attach it if the request is pending. If cancellation or expiry already won, deliver the stored outcome. |
| Worker starts | Read the monotonic clock under the lock. A request past its queue deadline or overall deadline is never given permission to run its body. |
| Timer fires, caller cancels, or worker returns | One `finish`. The first reason to commit is stored and never changes. A queue deadline stops applying once the body has started. |
| Worker returns after the caller was released | Release the slot, discard the result. |

Rules that go with it: a deadline wins when `now >= deadline`; an earlier committed cancellation
stays a cancellation; a late timer cannot extend admission or turn a late result into success.
The continuation is resumed and timers and operations are cancelled after the lock is released.
Timer sources are created only when they will be resumed. No closure cycle keeps a finished
request alive. The completion block may account for cleanup but never decides the caller's
outcome.

The executor takes both deadline kinds: `deadline` (the caller stops waiting) and `queueDeadline`
(work not started by then is withdrawn, started work is never cut off). The second is lifted
from #95.

Tests: the transition logic is a pure function driven by a manual clock and a scheduler the test
controls, so a test can advance past expiry while withholding the timer and then deliver start,
cancellation, completion, attachment and timer in every order, including equality at the
deadline. Short histories are enumerated exhaustively; longer multi-request histories are seeded
and replayable. An independent oracle checks the outcome, how many times the body ran, the resume
count, slots held and objects retained. One short stress run against the real queue stays, for
schedules the model missed. The existing `BlockingIOStrandingTests`, `DeadlineTimerBoxTests` and
`CymruQueueDeadlineTests` keep passing or are replaced by a stronger equivalent, said in the PR.

A mutation manifest starts here: a checked-in list pairing each invariant with a deliberate
mutation and the test that must fail for the named reason. First entries: drop a cancellation
that arrives before the continuation is attached; report cancellation on queue expiry; allow
start after expiry; suppress the timer; retain a finished request. Tests that can hang, trap or
leak run in a child process with a parent watchdog that kills and reaps it.

### Fault Battery Fixes

Rebase #95 onto the new executor: the network-change, `discoverPaths`, reverse-DNS caching, STUN
timeout and DNS input-check fixes with their tests, and the DNS queue deadline now served by the
state machine. Three items carried in from review:

- `discoverPaths` can return a stale topology after cancellation (Codex measured 161 of 1,000).
  The cancellation check moves to the point where the result is committed.
- The queue-edge test that assumed a submit-time deadline is replaced by a forced
  late-worker history from the state-machine tests.
- Three weak tests named in the strategy review are fixed: the public-IP stall test asserts that
  discovery was entered; the cancellation helper gets a watchdog and asserts the cancellation
  source; liveness tests stop using the unguarded `measure {}`.

Also the two follow-ups recorded on #95: ping under a non-transient send fault, and a valid reply
behind random datagrams still being processed.

### Resolution Off The Actor

One async resolver adapter with a finite, configuration-derived budget, used by trace, streaming
trace, ping, and the TCP and UDP probes. `getaddrinfo` still runs, on the executor, so results
are identical to today: first system-selected address, zone suffix kept, forced-family mismatch
enforced, `.auto` IPv4 literals still sent through the system for NAT64. The actor is free while
it runs.

Standalone `getPublicIPs` goes under the same bounded admission, loses its nested blocking
fan-out, and keeps returning a partial result when one family answers. STUN tries an endpoint as
soon as its name resolves instead of waiting for all names.

Tests: with the resolver gated shut, a cancelled trace returns, and a second call on the same
actor (`cancelActiveTraces()`, a ping to a literal) completes. A healthy STUN endpoint beside a
stalled name still yields an address.

### Overall Deadline

The #84 contract. One absolute monotonic deadline is set at the public boundary and passed
through admission, resolution, the probe window, retries, enrichment and classification. A phase
may tighten it (`min(parent, phaseStart + phaseBudget)`) and never resets it.

- At a phase's own cap, enrichment degrades as it does now: the trace returns with the hostname,
  ASN or public IP missing.
- At the overall cap, the call throws an error naming the phase that was running. Phase changes
  and expiry commit under one lock so a late timer cannot blame the next phase.
- Public-IP discovery that was attempted and got no answer is remembered for the rest of the
  call. Today `traceClassified` passes `nil` on and the classifier starts discovery again.
- Classification gets its own cap. The Cymru path has two stages and a semaphore ahead of the
  per-query executor deadline, so that deadline cannot bound a batch.
- A snapshot of executor pressure is readable: queued, running, and running after the caller
  gave up, with queue wait recorded separately from run time.

What the library can promise is that the caller is released at the deadline and abandoned work
stays bounded. It cannot stop an injected resolver's Swift code or a `getaddrinfo` already in
the kernel; the documentation says so.

Tests: a trace whose phases each finish inside their own limit but whose sum exceeds the total,
which no per-phase test can cover; expiry in each phase names that phase.

### Overload Is Not A Network Observation

`RDNSCache` uses `try?` around the executor, so a lookup that never got a worker becomes `nil`,
can be cached for the full TTL, and counts toward the resolver-stall breaker. Carry typed
internal outcomes instead: answer, confirmed no name, resolver timeout, no worker in time,
cancelled. Cache only the first two. Only a resolver timeout counts toward the breaker. The
public optional hostname is unchanged. DNS queries keep mapping queue expiry to
`DNSError.timeout`.

### Receive Loop Bounds

`TraceReceiveOperation.handleRead` and its streaming twin drain in `while true` on the serial
queue that also delivers their deadline, so a socket that stays readable with irrelevant replies
can starve the timer. Bound the work per callback and check the absolute deadline while
draining. Both trace paths also ignore a failed `O_NONBLOCK`; check it as `Ping.swift` does.
Tests: a continuously readable loopback socket, and an injected `fcntl` failure.

### Release 0.18.0

After Fault Battery Fixes lands: bump `Version.swift`, consolidate `Unreleased` into a section
organized by user-visible value with "Behavior changes" first, tag the release-prep merge commit.
Tagging and publishing need David's explicit go. The later stages ship in the release after.

## Gates

A stage is done when these pass on its branch, with the output in the PR body:

```bash
swift format lint --strict -r Sources Tests
SKIP_NETWORK_TESTS=1 PTR_SKIP_STUN=1 swift test -c debug          # twice in a row
swift package diagnose-api-breaking-changes v0.17.1 --products SwiftFTR
~/.claude/bin/orphan-audit
~/.claude/bin/codex-review --base origin/main                     # SHIP, within three rounds
```

From Request State Machine onward, one more: the mutation manifest runner applies each listed
mutation, and every one must fail its named test for the named reason while the clean tree
passes. A mutant that fails to compile or fails an unrelated test earns no credit. The runner is
built in that stage; its command goes here when it exists.

If a second review pass on any stage finds a new blocker, the stage stops and the decision goes
to David.

## Decisions for David

Each has a recommended default. Work proceeds on the default until he says otherwise; none of
these blocks Request State Machine or Fault Battery Fixes.

1. **Is the overall deadline on by default?** Recommended: yes, with a published formula
   (resolution budget, plus probe window and retry allowance, plus the configured enrichment
   waves, plus the classification cap), and an optional `TraceOptions` total budget to tighten
   it. The roadmap goal is a bound on every call, and a caller-supplied-only budget leaves
   existing callers unbounded. The cost is a behavior change: a call that used to return very
   late now throws.
2. **The shape of the deadline error.** Recommended: a new `TracerouteError` case carrying the
   phase. Adding a case breaks callers that switch exhaustively over the enum, which 0.14 already
   did for `DNSError` in a minor release. The alternative is a separate error type.
3. **Is executor pressure public API?** Recommended: yes, a read-only snapshot, because #84
   asks for it in order to tell a slow network from a busy library.
4. **When to cut 0.18.0.** Recommended: after Fault Battery Fixes, so the fixes already written
   reach consumers without waiting on the deadline API.

## Out of scope

Roadmap, not this plan:

- Replacing `getaddrinfo` and `getnameinfo` with DNS-SD (`DNSServiceGetAddrInfo`,
  `DNSServiceQueryRecord`), which would free the worker slot as well as the caller. It needs
  resolver parity shown on real networks first: family selection, hosts-file names, search
  domains, `.local`, VPN split DNS, DNS64 and NAT64.
- Non-blocking sockets with Dispatch sources for direct DNS, the Cymru TXT queries and STUN.
- Reserved capacity for forward resolution inside the eight slots, and a bound on queued work.
- Thread Sanitizer and Address Sanitizer jobs, scheduled soak runs, DNS and STUN parser fuzzing.
- A loopback fixture for the remote ASN database load with two subscribers.
- The public synchronous `reverseDNS(_:)` getting a finite wait.
- Root cause of the production timeouts in #84. This plan gives the instrumentation to find it;
  56 of 59 reported calls returned within five seconds of cancellation, so a blocked resolver is
  not yet established as the cause.

## Sources

The design follows a strategy review by Codex (`gpt-6.2-astra`, 2026-11-22), read against PR #94
and PR #95, and the review history of #87, #93 and #95. Claims about current code were checked
against `main` when this was written. The 161-of-1,000 stale-topology figure is Codex's
measurement and has not been reproduced here.
