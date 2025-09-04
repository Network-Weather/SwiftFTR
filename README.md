ParallelTraceroute
==================

Massively parallel, async/await traceroute library for macOS using ICMP datagram sockets (no sudo required). It fires one ICMP Echo probe per TTL up to a hop limit, as fast as possible, then concurrently collects ICMP Time Exceeded and Echo Reply messages to map the path.

Key points
- No sudo: uses `SOCK_DGRAM` with `IPPROTO_ICMP` (macOS supports this for ping/traceroute style operations).
- Parallel send: issues all TTL probes rapidly on a single socket by updating `IP_TTL` per send.
- Async/await friendly: single async `trace` API returning structured hop results.
- IPv4 only, macOS-focused.

Swift version
- Swift 6, macOS 13+

Library API
- `ParallelTraceroute().trace(to:maxHops:timeout:payloadSize:)` → `TraceResult` (default `maxHops=30`, `timeout=1.0s`)
- `TraceResult` contains `hops: [TraceHop]`, each with `ttl`, `host` (or `nil` on timeout), `rtt`, and a `reachedDestination` flag for echo replies.

Example (CLI)
Build and run the included sample executable:

```
swift build -c release
.build/release/ptroute 1.1.1.1 30 3
```

Programmatic usage
```
import ParallelTraceroute

let tracer = ParallelTraceroute()
let result = try await tracer.trace(to: "1.1.1.1", maxHops: 30, timeout: 1)
for hop in result.hops {
    print(hop.ttl, hop.host ?? "*", hop.rtt ?? 0)
}
```

Notes
- This implementation targets macOS’s ICMP datagram behavior. Other platforms may require adjustments (e.g., raw sockets on Linux typically need root).
- The traceroute sends one probe per TTL. You can adapt it to send multiple probes per TTL by issuing additional packets with incremented `sequence` numbers and tracking them in the same dictionaries.
- The socket is set `O_NONBLOCK` and we use `poll(2)` to drive receive without blocking. Incoming ICMP Time Exceeded packets include the embedded original header, which we parse to match the original `identifier`/`sequence`.
- Only IPv4 is implemented.

Fuzzing
- Quick random fuzzer (macOS-friendly): `icmpfuzz` builds without libFuzzer and hammers the parser with randomized inputs under ASan/UBSan.
  - Build: `swift build -c release -Xswiftc -sanitize=address -Xswiftc -sanitize=undefined`
  - Run: `.build/release/icmpfuzz` (override iterations with `ITER=200000`)
- Corpus-based and libFuzzer harness (Linux): `icmpfuzzer` provides a libFuzzer entrypoint when built on Linux with `-sanitize=fuzzer`.
  - Generate seed corpus: `swift run genseeds FuzzCorpus/icmp`
  - Linux build (Swift 6 toolchain): `swift build -c release -Xswiftc -sanitize=fuzzer,address,undefined`
  - Run: `.build/release/icmpfuzzer FuzzCorpus/icmp -max_total_time=30` (libFuzzer options)
  - On macOS, the same binary acts as a corpus replayer: `.build/release/icmpfuzzer FuzzCorpus/icmp`

License
- No license specified. Add one if you plan to distribute.
