import Foundation
import Testing

@testable import SwiftFTR

@Suite("VPN Classification Tests")
struct VPNClassificationTests {

  // MARK: - VPNContext Tests

  @Test("VPNContext auto-detects VPN from interface name")
  func testVPNContextAutoDetect() {
    // VPN interfaces should create VPN context
    let utunContext = VPNContext.forInterface("utun3")
    #expect(utunContext.isVPNTrace == true)
    #expect(utunContext.traceInterface == "utun3")

    let ipsecContext = VPNContext.forInterface("ipsec0")
    #expect(ipsecContext.isVPNTrace == true)

    let pppContext = VPNContext.forInterface("ppp0")
    #expect(pppContext.isVPNTrace == true)

    // Non-VPN interfaces should not create VPN context
    let wifiContext = VPNContext.forInterface("en0")
    #expect(wifiContext.isVPNTrace == false)
    #expect(wifiContext.traceInterface == "en0")

    // Nil interface should not create VPN context
    let nilContext = VPNContext.forInterface(nil)
    #expect(nilContext.isVPNTrace == false)
    #expect(nilContext.traceInterface == nil)
  }

  // MARK: - HopCategory Tests

  @Test("VPN HopCategory exists")
  func testVPNHopCategory() {
    #expect(HopCategory.vpn.rawValue == "VPN")
  }

  @Test("HopCategory is Codable")
  func testHopCategoryCodable() throws {
    let categories: [HopCategory] = [.local, .isp, .transit, .destination, .unknown, .vpn]

    let encoder = JSONEncoder()
    let data = try encoder.encode(categories)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode([HopCategory].self, from: data)

    #expect(decoded == categories)
  }

  // MARK: - Classification Logic Tests

  @Test("CGNAT classified as VPN when VPN context active")
  func testCGNATWithVPNContext() async throws {
    // Create a mock trace with CGNAT IP as first hop
    let hops: [TraceHop] = [
      TraceHop(
        ttl: 1, ipAddress: "100.100.100.1", rtt: 0.005, reachedDestination: false,
        hostname: "vpn-gateway.example.com"),
      TraceHop(
        ttl: 2, ipAddress: "192.168.1.1", rtt: 0.010, reachedDestination: false,
        hostname: "router.local"),
      TraceHop(
        ttl: 3, ipAddress: "73.1.2.3", rtt: 0.015, reachedDestination: true, hostname: nil),
    ]
    let trace = TraceResult(destination: "example.com", maxHops: 3, reached: true, hops: hops)

    // Create VPN context
    let vpnContext = VPNContext(traceInterface: "utun3", isVPNTrace: true, vpnLocalIPs: [])

    // Classify with VPN context
    let classifier = TraceClassifier()
    let classified = try await classifier.classify(
      trace: trace,
      destinationIP: "73.1.2.3",
      resolver: VPNTestASNResolver(mapping: [:]),
      vpnContext: vpnContext
    )

    // First hop (CGNAT) should be VPN when VPN context is active
    #expect(classified.hops[0].category == .vpn)

    // Second hop (private IP after VPN) should also be VPN (part of VPN solution)
    #expect(classified.hops[1].category == .vpn)
  }

  @Test("CGNAT classified as ISP when no VPN context")
  func testCGNATWithoutVPNContext() async throws {
    // Create a mock trace with CGNAT IP as first hop (typical ISP CGNAT)
    let hops: [TraceHop] = [
      TraceHop(
        ttl: 1, ipAddress: "100.64.0.1", rtt: 0.005, reachedDestination: false, hostname: nil),
      TraceHop(
        ttl: 2, ipAddress: "73.1.2.3", rtt: 0.015, reachedDestination: true, hostname: nil),
    ]
    let trace = TraceResult(destination: "example.com", maxHops: 2, reached: true, hops: hops)

    // Classify without VPN context
    let classifier = TraceClassifier()
    let classified = try await classifier.classify(
      trace: trace,
      destinationIP: "73.1.2.3",
      resolver: VPNTestASNResolver(mapping: [:]),
      vpnContext: nil
    )

    // First hop (CGNAT) should be ISP
    #expect(classified.hops[0].category == .isp)
  }

  @Test("Private IPs after VPN hop classified as VPN")
  func testPrivateIPsAfterVPNClassifiedAsVPN() async throws {
    // Create a trace that goes through VPN to a 10.x network
    let hops: [TraceHop] = [
      TraceHop(
        ttl: 1, ipAddress: "100.100.100.1", rtt: 0.005, reachedDestination: false,
        hostname: "vpn-gateway.corp.example.com"),
      TraceHop(
        ttl: 2, ipAddress: "10.0.0.1", rtt: 0.010, reachedDestination: false, hostname: nil),
      TraceHop(
        ttl: 3, ipAddress: "10.0.0.50", rtt: 0.015, reachedDestination: true, hostname: nil),
    ]
    let trace = TraceResult(destination: "internal.corp", maxHops: 3, reached: true, hops: hops)

    let vpnContext = VPNContext(traceInterface: "utun3", isVPNTrace: true, vpnLocalIPs: [])

    let classifier = TraceClassifier()
    let classified = try await classifier.classify(
      trace: trace,
      destinationIP: "10.0.0.50",
      resolver: VPNTestASNResolver(mapping: [:]),
      vpnContext: vpnContext
    )

    // All hops through VPN should be VPN
    #expect(classified.hops[0].category == .vpn)
    #expect(classified.hops[1].category == .vpn)
    #expect(classified.hops[2].category == .vpn)
  }

  @Test("Exit node LAN classified as VPN")
  func testExitNodeLANClassifiedAsVPN() async throws {
    // Create a trace through VPN to exit node's 192.168.x network
    let hops: [TraceHop] = [
      TraceHop(
        ttl: 1, ipAddress: "100.120.205.29", rtt: 0.005, reachedDestination: false,
        hostname: "exit-node.vpn.example.com"),
      TraceHop(
        ttl: 2, ipAddress: "192.168.1.1", rtt: 0.010, reachedDestination: false,
        hostname: "router.local"),
      TraceHop(
        ttl: 3, ipAddress: "157.131.132.109", rtt: 0.015, reachedDestination: false,
        hostname: nil),
    ]
    let trace = TraceResult(destination: "example.com", maxHops: 3, reached: false, hops: hops)

    let vpnContext = VPNContext(traceInterface: "utun16", isVPNTrace: true, vpnLocalIPs: [])

    let classifier = TraceClassifier()
    let classified = try await classifier.classify(
      trace: trace,
      destinationIP: "93.184.216.34",
      resolver: VPNTestASNResolver(mapping: [:]),
      vpnContext: vpnContext
    )

    // First hop should be VPN
    #expect(classified.hops[0].category == .vpn)

    // 192.168.x after VPN should be VPN (exit node's LAN is part of VPN solution)
    #expect(classified.hops[1].category == .vpn)
  }
}

// MARK: - Mock ASN Resolver

/// Mock ASN resolver for VPN classification testing
private struct VPNTestASNResolver: ASNResolver {
  let mapping: [String: ASNInfo]

  func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
    var result: [String: ASNInfo] = [:]
    for ip in ipv4Addrs {
      if let info = mapping[ip] {
        result[ip] = info
      }
    }
    return result
  }
}
