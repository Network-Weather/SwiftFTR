# SwiftFTR Concurrency Modernization Plan

**Status**: ✅ **COMPLETED** (October 2025)
**Results**: See `Concurrency-Bottleneck-Baseline.md` for actual implementation and performance results

## Goals

- Keep shared state safe while enabling true parallel execution for traceroute, classified trace, ping, bufferbloat, and multipath work.
- Remove blocking I/O from actor contexts so cooperative executors stay responsive.
- Adopt Swift 6.2 concurrency features (`@concurrent`, default isolation updates) and make `Sendable` boundaries explicit.
- Ensure tests and documentation reflect the new concurrency architecture.

## Guidance Summary

1. **Actor as façade**: Retain `SwiftFTR` as a lightweight actor (configuration, caches, cancellation), but delegate heavy operations to `Sendable` session workers that execute off‑actor.
2. **Nonblocking helpers**: Wrap STUN and DNS networking in continuations or detached tasks so the actor never blocks on sockets.
3. **Swift 6.2 idioms**: Use `@concurrent` for pure helpers/readers, keep async code aligned with the caller’s context, and favour value types with explicit `Sendable` conformance.
4. **Cache actors**: Manage caches via actors or `ManagedCriticalState`, offering `@concurrent` read APIs while keeping writes serialized.
5. **Parallel multipath**: Run flow variations via task groups and stream results to consumers for faster feedback.
6. **Robust testing**: Expand concurrency stress coverage beyond ping, exercising cancellation, multipath batching, and race conditions.

## Execution Plan

### 1. Concurrency Audit (Design Preparation)
- Enumerate async entry points (`trace`, `traceClassified`, `discoverPaths`, `ping`, `testBufferbloat`).
- Document current isolation, blocking calls, and sendability concerns.
- Produce a short design note mapping the existing flow to the target session-based architecture.

### 2. Isolate Blocking Work
- Refactor STUN and DNS helpers to use `withCheckedThrowingContinuation` or `Task.detached` wrappers.
- Ensure `SwiftFTR` actor simply awaits these async helpers instead of executing synchronous I/O internally.

### 3. Session Extraction
- Introduce `TraceSession`, `ClassifiedSession`, and `PingSession` (`Sendable` structs/classes) to encapsulate socket operations.
- Modify `SwiftFTR.trace` / `traceClassified` to spawn sessions, pass shared caches/config, and await completion with existing cancellation hooks.

### 4. Cache Modernisation
- Replace `_ASNMemoryCache`’s locking with an actor or `ManagedCriticalState`, exposing read methods as `@concurrent`.
- Review `RDNSCache` for explicit `Sendable` conformance and potential `@concurrent` reads.

### 5. Multipath Parallelism & Streaming
- Rework `MultipathDiscovery` to use `withThrowingTaskGroup` to schedule batches of flow variations in parallel.
- Merge fingerprints via sendable state and optionally expose an `AsyncStream<DiscoveredPath>` for incremental consumption.
- Update CLI handling to accommodate streamed or batched results if beneficial.

### 6. API Polishing for Swift 6.2
- Annotate pure helper functions/closures with `@concurrent` and `@Sendable` as appropriate.
- Audit public types for `Sendable` conformance and document any `@unchecked Sendable` cases.
- Consider optional use of new Swift 6.2 primitives (`InlineArray`, `Span`) only if profiling suggests a win.
- Refresh DocC/README with the new concurrency story and requirements.

### 7. Testing Upgrades
- Add stress tests that launch multiple concurrent traces/classified traces, verifying bounded completion spread and responsive cancellation.
- Extend multipath tests to cover parallel batches and streaming behaviour.
- Integrate thread-sanitized builds (e.g., `swift test -Xswiftc -sanitize=thread`) into nightly or optional CI flows.

### 8. Documentation Refresh
- Update README and `docs/` guides with migration notes, Swift 6.2 minimum toolchain info, and concurrency best practices for consumers.
- Summarise expected behaviour changes (e.g., traceroutes now run in parallel) and how to opt out if necessary.

## Deliverables
- Design note capturing audit findings and architecture decisions.
- Refactored codebase with session workers, nonblocking helpers, modernised caches, and parallel multipath.
- Extended test suites covering new concurrency scenarios.
- Updated documentation reflecting the Swift 6.2-aligned architecture.
