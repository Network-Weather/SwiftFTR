# Field evidence from NWX production telemetry

Observed failures reported by the NWX macOS client fleet (`log.MeasurementManager`
events in the nwx-prod-edge `telemetry` log, week of 2026-08-23). NWX pins
SwiftFTR **0.14.0** (`46de63af`); `git diff 46de63af..HEAD -- Sources/SwiftFTR/`
touches only a docc file, so source references below describe current `main` as
well as what the fleet is running.

This file records **what production is telling us** and how to re-derive it.
The work items are in [ROADMAP.md](ROADMAP.md); the Bug 2 analysis is in
[docs/BUG2-INVESTIGATION.md](docs/BUG2-INVESTIGATION.md). Keep fixes and
hypotheses out of this file so it stays a durable record rather than a stale plan.

Refresh the evidence:

```bash
gcloud config configurations activate nwx
gcloud logging read 'logName="projects/nwx-prod-edge/logs/telemetry" AND jsonPayload.event="log.MeasurementManager"' --project=nwx-prod-edge --limit=200 --format=json
```

---

## Signal 1: `sendto` EAGAIN aborts the whole trace

**Volume (1 week):** ~80 `Traceroute failed | sendto failed (errno=35): Resource
temporarily unavailable` events across at least 4 distinct clients. The most
common traceroute failure in production.

**Mechanism — verified in source, not inferred:**

- The trace socket is set `O_NONBLOCK` (`Traceroute.swift:522-523`).
- All `maxHops` probes are sent in one unpaced burst (`Traceroute.swift:536-544`;
  same pattern near `Traceroute.swift:686`).
- `sendTraceProbe` throws `TracerouteError.sendFailed(errno:)` on any negative
  return (`Traceroute.swift:1249`), with no special-casing of transient errnos.

On a non-blocking datagram socket, `sendto` returns `EAGAIN`/`ENOBUFS` when the
socket or interface send buffer is momentarily full — which a back-to-back burst,
plus concurrent pings from the same host app, can cause. The caller loses the
entire topology measurement because one probe needed to wait a few milliseconds.

**Downstream errno contract (read from NWX source,
`MeasurementManager.swift:2777-2799`):** NWX maps `EHOSTUNREACH`, `ENETDOWN`, and
`ENETUNREACH` to offline states it acts on, and `EACCES` to a permissions
diagnostic. `errno=35` falls through to a generic error log carrying no
actionable state. `errno=50 ENETDOWN` also appears in the field data; it is
expected during interface transitions and its fail-fast behavior is correct.

## Signal 2: `traceClassified()` exceeding NWX's 60-second watchdog

**Volume (1 week):** 5 distinct clients logged the watchdog pair `Trace timeout:
traceClassified() did not complete within 60 seconds` followed by `This indicates
a hang in SwiftFTR library when called from NWX actor context` (~10 occurrences).

**The second sentence is a string someone wrote into a log call, not a finding.**
Investigation has since shown the probe path is not implicated: every exit path
of both receive operations resumes its continuation exactly once, and
cancellation during the probe phase terminates in ~0.105s with no leaked socket
or continuation. See [docs/BUG2-INVESTIGATION.md](docs/BUG2-INVESTIGATION.md) for
the audit, the measurements, and the ranked assessment.

**Where the caller sits:** NWX wraps `traceClassified(to:vpnContext:)` in a
60-second `withThrowingTaskGroup` watchdog
(`nwx/clients/macos/NWX/NWX/Managers/MeasurementManager.swift:2390-2423`) and
cancels the group when it fires.

**Known limits of this signal:**

- Telemetry cannot distinguish "never returned" from "returned after 60s" — NWX
  stops awaiting at the watchdog, so the tail beyond 60s is unobserved.
- NWX `log.*` telemetry carries no `app_version`, so it is not possible to tell
  whether the reporting clients predate NWX 1.3.0, which fixed a host-app SSDP
  receive loop that pinned a cooperative thread for up to 200s (nwx `f4bbeb40`).
  Adding that field is the cheapest way to close the question.
