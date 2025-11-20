# Concurrency Unblocking Plan

## Context
Tests in `Tests/SwiftFTRTests/ActorSchedulingTests.swift` expose two core problems:
1. `Task {}` spawned from the `SwiftFTR` actor inherits the actor executor, so receiver loops inside `PingExecutor` do not start until the actor finishes synchronous work (e.g., tight send loops or bufferbloat orchestration). This causes wall-clock latency to scale with `count` rather than RTT.
2. `withTaskGroup` inside `MultipathDiscovery` immediately re-enters the same actor, so “parallel” flow variations serialize. Multipath integration tests prove elapsed time ~= N × timeout instead of max(timeout).

We also see HTTP/DNS probes and bufferbloat helpers running blocking work on the actor. The goal is to isolate blocking I/O from actor executors and guarantee true parallelism.

## Deliverables
1. **Ping Isolation**
   - Move send/receive loops into detached tasks or an executor that never inherits the actor.
   - Maintain `ResponseCollector` thread safety and expose structured telemetry when `enableLogging` is true.
   - Extend `PingParallelismTests` with an actor-scoped scenario; tighten `PingIntegrationTests` expectations once behavior is stable.

2. **Bufferbloat Harness**
   - Ensure baseline/loaded ping phases use the isolated executor so load generation cannot stall measurement.
   - Add a regression test that runs the bufferbloat measurement from within a dedicated actor to confirm no serialization.

3. **Multipath Parallelism**
   - Refactor `MultipathDiscovery` so each flow runs on a non-actor executor (lightweight `SwiftFTR` clone or nonisolated helper).
   - Share caches (STUN, RDNS, ASN) across clones to avoid redundant network calls.
   - Tighten `MultipathTests.testPerformance` thresholds to reflect true parallel batching.

4. **Probe & Resolver Cleanup**
   - Wrapper functions for STUN/DNS/HTTP/TCP/UDP probes should either use detached tasks or `withCheckedContinuation` over non-blocking sockets.
   - Improve `ProbeConcurrencyTests` reliability (e.g., favor HTTPS endpoints or local fixtures).

5. **Verification & Release Prep**
   - Re-run `swift test -c debug` with and without `SKIP_NETWORK_TESTS`, capture timing deltas, and update release notes / README if CLI behavior changes.
   - Commit work in logical chunks on the feature branch, documenting rationale in each commit message.

6. **Executor & Annotation Audit (Swift 6.2+)**
   - Tag every async entrypoint that should run on a non-call-site executor with `@concurrent` (`trace`, `traceClassified`, `discoverPaths`, `testBufferbloat`, probe APIs, DNS queries). This both documents intent and allows the runtime to schedule them off the actor thread.
   - Introduce `NetworkTestGate` for the integration tests so timing-sensitive suites acquire exclusive access instead of racing each other; keep their thresholds strict (e.g., PingParallelism spread <0.6s).
   - Instrument and refactor any remaining actor-isolated heavy work (notably `performTrace`, `traceClassifiedWithFlowID`, `_testBufferbloat`, and `MultipathDiscovery`) so the actor only guards shared state while detached helpers handle sockets, URLSession load generation, etc.

## Risks & Mitigations
- **Socket ownership:** Detached tasks must close sockets deterministically; use `withTaskCancellationHandler` and `TaskGroup` cancellation.
- **Backwards compatibility:** JSON stats must remain unchanged; tests ensure no API regression.
- **Flaky network tests:** Allow fallbacks or skip conditions for unreachable hosts, but keep the new actor-scheduling tests enabled since they are deterministic.
