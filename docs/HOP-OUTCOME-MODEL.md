# Per-hop outcome model

Implementation plan for the ROADMAP item "Per-hop outcome model".

## What is wrong

`TraceHop` encodes what happened at a hop implicitly, through which fields are `nil`.
That loses a distinction the library already parses: `.timeExceeded` and
`.destinationUnreachable` construct **identical** hops — an address, an RTT,
`reachedDestination: false`. So "this router forwarded me on" and "this router refused
to route this" are indistinguishable to a caller.

The ICMP code that would explain the refusal is parsed and then discarded:
`ParsedICMP.Kind` carries a code only on `.other`. The ping parser keeps it
(`PingReply.destinationUnreachable(..., code:)`), so the trace path is the outlier.

## The four outcomes

1. The probe never left the host.
2. It was sent and nothing came back.
3. A router or host reported it undeliverable — with a reason and a round-trip time.
4. It got a normal reply: Time Exceeded from an intermediate hop, or Echo Reply at the
   destination.

## Changes

### 1. Carry the ICMP code through both parsers

Add `code: UInt8` to `ParsedICMP.Kind.destinationUnreachable` and to the `@_spi(Test)`
`TestParsedICMP.Kind`. `code` is already in scope at every construction site in both the
v4 and v6 parsers, so this is mechanical.

### 2. `HopOutcome`

A public enum covering the four cases, with the reason attached where one exists.
Timing and address stay where they are.

### 3. Additive on the hop types

`TraceHop`, `ClassifiedHop`, and the streaming hop type gain `outcome`. The existing
`ipAddress` / `rtt` / `reachedDestination` stay and are documented as derived.

A purer design puts timing and address on the enum's associated values so illegal states
are unrepresentable — no `.timedOut` carrying an RTT. That is the better model in the
abstract and the wrong trade here: it breaks every downstream read of `hop.rtt` for a
correctness property nothing is currently getting wrong. Revisit at a major version.

### 4. Degrade a probe we could not send

Transient send-pressure retry currently throws when its shared burst budget is exhausted,
losing the whole trace. With `.notSent(errno:)` a caller can tell "we never sent" from "the
router ignored us", so skipping just that TTL becomes honest rather than a phantom
unresponsive hop.

Guard: if **no** probe was sent, still throw. A trace that sent nothing is an error, not a
result full of holes.

### 5. CLI JSON

Additive `outcome` field, snake_case, alongside the existing keys. Nothing existing is
renamed or removed — the CLI's output has a stated backward-compatibility obligation.

## Deliberately out of scope

A fifth outcome for replies arriving after the deadline, which currently collapse into the
timeout case. Only meaningful for the streaming API; add it when a consumer asks.

## Acceptance

- A hop that got Time Exceeded and a hop that got Destination Unreachable are
  distinguishable, and the unreachable one reports its ICMP code.
- A trace that cannot send some probes returns a result marking exactly those TTLs
  `.notSent`, rather than failing.
- A trace that cannot send *any* probe still throws.
- Existing callers reading `ipAddress` / `rtt` / `reachedDestination` are unaffected.
