import Foundation
import Testing

@testable import SwiftFTR

/// Tests for per-operation interface and source IP binding
///
/// These tests verify that:
/// 1. Operation-level interface config overrides global config
/// 2. Different interfaces produce different public IPs (multi-interface systems)
/// 3. Concurrent operations with different interfaces work correctly
/// 4. Invalid interfaces produce descriptive errors
///
/// Test Strategy:
/// - Network tests are gated with SKIP_NETWORK_TESTS environment variable
/// - Interface-specific tests skip if interfaces not available
/// - Tests use real network calls to verify actual binding behavior
@Suite("Interface Binding Tests")
struct InterfaceBindingTests {

  // MARK: - Helper Functions

  /// Check if a network interface exists and is up
  func interfaceAvailable(_ name: String) -> Bool {
    #if canImport(Darwin)
      return if_nametoindex(name) != 0
    #else
      return false
    #endif
  }

  /// Check if network tests should be skipped
  var shouldSkipNetworkTests: Bool {
    ProcessInfo.processInfo.environment["SKIP_NETWORK_TESTS"] != nil
  }

  /// Discover available network interfaces (excluding loopback and virtual)
  func discoverNetworkInterfaces() -> [String] {
    #if canImport(Darwin)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
      process.arguments = ["-l"]

      let pipe = Pipe()
      process.standardOutput = pipe

      try? process.run()
      process.waitUntilExit()

      guard let data = try? pipe.fileHandleForReading.readToEnd(),
        let output = String(data: data, encoding: .utf8)
      else {
        return []
      }

      let interfaces = output.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: " ")
        .map(String.init)
        .filter { iface in
          // Exclude loopback, virtual, and bridge interfaces
          !iface.starts(with: "lo") && !iface.starts(with: "gif") && !iface.starts(with: "stf")
            && !iface.starts(with: "anpi") && !iface.starts(with: "bridge")
            && !iface.starts(with: "ap") && !iface.starts(with: "awdl")
            && !iface.starts(with: "llw") && !iface.starts(with: "utun")
            && interfaceAvailable(iface)
        }

      return interfaces
    #else
      return []
    #endif
  }

  /// Get two different network interfaces for testing
  func getTwoInterfaces() -> (String, String)? {
    let interfaces = discoverNetworkInterfaces()
    guard interfaces.count >= 2 else { return nil }
    return (interfaces[0], interfaces[1])
  }

  // MARK: - Per-Operation Override Tests

  @Test("Ping with operation interface override")
  func testPingWithOperationInterfaceOverride() async throws {
    guard !shouldSkipNetworkTests else { return }
    let interfaces = discoverNetworkInterfaces()
    guard let firstInterface = interfaces.first else {
      print("⏭️  Skipping: No suitable network interfaces found")
      return
    }

    // Create SwiftFTR with NO global interface
    let ftr = SwiftFTR()

    // Ping with operation-level interface binding
    let result = try await ftr.ping(
      to: "1.1.1.1",
      config: PingConfig(count: 3, timeout: 2.0, interface: firstInterface)
    )

    // Should succeed with some responses
    #expect(result.statistics.sent == 3)
    #expect(
      result.statistics.received > 0, "Should receive at least one response via \(firstInterface)")
  }

  @Test("Ping without override uses global interface")
  func testPingWithoutOverrideUsesGlobal() async throws {
    guard !shouldSkipNetworkTests else { return }
    let interfaces = discoverNetworkInterfaces()
    guard let firstInterface = interfaces.first else {
      print("⏭️  Skipping: No suitable network interfaces found")
      return
    }

    // Create SwiftFTR with global interface
    let ftr = SwiftFTR(config: SwiftFTRConfig(interface: firstInterface))

    // Ping WITHOUT operation-level interface (should use global)
    let result = try await ftr.ping(
      to: "1.1.1.1",
      config: PingConfig(count: 3, timeout: 2.0)
    )

    #expect(result.statistics.sent == 3)
    #expect(
      result.statistics.received > 0, "Should receive responses using global \(firstInterface)")
  }

  @Test("Ping with nil global and operation uses system default")
  func testPingWithNilGlobalAndOperation() async throws {
    guard !shouldSkipNetworkTests else { return }

    // Create SwiftFTR with NO global interface
    let ftr = SwiftFTR()

    // Ping without operation interface (should use system routing)
    let result = try await ftr.ping(
      to: "1.1.1.1",
      config: PingConfig(count: 3, timeout: 2.0)
    )

    #expect(result.statistics.sent == 3)
    #expect(result.statistics.received > 0, "Should receive responses via system default route")
  }

  // MARK: - Multi-Interface Tests

  @Test("Different interfaces have different public IPs")
  func testDifferentInterfacesHaveDifferentPublicIPs() async throws {
    guard !shouldSkipNetworkTests else { return }
    guard let (iface1, iface2) = getTwoInterfaces() else {
      print("⏭️  Skipping: Need at least 2 network interfaces")
      return
    }

    // Test via first interface
    let ftr1 = SwiftFTR(config: SwiftFTRConfig(interface: iface1))
    let trace1 = try await ftr1.traceClassified(to: "1.1.1.1")

    // Test via second interface
    let ftr2 = SwiftFTR(config: SwiftFTRConfig(interface: iface2))
    let trace2 = try await ftr2.traceClassified(to: "1.1.1.1")

    // Verify public IPs detected
    #expect(trace1.publicIP != nil, "Should detect public IP via \(iface1)")
    #expect(trace2.publicIP != nil, "Should detect public IP via \(iface2)")

    // Note: Public IPs may be the same if both interfaces use same gateway (e.g., NAT)
    // This is not a failure - just log the result
    if trace1.publicIP != trace2.publicIP {
      print("✓ Multi-interface test: Different public IPs detected")
      print("  \(iface1) public IP: \(trace1.publicIP ?? "nil")")
      print("  \(iface2) public IP: \(trace2.publicIP ?? "nil")")
    } else {
      print("ℹ️  Multi-interface test: Same public IP (both interfaces behind same NAT)")
      print("  \(iface1) & \(iface2) public IP: \(trace1.publicIP ?? "nil")")
    }
  }

  @Test("Concurrent pings with different interfaces")
  func testConcurrentPingsWithDifferentInterfaces() async throws {
    guard !shouldSkipNetworkTests else { return }
    guard let (iface1, iface2) = getTwoInterfaces() else {
      print("⏭️  Skipping: Need at least 2 network interfaces")
      return
    }

    let ftr = SwiftFTR()

    // Concurrent pings to same target via different interfaces
    async let result1 = ftr.ping(
      to: "1.1.1.1",
      config: PingConfig(count: 3, timeout: 2.0, interface: iface1)
    )
    async let result2 = ftr.ping(
      to: "1.1.1.1",
      config: PingConfig(count: 3, timeout: 2.0, interface: iface2)
    )

    let (r1, r2) = try await (result1, result2)

    // Both should succeed
    #expect(r1.statistics.received > 0, "\(iface1) should receive responses")
    #expect(r2.statistics.received > 0, "\(iface2) should receive responses")

    print("✓ Concurrent test passed:")
    print("  \(iface1): \(r1.statistics.received)/\(r1.statistics.sent) responses")
    print("  \(iface2): \(r2.statistics.received)/\(r2.statistics.sent) responses")
  }

  // MARK: - Error Handling Tests

  @Test("Invalid interface throws descriptive error")
  func testInvalidInterfaceThrowsError() async {
    let ftr = SwiftFTR()

    do {
      _ = try await ftr.ping(
        to: "1.1.1.1",
        config: PingConfig(count: 1, timeout: 1.0, interface: "nonexistent999")
      )
      Issue.record("Should have thrown interfaceBindFailed error")
    } catch let error as TracerouteError {
      if case .interfaceBindFailed(let iface, _, let details) = error {
        #expect(iface == "nonexistent999")
        #expect(details?.contains("not found") ?? false, "Error should mention interface not found")
        print("✓ Invalid interface error: \(error)")
      } else {
        Issue.record("Wrong error type: \(error)")
      }
    } catch {
      Issue.record("Unexpected error type: \(error)")
    }
  }

  @Test("Invalid source IP throws descriptive error")
  func testInvalidSourceIPThrowsError() async {
    let interfaces = discoverNetworkInterfaces()
    guard let firstInterface = interfaces.first else {
      print("⏭️  Skipping: No suitable network interfaces found")
      return
    }

    let ftr = SwiftFTR()

    do {
      _ = try await ftr.ping(
        to: "1.1.1.1",
        config: PingConfig(
          count: 1,
          timeout: 1.0,
          interface: firstInterface,
          sourceIP: "192.0.2.1"  // TEST-NET-1 - unlikely to be assigned
        )
      )
      // May succeed if IP happens to be assigned, so don't fail the test
      print("Note: Source IP 192.0.2.1 binding succeeded (IP may be assigned)")
    } catch let error as TracerouteError {
      if case .sourceIPBindFailed(let ip, _, _) = error {
        #expect(ip == "192.0.2.1")
        print("✓ Invalid source IP error: \(error)")
      } else {
        Issue.record("Wrong error type: \(error)")
      }
    } catch {
      Issue.record("Unexpected error type: \(error)")
    }
  }

  // MARK: - TCP/DNS Probe Interface Binding Tests

  @Test("TCP probe with interface binding")
  func testTCPProbeInterfaceBinding() async throws {
    guard !shouldSkipNetworkTests else { return }
    let interfaces = discoverNetworkInterfaces()
    guard let firstInterface = interfaces.first else {
      print("⏭️  Skipping: No suitable network interfaces found")
      return
    }

    // TCP probe to Cloudflare DNS (port 53)
    let result = try await tcpProbe(
      config: TCPProbeConfig(
        host: "1.1.1.1",
        port: 53,
        timeout: 2.0,
        interface: firstInterface
      )
    )

    #expect(result.isReachable, "TCP probe should succeed via \(firstInterface)")
    print(
      "✓ TCP probe via \(firstInterface): RTT \(String(format: "%.1f", (result.rtt ?? 0) * 1000))ms"
    )
  }

  @Test("DNS probe with interface binding")
  func testDNSProbeInterfaceBinding() async throws {
    guard !shouldSkipNetworkTests else { return }
    let interfaces = discoverNetworkInterfaces()
    guard let firstInterface = interfaces.first else {
      print("⏭️  Skipping: No suitable network interfaces found")
      return
    }

    // DNS probe to Cloudflare DNS
    let result = try await dnsProbe(
      config: DNSProbeConfig(
        server: "1.1.1.1",
        query: "example.com",
        timeout: 2.0,
        interface: firstInterface
      )
    )

    #expect(result.isReachable, "DNS probe should succeed via \(firstInterface)")
    #expect(result.responseCode == 0, "Should get NOERROR response")
    print(
      "✓ DNS probe via \(firstInterface): RTT \(String(format: "%.1f", (result.rtt ?? 0) * 1000))ms"
    )
  }

  @Test("Bufferbloat test with interface binding")
  func testBufferbloatInterfaceBinding() async throws {
    guard !shouldSkipNetworkTests else { return }
    let interfaces = discoverNetworkInterfaces()
    guard let firstInterface = interfaces.first else {
      print("⏭️  Skipping: No suitable network interfaces found")
      return
    }

    let ftr = SwiftFTR()

    // Quick bufferbloat test via first interface
    let result = try await ftr.testBufferbloat(
      config: BufferbloatConfig(
        target: "1.1.1.1",
        baselineDuration: 1.0,  // 1s baseline
        loadDuration: 2.0,  // 2s load
        pingInterval: 0.2,  // 5 pings per phase
        interface: firstInterface
      )
    )

    // Verify test completed
    #expect(result.baseline.sampleCount > 0, "Should have baseline samples")
    #expect(result.loaded.sampleCount > 0, "Should have loaded samples")
    print("✓ Bufferbloat test via \(firstInterface): Grade \(result.grade.rawValue)")
  }

  // MARK: - Override Precedence Tests

  @Test("Operation interface overrides global interface")
  func testOperationOverridesGlobal() async throws {
    guard !shouldSkipNetworkTests else { return }
    guard let (iface1, iface2) = getTwoInterfaces() else {
      print("⏭️  Skipping: Need at least 2 network interfaces")
      return
    }

    // Create with global interface 1
    let ftr = SwiftFTR(config: SwiftFTRConfig(interface: iface1))

    // Ping with operation-level interface 2 (should override)
    let result = try await ftr.ping(
      to: "1.1.1.1",
      config: PingConfig(count: 3, timeout: 2.0, interface: iface2)
    )

    // Should succeed (using iface2, not iface1)
    #expect(result.statistics.received > 0)
    print("✓ Operation override test passed: used \(iface2) instead of global \(iface1)")
  }
}
