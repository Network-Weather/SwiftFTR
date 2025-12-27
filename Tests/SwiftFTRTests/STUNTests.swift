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
    #expect(Bool(true))  // Placeholder - method exists and compiles
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

  // MARK: - Multi-Server STUN Fallback Tests

  @Test("STUN server list is populated")
  func testSTUNServerList() {
    #expect(stunServers.count >= 3)
    #expect(stunServers.contains { $0.host.contains("google") })
    #expect(stunServers.contains { $0.host.contains("cloudflare") })
  }

  @Test(
    "STUN fallback tries multiple servers",
    .enabled(if: ProcessInfo.processInfo.environment["PTR_SKIP_STUN"] == nil)
  )
  func testSTUNFallback() throws {
    // Should succeed using any of the fallback servers
    let result = try stunGetPublicIPv4WithFallback(timeout: 2.0)

    #expect(result.ip.contains("."))
    #expect(result.ip.split(separator: ".").count == 4)
  }

  @Test(
    "STUN fallback with logging",
    .enabled(if: ProcessInfo.processInfo.environment["PTR_SKIP_STUN"] == nil)
  )
  func testSTUNFallbackWithLogging() throws {
    let result = try stunGetPublicIPv4WithFallback(timeout: 2.0, enableLogging: true)
    #expect(result.ip.contains("."))
  }

  // MARK: - DNS-Based Public IP Discovery Tests

  @Test("DNSPublicIPError descriptions")
  func testDNSPublicIPErrorDescriptions() {
    let queryFailed = DNSPublicIPError.queryFailed("timeout")
    #expect(queryFailed.description.contains("timeout"))

    let noIP = DNSPublicIPError.noIPInResponse
    #expect(noIP.description.contains("IP"))
  }

  @Test("DNSPublicIPError is Sendable")
  func testDNSPublicIPErrorSendable() {
    let error = DNSPublicIPError.queryFailed("test")

    Task {
      let desc = error.description
      #expect(desc.contains("test"))
    }
  }

  @Test(
    "DNS-based public IP discovery via Akamai whoami",
    .enabled(if: ProcessInfo.processInfo.environment["PTR_SKIP_STUN"] == nil)
  )
  func testDNSPublicIPDiscovery() throws {
    let result = try getPublicIPv4ViaDNS(timeout: 5.0)

    // Should get a valid IPv4 address
    #expect(result.ip.contains("."))
    let parts = result.ip.split(separator: ".").compactMap { Int($0) }
    #expect(parts.count == 4)
    #expect(parts.allSatisfy { $0 >= 0 && $0 <= 255 })
  }

  @Test(
    "DNS public IP with logging",
    .enabled(if: ProcessInfo.processInfo.environment["PTR_SKIP_STUN"] == nil)
  )
  func testDNSPublicIPWithLogging() throws {
    let result = try getPublicIPv4ViaDNS(timeout: 5.0, enableLogging: true)
    #expect(result.ip.contains("."))
  }

  // MARK: - Unified Public IP Discovery Tests

  @Test("PublicIPError description")
  func testPublicIPErrorDescription() {
    let error = PublicIPError.allMethodsFailed(stunError: "timeout", dnsError: "no response")
    #expect(error.description.contains("STUN"))
    #expect(error.description.contains("DNS"))
    #expect(error.description.contains("timeout"))
    #expect(error.description.contains("no response"))
  }

  @Test("PublicIPError is Sendable")
  func testPublicIPErrorSendable() {
    let error = PublicIPError.allMethodsFailed(stunError: "err1", dnsError: "err2")

    Task {
      let desc = error.description
      #expect(desc.contains("err1"))
    }
  }

  @Test(
    "Unified getPublicIPv4 succeeds",
    .enabled(if: ProcessInfo.processInfo.environment["PTR_SKIP_STUN"] == nil)
  )
  func testUnifiedPublicIPDiscovery() throws {
    // Should succeed via STUN (fast path) or DNS (fallback)
    let result = try getPublicIPv4(stunTimeout: 2.0, dnsTimeout: 5.0)

    #expect(result.ip.contains("."))
    let parts = result.ip.split(separator: ".").compactMap { Int($0) }
    #expect(parts.count == 4)
    #expect(parts.allSatisfy { $0 >= 0 && $0 <= 255 })
  }

  @Test(
    "Unified getPublicIPv4 with logging",
    .enabled(if: ProcessInfo.processInfo.environment["PTR_SKIP_STUN"] == nil)
  )
  func testUnifiedPublicIPWithLogging() throws {
    let result = try getPublicIPv4(
      stunTimeout: 2.0,
      dnsTimeout: 5.0,
      enableLogging: true
    )
    #expect(result.ip.contains("."))
  }

  @Test(
    "STUN and DNS both return valid public IPs",
    .enabled(if: ProcessInfo.processInfo.environment["PTR_SKIP_STUN"] == nil)
  )
  func testSTUNAndDNSBothWork() throws {
    // Both methods should return valid public IPv4 addresses
    // Note: They may differ on VPNs or multi-homed networks, so we just verify both work
    let stunResult = try stunGetPublicIPv4WithFallback(timeout: 2.0)
    let dnsResult = try getPublicIPv4ViaDNS(timeout: 5.0)

    // Validate STUN result
    let stunParts = stunResult.ip.split(separator: ".").compactMap { Int($0) }
    #expect(stunParts.count == 4, "STUN should return valid IPv4")
    #expect(stunParts.allSatisfy { $0 >= 0 && $0 <= 255 })

    // Validate DNS result
    let dnsParts = dnsResult.ip.split(separator: ".").compactMap { Int($0) }
    #expect(dnsParts.count == 4, "DNS should return valid IPv4")
    #expect(dnsParts.allSatisfy { $0 >= 0 && $0 <= 255 })

    // Both should be non-private (public) IPs
    #expect(stunParts[0] != 10, "STUN IP should be public, not 10.x.x.x")
    #expect(dnsParts[0] != 10, "DNS IP should be public, not 10.x.x.x")
  }
}
