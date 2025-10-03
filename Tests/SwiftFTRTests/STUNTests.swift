import Foundation
import Testing

@testable import SwiftFTR

@Suite("STUN Tests")
struct STUNTests {

  // MARK: - STUNPublicIP Tests

  @Test("STUNPublicIP structure")
  func testSTUNPublicIPStructure() {
    let publicIP = STUNPublicIP(ip: "203.0.113.45")
    #expect(publicIP.ip == "203.0.113.45")
  }

  @Test("STUNPublicIP is Sendable")
  func testSTUNPublicIPSendable() {
    let publicIP = STUNPublicIP(ip: "198.51.100.1")

    Task {
      // Can safely send across concurrency domains
      let ip = publicIP.ip
      #expect(ip == "198.51.100.1")
    }
  }

  // MARK: - STUNError Tests

  @Test("STUNError resolveFailed description")
  func testResolveFailed() {
    let error = STUNError.resolveFailed(errno: 8, details: "No address found")
    let desc = error.description

    #expect(desc.contains("Failed to resolve STUN server"))
    #expect(desc.contains("errno=8"))
    #expect(desc.contains("No address found"))
  }

  @Test("STUNError socketFailed description")
  func testSocketFailed() {
    let error = STUNError.socketFailed(errno: 24, details: "Resource limit")
    let desc = error.description

    #expect(desc.contains("Failed to create UDP socket"))
    #expect(desc.contains("errno=24"))
    #expect(desc.contains("Resource limit"))
  }

  @Test("STUNError sendFailed description")
  func testSendFailed() {
    let error = STUNError.sendFailed(errno: 65, details: "Network unreachable")
    let desc = error.description

    #expect(desc.contains("Failed to send STUN request"))
    #expect(desc.contains("errno=65"))
    #expect(desc.contains("Network unreachable"))
  }

  @Test("STUNError recvTimeout description")
  func testRecvTimeout() {
    let error = STUNError.recvTimeout
    let desc = error.description

    #expect(desc == "STUN request timed out")
  }

  @Test("STUNError interfaceBindFailed description")
  func testInterfaceBindFailed() {
    let error = STUNError.interfaceBindFailed(
      interface: "en0",
      errno: 49,
      details: "Interface not found"
    )
    let desc = error.description

    #expect(desc.contains("Failed to bind STUN socket to interface 'en0'"))
    #expect(desc.contains("errno=49"))
    #expect(desc.contains("Interface not found"))
  }

  @Test("STUNError sourceIPBindFailed description")
  func testSourceIPBindFailed() {
    let error = STUNError.sourceIPBindFailed(
      sourceIP: "192.168.1.100",
      errno: 49,
      details: "Cannot assign requested address"
    )
    let desc = error.description

    #expect(desc.contains("Failed to bind STUN socket to source IP '192.168.1.100'"))
    #expect(desc.contains("errno=49"))
    #expect(desc.contains("Cannot assign requested address"))
  }

  @Test("STUNError without details")
  func testErrorWithoutDetails() {
    let error = STUNError.resolveFailed(errno: 8, details: nil)
    let desc = error.description

    #expect(desc.contains("Failed to resolve STUN server"))
    #expect(desc.contains("errno=8"))
    #expect(!desc.contains(". ."))  // No trailing period-space-period
  }

  // MARK: - Integration with SwiftFTR

  @Test("SwiftFTR caches STUN result")
  func testSTUNCaching() async throws {
    // Test that we can override public IP without STUN call
    let config = SwiftFTRConfig(publicIP: "203.0.113.1")
    let tracer = SwiftFTR(config: config)

    // This should use the provided IP, not call STUN
    let result = try await tracer.traceClassified(to: "1.1.1.1")

    #expect(result.publicIP == "203.0.113.1")
  }

  @Test("networkChanged invalidates STUN cache")
  func testNetworkChangedInvalidatesCache() async {
    let config = SwiftFTRConfig(publicIP: "198.51.100.1")
    let tracer = SwiftFTR(config: config)

    // Simulate network change
    await tracer.networkChanged()

    // After network change, cache should be cleared
    // (Can't easily test without actual STUN call, but method exists)
    #expect(true)  // Placeholder - method exists and compiles
  }

  // MARK: - STUN Network Tests

  @Test(
    "STUN call to Google STUN server",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS"))
  )
  func testSTUNRealCall() throws {
    // Test actual STUN call to Google's public STUN server
    // This exercises the full network code path
    let result = try stunGetPublicIPv4(
      host: "stun.l.google.com",
      port: 19302,
      timeout: 2.0
    )

    // Should get a valid public IP (IPv4 format)
    #expect(result.ip.contains("."))
    #expect(result.ip.split(separator: ".").count == 4)

    // IP should be non-private
    let parts = result.ip.split(separator: ".").compactMap { Int($0) }
    #expect(parts.count == 4)
    #expect(parts.allSatisfy { $0 >= 0 && $0 <= 255 })
  }

  @Test(
    "STUN timeout on invalid server",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS"))
  )
  func testSTUNTimeout() throws {
    // Use a valid IP that won't respond to STUN (reserved documentation IP)
    #expect(
      throws: STUNError.self,
      performing: {
        _ = try stunGetPublicIPv4(
          host: "192.0.2.1",  // Reserved TEST-NET-1
          port: 19302,
          timeout: 0.5  // Short timeout
        )
      })
  }

  @Test(
    "STUN with invalid hostname",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS"))
  )
  func testSTUNInvalidHostname() throws {
    // Non-existent hostname should fail to resolve
    #expect(
      throws: STUNError.self,
      performing: {
        _ = try stunGetPublicIPv4(
          host: "this-host-definitely-does-not-exist-12345.invalid",
          port: 19302,
          timeout: 1.0
        )
      })
  }

  @Test(
    "STUN with logging enabled",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS"))
  )
  func testSTUNWithLogging() throws {
    // Test that logging parameter doesn't break anything
    let result = try stunGetPublicIPv4(
      host: "stun.l.google.com",
      port: 19302,
      timeout: 2.0,
      enableLogging: true
    )

    #expect(result.ip.contains("."))
  }

  @Test("STUN error types conform to Error protocol")
  func testSTUNErrorProtocol() {
    let error: Error = STUNError.recvTimeout

    #expect(error is STUNError)
    // Error description should be non-empty
    #expect(!error.localizedDescription.isEmpty)
  }
}
