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
  ephemeral port. No new test sends a packet off the host.
- **Private executors.** Any test that stalls a blocking call does it on a private
  `BlockingIOExecutor`, installed through the seam, never on the process-wide one.
- **Discrimination.** Each test states the failure it catches. Where practical it was shown to fail
  against a deliberately broken build (a negative control) before being kept; the PR body lists
  which.

## Conditions covered

| Phase | Conditions | Operations |
|---|---|---|
| Forward resolution | fails; stalls (synchronous, see Findings) | trace, traceClassified, traceStream, ping |
| Probe socket | creation fails; reads report EOF continuously | trace, traceStream, ping |
| Probe window | no replies; replies after the deadline; truncated and garbage ICMPv4/ICMPv6; replies for another identifier; mixed valid and invalid in one burst | trace, traceStream, traceClassified |
| Public-IP discovery | stalls past its budget; fails; network change while in flight | traceClassified, discoverPaths |
| STUN wire | silent, garbage, slow server; sub-microsecond timeout | stunGetPublicIP |
| Reverse DNS | stalls; handle cancellation during the lookup wave | trace, traceClassified |
| ASN | `.remote` database download that stalls | LocalASNResolver |
| DNS wire | silence, NXDOMAIN, SERVFAIL, garbage, oversized datagram, compression loop | dnsProbe, dns queries |
| TCP / UDP / HTTP | refused, accept-then-silence, reset mid-response, slow first byte, timeout | tcpProbe, udpProbe, httpProbe |
| Cancellation | task cancellation and `networkChanged()` / `cancelActiveTraces()` at varying points | trace, traceClassified, traceStream, ping, discoverPaths |
| Concurrency | many simultaneous traces on one tracer and across tracers with faults injected | trace, traceClassified |

## Out of scope

- An overall deadline on `traceClassified` with an error naming the phase, and an executor-pressure
  reading (#84). Both are API additions for a minor release.
- Moving forward resolution off the actor. It needs a resolution budget, which is a new
  configuration field. The test that shows the defect is checked in disabled, pointing at the
  finding below.
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

Defects the battery exposes are recorded here with their disposition as they are confirmed.
