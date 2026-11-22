# Robustness testing: fault injection, phase by phase

Plan and coverage map for the ROADMAP item "Robustness under network and DNS failure, proven by
tests" and the open asks of #84.

## Why

SwiftFTR runs inside software that is diagnosing a broken network, so a failing network is its
normal operating condition (David, 2026-11-21). The promise under test is: every public operation
returns or throws within a time the caller can compute from its configuration, returns a degraded
result where one is defined, and never crashes, hangs, leaks or strands its caller, whatever fails
underneath and at whatever point. Release 0.17.1 fixed three defects of exactly this kind in the
blocking-I/O bridge, two found only by review. The existing offline tests prove the bridge in
isolation; nothing proved the assembled operations under failure, because forward resolution, the
probe socket and public-IP discovery could not be replaced from a test.

A different solution would also serve if it gives the same property: deterministic, offline tests
that fail when any phase can wait without a bound or strand its caller.

## Method

- **Seams, not mocks of the whole tracer.** `Sources/SwiftFTR/TestSeams.swift` holds four
  task-local overrides, all `nil` in production: the blocking-I/O executor, forward resolution,
  the ICMP socket factory used by trace and ping, and IPv4 public-address discovery. Task-locals
  scope an override to the test task and its children, so no test touches process-wide state and
  parallel tests cannot see each other's overrides. Production behavior is unchanged when they are
  unset, and the public API is unchanged
  (`swift package diagnose-api-breaking-changes v0.17.1 --products SwiftFTR`).
- **A loopback "network" for the probe window.** The socket factory hands a trace a loopback UDP
  socket instead of an ICMP one, and forward resolution points the trace at a loopback UDP peer.
  The trace sends its real echo requests to that peer, which replies with whatever a test scripts:
  silence, late replies, time-exceeded and echo replies, truncated or garbage datagrams, replies
  carrying another identifier. The trace's own receive loop and parser handle them unchanged.
- **Local fixtures for every other protocol.** TCP listeners that refuse, accept and stay silent,
  reset mid-response or answer slowly; an HTTP responder on the same listener; UDP responders for
  STUN and DNS that stay silent, answer late or answer garbage. All bind `127.0.0.1` or `::1` on an
  ephemeral port. No new test sends a packet off the host. The fixtures have tests of their own
  (`FaultInjectionFixtureTests`).
- **Private executors.** Any test that stalls a blocking call does it on a private
  `BlockingIOExecutor`, installed through the seam, never on the process-wide one.
- **Discrimination.** Each test states the failure it catches. Where practical it was shown to fail
  against a deliberately broken build (a negative control) before being kept; the PR body lists
  which.

## Conditions covered

The battery landed in two pull requests: the seams, fixtures and probe-window tests first, then
the remaining tests with the library fixes they motivated. All of it is below.

| Phase | Conditions | Operations | Tests |
|---|---|---|---|
| Forward resolution | fails (the injected error is checked, so a call that went around the seam fails); stalls (disabled, finding 5) | trace, traceClassified, traceStream, ping | `ProbeWindow`, `Enrichment` |
| Probe socket | creation fails the way `socket(2)` does; every send fails with a non-transient errno | trace, traceClassified, traceStream, ping | `ProbeWindow` |
| Probe window | no replies; late replies; truncated, garbage and seeded-random ICMPv4/ICMPv6 ahead of valid replies; another identifier; unreachable; a silent stream that must wait out its window and send its retries | trace, traceStream, ping | `ProbeWindow` |
| Public-IP discovery | stalls past its budget; fails; result arriving after a network change | traceClassified, discoverPaths | `Enrichment`, `Cancellation` |
| STUN wire | silent, garbage, wrong transaction, slow server; sub-microsecond timeout | stunGetPublicIP | `Wire` |
| Reverse DNS | stalls past its deadline; the stall breaker; cancellation during the wave; a cancelled lookup is not cached | trace, discoverPaths | `Enrichment`, `Cancellation` |
| ASN | resolver that stalls and ignores its timeout, or ignores cancellation | traceClassified, discoverPaths | `Cancellation` |
| DNS wire | silence, slow, NXDOMAIN, SERVFAIL, garbage, oversized, compression loop, overstated answer count | the `__dnsQuery` SPI | `Wire` |
| Full executor | every blocking-I/O slot held while discovery, reverse DNS and DNS queue; the queue deadline withdraws queued work and spares started work; a late-starting DNS query is governed by its own timeouts; invalid inputs reported as themselves | traceClassified, dnsProbe, queryA, the executor | `Enrichment` |
| TCP / UDP / HTTP | refused, accept-then-silence, reset mid-response, close without response, slow first byte, 503, cancellation | tcpProbe, udpProbe, httpProbe | `Wire` |
| Cancellation | task cancellation, `networkChanged()` and `cancelActiveTraces()` across each operation and in each stalled phase, with the error checked per source | trace, traceClassified, traceStream, ping, discoverPaths | `Cancellation` |
| Concurrency | many simultaneous operations on one tracer and across tracers under faults, with a network change mid-flight | trace, traceClassified | `Enrichment` |
| The fixtures themselves | stall gate release rules; the watchdog; zero-byte UDP; refusing TCP port reserved; TCP teardown joins its handlers | fixtures | `Fixture` |

Test suites are `FaultInjection<Name>Tests`. Every timed operation in the probe-window tests runs
under a watchdog (`measure(within:)`), so an operation that never returns fails its test instead
of hanging the run.

Not covered, and why:

- **A socket that fails on read.** Darwin keeps delivering datagrams to a UDP socket after
  `shutdown(SHUT_RD)`, and closing the descriptor under the trace would risk the number being
  reused, so no test stages a read error. The receive loop's deadline timer is independent of the
  read source, which is the property that bounds it; that is shown by the silent-network tests.
- **A `.remote` ASN database download that stalls** (finding 7). The download is skipped whenever
  a database is already cached under `~/Library/Application Support/SwiftIP2ASN`, which is shared
  with every other user of SwiftIP2ASN on the machine, and the cache location cannot be redirected
  from SwiftFTR. A test would have to delete that cache.
- **The `.dns` and `.hybrid` strategies end to end**: their fallback is Team Cymru over the real
  resolver. `CymruQueueDeadlineTests` covers their queueing bound; the battery passes a stub
  resolver to every classified trace so no test reaches it.
- **A TCP port that drops SYNs (filtered).** Producing one needs a firewall rule.

## Out of scope

- An overall deadline on `traceClassified` with an error naming the phase, and an executor-pressure
  reading (#84). Both are API additions for a minor release.
- Moving forward resolution off the actor. It needs a resolution budget, which is a new
  configuration field. The test that shows the defect is checked in disabled (finding 5).
- `testBufferbloat`, which needs real load traffic, and the interface-bound HTTPS spike.
- Raw-socket or privileged fault injection, and any test that sends traffic off the host.

## Gates

Each gate passes or fails on its exit status.

```bash
SKIP_NETWORK_TESTS=1 PTR_SKIP_STUN=1 swift test -c debug                      # full offline suite
SKIP_NETWORK_TESTS=1 PTR_SKIP_STUN=1 swift test -c debug --filter FaultInjection # the new battery
swift format lint --strict -r Sources Tests
swift package diagnose-api-breaking-changes v0.17.1 --products SwiftFTR
```

## Findings

Defects the battery exposed, with their disposition. Each "confirmed" finding has a test that
failed before its fix (or fails today, if disabled), with the measurement quoted. File and line
numbers are as of the commit that added this section.

1. **A network change did not interrupt a trace's reverse-DNS wave.** Confirmed and fixed.
   `performTrace` awaited `rdnsCache.batchLookup` outside `withTraceCancellation`
   (`Traceroute.swift:895` after the fix), so `networkChanged()` and `cancelActiveTraces()`
   returned the trace only when the slowest lookup hit its deadline (5 s by default). Test:
   `FaultInjectionCancellationTests.reverseDNSWave`, 10.0 s before, under 0.1 s after.
2. **`discoverPaths` ignored `networkChanged()` and `cancelActiveTraces()`.** Confirmed and fixed.
   Each flow runs on a throwaway tracer, so the parent's handles never included them; discovery
   ran to completion and returned a topology from the old network. Now `Multipath.swift:575`
   registers a handle and races discovery inside one task group, which still joins every worker.
   Test: `discoverPathsCancellation`, 10.0 s and a returned topology before, under 0.1 s after.
3. **`discoverPaths` ignored `publicIPDiscoveryTimeout`.** Confirmed and fixed. Flow workers were
   built from a configuration that dropped it (`Multipath.swift:618` and `:661` after the fix) and
   their classifier was not passed it, so each flow paid the 6 s default. Test:
   `multipathHonoursPublicIPBudget` with a 0.3 s budget, 12.0 s before, 0.6 s after.
4. **A sub-microsecond STUN timeout waited forever.** Confirmed and fixed. `stunGetPublicIP`
   truncated the timeout to a zero `timeval`, which disables `SO_RCVTIMEO`
   (`STUN.swift:213` after the fix). Reachable through the public `getPublicIPs(stunTimeout:)`.
   Test: `stunTinyTimeout`, still blocked at the 2 s watchdog before, immediate after.
5. **Forward resolution is synchronous on the tracer actor and unbounded.** Confirmed (known from
   #84), not fixed. `resolveHost` (`Traceroute.swift:629`, `:785`) calls `getaddrinfo` on the
   actor, even for a literal under `.auto`, so a stalled resolver holds every other call on that
   tracer, `cancelActiveTraces()` and `networkChanged()` included, and cannot be cancelled. With a
   5 s injected stall, `cancelActiveTraces()` took 5.0 s to return. Not fixed: bounding it needs a
   resolution budget, which is a configuration field. Test, disabled because it blocks for its
   stall: `FaultInjectionEnrichmentTests.forwardResolutionStall`.
6. **A failed public-IP discovery is paid twice.** Confirmed, not fixed. When discovery fails or
   times out, `traceClassified` passes `publicIP: nil` to the classifier (`Traceroute.swift:1059`),
   which runs discovery again with the same budget (`Segmentation.swift:240`), so the bound is two
   budgets. Measured in `multipathHonoursPublicIPBudget` (0.6 s for a 0.3 s budget). Not fixed
   here because the public `classify(publicIP: nil)` means "discover", so the fix is an internal
   way to say "already tried", a small design choice. Test, disabled: `publicIPDiscoveredOnce`.
7. **A `.remote` ASN database download is bounded only by URLSession's request timeout.**
   Unverified, from reading the code. With no bundled or cached database, the first resolve waits
   on `RemoteDatabase.load()` (`LocalASNResolver.swift:212`), which uses `URLSession.shared` with
   its 60 s default, and ignores the resolver `timeout`. Could not be staged (see "Not covered").
8. **DNS queries waited without limit for an executor slot.** Confirmed and fixed. Every DNS query
   went onto the shared executor with no deadline, so its socket timeouts bounded the query but not
   the queueing: with the executor full, `dnsProbe` with a 0.3 s timeout waited as long as the
   occupant held it (3.0 s). A query now waits at most its `timeout` for a worker (the executor's
   `queueDeadline`, which withdraws only work that has not started) and reports
   `DNSError.timeout`; once started it is governed by its own send and receive timeouts and is
   never cut off. Tests: `dnsQueryWithFullExecutor`, `startedDNSQueryNotCutOff`,
   `startedDNSQueryOwnTimeout`, `queueDeadlineSemantics`.
9. **`getPublicIPs` runs blocking STUN on Swift's cooperative pool, without a deadline.**
   Unverified, from reading the code. `STUN.swift:725` wraps `stunGetPublicIPWithFallback`,
   which calls `getaddrinfo` for each server hostname and blocks in `recv`, in plain `Task`s rather
   than on the bounded executor. A stalled resolver can hold two cooperative threads for up to
   30 s per server in the list, and the call cannot be cancelled. Not fixed: the right bound is a
   budget the public signature does not have.

10. **A reverse-DNS lookup cut short by cancellation was cached as a miss for 24 hours.**
    Confirmed and fixed; found by the Codex review of fix 1, which made it common. The resolver
    reports a cancelled wait as `nil`, and `RDNSCache.lookup` cached that as a negative answer and
    counted it toward the stall breaker. Test: `cancelledLookupNotCached`.
11. **Follow-ups to fixes 2 and 8, from the same review.** Confirmed by test and fixed: a flow
    cancelled during public-IP discovery went on to resolve its destination; a flow's
    classification could wait on a shared ASN load after cancellation; caller cancellation could
    surface from `discoverPaths` as `TracerouteError.cancelled`; and an invalid DNS query behind a
    full executor reported `timeout` instead of its input error. Tests:
    `discoverPathsCancellation` (every phase against every cancellation source) and
    `invalidDNSQueryWithFullExecutor`.

12. **The DNS queue deadline masked a source address of the wrong family.** Confirmed by the
    second review pass of the first version of fix 8, and fixed with both halves of the chosen
    design (coordinator's decision): the deadline now bounds only the wait for a worker, so a query
    that has started reports its own errors; and the inputs that can be judged without I/O
    (timeout, name, server address, and the source address's family) are still checked before
    queueing, because a query that is withdrawn never runs and so cannot discover them. Without the
    up-front check a wrong-family `sourceIP` behind a full executor still reports `timeout`, which
    is what the negative control showed. Test: `invalidDNSQueryWithFullExecutor`.

Observations that are not defects of the library:

- `traceStream` yields hops in arrival order, so when the destination answers several TTLs a hop
  past the destination can arrive, flagged `reachedDestination`, before the real destination's.
  This is the documented contract ("the caller is responsible for sorting"); the battery asserts
  that the lowest such TTL is the destination.
- `TraceLifecycleTests.cancelActiveTracesCancelsClassifiedTrace` is not gated on
  `SKIP_NETWORK_TESTS`, so the offline suite sends a real trace toward `192.0.2.1` and real STUN
  queries. The seams added here would let it run offline.
