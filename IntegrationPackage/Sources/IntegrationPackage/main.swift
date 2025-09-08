import SwiftFTR
import Foundation

@main
struct IntegrationPackageTest {
    static func main() async {
        print("=== External Package Integration Test ===")
        print("Testing SwiftFTR as an external dependency...")
        
        // Test 1: Basic import and initialization
        let config = SwiftFTRConfig(
            maxHops: 5,
            maxWaitMs: 1000,
            enableLogging: false
        )
        let tracer = SwiftFTR(config: config)
        print("✓ Successfully imported and initialized SwiftFTR")
        
        // Test 2: Basic trace
        do {
            print("\nPerforming trace to 1.1.1.1...")
            let result = try await tracer.trace(to: "1.1.1.1")
            print("✓ Trace completed")
            print("  - Destination: \(result.destination)")
            print("  - Hops found: \(result.hops.count)")
            print("  - Duration: \(String(format: "%.3f", result.duration))s")
            
            if let firstHop = result.hops.first {
                let addr = firstHop.ipAddress ?? "*"
                print("  - First hop: \(addr)")
            }
        } catch {
            print("✗ Trace failed: \(error)")
            Foundation.exit(1)
        }
        
        // Test 3: Configuration API
        let customConfig = SwiftFTRConfig(
            maxHops: 3,
            maxWaitMs: 500,
            payloadSize: 32,
            publicIP: "8.8.8.8",
            enableLogging: false
        )
        let customTracer = SwiftFTR(config: customConfig)
        print("\n✓ Configuration API works correctly")
        
        // Test 4: Error handling
        do {
            _ = try await customTracer.trace(to: "invalid-host-12345.test")
            print("✗ Should have thrown error")
            Foundation.exit(1)
        } catch TracerouteError.resolutionFailed {
            print("✓ Error handling works correctly")
        } catch {
            print("✗ Unexpected error type: \(error)")
            Foundation.exit(1)
        }
        
        print("\n=== All Integration Tests Passed ===")
    }
}