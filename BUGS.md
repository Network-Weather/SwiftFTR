# Field evidence from downstream production telemetry

Observed failures reported by a downstream macOS client fleet (week of
2026-08-23). The fleet pins SwiftFTR **0.14.0** (`46de63af`); `git diff 46de63af..HEAD -- Sources/SwiftFTR/`
touches only a docc file, so source references below describe current `main` as
well as what the fleet is running.

This file records **what production is telling us** and how to re-derive it.
The work items are in [ROADMAP.md](ROADMAP.md); the Bug 2 analysis is in
[docs/BUG2-INVESTIGATION.md](docs/BUG2-INVESTIGATION.md). Keep fixes and
hypotheses out of this file so it stays a durable record rather than a stale plan.

Refreshing the evidence requires access to the downstream consumer's
telemetry; the queries are documented on their side.

---

## Signal 1: `sendto` EAGAIN aborts the whole trace

**Volume (1 week):** ~80 `Traceroute failed | sendto failed (errno=35): Resource
temporarily unavailable` events across at least 4 distinct clients. The most
common traceroute failure in production.

**Call shape — verified in source:**

- The trace socket is set `O_NONBLOCK` (`Traceroute.swift:522-523`).
- All `maxHops` probes are sent in one unpaced burst (`Traceroute.swift:536-544`;
  same pattern near `Traceroute.swift:686`).
- `sendTraceProbe` throws `TracerouteError.sendFailed(errno:)` on any negative
  return (`Traceroute.swift:1249`), with no special-casing of transient errnos.

So one failed probe costs the caller the entire topology measurement, even
though the other 39 probes in the burst succeeded. That part is not in doubt.

**Mechanism — not established. Earlier claim retracted.**

This file previously asserted that `sendto` returns `EAGAIN`/`ENOBUFS` "when the
socket or interface send buffer is momentarily full". The socket-buffer half is
**false** for this socket type, and the interface half produces a different
errno. See [docs/EAGAIN-MECHANISM.md](docs/EAGAIN-MECHANISM.md) for the
measurements:

- On `socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)` the send buffer never holds a
  byte — the datagram goes straight to `ip_output` on the calling thread. With
  `SO_SNDBUF` set to exactly one message length, 5000 back-to-back sends all
  succeed; one byte below, every send is `EMSGSIZE`. No `SO_SNDBUF` value
  produces `EAGAIN`.
- Interface pressure does reproduce, but reports **`ENOBUFS` (55)**, and only
  for a socket sustaining ~19k pkt/s of its own traffic. macOS's FQ-CoDel
  scheduler isolates flows per socket: 31 sockets flooding the same interface
  hard enough to take `ENOBUFS` left a concurrent 40-probe trace burst
  completely untouched.
- Roughly 3.8M sends across ten load shapes — including the exact burst
  SwiftFTR issues — produced **zero `EAGAIN`**.

What produces `errno=35` in the field is still unknown. Reading XNU leaves one
reachable path: a content-filter or socket-filter network extension attached to
the process's datagram sockets, whose pending bytes drive `sbspace()` to zero.
That is a hypothesis, untested — the investigating machine had no filter
installed. Adding `net.cfil.active_count` to the fleet's telemetry alongside the errno
would settle it.

**Downstream errno contract (verified in the consumer's source):** the
consumer maps `EHOSTUNREACH`, `ENETDOWN`, and
`ENETUNREACH` to offline states it acts on, and `EACCES` to a permissions
diagnostic. `errno=35` falls through to a generic error log carrying no
actionable state. `errno=50 ENETDOWN` also appears in the field data; it is
expected during interface transitions and its fail-fast behavior is correct.

## Signal 2: `traceClassified()` exceeding the caller's 60-second watchdog

**Volume (1 week):** 5 distinct clients logged the watchdog pair `Trace timeout:
traceClassified() did not complete within 60 seconds` followed by a second line
asserting a hang inside SwiftFTR (~10 occurrences).

**The second sentence is a string someone wrote into a log call, not a finding.**
Investigation has since shown the probe path is not implicated: every exit path
of both receive operations resumes its continuation exactly once, and
cancellation during the probe phase terminates in ~0.105s with no leaked socket
or continuation. See [docs/BUG2-INVESTIGATION.md](docs/BUG2-INVESTIGATION.md) for
the audit, the measurements, and the ranked assessment.

**Where the caller sits:** the consumer wraps `traceClassified(to:vpnContext:)`
in a 60-second `withThrowingTaskGroup` watchdog and cancels the group when it
fires.

**Known limits of this signal:**

- Telemetry cannot distinguish "never returned" from "returned after 60s" — the
  caller stops awaiting at the watchdog, so the tail beyond 60s is unobserved.
- The fleet's telemetry carries no `app_version`, so it is not possible to tell
  whether the reporting clients predate a host-app fix for an SSDP receive loop
  that pinned a cooperative thread for up to 200s. Adding that field is the
  cheapest way to close the question.
