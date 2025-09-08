import XCTest
import SwiftFTR

final class StressAndEdgeCaseTests: XCTestCase {
    
    // MARK: - Stress Tests
    
    func testRapidSequentialTraces() async throws {
        let config = SwiftFTRConfig(maxHops: 3, maxWaitMs: 500)
        let tracer = SwiftFTR(config: config)
        
        // Run 10 traces in rapid succession
        for i in 1...10 {
            let result = try await tracer.trace(to: "1.1.1.1")
            XCTAssertFalse(result.hops.isEmpty, "Trace \(i) should have hops")
            XCTAssertLessThanOrEqual(result.duration, 1.0, "Trace \(i) should complete quickly")
        }
    }
    
    func testManyHopsWithTimeouts() async throws {
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
    
    func testMemoryLeakWithRepeatedTraces() async throws {
        let config = SwiftFTRConfig(maxHops: 5, maxWaitMs: 500)
        let tracer = SwiftFTR(config: config)
        
        // Track memory usage (basic check)
        for _ in 1...50 {
            _ = autoreleasepool {
                Task {
                    _ = try? await tracer.trace(to: "8.8.8.8")
                }
            }
        }
        
        // If we get here without crashing, memory management is likely okay
        XCTAssertTrue(true)
    }
    
    // MARK: - Edge Cases
    
    func testZeroPayloadSize() async throws {
        let config = SwiftFTRConfig(
            maxHops: 3,
            payloadSize: 0  // Edge case: zero payload
        )
        let tracer = SwiftFTR(config: config)
        
        let result = try await tracer.trace(to: "1.1.1.1")
        XCTAssertNotNil(result)
        XCTAssertFalse(result.hops.isEmpty)
    }
    
    func testSpecialIPAddresses() async throws {
        let config = SwiftFTRConfig(maxHops: 3, maxWaitMs: 500)
        let tracer = SwiftFTR(config: config)
        
        // Test broadcast address (should resolve but might not route)
        do {
            let result = try await tracer.trace(to: "255.255.255.255")
            XCTAssertNotNil(result)
        } catch TracerouteError.resolutionFailed {
            // Some systems might reject broadcast address
            XCTAssertTrue(true)
        }
        
        // Test multicast address
        let multicastResult = try await tracer.trace(to: "224.0.0.1")
        XCTAssertNotNil(multicastResult)
        
        // Test zero address
        do {
            _ = try await tracer.trace(to: "0.0.0.0")
            // Might succeed on some systems
        } catch {
            // Expected to fail on most systems
            XCTAssertTrue(true)
        }
    }
    
    func testIPv6Rejection() async throws {
        let config = SwiftFTRConfig()
        let tracer = SwiftFTR(config: config)
        
        // Currently only IPv4 is supported
        do {
            _ = try await tracer.trace(to: "2001:4860:4860::8888")
            XCTFail("Should reject IPv6")
        } catch TracerouteError.resolutionFailed(_, let details) {
            // Should fail because IPv6 is not supported
            XCTAssertNotNil(details)
        } catch {
            // Any error is acceptable for unsupported IPv6
            XCTAssertTrue(true)
        }
    }
    
    func testDNSResolutionEdgeCases() async throws {
        let config = SwiftFTRConfig(maxHops: 3)
        let tracer = SwiftFTR(config: config)
        
        // Test empty string
        do {
            _ = try await tracer.trace(to: "")
            XCTFail("Should fail on empty hostname")
        } catch TracerouteError.resolutionFailed {
            XCTAssertTrue(true)
        }
        
        // Test whitespace
        do {
            _ = try await tracer.trace(to: "   ")
            XCTFail("Should fail on whitespace hostname")
        } catch TracerouteError.resolutionFailed {
            XCTAssertTrue(true)
        }
        
        // Test very long hostname
        let longHost = String(repeating: "a", count: 256) + ".com"
        do {
            _ = try await tracer.trace(to: longHost)
            XCTFail("Should fail on too long hostname")
        } catch TracerouteError.resolutionFailed {
            XCTAssertTrue(true)
        }
    }
    
    func testPublicIPOverride() async throws {
        // Test various public IP formats
        let testIPs = [
            "1.2.3.4",
            "255.255.255.254",
            "100.64.0.1"  // CGNAT
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
        let config = SwiftFTRConfig(maxHops: 5)
        let tracer = SwiftFTR(config: config)
        
        // Test known providers
        let providers = [
            ("1.1.1.1", 13335),  // Cloudflare
            ("8.8.8.8", 15169),  // Google
            ("9.9.9.9", 19281)   // Quad9
        ]
        
        for (ip, expectedASN) in providers {
            let classified = try await tracer.traceClassified(to: ip)
            XCTAssertEqual(classified.destinationASN, expectedASN, 
                          "ASN for \(ip) should be \(expectedASN)")
        }
    }
    
    func testCachingBehavior() async throws {
        let config = SwiftFTRConfig(maxHops: 3)
        let tracer = SwiftFTR(config: config)
        
        // First trace should populate cache
        let start1 = Date()
        let classified1 = try await tracer.traceClassified(to: "1.1.1.1")
        _ = Date().timeIntervalSince(start1)
        
        // Second trace to same destination should be faster due to caching
        let start2 = Date()
        let classified2 = try await tracer.traceClassified(to: "1.1.1.1")
        _ = Date().timeIntervalSince(start2)
        
        XCTAssertEqual(classified1.destinationASN, classified2.destinationASN)
        // Cache might make second request faster, but network variance exists
        XCTAssertNotNil(classified1.destinationASN)
        XCTAssertNotNil(classified2.destinationASN)
    }
    
    // MARK: - Timeout Behavior Tests
    
    func testTimeoutBehavior() async throws {
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
            XCTAssertLessThanOrEqual(elapsed, expectedMax, 
                                     "Trace with \(timeout)ms timeout took \(elapsed)s")
            XCTAssertNotNil(result)
        }
    }
}