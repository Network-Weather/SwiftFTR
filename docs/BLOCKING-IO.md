# Event-based I/O: no thread held while waiting, one deadline per operation

Sequenced plan for the ROADMAP item "Robustness under network and DNS failure, proven by tests".
Stage: product. Status: the four stages before the release have landed and shipped in 0.18.0:
Independent Fixes (#100), Receive Loop Bounds (#108), Consistent Cancellation (#110) and
Event-Based DNS (#111, #112), with the structured DNS probe outcome (#114) and foreign-reply
handling (#116). 0.18.1 followed with fixes from the open issues. The five remaining stages are
the content of 0.19.0 (David, 2026-11-22); see Release 0.19.0 for the order, the pull-request
slices and what else ships with them. The plan was reviewed twice, and the 0.19.0 sequencing
once (see Review record). Completed stages are struck through.

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

- Every public signature and error case, except the breaks decision 10 allows and Release
  0.19.0 names: two `DNSError` cases, one `TracerouteError` case, and the public-IP breaks listed
  under Public-IP Resolver. New options are added as
  further initializers, so existing calls keep their exact function type.
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

### ~~Consistent Cancellation~~ (landed in #110)

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

### ~~Event-Based DNS~~ (DNS queries and probes landed in #111; Team Cymru lookups in #112)

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
  event with no data). Zero bytes is an empty datagram, not a receive failure; DNS ignores it, as
  it carries no transaction ID. The drain is bounded, the caller's acceptance check runs on each
  datagram, and the absolute deadline is checked before a reply is accepted.
- **Foreign replies are ignored; malformed ones keep today's meaning.** A datagram without the
  query's transaction ID, or too short to carry one, is ignored until the deadline (decision 8,
  done in #116). A datagram with the right ID that is otherwise invalid fails with
  `malformedResponse`, as now.
- **Truncation stays an error.** There is no TCP fallback today and none is added here.
- **Timing.** RTT is stamped at `send` and in the read handler.

Synchronous callers. `getPublicIPv4ViaDNS` (the IPv4 whoami fallback in `STUN.swift`) calls the
blocking TXT query from inside the blocking public-IP closure. That blocking implementation
stays, used by the fallback and by tests that call it directly, until Async Public-IP Discovery
removes its last caller and moves or removes those tests.

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
- A datagram without the query's transaction ID, an empty one included (decision 8). Today a
  wrong ID is `malformedResponse`, which `dnsProbe` reports as reachable, and an empty datagram
  is `DNSError.timeout` at once. Both are ignored, so a server that sends only such datagrams is
  `DNSError.timeout` at the deadline, and `dnsProbe` reports it timed out and unreachable.

Tests: the existing DNS fault battery against the new transport; refused port; `EAGAIN` on send
(injected); cancellation returns while the fixture is still silent, and the descriptor is closed
once; with every executor slot held, a query to a healthy loopback server still answers.

### ~~Release 0.18.0~~ (released 2026-11-22)

The four stages above, with the changelog's 0.18.0 section and the upgrade guide
(`MigratingTo018.md`) covering every behavior change in it.

### Release 0.19.0

The five remaining stages, the open defects that are cheap to fix beside them, and the
source-breaking error cases this plan had deferred. David's decisions for this release
(2026-11-22): the whole remaining plan ships in 0.19.0; the overall deadline is on by default
(decision 4); a deadline that passes after probing returns the hops and names the phase
(decision 5); source breaks are allowed in 0.19.0 (decision 10).

**Order, and why.** The overall deadline goes last. A deadline can only release a caller at a
point where the work it is waiting on can be abandoned, and until Resolution Off The Actor lands
a trace calls `getaddrinfo` on the tracer actor, where no timer can interrupt it; a deadline
built before that would be a bound the library could not keep (both reviewers, from the code).
With everything before it event-based or behind a deadline, the caller's wait is bounded in
every phase and the default deadline is a sum of caps that all exist. Expiry stops the
event-based work outright. It does not stop a `getaddrinfo` already running: that caller is
released while the call finishes in its executor slot, which is the residual Resolution Off The
Actor accepts. The order is otherwise
the risk order above: the UDP transports, then reverse DNS, then forward resolution.

Each row is one pull request under about 2,000 changed lines. The rows are not independent:
`DNS.swift`, `Traceroute.swift`, `Multipath.swift`, `Segmentation.swift`, `TestSeams.swift`,
`CHANGELOG.md` and the upgrade guide are edited in more than one, so pull requests land one at a
time and each is brought up to date with `main` before it merges. Work on different rows may
overlap in time; the "After" column is what must have landed first.

| Slice | After | Contents |
|---|---|---|
| Small Fixes | | #138 (a ping whose send failed ends once every sent probe is answered), #139 (`seedPublicIP` and the shared address parsers: a NAT64 address wrapping a non-global IPv4 address, a string with an embedded NUL), #128 (a DNS reply's question is compared with the query; a reply with no question section stays acceptable), #140 (CLI wording for a failed receive), #136 (README). Each caller-visible change gets an upgrade-guide entry. |
| Upload Default | | Bufferbloat's default upload URL (decision 11, #89). |
| Test Hygiene | | #135 (a watchdog on the ASN-enrichment cancellation test), #129 (fixture teardown that does not block an async test), the stronger `cancelledLookupNotCached` (ROADMAP). Tests only. |
| DNS Error Cases | Small Fixes | `DNSError.connectionRefused` and `DNSError.unreachable`, mapped by where the failure came from: a refusal received after the send (`sendFailed` today), an unreachable received after the send (`timeout` today), and a local routing failure on connect or send (`sendFailed` today). `dnsProbe`'s result for each origin does not change. Adds the API allowlist and runs the API check in CI. |
| Async Public-IP Discovery | Small Fixes | The stage below. STUN server names and each STUN attempt run as executor requests under one absolute discovery deadline; nothing moves onto the cooperative pool. Deletes the blocking DNS path, so it lands after Small Fixes has touched it. |
| Resolver Seam | Async Public-IP Discovery | First half of the stage below: the `PublicIPResolver` protocol and strategy, a per-family cache, the tracer-enforced deadline, one question per call asked after the family is known, no discovery in the classifier or in flows, the source reported on results, and the source breaks. |
| Library Resolver | Resolver Seam | Second half: the library's STUN-only resolver in its own file, bound before anything is sent (#151), the whoami query through recursive resolvers deleted (#153), `getPublicIPs` and `discoverPublicIPWithHostname()` on it. |
| Event-Based STUN | Library Resolver | The stage below: STUN on the event-based transport, servers tried at once, foreign replies ignored, a cancellable, bounded wait on each server-name lookup, and the rule for which answer is believed (decision 16). |
| Reverse-DNS Lookup | | The `DNSServiceQueryRecord` lookup object with its teardown contract and its tests, including the off-queue deallocate stress test, the descriptor-count test at a lowered limit and the gated live comparison. Unused until the next row; the two are released together. |
| Reverse-DNS Cache | Reverse-DNS Lookup | `RDNSCache` on the new lookup: the concurrency cap, the link-local cap, what is cached, the stall breaker, and `withTraceCancellation` around the multipath flow's reverse-DNS wait. |
| Resolution Off The Actor | Event-Based STUN, Reverse-DNS Cache | The stage below, as one change: the resolution seam is one closure shared by trace, streaming trace, ping and the probes, so it becomes async for all of them together. If it outgrows the cap, the second pull request is the forward-resolution budget option (decision 7) and `discoverPaths` resolving once. |
| Enrichment Lifetimes | Resolver Seam | The ASN lookup's timeout reaches every resolver it passes through (`HybridASNResolver` ignores it today), and a caller leaving a shared ASN database load neither cancels it for others nor leaves the resolver latched as failed. (Remembering a failed public-IP attempt moved to Resolver Seam.) |
| Deadline For Traces | Resolution Off The Actor, Enrichment Lifetimes | The deadline clock, the phase bookkeeping and its lock, the `TracerouteError` deadline case (decision 6), the result field naming the phase, and the new configuration option, for `traceClassified`. Measured hops are committed when the receive window completes, so expiry in any later phase can return them. Every phase the default sums has a cap: both reverse-DNS waves, classification, and the scheduling allowance. |
| Deadline For Multipath | Deadline For Traces | `discoverPaths` and its per-flow pipeline: the phase is reported on the topology, paths from finished batches are returned, and the actor-side publication check still rejects a result from before a network change. |
| Offline Tripwire | every row above | A test-only check on each real network path that fails an offline test reaching anything but loopback or a fixture the test bound itself (ROADMAP). Tests that deliberately exercise the real transport against a loopback fixture keep doing so. Last, because it touches the paths the other rows rewrite. |
| Release 0.19.0 | all | Version, changelog section, `MigratingTo019.md` complete, release notes. |

**New options keep existing calls exact.** A new option is added as a further initializer that
repeats the existing parameters and adds the new one, all defaulted. Swift resolves a call that
names none of the new parameters to the initializer with the fewest defaulted parameters, so
`SwiftFTRConfig()` and every existing call, including one that uses the initializer as a function
value with its type stated, compile unchanged and mean what they meant (a bare
`SwiftFTRConfig.init` with no type context becomes ambiguous). That was checked with three such
initializers on Swift 6.4 only; the pull request that adds the first one adds a test of the
selection, so CI's Swift 6.1 checks it too. No initializer signature is changed or removed.

**What must ship together.** Reverse-DNS Lookup with Reverse-DNS Cache. Enrichment Lifetimes
before either Deadline row, or the default deadline budgets one discovery and the call spends
two. Deadline For Traces and Deadline For Multipath in the same release, since flows run the
same pipeline. If a row stops under the second-pass rule in Gates, what can be released without
it is David's call, made against this list.

**Not in 0.19.0**, though related: reporting an HTTP status as soon as the headers arrive (#122),
which needs its own transport and its own plan; a structured outcome on the TCP, UDP and HTTP
probe results, which belongs with the API review before 1.0; stopping a remote ASN database
download when every caller has left (ROADMAP).

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

### Public-IP Resolver

Public-IP resolution becomes something a caller can replace, behind one seam, instead of code
spread through the trace, the classifier and each multipath flow (David, 2026-11-22). A host app
often knows more than the library can find out: which interface is the hardline and which the
VPN, what the gateway reports, what it observed a minute ago. And the library's own fallback is
wrong today: it asks recursive resolvers (`1.1.1.1`, `8.8.8.8`) for a whoami name and reads a
record built from the client-subnet hint the resolver forwards, which on one measured network was
a different host in the right /24 through one resolver and a different /24 through the other,
never the caller's address (#153). It is not bound to the tracer's interface either (#151).

- **The seam.** A public `PublicIPResolver` protocol with one async method. The request names one
  address family, the interface and source address the tracer is bound to, and an absolute
  deadline. The answer is an observation: the address, its family, and where it came from, or
  nothing. `SwiftFTRConfig` gets a strategy with three cases: the library's resolver (the
  default), none, or the caller's. (ASN resolution has no such strategy case today; a caller's
  `ASNResolver` is passed per call. This is new shape, not a copy.)
- **The tracer enforces the deadline, not the resolver.** The wait on a resolver is a
  single-resume race between its answer, the deadline and cancellation, so a caller's resolver
  that never returns, or ignores cancellation, cannot hold the call; a task group that joins its
  children would. An answer that arrives after the caller was released is dropped and never
  written to the cache.
- **Per family, and after the family is known.** The cache holds one observation per family, and
  a seed fills only its own family; today one slot holds either, so an IPv6 seed can label the
  hops of an IPv4 trace. A trace asks for the family it actually probed, which for the
  automatic preference is known only once the destination has resolved: `traceClassified` asks
  after its probes have returned, so an overall deadline that expires during the question finds
  the hops measured (decision 5). A multipath run is IPv4 by contract and asks in the parent
  before its first batch; a deadline that expires there is before any probe, and throws.
- **One question per call.** With no configured or seeded address of that family, a classified
  trace or a multipath run asks once, under `publicIPDiscoveryTimeout`, inside the trace's
  cancellation. Order of precedence: a configured address of the family, then an unexpired seed
  or cached observation, then the strategy. A miss is remembered for the rest of the call only.
  The generation check stays after every suspension.
- **Nothing else discovers.** `TraceClassifier.classify` classifies with the address it is given
  or without one; its parameters that exist only for discovery go, and `publicIP` becomes a
  required argument so the choice is visible at each call site. A multipath run asks once in the
  parent, after registering its handle, and hands that answer, or its absence, to every flow of
  every batch. The second discovery a failed call pays today (finding 6) goes with this.
- **Every address is checked wherever it comes from**: the resolver's answer, the configured
  override and a seed must each be a globally routable address of the family asked for.
- **Where it came from survives.** The observation's source is kept in the cache and reported on
  the classified trace and the multipath topology beside the address, so a caller can tell a
  seed from a STUN answer from their own resolver's.
- **The library's resolver, in its own file**, is STUN only when this stage lands: it wraps the
  discovery from Async Public-IP Discovery. The whoami query through recursive resolvers is
  deleted, with nothing in its place until decision 16 is made. Each STUN socket is created and
  bound to the request's interface and source address before its server name is resolved; with
  the bind failing nothing is sent, the name lookup included. (The lookup itself goes through
  the system resolver and is not bound to the interface; that is stated, not hidden.)
- **`discoverPublicIPWithHostname()`** asks the configured strategy for a fresh IPv4 observation,
  bypassing the configured override and the cache as now, and throws when the strategy is none.
- **Standalone `getPublicIPs`** keeps its signature and its meaning: STUN only, `stunTimeout` per
  server. It stops relaxing its binding: a source address of one family no longer lets the other
  family run unbound, and an invalid source address sends nothing.
- **Source breaks** (decision 10), allowlisted in the API gate and each with an upgrade-guide
  entry: the `classify` parameters, the public-IP properties that become per family, and whatever
  of `PublicIPError` and `STUNPublicIP` no longer describes anything.

Two pull requests. **Resolver Seam**: the protocol, the strategy, the per-family cache and its
precedence, the deadline race, the classifier and multipath changes, the source on results, and
the breaks. **Library Resolver**: the STUN-only resolver in its own file with bind-before-resolve,
the whoami deletion, `getPublicIPs` and `discoverPublicIPWithHostname()`.

Tests: a caller's resolver is asked once per call and its answer classifies the trace; with the
strategy set to none no discovery packet is sent and the trace classifies without an address; a
resolver that never returns, and one that ignores cancellation and answers after the caller has
returned, are abandoned at the deadline with the right error for who cancelled and no late cache
write; an IPv6 seed followed by an IPv4 trace and by a multipath run; a parent with no answer
shares its one miss with every flow; a network change during the question ends the call; a
private, CGNAT or wrong-family address is refused from every source; on a bound tracer every
socket is bound before anything is sent.

### Event-Based STUN

Inside the library's resolver. The STUN exchange moves onto the transport from Event-Based DNS,
against an already-resolved endpoint, and **the servers are tried at the same time** (David,
2026-11-22): each starts as its name resolves, holds no thread, and shares the whole discovery
deadline. The STUN share of the budget from Async Public-IP Discovery goes away with the
sequence it protected. A reply that is not a STUN response to this request (too short, wrong
magic cookie, wrong transaction ID, or empty) is ignored until the deadline, as DNS ignores a
foreign reply; an invalid reply that does carry the transaction ID fails that server only. Name
resolution for STUN servers gets a bounded, cancellable wait here and moves with Resolution Off
The Actor.

Which answer is believed is decision 16. Until it is made the rule is the conservative one. An
address is reported as soon as two servers have reported the same one. Otherwise the answers are
compared when every attempt has finished or the deadline passes, whichever is first: one
distinct address is reported, and two different ones yield none. So a single healthy server
still answers, at the deadline if another is stalled, and a disagreement is never hidden by
whichever reply came first.

Tests: the STUN fault battery against the new transport; a refused port does not delay the other
servers; two servers that agree answer at once; a healthy endpoint beside a stalled name yields
an address at the deadline; two servers that disagree yield none whichever replies first; `getPublicIPs` still returns a partial result when one family answers.

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
`performClassifiedTraceWithFlowID`). It extends the cancel state from Consistent Cancellation
and lands after the event-based stages and Resolution Off The Actor, so that no phase can hold
the actor past the deadline. The deadline bounds the caller's wait; event-based work is stopped
at expiry, and a blocking `getaddrinfo` already under way runs on in its slot.

- One absolute deadline on one monotonic clock, the one Dispatch timers use, started on entry to
  the actor-isolated method.
- The probe send burst honors it. The burst retries a send under socket pressure for up to its
  own 250 ms budget, waiting synchronously on the tracer actor (`SendRetry.swift`); it uses the
  earlier of that budget and the overall deadline, and stops sending when the overall deadline
  has passed.
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
swift package diagnose-api-breaking-changes v0.18.1 --products SwiftFTR
# once the DNS Error Cases slice has landed, add:
#   --breakage-allowlist-path "$PWD/api-breakage-allowlist.txt"
# (one exact diagnostic per line; the file takes no comments)
swift package --allow-writing-to-directory docc generate-documentation --target SwiftFTR \
  --output-path docc --transform-for-static-hosting --warnings-as-errors
~/.claude/bin/orphan-audit
~/.claude/bin/codex-review --base origin/main                     # SHIP, within three rounds
```

- The release-mode run is there because optimized builds shorten object lifetimes, which is how
  an object kept alive only by a callback context is freed early.
- The API check runs against `v0.18.1`. The only breakages allowlisted are the ones this plan
  names: the two `DNSError` cases, the `TracerouteError` deadline case (decision 6) and the
  public-IP breaks listed under Public-IP Resolver. Any other reported breakage, a changed
  initializer included, fails the gate.
- Each event-based stage adds one more: with every executor slot held by a gated blocker, the
  operation it converts still completes against a healthy loopback fixture reached by a literal
  address.

If a second review pass on any stage finds a new blocker, the stage stops and the decision goes
to David.

## Upgrade guide

`Sources/SwiftFTR/SwiftFTR.docc/MigratingTo018.md` covers 0.17 to 0.18. The 0.19.0 stages get
`MigratingTo019.md`, a DocC article of the same kind, written for both people and coding agents
updating a consumer from 0.18.

- The first 0.19.0 pull request that changes behavior creates it, and each later one adds its
  entry in the same change. A source-breaking change gets the code edit that fixes the build.
- Each entry has the same shape: what changed, what a caller sees, and what to change, with
  before-and-after code an agent can apply mechanically.
- Release gate: every line under "Behavior changes" in the changelog section being released has
  a matching entry.

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
4. **Overall deadline on by default?** Decided: yes (David, 2026-11-22), with the default equal
   to the sum of the active phase caps plus an allowance, and a caller-supplied total that
   replaces it.
5. **What happens to the hops when the overall deadline passes after probing?** Decided: return
   the result with enrichment missing and a field naming the phase that ran out, and throw only
   when the deadline passes before the probe window completes (David, 2026-11-22).
6. **Shape of the deadline error**, for the case that does throw. Decided: a new
   `TracerouteError` case (David, 2026-11-22, replacing his earlier choice of a separate type,
   which was made to avoid a source break before decision 10 allowed breaks in 0.19.0). A caller
   that catches `TracerouteError` sees the deadline, and an exhaustive switch over it fails to
   compile until it handles the case. Decision 5 makes this error rare: it is thrown only when
   the deadline passes before the probe window completes. It is one of the allowlisted breaks.
7. **Forward-resolution budget.** There is no configuration to derive one from today. Decided:
   a new `SwiftFTRConfig` option for traces, defaulting to 20 seconds (David, 2026-11-22), with
   probes spending from their existing `timeout`. The 20 seconds is a judgement, not a
   measurement: how long the system resolver itself waits has not been measured.
8. **Stale DNS replies.** Decided: DNS ignores a datagram whose transaction ID does not match and
   keeps waiting until the deadline, as its own change directly after Event-Based DNS and
   before 0.18.0 (David, 2026-11-22). It closes a gap review found in the event-based
   transport: a stale datagram queued before the query left but read after it is taken as the
   reply. It changes one verdict: a server that sends only wrong-ID datagrams is reported as
   timed out, not as reachable with a malformed response. Done in #116, for DNS on both the
   event-based and the blocking path; a datagram too short to carry an ID is ignored too.
9. **Structured DNS probe outcome.** Decided: add an additive `outcome` field to
   `DNSProbeResult`; `isReachable` stays false for a refused port; the throwing query methods keep
   `DNSError.sendFailed` for a refusal (David, 2026-11-22). Superseded for the throwing methods
   by decision 10: 0.19.0 adds the two cases.
10. **Source breaks in 0.19.0.** Decided: allowed (David, 2026-11-22). The breaks taken are named
    in Release 0.19.0 and allowlisted in the API gate; each has an upgrade-guide entry with the
    edit that fixes the build.
11. **Bufferbloat's default upload URL** (#89). Decided: Cloudflare's speed-test upload endpoint,
    the same provider as the default download (David, 2026-11-22). `testBufferbloat` sends its
    upload load to a volunteer-run test site today when the caller sets no `uploadURL`.
    `https://speed.cloudflare.com/__up` accepted a 1 KB and a 1 MB POST with status 200 on
    2026-11-22; its limits and terms were not checked. Callers who set `uploadURL` are unaffected.
    It is its own pull request (Upload Default), with an upgrade-guide entry.

12. **Public-IP resolution is injectable.** Decided: a `PublicIPResolver` the caller can replace,
    with the library's own as the default, and existing callers may break for it in 0.19.0
    (David, 2026-11-22). See Public-IP Resolver.
13. **The DNS whoami fallback.** Decided: not through a resolver, whose own address can differ
    materially from the caller's; acceptable only as a packet the library crafts and sends itself
    to a server that echoes its source (David, 2026-11-22). Measurement in #153.
14. **Is the wrong fallback patched in 0.18?** Read by the author from David's "we can put this in
    0.19" as no: #153 is fixed in 0.19.0 by Public-IP Resolver, with no 0.18.2. Not stated by
    David in those words.
15. **Reporting every method's answer.** Open. Recommended: not in 0.19.0. The observation that
    is believed names its source; a caller who wants every reply supplies a resolver. ROADMAP.
16. **Which answer the library's resolver believes, and whether it has a DNS echo at all.** Open.
    Both reviewers found that "first valid answer wins" with a DNS echo beside STUN is unsafe: a
    gateway, captive portal or DNS proxy that intercepts port 53 can answer a query sent to a
    literal address with a well-formed reply carrying its own or its resolver's address, faster
    than STUN, and nothing in the packet shows it. Options: **STUN Only** (recommended for
    0.19.0): no DNS echo; where STUN is blocked the trace classifies without an address, or the
    host app supplies one. **STUN Leads**: an echo answer is used only when no STUN server
    answered and two independent echo operators agree. **Agreement Required**: no address unless
    two operators agree and one of them is STUN. The echo itself (class CH is unsupported by the
    DNS client today; strict reply checks; whether to pin Google's addresses) is ROADMAP unless
    this decision brings it in.

## Out of scope

Still unbounded after this plan, or deliberately deferred. Roadmap, not this plan:

- Replacing `getaddrinfo` for forward resolution.
- The public synchronous `reverseDNS(_:)`, direct `TraceClassifier.classify` with an
  uncooperative resolver, and `preloadASNDatabase()` with a remote source.
- `testBufferbloat`, whose load generation uses `URLSession.shared` and is awaited without
  cancellation after the ping phase ends.
- The `swift-ftr` CLI's own synchronous `reverseDNS` and `getaddrinfo` calls.
- DNS over TCP on truncation, and EDNS0. A truncated answer is `malformedResponse` today.
- The blocking `poll` and `usleep` in `SendRetry.swift`, which can hold the tracer actor or an
  operation's queue for up to the 250 ms burst budget.
- `discoverPublicIPWithHostname()` not being ended by a network change.
- Using real PTR time-to-live values in `RDNSCache` instead of one cache-wide value.
- Collapsing the multipath per-flow pipeline onto the shared classified-trace implementation.
- Coalescing identical in-flight forward lookups.
- Thread Sanitizer and Address Sanitizer jobs, scheduled soak runs, DNS and STUN parser fuzzing.
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
- Changing foreign-transaction-ID handling in the Event-Based DNS stage itself (raised by all
  three as a choice to make). Kept out of that stage; decision 8 then made it its own change
  before 0.18.0.

**0.19.0 sequencing, 2026-11-22.** The Release 0.19.0 section was reviewed once by Codex and
Gemini, against a draft that put Overall Deadline third and grouped the rows into independent
lanes. Folded
in:

- A deadline cannot be kept while a trace calls `getaddrinfo` on the actor, so the deadline rows
  moved after Resolution Off The Actor (both; Gemini would put them last, Codex would move
  resolution earlier, and last was chosen because the resolver should have the executor to
  itself, which needs reverse DNS converted first).
- The rows share files, so merges are serial and dependencies are named per row (both).
- Async Public-IP Discovery as first written would have moved STUN name lookups onto the
  cooperative pool with no deadline; they stay executor requests under one discovery deadline
  (Gemini). The whole-discovery cap is preserved across queueing, attempts and fallback (Codex).
- The `DNSError` mapping was misstated: a received unreachable throws `timeout` today, not
  `sendFailed` (both).
- Remembering a failed discovery, and ASN timeout propagation, must precede the deadline or its
  default sum is wrong; `HybridASNResolver` ignores its timeout and a cancelled database load
  latches the resolver as failed (both). Hence Enrichment Lifetimes.
- The first deadline slice must commit measured hops at receive completion and cap every phase
  it sums (Codex).
- Codex measured that the API check reports added enum cases and accepts one exact line per
  allowlist entry, and reports nothing for an added initializer.
- Gemini reported that a second initializer with a defaulted extra parameter makes
  `SwiftFTRConfig()` ambiguous. That is wrong: Swift picks the initializer with the fewest
  defaulted parameters (measured by Codex and by the author). New options stay further
  initializers.
- The resolution seam is shared by traces and probes, so resolution is one change (Gemini).
- The "stopping short" claim was false; replaced by what must ship together (both).
- Nothing ran the API check in CI, and the exhaustive-switch test decision 6 cited did not
  exist (Gemini).

Declined: deferring the bufferbloat upload default to the roadmap (both suggested it while
decision 11 was open; David has since decided it).

Not checked by the author: the reviewers' line citations were read for the findings adopted, not
for every claim in their reports.

**Injectable public-IP resolution, 2026-11-22.** The Public-IP Resolver and Event-Based STUN
sections were reviewed once by Codex and Gemini, against a draft with a DNS echo beside STUN and
first answer wins. Folded in: that rule is unsafe against intercepted port 53 (both), so the
library's resolver is STUN only pending decision 16; the cache must be per family and the
question asked after the family is known (both); the tracer, not the resolver, enforces the
deadline, with a single-resume race (Codex); sockets are bound before the server name is
resolved (Gemini); every address is checked for scope and family from every source (Gemini); the
source must survive caching and reach results (both); `getPublicIPs` relaxed its source binding
(Codex); the stage is two pull requests (both); the API gate must list the new breaks (Gemini).
Declined: pinning literal STUN addresses now (Gemini; already a ROADMAP item with an open
trade-off); merging the seam with Event-Based STUN to avoid wrapping blocking STUN first
(Gemini; the seam is the caller-visible change and should not wait on a transport swap). The
reviewers' line citations were read for the findings adopted, not for every claim.

No third review round on the design: the second version adopts the reviewers' recommendations
and does not introduce a new approach.

Unverified claims this plan repeats: that a stalled `getnameinfo` holds a slot for about 30
seconds (repo comments and an earlier measurement, not re-measured); behavior on NAT64, on a
network with broken IPv6, and with the system daemon stopped or stalled (documentation and
source reading only). The measurements cited are one machine on one network.
