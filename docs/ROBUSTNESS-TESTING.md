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

- **Seams, not mocks of the whole tracer.** `Sources/SwiftFTR/TestSeams.swift` holds task-local
  overrides, all `nil` in production: the blocking-I/O executor, forward resolution, the ICMP
  socket factory used by trace and ping, IPv4 public-address discovery, a hook that holds
  `discoverPaths` at the step where it commits its result, the `fcntl` that makes a trace, ping,
  UDP exchange, TCP probe or UDP probe socket non-blocking, and for the event-based UDP transport (`UDPExchange`) its
  `send` and `close` calls and the DNS server port. Task-locals
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
- **Discrimination.** Each test states the failure it catches and was shown to fail against a
  deliberately broken build (a negative control) before being kept; the PR body lists them.
- **No bound assumes a fast machine.** A stall is held by a gate for far longer than the operation
  is allowed. Tests assert that the operation returned while its stall was still in force, under a
  watchdog derived from configuration (`measure(within:)`): half the shortest stall for
  cancellation, the default public-IP budget for enrichment, the moment a slow fixture would have
  answered for the wire protocols.
- **A socket that never runs dry, not a flood, for the receive loops.** A receive loop reads until
  its socket reports no data, so the tests hold one by never letting that happen: the `fcntl`
  seam leaves the probe socket blocking with a 1 s receive timeout, and a fixture sends a
  well-formed reply for another identifier every 2 ms, so every read gets a datagram. A loopback
  flood was tried first and cannot do this reliably. Paced to stay ahead, it held the unfixed loop
  in roughly 70 to 100 percent of debug runs on an M4, and in the rest the loop found the socket
  empty within seconds, because loopback delivers at about the rate a loop drains. Sent flat out,
  it overflowed loopback's input queue (`net.link.generic.system.rcvq_maxlen`, 256): one run lost
  about 85,000 of 285,000 packets host-wide and failed unrelated tests running in parallel. Over
  IPv6, even twelve senders kept the socket readable only about 72 percent of the time.

## Conditions covered

The battery landed in two pull requests: the seams, fixtures and probe-window tests first, then
the remaining tests with the library fixes they motivated. All of it is below.

| Phase | Conditions | Operations | Tests |
|---|---|---|---|
| Forward resolution | fails (the injected error is checked, so a call that went around the seam fails); stalls (disabled, finding 5) | trace, traceClassified, traceStream, ping | `ProbeWindow`, `Enrichment` |
| Probe socket | creation fails the way `socket(2)` does; every send fails with a non-transient errno | trace, traceClassified, traceStream, ping | `ProbeWindow` |
| Probe socket (ping) | every send fails: nothing is counted as sent, and the ping does not wait out a reply window | ping | `ProbeWindow` |
| Probe window | no replies; late replies; truncated, garbage and seeded-random ICMPv4/ICMPv6 ahead of valid replies, which are still processed; another identifier; unreachable; a silent stream that must wait out its window and send its retries | trace, traceStream, ping | `ProbeWindow` |
| Ping reply matching | echo replies with the ping's identifier for sequences never sent (0, 9, 65535) or not yet sent, a reply queued while its request was still being sent, and duplicates, are not counted and neither end the ping early nor hold it; the first reply to a sequence keeps its RTT and TTL; a reply after its probe's `timeout` but within the ping counts; with a failed send, the ping ends once every probe that left is answered, whether the last reply or the end of the send loop comes last, does not end before its remaining probes are sent, and still waits out its window for an unanswered probe (IPv4 and IPv6) | ping | `PingReplyMatchingTests` |
| Public-IP discovery | stalls past its budget; fails; result arriving after a network change | traceClassified, discoverPaths | `Enrichment`, `Cancellation` |
| STUN wire | silent, garbage, wrong transaction, slow server; sub-microsecond timeout | stunGetPublicIP | `Wire` |
| Reverse DNS | stalls past its deadline; the stall breaker; cancellation during the wave; a cancelled lookup is not cached and, though it ran past the stall threshold, does not count toward the breaker | trace, traceClassified, discoverPaths | `Enrichment`, `Cancellation` |
| Reverse-DNS lookup (`DNSServiceQueryRecord`, not yet used by `RDNSCache`) | the PTR question for IPv4, IPv6, IPv4-mapped and zoned link-local addresses; PTR data that is not one well-formed, uncompressed name (a compression pointer, a reserved label type, truncation, trailing data, over 255 bytes, the root alone); labels from the reverse zone holding `.`, `\`, space, NUL, ESC, DEL, invalid and non-ASCII UTF-8, escaped to printable ASCII with one label reading as one, also over 500 random names; each outcome (an added PTR, no such record and no such name, daemon errors, the daemon's timeout, intermediate CNAMEs and remove events ignored); the start call or the queue call failing; the deadline; cancellation before the start, during a start stalled in the daemon, after the start, racing a reply and racing the deadline, each with one outcome and one deallocate per reference on the lookup's queue and the callback context still alive at every deallocate; each order of a reply against a cancellation and against the deadline, forced by holding the lookup's queue and by passing the deadline from the test through the `armDeadline` seam, never by a timer racing the test; a start stalled past the deadline releasing the caller and deallocating when it returns; the cap on lookups in flight, whose permit is held until the reference is gone; with every executor slot held; a stress loop of 3,000 answered, cancelled and expiring lookups of 127.0.0.1 and ::1 against the real daemon, asserting only what holds in any interleaving; a live comparison with `getnameinfo` | `ReverseDNSLookup.lookup` | `ReverseDNSLookupTests`, `ReverseDNSLookupDaemonTests` |
| ASN | resolver that stalls and ignores its timeout, or ignores cancellation | traceClassified, discoverPaths | `Cancellation` |
| DNS wire | silence, slow, NXDOMAIN, SERVFAIL, garbage without the query's transaction ID (ignored, so a timeout), oversized, compression loop, overstated answer count (both incomplete answer sections are `malformedResponse`) | the `__dnsQuery` SPI | `Wire` |
| DNS transport | refused port (IPv4 and IPv6); empty datagram (ignored, so a timeout); `EAGAIN` and `ENOBUFS` on send, retried and persisting; a short send; `fcntl` failure; cancellation while the server is silent; the socket closed exactly once, before the caller resumes, on every way out | `tracer.dns`, dnsProbe, the `__dnsQuery` SPI | `EventBasedDNSTests` |
| DNS probe outcome | every `DNSProbeOutcome` with the full result (`outcome`, `isReachable`, `rtt`, `elapsed`, `responseCode`, `error`): an answer and NXDOMAIN; a refused port (IPv4 and IPv6); silence; a short datagram with the query's transaction ID (`malformedReply`); `EHOSTUNREACH` and `ENETUNREACH` on receive, through the receive seam; `EHOSTUNREACH`, `EHOSTDOWN`, `ENETUNREACH` and `ENETDOWN` from `connect` (connect seam) and `send`; other connect and send errors, an unclassified receive error and an invalid server; a stall inside the read excluded from the round trip; an unreachable error read before the send ignored; no read once the exchange has finished and closed its socket, with a second reply still queued (answered, timed out, cancelled); cancellation mid-probe; the initializer and 0.17 JSON without `outcome`, and a round trip | dnsProbe, `DNSProbeResult` | `DNSProbeOutcomeTests` |
| DNS foreign replies | a reply with another transaction ID, then the real one, which answers with its own round trip (IPv4 and IPv6); empty and one-byte datagrams, then the real reply; only foreign replies, read while the query still waits, then a timeout and `timedOut`; a datagram with the query's ID but no valid header, still `malformedResponse` at once; a stale reply queued before the send and read after it; after a foreign datagram, a reply or refusal that comes only after the deadline, which is a timeout because each read event judges at most one datagram (query and dnsProbe); foreign replies that never stop, on a socket that never runs dry, with the deadline (IPv4 and IPv6) and cancellation still ending the query; a Team Cymru lookup answered foreign first; the blocking TXT path: a foreign and an empty datagram before the reply, a wait bounded by the time left after a foreign reply, a reply returned after the deadline (as the first read, or after a foreign one) taken as a timeout and the next server tried, and an endless feed | the `__dnsQuery` SPI, `tracer.dns`, dnsProbe, CymruDNSResolver, `DNSClient.queryTXTBlocking` | `DNSForeignReplyTests` |
| DNS question echo | a reply with the query's ID echoing another name, type or class, then the real reply (IPv4 and IPv6); only such replies, then a timeout and `timedOut`; the name echoed in another letter case answers; a header-only REFUSED still answers with RCODE 5; a question cut short is still `malformedResponse` at once; an endless feed of such replies with the deadline still ending the query (IPv4 and IPv6); the blocking TXT path, with such a reply before the real one and with an endless feed | the `__dnsQuery` SPI, `tracer.dns`, dnsProbe, `DNSClient.queryTXTBlocking` | `DNSQuestionMatchTests` |
| DNS first-question verdicts | every shape of a same-ID reply's first question (matching, other letter case, other name or type, a compression pointer into the header, a pointer loop, reserved label types 0x40 and 0x80, a label past the end, a name over 255 bytes, a missing terminator, type and class cut short, two questions with the first matching or not, no question with trailing bytes), with its verdict on the query, dnsProbe and the blocking path, and the shared reading the matcher and validator both use | the `__dnsQuery` SPI, dnsProbe, `DNSClient.queryTXTBlocking` | `DNSQuestionVerdictTests` |
| Address parsing | `seedPublicIP` and the public-address table, for IPv4, IPv4-mapped and NAT64-embedded IPv4 and IPv6; a NUL inside an address or destination string, through every parser and public entry point that reaches one | seedPublicIP, isPrivateIPv4, isCGNATIPv4, reverseIPv6Nibbles, reverseDNS, destination resolution, DNS server and source addresses | `PublicIPValidationTests` |
| DNS error replies | well-formed NXDOMAIN (SOA in authority; CNAME chain), SERVFAIL and REFUSED (question echoed; header only) keep their response code; the same codes with a declared answer record missing or cut short, or a declared question missing or cut short, are `malformedResponse` and `malformedReply` | the `__dnsQuery` SPI, `tracer.dns`, dnsProbe | `DNSErrorReplyValidationTests` |
| Full executor | every blocking-I/O slot held while discovery and reverse DNS queue; invalid DNS inputs reported as themselves without waiting for a slot; DNS queries, dnsProbe and Team Cymru lookups answer while every slot is held | traceClassified, queryA, `tracer.dns`, dnsProbe, CymruDNSResolver | `Enrichment`, `EventBasedDNSTests`, `CymruEventBasedTests` |
| TCP / UDP / HTTP | refused, accept-then-silence, reset mid-response, close without response, slow first byte, 503, cancellation | tcpProbe, udpProbe, httpProbe | `Wire` |
| HTTP headers then a stalled body | `Content-Length` or chunked, with and without `Content-Type`; `Connection: close`; a small first body chunk, with and without `Content-Type`; no body on a kept-alive connection; a partial status line | httpProbe | `Wire` |
| Cancellation | task cancellation, `networkChanged()`, `cancelActiveTraces()`, and the caller and the tracer together, across each operation and in each stalled phase, with the exact error checked per source; a stream consumer that cancels sees a normal end and the producer closes its socket; an invalidation either side of `discoverPaths` committing its result | trace, traceClassified, traceStream, ping, discoverPaths | `Cancellation` |
| Concurrency | many simultaneous operations on one tracer and across tracers under faults, with a network change mid-flight | trace, traceClassified | `Enrichment` |
| Non-blocking switch | either `fcntl` call that sets `O_NONBLOCK` fails; for the probes, the result, nothing sent or connected, and the socket closed, against a pass-through control | trace, traceClassified, traceStream, ping, tcpProbe, udpProbe | `ReceiveLoop`, `ProbeNonBlockingSetupTests` |
| Receive loop | a socket that never reports it is empty, fed well-formed replies for another identifier: the deadline, cancellation, ping's sends and a stream's retry still happen, and valid replies among them are recorded; a backlog longer than one read callback is read to the end; the socket is closed when the operation returns | trace, traceStream, ping | `ReceiveLoop` |
| The fixtures themselves | stall gate release rules; the watchdog; zero-byte UDP; refusing TCP port reserved; TCP `stop()` returns without waiting for its handlers and `stopAndWait()` joins them; a stopped UDP fixture's thread closes its own socket | fixtures | `Fixture` |

Test suites are `FaultInjection<Name>Tests`, plus `EventBasedDNSTests`, `DNSProbeOutcomeTests`,
`DNSForeignReplyTests` and `DNSErrorReplyValidationTests` for the event-based DNS transport,
`CymruEventBasedTests` for the Team Cymru lookups on it, `ProbeNonBlockingSetupTests` for the TCP
and UDP probes' socket setup, and `ReverseDNSLookupTests` and `ReverseDNSLookupDaemonTests` for
the `DNSServiceQueryRecord` reverse lookup. Every timed operation runs under a watchdog
(`measure(within:)`), so an operation that never returns fails its test instead of hanging the run.

Fixture teardown parks no thread. A fixture's `stop()` sets a flag under the fixture's lock and
returns; the fixture's own thread notices within its 20 ms receive timeout or poll and closes its
socket as it exits. Every other path that sends on that socket (a delayed reply, an injected one)
checks the flag under the same lock, and the close happens under that lock after the flag is set,
so no descriptor number is used after it is closed and perhaps handed to another test's socket.
A fixture with more than one thread closes its socket in the last one to exit; `EndlessReplies`
keeps the reply port reserved until its sender's last reply has gone. A test that needs a fixture
joined awaits it without a thread (`LoopbackTCPServer.stopAndWait()`). The suite passes with
`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`, which limits the cooperative pool and so exposes a
blocking call made from an async test.

Not covered, and why:

- **A socket that fails on read.** Darwin keeps delivering datagrams to a UDP socket after
  `shutdown(SHUT_RD)`, and closing the descriptor under the trace would risk the number being
  reused, so no test stages a read error. The receive loop's deadline timer is independent of the
  read source, which is the property that bounds it; that is shown by the silent-network tests.
- **A `.remote` ASN database download that stalls** (finding 7). The download is skipped whenever
  a database is already cached under `~/Library/Application Support/SwiftIP2ASN`, which is shared
  with every other user of SwiftIP2ASN on the machine, and the cache location cannot be redirected
  from SwiftFTR. A test would have to delete that cache.
- **Missing authority or additional records.** A reply is checked for the question and answer
  records its header declares, and an NXDOMAIN reply's SOA lives in the authority section, so an
  NXDOMAIN reply whose header declares an authority record it does not carry is still reported as
  NXDOMAIN. No response code has those sections checked, so no test stages it.
- **The `finished` check at the top of the read handler.** Every path that finishes the exchange
  returns from the handler, and Dispatch invokes no event handler once the source is cancelled,
  so no test can enter the handler after `finish`: removing the check fails nothing.
  `DNSProbeOutcomeTests.noReadAfterFinish` shows that no read follows the close, and fails when
  the check is removed together with the `return` after a reply.
- **A stale datagram that carries the query's own transaction ID.** A DNS query ignores every
  datagram without its transaction ID, before or after the send
  (`DNSForeignReplyTests.staleReplyReadAfterTheSend`), but it cannot tell when a datagram
  arrived, so a stale reply to an earlier query on the same port toward the same server that
  happens to carry the same ID is taken as the reply. Each query draws its ID from
  `UInt16.random(in:)`, the system's cryptographically secure generator, so a given stale reply
  matches with probability 1 in 65,536, and only after the kernel has handed the same ephemeral
  port to a new socket while that reply was still in flight. Not staged: no fixture can make the
  two IDs collide without a seam on ID generation.
- **A DNS reply that arrives after the deadline but before the deadline timer runs.** The
  transport checks the deadline before it accepts a reply, but the two events race on one queue
  and no fixture can order them deterministically, so no test shows the check is needed.
- **Host and network unreachable from the kernel** (finding 19). Loopback cannot produce
  `EHOSTUNREACH` or `ENETUNREACH`, so `DNSProbeOutcomeTests.unreachable` injects them through the
  receive seam; no test shows the kernel reporting them on a connected UDP socket.
- **The `.dns` and `.hybrid` strategies end to end**: their fallback is Team Cymru over the real
  resolver. `CymruEventBasedTests` runs `CymruDNSResolver` against a loopback responder; the
  battery passes a stub resolver to every classified trace so no test reaches it.
- **A TCP port that drops SYNs (filtered).** Producing one needs a firewall rule.
- **Which of two simultaneous resolutions of a reverse lookup wins.** The fake daemon forces each
  order of a reply against a cancellation and against the deadline by holding the lookup's
  queue and passing the deadline itself, but a cancellation and the deadline both resolve off
  that queue, and no fixture can make them arrive at the same instant; the lock decides, and the
  racing loops and the stress loop check only that one outcome and one deallocate follow.
- **The reverse lookup against a stopped or stalled daemon.** `kDNSServiceErr_ServiceNotRunning`
  and `kDNSServiceErr_DefunctConnection` are delivered through the substitute daemon; stopping the
  system's needs root.

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
   built from a configuration that dropped it (now `SwiftFTRConfig.multipathFlowConfig`, which
   copies every field, in `Multipath.swift`) and their classifier was not passed it, so each flow
   paid the 6 s default. Test:
   `multipathHonoursPublicIPBudget` with a 0.3 s budget, 12.0 s before, 0.6 s after; it fails if
   discovery outlasts the 6 s default.
4. **A sub-microsecond STUN timeout waited forever.** Confirmed and fixed. `stunGetPublicIP`
   truncated the timeout to a zero `timeval`, which disables `SO_RCVTIMEO`
   (`STUN.swift:213` after the fix). Reachable through the public `getPublicIPs(stunTimeout:)`.
   Test: `stunTinyTimeout`, still blocked at its watchdog before, immediate after.
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
8. **DNS queries waited without limit for an executor slot.** Confirmed and fixed. Every DNS
   query went onto the shared executor with no deadline, so its socket timeouts bounded the query
   but not the queueing: with the executor full, `dnsProbe` with a 0.3 s timeout waited as long as
   the occupant held it (3.0 s). A deadline counted from submission would have reported a healthy
   server as unreachable when no packet was sent, so instead DNS queries and Team Cymru lookups
   now wait on Dispatch sources (`UDPExchange.swift`) and need no worker. Tests:
   `EventBasedDNSTests.answersWithEveryWorkerHeld`, which waited out its 5 s watchdog before and
   answers while every slot is held after, and `CymruEventBasedTests.resolvesWithEveryWorkerHeld`,
   which returned no ASN data at its 1.5 s queue deadline before.
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
    full executor waited for a worker to report its input error. Tests:
    `discoverPathsCancellation` (every phase against every cancellation source) and
    `invalidDNSQueryWithFullExecutor`.

12. **The source address's family was checked only once a worker ran the query.** Fixed: the
    inputs that can be judged without I/O (timeout, name, server address, and the source address's
    family) are checked before a DNS query is queued, so a query that can never succeed reports
    why without waiting behind busy workers. Test: `invalidDNSQueryWithFullExecutor`, which fails
    at its watchdog without the check.
13. **`discoverPaths` could return a topology from the old network.** Confirmed and fixed; found
    by the second Codex review of fix 2. A network change that landed after the flows finished but before
    the result reached the caller was not seen, because the race against the handle covers only
    the flows, and the task group's join is a suspension point. In a stress loop of 20,000
    discoveries with a network change at spread offsets, 13 returned a topology although the
    change began while the discovery was still registered; with the fix, none. `discoverPaths` now
    commits in one non-suspending step on the tracer: it checks that its handle is still
    registered, which invalidation undoes synchronously before cancelling anything, and returns.
    Tests: `discoverPathsInvalidatedBeforeCommit` and `discoverPathsCommittedBeforeInvalidation`,
    which hold discovery at that step through the `beforeMultipathCommit` seam.
14. **An endless supply of irrelevant replies held trace, stream and ping past their deadlines.**
    Confirmed and fixed. Each receive loop read until its socket was empty, on the serial queue
    that also delivers its deadline timer, its cancellation, ping's sends and a stream's retry. On
    the unfixed code with real non-blocking sockets, a loopback flood of echo replies for another
    identifier held the trace, the stream and the ping past a 10 s watchdog with a 0.3 s window,
    held trace and stream cancellation the same way, and kept the stream's retry and ping's second
    and third probes from being sent. Ping cancellation was already prompt: its loop re-checked its
    state on every read. Each read callback now handles at most 64 datagrams and checks for
    cancellation and the deadline before every read. For the trace either half alone keeps the
    deadline and cancellation; ping's sends and the stream's retry need the bound. Tests:
    `FaultInjectionReceiveLoopTests`.
15. **A trace ran on a blocking socket when `fcntl` failed.** Confirmed and fixed. With the result
    ignored, a failed `F_SETFL` left the socket blocking, and every trace path, and ping once its
    own check was removed, waited in its last read past a 5 s watchdog with a 0.3 s window. The
    trace paths now throw `socketCreateFailed`, as ping did. Test: `nonBlockingFailure`.
16. **The trace paths closed their descriptor while the cancelled read source could still hold
    it.** Fixed from reading the code; the race is not observable from a test. The descriptor is
    now closed from the source's cancellation handler, before the call returns, as in ping and the
    TCP and UDP probes. The tests check that every socket is closed when the call returns.
17. **A refused DNS port was reported as silence.** Confirmed and fixed. `recv` on the connected
    socket failed at once with `ECONNREFUSED` and the client called it `DNSError.timeout`, so
    `dnsProbe` said "Timeout - no response" about a host that had answered. Measured on `main`:
    `timeout` after 1 ms, for a fixture port and for port 53 on loopback. Now the query methods
    throw `connectionRefused`, and `dnsProbe` stays unreachable (no DNS server answered) with a message
    that names the refusal and `outcome == .refused`, with `elapsed` set to when it arrived.
    Tests: `EventBasedDNSTests.refusedPort` and `DNSProbeOutcomeTests.refused`, IPv4 and IPv6.
18. **An empty DNS datagram was reported as silence.** Confirmed and fixed. A zero-byte `recv`
    was treated like a failed one, `DNSError.timeout` after 1 ms on `main`. It is now
    `malformedResponse`, which `dnsProbe` reported as reachable; finding 25 then made it a
    datagram that cannot answer the query, ignored like one with another transaction ID. Test:
    `EventBasedDNSTests.emptyDatagram`.
19. **Host and network unreachable on a DNS query were reported as silence.** Confirmed through
    the receive seam and fixed for `dnsProbe`. The transport ends the exchange at once on
    `EHOSTUNREACH` and `ENETUNREACH`, and `dnsProbe` said "Timeout - no response". It now returns
    `outcome == .unreachable`, with a message naming the errno and `elapsed` set to when the report
    arrived. The query methods still throw `DNSError.timeout` for them, since no existing case
    describes them and a new one would break exhaustive switches (ROADMAP). Test:
    `DNSProbeOutcomeTests.unreachable`, both errnos.
20. **Cancellation did not say who cancelled.** Confirmed and fixed. `ping` threw
    `TracerouteError.cancelled` when its own task was cancelled, in all 16 steps of the ping
    sweep. A trace's task-cancellation handler set the same flag `cancelActiveTraces()` sets, so a
    caller's cancellation was reported as the tracer's in every probe-window step (24 of 24), in
    the reverse-DNS wave and in three of four `traceClassified` phases. In the fourth, public-IP
    discovery, a `Task.checkCancellation()` noticed first and threw `CancellationError`, even when
    the tracer had cancelled too. The handle now records the reason in a lock-protected state
    that the task-cancellation handler sets synchronously, the tracer's reason outranking the
    caller's, and `trace` and `traceClassified` report it on the tracer's actor. Tests: the
    `FaultInjectionCancellationTests` sweeps, each asserting the exact type for each source and for
    both together (`Canceller.both`, which cancels the task and the tracer's traces in one step on
    the actor), and `streamConsumerCancellationCleansUp`.
21. **A stream cancelled just before it ended finished normally.** Confirmed from reading and
    fixed; found by Codex review of #110. A `cancelActiveTraces()` that landed after the producer
    passed its last check but before it unregistered was recorded and then ignored. The producer
    now commits, as `discoverPaths` does: it checks, unregisters and ends the stream in one
    non-suspending step on the tracer. Tests: `streamCancelledBeforeCommit` and
    `streamCommittedBeforeCancellation`, which hold the stream at that step through the
    `beforeStreamCommit` seam; with the old unconditional finish the first fails.
22. **A cancelled `dnsProbe` returned a fake result.** Confirmed and fixed. Cancelling the calling
    task mid-probe returned `isReachable == false` with "Unexpected error: CancellationError()".
    It now throws `CancellationError`. Test: `DNSProbeOutcomeTests.cancellation`.
23. **No route to the DNS server was reported as a send failure, without its errno.** Confirmed
    through the connect and send seams and fixed for `dnsProbe`. A `connect` failure became
    `DNSError.sendFailed` with the errno discarded, and a send-time errno was dropped, so "no route
    to this server", the usual no-network case, read "Failed to send query". `EHOSTUNREACH`,
    `EHOSTDOWN`, `ENETUNREACH` and `ENETDOWN` are now `outcome == .unreachable` with the errno, and
    other errnos are named in the message. The query methods throw `unreachable`. Test:
    `DNSProbeOutcomeTests.locallyUnreachable`, both stages and all four errnos.
24. **An unclassified receive error was reported as a timeout.** Fixed: `dnsProbe` said "Timeout -
    no response" for a socket error that came at once. It now says a receive error occurred, with
    the errno. Test: `DNSProbeOutcomeTests.failed`.
25. **A stale or stray DNS datagram decided the query.** Confirmed and fixed. The first datagram
    after the send was the reply whatever it was, so one with another query's transaction ID
    ended the query as `malformedResponse` and `dnsProbe` reported a silent server reachable;
    staged with a reply queued before the send and read after it. A DNS query now ignores any
    datagram without its transaction ID, or too short to carry one, and keeps waiting to its
    deadline; one with the right ID still decides, valid or not. After the send the transport judges at most one datagram per read
    event, so an ignored one costs its own event: a datagram read later in the same event could
    have arrived after the stamp taken for it, even after the deadline. An endless stream of
    ignored datagrams therefore cannot hold off the deadline or cancellation. The blocking TXT path waits only for the time it has left, and treats a reply `recv` returns after the deadline, which its receive timeout alone allows by about 2 ms, as a timeout.
    Tests: `DNSForeignReplyTests`.
26. **The TCP and UDP probes ran on a blocking socket when `fcntl` failed** (#107). Confirmed and
    fixed. Both ignored the two `fcntl` results, and neither read the `fileControl` seam, so an
    injected failure changed nothing: the TCP probe connected and reported `open`, the UDP probe
    sent its datagram. On a blocking socket, the TCP probe's `connect` waits for the kernel: with
    the check removed, a failed `F_SETFL` and a loopback listener whose backlog was full, a probe
    with a 1 s timeout returned after 7.8 s with `connectionState == .error` and "Operation timed
    out", not `.filtered`. Both probes now check the calls through `setProbeSocketNonBlocking` and
    report a failure as their other socket-setup failures are reported: not reachable, no round
    trip, `.error` for TCP and no response type for UDP, with a message naming the failed step
    and errno, before anything is sent, with the socket closed. Tests: `ProbeNonBlockingSetupTests`.

27. **A server that sent its headers and stalled its body was reported unreachable** (#122).
    Confirmed, partly fixed. URLSession calls the delegate's `didReceive response` only once body
    bytes follow the headers: one byte when the response declares `Content-Type:
    application/octet-stream`, otherwise enough to sniff a type from (600 bytes was enough, 10
    was not). `X-Content-Type-Options: nosniff`, chunked encoding, `Connection: close`,
    `prefersIncrementalDelivery` and the `bytes(from:)` API made no difference. So the probe ran to
    its timeout and said `isReachable == false`, `statusCode == nil`, `"Timeout"`. Now, when the
    task's metrics record a response start, the probe reports the server as reachable with an
    error beginning `"Timeout: "`, and with the status when the metrics carry the parsed response
    (they do once body bytes have arrived). With no body bytes the metrics hold only
    `responseStartDate`, the same as for a partial status line, so the status stays `nil`.
    Reporting the status as soon as the headers arrive needs a transport that reads the status
    line itself. Test: `FaultInjectionWireTests.httpHeadersThenStall`, whose prompt-status
    expectations are recorded with `withKnownIssue`.
28. **Ping counted echo replies it had not asked for.** Confirmed and fixed. Any echo reply with
    the ping's identifier was recorded under its sequence number, and the ping ended once it had
    as many as it sends. A reply to a sequence never sent ended a three-probe ping after its first
    probe, reporting one sent, one received and no loss; with each probe answered behind a stray,
    the ping ended before the second probe's reply and reported 50 percent loss on a path that
    lost nothing. A reply to a sequence not yet sent was kept as that probe's reply, with an RTT
    of -1.0 s and the unanswered probe counted as received. A duplicate replaced the first reply's
    RTT and TTL (0.104 s for a 0.2 ms reply). Ping now counts only the first reply to a request it
    has sent and drops the rest like replies for another identifier. A send time recorded before a
    read does not prove the reply came after the send: a reply queued while the send was still
    retrying buffer pressure on the ping's queue was read after the send time was set, kept, and
    the genuine reply dropped as its duplicate (TTLs 9, 7, 9 for three genuine replies marked 9).
    Ping now reads the kernel's arrival stamp (`SO_TIMESTAMP_MONOTONIC`, delivered on this macOS
    for unprivileged ICMP and ICMPv6 datagram sockets and on the clock ping stamps its sends with)
    and ignores a reply that arrived before its request's successful send. Without a stamp the
    reply is judged as before. A reply to an earlier probe
    that arrives after `timeout` but before the ping's last reply window ends still counts, as
    `PingConfig.timeout` documents. Tests: `PingReplyMatchingTests`, IPv4 and IPv6.
29. **A ping whose send failed waited out its whole window** (#138). Confirmed and fixed. Early
  completion compared the replies with the configured `count`, which a ping with a failed send
  can never reach: two probes, the first send failing and the second answered at once, ended at
  the reply deadline. Once the send loop has finished, the ping now compares the replies with the
  sends that succeeded, both when the loop finishes and when a reply arrives. Tests:
  `PingReplyMatchingTests` (`failedSend…`), IPv4 and IPv6.
30. **`seedPublicIP` accepted a NAT64 address wrapping a private IPv4 address, and strings with an
  embedded NUL** (#139). Confirmed and fixed. `64:ff9b::192.168.1.1` was accepted because the
  well-known prefix was accepted whatever it embedded; RFC 6052 section 3.1 forbids it for
  non-global IPv4. `"8.8.8.8\u{0}junk"` was accepted as `8.8.8.8` because `inet_pton` reads a C
  string. The same truncation reached every parser that hands a caller's string to `inet_pton` or
  `getaddrinfo`: `isPrivateIPv4`, `isCGNATIPv4`, `reverseIPv6Nibbles`, `reverseDNS` (which looked
  up the address before the NUL), DNS server and source addresses, and destination resolution
  for ping, trace and the TCP and UDP probes (which resolved and probed the text before the NUL).
  The parsers and destination resolution now reject such a string. Interface names reach
  `if_nametoindex` the same way and are not checked. Tests: `PublicIPValidationTests`.
31. **A DNS reply's question was never compared with the query** (#128). Confirmed and fixed. A
  reply with the query's transaction ID was accepted whatever question it echoed, so its answers
  were reported for the name asked. A datagram whose first question is readable and names another
  name (compared without regard to ASCII case), type or class is now ignored like one with a
  foreign ID, on the event-based and blocking paths, and the query waits on to its deadline.
  The matcher and the validator read the first question by one rule, so they agree on which
  questions are unreadable (and so malformed): review of the first version found that its own
  reader let a compression pointer through, and the validator then read a pointer into the
  header as the root name and took the reply's REFUSED; and that it had no 255-byte limit, so a
  malformed reply was ignored as a different question. Tests: `DNSQuestionMatchTests`,
  `DNSQuestionVerdictTests`.

Observations that are not defects of the library:

- `traceStream` yields hops in arrival order, so when the destination answers several TTLs a hop
  past the destination can arrive, flagged `reachedDestination`, before the real destination's.
  This is the documented contract ("the caller is responsible for sorting"); the battery asserts
  that the lowest such TTL is the destination.
- `TraceLifecycleTests.cancelActiveTracesCancelsClassifiedTrace` is not gated on
  `SKIP_NETWORK_TESTS`, so the offline suite sends a real trace toward `192.0.2.1` and real STUN
  queries. The seams added here would let it run offline.
- An `AsyncThrowingStream` producer that finishes with an error inside its own `onTermination`
  handler delivers that error to a consumer that cancelled; one that finishes after the handler
  returns does not. `traceStream` therefore finishes normally when its consumer cancels, rather
  than relying on its producer losing that race.
- A wait on a test-owned signal that is a bare continuation, semaphore or stream cannot be ended
  by `.timeLimit`, whose task group still joins the stuck child. Waits for a fixture to start,
  become ready or be cancelled go through `waitBounded`, and polls for one to run through
  `eventually`, each failing the test after ten seconds. A test that gives up does not join the
  operation it was waiting on. A wait for a task that only the behaviour under test can end, a
  cancellation or a deadline the test is checking, runs under `measure(within:)`. Waits that
  cannot fail to end are left unbounded: a stall the test itself releases, a call with its own
  timeout that is not the one under test.
- `fstat` cannot tell sockets apart on Darwin: it reports inode 0 for every socket. The battery
  identifies a socket by its bound local address when checking that the library closed it.
