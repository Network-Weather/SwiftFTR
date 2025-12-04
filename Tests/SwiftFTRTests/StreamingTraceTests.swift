import SwiftFTR
import XCTest

@available(macOS 13.0, *)
final class StreamingTraceTests: XCTestCase {

  // MARK: - StreamingHop Type Tests

  func testStreamingHopCreation() {
    let hop = StreamingHop(
      ttl: 5,
      ipAddress: "192.168.1.1",
      rtt: 0.025,
      reachedDestination: false
    )

    XCTAssertEqual(hop.ttl, 5)
    XCTAssertEqual(hop.ipAddress, "192.168.1.1")
    XCTAssertEqual(hop.rtt, 0.025)
    XCTAssertFalse(hop.reachedDestination)
  }

  func testStreamingHopTimeout() {
    // Timeout placeholder has nil IP and RTT
    let timeout = StreamingHop(
      ttl: 3,
      ipAddress: nil,
      rtt: nil,
      reachedDestination: false
    )

    XCTAssertEqual(timeout.ttl, 3)
    XCTAssertNil(timeout.ipAddress)
    XCTAssertNil(timeout.rtt)
    XCTAssertFalse(timeout.reachedDestination)
  }

  func testStreamingHopEquality() {
    let hop1 = StreamingHop(ttl: 1, ipAddress: "1.1.1.1", rtt: 0.01, reachedDestination: true)
    let hop2 = StreamingHop(ttl: 1, ipAddress: "1.1.1.1", rtt: 0.01, reachedDestination: true)
    let hop3 = StreamingHop(ttl: 2, ipAddress: "1.1.1.1", rtt: 0.01, reachedDestination: true)

    XCTAssertEqual(hop1, hop2)
    XCTAssertNotEqual(hop1, hop3)
  }

  // MARK: - StreamingTraceConfig Tests

  func testDefaultConfig() {
    let config = StreamingTraceConfig()

    XCTAssertEqual(config.probeTimeout, 10.0)
    XCTAssertEqual(config.retryAfter, 4.0)
    XCTAssertTrue(config.emitTimeouts)
    XCTAssertEqual(config.maxHops, 40)
  }

  func testCustomConfig() {
    let config = StreamingTraceConfig(
      probeTimeout: 5.0,
      retryAfter: 2.0,
      emitTimeouts: false,
      maxHops: 20
    )

    XCTAssertEqual(config.probeTimeout, 5.0)
    XCTAssertEqual(config.retryAfter, 2.0)
    XCTAssertFalse(config.emitTimeouts)
    XCTAssertEqual(config.maxHops, 20)
  }

  func testConfigWithNoRetry() {
    let config = StreamingTraceConfig(
      probeTimeout: 5.0,
      retryAfter: nil,  // Disable retry
      emitTimeouts: true,
      maxHops: 30
    )

    XCTAssertEqual(config.probeTimeout, 5.0)
    XCTAssertNil(config.retryAfter)
    XCTAssertTrue(config.emitTimeouts)
  }

  func testStaticDefaultConfig() {
    let config = StreamingTraceConfig.default

    XCTAssertEqual(config.probeTimeout, 10.0)
    XCTAssertEqual(config.retryAfter, 4.0)
    XCTAssertTrue(config.emitTimeouts)
  }

  // MARK: - Streaming Trace Integration Tests

  func testStreamingTraceToLocalhost() async throws {
    let tracer = SwiftFTR()
    let config = StreamingTraceConfig(
      probeTimeout: 2.0,
      retryAfter: 1.0,
      emitTimeouts: true,
      maxHops: 3
    )

    var hops: [StreamingHop] = []

    for try await hop in tracer.traceStream(to: "127.0.0.1", config: config) {
      hops.append(hop)
    }

    // Localhost trace should complete (may or may not reach depending on system config)
    // At minimum, we should get either real hops or timeout placeholders
    XCTAssertFalse(hops.isEmpty, "Should have at least one hop (or timeout placeholder)")
  }

  func testStreamingTraceEmitsHopsProgressively() async throws {
    let tracer = SwiftFTR()
    let config = StreamingTraceConfig(
      probeTimeout: 5.0,
      retryAfter: 3.0,
      emitTimeouts: true,
      maxHops: 10
    )

    var hopTTLs: [Int] = []
    var firstHopTime: Date?

    for try await hop in tracer.traceStream(to: "1.1.1.1", config: config) {
      if firstHopTime == nil {
        firstHopTime = Date()
      }
      hopTTLs.append(hop.ttl)

      // Verify hops have valid TTL
      XCTAssertGreaterThanOrEqual(hop.ttl, 1)
      XCTAssertLessThanOrEqual(hop.ttl, config.maxHops)

      // Verify destination hop has reachedDestination=true
      if hop.ipAddress == "1.1.1.1" {
        XCTAssertTrue(hop.reachedDestination)
      }
    }

    XCTAssertFalse(hopTTLs.isEmpty, "Should have received at least one hop")

    // Verify we got hops (arrival order, not TTL order expected)
    let uniqueTTLs = Set(hopTTLs)
    XCTAssertEqual(uniqueTTLs.count, hopTTLs.count, "Each TTL should only appear once")
  }

  func testStreamingTraceArrivalOrder() async throws {
    // This test verifies hops arrive in network order, not necessarily TTL order
    let tracer = SwiftFTR()
    let config = StreamingTraceConfig(
      probeTimeout: 5.0,
      retryAfter: 3.0,
      emitTimeouts: false,  // Only get actual responses
      maxHops: 15
    )

    var arrivalOrder: [Int] = []

    for try await hop in tracer.traceStream(to: "1.1.1.1", config: config) {
      arrivalOrder.append(hop.ttl)
    }

    // Arrival order may differ from TTL order due to network timing
    // Nearby hops often arrive first, but far hops might arrive before middle hops
    // The key is that we DON'T enforce TTL ordering in the stream

    if arrivalOrder.count > 1 {
      // Verify all TTLs are unique
      let uniqueTTLs = Set(arrivalOrder)
      XCTAssertEqual(uniqueTTLs.count, arrivalOrder.count, "Each TTL should only appear once")

      // Sort for comparison
      let sortedTTLs = arrivalOrder.sorted()
      // We just verify we got valid data - arrival order may or may not match TTL order
      XCTAssertEqual(sortedTTLs.first, arrivalOrder.min())
      XCTAssertEqual(sortedTTLs.last, arrivalOrder.max())
    }
  }

  func testStreamingTraceWithTimeoutPlaceholders() async throws {
    let tracer = SwiftFTR()
    let config = StreamingTraceConfig(
      probeTimeout: 3.0,  // Short timeout to force timeouts
      retryAfter: 2.0,
      emitTimeouts: true,  // Emit timeout placeholders
      maxHops: 20
    )

    var receivedHops: [StreamingHop] = []
    var timeoutHops: [StreamingHop] = []

    for try await hop in tracer.traceStream(to: "1.1.1.1", config: config) {
      if hop.ipAddress == nil && hop.rtt == nil {
        timeoutHops.append(hop)
      } else {
        receivedHops.append(hop)
      }
    }

    // Should have at least some hops (either real or timeouts)
    let totalHops = receivedHops.count + timeoutHops.count
    XCTAssertGreaterThan(totalHops, 0, "Should have at least one hop")

    // Timeout hops should have nil IP and RTT
    for timeout in timeoutHops {
      XCTAssertNil(timeout.ipAddress)
      XCTAssertNil(timeout.rtt)
      XCTAssertFalse(timeout.reachedDestination)
    }
  }

  func testStreamingTraceWithoutTimeoutPlaceholders() async throws {
    let tracer = SwiftFTR()
    let config = StreamingTraceConfig(
      probeTimeout: 5.0,
      retryAfter: 3.0,
      emitTimeouts: false,  // NO timeout placeholders
      maxHops: 15
    )

    var hops: [StreamingHop] = []

    for try await hop in tracer.traceStream(to: "1.1.1.1", config: config) {
      hops.append(hop)
      // With emitTimeouts=false, every hop should have an IP
      XCTAssertNotNil(hop.ipAddress, "Without emitTimeouts, all hops should have IP addresses")
      XCTAssertNotNil(hop.rtt, "Without emitTimeouts, all hops should have RTT")
    }

    // Should have at least some real hops
    XCTAssertGreaterThan(hops.count, 0, "Should have received at least one real hop")
  }

  func testStreamingTraceRTTValues() async throws {
    let tracer = SwiftFTR()
    let config = StreamingTraceConfig(
      probeTimeout: 5.0,
      retryAfter: 3.0,
      emitTimeouts: false,
      maxHops: 10
    )

    for try await hop in tracer.traceStream(to: "1.1.1.1", config: config) {
      if let rtt = hop.rtt {
        // RTT should be positive and reasonable (< 10 seconds)
        XCTAssertGreaterThan(rtt, 0, "RTT should be positive")
        XCTAssertLessThan(rtt, 10.0, "RTT should be less than 10 seconds")
      }
    }
  }

  // MARK: - RTT Timing Tests

  func testStreamingHopRTTIsPositive() async throws {
    // Verify that RTT values are always positive and measured correctly
    let tracer = SwiftFTR()
    let config = StreamingTraceConfig(
      probeTimeout: 5.0,
      retryAfter: nil,  // Disable retry to test simple case
      emitTimeouts: false,
      maxHops: 10
    )

    var hops: [StreamingHop] = []
    for try await hop in tracer.traceStream(to: "1.1.1.1", config: config) {
      hops.append(hop)
    }

    // All hops with responses should have positive RTT
    for hop in hops {
      if let rtt = hop.rtt {
        XCTAssertGreaterThan(rtt, 0, "RTT should be positive for TTL \(hop.ttl)")
        XCTAssertLessThan(rtt, 5.0, "RTT should be less than probe timeout")
      }
    }
  }

  func testStreamingHopRTTReflectsNetworkLatency() async throws {
    // Verify RTT values are reasonable network latencies, not total wait times
    let tracer = SwiftFTR()
    let config = StreamingTraceConfig(
      probeTimeout: 10.0,
      retryAfter: 4.0,  // Enable retry
      emitTimeouts: false,
      maxHops: 15
    )

    var hops: [StreamingHop] = []
    for try await hop in tracer.traceStream(to: "1.1.1.1", config: config) {
      hops.append(hop)
    }

    // For responsive hops, RTT should be much less than the retry threshold
    // (unless we're on a very slow network)
    let fastHops = hops.filter { $0.rtt != nil && $0.rtt! < 1.0 }
    XCTAssertGreaterThan(
      fastHops.count, 0,
      "Should have at least one hop with RTT < 1s (indicates proper timing, not wait time)")

    // Even slow hops shouldn't report RTT equal to retry time unless genuinely slow
    for hop in hops {
      if let rtt = hop.rtt {
        // RTT should reflect actual network time, not be artificially inflated
        // A genuinely slow hop might take 4+ seconds, but most should be faster
        if rtt >= 4.0 {
          // This is fine - could be a genuinely slow router or retry scenario
          // Just verify it's not impossibly slow
          XCTAssertLessThan(rtt, 10.0, "RTT should be less than total timeout")
        }
      }
    }
  }

  func testEachTTLEmittedOnlyOnce() async throws {
    // Verify that even with retries, each TTL is emitted at most once
    let tracer = SwiftFTR()
    let config = StreamingTraceConfig(
      probeTimeout: 8.0,
      retryAfter: 3.0,  // Short retry to trigger retries
      emitTimeouts: true,
      maxHops: 20
    )

    var ttlCounts: [Int: Int] = [:]
    for try await hop in tracer.traceStream(to: "1.1.1.1", config: config) {
      ttlCounts[hop.ttl, default: 0] += 1
    }

    // Each TTL should appear exactly once
    for (ttl, count) in ttlCounts {
      XCTAssertEqual(count, 1, "TTL \(ttl) should be emitted exactly once, got \(count)")
    }
  }

  func testRTTMeasuredFromCorrectProbe() async throws {
    // This test verifies RTT is measured from probe send time, not stream start
    // We can't directly test retry scenarios without mocking, but we can verify
    // that RTT values are consistent with being measured from individual probes

    let tracer = SwiftFTR()
    let config = StreamingTraceConfig(
      probeTimeout: 5.0,
      retryAfter: nil,
      emitTimeouts: false,
      maxHops: 10
    )

    let startTime = Date()
    var hops: [(hop: StreamingHop, receivedAt: Date)] = []

    for try await hop in tracer.traceStream(to: "1.1.1.1", config: config) {
      hops.append((hop, Date()))
    }

    guard !hops.isEmpty else {
      XCTFail("Should have received at least one hop")
      return
    }

    // The RTT reported for each hop should be less than or approximately equal to
    // the time elapsed since we started iterating the stream
    // (accounting for the fact that probes are sent before we start iterating)
    for (hop, receivedAt) in hops {
      if let rtt = hop.rtt {
        let wallClockElapsed = receivedAt.timeIntervalSince(startTime)
        // RTT should be <= wall clock time (with some tolerance for timing jitter)
        // This verifies RTT is measured from probe send, not from some arbitrary start
        XCTAssertLessThanOrEqual(
          rtt, wallClockElapsed + 0.5,  // 500ms tolerance
          "RTT (\(rtt)s) should not exceed wall clock elapsed (\(wallClockElapsed)s) for TTL \(hop.ttl)"
        )
      }
    }
  }

  // MARK: - Cancellation Tests

  func testStreamingTraceCancellation() async throws {
    let tracer = SwiftFTR()
    let config = StreamingTraceConfig(
      probeTimeout: 10.0,
      retryAfter: 5.0,
      emitTimeouts: true,
      maxHops: 30
    )

    // Use actor to track hop count safely across concurrency boundaries
    actor HopCounter {
      var count = 0
      func increment() { count += 1 }
      func getCount() -> Int { count }
    }

    let counter = HopCounter()
    let task = Task {
      for try await _ in tracer.traceStream(to: "1.1.1.1", config: config) {
        await counter.increment()
        if await counter.getCount() >= 3 {
          // Cancel after receiving 3 hops
          throw CancellationError()
        }
      }
    }

    do {
      try await task.value
      XCTFail("Should have thrown cancellation error")
    } catch is CancellationError {
      // Expected
      let finalCount = await counter.getCount()
      XCTAssertGreaterThanOrEqual(
        finalCount, 3, "Should have received at least 3 hops before cancel")
    }
  }

  // MARK: - Error Handling Tests

  func testStreamingTraceInvalidHost() async throws {
    let tracer = SwiftFTR()

    do {
      for try await _ in tracer.traceStream(to: "invalid-hostname-xyz.nonexistent") {
        XCTFail("Should not receive any hops for invalid host")
      }
      XCTFail("Should have thrown an error")
    } catch TracerouteError.resolutionFailed {
      // Expected
    }
  }
}
