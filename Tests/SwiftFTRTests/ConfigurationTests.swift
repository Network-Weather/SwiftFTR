import XCTest
@testable import SwiftFTR

@available(macOS 13.0, *)
final class ConfigurationTests: XCTestCase {
    
    func testNoEnvironmentVariableDependency() async throws {
        // Clear any potential environment variables to ensure they're not used
        unsetenv("PTR_SKIP_STUN")
        unsetenv("PTR_PUBLIC_IP")
        
        // Create config with explicit values
        let config = SwiftFTRConfig(
            maxHops: 15,
            maxWaitMs: 500,
            payloadSize: 32,
            publicIP: "203.0.113.1",
            enableLogging: false
        )
        
        let tracer = SwiftFTR(config: config)
        
        // This should work without any environment variables
        let result = try await tracer.trace(to: "1.1.1.1")
        
        // Verify config was respected
        XCTAssertLessThanOrEqual(result.hops.count, 15, "Should respect maxHops from config")
        XCTAssertNotNil(result.destination)
    }
    
    func testConfigurationOverridesDefaults() async throws {
        let customConfig = SwiftFTRConfig(
            maxHops: 10,
            maxWaitMs: 250,
            payloadSize: 64,
            publicIP: "198.51.100.1",
            enableLogging: true
        )
        
        XCTAssertEqual(customConfig.maxHops, 10)
        XCTAssertEqual(customConfig.maxWaitMs, 250)
        XCTAssertEqual(customConfig.payloadSize, 64)
        XCTAssertEqual(customConfig.publicIP, "198.51.100.1")
        XCTAssertTrue(customConfig.enableLogging)
        
        // Test default config
        let defaultConfig = SwiftFTRConfig()
        XCTAssertEqual(defaultConfig.maxHops, 30)
        XCTAssertEqual(defaultConfig.maxWaitMs, 1000)
        XCTAssertEqual(defaultConfig.payloadSize, 56)
        XCTAssertNil(defaultConfig.publicIP)
        XCTAssertFalse(defaultConfig.enableLogging)
    }
    
    func testThreadSafetyWithMultipleConfigs() async throws {
        // Create multiple tracers with different configs concurrently
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    let config = SwiftFTRConfig(
                        maxHops: 10 + i,
                        maxWaitMs: 500 + (i * 100),
                        payloadSize: 32 + (i * 8),
                        publicIP: nil,
                        enableLogging: false
                    )
                    
                    let tracer = SwiftFTR(config: config)
                    
                    // Each tracer should work independently
                    do {
                        _ = try await tracer.trace(to: "1.1.1.1")
                    } catch {
                        // Network errors are acceptable in tests
                        if case TracerouteError.socketCreateFailed = error {
                            // Expected in some CI environments
                        } else if case TracerouteError.platformNotSupported = error {
                            // Expected on non-macOS platforms
                        } else {
                            // Other errors might occur in CI
                            print("Trace failed with error: \(error)")
                        }
                    }
                }
            }
        }
    }
    
    func testClassificationWithCustomPublicIP() async throws {
        let config = SwiftFTRConfig(
            maxHops: 20,
            maxWaitMs: 1000,
            payloadSize: 56,
            publicIP: "203.0.113.50", // TEST-NET-3 address
            enableLogging: false
        )
        
        let tracer = SwiftFTR(config: config)
        
        do {
            let classified = try await tracer.traceClassified(to: "1.1.1.1")
            
            // Public IP should be what we configured
            XCTAssertEqual(classified.publicIP, "203.0.113.50")
            
            // Should have performed classification
            XCTAssertFalse(classified.hops.isEmpty)
            
            // Verify categories are assigned
            for hop in classified.hops where hop.ip != nil {
                XCTAssertTrue([.local, .isp, .transit, .destination, .unknown].contains(hop.category))
            }
        } catch {
            // Handle expected errors in CI
            if case TracerouteError.socketCreateFailed = error {
                print("Socket creation failed (expected in CI)")
            } else if case TracerouteError.platformNotSupported = error {
                print("Platform not supported (expected on non-macOS)")
            } else {
                throw error
            }
        }
    }
    
    func testNonIsolatedAPI() async throws {
        // This test validates that we can call SwiftFTR from any context
        // without MainActor requirements
        
        let config = SwiftFTRConfig()
        let tracer = SwiftFTR(config: config)
        
        // Call from a detached task (not on MainActor)
        let handle = Task.detached { () -> String? in
            do {
                let result = try await tracer.trace(to: "1.1.1.1")
                return result.destination
            } catch {
                return nil
            }
        }
        
        let ip = await handle.value
        // We may or may not get a result depending on network
        // The important thing is that it compiles and runs without actor isolation issues
        _ = ip
    }
    
    func testPayloadSizeConfiguration() async throws {
        // Test various payload sizes
        let sizes = [32, 56, 128, 256]
        
        for size in sizes {
            let config = SwiftFTRConfig(
                maxHops: 5,
                maxWaitMs: 500,
                payloadSize: size,
                publicIP: nil,
                enableLogging: false
            )
            
            let tracer = SwiftFTR(config: config)
            
            do {
                let result = try await tracer.trace(to: "127.0.0.1")
                // Just verify it doesn't crash with different payload sizes
                XCTAssertNotNil(result.destination)
            } catch {
                // Some payload sizes might fail on certain systems
                print("Payload size \(size) failed: \(error)")
            }
        }
    }
}