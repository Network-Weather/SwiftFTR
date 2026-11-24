# Migrating to SwiftFTR 0.19

Handle the two new DNSError cases, the public-IP resolver, and the DNS, address-validation, ping, bufferbloat, public-IP discovery, ASN lookup and CLI changes introduced in SwiftFTR 0.19.

## Overview

Each section below covers one change an unmodified caller can observe, in the same shape, so a
person or a coding agent can work through a consumer one change at a time:

- **What changed**, in the library.
- **What a caller sees**, at the call site.
- **What to change**, with code before and after.

To find the call sites to review, search the consumer for `switch` over `DNSError`,
`DNSError.sendFailed`, `dnsProbe(`, `DNSError.timeout`,
`.timedOut`, `seedPublicIP(`, `64:ff9b`, `ping(`, `testBufferbloat(`, `getPublicIPs(`, `publicIPDiscoveryTimeout`,
`.classify(`, `.publicIP` read from a `SwiftFTR` tracer, `SwiftFTRConfig(` calls that pass `publicIP:`,
`traceClassified(` results whose `publicIP` or `clientASN` is read for an IPv6 destination,
`discoverPaths(` followed by a read of the public-IP cache, `PublicIPError`,
`discoverPublicIPWithHostname(`, `STUNPublicIP`, `getPublicIPs(` calls that pass `sourceIP:`,
`ASNResolver` conformances and `resolve(ipv4Addrs:` calls, `preloadASNDatabase(`, and any
script that reads the output of `swift-ftr probe dns`.

## Update the package

```swift
dependencies: [
  .package(
    url: "https://github.com/Network-Weather/SwiftFTR.git",
    from: "0.19.0"
  )
]
```

## DNSError adds connectionRefused and unreachable

**What changed.** ``DNSError`` has two new cases, ``DNSError/connectionRefused`` and
``DNSError/unreachable``. The query methods (``DNSQueries``, ``reverseDNS(ip:server:timeout:interface:sourceIP:)``,
``reverseIPv6(ip:server:timeout:interface:sourceIP:)``, ``queryA(hostname:server:timeout:interface:sourceIP:)``,
``queryAAAA(hostname:server:timeout:interface:sourceIP:)``) throw them where 0.18 threw
``DNSError/sendFailed`` or ``DNSError/timeout``, so each failure is named as
``dnsProbe(server:query:timeout:)`` already named it:

| What happened | 0.18 threw | 0.19 throws | `dnsProbe` outcome (unchanged) |
|---|---|---|---|
| ICMP port unreachable after the send: the host is up, nothing listens on the port | `sendFailed` | `connectionRefused` | `refused` |
| ICMP host or network unreachable after the send | `timeout` | `unreachable` | `unreachable` |
| `connect` or `send` fails with `EHOSTUNREACH`, `EHOSTDOWN`, `ENETUNREACH` or `ENETDOWN` | `sendFailed` | `unreachable` | `unreachable` |
| Any other send or connect failure (a short send, `EPERM`, `EMSGSIZE`, buffer pressure past the timeout) | `sendFailed` | `sendFailed` | `failed` |
| Silence, or another receive error | `timeout` | `timeout` | `timedOut` or `failed` |

`dnsProbe` itself does not change: its `outcome`, `isReachable`, `rtt`, `elapsed` and `error`
are what 0.18 gave for every one of these.

**What a caller sees.** A `switch` over `DNSError` without a `default` no longer compiles
("switch must be exhaustive"). A `catch DNSError.sendFailed` no longer catches a refusal or a
no-route failure, and a `catch DNSError.timeout` no longer catches a host or network unreachable
report: code that retried on `timeout` no longer retries for that case, which arrives at once
rather than after the timeout.

**What to change.** Add the two cases to every exhaustive switch, and choose a retry policy for
each. 0.18's handling cannot be kept exactly: `unreachable` joins a report that 0.18 threw as
`timeout` with a local no-route failure it threw as `sendFailed`, and nothing in the error tells
them apart afterwards (a later `dnsProbe` measures a new request, not the one that failed). The
example below makes one explicit choice for each case; adapt it to the consumer's policy.

Before:

```swift
do {
  let result = try await tracer.dns.a(hostname: name, server: server)
  use(result)
} catch let error as DNSError {
  switch error {
  case .timeout: retryLater()
  case .sendFailed: reportNoDNSServer()
  case .invalidIP, .invalidHostname, .invalidTimeout: reportBadInput()
  case .socketCreationFailed, .setsockoptFailed, .bindFailed: reportLocalFailure()
  case .malformedResponse, .noRecords, .serverError: reportAnswer(error)
  }
}
```

After, retrying both kinds of unreachable failure and not retrying a refusal:

```swift
do {
  let result = try await tracer.dns.a(hostname: name, server: server)
  use(result)
} catch let error as DNSError {
  switch error {
  case .timeout: retryLater()
  case .unreachable:
    // Retry, as for timeout: no route, or the network reported the server unreachable. It
    // arrives at once rather than after the timeout, so retry after a backoff, not in a loop.
    // (0.18 threw timeout for the network's report, and sendFailed for a local no-route.)
    retryLater()
  case .connectionRefused:
    // Do not retry: the host answered that no DNS server listens on the port.
    // (0.18 threw sendFailed for this.)
    reportNoDNSServer()
  case .sendFailed: reportNoDNSServer()
  case .invalidIP, .invalidHostname, .invalidTimeout: reportBadInput()
  case .socketCreationFailed, .setsockoptFailed, .bindFailed: reportLocalFailure()
  case .malformedResponse, .noRecords, .serverError: reportAnswer(error)
  }
}
```

A consumer that would rather not retry a local no-route failure, as 0.18 effectively did, cannot
tell it from the network's report by the error; treat every `unreachable` the same, whichever way
it chooses.

## A DNS reply that echoes another question is ignored

**What changed.** A DNS reply must now echo the question that was asked, as well as carry the
query's transaction ID (RFC 5452 sections 3 and 9.1). A datagram whose first question is readable
and names another name (compared without regard to ASCII case), another type or another class is
ignored, like one with another transaction ID, and the query keeps waiting to the same deadline.
This applies to the query methods (``DNSQueries``), ``dnsProbe(server:query:timeout:)`` and the
Team Cymru ASN lookups. A reply with no question section, such as a header-only REFUSED, still
decides the query with its response code; one whose first question cannot be read (not plain
labels, over 255 bytes, or cut short) is still malformed. A first question whose name is a
compression pointer, which 0.18 read as the root name and whose response code it believed, is now
malformed too: there is no earlier name for it to point at.

**What a caller sees.** A server that answers only with replies to another question, which 0.18
reported as answered with those replies' records, now times out: the query methods throw
``DNSError/timeout`` and `dnsProbe` returns `outcome == .timedOut` with `isReachable == false`,
`rtt == nil` and `error == "Timeout - no response"`. A server that sends such a reply and then the
right one is answered by the right one, with its own round-trip time.

**What to change.** Nothing, if a timeout already means "no usable answer from this server". Code
that treated `.timedOut` as "the server is down" should allow that the server may be up and
answering some other question, which only a packet capture can tell apart. No source change is
needed:

Before and after:

```swift
let probe = try await dnsProbe(server: server, query: name, timeout: 2)
switch probe.outcome {
case .answered: showHealthy(rtt: probe.rtt)
case .timedOut: showNoAnswer()  // includes a server answering only another question
default: showFailed(probe.error)
}
```

## Address strings with a NUL, and NAT64 addresses embedding a private IPv4 address

**What changed.** Every address and destination string the library parses is rejected if it
contains a NUL character. Before, `inet_pton` and `getaddrinfo` read only the text before the
NUL, so `"8.8.8.8\u{0}junk"` was taken as `8.8.8.8`. Separately,
``SwiftFTR/seedPublicIP(_:source:)`` rejects a `64:ff9b::/96` (NAT64 well-known prefix) address
whose embedded IPv4 address is not public, such as `64:ff9b::192.168.1.1`, which RFC 6052 section
3.1 forbids; `64:ff9b::8.8.8.8` is still accepted.

**What a caller sees.** For a string containing a NUL: `seedPublicIP` returns `false`;
``isPrivateIPv4(_:)`` and ``isCGNATIPv4(_:)`` return `false`; ``reverseIPv6Nibbles(_:)`` and
``reverseDNS(_:)`` return `nil` without a lookup; a DNS query to such a server throws
``DNSError/invalidIP(_:)``, and with such a source address ``DNSError/bindFailed(_:)``; `ping` and
`trace` throw ``TracerouteError/resolutionFailed(host:details:)`` for such a destination and
``TracerouteError/sourceIPBindFailed(sourceIP:errno:details:)`` for such a source address; the TCP
and UDP probes return an unresolved or unbound error result. Interface names are not checked.

**What to change.** Strip a trailing NUL that came from a C buffer before passing a string in, and
check `seedPublicIP`'s result instead of assuming the seed was cached:

Before:

```swift
let address = String(cString: buffer) + suffix  // may carry a NUL from a fixed-size field
await tracer.seedPublicIP(address, source: .gatewayReported)
```

After:

```swift
let address = (String(cString: buffer) + suffix).replacingOccurrences(of: "\u{0}", with: "")
if await tracer.seedPublicIP(address, source: .gatewayReported) == false {
  // Not a public address: let the next classified trace discover it.
}
```

## A ping whose send failed ends once every sent probe is answered

**What changed.** A ping ended early only once it had as many replies as its configured `count`.
When a send failed, that count could not be reached, so the ping waited out its full reply window
after every probe that left had been answered. It now ends once every probe that was sent has been
answered.

**What a caller sees.** Such a ping returns sooner, with the same result: `statistics.sent` counts
the sends that succeeded, as before. A ping with a probe still unanswered waits the full
``PingConfig/timeout`` after its last send, as before.

**What to change.** Nothing. Code that measured a ping's duration to detect send failures should
read `statistics.sent` instead:

Before:

```swift
let start = Date()
let result = try await tracer.ping(to: host, config: config)
let sendTroubleSuspected = Date().timeIntervalSince(start) > config.timeout
```

After:

```swift
let result = try await tracer.ping(to: host, config: config)
let sendTroubleSuspected = result.statistics.sent < config.count
```

## The CLI's wording for a failed DNS probe

**What changed.** `swift-ftr probe dns` printed `Outcome: failed: the probe could not run` for
`outcome == .failed`, which also covers a probe whose query was sent and whose receive then failed.
It now prints `Outcome: failed: the probe could not complete`. The JSON output is unchanged; its
`outcome` is still `"failed"`.

**What a caller sees.** Only the human-readable line differs.

**What to change.** A script that matches the old line should match the JSON `outcome` instead:

Before:

```sh
swift-ftr probe dns 192.0.2.53 example.com | grep -q 'failed: the probe could not run'
```

After:

```sh
swift-ftr probe dns 192.0.2.53 example.com --json | jq -e '.outcome == "failed"'
```

## The default bufferbloat upload target is Cloudflare's speed test

**What changed.** With no ``BufferbloatConfig/uploadURL``, ``SwiftFTR/SwiftFTR/testBufferbloat(config:)``
sent its upload load to `https://httpbin.org/post`, a free community service with no availability
promise. It now sends it to `https://speed.cloudflare.com/__up`, the upload endpoint of the same
service the default download load uses. The requests themselves are unchanged: 256 KiB POSTs, one
after another on each of ``BufferbloatConfig/parallelStreams`` streams, until the load phase ends.

**What a caller sees.** Upload traffic to `speed.cloudflare.com` instead of `httpbin.org`, and an
upload load that no longer depends on httpbin.org's health. A caller that sets `uploadURL` sees no
change.

**What to change.** Nothing, unless a firewall rule, a proxy allowlist or a test fixture names
`httpbin.org` for the bufferbloat test: allow `speed.cloudflare.com` instead, or keep the old
target explicitly.

Before (0.18, relying on the default):

```swift
let result = try await tracer.testBufferbloat(config: BufferbloatConfig(loadType: .upload))
```

After, to keep sending the upload load to httpbin.org:

```swift
let result = try await tracer.testBufferbloat(
  config: BufferbloatConfig(loadType: .upload, uploadURL: "https://httpbin.org/post"))
```

## getPublicIPs ends when its caller is cancelled

**What changed.** ``getPublicIPs(stunTimeout:interface:sourceIP:enableLogging:)`` runs its IPv4
and IPv6 sweeps as child tasks of the calling task. Cancelling the calling task now ends both
sweeps at once. In 0.18 the sweeps ran in tasks of their own that did not see the cancellation, so
the call went on until every STUN server had answered or timed out.

**What a caller sees.** A cancelled call returns at once with whatever it had found by then:
usually `PublicIPs(v4: nil, v6: nil)`, or one family if that sweep had already finished. In 0.18
the same call returned later with both families filled in where the network allowed. The call
still never throws.

**What to change.** Code that cancels the task around `getPublicIPs` and still uses the result
should treat `nil` fields after cancellation as "not measured", not as "this family has no public
address". Check for cancellation before reporting a family as missing.

Before:

```swift
let ips = await getPublicIPs()
show(v4: ips.v4 ?? "no IPv4 path", v6: ips.v6 ?? "no IPv6 path")
```

After:

```swift
let ips = await getPublicIPs()
guard !Task.isCancelled else { return }  // nil fields here mean "not measured"
show(v4: ips.v4 ?? "no IPv4 path", v6: ips.v6 ?? "no IPv6 path")
```

## Public-IP discovery in a classified trace stops at its budget

**What changed.** In ``SwiftFTR/SwiftFTR/traceClassified(to:vpnContext:resolver:)`` and
``SwiftFTR/SwiftFTR/discoverPaths(to:config:)``, public-IP discovery is bounded by one deadline:
``SwiftFTRConfig/publicIPDiscoveryTimeout`` (6 s by default) from the moment discovery starts.
Every STUN server-name lookup and STUN attempt is cut at that deadline, and the discovery stops
there. In 0.18 the caller was released at the budget while the discovery ran on in a slot of the
blocking-I/O executor.

**What a caller sees.** No signature changes and no new errors: a discovery that finds nothing
still leaves `publicIP` as `nil` in the classified result. A stalled STUN attempt no longer goes on
using an executor slot's worth of work after the trace has returned.

**What to change.** Nothing: the same configuration now ends the work at the budget, not only
the caller's wait.

## The library's public-IP resolver is STUN only

**What changed.** When IPv4 STUN got no answer, 0.18 asked the recursive resolvers `1.1.1.1` and
`8.8.8.8` for the `whoami.ds.akahelp.net` TXT record, whose `ip` field is built from the
client-subnet hint the resolver forwards, so it named another host or network than the caller's
(#153); the query was not bound to the tracer's interface either (#151). The fallback is deleted:
``PublicIPResolverStrategy/library`` is STUN only. Every STUN socket is bound to the tracer's
interface and source address before its server name is resolved, and a failed bind sends
nothing, the lookup included. The lookups use the system resolver, which is not bound.

**What a caller sees.**

- Where UDP to the STUN servers is blocked, `publicIP` and `clientASN` are `nil` where 0.18 may
  have reported the whoami address (own-network hops are TRANSIT, not ISP), and
  ``SwiftFTR/SwiftFTR/discoverPublicIPWithHostname()`` throws (see below). With STUN silent,
  discovery ends once both servers time out, about 4 s by default.
- A tracer bound to an interface or source address it cannot bind sends no STUN name lookups.

**What to change.** Nothing, if STUN reaches its servers. A host app that knows its public
address where STUN is blocked supplies it, through a seed or its own resolver:

Before:

```swift
let tracer = SwiftFTR(config: SwiftFTRConfig(interface: "en0"))
// 0.18 fell back to a whoami record when STUN failed
```

After:

```swift
let tracer = SwiftFTR(config: SwiftFTRConfig(interface: "en0"))
if let known = myGatewayReportedWAN {
  _ = await tracer.seedPublicIP(known, source: .gatewayReported)
}
// or: SwiftFTRConfig(interface: "en0", publicIPResolver: .custom(myResolver))
```

## discoverPublicIPWithHostname asks the strategy, and PublicIPError has new cases

**What changed.** ``SwiftFTR/SwiftFTR/discoverPublicIPWithHostname()`` ran the library's
discovery whatever the tracer's strategy. It now asks the configured
``SwiftFTRConfig/publicIPResolver`` once for a fresh IPv4 address, bypassing
``SwiftFTRConfig/publicIP`` and the cache and caching nothing, as before, and returns only a
globally routable IPv4 address. ``PublicIPError`` loses `allMethodsFailed(stunError:dnsError:)`,
which described a DNS tier that no longer exists, and gains ``PublicIPError/discoveryDisabled``
and ``PublicIPError/noAddress(reason:)``.

**What a caller sees.**

- With ``PublicIPResolverStrategy/disabled`` it throws ``PublicIPError/discoveryDisabled`` and
  sends nothing; with ``PublicIPResolverStrategy/custom(_:)`` the caller's resolver answers. 0.18
  sent STUN in both.
- When the strategy finds no address in time, or answers with an address that is not a public
  IPv4 address, or the configured source address is IPv6, the call throws
  ``PublicIPError/noAddress(reason:)``. 0.18 threw `allMethodsFailed`, or an internal timeout
  error, or returned the address unchecked.
- A call cancelled while its reverse-DNS lookup runs throws `CancellationError`; 0.18 returned the
  address with `hostname == nil`, as if it had no name.
- Code that matches or builds `PublicIPError.allMethodsFailed` no longer compiles, and an
  exhaustive `switch` over ``PublicIPError`` must handle the two new cases.

**What to change.** Match the new cases:

Before:

```swift
do {
  let (ip, _) = try await tracer.discoverPublicIPWithHostname()
  show(ip)
} catch PublicIPError.allMethodsFailed(let stun, let dns) {
  log("no public IP: STUN \(stun), DNS \(dns)")
}
```

After:

```swift
do {
  let (ip, _) = try await tracer.discoverPublicIPWithHostname()
  show(ip)
} catch PublicIPError.noAddress(let reason) {
  log("no public IP: \(reason)")
} catch PublicIPError.discoveryDisabled {
  // the tracer's publicIPResolver is .disabled
}
```

## getPublicIPs binds each family, or sends nothing for it

**What changed.** ``getPublicIPs(stunTimeout:interface:sourceIP:enableLogging:)`` asks the
library's resolver for each family. Given a `sourceIP`, it runs only the sweep of that address's
family, bound to it; 0.18 ran the other family's sweep unbound. A `sourceIP` that is not an IP
address now sends nothing; 0.18 ran both sweeps unbound. `stunTimeout` is still per server, and
the call still has no overall deadline and reports the address as the STUN server gave it.

**What a caller sees.** With `sourceIP: "192.0.2.10"`, `v6` is always `nil`; with an IPv6
`sourceIP`, `v4` is always `nil`; with a malformed one, both are `nil`.

**What to change.** To discover both families, make two calls, each with a source address of its
own family. A call without `sourceIP` sweeps both families unbound, so it cannot ask for
system-routed IPv6 alone: the IPv4 request would also leave, over the default route. A caller
with a source address for one family only gets that family.

Before:

```swift
let ips = await getPublicIPs(sourceIP: v4Source)  // 0.18: v6 swept unbound
```

After:

```swift
async let v4 = getPublicIPs(sourceIP: v4Source)
async let v6 = getPublicIPs(sourceIP: v6Source)
let ips = await PublicIPs(v4: v4.v4, v6: v6.v6)
```

## STUNPublicIP is no longer public

**What changed.** `STUNPublicIP` is internal; no public function returned or took it in 0.18.
**What a caller sees.** A reference to it no longer compiles. **What to change.** Use
``PublicIPObservation``:

Before:

```swift
let found = STUNPublicIP(ip: address, family: AF_INET)
```

After:

```swift
let found = PublicIPObservation(address: address, family: .v4, source: .stun)
```

## TraceClassifier.classify takes the public address and no longer finds it

**What changed.** ``TraceClassifier/classify(trace:destinationIP:resolver:timeout:publicIP:vpnContext:)``
classifies with the public address it is given, or without one, and sends nothing to find it. The
parameters that existed only for its discovery (`interface`, `sourceIP`, `enableLogging` and
`publicIPDiscoveryTimeout`) are gone, and `publicIP` no longer has a default.

**What a caller sees.** A call that passes any of the removed parameters, or leaves `publicIP` out,
no longer compiles. A call that passed `publicIP: nil` (or left it out) to have the classifier run
STUN now classifies without a public address: hops in the client's own network are labelled
TRANSIT rather than ISP, and `clientASN` is `nil`.

**What to change.** Drop the removed arguments and pass `publicIP` explicitly. To keep 0.18's
discovery, use ``SwiftFTR/SwiftFTR/traceClassified(to:vpnContext:resolver:)``, which asks for the
address once; or find it yourself and pass it in.

Before:

```swift
let classified = try await TraceClassifier().classify(
  trace: trace, destinationIP: destination, resolver: resolver,
  interface: "en0", sourceIP: source, enableLogging: true, publicIPDiscoveryTimeout: 4)
```

After:

```swift
let known = await tracer.publicIP(for: .v4)?.address  // or your own observation, or nil
let classified = try await TraceClassifier().classify(
  trace: trace, destinationIP: destination, resolver: resolver, publicIP: known)
```

## SwiftFTR.publicIP is per address family

**What changed.** The tracer keeps one public address per family, with where it came from. The
`publicIP` property is replaced by ``SwiftFTR/SwiftFTR/publicIP(for:)``, which takes an
``IPAddressFamily`` and returns a ``PublicIPObservation`` (address, family and source) or `nil`.
Like the property, it returns the configured ``SwiftFTRConfig/publicIP`` first, and otherwise
what is seeded or cached, without asking anyone.

**What a caller sees.** `await tracer.publicIP` no longer compiles.

**What to change.** Name the family, and read `.address`. Where 0.18 code did not care which
family it got, ask for the one the trace used, or IPv4 first:

Before:

```swift
let address: String? = await tracer.publicIP
```

After:

```swift
let v4 = await tracer.publicIP(for: .v4)?.address
let v6 = await tracer.publicIP(for: .v6)?.address
let address: String? = v4 ?? v6
```

## A classified trace asks for its public address once, after the probes, for their family

**What changed.** ``SwiftFTR/SwiftFTR/traceClassified(to:vpnContext:resolver:)`` asked for an IPv4
address before probing, whatever the destination, and when that failed the classifier asked again,
so a failed discovery cost twice ``SwiftFTRConfig/publicIPDiscoveryTimeout``. It now asks once,
after the probes have returned, for the family they used, through the new
``SwiftFTRConfig/publicIPResolver`` strategy: the library's resolver by default (STUN only; see
"The library's public-IP resolver is STUN only"), ``PublicIPResolverStrategy/disabled``, or the
caller's own ``PublicIPResolver``. An answer that is not a globally routable address of that
family is not used. ``ClassifiedTrace/publicIPSource`` says where the address came from.

**What a caller sees.**

- An IPv6 trace reports the IPv6 public address found by IPv6 STUN, where 0.18 reported the IPv4
  one; with no answer to IPv6 STUN, `publicIP` and `clientASN` are `nil`, and hops in the client's
  own network are labelled TRANSIT rather than ISP.
- With discovery failing, a classified trace spends one budget on it, not two.
- An address the library's discovery finds that is not globally routable (a STUN server inside
  the network can report one) is no longer used.
- `ClassifiedTrace` encodes a new `publicIPSource` key.

**What to change.** Nothing for an IPv4 caller with the default strategy. A caller that needs an
address where STUN is blocked, or knows better than STUN which exit a trace takes, supplies a
resolver; one that must send nothing disables it:

Before:

```swift
let tracer = SwiftFTR(config: SwiftFTRConfig(interface: "en0"))
```

After:

```swift
// `myResolver` conforms to PublicIPResolver (an example is in docs/guides/EXAMPLES.md).
let tracer = SwiftFTR(
  config: SwiftFTRConfig(interface: "en0", publicIPResolver: .custom(myResolver)))
// or: SwiftFTRConfig(interface: "en0", publicIPResolver: .disabled)
```

## A configured or seeded public address answers only its own family, and must be public

**What changed.** ``SwiftFTRConfig/publicIP`` and a seed from
``SwiftFTR/SwiftFTR/seedPublicIP(_:source:)`` each apply only to traces of their own address
family. A configured address that is not globally routable (private, CGNAT, link-local, loopback,
documentation ranges and the others ``SwiftFTR/SwiftFTR/seedPublicIP(_:source:)`` rejects) is not
used. A seed's ``PublicIPSource`` is kept and reported as ``ClassifiedTrace/publicIPSource``.

**What a caller sees.**

- With `SwiftFTRConfig(publicIP: "9.9.9.9")` (an IPv4 address) an IPv6 classified trace no
  longer reports it: it asks the strategy for an IPv6 address, which by default sends IPv6 STUN.
- A configured private or documentation address, which 0.18 reported and classified with, is
  ignored, and the trace asks the strategy instead.
- An IPv6 seed no longer labels an IPv4 trace, and the reverse. An IPv4-mapped address
  (`::ffff:8.8.8.8`) is IPv4: it is kept as `8.8.8.8` and answers IPv4 traces only.
- `swift-ftr trace` and `multipath` with `--public-ip` still send no discovery traffic, but report
  no public address where the given one is refused or of the other family.

**What to change.** Configure a public address, seed each family you know, and disable the strategy
if no discovery traffic may be sent:

Before:

```swift
let config = SwiftFTRConfig(publicIP: knownWAN)  // 0.18: used for every trace, never discovered
```

After:

```swift
let config = SwiftFTRConfig(publicIP: knownWAN, publicIPResolver: .disabled)
// knownWAN must be globally routable, and answers only traces of its own family.
```

## A multipath run asks for its public address once, before its flows

**What changed.** ``SwiftFTR/SwiftFTR/discoverPaths(to:config:)`` asks for the IPv4 public address
once, in the parent, before its first batch of flows, in the same order a classified trace uses
(configured, seeded or cached, then the ``SwiftFTRConfig/publicIPResolver`` strategy), and gives
every flow that answer or its absence. With nothing cached, each flow used to discover on its own,
and nothing it found was cached. ``NetworkTopology/publicIPSource`` says where the address came
from.

**What a caller sees.**

- With discovery failing, a run spends one ``SwiftFTRConfig/publicIPDiscoveryTimeout`` on it
  before probing, rather than one per flow.
- An address the run finds is cached, so a later classified trace or run on the same tracer does
  not ask again until ``SwiftFTR/SwiftFTR/invalidatePublicIP()`` or a network change.
- ``NetworkTopology/publicIP`` is the run's answer; it was the first path's.
- A network change while the question is outstanding ends the run with
  ``TracerouteError/cancelled`` before any flow has probed.

**What to change.** Nothing, unless code relied on a multipath run leaving the public-IP cache
empty; invalidate it after the run in that case:

Before:

```swift
let topology = try await tracer.discoverPaths(to: host)
```

After, to keep the cache as it was:

```swift
let topology = try await tracer.discoverPaths(to: host)
await tracer.invalidatePublicIP()  // 0.19 caches the run's answer
```

## An ASN lookup's timeout bounds the whole call

**What changed.** The `timeout` passed to ``ASNResolver/resolve(ipv4Addrs:timeout:)`` is how long
the whole call may take, through every built-in resolver it passes, and the call returns what it
has when it runs out:

| Resolver | 0.18 | 0.19 |
|---|---|---|
| ``CymruDNSResolver`` (`.dns`) | each query, each server and each wave of eight queries got the full timeout | every query and the fallback to the second server share one deadline; each server still to try gets an equal share of the time left, and no query starts once it has passed |
| ``LocalASNResolver`` (`.embedded`, `.remote`) | waited for a database still loading however long it took, and ran each batch on the resolver | waits for the load until the timeout, and the load runs on and answers the next lookup; batches run off the resolver and stop at the timeout |
| ``HybridASNResolver`` (the default `.hybrid(.embedded)`) | the same database wait, then DNS with `fallbackTimeout` | the same bounded wait, then a wait for DNS until the timeout, or no DNS when none is left; the DNS query keeps `fallbackTimeout`, so concurrent lookups share it |
| ``CachingASNResolver`` | waited for the resolver behind it | stops waiting at its own timeout; the shared lookup runs on and fills the cache |

A caller that stops waiting, at its timeout or because it was cancelled, stops nothing shared: a
database load and a cached lookup run on for the other callers, and a resolver whose caller left
answers its next lookup from that same load. Only a load that failed leaves its resolver without
a database, as in 0.18.

**What a caller sees.**

- A classified trace spends at most the 1.5 s it passes on ASN lookups. One started before the
  local database has loaded can come back without ASN data, where 0.18 waited for the load.
- A `.dns` lookup with a stalled first server returns at its timeout, so fewer addresses may
  resolve, and AS names (``ASNInfo/name``) can be empty when the origin queries used most of the
  time.
- Cancelling a task in ``LocalASNResolver/resolve(ipv4Addrs:timeout:)`` while the database loads
  throws `CancellationError` at once; it used to wait for the load and answer. A cancelled
  ``LocalASNResolver/preload()`` returns, leaving the load running.
- A direct call with a timeout shorter than a cold database load returns an empty map for
  addresses the database would have answered.

**What to change.** Load the database before the first classified trace if that trace should
carry ASN data, and give direct lookups a timeout that covers what they wait for:

Before:

```swift
let tracer = SwiftFTR(config: SwiftFTRConfig())
let trace = try await tracer.traceClassified(to: host)  // waited for the database to load
```

After:

```swift
let tracer = SwiftFTR(config: SwiftFTRConfig())
await tracer.preloadASNDatabase()  // waits for the load; a lookup no longer does
let trace = try await tracer.traceClassified(to: host)
```

A custom ``ASNResolver`` is not raced by the library: honor `timeout` as the bound for the whole
call, as the built-in resolvers do.
