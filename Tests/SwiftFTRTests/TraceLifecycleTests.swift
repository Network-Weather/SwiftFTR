import Foundation
import Testing

@testable import SwiftFTR

/// How long a cancelled stream may take to end, and how long a condition may take to hold. The
/// stream's probe timeout outlasts it, so a stream that ends within it was ended by its
/// cancellation, and one that is not trips it.
private let lifecycleWatchdog: TimeInterval = 20

@Suite("Trace Lifecycle and Options Tests")
struct TraceLifecycleTests {
  @Test("cancelActiveTraces cancels active trace while preserving caches", .timeLimit(.minutes(1)))
  func cancelActiveTracesPreservesCaches() async throws {
    // Reverse DNS answers from a local stub, so populating the cache sends no query.
    let tracer = offlineTracer(
      SwiftFTRConfig(maxHops: 1, maxWaitMs: 1_000, noReverseDNS: false),
      rdns: RDNSCache { _, _ in .answer("one.one.one.one") }
    )

    // Populate rDNS cache with an entry
    #expect(await tracer.rdnsCache.lookup("1.1.1.1") == "one.one.one.one")
    #expect(await tracer.rdnsCache.count == 1)

    // Set a cached public IP directly or via effective discovery
    let _ = await tracer.effectivePublicIPv4 { "9.9.9.10" }
    #expect(await tracer.publicIP(for: .v4)?.address == "9.9.9.10")

    let streamConfig = StreamingTraceConfig(
      probeTimeout: 3 * lifecycleWatchdog,
      retryAfter: nil,
      emitTimeouts: false,
      maxHops: 1
    )

    // A loopback peer that never answers, so the stream stays in its receive window until it is
    // cancelled. A real first hop can answer within a millisecond and end the stream first.
    let network = try FakeICMPNetwork { _ in [] }
    defer { network.stop() }
    try await network.install {
      let consumer = Task {
        var iterator = tracer.traceStream(
          to: "fake.test", config: streamConfig
        ).makeAsyncIterator()
        return try await iterator.next()
      }

      let receiving = await waitUntil {
        // Probes sent, so past resolution, whose wait also installs a handler.
        guard network.probes.value > 0, let handle = await tracer.activeTraces.first else {
          return false
        }
        return await handle.hasCancellationHandler
      }
      #expect(receiving, "The streaming trace should start before cancellation")

      // The probe timeout outlasts the watchdog, so a stream that ends was ended by the
      // cancellation. The watchdog covers the cancellation request too, so a request that is
      // slow to cancel the stream fails as surely as one that never does.
      let ((outcome, unregistered), _) = try await measure(within: lifecycleWatchdog) {
        await tracer.cancelActiveTraces()
        let outcome = await consumer.result
        return (outcome, await waitUntil { await tracer.activeTraces.isEmpty })
      }
      if case .failure(let error) = outcome {
        var cancelled = error is CancellationError
        if case TracerouteError.cancelled = error { cancelled = true }
        #expect(cancelled, "threw \(error)")
      }
      #expect(unregistered)
    }

    // Verify caches are still intact!
    #expect(await tracer.publicIP(for: .v4)?.address == "9.9.9.10")
    #expect(await tracer.rdnsCache.count == 1)

    // Now call networkChanged() and verify it DOES clear the public IP and rDNS
    await tracer.networkChanged()
    #expect(await tracer.publicIP(for: .v4)?.address == nil)
    #expect(await tracer.rdnsCache.count == 0)
  }

  @Test("TraceOptions maxHops bounds trace hops")
  func traceOptionsBoundsMaxHops() async throws {
    let tracer = SwiftFTR(
      config: SwiftFTRConfig(maxHops: 30, maxWaitMs: 100, noReverseDNS: true)
    )

    // Trace to loopback with maxHops: 2
    let result = try await tracer.trace(to: "127.0.0.1", options: TraceOptions(maxHops: 2))
    #expect(result.maxHops == 2)
    #expect(result.hops.count <= 2)
  }

  @Test("TraceOptions rejects out-of-range maxHops before network work")
  func traceOptionsRejectsOutOfRange() async {
    let tracer = SwiftFTR(config: SwiftFTRConfig(noReverseDNS: true))

    let invalidOptions: [(name: String, options: TraceOptions)] = [
      ("zero hops", TraceOptions(maxHops: 0)),
      ("negative hops", TraceOptions(maxHops: -1)),
      ("too many hops", TraceOptions(maxHops: 256)),
      ("extreme hops", TraceOptions(maxHops: 1_000)),
    ]

    for (name, options) in invalidOptions {
      do {
        _ = try await tracer.trace(to: "127.0.0.1", options: options)
        Issue.record("\(name) should have thrown invalidConfiguration")
      } catch TracerouteError.invalidConfiguration(let reason) {
        #expect(reason.contains("maxHops must be in 1...255"))
      } catch {
        Issue.record("\(name) threw unexpected error: \(error)")
      }

      do {
        _ = try await tracer.traceClassified(to: "127.0.0.1", options: options)
        Issue.record("\(name) should have thrown invalidConfiguration for classified trace")
      } catch TracerouteError.invalidConfiguration(let reason) {
        #expect(reason.contains("maxHops must be in 1...255"))
      } catch {
        Issue.record("\(name) threw unexpected error: \(error)")
      }
    }
  }

  @Test("TraceOptions defaults to nil maxHops")
  func traceOptionsDefaultInit() {
    let options = TraceOptions()
    #expect(options.maxHops == nil)
  }

  @Test("cancelActiveTraces cancels in-flight classified trace")
  func cancelActiveTracesCancelsClassifiedTrace() async throws {
    // A loopback peer that never answers, with a receive window that outlasts the watchdog, so the
    // trace is still probing when it is cancelled and only the cancellation can end it in time.
    // Public-IP discovery, reverse DNS and ASN lookups are local substitutes.
    let network = try FakeICMPNetwork { _ in [] }
    defer { network.stop() }
    let tracer = offlineTracer(
      SwiftFTRConfig(
        maxHops: 30,
        maxWaitMs: Int(3 * lifecycleWatchdog * 1_000),
        enableLogging: false,
        noReverseDNS: false
      )
    )

    try await network.install {
      let task = Task {
        try await tracer.traceClassified(to: "fake.test")
      }

      let receiving = await waitUntil {
        // Probes sent, so past resolution, whose wait also installs a handler.
        guard network.probes.value > 0, let handle = await tracer.activeTraces.first else {
          return false
        }
        return await handle.hasCancellationHandler
      }
      #expect(receiving, "The classified trace should reach its receive window before cancellation")
      #expect(
        await waitUntil { network.probes.value > 0 },
        "The classified trace should have sent its probes")

      let (outcome, _) = try await measure(within: lifecycleWatchdog) {
        await tracer.cancelActiveTraces()
        return await task.result
      }
      switch outcome {
      case .success:
        Issue.record("traceClassified should have thrown cancelled")
      case .failure(TracerouteError.cancelled):
        break  // Expected
      case .failure(let error):
        Issue.record("Unexpected error from cancelled traceClassified: \(error)")
      }
    }

    let unregistered = await waitUntil { await tracer.activeTraces.isEmpty }
    #expect(unregistered)
  }

  final class HangingASNResolver: ASNResolver, @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)

    /// Whether the resolver was invoked within `limit` seconds.
    func waitUntilStarted(within limit: TimeInterval) -> Bool {
      started.wait(timeout: .now() + limit) == .success
    }

    func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
      started.signal()
      // Suspends indefinitely, simulating an unresponsive resolver that ignores its timeout
      while true {
        try await Task.sleep(nanoseconds: 1_000_000_000)
      }
    }
  }

  @Test("cancelActiveTraces interrupts ASN enrichment when resolver is suspended")
  func cancelActiveTracesInterruptsASNEnrichment() async throws {
    let resolver = HangingASNResolver()
    let tracer = SwiftFTR(
      config: SwiftFTRConfig(
        maxHops: 1,
        maxWaitMs: 100,
        // Configured, so classification reaches the resolver without public-IP discovery.
        publicIP: "9.9.9.10",
        enableLogging: false,
        noReverseDNS: true
      )
    )

    let task = Task {
      try await tracer.traceClassified(to: "127.0.0.1", resolver: resolver)
    }
    // A trace still waiting when the test gives up must not outlive it; the resolver ends when
    // cancelled.
    defer { task.cancel() }

    // Wait until the resolver is actively invoked during the enrichment phase. Bounded: a trace
    // that fails before classification never invokes it, and must fail this test, not hang it.
    let started = await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: resolver.waitUntilStarted(within: 10))
      }
    }
    guard started else {
      // Not joined: a trace stuck before the resolver may not end even when cancelled.
      task.cancel()
      Issue.record("the resolver was not invoked within 10 seconds")
      return
    }
    #expect(await !tracer.activeTraces.isEmpty, "the trace was no longer running in enrichment")

    // Cancel while classifier.classify() is actively awaiting the suspended resolver. The resolver
    // never returns, so a trace that ends was ended by the cancellation. The watchdog covers the
    // cancellation request and the trace's end, so a cancellation that does not reach the trace
    // fails the test instead of hanging the run.
    let (outcome, _) = try await measure(within: lifecycleWatchdog) {
      await tracer.cancelActiveTraces()
      return await task.result
    }
    switch outcome {
    case .failure(TracerouteError.cancelled):
      break  // Interrupted rather than waiting on the hanging resolver.
    case .failure(let error):
      Issue.record("Unexpected error from cancelled traceClassified: \(error)")
    case .success:
      Issue.record("traceClassified should have thrown cancelled during ASN enrichment")
    }

    let unregistered = await waitUntil { await tracer.activeTraces.isEmpty }
    #expect(unregistered)
  }

  /// Whether `condition` holds within ``lifecycleWatchdog``.
  private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
  ) async -> Bool {
    await eventually(within: lifecycleWatchdog) { await condition() }
  }
}
