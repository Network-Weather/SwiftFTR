import SwiftFTR
import XCTest

final class StressAndEdgeCaseTests: XCTestCase {

  private func requireNetworkTests() throws {
    try XCTSkipIf(
      ProcessInfo.processInfo.environment["SKIP_NETWORK_TESTS"] != nil,
      "Live network tests are disabled by SKIP_NETWORK_TESTS")
  }

  // MARK: - Stress Tests

  func testRapidSequentialTraces() async throws {
    try requireNetworkTests()

    let config = SwiftFTRConfig(maxHops: 3, maxWaitMs: 500)
    let tracer = SwiftFTR(config: config)

    // Run 10 traces in rapid succession
    for i in 1...10 {
      let result = try await tracer.trace(to: "1.1.1.1")
      XCTAssertFalse(result.hops.isEmpty, "Trace \(i) should have hops")
      // Allow more tolerance for CI environments and network variance
      XCTAssertLessThanOrEqual(
        result.duration, 1.5, "Trace \(i) should complete within reasonable time")
    }
  }

  func testManyHopsWithTimeouts() async throws {
    try requireNetworkTests()

    // Use a destination likely to have timeouts in the middle
    let config = SwiftFTRConfig(maxHops: 30, maxWaitMs: 2000)
    let tracer = SwiftFTR(config: config)

    let result = try await tracer.trace(to: "1.0.0.1")

    // Check for proper handling of timeouts
    let timeouts = result.hops.filter { $0.ipAddress == nil }
    let responses = result.hops.filter { $0.ipAddress != nil }

    XCTAssertFalse(responses.isEmpty, "Should have at least some responses")
    // It's okay to have timeouts, just verify they're handled
    for hop in timeouts {
      XCTAssertNil(hop.rtt)
      XCTAssertFalse(hop.reachedDestination)
    }
  }

  // MARK: - Edge Cases

  func testZeroPayloadSize() async throws {
    try requireNetworkTests()

    let config = SwiftFTRConfig(
      maxHops: 3,
      payloadSize: 0  // Edge case: zero payload
    )
    let tracer = SwiftFTR(config: config)

    let result = try await tracer.trace(to: "1.1.1.1")
    XCTAssertEqual(result.destination, "1.1.1.1")
    XCTAssertEqual(result.maxHops, 3)
    XCTAssertFalse(result.hops.isEmpty)
  }

  func testSpecialIPAddresses() async throws {
    try requireNetworkTests()

    let config = SwiftFTRConfig(maxHops: 3, maxWaitMs: 500)
    let tracer = SwiftFTR(config: config)

    // Test broadcast address (should resolve but might not route)
    do {
      let result = try await tracer.trace(to: "255.255.255.255")
      XCTAssertEqual(result.destination, "255.255.255.255")
      XCTAssertLessThanOrEqual(result.hops.count, 3)
    } catch TracerouteError.resolutionFailed {
      // Some systems might reject broadcast address
    } catch TracerouteError.sendFailed {
      // GitHub Actions and other restricted environments block broadcast
    }

    // Test multicast address
    do {
      let multicastResult = try await tracer.trace(to: "224.0.0.1")
      XCTAssertEqual(multicastResult.destination, "224.0.0.1")
      XCTAssertLessThanOrEqual(multicastResult.hops.count, 3)
    } catch TracerouteError.sendFailed {
      // Some environments block multicast
    }
  }

  /// IPv6 traceroute now works (Stage 2). When v6 reachability is available,
  /// trace() to a v6 literal completes without throwing. Network-gated.
  func testIPv6TraceSucceeds() async throws {
    try requireNetworkTests()
    try XCTSkipUnless(IPv6Reachability.isAvailable(), "IPv6 connectivity is unavailable")

    let config = SwiftFTRConfig(maxHops: 10)
    let tracer = SwiftFTR(config: config)
    let result = try await tracer.trace(to: "2606:4700:4700::1111")
    XCTAssertEqual(result.destination, "2606:4700:4700::1111")
    XCTAssertGreaterThan(result.hops.count, 0)
  }

  func testDNSResolutionEdgeCases() async throws {
    try requireNetworkTests()

    let config = SwiftFTRConfig(maxHops: 3)
    let tracer = SwiftFTR(config: config)

    // Test empty string
    do {
      _ = try await tracer.trace(to: "")
      XCTFail("Should fail on empty hostname")
    } catch TracerouteError.resolutionFailed {
      // Expected.
    }

    // Test whitespace
    do {
      _ = try await tracer.trace(to: "   ")
      XCTFail("Should fail on whitespace hostname")
    } catch TracerouteError.resolutionFailed {
      // Expected.
    }

    // Test very long hostname
    let longHost = String(repeating: "a", count: 256) + ".com"
    do {
      _ = try await tracer.trace(to: longHost)
      XCTFail("Should fail on too long hostname")
    } catch TracerouteError.resolutionFailed {
      // Expected.
    }
  }

  func testPublicIPOverride() async throws {
    try requireNetworkTests()

    // Test various public IP formats
    let testIPs = [
      "1.2.3.4",
      "255.255.255.254",
      "100.64.0.1",  // CGNAT
    ]

    for ip in testIPs {
      let config = SwiftFTRConfig(
        maxHops: 3,
        publicIP: ip
      )
      let tracer = SwiftFTR(config: config)

      let classified = try await tracer.traceClassified(to: "1.1.1.1")
      XCTAssertEqual(classified.publicIP, ip, "Public IP override should be \(ip)")
    }
  }

  // MARK: - ASN Resolution Tests

  func testASNResolutionForKnownProviders() async throws {
    try requireNetworkTests()

    let config = SwiftFTRConfig(maxHops: 5)
    let tracer = SwiftFTR(config: config)

    // Test known providers
    let providers = [
      ("1.1.1.1", 13335),  // Cloudflare
      ("8.8.8.8", 15169),  // Google
      ("9.9.9.9", 19281),  // Quad9
    ]

    for (ip, expectedASN) in providers {
      let classified = try await tracer.traceClassified(to: ip)
      XCTAssertEqual(
        classified.destinationASN, expectedASN,
        "ASN for \(ip) should be \(expectedASN)")
    }
  }

  func testRepeatedClassificationReturnsConsistentDestinationASN() async throws {
    try requireNetworkTests()

    let config = SwiftFTRConfig(maxHops: 3)
    let tracer = SwiftFTR(config: config)

    let classified1 = try await tracer.traceClassified(to: "1.1.1.1")
    let classified2 = try await tracer.traceClassified(to: "1.1.1.1")

    XCTAssertEqual(classified1.destinationASN, classified2.destinationASN)
    XCTAssertNotNil(classified1.destinationASN)
    XCTAssertNotNil(classified2.destinationASN)
  }

  // MARK: - Timeout Behavior Tests

  func testTimeoutBehavior() async throws {
    try requireNetworkTests()

    let timeouts = [100, 500, 1000, 2000, 5000]

    for timeout in timeouts {
      let config = SwiftFTRConfig(
        maxHops: 10,
        maxWaitMs: timeout
      )
      let tracer = SwiftFTR(config: config)

      let start = Date()
      let result = try await tracer.trace(to: "1.1.1.1")
      let elapsed = Date().timeIntervalSince(start)

      // Verify timeout is respected (with some tolerance)
      let expectedMax = Double(timeout) / 1000.0 + 0.5  // 500ms tolerance
      XCTAssertLessThanOrEqual(
        elapsed, expectedMax,
        "Trace with \(timeout)ms timeout took \(elapsed)s")
      XCTAssertEqual(result.destination, "1.1.1.1")
      XCTAssertEqual(result.maxHops, 10)
      XCTAssertLessThanOrEqual(result.hops.count, 10)
    }
  }
}
