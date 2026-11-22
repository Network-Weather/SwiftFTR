# Migrating to SwiftFTR 0.18

Handle the cancellation, discovery-budget, DNS validation and trace socket-setup changes introduced in SwiftFTR 0.18.

## Overview

SwiftFTR 0.18 is source-compatible with 0.17: no public declaration is added, removed or changed.
What changes is behavior an unmodified caller can observe. Each section below has the same shape,
so a person or a coding agent can work through a consumer one change at a time:

- **What changed**, in the library.
- **What a caller sees**, at the call site.
- **What to change**, with code before and after.

To find the call sites to review, search the consumer for `discoverPaths(`, `networkChanged(`,
`cancelActiveTraces(`, `publicIPDiscoveryTimeout`, `DNSError` and `socketCreateFailed`.

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

## Invalid DNS inputs are reported before queueing

**What changed.** Every DNS query (`dnsProbe`, the `tracer.dns` queries, `reverseDNS`,
`reverseIPv6`, `queryA`, `queryAAAA`) checks its timeout, name, server address and the family of
its source address before it waits for one of the shared blocking-I/O workers. The source-address
family was checked only once a worker ran the query.

**What a caller sees.** The same `DNSError` case as 0.17 (`invalidTimeout`, `invalidHostname`,
`invalidIP`, or `bindFailed` for a source address of the wrong family), but without waiting behind
other blocking work first. `dnsProbe` throws `invalidTimeout` and `invalidHostname`, as before; it
reports an invalid server or a wrong-family source address in the returned result's `error`, as
before, rather than throwing.

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

## A trace whose socket cannot be made non-blocking throws

**What changed.** `trace`, `traceClassified` and `traceStream` check the two `fcntl` calls that
make their probe socket non-blocking, as `ping` already did. In 0.17 a failure was ignored and the
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
