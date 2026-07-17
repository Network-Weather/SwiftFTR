import Foundation
import Testing

@testable import SwiftFTR

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

  @Test("networkChanged stops an active streaming receive operation", .timeLimit(.minutes(1)))
  func networkChangeStopsStreamingOperation() async throws {
    let tracer = SwiftFTR(
      config: SwiftFTRConfig(maxHops: 1, maxWaitMs: 1_000, noReverseDNS: true))
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
    try #require(receiving, "The streaming receive operation should start before cancellation")

    let started = ContinuousClock.now
    await tracer.networkChanged()

    do {
      _ = try await consumer.value
    } catch is CancellationError {
      // AsyncSequence cancellation may surface as CancellationError.
    } catch TracerouteError.cancelled {
      // The receive operation reports the library's cancellation error.
    }

    let unregistered = await waitUntil { await tracer.activeTraces.isEmpty }
    #expect(unregistered)
    #expect(started.duration(to: .now) < .seconds(1))
  }

  @Test("Ending iteration cancels the streaming producer", .timeLimit(.minutes(1)))
  func endingIterationCancelsProducer() async throws {
    let tracer = SwiftFTR(
      config: SwiftFTRConfig(maxHops: 1, maxWaitMs: 1_000, noReverseDNS: true))
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
    try #require(receiving, "The streaming receive operation should start before cancellation")

    let started = ContinuousClock.now
    consumer.cancel()
    _ = try? await consumer.value

    let unregistered = await waitUntil { await tracer.activeTraces.isEmpty }
    #expect(unregistered)
    #expect(started.duration(to: .now) < .seconds(1))
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
