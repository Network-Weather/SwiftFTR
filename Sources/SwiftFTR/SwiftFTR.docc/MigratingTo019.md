# Migrating to SwiftFTR 0.19

Handle the behavior changes introduced in SwiftFTR 0.19.

## Overview

Each section below covers one change an unmodified caller can observe, in the same shape, so a
person or a coding agent can work through a consumer one change at a time:

- **What changed**, in the library.
- **What a caller sees**, at the call site.
- **What to change**, with code before and after.

To find the call sites to review, search the consumer for `getPublicIPs(`.

## Update the package

```swift
dependencies: [
  .package(
    url: "https://github.com/Network-Weather/SwiftFTR.git",
    from: "0.19.0"
  )
]
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
