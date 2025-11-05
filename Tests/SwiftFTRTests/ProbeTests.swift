import Foundation
import Testing

@testable import SwiftFTR

@Suite("TCP Probe Tests")
struct TCPProbeTests {

  @Test(
    "TCP probe to reachable port",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")))
  func testReachablePort() async throws {
    // Test against Cloudflare DNS on port 53
    let result = try await tcpProbe(host: "1.1.1.1", port: 53, timeout: 3.0)

    #expect(result.isReachable)
    #expect(result.rtt != nil)
    #expect(result.rtt! > 0)
    #expect(result.rtt! < 5.0)
  }

  @Test("TCP probe to closed port (localhost)")
  func testClosedPort() async throws {
    // Test against localhost closed port - guaranteed RST response
    // Connection refused (RST) still counts as reachable
    let result = try await tcpProbe(host: "127.0.0.1", port: 9999, timeout: 2.0)

    // Expect success (RST = host reachable, port closed)
    #expect(result.isReachable)
    #expect(result.rtt != nil)
    #expect(result.rtt! < 0.1)  // Localhost should be instant
  }

  @Test(
    "TCP probe to filtered port (real-world behavior)",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")))
  func testFilteredPort() async throws {
    // Test against remote host with filtered port
    // Many modern firewalls filter (drop) rather than reject (RST)
    // Filtered ports timeout, which counts as unreachable
    let result = try await tcpProbe(host: "8.8.8.8", port: 12345, timeout: 2.0)

    // Filtered ports timeout (no response) = unreachable
    #expect(!result.isReachable)
    #expect(result.error != nil)
  }

  @Test("TCP probe to unreachable host")
  func testUnreachableHost() async throws {
    // Test against TEST-NET-1 (should timeout)
    let result = try await tcpProbe(host: "192.0.2.1", port: 80, timeout: 2.0)

    #expect(!result.isReachable)
    #expect(result.rtt == nil)
    #expect(result.error != nil)
  }

  @Test(
    "TCP probe with invalid hostname",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")))
  func testInvalidHostname() async throws {
    let result = try await tcpProbe(
      host: "this-hostname-does-not-exist.invalid",
      port: 80,
      timeout: 2.0
    )

    #expect(!result.isReachable)
  }
}

@Suite("UDP Probe Tests")
struct UDPProbeTests {

  @Test(
    "UDP probe to reachable host",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")))
  func testReachableHost() async throws {
    // Test against Cloudflare DNS on port 53
    // Need to send valid DNS query to get response
    let dnsQuery = buildDNSQuery(domain: "example.com")
    let result = try await udpProbe(host: "1.1.1.1", port: 53, timeout: 3.0, payload: dnsQuery)

    #expect(result.isReachable)
    #expect(result.rtt != nil)
    #expect(result.responseType != nil)
  }

  @Test("UDP probe to unreachable host")
  func testUnreachableHost() async throws {
    // Test against TEST-NET-1 (should timeout)
    let result = try await udpProbe(host: "192.0.2.1", port: 53, timeout: 2.0)

    #expect(!result.isReachable)
    #expect(result.rtt == nil)
    #expect(result.responseType == "timeout")
  }

  @Test(
    "UDP probe with DNS payload",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")))
  func testWithDNSPayload() async throws {
    // Send valid DNS query to get response
    let dnsQuery = buildDNSQuery(domain: "google.com")
    let result = try await udpProbe(host: "8.8.8.8", port: 53, timeout: 3.0, payload: dnsQuery)

    // Google DNS should respond to valid DNS query
    #expect(result.isReachable)
  }

  // Helper to build a simple DNS query packet
  private func buildDNSQuery(domain: String) -> Data {
    var data = Data()

    // DNS Header (12 bytes)
    data.append(contentsOf: [0x12, 0x34])  // Transaction ID
    data.append(contentsOf: [0x01, 0x00])  // Flags: standard query, recursion desired
    data.append(contentsOf: [0x00, 0x01])  // Questions: 1
    data.append(contentsOf: [0x00, 0x00])  // Answer RRs: 0
    data.append(contentsOf: [0x00, 0x00])  // Authority RRs: 0
    data.append(contentsOf: [0x00, 0x00])  // Additional RRs: 0

    // Question Section: encode domain name
    for label in domain.split(separator: ".") {
      let labelBytes = Array(label.utf8)
      data.append(UInt8(labelBytes.count))
      data.append(contentsOf: labelBytes)
    }
    data.append(0x00)  // End of domain name

    // QTYPE: A record (1)
    data.append(contentsOf: [0x00, 0x01])
    // QCLASS: IN (1)
    data.append(contentsOf: [0x00, 0x01])

    return data
  }
}

@Suite("DNS Probe Tests")
struct DNSProbeTests {

  @Test(
    "DNS probe to valid server",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")))
  func testValidServer() async throws {
    // Test against Cloudflare DNS
    let result = try await dnsProbe(server: "1.1.1.1", query: "example.com", timeout: 3.0)

    #expect(result.isReachable)
    #expect(result.rtt != nil)
    #expect(result.responseCode != nil)
    #expect(result.responseCode == 0)
    #expect(result.rtt! > 0)
    #expect(result.rtt! < 5.0)
  }

  @Test(
    "DNS probe with NXDOMAIN",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")))
  func testNXDOMAIN() async throws {
    // Query for non-existent domain
    let result = try await dnsProbe(
      server: "8.8.8.8",
      query: "this-domain-definitely-does-not-exist-12345.invalid",
      timeout: 3.0
    )

    #expect(result.isReachable)
    #expect(result.responseCode != nil)
    #expect(result.responseCode == 3)
  }

  @Test("DNS probe to unreachable server")
  func testUnreachableServer() async throws {
    // Use 0.0.0.0 ("this network" - not routable, will timeout)
    // Other reserved ranges may be intercepted by DNS forwarders
    let result = try await dnsProbe(server: "0.0.0.0", query: "example.com", timeout: 2.0)

    #expect(!result.isReachable)
    #expect(result.rtt == nil)
    #expect(result.error != nil)
  }

  @Test("DNS probe with invalid server IP")
  func testInvalidServerIP() async throws {
    let result = try await dnsProbe(
      server: "invalid.ip.address", query: "example.com", timeout: 2.0)

    #expect(!result.isReachable)
    #expect(result.error != nil)
  }
}

@Suite("HTTP Probe Tests")
struct HTTPProbeTests {

  @Test(
    "HTTP probe successful request",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")))
  func testSuccessfulRequest() async throws {
    // Test against example.com (HTTP)
    let result = try await httpProbe(url: "http://example.com", timeout: 5.0)

    #expect(result.isReachable)
    #expect(result.statusCode != nil)
    #expect(result.statusCode == 200)
    #expect(result.rtt != nil)
    #expect(result.rtt! > 0)
  }

  @Test(
    "HTTPS probe successful request",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")))
  func testHTTPSSuccessfulRequest() async throws {
    // Test against example.com (HTTPS)
    let result = try await httpProbe(url: "https://example.com", timeout: 5.0)

    #expect(result.isReachable)
    #expect(result.statusCode != nil)
    #expect(result.statusCode == 200)
    #expect(result.rtt != nil)
  }

  @Test(
    "HTTP probe 404 response",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")))
  func test404Response() async throws {
    // Test against URL that returns 404
    let result = try await httpProbe(
      url: "http://example.com/this-page-does-not-exist-12345",
      timeout: 5.0
    )

    // 404 still counts as success (server is reachable)
    #expect(result.isReachable)
    #expect(result.statusCode == 404)
    #expect(result.rtt != nil)
  }

  @Test("HTTP probe invalid URL")
  func testInvalidURL() async throws {
    let result = try await httpProbe(url: "not a valid url", timeout: 2.0)

    #expect(!result.isReachable)
    #expect(result.error != nil)
  }

  @Test("HTTP probe unreachable host")
  func testUnreachableHost() async throws {
    // Test against TEST-NET-1
    let result = try await httpProbe(url: "http://192.0.2.1", timeout: 2.0)

    #expect(!result.isReachable)
    #expect(result.statusCode == nil)
    #expect(result.error != nil)
  }

  @Test(
    "HTTP probe with redirect",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")))
  func testWithRedirect() async throws {
    // Test redirect handling (example.com may redirect to HTTPS)
    let config = HTTPProbeConfig(url: "http://example.com", timeout: 5.0, followRedirects: false)
    let result = try await httpProbe(config: config)

    #expect(result.isReachable)
    // Status code could be 200 or 3xx depending on redirect behavior
    #expect(result.statusCode != nil)
  }
}

@Suite("Probe Concurrency Tests")
struct ProbeConcurrencyTests {

  @Test(
    "Concurrent probes",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")))
  func testConcurrentProbes() async throws {
    // Test running multiple probes concurrently
    async let tcp = tcpProbe(host: "1.1.1.1", port: 53, timeout: 3.0)
    async let dns = dnsProbe(server: "8.8.8.8", query: "example.com", timeout: 3.0)
    async let http = httpProbe(url: "http://example.com", timeout: 5.0)

    let (tcpResult, dnsResult, httpResult) = try await (tcp, dns, http)

    #expect(tcpResult.isReachable)
    #expect(dnsResult.isReachable)
    #expect(httpResult.isReachable)
  }
}
