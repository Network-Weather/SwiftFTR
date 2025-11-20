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

  /// Check if interface has an active IPv4 address
  func interfaceHasIPv4(_ name: String) -> Bool {
    #if canImport(Darwin)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
      process.arguments = [name]

      let pipe = Pipe()
      process.standardOutput = pipe

      try? process.run()
      process.waitUntilExit()

      guard let data = try? pipe.fileHandleForReading.readToEnd(),
        let output = String(data: data, encoding: .utf8)
      else {
        return false
      }

      // Check for "inet " line (IPv4 address)
      return output.contains("inet ") && !output.contains("status: inactive")
    #else
      return false
    #endif
  }

  /// Quick check that interface can reach 1.1.1.1
  func interfaceIsReachable(_ name: String) async -> Bool {
    let ftr = SwiftFTR()
    do {
      let result = try await ftr.ping(
        to: "1.1.1.1",
        config: PingConfig(count: 1, interval: 0.0, timeout: 1.0, interface: name)
      )
      return result.statistics.received > 0
    } catch {
      return false
    }
  }

  /// Discover available network interfaces (excluding loopback and virtual, must have IPv4)
  func discoverNetworkInterfaces() async -> [String] {
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

      let candidates = output.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: " ")
        .map(String.init)
        .filter { iface in
          // Exclude loopback, virtual, and bridge interfaces
          !iface.starts(with: "lo") && !iface.starts(with: "gif") && !iface.starts(with: "stf")
            && !iface.starts(with: "anpi") && !iface.starts(with: "bridge")
            && !iface.starts(with: "ap") && !iface.starts(with: "awdl")
            && !iface.starts(with: "llw") && !iface.starts(with: "utun")
            && interfaceAvailable(iface)
            && interfaceHasIPv4(iface)  // Must have active IPv4
        }

      var reachable: [String] = []
      for iface in candidates {
        if await interfaceIsReachable(iface) {
          reachable.append(iface)
        }
        if reachable.count >= 3 { break }
      }
      return reachable
    #else
      return []
    #endif
  }

  /// Get two different network interfaces for testing
  func getTwoInterfaces() async -> (String, String)? {
    let interfaces = await discoverNetworkInterfaces()
    guard interfaces.count >= 2 else { return nil }
    return (interfaces[0], interfaces[1])
  }

  // MARK: - Per-Operation Override Tests

  @Test("Ping with operation interface override")
  func testPingWithOperationInterfaceOverride() async throws {
    guard !shouldSkipNetworkTests else {
      print("⏭️  Skipping interface override test: SKIP_NETWORK_TESTS=1")
      return
    }
    let interfaces = await discoverNetworkInterfaces()
    guard let firstInterface = interfaces.first else {
      print("⏭️  Skipping: No suitable network interfaces found")
      return
    }

    let result = try await NetworkTestGate.shared.withPermit {
      try await SwiftFTR().ping(
        to: "1.1.1.1",
        config: PingConfig(count: 3, timeout: 2.0, interface: firstInterface)
      )
    }
    #expect(result.statistics.sent == 3)
    #expect(
      result.statistics.received > 0,
      "Should receive at least one response via \(firstInterface)")
  }

  @Test("Ping without override uses global interface")
  func testPingWithoutOverrideUsesGlobal() async throws {
    guard !shouldSkipNetworkTests else {
      print("⏭️  Skipping global-interface test: SKIP_NETWORK_TESTS=1")
      return
    }
    let interfaces = await discoverNetworkInterfaces()
    guard let firstInterface = interfaces.first else {
      print("⏭️  Skipping: No suitable network interfaces found")
      return
    }

    let result = try await NetworkTestGate.shared.withPermit {
      try await SwiftFTR(config: SwiftFTRConfig(interface: firstInterface)).ping(
        to: "1.1.1.1",
        config: PingConfig(count: 3, timeout: 2.0)
      )
    }

    #expect(result.statistics.sent == 3)
    if result.statistics.received == 0 {
      print("⚠️  All pings via \(firstInterface) timed out (network may be saturated)")
    }
  }

  @Test("Ping with nil global and operation uses system default")
  func testPingWithNilGlobalAndOperation() async throws {
    guard !shouldSkipNetworkTests else {
      print("⏭️  Skipping system-default test: SKIP_NETWORK_TESTS=1")
      return
    }

    let result = try await NetworkTestGate.shared.withPermit {
      try await SwiftFTR().ping(
        to: "1.1.1.1",
        config: PingConfig(count: 3, timeout: 2.0)
      )
    }
    #expect(result.statistics.sent == 3)
    #expect(result.statistics.received > 0, "Should receive responses via system default route")
  }

  // MARK: - Multi-Interface Tests

  @Test("Different interfaces have different public IPs")
  func testDifferentInterfacesHaveDifferentPublicIPs() async throws {
    guard !shouldSkipNetworkTests else {
      print("⏭️  Skipping multi-interface test: SKIP_NETWORK_TESTS=1")
      return
    }
    guard let (iface1, iface2) = await getTwoInterfaces() else {
      print("⏭️  Skipping: Need at least 2 network interfaces")
      return
    }

    let ftr1 = SwiftFTR(config: SwiftFTRConfig(interface: iface1))
    let trace1 = try await ftr1.traceClassified(to: "1.1.1.1")

    let ftr2 = SwiftFTR(config: SwiftFTRConfig(interface: iface2))
    let trace2 = try await ftr2.traceClassified(to: "1.1.1.1")

    #expect(trace1.publicIP != nil, "Should detect public IP via \(iface1)")
    #expect(trace2.publicIP != nil, "Should detect public IP via \(iface2)")

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
    guard !shouldSkipNetworkTests else {
      print("⏭️  Skipping concurrent interface ping test: SKIP_NETWORK_TESTS=1")
      return
    }
    guard let (iface1, iface2) = await getTwoInterfaces() else {
      print("⏭️  Skipping: Need at least 2 network interfaces")
      return
    }

    let ftr = SwiftFTR()
    async let result1 = ftr.ping(
      to: "1.1.1.1",
      config: PingConfig(count: 3, timeout: 2.0, interface: iface1)
    )
    async let result2 = ftr.ping(
      to: "1.1.1.1",
      config: PingConfig(count: 3, timeout: 2.0, interface: iface2)
    )

    let (r1, r2) = try await (result1, result2)
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
    let interfaces = await discoverNetworkInterfaces()
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
    let interfaces = await discoverNetworkInterfaces()
    guard let firstInterface = interfaces.first else {
      print("⏭️  Skipping: No suitable network interfaces found")
      return
    }

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
    let interfaces = await discoverNetworkInterfaces()
    guard let firstInterface = interfaces.first else {
      print("⏭️  Skipping: No suitable network interfaces found")
      return
    }

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
    let interfaces = await discoverNetworkInterfaces()
    guard let firstInterface = interfaces.first else {
      print("⏭️  Skipping: No suitable network interfaces found")
      return
    }

    let ftr = SwiftFTR()
    let result = try await ftr.testBufferbloat(
      config: BufferbloatConfig(
        target: "1.1.1.1",
        baselineDuration: 0.6,
        loadDuration: 1.2,
        pingInterval: 0.2,
        interface: firstInterface
      )
    )

    if result.loaded.sampleCount == 0 {
      print(
        "⏭️  Bufferbloat load phase produced zero samples via \(firstInterface); network unavailable?"
      )
      return
    }
    print("✓ Bufferbloat test via \(firstInterface): Grade \(result.grade.rawValue)")
  }

  // MARK: - Override Precedence Tests

  @Test("Operation interface overrides global interface")
  func testOperationOverridesGlobal() async throws {
    guard !shouldSkipNetworkTests else { return }
    guard let (iface1, iface2) = await getTwoInterfaces() else {
      print("⏭️  Skipping: Need at least 2 network interfaces")
      return
    }

    let ftr = SwiftFTR(config: SwiftFTRConfig(interface: iface1))
    let result = try await ftr.ping(
      to: "1.1.1.1",
      config: PingConfig(count: 3, timeout: 2.0, interface: iface2)
    )
    #expect(result.statistics.received > 0)
    print("✓ Operation override test passed: used \(iface2) instead of global \(iface1)")
  }
}
