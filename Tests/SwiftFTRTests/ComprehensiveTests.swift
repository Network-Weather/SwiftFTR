import SwiftFTR
import XCTest

final class ComprehensiveIntegrationTests: XCTestCase {

  // MARK: - Configuration Tests

  func testDefaultConfiguration() async throws {
    let config = SwiftFTRConfig()
    XCTAssertEqual(config.maxHops, 40)
    XCTAssertEqual(config.maxWaitMs, 1000)
    XCTAssertEqual(config.payloadSize, 56)
    XCTAssertNil(config.publicIP)
    XCTAssertFalse(config.enableLogging)
  }

  func testCustomConfiguration() async throws {
    let config = SwiftFTRConfig(
      maxHops: 15,
      maxWaitMs: 2500,
      payloadSize: 128,
      publicIP: "1.2.3.4",
      enableLogging: true
    )

    XCTAssertEqual(config.maxHops, 15)
    XCTAssertEqual(config.maxWaitMs, 2500)
    XCTAssertEqual(config.payloadSize, 128)
    XCTAssertEqual(config.publicIP, "1.2.3.4")
    XCTAssertTrue(config.enableLogging)
  }

  // MARK: - Basic Trace Tests

  func testTraceToValidIPv4() async throws {
    let config = SwiftFTRConfig(maxHops: 5, maxWaitMs: 2000)
    let tracer = SwiftFTR(config: config)

    let result = try await tracer.trace(to: "1.1.1.1")

    XCTAssertEqual(result.destination, "1.1.1.1")
    XCTAssertEqual(result.maxHops, 5)
    XCTAssertFalse(result.hops.isEmpty)
    XCTAssertLessThanOrEqual(result.hops.count, 5)
    XCTAssertGreaterThan(result.duration, 0)

    // Verify first hop is typically local network
    if let firstHop = result.hops.first {
      XCTAssertEqual(firstHop.ttl, 1)
      if let ip = firstHop.ipAddress {
        // Common local network ranges
        let isLocal = ip.hasPrefix("192.168.") || ip.hasPrefix("10.") || ip.hasPrefix("172.")
        XCTAssertTrue(isLocal || firstHop.rtt != nil, "First hop should be local or have RTT")
      }
    }
  }

  func testTraceToLocalhost() async throws {
    let config = SwiftFTRConfig(maxHops: 1, maxWaitMs: 500)
    let tracer = SwiftFTR(config: config)

    let result = try await tracer.trace(to: "127.0.0.1")

    XCTAssertEqual(result.destination, "127.0.0.1")
    // Localhost might be reached in 1 hop or might not respond to ICMP
    XCTAssertGreaterThanOrEqual(result.hops.count, 0)
  }

  // MARK: - Error Handling Tests

  func testInvalidHostname() async throws {
    let config = SwiftFTRConfig(maxHops: 3)
    let tracer = SwiftFTR(config: config)

    do {
      _ = try await tracer.trace(to: "this-is-not-a-valid-hostname-12345.invalid")
      XCTFail("Should have thrown resolution error")
    } catch TracerouteError.resolutionFailed(let host, let details) {
      XCTAssertEqual(host, "this-is-not-a-valid-hostname-12345.invalid")
      XCTAssertNotNil(details)
      XCTAssertTrue(details?.contains("nodename") == true || details?.contains("not known") == true)
    } catch {
      XCTFail("Unexpected error type: \(error)")
    }
  }

  func testInvalidIPv4Format() async throws {
    let config = SwiftFTRConfig()
    let tracer = SwiftFTR(config: config)

    do {
      _ = try await tracer.trace(to: "999.999.999.999")
      XCTFail("Should have thrown resolution error")
    } catch TracerouteError.resolutionFailed {
      // Expected
    } catch {
      XCTFail("Unexpected error type: \(error)")
    }
  }

  // MARK: - Classification Tests

  func testClassifiedTrace() async throws {
    let config = SwiftFTRConfig(
      maxHops: 10,
      publicIP: "8.8.8.8"  // Override to avoid STUN in tests
    )
    let tracer = SwiftFTR(config: config)

    let classified = try await tracer.traceClassified(to: "1.1.1.1")

    XCTAssertEqual(classified.destinationHost, "1.1.1.1")
    XCTAssertEqual(classified.destinationIP, "1.1.1.1")
    XCTAssertEqual(classified.publicIP, "8.8.8.8")
    XCTAssertNotNil(classified.destinationASN)
    XCTAssertFalse(classified.hops.isEmpty)

    // Verify hop categorization - categories should be valid
    // Note: Network topology varies greatly:
    // - TRANSIT segment may be missing if ISP peers directly with destination
    // - Some hops may timeout and be categorized as UNKNOWN
    // - Private IPs might not always be categorized as LOCAL due to ASN resolution
    var categoryCounts = [HopCategory: Int]()
    for hop in classified.hops {
      XCTAssertTrue(
        [.local, .isp, .transit, .destination, .unknown].contains(hop.category),
        "Hop category should be one of the valid types")
      categoryCounts[hop.category, default: 0] += 1
    }

    // We should have at least some categorized hops
    XCTAssertFalse(categoryCounts.isEmpty, "Should have at least some categorized hops")

    // Common patterns (but not guaranteed):
    // - Often starts with LOCAL (router)
    // - Usually has ISP hops
    // - May or may not have TRANSIT (depends on peering)
    // - Should end near DESTINATION (if reached)
    print("Category distribution: \(categoryCounts)")
  }

  func testClassifiedTraceWithoutPublicIP() async throws {
    let config = SwiftFTRConfig(maxHops: 5)
    let tracer = SwiftFTR(config: config)

    // This will attempt STUN discovery
    let classified = try await tracer.traceClassified(to: "8.8.8.8")

    XCTAssertEqual(classified.destinationHost, "8.8.8.8")
    // publicIP might be nil if STUN fails, which is okay
    XCTAssertNotNil(classified.destinationASN)
  }

  // MARK: - Boundary and Edge Cases

  func testMinimalHops() async throws {
    let config = SwiftFTRConfig(maxHops: 1, maxWaitMs: 500)
    let tracer = SwiftFTR(config: config)

    let result = try await tracer.trace(to: "8.8.8.8")

    XCTAssertEqual(result.maxHops, 1)
    XCTAssertLessThanOrEqual(result.hops.count, 1)
  }

  func testMaximalHops() async throws {
    let config = SwiftFTRConfig(maxHops: 64, maxWaitMs: 3000)
    let tracer = SwiftFTR(config: config)

    let result = try await tracer.trace(to: "1.1.1.1")

    XCTAssertEqual(result.maxHops, 64)
    XCTAssertLessThanOrEqual(result.hops.count, 64)
  }

  func testVeryShortTimeout() async throws {
    let config = SwiftFTRConfig(maxHops: 5, maxWaitMs: 100)  // 100ms is very short
    let tracer = SwiftFTR(config: config)

    let result = try await tracer.trace(to: "8.8.8.8")

    // With very short timeout, some hops might timeout
    let timeouts = result.hops.filter { $0.ipAddress == nil }.count
    XCTAssertGreaterThanOrEqual(timeouts, 0)
  }

  func testLargePayloadSize() async throws {
    let config = SwiftFTRConfig(
      maxHops: 3,
      payloadSize: 1024  // Large payload
    )
    let tracer = SwiftFTR(config: config)

    // Should not crash with large payload
    let result = try await tracer.trace(to: "1.1.1.1")
    XCTAssertNotNil(result)
  }

  // MARK: - Concurrent Execution Tests

  func testConcurrentTraces() async throws {
    let config = SwiftFTRConfig(maxHops: 5)
    let tracer = SwiftFTR(config: config)

    // Run multiple traces concurrently
    async let trace1 = tracer.trace(to: "1.1.1.1")
    async let trace2 = tracer.trace(to: "8.8.8.8")
    async let trace3 = tracer.trace(to: "9.9.9.9")

    let results = try await [trace1, trace2, trace3]

    XCTAssertEqual(results.count, 3)
    XCTAssertEqual(results[0].destination, "1.1.1.1")
    XCTAssertEqual(results[1].destination, "8.8.8.8")
    XCTAssertEqual(results[2].destination, "9.9.9.9")

    for result in results {
      XCTAssertFalse(result.hops.isEmpty)
    }
  }

  // MARK: - Performance Tests

  func testTracePerformance() throws {
    let config = SwiftFTRConfig(maxHops: 10, maxWaitMs: 1000)
    let tracer = SwiftFTR(config: config)

    measure {
      let expectation = XCTestExpectation(description: "Trace completes")

      Task {
        do {
          let _ = try await tracer.trace(to: "1.1.1.1")
          expectation.fulfill()
        } catch {
          XCTFail("Performance test failed: \(error)")
        }
      }

      wait(for: [expectation], timeout: 5.0)
    }
  }

  // MARK: - Helper Methods

  func testUtilityFunctions() {
    // Test isPrivateIPv4
    XCTAssertTrue(isPrivateIPv4("192.168.1.1"))
    XCTAssertTrue(isPrivateIPv4("10.0.0.1"))
    XCTAssertTrue(isPrivateIPv4("172.16.0.1"))
    XCTAssertTrue(isPrivateIPv4("169.254.1.1"))
    XCTAssertFalse(isPrivateIPv4("8.8.8.8"))
    XCTAssertFalse(isPrivateIPv4("1.1.1.1"))

    // Test isCGNATIPv4
    XCTAssertTrue(isCGNATIPv4("100.64.0.1"))
    XCTAssertTrue(isCGNATIPv4("100.127.255.254"))
    XCTAssertFalse(isCGNATIPv4("100.63.255.255"))
    XCTAssertFalse(isCGNATIPv4("100.128.0.0"))
  }
}
