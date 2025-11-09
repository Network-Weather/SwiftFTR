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

    // Test 6: DNS AAAA query for www.google.com (0.8.0 API)
    print("\n6. Testing DNS AAAA query for www.google.com (v0.8.0 API)...")
    do {
      let result = try await tracer.dns.aaaa(hostname: "www.google.com")

      if result.records.isEmpty {
        print("  - No IPv6 addresses found")
      } else {
        print("✓ Found \(result.records.count) IPv6 address(es) (RTT: \(String(format: "%.1f", result.rttMs))ms):")
        for record in result.records {
          if case .ipv6(let addr) = record.data {
            print("  - \(addr) (TTL: \(record.ttl)s)")
          }
        }
      }
    } catch {
      print("✗ DNS AAAA query failed: \(error)")
      Foundation.exit(1)
    }

    // Test 7: DNS A query (0.8.0 API)
    print("\n7. Testing DNS A query for google.com (v0.8.0 API)...")
    do {
      let result = try await tracer.dns.a(hostname: "google.com")
      print("✓ Found \(result.records.count) IPv4 address(es) (RTT: \(String(format: "%.1f", result.rttMs))ms):")
      for record in result.records.prefix(2) {
        if case .ipv4(let addr) = record.data {
          print("  - \(addr)")
        }
      }
    } catch {
      print("✗ DNS A query failed: \(error)")
      Foundation.exit(1)
    }

    // Test 8: Reverse DNS query (0.8.0 API)
    print("\n8. Testing reverse DNS for 8.8.8.8 (v0.8.0 API)...")
    do {
      let result = try await tracer.dns.reverseIPv4(ip: "8.8.8.8")
      print("✓ Found \(result.records.count) PTR record(s) (RTT: \(String(format: "%.1f", result.rttMs))ms):")
      for record in result.records {
        if case .hostname(let hostname) = record.data {
          print("  - \(hostname)")
        }
      }
    } catch {
      print("✗ Reverse DNS query failed: \(error)")
      Foundation.exit(1)
    }

    // Test 9: MX query (0.8.0 API)
    print("\n9. Testing MX query for google.com (v0.8.0 API)...")
    do {
      let result = try await tracer.dns.query(name: "google.com", type: .mx)
      print("✓ Found \(result.records.count) MX record(s) (RTT: \(String(format: "%.1f", result.rttMs))ms):")
      for record in result.records.prefix(3) {
        if case .mx(let priority, let exchange) = record.data {
          print("  - Priority \(priority): \(exchange)")
        }
      }
    } catch {
      print("✗ MX query failed: \(error)")
      Foundation.exit(1)
    }

    // Test 10: CAA query (0.8.0 API)
    print("\n10. Testing CAA query for google.com (v0.8.0 API)...")
    do {
      let result = try await tracer.dns.query(name: "google.com", type: .caa)
      if result.records.isEmpty {
        print("  - No CAA records found (domain allows any CA)")
      } else {
        print("✓ Found \(result.records.count) CAA record(s) (RTT: \(String(format: "%.1f", result.rttMs))ms):")
        for record in result.records.prefix(3) {
          if case .caa(let flags, let tag, let value) = record.data {
            print("  - Flags: \(flags), Tag: \(tag), Value: \(value)")
          }
        }
      }
    } catch {
      print("✗ CAA query failed: \(error)")
      Foundation.exit(1)
    }

    // Test 11: HTTPS query (0.8.0 API)
    print("\n11. Testing HTTPS query for cloudflare.com (v0.8.0 API)...")
    do {
      let result = try await tracer.dns.query(name: "cloudflare.com", type: .https)
      if result.records.isEmpty {
        print("  - No HTTPS records found")
      } else {
        print("✓ Found \(result.records.count) HTTPS record(s) (RTT: \(String(format: "%.1f", result.rttMs))ms):")
        for record in result.records.prefix(3) {
          if case .https(let priority, let target, let svcParams) = record.data {
            print("  - Priority \(priority): \(target) (params: \(svcParams.count) bytes)")
          }
        }
      }
    } catch {
      print("✗ HTTPS query failed: \(error)")
      Foundation.exit(1)
    }

    print("\n=== All Tests Passed ===")
  }
}
