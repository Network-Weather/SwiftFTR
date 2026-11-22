# Migrating to SwiftFTR 0.18

Handle the cancellation, discovery-budget and DNS changes introduced in SwiftFTR 0.18.

## Overview

SwiftFTR 0.18 is source-compatible with 0.17: no public declaration is added, removed or changed.
What changes is behavior an unmodified caller can observe. Each section below has the same shape,
so a person or a coding agent can work through a consumer one change at a time:

- **What changed**, in the library.
- **What a caller sees**, at the call site.
- **What to change**, with code before and after.

To find the call sites to review, search the consumer for `discoverPaths(`, `networkChanged(`,
`cancelActiveTraces(`, `publicIPDiscoveryTimeout`, `DNSError`, `dnsProbe(`, `rttMs` and the `rtt`
of the DNS result types.

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
topology measured on the old network. Cancelling the calling task still throws
`CancellationError`, so the two sources can be told apart; when both happened, the tracer's
`TracerouteError.cancelled` is reported.

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
its source address before it opens a socket. In 0.17 the source-address family was checked only
once one of the shared blocking-I/O workers ran the query, so behind busy workers the error was
late.

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
returns `isReachable == true` with `responseCode == nil`, a round-trip time, and `error` set to
"Connection refused - the host is reachable but no DNS server is listening". 0.17 reported the
refusal as `DNSError.timeout`, and `dnsProbe` as `isReachable == false` with "Timeout - no
response", although the refusal arrived at once. A server that stays silent is still
`DNSError.timeout`, and in `dnsProbe` still unreachable with "Timeout - no response".

**What a caller sees.** For a host with no DNS service on the port, `dnsProbe` changes from
unreachable to reachable with an error, and the query methods throw `sendFailed` where they threw
`timeout`. `isReachable` now means what it means for `udpProbe`: the host answered. As in 0.17, a
reachable result with `responseCode == nil` is not a DNS answer; a malformed reply looks the same.

**What to change.** Where `isReachable` is read as "a DNS server answered", test `responseCode`
as well, which is set for every DNS answer, NXDOMAIN and SERVFAIL included. Where the query
methods' errors are handled, treat `sendFailed` as "the query was not delivered to a DNS server",
distinct from `timeout`.

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
if result.isReachable, result.responseCode != nil {
  showDNSServerUp(resolver)  // a DNS server answered, NXDOMAIN and SERVFAIL included
} else if result.isReachable {
  // The host answered, but not with a DNS answer: a refused port or a malformed reply.
  showDNSServerMisbehaving(resolver, reason: result.error)
} else {
  showDNSServerDown(resolver, reason: result.error)
}
```

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

## An empty DNS reply is a malformed response

**What changed.** A zero-byte datagram from the server is a malformed reply: the query methods
throw `DNSError.malformedResponse`, and `dnsProbe` returns `isReachable == true` with
`responseCode == nil`, a round-trip time and `error == "Malformed response"`, as for any other
malformed reply. 0.17 reported it as `DNSError.timeout`, and `dnsProbe` as unreachable with
"Timeout - no response".

**What a caller sees.** For a server that answers with an empty datagram, `malformedResponse`
where it saw `timeout`, and a reachable `dnsProbe` result.

**What to change.** Nothing, if the consumer already handles `malformedResponse` and the reachable
`dnsProbe` result with no response code, as the previous section shows. Otherwise add the case.

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
} catch DNSError.malformedResponse {
  reportBadAnswer(from: resolver)
}
```
