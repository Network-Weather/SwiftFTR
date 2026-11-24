# SwiftFTR design and investigation documents

Design records, investigations and plans that sit behind the code. API guides are the DocC
articles indexed in the [root README](../README.md#documentation); contributor and release notes
are in [development/README.md](development/README.md).

## Current design records
- [Cache and network-transition lifecycle](CACHE-AND-TRANSITION-LIFECYCLE.md): what the `SwiftFTR` actor caches, what invalidates each cache class, and the network-transition controls callers get, with their shipped signatures and open decisions. (updated 2026-11-23; update when: a cache, invalidation rule or lifecycle control in `Traceroute.swift` or `RDNSCache.swift` changes)
- [IPv6 support](IPV6.md): architectural contracts for dual-stack behavior and the sequenced stages of IPv6 parity, with remaining hardening work, test gates and known-good v6 endpoints. (updated 2026-11-24; update when: a Stage 7 hardening item lands or a v6 contract changes)
- [Robustness testing: fault injection, phase by phase](ROBUSTNESS-TESTING.md): why and how the offline fault-injection battery simulates failing networks, the conditions and operations it covers, what is out of scope, the gate commands, and the defects it found. (updated 2026-11-24; update when: a seam, fixture or covered phase is added or removed, or a listed finding changes disposition)
- [Event-based I/O: no thread held while waiting, one deadline per operation](BLOCKING-IO.md): sequenced plan for making every public operation return within a configuration-derived time, by making DNS, STUN and reverse DNS event-based, moving forward resolution off the tracer actor and adding an overall deadline, with the gates each stage must pass, the review record and the decisions awaiting the owner. (updated 2026-11-24; update when: a stage lands or is reshaped, or one of the listed decisions is made)

## Investigations and plans
- [BUG 2 investigation](BUG2-INVESTIGATION.md): static audit and measurements of why `traceClassified()` could run past a 60-second watchdog in 0.14.0, including continuation exit paths, blocking-I/O executor behavior and resolver stall times. (updated 2026-11-22; update when: the remaining unbounded waits in #84 are fixed or re-measured)
- [Bounding and cancelling the enrichment phase](ENRICHMENT-BOUNDING.md): the plan behind cancellation-aware blocking I/O, caller-side deadlines and the reverse-DNS breaker, and the residual exposure it left. (updated 2026-11-22; update when: the blocking-I/O executor or reverse-DNS bounding is redesigned)
- [Per-hop outcome model](HOP-OUTCOME-MODEL.md): the design of `HopOutcome`, why timing and address stay outside the enum, and how unsent probes degrade a trace instead of failing it. (updated 2026-11-21; update when: `HopOutcome` gains a case or the hop types change shape)
- [EAGAIN on ICMP datagram sockets](EAGAIN-MECHANISM.md): kernel-source reading and load measurements of which errors `sendto` can return on an unprivileged ICMP socket, the content-filter hypothesis, and the send-retry budget. (updated 2026-11-22; update when: field telemetry or a content-filter test settles the EAGAIN cause, or the send-retry budget changes)
