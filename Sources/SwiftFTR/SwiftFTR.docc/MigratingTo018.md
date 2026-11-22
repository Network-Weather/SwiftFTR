# Migrating to SwiftFTR 0.18

Handle the cancellation, discovery-budget, DNS and trace socket-setup changes introduced in SwiftFTR 0.18, and adopt the structured DNS probe outcome.

## Overview

SwiftFTR 0.18 is source-compatible with 0.17: no public declaration is removed or changed. One is
added: ``DNSProbeOutcome``, with ``DNSProbeResult/outcome``, ``DNSProbeResult/elapsed`` and an
initializer that takes both; the initializer and JSON without them still work and derive them.
What changes is behavior an unmodified caller can observe. Each section below has the same shape,
so a person or a coding agent can work through a consumer one change at a time:

- **What changed**, in the library.
- **What a caller sees**, at the call site.
- **What to change**, with code before and after.

To find the call sites to review, search the consumer for `discoverPaths(`, `networkChanged(`,
`cancelActiveTraces(`, `TracerouteError.cancelled`, `.cancelled`, `publicIPDiscoveryTimeout`,
`DNSError`, `socketCreateFailed`, `dnsProbe(`, `rttMs` and the `rtt` and `error` of the DNS result
types.

## Update the package

```swift
dependencies: [
  .package(
    url: "https://github.com/Network-Weather/SwiftFTR.git",
    from: "0.18.0"
  )
]
```

## discoverPaths ends on a network change

**What changed.** `networkChanged()` and `cancelActiveTraces()` now end a `discoverPaths` call in
flight, as they already ended `trace`, `traceClassified` and `traceStream`. A topology or a flow
error that arrives after the invalidation began, but before `discoverPaths` returned, is discarded
too, so a call that returns a topology returned it before `networkChanged()` or
`cancelActiveTraces()` started.

**What a caller sees.** `discoverPaths` throws `TracerouteError.cancelled` where 0.17 returned a
topology measured on the old network. Cancelling the calling task now always throws
`CancellationError`, where 0.17 threw `TracerouteError.cancelled` if the cancellation landed during
a flow's probe receive window, so the two sources can be told apart; when both happened, the
tracer's `TracerouteError.cancelled` is reported.

**What to change.** Catch `TracerouteError.cancelled` wherever `discoverPaths` is called and treat
it as "this measurement was abandoned", not as a failure of the network being diagnosed. Do not
restart discovery from that handler: the same error follows `cancelActiveTraces()`, which a
consumer may call to stop. Start the replacement from the code that handles the network change,
where the reason is known.

Before:

```swift
do {
  let topology = try await tracer.discoverPaths(to: target, config: config)
  show(topology)
} catch is CancellationError {
  return
} catch {
  reportFailure(error)
}
```

After:

```swift
do {
  let topology = try await tracer.discoverPaths(to: target, config: config)
  show(topology)
} catch is CancellationError {
  return
} catch TracerouteError.cancelled {
  // networkChanged() or cancelActiveTraces() ended it; whoever called that decides what runs next.
  return
} catch {
  reportFailure(error)
}
```

In 0.17 a caller that cancelled its own `discoverPaths` task while a flow was waiting for probe
replies received `TracerouteError.cancelled`, which the "Before" code reported as a failure; at
other points it received `CancellationError`. With the "After" code both errors arrive in a
handler that returns.

Keep any check the consumer already makes before it displays or stores a result, such as
comparing a network generation counter of its own. The tracer orders its own return against
`networkChanged()`, but not the consumer's code that runs afterwards: a topology returned just
before the change can still reach `show(topology)` after the consumer has moved to the new network.

## A network change ends a trace waiting on reverse DNS

**What changed.** `networkChanged()` and `cancelActiveTraces()` now interrupt the reverse-DNS
lookups at the end of `trace()` and `traceClassified()`. In 0.17 a trace in that phase ended only
when its slowest lookup reached its deadline (5 s by default).

**What a caller sees.** The same `TracerouteError.cancelled` as before, but immediately rather than
up to the lookup deadline later.

**What to change.** Nothing is required. Remove any delay or extra timeout added around a trace
to cover the old wait after a network change, and make sure `TracerouteError.cancelled` is not
reported as a failure of the network.

Before:

```swift
await tracer.networkChanged()
// Wait out traces still finishing their reverse-DNS lookups.
try await Task.sleep(for: .seconds(5))
startTracing()
```

After:

```swift
await tracer.networkChanged()
startTracing()
```

## Cancelling your own ping or trace throws CancellationError

**What changed.** The two cancellation errors now mean one thing each. `CancellationError`: the
caller cancelled its own task. `TracerouteError.cancelled`: the tracer ended the operation, through
`networkChanged()` or `cancelActiveTraces()`; when both happened, this one is reported. `ping` threw
`TracerouteError.cancelled` for its own task's cancellation, and `trace` and `traceClassified`
threw it in most phases and `CancellationError` at some checkpoints between phases. `ping` is still not ended by
`networkChanged()` or `cancelActiveTraces()`, so it now only ever throws `CancellationError` for a
cancellation. `discoverPaths` follows the same rule: in 0.17 a caller's cancellation threw
`TracerouteError.cancelled` during a flow's probe receive window and `CancellationError` at the
task-cancellation checkpoints inside and between flows, and 0.18 always throws
`CancellationError`. A `traceStream` consumer that cancels its task
sees iteration end normally, as in 0.17, unless the tracer had already ended the stream; the
cancellation prompts the stream to stop probing and close its socket. A stream the tracer ends
before it finishes throws `TracerouteError.cancelled`, even after its last hop has been
delivered. Breaking out of a loop over a
stream held in a variable cancels nothing: the trace runs until it finishes or the stream is
released.

**What a caller sees.** A ping or trace that the consumer itself cancels, for example by
cancelling the task that runs it when a view goes away or a newer measurement replaces it, throws
`CancellationError`. A handler written as `catch TracerouteError.cancelled` no longer catches it,
so the error falls through to the consumer's general failure handling and can be shown or logged
as a network failure.

**What to change.** Catch both errors wherever a ping or trace can be cancelled, and handle each
for what it means: `CancellationError` as "I stopped this myself", `TracerouteError.cancelled` as
"the tracer abandoned this measurement". Neither is a failure of the network being diagnosed. Do
not retry from the `TracerouteError.cancelled` handler: start the replacement from the code that
handled the network change.

Before:

```swift
do {
  let result = try await tracer.ping(to: target, config: config)
  record(result)
} catch TracerouteError.cancelled {
  // Assumed to cover the consumer's own cancellation of this task.
  return
} catch {
  reportFailure(error)
}
```

After:

```swift
do {
  let result = try await tracer.ping(to: target, config: config)
  record(result)
} catch is CancellationError {
  // This task was cancelled by the consumer.
  return
} catch TracerouteError.cancelled {
  // networkChanged() or cancelActiveTraces() ended a trace; never thrown by ping.
  return
} catch {
  reportFailure(error)
}
```

The same change applies to `trace(to:)` and `traceClassified(to:)`. A consumer that only needs to
know that the operation did not run to completion can test for both in one place:

```swift
} catch {
  if error is CancellationError { return }
  if case TracerouteError.cancelled = error { return }
  reportFailure(error)
}
```

Keep any check the consumer already makes before it uses a result, such as comparing a
generation counter of its own: an operation that completed just before it was cancelled still
returns its result.

## discoverPaths honours publicIPDiscoveryTimeout

**What changed.** The flows `discoverPaths` runs now use the tracer's
`SwiftFTRConfig.publicIPDiscoveryTimeout`. In 0.17 they used the 6 s default whatever was
configured, while `traceClassified` honoured the setting.

**What a caller sees.** With a budget below 6 s, a `discoverPaths` call on a network where public-IP
discovery stalls returns sooner, and its topology may carry no public address where 0.17 found
one late.

**What to change.** Nothing, if the configured budget is what you want for multipath too. To keep
the 0.17 behavior for multipath only, give it a tracer with the default budget.

Before:

```swift
let tracer = SwiftFTR(config: SwiftFTRConfig(publicIPDiscoveryTimeout: 1))
let classified = try await tracer.traceClassified(to: target)
let topology = try await tracer.discoverPaths(to: target)  // used 6 s in 0.17
```

After:

```swift
let tracer = SwiftFTR(config: SwiftFTRConfig(publicIPDiscoveryTimeout: 1))
let multipathTracer = SwiftFTR(config: SwiftFTRConfig())  // the 6 s default
let classified = try await tracer.traceClassified(to: target)
let topology = try await multipathTracer.discoverPaths(to: target)
```

## Invalid DNS inputs are reported before any socket is opened

**What changed.** Every DNS query (`dnsProbe`, the `tracer.dns` queries, `reverseDNS`,
`reverseIPv6`, `queryA`, `queryAAAA`) checks its timeout, name, server address and the family of
its source address before it opens a socket. In 0.17 some of these checks ran only once one
of the shared blocking-I/O workers picked up the query, so behind busy workers the error could be
late. Which ones depended on the entry point: `dnsProbe` checked the timeout and name first, the
query functions checked less up front, and the server address and the source-address family
always waited for a worker.

**What a caller sees.** The same `DNSError` case as 0.17 (`invalidTimeout`, `invalidHostname`,
`invalidIP`, or `bindFailed` for a source address of the wrong family), at once. `dnsProbe` throws
`invalidTimeout` and `invalidHostname`, as before; it reports an invalid server or a wrong-family
source address in the returned result's `error`, as before, rather than throwing.

**What to change.** Nothing is required. A consumer that pairs a DNS server with a bound source
address can check the pairing up front; a `bindFailed` for a family mismatch means the pairing is
wrong, not that the network failed.

Before:

```swift
// Throws bindFailed whenever `server` is an IPv6 address.
let answers = try await queryA(hostname: name, server: server, sourceIP: wifiIPv4)
```

After:

```swift
let source = server.contains(":") ? wifiIPv6 : wifiIPv4
let answers = try await queryA(hostname: name, server: server, sourceIP: source)
```

## DNS round-trip times no longer include a wait for a worker

**What changed.** A DNS query is now one non-blocking UDP exchange that waits for its reply
without holding a thread, so it no longer runs on the blocking-I/O executor. Its round-trip time is
measured from sending the query to reading the reply. In 0.17 the time was measured from the call,
so it included any wait for one of the executor's eight workers, which stalled reverse-DNS lookups
during a trace can hold for seconds, and the socket setup. The fields are
`DNSQueryResult.rttMs` (milliseconds, from the `tracer.dns` queries), `DNSProbeResult.rtt`
(optional seconds, from `dnsProbe`), and the `rtt` in seconds of `ReverseDNSResult` (`reverseDNS`,
`reverseIPv6`), `AQueryResult` (`queryA`) and `AAAAQueryResult` (`queryAAAA`).

**What a caller sees.** Round-trip times that measure the network and the server only. While a
trace is resolving hostnames they are no longer inflated, and on an idle host they are slightly
smaller, by the socket setup that is no longer counted. A query also answers sooner under that
load, because it no longer waits for a worker at all.

**What to change.** Nothing is required. Remove any workaround for inflated values, such as
discarding DNS round-trip times measured while a trace was running. A consumer that wants the
duration of the whole call, as 0.17 reported it, measures the call itself.

Before:

```swift
let result = try await tracer.dns.a(hostname: "example.com")
// rttMs included queueing behind reverse DNS while a trace was running.
if !traceInFlight {
  record(dnsRTTMs: result.rttMs)
}
```

After:

```swift
let clock = ContinuousClock()
let start = clock.now
let result = try await tracer.dns.a(hostname: "example.com")
record(dnsRTTMs: result.rttMs)
// Only if the whole call is wanted, as 0.17 reported it in rttMs:
record(dnsCallDuration: clock.now - start)
```

## A refused DNS port is reported as a refusal

**What changed.** When the server's host answers a query with ICMP port unreachable, meaning the
host is up but nothing is listening on the DNS port, the query methods (`tracer.dns`,
`reverseDNS`, `reverseIPv6`, `queryA`, `queryAAAA`) throw `DNSError.sendFailed`, and `dnsProbe`
sets `error` to "Connection refused - the host is up but no DNS server is listening on this
port". 0.17 reported the refusal as `DNSError.timeout`, and `dnsProbe` said "Timeout - no
response", although the refusal arrived at once. `dnsProbe` still reports a refused port with
`isReachable == false`, `rtt == nil` and `responseCode == nil`: the probe answers "does DNS work
at this server", and it does not. A server that stays silent is still `DNSError.timeout`, and in
`dnsProbe` still "Timeout - no response".

**What a caller sees.** For a host with no DNS service on the port, the query methods throw
`sendFailed` where they threw `timeout`, and `dnsProbe` returns the same unreachable result as
0.17 with a different `error` message.

**What to change.** For `dnsProbe`, `isReachable` keeps its meaning. To tell a refusal from
silence, read ``DNSProbeResult/outcome``, not the `error` string, which is a message for people.
Replace any match on `error` text, and any code that treats every unreachable result alike, with a
`switch` over `outcome`. ``DNSProbeOutcome`` is a struct with static members, not an enum, so a
later release can add an outcome: match the members you handle and keep the `default` arm. A
refusal has no `rtt`; ``DNSProbeResult/elapsed`` is how long it took.

Before:

```swift
// 0.17 reported a refused port as "Timeout - no response", so a refusal and silence could not be
// told apart and every unreachable result was handled alike.
let result = try await dnsProbe(server: resolver)
if !result.isReachable {
  showDNSServerDown(resolver, reason: result.error)
}
```

After:

```swift
let result = try await dnsProbe(server: resolver)
switch result.outcome {
case .answered, .malformedReply:
  break  // isReachable is true
case .refused:
  showNoDNSServer(at: resolver)  // the host is up; result.elapsed is when it said so
case .timedOut:
  showDNSServerDown(resolver, reason: result.error)
default:
  // .unreachable, .failed, and any outcome a later release adds.
  showDNSServerDown(resolver, reason: result.error)
}
```

Where the query methods' errors are handled and the distinction matters, catch `sendFailed`
separately from `timeout`: it means the query was not delivered to a DNS server.

Before:

```swift
do {
  _ = try await tracer.dns.a(hostname: name, server: resolver)
} catch DNSError.timeout {
  reportNoAnswer(from: resolver)
}
```

After:

```swift
do {
  _ = try await tracer.dns.a(hostname: name, server: resolver)
} catch DNSError.timeout {
  reportNoAnswer(from: resolver)
} catch DNSError.sendFailed {
  // Refused (nothing listening on the port), or the query could not be sent.
  reportNotDelivered(to: resolver)
}
```

## A DNS datagram for another query is ignored

**What changed.** A DNS query takes as its reply only a datagram that carries its own
transaction ID. A datagram with another ID, or too short to carry one (an empty datagram
included), is ignored, and the query keeps waiting to the same timeout. 0.17 took the first
datagram whatever it was: a wrong ID threw `DNSError.malformedResponse`, and `dnsProbe` reported
the server reachable with "Malformed response"; an empty datagram threw `DNSError.timeout` at
once. A datagram with the right ID that is otherwise invalid (not a response, truncated, cut
short, unparseable) still ends the query at once as `malformedResponse`, and `dnsProbe` as
`outcome == .malformedReply`, `isReachable == true`.

**What a caller sees.** For a server, or a stale reply on a reused port, that sends only
datagrams for other queries: `DNSError.timeout` at the timeout where 0.17 threw
`malformedResponse` at once, and a `dnsProbe` result with `outcome == .timedOut`,
`isReachable == false` and "Timeout - no response", where 0.17 said reachable. A real reply that
follows such datagrams within the timeout is now returned. `malformedResponse` and
`malformedReply` now always mean the server answered this query, badly.

**What to change.** Nothing, unless the consumer treats `malformedResponse` or a reachable
`dnsProbe` result with no `responseCode` as proof that something is answering on the port. Such
datagrams now end as a timeout, which says nothing about the port. Report `malformedReply` as a
DNS server that answered badly, and a timeout as no answer to this query; to ask whether anything
at all sends back on the port, use ``udpProbe(host:port:timeout:payload:interface:sourceIP:)``.

Before:

```swift
let result = try await dnsProbe(server: resolver)
if result.isReachable && result.responseCode == nil {
  // 0.17: any datagram, a stray one included.
  showSomethingListening(on: resolver)
}
```

After:

```swift
let result = try await dnsProbe(server: resolver)
switch result.outcome {
case .malformedReply:
  // A datagram for this query that was not valid DNS.
  showDNSServerMisbehaving(resolver, reason: result.error)
case .timedOut:
  // Silence, or only datagrams for other queries.
  showNoAnswer(from: resolver)
default:
  handle(result)
}
```

The query methods, before:

```swift
do {
  _ = try await tracer.dns.a(hostname: name, server: resolver)
} catch DNSError.malformedResponse {
  showSomethingListening(on: resolver)
} catch DNSError.timeout {
  showNoAnswer(from: resolver)
}
```

After:

```swift
do {
  _ = try await tracer.dns.a(hostname: name, server: resolver)
} catch DNSError.malformedResponse {
  showDNSServerMisbehaving(resolver)
} catch DNSError.timeout {
  showNoAnswer(from: resolver)  // stray datagrams included
}
```

Before:

```swift
let result = try await dnsProbe(server: resolver)
if result.isReachable {
  showDNSServerUp(resolver)
} else {
  showDNSServerDown(resolver, reason: result.error)
}
```

After:

```swift
let result = try await dnsProbe(server: resolver)
switch result.outcome {
case .answered:
  showDNSServerUp(resolver)  // a DNS answer, NXDOMAIN and SERVFAIL included
case .malformedReply:
  showDNSServerMisbehaving(resolver, reason: result.error)
default:
  showDNSServerDown(resolver, reason: result.error)
}
```

## dnsProbe reports unreachable servers and receive errors as such

**What changed.** Three `dnsProbe` messages that hid what happened now say it:

- When the network reports the server's host or network unreachable after the query is sent
  (`EHOSTUNREACH` or `ENETUNREACH` on the socket), `outcome == .unreachable` and `error` says so
  with the errno, such as "Host unreachable - the network reported the server's host unreachable
  (errno=65: No route to host)". 0.17 said "Timeout - no response", although the report arrived
  before the timeout. ``DNSProbeResult/elapsed`` is when the report arrived.
- When this machine cannot send toward the server at all (`connect` or `send` fails with
  `EHOSTUNREACH`, `EHOSTDOWN`, `ENETUNREACH` or `ENETDOWN`), `outcome == .unreachable` and `error`
  is "Network unreachable - this machine has no route to the server (errno=51: Network is
  unreachable)" or a similar "Host unreachable - …"/"Network unreachable - …" message.
  ``DNSProbeResult/elapsed`` is `nil`, because nothing came back. 0.17 said "Failed to send query".
  Any other `connect` or `send` failure still starts "Failed to send query", now followed by the
  failing call and its errno where there is one, for example "Failed to send query - send failed
  (errno=1: Operation not permitted)".
- A socket error while waiting for the reply that is neither a refusal nor an unreachable report
  is `outcome == .failed` with "Receive failed - the socket reported an error while waiting for
  the reply (errno=…)". 0.17 said "Timeout - no response".

`isReachable` stays `false` and `rtt` stays `nil` in every case. The query methods are unchanged:
`DNSError.timeout` for the first and third, `DNSError.sendFailed` for the second.

**What a caller sees.** Different `error` messages for these cases, the first one sooner than the
timeout.

**What to change.** Nothing, unless the consumer matched "Timeout - no response" to detect silence
or "Failed to send query" to detect a local failure. Replace both with `outcome`; an exact match
on "Failed to send query" no longer matches when an errno follows it.

Before:

```swift
let silent = !result.isReachable && result.error == "Timeout - no response"
let localFailure = result.error == "Failed to send query"
```

After:

```swift
let silent = result.outcome == .timedOut
let noRoute = result.outcome == .unreachable && result.elapsed == nil
let localFailure = result.outcome == .failed
```

Apply the `silent` check only to results measured by 0.18 or later. For a result decoded from
JSON that 0.17 wrote, or built with the initializer that takes no `outcome`, the outcome is a
best-effort derivation from the old fields. In particular it cannot tell a refusal from silence:
0.17 wrote "Timeout - no response" for a refused port too, so such a result derives
`outcome == .timedOut` even when the host replied at once. Old data cannot recover the
distinction.

## dnsProbe throws CancellationError when its task is cancelled

**What changed.** Cancelling the task that awaits `dnsProbe` makes it throw `CancellationError`.
0.17 returned a result with `isReachable == false` and `error == "Unexpected error:
CancellationError()"`, which reads as a failed server.

**What a caller sees.** A thrown `CancellationError` where it got that result. `dnsProbe` was
already `throws`, so the call site compiles unchanged.

**What to change.** Make sure the code around the call treats `CancellationError` as "stopped",
not as a failure of the server, and does not record a result for it.

Before:

```swift
do {
  let result = try await dnsProbe(server: resolver)
  record(result)  // also recorded the fake result of a cancelled probe
} catch {
  reportFailure(error)
}
```

After:

```swift
do {
  let result = try await dnsProbe(server: resolver)
  record(result)
} catch is CancellationError {
  return
} catch {
  reportFailure(error)
}
```

## A trace whose socket cannot be made non-blocking throws

**What changed.** `trace`, `traceClassified` and `traceStream` (and `discoverPaths`, whose flows
run the same trace) check the two `fcntl` calls that make their probe socket non-blocking, as
`ping` already did. In 0.17 a failure was ignored and the
trace ran on a blocking socket, where its receive loop could wait for a reply past its deadline.

**What a caller sees.** `TracerouteError.socketCreateFailed(errno:details:)`, with `details` of
`fcntl F_GETFL failed` or `fcntl F_SETFL failed`, thrown before any probe is sent. The failure is
rare: it means the descriptor itself is unusable.

**What to change.** Nothing, if the consumer already handles `socketCreateFailed` from a trace,
which socket creation has always thrown. Check that the handler reports it as a local failure to
start the trace, not as a result about the network being diagnosed, and that it does not assume
the error can only come before a socket exists.

Before:

```swift
} catch TracerouteError.socketCreateFailed(let code, _) {
  // Assumed only when ICMP sockets are unavailable.
  showPermissionsHelp(errno: code)
}
```

After:

```swift
} catch TracerouteError.socketCreateFailed(let code, let details) {
  // Also thrown when the socket could not be made non-blocking.
  reportLocalFailure("could not open a probe socket: \(details)", errno: code)
}
```
