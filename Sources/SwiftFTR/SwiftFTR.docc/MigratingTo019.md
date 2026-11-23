# Migrating to SwiftFTR 0.19

Handle the behavior changes introduced in SwiftFTR 0.19.

## Overview

Each section below covers one change an unmodified caller can observe, in the same shape, so a
person or a coding agent can work through a consumer one change at a time:

- **What changed**, in the library.
- **What a caller sees**, at the call site.
- **What to change**, with code before and after.

To find the call sites to review, search the consumer for `testBufferbloat(` and
`BufferbloatConfig(`.

## Update the package

```swift
dependencies: [
  .package(
    url: "https://github.com/Network-Weather/SwiftFTR.git",
    from: "0.19.0"
  )
]
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
