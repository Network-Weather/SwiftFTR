# Event-based I/O: no thread held while waiting, one deadline per operation

Sequenced plan for the ROADMAP item "Robustness under network and DNS failure, proven by tests".
Stage: product. Status: plan; see Review record for what has been reviewed. Completed stages get
struck through as they land.

## Why

SwiftFTR runs inside software that is diagnosing a broken network, so a resolver that never
answers or a link that drops mid-operation is its normal operating condition. The roadmap goal is
that every public operation returns or throws within a time the caller can work out from its
configuration. This plan covers the trace family, ping, the TCP, UDP and DNS probes and public-IP
discovery. What it leaves unbounded is listed under Out of scope.

**The cause is that some waits hold a thread.** Ping, trace and the TCP and UDP probes wait on
Dispatch sources: no thread is held, a timer ends the wait, and cancellation closes the socket.
Four kinds of work are written as blocking calls instead:

| Work | How it waits today |
|---|---|
| DNS probes and Team Cymru ASN lookups | a blocking `recv` on a UDP socket with a receive timeout (`performDNSQueryInternal`, `DNS.swift`) |
| STUN public-IP discovery | the same, plus `getaddrinfo` for each server name |
| Reverse DNS | `getnameinfo` |
| Forward resolution of a destination | `getaddrinfo` |

A thread parked in one of those calls cannot be a cooperative-pool thread, so the first three
run on `BlockingIOExecutor` (`Utils.swift`), eight worker slots behind an `OperationQueue`, and
the fourth runs inline. Everything hard about this area follows from that:

- **Work queues for a thread it does not need.** A DNS probe sends one UDP packet, yet it waits
  for a free slot, and stalled `getnameinfo` calls can hold all eight. That wait has no bound.
- **A released caller still occupies a slot.** A blocking call cannot be interrupted, so
  cancellation and deadlines free the caller while the syscall runs on.
- **The bridge keeps producing races.** Four objects can each end a request on the executor (the
  operation's block, the deadline timer, the cancellation handler, a completion-block backstop).
  0.17.1 fixed three defects in it; review of #95 found a fourth of the same kind.
- **Inline `getaddrinfo` blocks the tracer actor** in `performTrace` and
  `performStreamingTrace`, so `cancelActiveTraces()` and `networkChanged()` wait behind it. For
  `ping` (`nonisolated`) and the TCP and UDP probes (free functions) it blocks a cooperative-pool
  thread.

The first version of this plan kept the blocking calls and rewrote the bridge as a per-request
state machine. That would have made the bridge correct and left every other item above in place.
Making the four kinds of work event-based removes the bridge, the slots and the queue, so there
is nothing to starve and nothing to race, and cancellation actually stops the work.

Two further defects are independent of this and are fixed first: the receive handlers for trace,
streaming trace and ping can starve their own deadline timer, and `traceClassified` has no
overall deadline (#84).

## What stays

- Every public signature. New options are added as separate initializer overloads so existing
  calls keep their exact function type. The one proposed exception is a new error case; see
  Decisions.
- The task-local test seams (`TestSeams.swift`), the loopback fixtures and the offline
  fault-injection battery from #94.
- The downstream contracts in `CLAUDE.md`: single destination-string entry points, canonical
  address form, zone-suffix preservation, family-agnostic errors, concurrent-ping safety,
  unprivileged sockets.
- Graceful degradation, the 0.15.0 contract: a trace whose probes succeeded returns its hops even
  when enrichment does not finish.
- The system resolver for names. Forward and reverse lookups keep going through macOS's
  resolver (via its event-based API), not a DNS client of the library's own, because split DNS,
  VPN resolvers, search domains and `.local` are part of what the host network is.
- `BlockingIOExecutor`, unchanged, until the last stage removes it.

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

Not ported: #95's DNS queue deadline. DNS Wait Bound covers the wait until Event-Based DNS
removes it.

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

### Consistent Cancellation

Two error types mean two things: `CancellationError` when the caller cancelled its own task, and
`TracerouteError.cancelled` when the library ended the operation (`networkChanged()`,
`cancelActiveTraces()`). Today the mapping is not consistent. `PingExecutor.ping` throws
`TracerouteError.cancelled` for task cancellation, and a trace throws either type for the same
cause depending on which check notices first (`Task.checkCancellation()` beside
`throw TracerouteError.cancelled` in `Traceroute.swift`). A caller that retries on
`TracerouteError.cancelled` therefore sometimes retries after its own cancellation.

Apply the rule `discoverPaths` gets in Independent Fixes to trace, streaming trace and ping:
task cancellation always throws `CancellationError`; a library-side cancel always throws
`TracerouteError.cancelled`; when both have happened, the library-side cancel is reported, since
it carries more information. The fault battery's cancellation tests stop accepting either type.
This is a behavior change and gets an upgrade-guide entry.

### DNS Wait Bound

Until DNS is event-based, a DNS probe can wait without limit for a worker slot. Give each query
an overall deadline of three times its `timeout` on the existing executor, as 0.17.1 did for the
Team Cymru lookups. A started query finishes within about twice its `timeout` (one for send, one
for receive), so the deadline does not cut off a healthy query. A query that hits it throws
`DNSError.timeout`. This is a few lines and is replaced by Event-Based DNS.

### Release 0.18.0

After the four stages above. Bump `Version.swift`, consolidate `Unreleased` into a section
organized by user-visible value with "Behavior changes" first, finish the upgrade guide for what
shipped, tag the release-prep merge commit. Tagging and publishing need David's explicit go.

### Event-Based DNS

Rewrite `performDNSQueryInternal` as a non-blocking connected UDP socket with a Dispatch read
source and a timer, in the pattern `PingOperation` already uses. Encoding, parsing, peer checks
and interface and source binding are reused unchanged. One owner stops readiness delivery and
closes the descriptor exactly once, in the source's cancel handler. Cancellation and the deadline
close the socket; a packet already sent cannot be recalled.

This covers the public DNS probes and the Team Cymru TXT lookups, which use the same client.
After it, neither touches the executor: no slot, no queue, no wait for a worker. The semaphore in
`CymruDNSResolver.resolve` that rations executor slots is no longer needed for that purpose; it
stays only if a limit on concurrent queries to the Cymru servers is wanted for its own sake.

Tests: the existing `dnsFaults` battery (silent, slow, garbage, wrong transaction) against the
new transport; cancellation closes the socket and returns while the fixture is still silent; a
flood of well-formed replies with a foreign transaction ID does not starve the deadline; with
every executor slot held, a DNS query to a healthy loopback server still answers.

### Event-Based STUN

The same transport change for the STUN exchange. Coordination becomes asynchronous: each server
is tried as soon as its name resolves, and a family that succeeded is returned at the cap while
a losing lookup is still stalled. Public-IP discovery is lifted out of the
`runDetachedBlockingIO` closures that wrap it today. Server names resolve through the forward
resolver of the next-but-one stage; until that lands they use the existing blocking helper on
the executor, one request per name. `resolveSTUNServer` gets a seam. First-ready selection can
change which server supplies the address; the changelog says so.

Tests: the `stunFaults` battery against the new transport; a healthy endpoint beside a stalled
name yields an address, in classified and standalone discovery; standalone `getPublicIPs` still
returns a partial result when one family answers.

### Event-Based Reverse DNS

Replace `getnameinfo` in `RDNSCache` with a PTR query through the system resolver's event-based
API, `DNSServiceQueryRecord`, delivered on a serial Dispatch queue and ended with
`DNSServiceRefDeallocate` on answer, error, cancellation or deadline. No thread is held, and a
lookup that is abandoned is actually stopped.

The outcome is typed where today every failure collapses to `nil`: answer, confirmed no name,
resolver error, timeout, cancelled. `RDNSCache` caches only an answer or a confirmed no name. The
stall breaker exists to protect executor slots; with no slots it is re-examined in this stage
and kept only if a test shows it still saves a caller time. The public optional hostname and the
public synchronous `reverseDNS(_:)` are unchanged; the synchronous function keeps `getnameinfo`.

Reverse DNS goes before forward resolution because it is cosmetic enrichment: a parity gap
costs a hostname, not a trace.

Tests: a seam that substitutes the query; stall, error and no-name outcomes; a cancelled lookup
is not cached; a network change ends the wave; hostnames match `getnameinfo` for a sample of
addresses on the test machine (a gated live test).

### Event-Based Forward Resolution

One async resolver used by trace, streaming trace, ping, the TCP and UDP probes, `discoverPaths`
(resolved once, then passed to its flows) and STUN server names.

- **Names** resolve through `DNSServiceGetAddrInfo` with a deadline, cancelled by
  `DNSServiceRefDeallocate`. The tracer actor is never blocked.
- **Literals** never touch a resolver: they are parsed in-process, zone suffix kept. The DNS-SD
  call rejects literals outright (measured, below), so this split is required, not optional.
- **Address selection must match `getaddrinfo`.** Today the library takes the first address
  `getaddrinfo(AF_UNSPEC)` returns, which the system has sorted by RFC 6724 destination-address
  rules. DNS-SD delivers addresses as they arrive. The resolver collects the answers for both
  families up to a short settle time and applies the same choice. This is the main risk in the
  plan and is what the parity gate below exists for.
- **NAT64.** In `.auto` mode a v4 literal goes through `getaddrinfo` today so the system can
  synthesize a v6 address on a v6-only network. The replacement has to do the same, and how is
  not yet established; candidates are the RFC 7050 prefix discovery (`ipv4only.arpa`) and
  keeping `getaddrinfo` for this one case. Decided in this stage on a real NAT64 network.
- A resolution that timed out is reported as a timeout, not as `resolutionFailed`.
- The probes spend one budget: resolution time comes out of `config.timeout`.

**Parity gate.** A checked-in comparison tool resolves a list of names both ways and reports
every difference in chosen address, family, canonical form and zone. It is run, and its output
recorded in the PR, on: dual-stack, v4-only, v6-only with NAT64, a VPN with split DNS, names from
`/etc/hosts`, single-label names using a search domain, and `.local` names. Any difference is
either fixed or listed with the owner's acceptance. If parity cannot be reached for a case,
`getaddrinfo` is kept for that case on a dedicated thread with a deadline, and the plan says so.

A first measurement on one dual-stack Mac (2026-11-22, a scratch tool, not checked in): for
`example.com`, `one.one.one.one` and `localhost`, DNS-SD returned the same addresses in the same
order as `getaddrinfo`. For the machine's own hostname it returned the same two addresses in the
opposite order (v6 first, where `getaddrinfo` put v4 first). For IPv4, IPv6 and zoned literals it
returned an error. A name that does not exist failed in both.

Tests: with a trace's resolver gated shut and shown to have been entered, `cancelActiveTraces()`
returns and the victim trace finishes while the gate stays shut; a literal `trace` and `ping`
never call the resolver; with at least core-count pings in resolution, an unrelated async task
still runs.

### Retire The Executor

Once nothing in the library submits to it, delete `BlockingIOExecutor`, `ContinuationBox`,
`BlockingIOCancellationBridge`, `DeadlineTimerBox`, `runDetachedBlockingIO` and the executor
seam, with their tests. Whatever blocking call is left (the synchronous `reverseDNS(_:)`, any
`getaddrinfo` case kept by the parity gate) runs on its own thread with a deadline, not on a
shared pool. If a shared pool turns out to be unavoidable, this stage becomes the per-request
state machine from the first version of this plan (git history of this file, commit `006ca88`).

### Overall Deadline

The #84 contract, for `traceClassified` and `discoverPaths` (including the per-flow pipeline in
`performClassifiedTraceWithFlowID`). It can land any time after Receive Loop Bounds; it is
simpler after the event-based stages, because expiry then stops the work instead of abandoning
it.

- One absolute deadline on one monotonic clock, the one Dispatch timers use, started on entry to
  the actor-isolated method.
- The default is the sum of the caps of the phases active for this call (skipping disabled
  reverse DNS, a configured or cached public IP, an embedded ASN database), plus a stated
  scheduling allowance. So by default it fires only when a phase overran its own cap. A
  caller-supplied total replaces the default.
- A phase may tighten the deadline and never resets it. At a phase's own cap, enrichment degrades
  as now. Classification gets its own cap, and when it expires the trace is returned with ASN
  data missing.
- Phase changes and the final return read the clock under the same lock as expiry, and commit
  expiry for the outgoing phase when the deadline has passed, so a late timer cannot blame the
  next phase or lose to a late result.
- Hops are never discarded. If the overall deadline passes after the probe window, the measured
  hops are returned (see Decisions for how).
- `TraceHandle` is an actor reached through `Task { await handle.cancel() }`, and
  `withTraceCancellation` hard-codes `TracerouteError.cancelled`. Naming the right phase needs a
  synchronous cancel source that carries a reason: caller, network change, or deadline.
- Public-IP discovery that was attempted and got no answer is remembered for the rest of the
  call, so the classifier does not start it again.
- The shared ASN load in `_ASNMemoryCache` is cancelled when its last waiter leaves; each
  subscriber's wait has its own deadline. An injected `ASNResolver` that ignores cancellation
  cannot be stopped: the caller is released and the documentation says so.

Tests: a caller-tightened total with phases that each finish inside their own cap but whose sum
exceeds it; expiry in each phase names that phase; two subscribers to one ASN load with
different deadlines.

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
  an object kept alive only by a callback context is freed early.
- After 0.18.0 the API check also runs against `v0.18.0`. If the new error case is accepted, it
  goes in a breakage allowlist file passed to the check, and nothing else does.
- Each event-based stage adds one more: with every executor slot held by a gated blocker, the
  operation it converts still completes against a healthy loopback fixture. Event-Based Forward
  Resolution also has the parity gate described in its section.

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

Each has a recommended default. Work proceeds on the default until he says otherwise.

1. **Cancellation errors (Consistent Cancellation).** Recommended: fix before 0.18.0. Ping's
   error type changes for a caller that cancels its own task.
2. **Overall deadline on by default?** Recommended: yes, with the default equal to the sum of
   the active phase caps plus an allowance, and a caller-supplied total that replaces it.
3. **What happens to the hops when the overall deadline passes after probing?** Recommended:
   return the `ClassifiedTrace` with enrichment missing and a field naming the phase that ran
   out, and throw only when the deadline passes before the probe window completes. The
   alternative is to throw and carry the partial trace in the error.
4. **Shape of the deadline error.** The first-round reviewers split.
   - A new `TracerouteError` case (Fable, Gemini; the author's recommendation): callers route on
     `TracerouteError`, so a separate type would fall into a generic catch at run time with no
     warning, while a new case breaks exhaustive switches at compile time, which is the louder
     signal. 0.14 added `DNSError` cases in a minor release. The phase payload would be a struct
     with static members, so a later phase is not a second break.
   - A separate type such as `TraceDeadlineExceeded` (Codex): it keeps existing code compiling.
5. **When to cut 0.18.0.** Recommended: after the first four stages.
6. **Forward-resolution budget.** There is no configuration to derive one from today.
   Recommended: a new `SwiftFTRConfig` option for traces, defaulting to 10 seconds, with probes
   spending from their existing `timeout`. The 10 seconds is a proposal, not a measurement.
7. **Parity differences.** If the parity gate finds a case where the event-based resolver picks
   a different address than `getaddrinfo`, is matching `getaddrinfo` exactly required, or is a
   documented difference acceptable? Recommended: exact match for the chosen address on every
   listed network type, since downstream consumers compare hop and destination addresses.

## Out of scope

Still unbounded after this plan, or deliberately deferred. Roadmap, not this plan:

- The public synchronous `reverseDNS(_:)`, direct `TraceClassifier.classify` with an
  uncooperative resolver, and `preloadASNDatabase()` with a remote source.
- `testBufferbloat`, whose load generation uses `URLSession.shared` and is awaited without
  cancellation after the ping phase ends.
- The `swift-ftr` CLI's own synchronous `reverseDNS` and `getaddrinfo` calls.
- Collapsing the multipath per-flow pipeline onto the shared classified-trace implementation,
  which would also fix the configuration it drops (#91).
- Coalescing identical in-flight forward lookups.
- The UDP probe's receive loop, unless Receive Loop Bounds finds it has the same defect.
- Thread Sanitizer and Address Sanitizer jobs, scheduled soak runs, DNS and STUN parser fuzzing.
- Root cause of the production timeouts in #84. This plan gives the means to find it; 56 of 59
  reported calls returned within five seconds of cancellation, so a blocked resolver is not
  established as the cause.

## Review record

**First version (per-request state machine), 2026-11-22.** Reviewed once by Codex
(`gpt-6.2-astra`, high), Gemini (`gemini-4-carbon-high`) and Claude Fable 5.2 (high), each
without sight of the others. What survives into this version: ping and the probes do not resolve
on the actor (all three caught the first draft saying they did); literals must never wait on a
shared resource (Fable, Gemini); Receive Loop Bounds before Overall Deadline (all three); the
executor-independent part of #95 ships first (Fable); hops survive the overall deadline (all
three); the `discoverPaths` commit rule, the lost `getnameinfo` status and ownership of abandoned
ASN work (Codex, Gemini). The state-machine findings are in git history with that version.

That review's brief listed "replacing getaddrinfo with DNS-SD is out of scope" as a constraint
decided by the owner. It was the author's scoping, not David's decision, so the reviewers were
steered away from the approach this version takes.

**This version (event-based), 2026-11-22.** Prompted by David asking why a DNS query needs a
worker at all, and whether the whole thing can be event-based. The approach changed, so it gets
one new review round; the outcome is recorded here when it returns.

Unverified claims this plan repeats: that a stalled `getnameinfo` holds a slot for about 30
seconds (repo comments and an earlier measurement, not re-measured). The DNS-SD comparison above
is one machine on one network.
