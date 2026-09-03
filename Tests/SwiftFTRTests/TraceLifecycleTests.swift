import Foundation
import Testing

@testable import SwiftFTR

@Suite("Trace Lifecycle and Options Tests")
struct TraceLifecycleTests {
  @Test("cancelActiveTraces cancels active trace while preserving caches", .timeLimit(.minutes(1)))
  func cancelActiveTracesPreservesCaches() async throws {
    let tracer = SwiftFTR(
      config: SwiftFTRConfig(maxHops: 1, maxWaitMs: 1_000, noReverseDNS: false)
    )

    // Populate rDNS cache with an entry
    _ = await tracer.rdnsCache.lookup("1.1.1.1")

    // Set a cached public IP directly or via effective discovery
    let _ = await tracer.effectivePublicIPForClassification { "198.51.100.1" }
    #expect(await tracer.publicIP == "198.51.100.1")

    let streamConfig = StreamingTraceConfig(
      probeTimeout: 30,
      retryAfter: nil,
      emitTimeouts: false,
      maxHops: 1
    )

    let consumer = Task {
      var iterator = tracer.traceStream(
        to: "192.0.2.1", config: streamConfig
      ).makeAsyncIterator()
      return try await iterator.next()
    }

    let receiving = await waitUntil {
      guard let handle = await tracer.activeTraces.first else { return false }
      return await handle.hasCancellationHandler
    }
    #expect(receiving, "The streaming trace should start before cancellation")

    let started = ContinuousClock.now
    await tracer.cancelActiveTraces()

    do {
      _ = try await consumer.value
    } catch is CancellationError {
    } catch TracerouteError.cancelled {
    }

    let unregistered = await waitUntil { await tracer.activeTraces.isEmpty }
    #expect(unregistered)
    #expect(started.duration(to: .now) < .seconds(1))

    // Verify caches are still intact!
    #expect(await tracer.publicIP == "198.51.100.1")

    // Now call networkChanged() and verify it DOES clear the public IP and rDNS
    await tracer.networkChanged()
    #expect(await tracer.publicIP == nil)
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
    let tracer = SwiftFTR(
      config: SwiftFTRConfig(
        maxHops: 30,
        maxWaitMs: 1000,
        enableLogging: false,
        noReverseDNS: false
      )
    )

    let task = Task {
      try await tracer.traceClassified(to: "192.0.2.1")
    }

    let started = await waitUntil {
      await !tracer.activeTraces.isEmpty
    }
    #expect(started)

    await tracer.cancelActiveTraces()

    do {
      _ = try await task.value
      Issue.record("traceClassified should have thrown cancelled")
    } catch TracerouteError.cancelled {
      // Expected
    } catch {
      Issue.record("Unexpected error from cancelled traceClassified: \(error)")
    }

    let unregistered = await waitUntil { await tracer.activeTraces.isEmpty }
    #expect(unregistered)
  }

  private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
  ) async -> Bool {
    for _ in 0..<10_000 {
      if await condition() { return true }
      await Task.yield()
    }
    return false
  }
}
