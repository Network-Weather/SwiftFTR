import Foundation
import Testing

@testable import SwiftFTR

/// How long a cancelled stream may take to end. Each stream here has a probe timeout that outlasts
/// it, so a stream that ends within it was ended by its cancellation, and one that is not trips it.
private let lifecycleWatchdog: TimeInterval = 20

@Suite("Streaming Trace Lifecycle Tests")
struct StreamingLifecycleTests {
  @Test("TraceHandle invokes an installed cancellation handler exactly once")
  func traceHandleCancellationHandler() async {
    let handle = TraceHandle()
    let counter = LockedCounter()

    await handle.installCancellationHandler {
      counter.increment()
    }
    await handle.cancel()
    await handle.cancel()

    #expect(counter.value == 1)
  }

  @Test("A handler installed after cancellation runs immediately")
  func lateCancellationHandler() async {
    let handle = TraceHandle()
    let counter = LockedCounter()

    await handle.cancel()
    await handle.installCancellationHandler {
      counter.increment()
    }

    #expect(counter.value == 1)
  }

  @Test("Clearing an older registration ID does not clear the next phase's handler")
  func handlerRegistrationIsolation() async {
    let handle = TraceHandle()
    let counterA = LockedCounter()
    let counterB = LockedCounter()

    // Phase 1 installs handler A
    let idA = await handle.installCancellationHandler {
      counterA.increment()
    }
    #expect(await handle.hasCancellationHandler)

    // Phase 2 installs handler B
    _ = await handle.installCancellationHandler {
      counterB.increment()
    }

    // Phase 1 cleanup attempts to clear its handler using idA
    await handle.clearCancellationHandler(id: idA)

    // Handler B must NOT have been cleared
    #expect(await handle.hasCancellationHandler)

    await handle.cancel()
    #expect(counterA.value == 0)
    #expect(counterB.value == 1)
  }

  @Test("networkChanged stops an active streaming receive operation", .timeLimit(.minutes(1)))
  func networkChangeStopsStreamingOperation() async throws {
    // A loopback peer that never answers, so the stream stays in its receive window until it is
    // cancelled. A real first hop can answer within a millisecond and end the stream first.
    let network = try FakeICMPNetwork { _ in [] }
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 1, maxWaitMs: 1_000, noReverseDNS: true))
    let streamConfig = StreamingTraceConfig(
      probeTimeout: 3 * lifecycleWatchdog,
      retryAfter: nil,
      emitTimeouts: false,
      maxHops: 1
    )

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
      try #require(receiving, "The streaming receive operation should start before cancellation")

      // The watchdog covers the request as well as the stream's end and its unregistering, so a
      // network change that is slow to cancel the stream fails as surely as one that never does.
      let ((outcome, unregistered), _) = try await measure(within: lifecycleWatchdog) {
        await tracer.networkChanged()
        let outcome = await consumer.result
        return (outcome, await waitUntil { await tracer.activeTraces.isEmpty })
      }
      switch outcome {
      case .success:
        Issue.record("the stream ended normally instead of reporting the network change")
      case .failure(TracerouteError.cancelled):
        break  // The tracer ended the live stream.
      case .failure(let error):
        Issue.record("the stream threw \(error)")
      }
      #expect(unregistered)
    }
  }

  @Test("Ending iteration cancels the streaming producer", .timeLimit(.minutes(1)))
  func endingIterationCancelsProducer() async throws {
    // A loopback peer that never answers, so the stream stays in its receive window until it is
    // cancelled. A real first hop can answer within a millisecond and end the stream first.
    let network = try FakeICMPNetwork { _ in [] }
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig(maxHops: 1, maxWaitMs: 1_000, noReverseDNS: true))
    let streamConfig = StreamingTraceConfig(
      probeTimeout: 3 * lifecycleWatchdog,
      retryAfter: nil,
      emitTimeouts: false,
      maxHops: 1
    )

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
      try #require(receiving, "The streaming receive operation should start before cancellation")

      // The watchdog covers the cancellation, the consumer's return and the producer's unregistering.
      let (unregistered, _) = try await measure(within: lifecycleWatchdog) {
        consumer.cancel()
        _ = await consumer.result
        return await waitUntil { await tracer.activeTraces.isEmpty }
      }
      #expect(unregistered)
    }
  }

  /// Whether `condition` holds within ``lifecycleWatchdog``.
  private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
  ) async -> Bool {
    await eventually(within: lifecycleWatchdog) { await condition() }
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}
