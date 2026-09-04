# SwiftFTR Benchmarks

This document tracks the performance characteristics of SwiftFTR releases.
Benchmarks are run using the `ResourceBenchmark` tool: `swift run ResourceBenchmark`.

## Methodology
- **Test:** 500 concurrent pings to `8.8.8.8` (Timeout: 2s).
- **Metric:** Memory (RSS) Delta, CPU Time, Throughput.
- **Machine:** macOS arm64 (M-series).

## Results

### v0.8.0 (November 2025)
*Optimization: Event-driven DispatchSource + Private Serial Queues (Robustness Focus)*

| Metric | Result | vs v0.7.0 |
| :--- | :--- | :--- |
| **Throughput** | **573 pings/sec** | **35x Faster** |
| **Duration** | **~0.87s** | **97% Faster** |
| **Memory Delta** | **8.33 MB** | Higher baseline* |
| **Memory Per Ping** | **~17 KB** | Lean |
| **CPU Time** | **0.03s** | **40x Less** |

> *Note: v0.8.0 prioritizes robustness with private serial queues per operation, preventing thread starvation and race conditions. While using slightly more memory than a shared queue approach (17KB vs 11KB), it delivers massive throughput and minimal CPU usage.*

### v0.7.0 (October 2025)
*Architecture: Task-based polling (poll(2))*

| Metric | Result |
| :--- | :--- |
| **Throughput** | 16.0 pings/sec |
| **Duration** | 31.3s |
| **Memory Delta** | 3.62 MB |
| **Memory Per Ping** | ~7.4 KB |
| **CPU Time** | 1.25s |

---

## History
- **v0.8.0-rc2 (Global Queue)**: 11.8 KB/ping, 248 pings/sec. Switched to private queues for reliability.
- **v0.8.0-rc1 (Private Queue)**: 17.5 KB/ping.
- **v0.8.0-final**: 17 KB/ping, 573 pings/sec.
## Embedded ASN database across tracer instances

Measured with `swift run -c release asnloadprobe 8`, which constructs 8 `SwiftFTR` instances with
`asnResolverStrategy: .embedded`, preloads them one after another, then constructs and preloads 8
more at once. Apple M4, macOS 26. Shared-store column re-measured 2026-09-03 against SwiftIP2ASN
0.5.1; the per-instance column was taken 2026-09-01 at the commit before sharing landed.

| Metric | Per-instance loading | Shared store |
| :--- | :--- | :--- |
| **Preload, first instance** | 59.9 ms | 56.8 ms |
| **Preload, each further instance** | 56-62 ms | 0.0 ms |
| **8 concurrent preloads** | 64.3 ms | 0.0 ms (already resident) |
| **Resident memory, 16 instances** | 6.1 MB -> 507.9 MB | 6.1 MB -> 57.2 MB |

### Resolver strategies

Cold and warm resolution of ten well-known public addresses, release build, SwiftIP2ASN 0.5.1,
2026-09-03. Reproduce with `swift test -c release --filter AsnStrategyBench`. Cold includes the
one-time database load for the local strategies; the `.dns` figure depends on the resolver in front
of the machine and varies between runs.

| Strategy | Coverage | Cold | Warm |
| :--- | :--- | :--- | :--- |
| `.dns` | 10/10 | 0.187 s | <0.1 ms |
| `.hybrid(.embedded)` (default) | 10/10 | 0.059 s | <0.1 ms |
| `.embedded` | 10/10 | 0.055 s | <0.1 ms |

Run the same benchmark in a debug build and the local strategies invert, costing about 0.50 s cold
against DNS's 0.22 s, because decompressing and parsing the database is roughly eight times slower
unoptimized. Compare strategies in release only.

### What one copy costs

Physical footprint, measured by loading `UltraCompactDatabase` repeatedly in a release build
against SwiftIP2ASN 0.5.1 on 2026-09-03. The database holds 455,832 IPv4 ranges, 121,752 IPv6
ranges and 86,833 ASN names.

| | Footprint | Delta |
| :--- | :--- | :--- |
| Baseline | 1.6 MB | |
| One database loaded | 51.0 MB | +49.4 MB |
| Two held | 66.1 MB | +15.1 MB |
| Three held | 81.1 MB | +15.0 MB |

So a copy is about **15 MB**: 9.4 MB of parallel range arrays plus roughly 6 MB of ASN-name
strings. The first load costs far more footprint than the copy it produces because the decoder
allocates a scratch buffer eight times the compressed size, decodes into it, and copies the result
out before parsing; the allocator retains those pages for reuse rather than returning them to the
system. Releasing every database does not return the footprint either, for the same reason.

Reducing this further means changing the on-disk format upstream in SwiftIP2ASN rather than
anything in SwiftFTR. In rough order of payoff: ship the database in its binary-searchable layout
and memory-map it, which makes the pages clean, evictable and shared between processes and removes
the decode entirely; flatten the ASN-name table into one contiguous UTF-8 buffer with a sorted
offset array, worth about 3.5 MB; and record the decompressed size in the header so the decoder can
size its buffer exactly instead of guessing at 8x.
