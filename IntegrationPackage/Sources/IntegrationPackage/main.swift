import SwiftFTR
import Foundation

@main
struct IntegrationPackageTest {
    static func main() async {
        print("=== External Package Integration Test ===")
        print("Testing SwiftFTR as an external dependency...")
        
        // Test 1: Basic import and initialization
        let config = SwiftFTRConfig(
            maxHops: 30,  // Use default to ensure we can reach destinations
            maxWaitMs: 2000,
            enableLogging: false
        )
        let tracer = SwiftFTR(config: config)
        print("✓ Successfully imported and initialized SwiftFTR")
        
        // Test 2: Basic trace with validation
        do {
            print("\nPerforming trace to 1.1.1.1...")
            let result = try await tracer.trace(to: "1.1.1.1")
            
            // Validate the trace actually worked
            guard result.reached else {
                print("✗ Failed to reach destination 1.1.1.1")
                Foundation.exit(1)
            }
            
            guard result.hops.count > 0 else {
                print("✗ No hops found in trace")
                Foundation.exit(1)
            }
            
            // Verify we have at least some responsive hops
            let responsiveHops = result.hops.filter { $0.ipAddress != nil }
            guard responsiveHops.count > 0 else {
                print("✗ No responsive hops found")
                Foundation.exit(1)
            }
            
            print("✓ Trace completed successfully")
            print("  - Destination: \(result.destination)")
            print("  - Reached: \(result.reached)")
            print("  - Total hops: \(result.hops.count)")
            print("  - Responsive hops: \(responsiveHops.count)")
            print("  - Duration: \(String(format: "%.3f", result.duration))s")
            
            if let firstHop = result.hops.first {
                let addr = firstHop.ipAddress ?? "*"
                print("  - First hop: \(addr)")
            }
        } catch {
            print("✗ Trace failed: \(error)")
            Foundation.exit(1)
        }
        
        // Test 3: Classified trace with specific validation for 8.8.8.8
        do {
            print("\nTesting classified trace to 8.8.8.8 (Google DNS)...")
            let classifiedConfig = SwiftFTRConfig(
                maxHops: 30,  // Ensure we can reach Google
                maxWaitMs: 2000,
                enableLogging: false
            )
            let classifiedTracer = SwiftFTR(config: classifiedConfig)
            let classified = try await classifiedTracer.traceClassified(to: "8.8.8.8")
            
            // Verify we reached the destination
            guard classified.destinationIP == "8.8.8.8" else {
                print("✗ Destination IP mismatch")
                Foundation.exit(1)
            }
            
            // Verify Google's ASN (AS15169)
            guard let destASN = classified.destinationASN else {
                print("✗ Failed to resolve destination ASN for 8.8.8.8")
                Foundation.exit(1)
            }
            
            guard destASN == 15169 else {
                print("✗ Expected Google AS15169 for 8.8.8.8, got AS\(destASN)")
                Foundation.exit(1)
            }
            
            // Verify we have a public IP and it has an ASN
            guard let publicIP = classified.publicIP else {
                print("✗ Failed to detect public IP")
                Foundation.exit(1)
            }
            
            // Verify the public IP is actually public (has an ASN)
            guard let clientASN = classified.clientASN else {
                print("✗ Public IP \(publicIP) has no ASN - likely not a real public IP")
                Foundation.exit(1)
            }
            
            // Basic sanity check - public IPs shouldn't be private ranges
            let privateRanges = ["192.168.", "10.", "172.16.", "172.17.", "172.18.", 
                                 "172.19.", "172.20.", "172.21.", "172.22.", "172.23.",
                                 "172.24.", "172.25.", "172.26.", "172.27.", "172.28.",
                                 "172.29.", "172.30.", "172.31.", "127.", "169.254."]
            for range in privateRanges {
                if publicIP.hasPrefix(range) {
                    print("✗ Public IP \(publicIP) is in private range")
                    Foundation.exit(1)
                }
            }
            
            // Verify hop classification exists
            let classifiedHops = classified.hops.filter { $0.ip != nil }
            guard classifiedHops.count > 0 else {
                print("✗ No classified hops found")
                Foundation.exit(1)
            }
            
            print("✓ Classification validated successfully")
            print("  - Destination: 8.8.8.8 (Google DNS)")
            print("  - Destination ASN: AS\(destASN) (\(classified.destinationASName ?? "Unknown"))")
            print("  - Public IP: \(publicIP)")
            print("  - Client ASN: AS\(clientASN) (\(classified.clientASName ?? "Unknown"))")
            print("  - Classified hops: \(classifiedHops.count)")
            
        } catch {
            print("✗ Classified trace failed: \(error)")
            Foundation.exit(1)
        }
        
        // Test 4: Configuration API
        let customConfig = SwiftFTRConfig(
            maxHops: 3,
            maxWaitMs: 500,
            payloadSize: 32,
            publicIP: "8.8.8.8",
            enableLogging: false
        )
        let customTracer = SwiftFTR(config: customConfig)
        print("\n✓ Configuration API works correctly")
        
        // Test 5: Error handling
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