# SwiftFTR development notes

Contributor guides and release-process records. The project-level index is in the
[root README](../../README.md#documentation).

## Guides
- [Testing guide](TESTING.md): test categories, environment gates, CI and self-hosted coverage, coverage reports and how to write network-safe tests. (updated 2026-11-21; update when: a test gate, test target or CI test job changes)
- [Code style](CODE_STYLE.md): swift-format usage and the intentional naming exceptions for CLI JSON fields, libFuzzer and SPI test helpers. (updated 2026-11-21; update when: a naming exception is added or removed, or format enforcement changes)

## Plans
- [HTTP probe production roadmap](HTTPProbe-Production-Roadmap.md): the product boundary, compatibility contract and six-PR sequence for exact-route HTTP probing over Network.framework. (updated 2026-11-21; update when: one of its PRs lands or exact-route HTTP becomes public API)
- [Concurrency unblocking plan](Concurrency-Unblocking-Plan.md): the 0.8.0-era plan for moving blocking work off the `SwiftFTR` actor and making ping, multipath and bufferbloat truly parallel. (updated 2026-11-21; update when: someone audits its deliverables against the code or archives it)

## Release records
- [0.14.0 release readiness](0.14.0-release-readiness.md): the 0.14.0 release gate, with its checks, live acceptance matrix across direct and VPN networks, and tag and publication steps. (updated 2026-11-21; update when: the owner decides to archive or remove release records)
- [0.8.0 release readiness](0.8.0-release-readiness.md): the 0.8.0 release status, test run and blocking items. (updated 2026-11-21; update when: the owner decides to archive or remove release records)
- [0.8.0 ping regressions](0.8.0-ping-regressions.md): debugging log of the 0.8.0 ping and bufferbloat test failures, the ICMP identifier diagnosis and the fixes. (updated 2026-11-21; update when: the owner decides to archive or remove release records)
