# SwiftFTR Improvement Plan

## Current Assessment
SwiftFTR is a well-architected Swift library (~2,255 lines) for parallel traceroute operations on macOS. It leverages ICMP datagram sockets without requiring sudo privileges and includes advanced features like ASN classification and STUN-based public IP discovery.

**Strengths:**
- Clean async/await API with parallel probe sending
- No root privileges required (uses SOCK_DGRAM on macOS)
- ASN-based route classification with hole-filling
- Fuzzing infrastructure and basic test coverage
- Good separation of concerns across modules

**Areas for Improvement:**

## 1. Fix Compilation Warnings & Hygiene (Priority: High)
- Keep `String(cString:)` for C NUL-terminated buffers. Use the pointer-based initializer via `withUnsafeBufferPointer` to avoid the deprecation warning on the array-based overload (still correct for `inet_ntop`/`getnameinfo`). Optionally use `String(validatingUTF8:)` where failure should be tolerated.
- Fix unused-result warnings for `withUnsafePointer`/`setsockopt` calls in tests/fuzzing by assigning to `_` explicitly where appropriate.
- In the CLI target (`Sources/swift-ftr/main.swift`), replace `@_implementationOnly import Darwin` with plain `import Darwin`. Reserve `@_implementationOnly` for library-only dependencies when you need to hide them from the public interface; no need to enable library evolution unless you want a stable ABI.

## 2. Enhance Test Coverage (Priority: High)
- **Current:** Only 2 basic tests (ICMP parsing, classification)
- **Add:** XCTest integration for proper test discovery and IDE support
- **Add:** Async traceroute method testing with mock network conditions
- **Add:** DNS resolution, STUN client, and ASN resolver testing
- **Add:** Error handling and edge case coverage
- **Add:** Performance benchmarks for large-scale tracing

## 3. Performance Optimizations (Priority: High)
- **Monotonic timing:** Use a monotonic clock for RTT (e.g., `clock_gettime(CLOCK_MONOTONIC, ...)`) instead of `CFAbsoluteTimeGetCurrent()` to avoid wall-clock jumps.
- **Memory:** Continue using `UnsafeRawBufferPointer`; avoid copies by slicing received buffers (already in place).
- **Allocation:** Reuse receive buffers in hot loops (hoist `var buf = [UInt8](repeating: 0, count: 2048)` out of inner loops) and reuse the ICMP echo packet buffer, updating only id/seq/checksum.
- **Concurrency:** Use structured concurrency (TaskGroup) for parallel reverse DNS (when enabled) and any per-hop post-processing. ASN TXT lookups are already batched; keep them batched.
- **Caching:** Add a small in-memory cache for ASN results keyed by IPv4. Optional LRU with size cap.
- **SIMD:** Defer SIMD parsing; returns are negligible compared to syscalls. Focus on zero-copy and buffer reuse first.

## 4. API Enhancements (Priority: Medium)
- **Progress tracking:** Provide `AsyncSequence<TraceHop>` (or event callbacks) to stream hop updates in real time.
- **Flexibility:** Support multiple probes per TTL for reliability (track by sequence and aggregate into per-TTL results).
- **Platform expansion:** Add IPv6 (ICMPv6) support with separate code paths and capability checks.
- **Resilience:** Configurable retries, per-TTL probe timeouts, and overall deadline controls.
- **Cancellation:** Check `Task.isCancelled` in loops and close the socket promptly to abort cleanly.

## 5. Documentation Improvements (Priority: Medium)
- **API docs:** Add comprehensive DocC documentation for all public types
- **Guides:** Create detailed usage examples and integration guides
- **Error handling:** Document all error cases and recovery strategies  
- **Algorithms:** Explain complex classification and hole-filling logic

## 6. Code Quality Enhancements (Priority: Medium)
- **Linting:** Add SwiftLint configuration for consistent code style
- **Error types:** Create detailed error types with actionable recovery suggestions
- **Observability:** Integrate `os_log` for debugging and metrics collection
- **Modularity:** Refactor large functions (e.g., Traceroute.swift hot loop) into smaller, testable units
- **Helper reuse:** Deduplicate `isPrivateIPv4`/`isCGNATIPv4` by keeping them in `Utils.swift` and removing CLI duplicates.

## 7. Package Infrastructure (Priority: Low)
- **Legal:** Add proper LICENSE file (MIT or Apache 2.0 recommended)
- **Testing:** Migrate to dedicated XCTest target structure (`Tests/SwiftFTRTests`), keep `ptrtests` only if needed.
- **CI/CD:** GitHub Actions on macOS 13/14 with Swift 6. Set `PTR_SKIP_STUN=1` by default for tests; add a network-allowed job separately if desired.
- **Discovery:** Add Swift Package Index compatibility and badges pointing at the new `SwiftFTR` repo.
- **Distribution:** Consider CocoaPods/Carthage only if requested; SwiftPM is sufficient for now.

## 8. Advanced Features (Priority: Low)
- **Network analysis:** MTU discovery and path MTU detection
- **Statistics:** Packet loss rates and jitter calculations  
- **Monitoring:** Path change detection over time
- **Export:** Support for standard formats (JSON schema, CSV, pcap)
- **Visualization:** Integration hooks for network topology mapping

## Operational Considerations
- **External services:** Team Cymru WHOIS may rate-limit; keep strict timeouts and rely on environment toggles (`PTR_SKIP_STUN`, `PTR_PUBLIC_IP`, optional `PTR_DNS`) to ensure tests and CI do not require network access.
- **IPv4 scope:** Library is currently IPv4/macOS-focused. Document this clearly until IPv6 support is added.

## Implementation Approach
1. **Phase 1:** Address warnings/hygiene; add LICENSE; basic XCTest scaffolding.
2. **Phase 2:** Performance optimizations (monotonic clock, buffer reuse, caching) and expand test coverage.
3. **Phase 3:** API enhancements (AsyncSequence progress, multi-probe, cancellation) and documentation (DocC).
4. **Phase 4:** Advanced features and ecosystem integration (CI, SPI, potential distributions).

## PR Roadmap (Concrete Steps)
- **PR 1 — Hygiene & Baseline**
  - Switch RTT timing to monotonic clock.
  - Reuse receive buffers; dedupe IPv4 helper functions; remove `@_implementationOnly` in CLI.
  - Add LICENSE (MIT or Apache-2.0).
- **PR 2 — Tests**
  - Add XCTest target with async tests; create `MockASNResolver` and default env `PTR_SKIP_STUN=1`.
  - Add a numeric-IPv4 trace test to validate timeouts without network dependencies.
- **PR 3 — Perf & API**
  - Add simple in-memory ASN cache; optional concurrent RDNS when enabled.
  - Introduce progress `AsyncSequence` and cancellation checks.
- **PR 4 — Docs & CI**
  - Add DocC and README snippets; add SPI badges and GitHub Actions matrix for macOS 13/14.

This plan will take SwiftFTR from a functional prototype to a production-ready, high-performance Swift networking library suitable for larger applications and monitoring tools.
