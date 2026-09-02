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
more at once. Apple M4, macOS 26, 2026-09-01.

| Metric | Per-instance loading | Shared store |
| :--- | :--- | :--- |
| **Preload, first instance** | 59.9 ms | 61.5 ms |
| **Preload, each further instance** | 56–62 ms | 0.0 ms |
| **8 concurrent preloads** | 64.3 ms | 0.0 ms (already resident) |
| **Resident memory, 16 instances** | 6.1 MB → 507.9 MB | 6.1 MB → 57.3 MB |

One loaded database costs about 50 MB resident. Every instance in the process built for the same
source shares it, and it is released when the last one goes away.
