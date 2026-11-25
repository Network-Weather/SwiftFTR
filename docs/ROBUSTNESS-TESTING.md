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
  UDP exchange, TCP probe or UDP probe socket non-blocking, the `sendto` a trace, stream or ping
  sends its probes with, an observer of each read it makes from its probe socket, and for the event-based UDP transport (`UDPExchange`) its
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
  Each probe socket is connected to its peer before its first send, through the send seam (Darwin
  refuses a `sendto` that names an address on a connected datagram socket), so the kernel
  delivers to it only what that peer sends, and the peer answers only sockets it made.
- **Local fixtures for every other protocol.** TCP listeners that refuse, accept and stay silent,
  reset mid-response or answer slowly; an HTTP responder on the same listener; UDP responders for
  STUN and DNS that stay silent, answer late or answer garbage. All bind `127.0.0.1` or `::1` on an
  ephemeral port, without `SO_REUSEADDR` (see the last observation below). No new test sends a packet off the host. The fixtures have tests of their own
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
| Public-IP discovery | stalls past its budget; fails; result arriving after a network change; STUN attempts against silent loopback servers, each able to outlast the watchdog, ended by the one discovery deadline; a name lookup waiting for a slot, abandoned at it; a failure at the deadline reported as a timeout whichever timer fired first; the budget a multipath run's question carries; standalone `getPublicIPs` ended by its caller's cancellation, returning the family that answered, and leaving the cooperative pool free with more stalled calls than it has threads | traceClassified, discoverPaths, getPublicIPs | `Enrichment`, `Cancellation`, `AsyncPublicIPDiscoveryTests` |
| Library public-IP resolver | on a bound request every STUN socket bound to the interface at its send (IPv4 and IPv6); a missing interface or an unbindable source address sending nothing, no server-name lookup included; a source address of the other family, or not an address, sending nothing; STUN failing on a bound request with no DNS query sent after it; `getPublicIPs` with a source address running only that family's sweep, with a malformed one sending nothing, and asking the library's resolver, and asking nothing once cancelled; sweeps waiting for the executor holding no sockets; `discoverPublicIPWithHostname()` asking the strategy past the configured address and cache, throwing for `.disabled`, refusing a private or IPv6 answer, and reporting the library's failure as `noAddress` | the library's resolver, getPublicIPs, discoverPublicIPWithHostname | `LibraryPublicIPResolverTests`, `PublicIPResolverTests` |
| STUN wire | silent, garbage, wrong transaction, slow server; sub-microsecond timeout | stunGetPublicIP | `Wire` |
| Reverse DNS | a daemon that never answers, behind the real lookup and its deadline timer: the wave costs its deadline once, then the stall breaker skips it, and every query is stopped; cancellation during the wave, with each query stopped; a resolver that ignores cancellation in the second wave of a classified trace and of a multipath flow, which each return while it stalls; only an answer is cached; one trace, classified trace or multipath flow asks about each hop address once, so a hop that times out costs one budget and one stall; the stalled-address holdoff (David, 2026-11-24): no re-ask and no breaker change while it lasts, expiry at ten minutes on an injected clock, dropped by every reset, not created by no such record, a question never asked, an error, a cancelled lookup or a timeout from before a reset, its table bounded; one address counting once per run of stalls (proposed by an agent, not yet confirmed by David, 2026-11-24) when asked again after its holdoff ends; shared lookups (David, 2026-11-24): five concurrent lookups of one address making one query, with one permit, and all getting its answer or its one timeout (one stall, one holdoff); a cancelled joiner leaving at once with its registration while the query and the others carry on; the last waiter leaving cancelling the query, which then records nothing even when its resolver reports a timeout; a reset mid-flight, the old query ending before or after the fresh one, with the later lookup starting fresh and the old timeout recording nothing; the round-3 review's one-entry-cache case, where a lookup waiting on a held query gets that query's one outcome; ten traces over five paths (a stalled hop alone, beside a named hop, beside a named and a no-such-record hop, with a reset every three traces, and a six-hop path whose whole resolver is stalled) each paying a bounded number of budgets, the last opening the breaker; which outcomes count toward the breaker (an asked, unanswered unicast question), which reset it (an answer, no such record) and which do neither (no query asked in time, a link-local question, an error); a lookup whose caller cancelled, reported as a stall, does not count; the one-second cap on link-local lookups; the limiter capping the queries a batch has in flight; with every executor slot held, a lookup through the cache answering from the real daemon | trace, traceClassified, discoverPaths | `Enrichment`, `Cancellation`, `RDNSCacheTests`, `RDNSSuppressionTests` |
| Reverse-DNS lookup (`DNSServiceQueryRecord`, behind `RDNSCache`) | the PTR question for IPv4, IPv6, IPv4-mapped and zoned link-local addresses; PTR data that is not one well-formed, uncompressed name (a compression pointer, a reserved label type, truncation, trailing data, over 255 bytes, the root alone); labels from the reverse zone holding `.`, `\`, space, NUL, ESC, DEL, invalid and non-ASCII UTF-8, escaped to printable ASCII with one label reading as one, also over 500 random names; every row of the deadline table on the type, each event before and after the deadline (the start, a failed start or queue call, an added PTR, a malformed one, intermediate CNAMEs and remove events, no such record and no such name, a daemon error, the daemon's timeout, cancellation), with the deadline passed through the `armDeadline` seam and no wake-up, so the lookup's own check decides; cancellation before the start, during a start stalled in the daemon, after the start, racing a reply and racing the deadline, each with one outcome and one deallocate per reference on the lookup's queue and the callback context still alive at every deallocate; each order of a reply against a cancellation and against the wake-up, forced by holding the lookup's queue; a start stalled past the deadline releasing the caller and deallocating when it returns; the real timer's wake-up, off the lookup's queue, and a real deadline already passed when the start runs; the cap on queries in flight, whose permit is held until the reference is gone; one deadline covering the wait for a permit as well as the query, so a queued lookup times out (`timedOutBeforeQuery`) with no query and no permit taken | `ReverseDNSLookup.lookup` | `ReverseDNSLookupTests` |
| Reverse-DNS lookup against the real daemon | 127.0.0.1 and ::1 only, which the daemon answers from its local records with no query sent; loopback answers started and deallocated on the lookup's queue; with every executor slot held; the cap on queries in flight, with the first starts held until the cap is reached; in a child process, far more lookups than the cap all answering and every daemon connection they opened closed again, counted from the process's own descriptor table, with the child stopped and the test failed, with its output, if it is still running after two minutes (the peak open is printed, not asserted; `SWIFTFTR_RDNS_DESCRIPTOR_STRESS=1` adds the experiment of lowering the child's descriptor limit to what is open plus the cap plus two); a stress loop of 3,000 answered, cancelled and expiring lookups, asserting only what holds in any interleaving; a live comparison with `getnameinfo`, skipped offline | `ReverseDNSLookup.lookup` | `ReverseDNSLookupDaemonTests` |
| ASN | resolver that stalls and ignores its timeout, or ignores cancellation | traceClassified, discoverPaths | `Cancellation` |
| DNS wire | silence, slow, NXDOMAIN, SERVFAIL, garbage without the query's transaction ID (ignored, so a timeout), oversized, compression loop, overstated answer count (both incomplete answer sections are `malformedResponse`) | the `__dnsQuery` SPI | `Wire` |
| DNS transport | refused port (IPv4 and IPv6); empty datagram (ignored, so a timeout); `EAGAIN` and `ENOBUFS` on send, retried and persisting; a short send; `fcntl` failure; cancellation while the server is silent; the socket closed exactly once, before the caller resumes, on every way out | `tracer.dns`, dnsProbe, the `__dnsQuery` SPI | `EventBasedDNSTests` |
| DNS probe outcome | every `DNSProbeOutcome` with the full result (`outcome`, `isReachable`, `rtt`, `elapsed`, `responseCode`, `error`): an answer and NXDOMAIN; a refused port (IPv4 and IPv6); silence; a short datagram with the query's transaction ID (`malformedReply`); `EHOSTUNREACH` and `ENETUNREACH` on receive, through the receive seam; `EHOSTUNREACH`, `EHOSTDOWN`, `ENETUNREACH` and `ENETDOWN` from `connect` (connect seam) and `send`; other connect and send errors, an unclassified receive error and an invalid server; a stall inside the read excluded from the round trip; an unreachable error read before the send ignored; no read once the exchange has finished and closed its socket, with a second reply still queued (answered, timed out, cancelled); cancellation mid-probe; the initializer and 0.17 JSON without `outcome`, and a round trip | dnsProbe, `DNSProbeResult` | `DNSProbeOutcomeTests` |
| DNS foreign replies | a reply with another transaction ID, then the real one, which answers with its own round trip (IPv4 and IPv6); empty and one-byte datagrams, then the real reply; only foreign replies, read while the query still waits, then a timeout and `timedOut`; a datagram with the query's ID but no valid header, still `malformedResponse` at once; a stale reply queued before the send and read after it; after a foreign datagram, a reply or refusal that comes only after the deadline, which is a timeout because each read event judges at most one datagram (query and dnsProbe); foreign replies that never stop, on a socket that never runs dry, with the deadline (IPv4 and IPv6) and cancellation still ending the query; a Team Cymru lookup answered foreign first; a Team Cymru TXT lookup sent a foreign and an empty datagram before the reply | the `__dnsQuery` SPI, `tracer.dns`, dnsProbe, CymruDNSResolver, `DNSClient.queryTXT` | `DNSForeignReplyTests` |
| DNS question echo | a reply with the query's ID echoing another name, type or class, then the real reply (IPv4 and IPv6); only such replies, then a timeout and `timedOut`; the name echoed in another letter case answers; a header-only REFUSED still answers with RCODE 5; a question cut short is still `malformedResponse` at once; an endless feed of such replies with the deadline still ending the query (IPv4 and IPv6); a Team Cymru TXT lookup sent such a reply before the real one | the `__dnsQuery` SPI, `tracer.dns`, dnsProbe, `DNSClient.queryTXT` | `DNSQuestionMatchTests` |
| DNS first-question verdicts | every shape of a same-ID reply's first question (matching, other letter case, other name or type, a compression pointer into the header, a pointer loop, reserved label types 0x40 and 0x80, a label past the end, a name over 255 bytes, a missing terminator, type and class cut short, two questions with the first matching or not, no question with trailing bytes), with its verdict on the query, dnsProbe and the Team Cymru TXT lookup, and the shared reading the matcher and validator both use | the `__dnsQuery` SPI, dnsProbe, `DNSClient.queryTXT` | `DNSQuestionVerdictTests` |
| Address parsing | `seedPublicIP` and the public-address table, for IPv4, IPv4-mapped and NAT64-embedded IPv4 and IPv6; a NUL inside an address or destination string, through every parser and public entry point that reaches one | seedPublicIP, isPrivateIPv4, isCGNATIPv4, reverseIPv6Nibbles, reverseDNS, destination resolution, DNS server and source addresses | `PublicIPValidationTests` |
| DNS error replies | well-formed NXDOMAIN (SOA in authority; CNAME chain), SERVFAIL and REFUSED (question echoed; header only) keep their response code; the same codes with a declared answer record missing or cut short, or a declared question missing or cut short, are `malformedResponse` and `malformedReply` | the `__dnsQuery` SPI, `tracer.dns`, dnsProbe | `DNSErrorReplyValidationTests` |
| Full executor | every blocking-I/O slot held while discovery and reverse DNS queue; invalid DNS inputs reported as themselves without waiting for a slot; DNS queries, dnsProbe and Team Cymru lookups answer while every slot is held | traceClassified, queryA, `tracer.dns`, dnsProbe, CymruDNSResolver | `Enrichment`, `EventBasedDNSTests`, `CymruEventBasedTests` |
| TCP / UDP / HTTP | refused, accept-then-silence, reset mid-response, close without response, slow first byte, 503, cancellation | tcpProbe, udpProbe, httpProbe | `Wire` |
| HTTP headers then a stalled body | `Content-Length` or chunked, with and without `Content-Type`; `Connection: close`; a small first body chunk, with and without `Content-Type`; no body on a kept-alive connection; a partial status line | httpProbe | `Wire` |
| Cancellation | task cancellation, `networkChanged()`, `cancelActiveTraces()`, and the caller and the tracer together, across each operation and in each stalled phase, with the exact error checked per source; a stream consumer that cancels sees a normal end and the producer closes its socket; an invalidation either side of `discoverPaths` committing its result | trace, traceClassified, traceStream, ping, discoverPaths | `Cancellation` |
| Concurrency | many simultaneous operations on one tracer and across tracers under faults, with a network change mid-flight | trace, traceClassified | `Enrichment` |
| Non-blocking switch | either `fcntl` call that sets `O_NONBLOCK` fails; for the probes, the result, nothing sent or connected, and the socket closed, against a pass-through control | trace, traceClassified, traceStream, ping, tcpProbe, udpProbe | `ReceiveLoop`, `ProbeNonBlockingSetupTests` |
| Receive loop | a socket that never reports it is empty, fed well-formed replies for another identifier: the deadline, cancellation, ping's sends and a stream's retry still happen, and valid replies among them are recorded; a backlog longer than one read callback is read to the end; the socket is closed when the operation returns | trace, traceStream, ping | `ReceiveLoop` |
| The fixtures themselves | stall gate release rules; the watchdog; zero-byte UDP; a probe socket connected to its fake network receiving only the network's datagrams, against an unconnected control; trace, stream and ping probe sockets connected through the send seam; a fake network answering only the sockets it made, bound by their first send or later; every UDP responder and counter (the shared responder, the scripted DNS peer, the held STUN server, the refusing-then-answering port, the UDP probe server and sink) answering or counting its request after a short and an empty stray queued ahead of it; the DNS query filter; refusing TCP port reserved; TCP `stop()` returns without waiting for its handlers and `stopAndWait()` joins them; a stopped UDP fixture's thread closes its own socket | fixtures | `Fixture` |

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
- **Which of two simultaneous events of a reverse lookup wins.** The fake daemon forces each
  order of a reply against a cancellation and against the wake-up by holding the lookup's queue,
  and decides itself when the deadline has passed, but a cancellation and the wake-up both
  arrive off that queue, and no fixture can make them arrive at the same instant; the lock
  decides, and the racing loops and the real-daemon stress loop check only that one outcome and
  one deallocate follow.
- **A bound on the reverse lookup's open descriptors.** The limiter bounds queries. The client
  library closes each daemon connection in a dispatch cancel handler that runs on the lookup's
  queue just after the deallocate, while the permit is handed on as the deallocate returns, so
  open connections can exceed the cap by the lookups whose cancel handler has not yet run, and
  nothing bounds how many those are: it depends on scheduling. The default test checks that
  every connection is closed once its lookup is done, and prints the peak (measured: at most one
  over the cap at caps of 1, 4 and 16, on a development Mac and on CI). The tight-limit
  experiment, which can fail on a valid ordering, runs only with
  `SWIFTFTR_RDNS_DESCRIPTOR_STRESS=1`. Nothing in the API lets the lookup wait for the close.
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
6. **A failed public-IP discovery was paid twice.** Confirmed and fixed. When discovery failed or
   timed out, `traceClassified` passed `publicIP: nil` to the classifier, which ran discovery again
   with the same budget, so the bound was two budgets. The classifier no longer discovers
   (`classify` takes a required `publicIP`), and `traceClassified` asks once, after its probes.
   Test: `publicIPDiscoveredOnce`, two attempts before, one after; the classification helpers in
   `SwiftFTRClassificationTests` and `VPNClassificationTests` assert the classifier starts none.
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
9. **`getPublicIPs` ran blocking STUN on Swift's cooperative pool, and ignored cancellation.**
   Confirmed and fixed. It wrapped the STUN sweeps, which call `getaddrinfo` for each server and
   block in `recv`, in plain `Task`s. With one more stalled call than the pool has threads, an
   unrelated task ran only after the STUN server answered; cancelling the caller left the call
   waiting out every attempt (both measured against loopback fixtures before the fix). The sweeps
   are now child tasks, every lookup and attempt is its own executor request, and cancellation
   ends the call at once. Still open: the standalone call as a whole has no bound. Each attempt is
   bounded by `stunTimeout` (its executor deadline is twice that), but name lookups have no
   deadline, because the public signature has no budget to take one from. Tests:
   `AsyncPublicIPDiscoveryTests.standaloneCancellation` and `standaloneLeavesPoolFree`.

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
    ignored datagrams therefore cannot hold off the deadline or cancellation. Every DNS query takes
    this path, Team Cymru's TXT lookups included.
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
  foreign ID, by every DNS query, Team Cymru's TXT lookups included, and the query waits
  on to its deadline.
  The matcher and the validator read the first question by one rule, so they agree on which
  questions are unreadable (and so malformed): review of the first version found that its own
  reader let a compression pointer through, and the validator then read a pointer into the
  header as the root name and took the reply's REFUSED; and that it had no 255-byte limit, so a
  malformed reply was ignored as a different question. Tests: `DNSQuestionMatchTests`,
  `DNSQuestionVerdictTests`.

**A reverse lookup that ran out of time was cached as "no hostname" for a day.** Confirmed on
  0.18 and fixed. The lookup on the executor reported a deadline that passed, in a slot or
  waiting for one, as `nil`, and `RDNSCache` cached that as a negative answer for the full TTL
  (86400 s by default): with every slot held, a lookup of 127.0.0.1 timed out, and once the
  slots were free the next lookup still returned `nil` from the cache without asking. The cache
  now keeps only answers, and a lookup that waited for a permit past its deadline without asking
  (`timedOutBeforeQuery`) does not count toward the stall breaker either. Tests:
  `RDNSCacheTests.onlyAnswersAreCached`, `RDNSCacheTests.whatCountsAsAStall`.

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
  identifies a socket by the kernel's identity of it (`soi_so`, from `proc_pidfdinfo`), against a
  duplicate it holds, when checking that the library closed it. It used the bound local address
  until a socket of the other type, bound to the same address and port and handed the same
  descriptor number, made a closed TCP probe socket read as open (once in a full debug run;
  forced by placing such a UDP socket on the old number).
- A loopback fixture could take the port of an IPv6 probe socket and receive its replies. The
  fake network hands trace and ping an unbound UDP socket, which takes an ephemeral port on `[::]`
  at its first send. Fixtures bound `::1` on port 0 with `SO_REUSEADDR`, and with that option
  Darwin chooses an IPv6 ephemeral port by exact address only, so it could hand a fixture a port
  such a socket already held. Holding 2,000 implicitly bound sockets and binding 2,000 fixtures
  gave about 240 collisions over IPv6 and none over IPv4 or without the option. Every later
  datagram to that port went to the fixture, so a ping given a reply window past its watchdog
  waited it out: the IPv6 ping reply-matching tests failed at their 20 s watchdog in about one
  full debug suite run in fifteen. With another process churning such binds alongside, 4 of 60
  IPv6 runs of the control test hit the watchdog and none of 60 IPv4 runs, each with every probe
  seen and every reply sent. Fixtures no longer set the option. Another process that binds `::1`
  with it, such as a suite built before this change running at the same time, can still take
  the port. When a ping reply-matching test hits its watchdog it reports the fake network's
  journal of probes received and replies sent. Test:
  `FaultInjectionFixtureTests.loopbackFixtureKeepsOffWildcardPorts`.
- An IPv4 refusing UDP port could stop refusing. `RefusingUDPPort` binds `127.0.0.1` and connects
  the socket elsewhere, so the kernel answers other senders with port-unreachable. Darwin picks
  an IPv6 ephemeral port without checking IPv4 sockets, so a dual-stack socket bound to `[::]`
  could be handed the same number (about 260 of 2,000 such binds against 2,000 refusing ports),
  and IPv4 datagrams to the port then went to it: no refusal. `EventBasedDNSTests.refusedPort`
  waited out its watchdog, and `refusalBeforeTheSendIsIgnored`, whose
  `RefusingThenAnsweringUDPPort` refuses the same way, failed with `sendFailed`, each about once
  in fifteen full debug runs. Both fixtures now bind through `bindRefusingUDP(family:)`, which
  for IPv4 also holds a v6-only socket on `[::]` with the same number.
  Port-unreachable rate limiting is not the cause: Darwin suppresses only repeats for the same
  flow within 100 ms (`net.inet.udp.port_unreach_rlc_*`), and refusals kept arriving during a
  flood of 63,000 sends to other closed ports. Test:
  `FaultInjectionFixtureTests.refusingUDPPortKeepsOffDualStack`.
- A ping test's precondition could be met by the wrong datagram.
  `PingReplyMatchingTests.replyQueuedBeforeSendIsIgnored` took "a datagram is queued" as proof
  that its injected early reply had landed before probe 2 left, but probe 1's own reply, still
  unread, met that while the injected one was in flight on loopback. Landing after the send, the
  injected reply was rightly kept. The test now waits until every datagram the fake network sent
  to the socket is queued or read. `futureSequenceIsNotCounted` had the same check; its 50 ms
  send interval hides the race only while probe 1's send runs on time, and with probe 2's send
  forced right behind it the old check failed 100 of 100 runs. It now waits the same way.
- A client of a stopped `LoopbackTCPServer` saw a reset instead of end-of-file.
  `stop()` shuts each connection down for reading and writing. Darwin then discards data already
  queued and unread, but data arriving afterwards usually resets the connection (997 of 1,000
  runs; the rest saw end-of-file), so a request still in
  flight when the server stopped turned the end-of-file
  `FaultInjectionFixtureTests.tcpServerStopDoesNotWaitAndStopAndWaitJoins` checks into
  `ECONNRESET` (about 1 run in 100 under load). That test now sends no request to its silent
  handler and waits until the responding handler has read its own, and saw no reset in 1,000
  runs. `stop()` documents the rule, and `tcpServerStopDiscardsUnreadRequest` pins the
  end-of-file half; the reset is not certain enough to pin.
- Two fixture tests starved the cooperative pool when repeated. `loopbackFixtureKeepsOffWildcardPorts`
  and `refusingUDPPortKeepsOffDualStack` made about 4,000 socket calls each on a pool thread.
  Repeated 500 times with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`, they stalled the run in 7 to
  21 s steps, and the TCP stop test, starved past both of its 30 s budgets, saw its handler answer
  and exit before `stop()` (2 of 500 strict repetitions, twice). Both loops now run on a thread of
  their own (`onOwnThread`).
- A fake network's late reply could land in another test's fixture. Tests such as
  `lateRepliesIgnored` schedule replies for after the operation has closed its probe socket. The
  reply goes to that socket's port number, and a fixture bound in the meantime can have been
  handed the same number: `DNSWireHardeningTests.productionQueryRejectsInvalidHeaders` read a
  16-byte echo reply as its query, failed, and left the query to time out (once in 15 full debug
  runs; 5 of 5 with the ordering forced). `FakeICMPNetwork` now holds a duplicate of every socket
  it opens until it stops, so the port number stays taken while it can still send, and every
  loopback responder takes only the datagram its test asked for (see the stray crash below).
- **`--repeat-until fail` over several suites at once is not a valid gate: it slows loopback for
  the whole host.** It repeats every test on its own and in parallel, so the quick ones run flat
  out together. Run with the filter `DNSWireHardeningTests|FaultInjection|PingReplyMatching`, it
  raised the worst loopback round trip of an unrelated process (one datagram every 10 ms) from
  1 to 5 ms to 200 to 750 ms in every second it ran. With
  `loopbackFixtureKeepsOffWildcardPorts` and `refusingUDPPortKeepsOffDualStack` skipped (about
  8,000 socket, bind and close calls a repetition), the worst round trip was 60 to 290 ms; with
  only those two repeating, 10 to 64 ms; with any one suite repeating alone, 8 to 124 ms. A
  capture on `lo0` showed requests reaching a fixture's port 0.35 s and up to 0.7 s after they
  were sent, after their 0.3 s fixture had closed. The fixtures' own threads ran on time
  throughout: they started within 3 ms, read every 20 ms, and found nothing queued. So the
  climb in "dropped due to no socket" is these late requests, not a separate fault, and every
  test that needs a loopback answer, or a probe seen, within a sub-second budget failed at its
  first repetition: about 25 tests in six files, 40 to 50 issues in the first 2 to 3 seconds. A
  test that fails stops repeating, so the failures look like a short burst although the
  slowdown lasts the whole run. Main and the branch that holds `FakeICMPNetwork`'s duplicate
  sockets each failed 10 of 10 such runs; every suite repeated alone passed. The same load from
  another process is enough without repetition: plain runs of the filter failed 10 of 10 while
  a second process ran the repeated filter, and 1 of 10 while it ran plain full suites. A valid
  repetition gate loops whole runs, each a normal load, with nothing else running:
  `for i in $(seq 30); do SKIP_NETWORK_TESTS=1 PTR_SKIP_STUN=1 swift test -c debug --skip-build
  --filter '<suites>' || break; done` passed 30 of 30 on main and on the branch, and 15 of 15
  each under `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`. The tests themselves still assume a
  loopback answer within 0.3 to 0.5 s, a wall-clock bound in disguise that a loaded host breaks.
  The rule they now follow, file by file (#103): a call the fixture must answer gets a generous
  timeout that the answer ends; a count of what a fixture saw is awaited, not read when the call
  returns; a ping or trace whose result depends on which replies land inside a short window is
  restaged so that it does not. A call whose own timeout is the thing tested keeps it short.
  Measured by running `DNSWireHardeningTests|FaultInjection|PingReplyMatching|TCPProbeTests|
  AsyncPublicIP|UDPProbeBinding` as whole runs while a second process runs the repeated filter
  from a main worktree, and counting the issues in the files a change touched.
- **A `DNSWireHardeningTests` query timed out because its responder started late.** The fixture's
  responder starts from a `Task`, so it first needs a cooperative-pool thread. Repeated under
  `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`, 187 of 1,507 responders entered more than 0.1 s late
  (at most 0.59 s), each with its query already queued, and the two that entered after 0.5 s
  were the run's two `.timeout` failures of `productionQueryPreservesOwnerName` and
  `productionQueryRejectsInvalidHeaders`, whose queries had 0.5 s. Delaying the responder by
  0.6 s failed all four of their cases with that signature. The three queries the fixture must answer now
  take `answeredQueryTimeout` (10 s); the answer ends them, so a passing run waits no longer.
- **A short stray datagram crashed the test process through a fixture's script** (#169).
  `FaultInjectionWireTests.dnsFaults` built its replies with `dnsResponse(to:)`, which wrote
  bytes 2, 3, 6 and 7 of whatever datagram reached the responder, so a stray under 8 bytes (a
  silent STUN server's 4-byte garbage, an empty probe) trapped with "Index out of range" and
  ended every test in the process: 4 of about 70 repeated runs, while loopback was slow enough
  that late datagrams reached recycled ports. `DNSQuestionMatchTests.questionTypeOffset`, reached
  through `ScriptedDNSPeer` from `DNSQuestionVerdictTests`, trapped the same way. A 4-byte
  datagram sent to either fixture reproduced both traps on demand. Fixed by one rule for every
  loopback responder: a `DatagramFilter` names the one request it takes (a DNS query for the
  test's name, a STUN binding request, the test's own payload), and everything else, empty
  datagrams included, is counted as ignored and never answered, counted as a request or handed
  to a script. `LoopbackUDPResponder`, `ScriptedDNSPeer`, `HeldUDPServer`,
  `RefusingThenAnsweringUDPPort`, the UDP probe tests' `LoopbackUDPServer` and `DatagramSink`
  follow it, and the shared DNS readers check lengths rather than index past a short datagram.
  Each has a test that queues a short and an empty stray ahead of its request (confirmed with
  `SO_NUMRCVPKT`, the fixture's first read held behind a gate) and fails when the filter is
  bypassed. `ScriptedDNSPeer`'s feed, which kept sending to the client's port after the query
  ended, now stops, under its send lock, before the query's socket closes (through the
  transport's close seam), and the peer holds a duplicate of that socket until it stops.
- **Strays that remain possible.** None can reach a probe socket: each is connected to its fake
  network, and a connected datagram socket receives only from its peer (a short and an empty
  stray from another socket: `SO_NUMRCVPKT` 1, the network's reply alone, against 3 unconnected),
  and the fake network answers only sockets it made, so another test's late request is neither
  counted nor scripted. Tests that count what is queued on a probe socket can therefore count
  exactly. Strays can still reach the unconnected sides: a fixture's port, and a test-side
  client socket. A fixture that holds a port releases it once it stops sending, but a datagram
  it sent just before can still be in flight on a loaded host (round trips of 200 to 750 ms were
  measured) and land on the next socket handed that number; `FakeICMPNetwork`'s replies and
  `EndlessReplies`' feed, at 500 a second, are the largest sources. `HeldUDPServer` answers its held clients with a 4-byte datagram when released, which
  reaches a client only while its STUN attempt is still blocked in `recv`: every test that
  releases one with attempts outstanding gives them a 60 s receive timeout, and the one whose
  attempts have 0.2 s asserts that none reached the server. Receivers no longer act on such
  datagrams, and a DNS filter given no name still takes another test's late query: the tests
  that assert an exact request count name their query.
- **The wire tests waited on loopback inside sub-second budgets** (#103). Under that load
  `FaultInjectionWireTests` recorded issues in 9 of 10 runs on main (93 issues), 3 of 10 with
  `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`: DNS error replies, the open TCP port and the refusing
  UDP port arrived after their 0.3 to 1 s timeouts and were reported as timeouts, and request
  and connection counts were read before the fixture's thread had counted. Every call the
  fixture answers now has a 10 s timeout its answer ends; an HTTP fault the server itself ends
  (refusal, reset, close) has a timeout past the watchdog, so a probe that missed it trips the
  watchdog; counts are awaited. A silent DNS or STUN server keeps 0.3 s. An HTTP server that
  accepts and stays silent, or answers after the watchdog, keeps a timeout the test is about, and
  that timeout starts before URLSession has connected: at 0.5 s the server had not accepted when
  the probe gave up in 3 of 20 loaded runs (6 cases), so it is 3 s, which still depends on connecting
  within it; a hook at the accept would remove that. The compression-loop reply is now required
  to be `malformedResponse`, not any `DNSError`.
- **Ping reply-matching tests needed replies inside a 0.5 s window** (#103). Under that load
  ping's tests recorded issues in 9 of 10 runs on main (116 issues), 3 of 10 strict:
  `unsentSequencesCannotEndPingEarly`, `futureSequenceIsNotCounted`,
  `failedSendStillWaitsForUnansweredProbe` and `lateReplyWithinPingIsCounted` counted fewer
  replies than were sent, because the
  replies crossed loopback after the last probe's window had closed, and
  `failedSendEndsWhenSendLoopFinishes` found probe 1's reply still unread at probe 2's send. Ping
  arms its last window at the last send's time and drops what it has not read when the window
  closes, so a reply's crossing has to finish before then. The first, third and fourth now hold probe 3's
  send, on the ping's queue, until the network has sent the earlier replies and they are queued
  (`DirectPing.waitUntilReplied`); the send time is taken after the hold, so the queued replies
  are read inside the window; the count is exact, since the probe socket hears only its
  network. A held test's "not early" bound is measured on ping's clock from probe 3's own send to
  ping's close, both stamped on ping's queue, never from the start of a run that contains the
  hold. In the late-reply test probe 3 is no longer answered, so the ping reads
  probe 1's late reply after its own probe's timeout and before its own end. The second leaves
  probe 2 unanswered, holds its send until probe 1's reply and the early one are queued, and
  checks that the reply queued before probe 2's send does not give it an RTT, so no genuine reply
  can mask a false match. `failedSendEndsWhenSendLoopFinishes` cannot be held that way: the
  send loop enqueues each send and sleeps on its own, so a hook cannot keep probe 2 back until a
  reply is read. Its reply is now injected (one loopback crossing, not two) and its interval is
  2 s, which still has to outlast delivery; a seam on the send loop's sleep would remove that.
- **The receive-loop tests waited on loopback and inferred what the operation did** (#103). Under
  that load `traceDeadline` and `streamDeadline` failed with "sent 0 -> 0": `EndlessReplies` started
  its feed only when the fake network saw the first probe, which crossed loopback after the 0.3 s
  window had closed (the strict "294 sent, 4 read" failures were the same start, just before it
  closed). The feed now starts as the probe socket is made, with an exact batch of echo replies for
  sequence 0, which no operation sends, and the socket is handed over only once the batch is queued
  whole. Nothing is inferred from the fixture's side: the operation's first read is the batch
  shrinking, and its every read passes through `TestSeams.observeProbeReceive` (the three
  probe-socket reads in the library), so `heldReading` asks for a read past the batch and no empty
  read, counted on the operation's own queue. Sent minus queued had taken replies in flight for
  reads, and the sender's pace had hidden a read that came back empty. Bounds are measured from the
  handover: "not early" from it, and each upper bound from it too, with the factory's priming under
  its own allowance, so pingDeadline still tells its reply window from its 5.8 s safety timer.
  `unreachableReported` ends on a destination reply instead of needing three replies within 0.3 s,
  and two probe counts are awaited. Under that load these files recorded issues in 9 of 10 runs on
  main (20 issues), 2 of 10 strict.
- **Two fixture and probe tests assumed a quiet host** (#103). `ProbeTests.testClosedPort` probed
  port 9999 on the assumption that nothing listens there and required the reset within 100 ms, a
  wall-clock upper bound that failed even unloaded (rtt 0.155 s in a release run; 5 of 60
  unloaded runs of the broad filter, and 6 of 10 loaded). It now probes a `RefusingTCPPort`
  reserved for the test, with a timeout past its watchdog, so only the reset can end it, and
  checks the round trip against the elapsed time instead of a constant.
  `FaultInjectionFixtureTests.udpZeroByteRequest` read the responder's answer with a blocking
  `recv` and a 1 s timeout in the async test body; the read now runs on a thread of its own with
  a 10 s timeout the answer ends, and reads past any other datagram on its client's port.
- **`AsyncPublicIPDiscoveryTests.stalledAttemptsBoundedByBudget` once found the fallback never
  asked.** It failed once in about 500 strict repetitions of its suite with the whoami responder
  asked 0 times, so not a stray (which would count one or more). 229 instrumented strict
  repetitions did not repeat it: the fallback always started 4.000 to 4.012 s into discovery and
  discovery ended at 8.001 to 8.014 s. Not reproduced; the mechanism is not known. The fallback is
  gone (#153, below), so the test now checks only that the budget ends a stalled STUN attempt and
  nothing goes on to the next server; its failure timeline went with the fallback.
- **The library's public-IP fallback reported an address that was not the caller's** (#153).
  Confirmed by measurement and fixed by deletion. IPv4 discovery, when STUN failed, asked
  `1.1.1.1` and `8.8.8.8` for `whoami.ds.akahelp.net` TXT, whose `ip` record is built from the
  client-subnet hint the resolver forwards: on one network another host in the right /24 through
  one resolver, another /24 through the other, on each of four tries. The resolver is STUN only
  (decision 16). Test: `nothingAfterSTUNFails` (both STUN servers refusing, bound request) counts
  no DNS send through the transport's send seam; one with a query added back after STUN fails.
- **Public-IP discovery sent traffic its binding did not cover** (#151). Confirmed by code reading
  and fixed. The whoami fallback was never bound, and the STUN sweep resolved its server names
  before binding each socket, so a failed bind still sent the lookups; now every socket is bound
  first and a failed bind sends nothing. Tests: `everySocketBoundBeforeSend` reads `IP_BOUND_IF`
  or `IPV6_BOUND_IF` at each send (0 with the sweep unbound); `failedBindSendsNothing` counts no
  lookup through `TestSeams.resolveSTUNServer` (two with lookups before the bind). The lookups use
  the system resolver, which is not bound to the interface.
- **`getPublicIPs` ran a family unbound when given a source address of the other one**, and both
  for a value that is not an address. Confirmed by code reading and fixed. Test:
  `standaloneSourceSelectsFamily` (fails with the old split restored).
- **`multipathHonoursPublicIPBudget` could not tell its configured budget from the default**
  (#103), its watchdog being the default budget. It now checks the deadline the question carries
  is within the configured 2 s (6 s with the default substituted), under a 20 s watchdog.
