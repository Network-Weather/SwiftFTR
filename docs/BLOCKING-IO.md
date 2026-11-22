# Event-based I/O: no thread held while waiting, one deadline per operation

Sequenced plan for the ROADMAP item "Robustness under network and DNS failure, proven by tests".
Stage: product. Status: Independent Fixes (#100) and Receive Loop Bounds (#108) have landed; Consistent
Cancellation is next. The
plan was reviewed twice (see Review record). Completed stages are struck through.

## Why

SwiftFTR runs inside software that is diagnosing a broken network, so a resolver that never
answers or a link that drops mid-operation is its normal operating condition. The roadmap goal is
that every public operation returns or throws within a time the caller can work out from its
configuration. This plan covers the trace family, ping, the TCP, UDP and DNS probes and public-IP
discovery. What it leaves unbounded is listed under Out of scope.

**The cause is that some waits hold a thread.** Ping, trace and the TCP and UDP probes wait on
Dispatch sources: no thread is held, a timer ends the wait, and cancellation closes the socket.
Four kinds of work are written as blocking calls instead:

| Work | How it waits today | Where it runs |
|---|---|---|
| DNS probes and Team Cymru ASN lookups | a blocking `recv` on a UDP socket; since Event-Based DNS, a Dispatch read source (`UDPExchange.swift`), with the blocking query kept only for the whoami fallback | `BlockingIOExecutor`; since Event-Based DNS, no thread |
| Public-IP discovery (STUN, with a DNS fallback for IPv4) | blocking `recv`, plus `getaddrinfo` per server name | the executor in a classified trace; plain `Task` closures and `DispatchQueue.concurrentPerform` in standalone `getPublicIPs` |
| Reverse DNS | `getnameinfo` | the executor |
| Forward resolution of a destination | `getaddrinfo` | inline in the caller |

`BlockingIOExecutor` (`Utils.swift`) is eight worker slots behind an `OperationQueue`.
Everything hard about this area follows from threads being held:

- **Work queues for a thread it does not need.** A DNS probe sends one UDP packet, yet it waits
  for a free slot, and stalled `getnameinfo` calls can hold all eight. That wait has no bound,
  and bounding it with a deadline would report a healthy server as unreachable when no packet
  was ever sent.
- **A released caller still occupies a slot.** A blocking call cannot be interrupted, so
  cancellation and deadlines free the caller while the syscall runs on.
- **The bridge is easy to get wrong.** Four objects can each end a request on the executor.
  0.17.1 fixed three defects in it. The queue deadline that #95 added on top had a fourth; that
  code never merged, so the fourth is not on `main`.
- **Inline `getaddrinfo` blocks the tracer actor** in `performTrace` and
  `performStreamingTrace`, so `cancelActiveTraces()` and `networkChanged()` wait behind it. For
  `ping` (`nonisolated`) and the TCP and UDP probes (free functions) it blocks a cooperative-pool
  thread.

The plan: make DNS, STUN and reverse DNS event-based, so they hold no thread and leave the
executor. Keep `getaddrinfo` for forward resolution, because it is the only thing that chooses
the address the system itself would connect to (see Resolution Off The Actor), and move it onto
the executor, which by then carries nothing else. The executor's internals do not change.

Two further defects are independent of this. The receive handlers for trace, streaming trace
and ping can starve their own deadline timer; that is fixed first. `traceClassified` has no
overall deadline (#84); that is a later stage, after Consistent Cancellation, which it builds
on.

## What stays

- Every public signature. New options are added as separate initializer overloads so existing
  calls keep their exact function type. No case is added to an existing public error enum.
- The fault-injection approach from #94: task-local seams, loopback fixtures, negative controls.
  The seam closure types for resolution and public-IP discovery are synchronous today and become
  async with the code they replace, so the tests that bind them change.
- The downstream contracts in `CLAUDE.md`: single destination-string entry points, canonical
  address form, zone-suffix preservation, family-agnostic errors, concurrent-ping safety,
  unprivileged sockets.
- Graceful degradation, the 0.15.0 contract: a trace whose probes succeeded returns its hops even
  when enrichment does not finish.
- The system resolver for names, forward and reverse, so split DNS, VPN resolvers, search
  domains and `.local` behave as they do for the rest of the host.
- `BlockingIOExecutor` and its bridge, unchanged. Its last remaining use is `getaddrinfo`.

## Stages

Each stage is one pull request under about 2,000 changed lines, reviewed by Codex before merge,
with tests shown to fail without the change. A stage that outgrows the cap is split, not
overridden.

The order puts the fixes that are independent of each other first and the release after the
four that close known defects. The event-based conversions follow in order of risk: the UDP
transports the library fully owns, then reverse DNS, where a difference costs only a hostname,
then forward resolution, where it would change what is measured.

### ~~Independent Fixes~~ (landed in #100)

The part of #95 that does not touch the executor's internals (about 1,700 of its 1,773 changed
lines; 69 are in `Utils.swift`):

- A network change cancels active `trace`, `traceClassified`, `traceStream` and `discoverPaths`
  operations, including a trace waiting on reverse DNS. `discoverPaths` now throws
  `TracerouteError.cancelled`. Ping and the probes are not tied to network changes.
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

Not ported: #95's DNS queue deadline. Event-Based DNS removes the wait it was bounding.

This stage starts the upgrade guide (see Upgrade guide).

### ~~Receive Loop Bounds~~ (landed in #108)

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
cause depending on which check notices first. A caller that retries on
`TracerouteError.cancelled` therefore sometimes retries after its own cancellation.

The cause is structural. In `trace`, `traceClassified` and the multipath flow, the task's
`onCancel` runs `Task { await handle.cancel() }`, which sets the same flag a library-side cancel
sets, and `withTraceCancellation` then turns everything into `TracerouteError.cancelled`. So the
fix is not a change of `throw` statements: `TraceHandle` gets a lock-protected, synchronous
cancel state that records the reason (caller task, or library), and `withTraceCancellation`
reports from it. Overall Deadline later adds a third reason to the same state.

The rule, as `discoverPaths` already has it from Independent Fixes: task cancellation throws
`CancellationError`; a library-side cancel throws `TracerouteError.cancelled`; when both
happened, the library-side cancel is reported. Trace follows both halves. Ping is not tied to
`networkChanged()` or `cancelActiveTraces()` (it registers no trace handle, and that does not
change here), so for ping the only change is that cancelling its own task throws
`CancellationError`. A streaming trace
follows it for a library-side cancel of a live stream, which throws `TracerouteError.cancelled`
to the consumer. A consumer that cancels its own task is different: iteration of an
`AsyncThrowingStream` can end normally (`next()` returns `nil`) before the producer sees the
cancellation, and no change to `TraceHandle` can make that completed call throw. That case is
documented as a normal end of iteration and tested for producer cleanup instead. The
battery's cancellation tests stop accepting either type, and the two follow-ups from the review
of #100 are done here (the `cancelActiveTraces()` doc comment; one gated trace per cancellation
source). This is a behavior change and gets an upgrade-guide entry.

### ~~Event-Based DNS~~ (landed in #111)

Rewrite `performDNSQueryInternal` as a non-blocking connected UDP socket with a Dispatch read
source and a timer. Encoding, parsing, peer checks and interface and source binding are reused
unchanged. This covers the public DNS probes and the Team Cymru TXT lookups. After it, neither
touches the executor, so the unbounded wait for a worker is gone at its cause.

The transport contract (it is shared with STUN later, so it is one small type):

- **Setup.** Set `O_NONBLOCK` and check both `fcntl` results. Setup owns the descriptor until
  the read source exists; from then on it is closed exactly once, in the source's cancel
  handler, after every source watching it has been cancelled. The continuation resumes after
  the close. A source that was created is always activated before it is cancelled.
- **Send.** A UDP send is all or nothing; a short count is a failure. `EINTR` retries. `EAGAIN`
  and `EWOULDBLOCK` wait for writability and retry the whole datagram. `ENOBUFS` retries after
  a short timer instead, because the socket reports writable at once while the interface's
  output queue is still full (`docs/EAGAIN-MECHANISM.md`). Both stay inside the deadline, with
  no blocking `poll` or `usleep`.
- **Receive.** Read `errno` on a negative `recv`. `EAGAIN` waits. `ECONNREFUSED`,
  `EHOSTUNREACH` and `ENETUNREACH` end the exchange at once (the ICMP error arrives as a read
  event with no data). Zero bytes is an empty datagram, not a timeout; this
  is a change, listed below. The drain is bounded and
  the absolute deadline is checked before a reply is accepted.
- **Foreign and malformed replies keep today's meaning**, with the one exception of the empty
  datagram. The first datagram decides: a wrong transaction ID or garbage fails with
  `malformedResponse`, as now. Ignoring them until the
  deadline would change a probe's verdict and is not part of this stage.
- **Truncation stays an error.** There is no TCP fallback today and none is added here.
- **Timing.** RTT is stamped at `send` and in the read handler.

Synchronous callers. `getPublicIPv4ViaDNS` (the IPv4 whoami fallback in `STUN.swift`) calls
`DNSClient.queryTXT` from inside the blocking public-IP closure, and the test entry point
`__dnsQuery` is synchronous. The blocking implementation stays, used only by that fallback,
until Async Public-IP Discovery removes its last caller; the tests move to the async path.

The limit on concurrent Cymru queries stays (it now bounds sockets, not slots) and its wait
becomes cancellation-aware.

Behavior changes for the upgrade guide, each with a test of the public verdict:

- DNS timing no longer includes the wait for a worker. That is `DNSQueryResult.rttMs`
  (milliseconds), returned by the query methods such as `DNSQueries.a`, and
  `DNSProbeResult.rtt` (optional seconds), returned by `dnsProbe`. Both start timing before the
  executor submission today.
- A refused port. Today `recv` fails at once with `ECONNREFUSED` and the client labels it
  `DNSError.timeout`, so the probe says "no response" although the host answered with a
  refusal. The new transport distinguishes a delivered refusal from silence. Which existing
  error it reports is chosen in this stage; no `DNSError` case is added. This is a change of
  reported outcome, not of speed.
- An empty datagram. Today it is reported as `DNSError.timeout`, so `dnsProbe` says unreachable.
  As a malformed reply, `dnsProbe` reports the server reachable, like any other malformed
  reply.

Tests: the existing DNS fault battery against the new transport; refused port; `EAGAIN` on send
(injected); cancellation returns while the fixture is still silent, and the descriptor is closed
once; with every executor slot held, a query to a healthy loopback server still answers.

### Release 0.18.0

After the four stages above. Bump `Version.swift`, consolidate `Unreleased` into a section
organized by user-visible value with "Behavior changes" first, finish the upgrade guide for what
shipped, tag the release-prep merge commit. Tagging and publishing need David's explicit go.

### Async Public-IP Discovery

Make the orchestration awaitable before changing STUN's transport. `getPublicIPv4`,
`getPublicIPv4ViaDNS`, `publicIPv4Discovery` and their callers in `Traceroute.swift` and
`Segmentation.swift` become async and are lifted out of the `runDetachedBlockingIO` closures
that wrap them. Standalone `getPublicIPs` replaces its unstructured `Task` wrappers, which also
swallow the caller's cancellation, with structured concurrency. The whoami fallback moves to the
async DNS transport, and the blocking DNS implementation is deleted.

The STUN exchange itself is still blocking after this stage and runs as individual executor
requests, one per attempt. Server names resolve as they do today. The classified IPv4 path keeps
its DNS fallback; the standalone API stays STUN-only.

### Event-Based STUN

The STUN exchange moves onto the transport from Event-Based DNS, against an already-resolved
endpoint. A server is tried as soon as its name has resolved, and a family that succeeded is
returned at the cap while a losing lookup is still stalled. Name resolution for STUN servers is
not changed here; it moves with Resolution Off The Actor. First-ready selection can change which
server supplies the address; the changelog says so. STUN keeps failing on the first invalid
reply, as now.

Tests: the STUN fault battery against the new transport; a refused port moves to the next
server at once; a healthy endpoint beside a stalled name yields an address, in classified and
standalone discovery; `getPublicIPs` still returns a partial result when one family answers.

### Event-Based Reverse DNS

Replace `getnameinfo` in `RDNSCache` with a PTR query through `DNSServiceQueryRecord`. No
thread is held, and an abandoned lookup is actually stopped. The system's own `getaddrinfo` and
`getnameinfo` are built on the same daemon queries, and a comparison on one Mac returned the
same name for 12 of 13 addresses (the exception: 255.255.255.255 is `broadcasthost` through
`getnameinfo` and has no PTR through this API).

The `DNSServiceRef` contract, which is where this API crashes if misused (deallocating off the
callback queue crashed a stress loop in 4 of 4 runs):

- One owner object per lookup, with a serial queue given to `DNSServiceSetDispatchQueue`. Both
  the start call's result and the queue call's result are checked.
- The start call does a synchronous round trip to the system daemon, so it runs on the lookup's
  queue, never on the actor or a cooperative thread. The deadline timer runs on a different
  queue, so a stalled start cannot starve it; the caller is released at the deadline and a late
  successful start is disposed of.
- `DNSServiceRefDeallocate` is called only on the lookup's queue. Cancellation from another
  thread hops to it. The callback context is released only after that deallocate.
- `kDNSServiceFlagsReturnIntermediates` is set; without it a nameless address never calls back.
  With it, intermediate CNAME records and remove events also arrive and are ignored: only an
  added PTR record or an error is an outcome. The query stays active until deallocated, so the
  first outcome deallocates.
- A zoned link-local address passes its zone as the interface index. The PTR name's trailing
  dot is stripped, so the hostname has the form `getnameinfo` gives.
- A cap on concurrent lookups, awaited without a thread. Each lookup holds a descriptor, and the
  executor's eight slots are today the only thing limiting how many run at once; a default
  256-descriptor limit is reachable by a few concurrent traces otherwise.

Outcomes are typed: answer, no such record, error, timeout, cancelled. What "no such record"
proves is decided here: the daemon can report it for a suppressed question as well as a real
negative answer, so if the two cannot be told apart, only answers are cached. Link-local
addresses are resolved by multicast. A peer that advertises a PTR answers and the lookup
succeeds at once; but multicast never says "no such name", so an unanswered link-local lookup
runs until its cap. Those lookups get a short cap of their own and an unanswered one does not
count toward the stall breaker, or every IPv6 trace whose first hop has no name would wait out
the full budget. The stall breaker stays: it saves
each trace the lookup budget while the resolver is broken.

The public optional hostname and the public synchronous `reverseDNS(_:)` are unchanged; the
synchronous function keeps `getnameinfo` on its caller's thread. The two can therefore disagree
for an address named only in `/etc/hosts`; the upgrade guide says so.

Tests: a seam substituting the query; each outcome; a cancelled lookup is not cached; a network
change ends the wave; a start call gated past the deadline releases the caller and deallocates
exactly once; the off-queue deallocate stress test; a descriptor-count test at a lowered limit;
a gated live comparison against `getnameinfo`.

### Resolution Off The Actor

Forward resolution keeps `getaddrinfo`. The reviews and a measurement settled this:

- `getaddrinfo` orders its answers using the routes and source addresses of each candidate and,
  ahead of the RFC 6724 rules, the kernel's statistics about recent connections. The event-based
  API returns addresses in arrival order. On one Mac, the first address it delivered from a cold
  cache differed from `getaddrinfo`'s for 7 of 21 public names. Sorting the collected answers by
  RFC 6724 matched all 21 but not the machine's own hostname, where `getaddrinfo` preferred IPv4.
- NAT64 synthesis for an IPv4 literal exists only inside `getaddrinfo`; the event-based API
  rejects literals.
- Which address gets probed is the measurement. A resolver that is race-free and picks a
  different destination than the system would is the worse failure.

So this stage changes where `getaddrinfo` runs, not what it returns:

- One async adapter, used by trace, streaming trace, ping, the TCP and UDP probes, STUN server
  names and `discoverPaths` (which resolves once, with its forced-IPv4 contract, and passes the
  address to its flows while keeping the original hostname for display).
- It submits `resolveHost` to the executor with a deadline. By this stage nothing else uses the
  executor, so enrichment cannot starve a forward lookup, and the existing bridge with a
  whole-call deadline is the path 0.17.1 fixed. Hints are unchanged, including the separate
  hint set `resolveSTUNServer` uses.
- Forced-family literals keep their inline fast path. An `.auto` literal still needs
  `getaddrinfo` for NAT64. Whether it can skip the call when the host has a routable IPv4
  address is measured in this stage; if not, it goes through the executor like a name.
- The adapter reads its seam on the async side before submitting. `TraceHandle` cancellation
  and task cancellation both reach the resolution, and the trace revalidates before creating
  its socket.
- A resolution that hit its deadline is reported through the existing
  `TracerouteError.resolutionFailed(host:details:)` with details saying it timed out, so no new
  case is needed. The TCP and UDP probes, which do not throw for network failures, report it in
  their result as they report other failures, and spend one budget: resolution time comes out
  of `config.timeout`.

Stalled lookups for eight different names can still hold every slot until `getaddrinfo` gives
up. That is bounded for the caller by the deadline and is the residual this plan accepts.

Tests: with a trace's resolver gated shut and shown to have been entered, `cancelActiveTraces()`
returns and the victim trace finishes while the gate stays shut; with at least core-count pings
in resolution, an unrelated async task still runs; a forced-family literal never calls the
resolver.

### Overall Deadline

The #84 contract, for `traceClassified` and `discoverPaths` (including the per-flow pipeline in
`performClassifiedTraceWithFlowID`). It can land any time after Consistent Cancellation, whose
cancel state it extends; it is simpler after the event-based stages, because expiry then stops
the work instead of abandoning it.

- One absolute deadline on one monotonic clock, the one Dispatch timers use, started on entry to
  the actor-isolated method.
- The default is the sum of the caps of the phases active for this call (skipping disabled
  reverse DNS, a configured or cached public IP, an embedded ASN database), plus a stated
  scheduling allowance. So by default it fires only when a phase overran its own cap. A
  caller-supplied total replaces the default. For `discoverPaths` the sum accounts for its
  sequential batches of flows.
- A phase may tighten the deadline and never resets it. At a phase's own cap, enrichment degrades
  as now. Classification gets its own cap, and when it expires the trace is returned with ASN
  data missing.
- Phase changes and the final return read the clock under the same lock as expiry, and commit
  expiry for the outgoing phase when the deadline has passed, so a late timer cannot blame the
  next phase or lose to a late result.
- Hops are never discarded. If the overall deadline passes after the probe window, the measured
  hops are returned (see Decisions for how). For `discoverPaths`, paths from batches that
  finished are returned when a later batch expires.
- Public-IP discovery that was attempted and got no answer is remembered for the rest of the
  call, so the classifier does not start it again.
- The shared ASN load in `_ASNMemoryCache` is cancelled when its last waiter leaves; each
  subscriber's wait has its own deadline, which must not be part of the key that decides whether
  two callers share a load. An injected `ASNResolver` that ignores cancellation cannot be
  stopped: the caller is released and the documentation says so.

Tests: a caller-tightened total with phases that each finish inside their own cap but whose sum
exceeds it; expiry in each phase names that phase; two subscribers to one ASN load with
different deadlines; a `discoverPaths` whose second batch expires returns the first batch.

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
- After 0.18.0 the API check also runs against `v0.18.0`. No breakage is allowlisted.
- Each event-based stage adds one more: with every executor slot held by a gated blocker, the
  operation it converts still completes against a healthy loopback fixture reached by a literal
  address.

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

Each open one has a recommended default, and work proceeds on the default until he says
otherwise. Decided ones say so.

1. **Is Event-Based DNS in 0.18.0?** Decided: yes (David, 2026-11-22).
2. **Cancellation errors (Consistent Cancellation).** Recommended: fix before 0.18.0. Ping's
   error type changes for a caller that cancels its own task.
3. **Forward resolution keeps `getaddrinfo`.** Recommended, as described in Resolution Off The
   Actor. The alternatives the reviewers named: sort the event-based API's answers in-process by
   RFC 6724 and document that the choice can differ from the system's (Gemini); or resolve
   through the event-based API to warm the daemon's cache and then call `getaddrinfo`, which
   answered in 1 to 7 ms from cache in one measurement (Fable, as an untested idea).
4. **Overall deadline on by default?** Recommended: yes, with the default equal to the sum of
   the active phase caps plus an allowance, and a caller-supplied total that replaces it.
5. **What happens to the hops when the overall deadline passes after probing?** Recommended:
   return the result with enrichment missing and a field naming the phase that ran out, and
   throw only when the deadline passes before the probe window completes. The alternative is to
   throw and carry the partial result in the error.
6. **Shape of the deadline error**, for the case that does throw. Decided: a separate error
   type, not a new `TracerouteError` case (David, 2026-11-22). A new case would break exhaustive
   switches in consumers; decision 5's default makes this error rare. The compatibility gate
   compiles an exhaustive switch over `TracerouteError` to hold that line, and the documentation
   says a caller catching only `TracerouteError` will not see the deadline error.
7. **Forward-resolution budget.** There is no configuration to derive one from today.
   Recommended: a new `SwiftFTRConfig` option for traces, defaulting to 10 seconds, with probes
   spending from their existing `timeout`. The 10 seconds is a proposal, not a measurement.
8. **Structured DNS probe outcome.** Decided: add an additive `outcome` field to
   `DNSProbeResult`; `isReachable` stays false for a refused port; the throwing query methods keep
   `DNSError.sendFailed` for a refusal (David, 2026-11-22).

## Out of scope

Still unbounded after this plan, or deliberately deferred. Roadmap, not this plan:

- Replacing `getaddrinfo` for forward resolution.
- The public synchronous `reverseDNS(_:)`, direct `TraceClassifier.classify` with an
  uncooperative resolver, and `preloadASNDatabase()` with a remote source.
- `testBufferbloat`, whose load generation uses `URLSession.shared` and is awaited without
  cancellation after the ping phase ends.
- The `swift-ftr` CLI's own synchronous `reverseDNS` and `getaddrinfo` calls.
- DNS over TCP on truncation, and EDNS0. A truncated answer is `malformedResponse` today.
- Ignoring replies with a foreign transaction ID until the deadline, for DNS and STUN.
- The blocking `poll` and `usleep` in `SendRetry.swift`, which can hold the tracer actor or an
  operation's queue for up to the 250 ms burst budget.
- `discoverPublicIPWithHostname()` not being ended by a network change.
- Using real PTR time-to-live values in `RDNSCache` instead of one cache-wide value.
- Collapsing the multipath per-flow pipeline onto the shared classified-trace implementation,
  which would also fix the configuration it drops (#91).
- Coalescing identical in-flight forward lookups.
- The UDP probe's setup. Its receive handler reads once per callback and does not have the
  receive-loop defect; its `fcntl` that sets `O_NONBLOCK` is still unchecked.
- Thread Sanitizer and Address Sanitizer jobs, scheduled soak runs, DNS and STUN parser fuzzing.
- Adding `connectionRefused` and `unreachable` cases to `DNSError`, which would break exhaustive
  switches; for the next release where a source break is acceptable.
- Root cause of the production timeouts in #84. This plan gives the means to find it; 56 of 59
  reported calls returned within five seconds of cancellation, so a blocked resolver is not
  established as the cause.

## Review record

**First version (per-request state machine), 2026-11-22.** Reviewed once by Codex
(`gpt-6.2-astra`, high), Gemini (`gemini-4-carbon-high`) and Claude Fable 5.2 (high),
independently. Its brief listed "replacing getaddrinfo with DNS-SD is out of scope" as decided by
the owner. That was the author's scoping, not David's decision.

**Second version (everything event-based, executor deleted), 2026-11-22.** Prompted by David
asking why a DNS query needs a worker at all. Reviewed once by the same three; Fable also ran
measurements on one Mac (macOS 26.7.3, dual-stack, a split-DNS VPN up; one run each). This
document is that version with their findings folded in:

- Event-based is right for DNS, STUN and reverse DNS (all three).
- Forward resolution cannot reproduce `getaddrinfo`'s choice by collecting answers and waiting
  (all three; Fable's measurement and reading of the system library's source). Hence it keeps
  `getaddrinfo`, and the executor is kept for it instead of deleted.
- The author's own comparison had called `getaddrinfo` first, so the event-based API answered
  from a warm cache in sorted order and looked more alike than it is (Fable).
- The interim "three times the timeout" DNS bound counts from submission and reports a healthy
  server as unreachable when the workers are busy (all three). Replaced by Event-Based DNS
  before the release.
- The `DNSServiceRef` rules, the required flag, the synchronous start call and the descriptor
  cap (all three; crash and descriptor limit measured by Fable).
- An unanswered link-local reverse lookup has no negative answer and runs to its cap (Gemini).
- Consistent Cancellation needs the reason-carrying cancel state, not just different `throw`s
  (Gemini).
- Standalone `getPublicIPs` does not use the executor today, the DNS client has a synchronous
  caller in the whoami fallback, and STUN's transport cannot be gated before its orchestration
  is async (all three). Hence Async Public-IP Discovery.
- The UDP transport contract: errno handling, send retry, close ordering (all three).

Declined, with the reason:

- Reimplementing RFC 6724 ordering and NAT64 prefix discovery in the library so the executor
  can be deleted outright (Gemini). It cannot match the system's choice where connection history
  matters, and it is the larger risk for the smaller gain.
- A shared connection to the daemon for reverse lookups (Gemini, Fable as one option). A cap on
  concurrent lookups is simpler and bounds descriptors as well; revisit if the cap costs time.
- Changing foreign-transaction-ID handling now (raised by all three as a choice to make). Kept
  as today so a probe's verdict does not change in the same release as its transport.

No third review round: this version adopts the reviewers' recommendations and does not introduce
a new approach.

Unverified claims this plan repeats: that a stalled `getnameinfo` holds a slot for about 30
seconds (repo comments and an earlier measurement, not re-measured); behavior on NAT64, on a
network with broken IPv6, and with the system daemon stopped or stalled (documentation and
source reading only). The measurements cited are one machine on one network.
