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

- **Seams, not mocks of the whole tracer.** `Sources/SwiftFTR/TestSeams.swift` holds five
  task-local overrides, all `nil` in production: the blocking-I/O executor, forward resolution,
  the ICMP socket factory used by trace and ping, IPv4 public-address discovery, and the `fcntl`
  that makes a trace or ping socket non-blocking. Task-locals
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
  ephemeral port. No new test sends a packet off the host. They land with the first slice, tested
  on their own; the protocol tests that use them come with the next.
- **Private executors.** Any test that stalls a blocking call does it on a private
  `BlockingIOExecutor`, installed through the seam, never on the process-wide one.
- **Discrimination.** Each test states the failure it catches. Where practical it was shown to fail
  against a deliberately broken build (a negative control) before being kept; the PR body lists
  which.

## Conditions covered

The battery lands in two pull requests. The first lands the seams, the fixtures and the tests of
the probe window, and changes no library behavior. The second lands the remaining tests together
with the library fixes they motivated. Until the second lands, the `--filter FaultInjection` gate
below runs only the first slice's tests, so a green gate means exactly the "Landed" rows.

### Landed

| Phase | Conditions | Operations | Tests |
|---|---|---|---|
| Forward resolution | fails (the injected error is checked, so a call that went around the seam fails) | trace, traceClassified, traceStream, ping | `FaultInjectionProbeWindowTests` |
| Probe socket | creation fails the way `socket(2)` does (`-1` with `errno`); every send fails with a non-transient errno | trace, traceClassified, traceStream, ping | `FaultInjectionProbeWindowTests` |
| Probe window | no replies; replies after the deadline; truncated, garbage and seeded-random ICMPv4/ICMPv6 queued ahead of valid replies; replies for another identifier; unreachable; a silent stream that must wait out its window and send its retries | trace, traceStream, ping | `FaultInjectionProbeWindowTests` |
| Non-blocking switch | either `fcntl` call that sets `O_NONBLOCK` fails | trace, traceClassified, traceStream, ping | `FaultInjectionReceiveLoopTests` |
| Receive loop | a socket that never reports it is empty, fed well-formed replies for another identifier: the deadline, cancellation, ping's sends and a stream's retry still happen, and valid replies among them are recorded; a backlog longer than one read callback is read to the end; the socket is closed when the operation returns | trace, traceStream, ping | `FaultInjectionReceiveLoopTests` |
| The fixtures themselves | stall gate release rules; the watchdog; zero-byte UDP requests; a refusing TCP port that stays reserved; TCP server teardown that joins its handlers | fixtures | `FaultInjectionFixtureTests` |

Every timed operation in these tests runs under a watchdog (`measure(within:)`), so an operation
that never returns fails its test instead of hanging the run.

### Planned for the next slice

| Phase | Conditions | Operations |
|---|---|---|
| Forward resolution | stalls (a disabled test; see #84) | trace |
| Public-IP discovery | stalls past its budget; fails; result arriving after a network change | traceClassified, discoverPaths |
| STUN wire | silent, garbage, wrong transaction, slow server; sub-microsecond timeout | stunGetPublicIP |
| Reverse DNS | stalls past its deadline; the stall breaker; cancellation during the wave | trace |
| ASN | resolver that stalls and ignores its timeout | traceClassified, discoverPaths |
| DNS wire | silence, slow, NXDOMAIN, SERVFAIL, garbage, oversized, compression loop, overstated answer count | the `__dnsQuery` SPI |
| Full executor | every blocking-I/O slot held while discovery, reverse DNS and DNS queue | traceClassified, dnsProbe |
| TCP / UDP / HTTP | refused, accept-then-silence, reset mid-response, close without response, slow first byte, 503, cancellation | tcpProbe, udpProbe, httpProbe |
| Cancellation | task cancellation, `networkChanged()` and `cancelActiveTraces()` across each operation and in each stalled phase | trace, traceClassified, traceStream, ping, discoverPaths |
| Concurrency | many simultaneous operations on one tracer and across tracers under faults | trace, traceClassified |

## Out of scope

- An overall deadline on `traceClassified` with an error naming the phase, and an executor-pressure
  reading (#84). Both are API additions for a minor release.
- Moving forward resolution off the actor. It needs a resolution budget, which is a new
  configuration field. The test that shows the defect comes with the next slice, disabled.
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

This slice changes no library behavior. The defects the full battery found, and their fixes, are
recorded here by the next slice, which lands them together.

### Receive loop bounds

- **An endless supply of irrelevant replies held trace, stream and ping past their deadlines.**
  Each receive loop read until its socket was empty, on the serial queue that also delivers its
  deadline timer, its cancellation, ping's sends and a stream's retry timer. Reproduced on the
  unfixed code with real non-blocking sockets: a loopback flood of echo replies for another
  identifier held the trace, the stream and the ping past a 10 s watchdog with a 0.3 s window,
  held trace and stream cancellation the same way, and kept a stream's retry and ping's second
  and third probes from being sent. Ping cancellation was already prompt, because ping's loop
  re-checked its state on every read. Fixed by reading at most 64 datagrams per callback and
  checking for cancellation and the deadline before every read. For the trace either half alone
  keeps the deadline and cancellation; ping's sends and the stream's retry need the bound.
- **A trace ran on a blocking socket when `fcntl` failed.** With the result ignored, a failed
  `F_SETFL` left the socket blocking, and every trace path, and ping once its own check was
  removed, waited in its last read past the watchdog. The trace paths now throw
  `socketCreateFailed`, as ping did.
- **The trace paths closed their descriptor while the cancelled read source could still hold
  it.** Not observable from a test; the descriptor is now closed from the source's cancellation
  handler, before the call returns, as in ping and the TCP and UDP probes.
- **How the condition is staged.** A loopback flood cannot hold a receive loop reliably. Loopback
  delivers at about the rate a loop drains, so a flood paced to stay ahead held the unfixed loop in
  most runs but let it find the socket empty within seconds in the rest; a flood sent flat out
  overflows loopback's input queue (`net.link.generic.system.rcvq_maxlen`, 256) and drops
  datagrams for every socket on the host, which failed unrelated tests running in parallel. An
  IPv6 loopback flood kept the socket readable only about three quarters of the time. The tests
  instead leave the socket blocking with a 1 s receive timeout, through the `fcntl` seam, and send
  one foreign reply every 2 ms, so every read gets a datagram. Each test was shown to fail with
  the part of the fix it covers removed.
- **`fstat` cannot tell sockets apart on Darwin.** It reports inode 0 for every socket, so the
  battery identifies a socket by its bound local address when checking that the library closed it.
