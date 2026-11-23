# Migrating to SwiftFTR 0.19

Handle the two new DNSError cases and the DNS, address-validation, ping, bufferbloat and CLI changes introduced in SwiftFTR 0.19.

## Overview

Each section below covers one change an unmodified caller can observe, in the same shape, so a
person or a coding agent can work through a consumer one change at a time:

- **What changed**, in the library.
- **What a caller sees**, at the call site.
- **What to change**, with code before and after.

To find the call sites to review, search the consumer for `switch` over `DNSError`,
`DNSError.sendFailed`, `dnsProbe(`, `DNSError.timeout`,
`.timedOut`, `seedPublicIP(`, `64:ff9b`, `ping(`, `testBufferbloat(`, and any script that reads the
output of `swift-ftr probe dns`.

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
