import Foundation
import SwiftFTR

@main
struct IntegrationTest {
  static func main() async {
    print("=== SwiftFTR Integration Test ===")

    // Test 1: Basic configuration and trace
    print("\n1. Testing basic configuration...")
    let config = SwiftFTRConfig(
      maxHops: 8,
      maxWaitMs: 1500,
      payloadSize: 64,
      enableLogging: true
    )
    let tracer = SwiftFTR(config: config)
    print("✓ Created tracer with config")

    // Test 2: Simple trace
    do {
      print("\n2. Testing basic trace to 1.1.1.1...")
      let result = try await tracer.trace(to: "1.1.1.1")
      print("✓ Trace completed successfully")
      print("  - Destination: \(result.destination)")
      print("  - Max hops configured: \(result.maxHops)")
      print("  - Reached destination: \(result.reached)")
      print("  - Hops found: \(result.hops.count)")
      print("  - Duration: \(String(format: "%.3f", result.duration))s")

      // Print first few hops
      for hop in result.hops.prefix(3) {
        let addr = hop.ipAddress ?? "*"
        let rtt = hop.rtt.map { String(format: "%.3f ms", $0 * 1000) } ?? "timeout"
        print("    Hop \(hop.ttl): \(addr) (\(rtt))")
      }
    } catch {
      print("✗ Trace failed: \(error)")
      Foundation.exit(1)
    }

    // Test 3: Classified trace with public IP override
    do {
      print("\n3. Testing classified trace with public IP override...")
      let configWithIP = SwiftFTRConfig(
        maxHops: 5,
        publicIP: "8.8.8.8",  // Use a well-known IP for testing
        enableLogging: false
      )
      let tracerWithIP = SwiftFTR(config: configWithIP)
      let classified = try await tracerWithIP.traceClassified(to: "1.1.1.1")
      print("✓ Classified trace completed")
      print("  - Public IP: \(classified.publicIP ?? "none")")
      print("  - Client ASN: \(classified.clientASN ?? 0)")
      print("  - Destination ASN: \(classified.destinationASN ?? 0)")
      print("  - Hops classified: \(classified.hops.count)")
    } catch {
      print("✗ Classified trace failed: \(error)")
      Foundation.exit(1)
    }

    // Test 4: Error handling with detailed error messages
    do {
      print("\n4. Testing error handling with invalid host...")
      let errorConfig = SwiftFTRConfig(
        maxHops: 5,
        enableLogging: true
      )
      let errorTracer = SwiftFTR(config: errorConfig)
      let _ = try await errorTracer.trace(to: "definitely-not-a-real-host-12345.invalid")
      print("✗ Should have failed but didn't")
      Foundation.exit(1)
    } catch TracerouteError.resolutionFailed(let host, let details) {
      print("✓ Correctly caught resolution error:")
      print("  - Host: \(host)")
      print("  - Details: \(details ?? "none")")
    } catch {
      print("✗ Unexpected error type: \(error)")
      Foundation.exit(1)
    }

    // Test 5: Verify configuration API works correctly
    print("\n5. Verifying configuration API...")

    do {
      let cleanConfig = SwiftFTRConfig(
        maxHops: 3,
        maxWaitMs: 500,
        enableLogging: false
      )
      let cleanTracer = SwiftFTR(config: cleanConfig)
      let _ = try await cleanTracer.trace(to: "8.8.8.8")
      print("✓ Configuration API works correctly")
    } catch {
      print("✗ Failed without env vars: \(error)")
      Foundation.exit(1)
    }

    print("\n=== All Tests Passed ===")
  }
}
