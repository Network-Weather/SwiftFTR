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
    let nonVPNContext = VPNContext.forInterface("test-interface")
    #expect(nonVPNContext.isVPNTrace == false)
    #expect(nonVPNContext.traceInterface == "test-interface")

    // Nil interface should not create VPN context
    let nilContext = VPNContext.forInterface(nil)
    #expect(nilContext.isVPNTrace == false)
    #expect(nilContext.traceInterface == nil)
  }

  /// `VPNContext.forInterface(_:)` now populates `vpnLocalIPs` by walking
  /// `getifaddrs` and collecting every v4 and v6 address bound to an
  /// interface that `NetworkInterfaceDiscovery.isVPNInterface` matches.
  /// This test asserts the discovery doesn't crash and returns *something
  /// shaped right*: any host running this test likely has at least one
  /// `utun*` interface (Apple system services use them even without an
  /// active VPN), so the set is usually non-empty — but we don't fail
  /// if it is, because CI runners can be configured without them.
  @Test("VPNContext.forInterface populates vpnLocalIPs from getifaddrs")
  func testVPNContextPopulatesLocalIPs() {
    let firstContext = VPNContext.forInterface("utun0")
    // Every entry should look like a valid IPv4 or IPv6 string.
    for ip in firstContext.vpnLocalIPs {
      let isV4 = detectAddressFamily(ip) == AF_INET
      // Strip %zone for v6 family check.
      let bare = ip.split(separator: "%", maxSplits: 1).first.map(String.init) ?? ip
      let isV6 = detectAddressFamily(bare) == AF_INET6
      #expect(isV4 || isV6, "Each vpnLocalIPs entry should be a valid v4 or v6 string: \(ip)")
    }
    // Same set is returned regardless of the specific interface argument;
    // the population walks every VPN interface on the host, not just the
    // named one. Sanity check that calling twice with different VPN-shaped
    // names yields the same set.
    let secondContext = VPNContext.forInterface("utun1")
    #expect(firstContext.vpnLocalIPs == secondContext.vpnLocalIPs)
    // And a non-VPN interface produces no context at all (empty set is fine).
    let nonVPNContext = VPNContext.forInterface("test-interface")
    // For a non-VPN interface, vpnLocalIPs reflects the host's other VPN
    // interfaces (still useful — the classifier needs them to recognize
    // VPN hops in a split-tunnel trace going out a physical interface).
    for ip in nonVPNContext.vpnLocalIPs {
      let bare = ip.split(separator: "%", maxSplits: 1).first.map(String.init) ?? ip
      #expect(detectAddressFamily(bare) == AF_INET || detectAddressFamily(bare) == AF_INET6)
    }
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

  // MARK: - VPN Interface Trace Tests

  @Test("VPN interface trace classifies private IPs as VPN, public as transit")
  func testVPNInterfaceTraceClassification() async throws {
    // Real trace through Tailscale exit node (utun17 interface)
    // First hop is already the VPN peer - no local gateway visible
    let hops: [TraceHop] = [
      TraceHop(
        ttl: 1, ipAddress: "100.120.205.29", rtt: 0.097, reachedDestination: false,
        hostname: "trogdor.tail3b5a2.ts.net"),  // VPN peer (CGNAT = VPN)
      TraceHop(
        ttl: 2, ipAddress: "192.168.1.1", rtt: 0.097, reachedDestination: false,
        hostname: "unifi.localdomain"),  // Exit node's LAN router (private = VPN)
      TraceHop(
        ttl: 3, ipAddress: "157.131.132.109", rtt: 0.093, reachedDestination: false,
        hostname: "lo0.bras2.rdcyca01.sonic.net"),  // Exit node's ISP (public = TRANSIT)
      TraceHop(
        ttl: 4, ipAddress: "135.180.179.42", rtt: 0.099, reachedDestination: false,
        hostname: "135-180-179-42.dsl.dynamic.sonic.net"),  // Transit (public = TRANSIT)
      TraceHop(
        ttl: 5, ipAddress: "1.1.1.1", rtt: 0.114, reachedDestination: true,
        hostname: "one.one.one.one"),  // Destination
    ]
    let trace = TraceResult(destination: "1.1.1.1", maxHops: 5, reached: true, hops: hops)

    let vpnContext = VPNContext(traceInterface: "utun17", isVPNTrace: true, vpnLocalIPs: [])

    let classifier = TraceClassifier()
    let classified = try await classifier.classify(
      trace: trace,
      destinationIP: "1.1.1.1",
      resolver: VPNTestASNResolver(mapping: [:]),
      vpnContext: vpnContext
    )

    // Private/CGNAT IPs = VPN infrastructure
    #expect(classified.hops[0].category == .vpn)  // CGNAT (100.x) = VPN
    #expect(classified.hops[1].category == .vpn)  // Private (192.168.x) = VPN

    // Public IPs = exit node's upstream (TRANSIT, not our ISP)
    #expect(classified.hops[2].category == .transit)  // Exit node's ISP
    #expect(classified.hops[3].category == .transit)  // Transit

    // Destination
    #expect(classified.hops[4].category == .destination)
  }

  @Test("Non-VPN trace with CGNAT still classified as ISP")
  func testNonVPNTraceBackwardCompatibility() async throws {
    // Non-VPN trace with ISP CGNAT
    let hops: [TraceHop] = [
      TraceHop(
        ttl: 1, ipAddress: "192.168.1.1", rtt: 0.001, reachedDestination: false,
        hostname: "router.local"),
      TraceHop(
        ttl: 2, ipAddress: "100.64.0.1", rtt: 0.005, reachedDestination: false,
        hostname: nil),  // ISP CGNAT
      TraceHop(
        ttl: 3, ipAddress: "203.0.113.1", rtt: 0.010, reachedDestination: false, hostname: nil),
      TraceHop(
        ttl: 4, ipAddress: "8.8.8.8", rtt: 0.015, reachedDestination: true,
        hostname: "dns.google"),
    ]
    let trace = TraceResult(destination: "dns.google", maxHops: 4, reached: true, hops: hops)

    // No VPN context
    let classifier = TraceClassifier()
    let classified = try await classifier.classify(
      trace: trace,
      destinationIP: "8.8.8.8",
      resolver: VPNTestASNResolver(mapping: [:]),
      vpnContext: nil
    )

    // Local gateway
    #expect(classified.hops[0].category == .local)

    // CGNAT without VPN context should be ISP
    #expect(classified.hops[1].category == .isp)
  }

  @Test("VPN trace to internal destination")
  func testVPNTraceToInternalDestination() async throws {
    // Trace through VPN to a private IP (VPN-internal server)
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

    // All intermediate hops are VPN
    #expect(classified.hops[0].category == .vpn)
    #expect(classified.hops[1].category == .vpn)
    // Final hop is destination (even if private IP)
    #expect(classified.hops[2].category == .destination)
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
