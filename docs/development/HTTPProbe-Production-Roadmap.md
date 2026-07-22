# HTTP Probe Production Roadmap

## Status

PR #53 establishes that `NWConnection` can perform a bounded HTTPS header probe on one exact,
caller-selected interface while preserving the logical hostname for TLS SNI, certificate
validation, and the HTTP `Host` field. Its release-binary cost is acceptable.

Merging that spike records the experiment; it does not make the new transport part of the public
`HTTPProbe` contract. The current URLSession implementation remains the production path until the
gates below are complete.

## Product Boundary

The first production release should add exact-route diagnostics without trying to replace all of
URLSession:

- A probe without explicit route controls continues to use URLSession. This preserves current
  redirect, proxy, cache, and system-routing behavior.
- A probe with an exact interface, source address, or forced address family uses the
  Network.framework transport.
- Exact means exact. The caller supplies a BSD interface name obtained from OS metadata. SwiftFTR
  must not infer a role from `enN`, `utunN`, interface type, or numeric suffix.
- An explicitly routed probe must never silently retry on the system default or another interface.
  Route denial is a result, not permission to fall back.
- `requiredInterface` is a path constraint, not a universal VPN-bypass guarantee. A
  NetworkExtension, content filter, kill switch, proxy, or system policy may permit, intercept, or
  reject the connection.
- System trust and hostname verification remain enabled. A numeric endpoint never replaces the
  logical hostname used for SNI and trust evaluation.

Transport selection for the new request API is explicit:

| Route and endpoint controls | Transport | Result |
| --- | --- | --- |
| `.system`, automatic family, no source or numeric remote address | URLSession | Current system-routed behavior |
| `.system` with a forced family or numeric remote address | Network.framework | System-selected route with the requested endpoint constraint |
| `.system` with a source address | None | Invalid; a source address requires an exact interface |
| `.interface(named:)` with automatic or forced family | Network.framework | Exact interface, with optional matching source or remote address |
| Source/remote address conflicts with the requested family or interface | None | Invalid request |

The legacy API always keeps its existing URLSession implementation. Tests must cover every row so
an unsupported control cannot be ignored accidentally.

The initial Network.framework transport is a diagnostic HTTP/1.1 client, not a general-purpose web
client. HTTP/2, HTTP/3, cookies, authentication, cache integration, uploads, streaming downloads,
and connection pooling are outside its first production scope.

## Compatibility Contract

Before adding a second transport, freeze the behavior callers already receive from
`HTTPProbe.swift`:

- Only absolute `http` and `https` URLs are accepted.
- The probe sends `GET` and stops after the final response headers.
- Any final HTTP response, including 4xx and 5xx, proves HTTP reachability.
- `followRedirects` remains opt-in.
- One timeout covers the whole operation.
- Existing `HTTPProbeResult` fields, JSON keys, initializer call sites, static error strings, and
  stable error prefixes remain unchanged during the transition. OS-localized suffixes remain
  system-defined and are not byte-stable across OS releases or locales.
- Existing cancellation behavior remains stable: the legacy API returns a failed result whose
  error is `"Cancelled"` instead of throwing `CancellationError`.

Do not grow the existing Codable result and public initializer into the new diagnostic model. Add
an enduring request/report API without `V2`, `Advanced`, `Spike`, or `InterfaceBound` in its names:

```swift
public func httpProbe(_ request: HTTPProbeRequest) async throws -> HTTPProbeReport
```

`HTTPProbeRequest` should use a typed `URL`, one operation timeout, an explicit redirect policy, a
stable configurable User-Agent, `PreferredFamily`, an `HTTPProbeRoute` such as `.system` or
`.interface(named:)`, an optional source address, and an explicit maximum response-body size. An
optional numeric remote address may be useful for diagnostics, but it changes only the connection
endpoint; the URL hostname remains authoritative for SNI, certificate validation, and `Host`.

`HTTPProbeReport` should contain one tagged outcome—response or failure—plus timing, connection,
and path-evidence values.
Use duration names such as `nameResolutionDuration`, `connectionDuration`,
`secureConnectionDuration`, `timeToFirstByte`, and `totalDuration` rather than extending the
legacy RTT terminology. A Codable failure value should carry a stable kind, terminal stage,
machine-readable code, and human-readable message. Define a thrown `HTTPProbeRequestError`
separately from the report-contained operational failure.

The new API may throw request-validation errors and native `CancellationError`; ordinary network
failures should return a report so timing and path evidence are retained. Existing
`HTTPProbeConfig`, `HTTPProbeResult`, both legacy functions, CLI JSON, and cancellation semantics
remain unchanged as compatibility adapters for at least one release. Deprecation, if useful, is a
later release decision; removal or renaming requires a major version.

An internal request plan should keep the URL hostname, resolved endpoint, request target, route
constraint, transport choice, and User-Agent policy separate. Legacy URLSession calls retain their
current system/default User-Agent behavior; the stable configurable User-Agent belongs to the new
request API. Public result types must not expose `NWPath`, `NWInterface`, `NWError`, `OSStatus`, or
Security-framework types.

Names must distinguish intent from evidence. In particular, a caller-supplied interface is the
*requested interface*, and a server-returned address is the *observed public address*. Neither
should be labeled as the other.

## Reviewable Implementation Sequence

### PR 1: Freeze Semantics and Add a Transport Seam

Introduce an internal transport protocol and normalized request/result model without changing
public behavior. Adapt the existing URLSession implementation to that seam and leave it selected
for every current call.

The request planner must:

- derive an origin-form, percent-encoded path and query from the URL without sending its fragment;
- generate the correct `Host` field, including non-default ports and brackets around IPv6 literals;
- keep the logical TLS hostname independent from a resolved IPv4 or IPv6 endpoint;
- reject unsupported schemes, URL user information, control characters, and header injection;
- carry an explicit User-Agent policy: preserve legacy URLSession behavior, while the new request
  API emits its stable configurable value; and
- define one monotonic operation deadline.

Acceptance gate:

- Existing HTTP probe tests pass unchanged.
- Golden tests cover URL normalization, `Host`, request target, User-Agent, IPv4/IPv6 endpoint
  separation, and invalid inputs.
- Transport-selection tests cover every valid and conflicting combination in the table above.
- The exported public symbol set and existing encoded result schema do not change.

### PR 2: Production Single-Hop HTTP/1.1 Transport

Turn the spike into a production-quality single-request state machine:

- use TCP for `http` and TCP plus TLS for `https`;
- set the URL hostname as the TLS server name and retain default certificate verification;
- establish and test a TLS policy, including an explicit minimum version appropriate for the
  product;
- keep trust injection test-only; the generic production probe has neither a permissive verifier
  nor built-in certificate pinning;
- offer HTTP/1.1 through ALPN, accept an omitted ALPN result as HTTP/1.1, and reject any actually
  negotiated unsupported protocol;
- consume a bounded number of interim 100, 102, and 103 responses until a final response arrives;
  treat 101 as a reachable final response, return its headers, and close without switching
  protocols;
- bound every header block and total parser storage;
- stop before buffering a response body; and
- treat `.waiting` as a deadline-bounded state that may recover, while recording the reason. It
  must not automatically become a different route.

Use exactly-once completion and deterministic cleanup for success, failure, timeout, and caller
cancellation. Measure intervals with `ContinuousClock`; reserve `Date` for the result timestamp.

Acceptance gate:

- Deterministic tests cover a successful injected operation, error propagation, already-cancelled
  entry, cancellation in each state, timeout/success races, and duplicate callbacks.
- Parser tests cover arbitrary fragmentation, coalesced body bytes, exact and exceeded bounds,
  EOF, malformed status lines, HTTP/1.0 and HTTP/1.1, each interim status, chained interim blocks,
  the maximum interim count, 101, and a final response.
- HTTP and HTTPS fixtures cover omitted and wrong ALPN, correct-host trust, wrong-host trust
  failure, and untrusted certificates.
- The focused concurrency/race suite passes under Thread Sanitizer.

### PR 3: Redirect, Bounded Body, and Result Parity

Implement the subset of URLSession semantics promised by `HTTPProbeConfig`:

- support relative and cross-origin redirects behind `followRedirects`;
- set a hop limit and detect loops;
- apply one end-to-end deadline rather than restarting the timeout per hop;
- rebuild endpoint selection, `Host`, SNI, and trust for every hop;
- reapply the same route constraint to every hop;
- choose and document an HTTPS-to-HTTP downgrade policy;
- preserve a numeric remote address across same-origin redirects; and
- reject cross-origin redirects when a numeric remote address is pinned until a per-origin
  endpoint policy exists. Never reuse one origin's address for another hostname or silently drop
  the pin.

Support optional response-body capture only behind an explicit byte limit; zero retains the
headers-only behavior. Parse `Content-Length`, chunked transfer coding, and connection-close
framing without exceeding the cap. Reject conflicting or unsupported transfer framing. Request
identity encoding initially and reject unsupported content encodings rather than accidentally
returning compressed bytes as decoded content. A body larger than its configured limit returns a
stable response-limit failure rather than a silently incomplete success.

Normalize transport failures into an internal outcome that can feed both public APIs. TLS failure
may prove that a peer was reachable, but it does not produce an HTTP status. DNS, route, and
connection failures remain unreachable. Cancellation and timeout must be stable and
distinguishable. The legacy adapter must continue producing its existing result fields and error
strings.

Acceptance gate:

- Local fixtures cover redirects disabled and enabled, relative and cross-host locations, loops,
  hop limits, downgrade handling, per-hop SNI/`Host`, and route retention.
- A checked-in, field-by-field parity table defines which legacy values must match and which may
  differ because of documented proxy, timing, cancellation, redirect, or error behavior. Fixture
  snapshots enforce that table for both transports.
- Body fixtures cover content length, chunking and bounded trailers, close framing, exact and
  exceeded limits, conflicting/malformed framing, and unsupported content encoding.
- Neither transport consumes an unbounded body, and redirect bodies are not buffered.

### PR 4: Exact-Route Core and Instrumentation

Implement the candidate request, route, report, and structured supporting types internally or as
SPI. Do not publish them before live route claims pass PR 5. Keep the legacy API on URLSession.

Route handling must:

- select one transport according to the table above and reject conflicting controls before any
  network work;
- resolve only the exact caller-supplied BSD name to an `NWInterface`;
- set `NWParameters.requiredInterface` and, when available, corroborate it with
  `currentPath.usesInterface` and the local endpoint/family;
- validate that a requested source address exists on that interface and matches the selected
  family before using a required local endpoint;
- support automatic, forced IPv4, and forced IPv6 selection without unbound pre-resolution; and
- fail explicitly if the requested route disappears or policy prevents its use.

Unconstrained system-routed requests retain URLSession's proxy behavior. System-routed
Network.framework requests preserve the system proxy policy. Exact-interface diagnostics set
`preferNoProxies`, then report whether Network.framework nevertheless configured or used a proxy
because that setting is a preference rather than a prohibition. A proxied result is not evidence
of direct server egress.

Collect structured diagnostics where the OS provides them:

- requested interface and source address;
- whether the connection path reports use of the requested interface, plus local endpoint, remote
  endpoint, and address family;
- path status and expensive/constrained/IPv4/IPv6 capabilities;
- DNS source, protocol, duration, preferred endpoint, and successful endpoint;
- whether a proxy was configured or used;
- connection attempts plus TCP and TLS handshake timing;
- negotiated ALPN, TLS version, and cipher suite;
- request-write-to-first-header-byte and total-to-final-header timing; and
- terminal phase plus stable error category and underlying OS domain/code.

`requiredInterface`, `NWConnection.currentPath`, TLS metadata, and
`NWConnection.EstablishmentReport` are constraint and local-path evidence. An echoed requested
name or `availableInterfaces` list is not proof of transmission, and path evidence does not replace
a controlled server's observed public address or packet capture when proving egress.
Logs must exclude URL query contents, request headers, cookies, credentials, certificate bodies,
and unbounded packet data. Treat local and public addresses as diagnostic data: retain raw values
only in the requested result or consented support artifact, and redact or aggregate them in product
telemetry.

Acceptance gate:

- Interface, source, and family validation is deterministic and fully parameterized.
- Missing, stale, or policy-denied interfaces fail without fallback.
- IPv4 and IPv6 fixtures verify the selected local and remote endpoints.
- Timing fields have documented start/end events and do not mislabel total establishment time as
  TCP handshake time.
- Candidate declarations follow Swift naming and documentation conventions and receive API review.
- The exported public symbol set remains unchanged.
- Internal request errors are separate from report-contained operational failures; ordinary
  network failures preserve their diagnostic report.

### PR 5: Live Acceptance

Use a controlled dual-stack echo endpoint, such as `check.networkweather.com/reflect`, to return
the server-observed remote address. Associate each attempt with a locally generated probe
identifier; the endpoint may later echo that opaque identifier if cross-system correlation is
needed. Keep response-body parsing strictly bounded and endpoint-agnostic in the transport;
interpret the controlled JSON in a separate adapter.

The release harness needs a versioned response schema, endpoint-health preflight, and an
independently operated fallback endpoint or region. Server-side correlation records must separate
reflector failure from client failure. Define access, redaction, and retention rules for result,
route, DNS, and packet-capture artifacts before collecting them.

Run the live matrix with interface names discovered fresh from OS metadata:

| Network state | Requested route | IPv4 outcome | IPv6 outcome |
| --- | --- | --- | --- |
| Clean direct dual stack | System default | Direct exit | Direct exit |
| Clean direct dual stack | Exact physical | Same direct exit | Same direct exit |
| Bypass-permitting dual-stack VPN | System default / exact VPN | VPN exit | VPN exit |
| Bypass-permitting dual-stack VPN | Exact physical | Direct exit | Direct exit |
| IPv4 VPN with default IPv6 suppressed | System default / exact VPN | VPN exit | Typed route-unavailable failure |
| IPv4 VPN with default IPv6 suppressed | Exact physical | Direct exit | Direct exit |
| Kill switch or `includeAllNetworks` | Exact physical | Typed policy denial | Typed policy denial |
| VPN disconnect/reconnect | Stale interface or source | Typed route-unavailable failure | Typed route-unavailable failure |

Also exercise clean IPv4-only, clean IPv6-only, DNS64/NAT64, split-tunnel inside/outside targets,
temporary IPv6 source addresses, interface or address loss during a request, plain HTTP, HTTPS,
configured proxy/PAC, proxy authentication, and proxy denial. Each profile must declare its exact
success, observed-exit, or typed-failure expectation before the run; post-hoc "policy-consistent"
classification is not an acceptance criterion.

For each cell, retain:

- timestamped OS interface and route metadata;
- the exact probe configuration and structured result;
- IPv4 and IPv6 STUN controls;
- DNS A and AAAA checks over IPv4 and IPv6 transports; and
- simultaneous, destination-filtered capture on the selected physical and tunnel interfaces when
  local path proof is required.

The HTTPS request's own hostname resolution needs separate proof. Use a unique per-attempt hostname
under a controlled authoritative zone and correlate authoritative query records and capture with
the probe identifier. Numeric endpoints and standalone A/AAAA controls are useful comparisons, but
they do not prove how a logical-host request was resolved.

No test or harness may hardcode an `enN` or `utunN` role. A manual rehearsal configured for an
exact interface or family must fail its preflight when that case is unavailable; it must not print
"Skipping" and report the run as fully exercised.

Acceptance gate:

- Correct SNI succeeds and a wrong logical hostname fails trust validation.
- The clean direct exact-physical IPv4 and IPv6 cells succeed with zero skipped cases and match the
  controlled direct exits.
- Default, exact-physical, exact-VPN, forced-IPv4, forced-IPv6, source-address, proxy, and
  policy-denial profiles satisfy their predeclared outcomes with no silent route fallback.
- Redirect hops retain the requested route.
- Unique-hostname evidence confirms the probe's own logical-host resolution behavior.
- Reflector health and fallback preflight succeeds before client failures count against the probe.
- At least 1,000 deterministic lifecycle races produce zero duplicate or missing completions; local
  fixture stress returns tasks, continuations, connections, and descriptors to its recorded
  baseline and an Instruments run reports no definite leaks. Thread Sanitizer remains a separate
  race-detection gate, not leak proof.
- Self-hosted live runs store structured artifacts; deterministic CI remains network-independent.
- Documentation states what is requested, path-reported, and server-observed, and preserves the
  caveat that NetworkExtension policy can override or deny the attempt.

PR 5 does not publish the candidate API, and no release may expose it between PR 4 and this gate.

### PR 6: Public API and Controlled Rollout

After live acceptance, publish `HTTPProbeRequest`, `HTTPProbeRoute`, `HTTPProbeReport`, and their
supporting values. Keep the legacy config, result, functions, initializer, Codable schema, CLI JSON,
error semantics, and cancellation behavior unchanged as adapters for at least one release.

Before publication:

- give every public value an explicit initializer and complete documentation, with defaulted
  parameters trailing;
- define all duration units as seconds, nil-versus-zero meaning, and timing aggregation across
  redirects;
- encode `HTTPProbeReport` manually with a top-level schema version, explicit coding keys, stable
  wire tags, `decodeIfPresent` for future optional fields, and a documented unknown-version policy;
- use an explicit discriminator so a report contains exactly one response or failure outcome;
- keep stable SwiftFTR failure codes separate from optional underlying OS domain/code diagnostics;
- use extensible raw-value identifier structs for failure kinds, stages, and other categories
  expected to grow, rather than public enums whose new cases break exhaustive switches; and
- snapshot the legacy schema using the CLI's fixed sorted-key encoder and fixed dates/numbers, while
  treating key/type/meaning—not arbitrary JSON byte order—as the compatibility contract.

Roll out behind an internal runtime flag: developer opt-in, employee diagnostics, then 1%, 5%, and
25% canaries split by IPv4, IPv6, and VPN state. Each canary stage runs for at least seven days and
records at least 1,000 eligible attempts per required cohort; cohorts that cannot reach the sample
require the complete manual matrix and a fourteen-day observation window. Assign a release owner
and record approval in the release issue before every increase.

The feature decision is captured at probe start. Turning the flag off does not reroute an in-flight
request. A disabled, stale, or unreachable control plane defaults the new exact-route API to a
typed feature-unavailable result; it never substitutes URLSession. Legacy system-routed calls
remain available. Keep URLSession for at least one release and retain a remote kill switch. Never
shadow normal user traffic without an explicit diagnostic or consented measurement because a
comparison doubles requests.

Immediately disable the transport for any trust regression, wrong-interface success, attributable
crash, hang, or definite leak. Also stop a stage when completion rate falls by more than one
percentage point, timeout rate rises by more than one percentage point, or p95 total duration is
more than 20% worse than its control for two consecutive daily windows.

## Continuous Gates

Every implementation PR must pass:

- `swift format lint --strict -r Sources Tests` with zero diagnostics, and
  `git diff --check`;
- debug and release builds;
- the full offline suite and focused deterministic HTTP suite;
- strict Swift concurrency checking with warnings treated as errors;
- targeted Thread Sanitizer runs with zero race reports, plus the separate lifecycle/leak gates
  defined above;
- DocC generation with warnings treated as errors;
- external-package integration;
- public-symbol/schema compatibility checks; and
- compilation and runtime smoke tests on the minimum supported macOS, plus the current pinned
  Xcode/Swift toolchain.

Record the exact commands and toolchain versions in each PR or release artifact; deployment-target
compilation alone does not prove Network.framework runtime behavior on the oldest OS.

Live tests should run separately on a self-hosted dual-stack Mac. The ordinary dual-stack suite is
a nightly or manual artifact-producing job. The VPN matrix is a pre-release gate with human review,
not a flaky dependency of every pull request.

## Production Definition of Done

The Network.framework HTTP transport is production-ready when all of the following are true:

- Existing unbound `HTTPProbe` behavior remains source- and result-compatible.
- Explicit route requests use only the exact requested interface/source/family or fail.
- HTTP and HTTPS, bounded response parsing, redirects, timeout, and cancellation meet their
  documented legacy and new-API contracts.
- TLS uses the logical hostname for SNI and system trust, with no permissive verification path.
- IPv4, IPv6, direct, VPN, stale-interface, and policy-denial cases pass the live matrix.
- Results distinguish requested route, path evidence, and server-observed egress.
- Timings and failure stages are stable, documented, and backed by deterministic tests.
- The implementation has a tested feature flag and kill switch; legacy/system probes retain their
  URLSession path, while a disabled exact-route request fails explicitly.
- Public API and DocC have completed review before route controls become generally available.

Promotion does not require HTTP/2, HTTP/3, a cookie jar, authentication challenges, arbitrary body
downloads, or URLSession replacement for system-routed probes. Those are separate product choices,
not hidden prerequisites for an exact-route diagnostic.
