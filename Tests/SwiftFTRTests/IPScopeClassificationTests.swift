import Foundation
import Testing

@testable import SwiftFTR

@Suite("IP Scope Classification")
struct IPScopeClassificationTests {
  @Test("IPv6 scope is derived from address bytes")
  func ipv6ScopeUsesAddressBytes() {
    let cases: [(String, IPAddressScope)] = [
      ("fc00::1", .privateNetwork),
      ("fdff:ffff::1", .privateNetwork),
      ("fe80::1%test-interface-a", .linkLocal),
      ("febf:ffff::1", .linkLocal),
      ("::1", .loopback),
      ("::", .unspecified),
      ("ff02::1", .multicast),
      ("2606:4700:4700::1111", .global),
    ]

    for (address, expectedScope) in cases {
      #expect(ipAddressScope(of: address) == expectedScope)
    }
  }

  @Test("IPv4-mapped IPv6 addresses inherit IPv4 scope")
  func mappedIPv4Scope() {
    let cases: [(String, IPAddressScope)] = [
      ("::ffff:10.0.0.1", .privateNetwork),
      ("::ffff:169.254.1.1", .linkLocal),
      ("::ffff:100.64.0.1", .carrierGradeNAT),
      ("::ffff:127.0.0.1", .loopback),
      ("::ffff:224.0.0.1", .multicast),
      ("::ffff:8.8.8.8", .global),
    ]

    for (address, expectedScope) in cases {
      #expect(ipAddressScope(of: address) == expectedScope)
    }
    #expect(ipAddressesAreEqual("::ffff:192.168.1.10", "192.168.1.10"))
    #expect(
      ipAddressesAreEqual(
        "fe80::1%test-interface-a", "fe80:0:0:0:0:0:0:1%test-interface-a"))
    #expect(ipAddressesAreEqual("fe80::1%test-interface-a", "fe80::1%test-interface-b") == false)
    #expect(ipAddressesAreEqual("ff02::1%7", "ff02:0:0:0:0:0:0:1%7"))
    #expect(ipAddressesAreEqual("ff02::1%test-interface-a", "ff02::1") == false)
    #expect(
      ipAddressesAreEqual(
        "2001:4860::1%test-interface-a", "2001:4860::1%test-interface-b") == false)
  }

  @Test("Non-global IPv6 hops stay local and out of ASN resolution")
  func nonGlobalIPv6Classification() async throws {
    let destination = "2606:4700:4700:0:0:0:0:1111"
    let hopAddresses = [
      "fc00::1",
      "fe80::1%test-interface-a",
      "::1",
      "::",
      "ff02::1",
      "::ffff:192.168.1.20",
      "::ffff:100.64.0.1",
      "::ffff:8.8.8.8",
      "2606:4700:4700::1111",
    ]
    let trace = TraceResult(
      destination: "one.one.one.one",
      maxHops: hopAddresses.count,
      reached: true,
      hops: hopAddresses.enumerated().map { index, address in
        TraceHop(
          ttl: index + 1,
          ipAddress: address,
          rtt: 0.001,
          reachedDestination: index == hopAddresses.count - 1)
      })
    let resolver = RecordingASNResolver()

    let result = try await TraceClassifier().classify(
      trace: trace,
      destinationIP: destination,
      resolver: resolver,
      publicIP: "198.51.100.20")

    #expect(
      result.hops.map(\.category) == [
        .local, .local, .local, .local, .local, .local, .isp, .transit, .destination,
      ])

    let requestedAddresses = await resolver.requestedAddresses()
    #expect(requestedAddresses.contains("8.8.8.8"))
    #expect(requestedAddresses.contains("::ffff:8.8.8.8") == false)
    #expect(requestedAddresses.contains(destination))
    #expect(requestedAddresses.allSatisfy(isGloballyRoutableIPAddress))
  }

  @Test("Mapped public IPv4 uses its canonical ASN lookup key")
  func mappedPublicIPv4ASNLookup() async throws {
    let resolver = RecordingASNResolver(mapping: [
      "8.8.8.8": ASNInfo(asn: 15_169, name: "Google")
    ])
    let trace = TraceResult(
      destination: "example.net",
      maxHops: 1,
      reached: false,
      hops: [
        TraceHop(
          ttl: 1,
          ipAddress: "::ffff:8.8.8.8",
          rtt: 0.001,
          reachedDestination: false)
      ])

    let result = try await TraceClassifier().classify(
      trace: trace,
      destinationIP: "1.1.1.1",
      resolver: resolver,
      publicIP: "198.51.100.20")

    let hop = try #require(result.hops.first)
    #expect(hop.ip == "::ffff:8.8.8.8")
    #expect(hop.asn == 15_169)
    #expect(hop.asName == "Google")
    let requestedAddresses = await resolver.requestedAddresses()
    #expect(requestedAddresses.contains("8.8.8.8"))
    #expect(requestedAddresses.contains("::ffff:8.8.8.8") == false)
  }

  @Test("An exact VPN-local public address is VPN without relabeling its neighbors")
  func exactVPNLocalAddress() async throws {
    let trace = TraceResult(
      destination: "example.net",
      maxHops: 3,
      reached: true,
      hops: [
        TraceHop(
          ttl: 1,
          ipAddress: "2001:4860:0:0:0:0:0:8844",
          rtt: 0.001,
          reachedDestination: false),
        TraceHop(
          ttl: 2,
          ipAddress: "2001:4860::8845",
          rtt: 0.002,
          reachedDestination: false),
        TraceHop(
          ttl: 3,
          ipAddress: "2606:4700:4700::1111",
          rtt: 0.003,
          reachedDestination: true),
      ])
    let context = VPNContext(
      traceInterface: "test-interface",
      isVPNTrace: false,
      vpnLocalIPs: ["2001:4860::8844"])

    let result = try await TraceClassifier().classify(
      trace: trace,
      destinationIP: "2606:4700:4700::1111",
      resolver: RecordingASNResolver(),
      publicIP: "198.51.100.20",
      vpnContext: context)

    #expect(result.hops.map(\.category) == [.vpn, .transit, .destination])
  }

  @Test("Destination equality takes precedence over VPN-local and scope rules")
  func destinationPrecedesVPNRules() async throws {
    let trace = TraceResult(
      destination: "internal.example",
      maxHops: 2,
      reached: true,
      hops: [
        TraceHop(
          ttl: 1,
          ipAddress: "::ffff:100.64.1.1",
          rtt: 0.001,
          reachedDestination: false),
        TraceHop(
          ttl: 2,
          ipAddress: "::ffff:192.168.1.10",
          rtt: 0.002,
          reachedDestination: true),
      ])
    let context = VPNContext(
      traceInterface: "utun3",
      isVPNTrace: true,
      vpnLocalIPs: ["192.168.1.10"])

    let result = try await TraceClassifier().classify(
      trace: trace,
      destinationIP: "192.168.1.10",
      resolver: RecordingASNResolver(),
      publicIP: "198.51.100.20",
      vpnContext: context)

    #expect(result.hops.map(\.category) == [.vpn, .destination])
  }

  @Test("Built-in resolvers reject non-global addresses before lookup")
  func resolversFilterNonGlobalAddresses() async throws {
    let addresses = [
      "10.0.0.1", "100.64.0.1", "fc00::1", "fe80::1", "::1", "::", "ff02::1",
      "::ffff:192.168.1.1", "::ffff:100.64.0.1",
    ]

    let dnsResult = try await CymruDNSResolver().resolve(ipv4Addrs: addresses, timeout: 0.01)
    let localResult = try await LocalASNResolver().resolve(ipv4Addrs: addresses, timeout: 0.01)
    let hybridResult = try await HybridASNResolver(source: .embedded).resolve(
      ipv4Addrs: addresses,
      timeout: 0.01)

    #expect(dnsResult.isEmpty)
    #expect(localResult.isEmpty)
    #expect(hybridResult.isEmpty)
  }
}

private actor RecordingASNResolver: ASNResolver {
  private let mapping: [String: ASNInfo]
  private var addresses: Set<String> = []

  init(mapping: [String: ASNInfo] = [:]) {
    self.mapping = mapping
  }

  func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
    addresses.formUnion(ipv4Addrs)
    return mapping.filter { ipv4Addrs.contains($0.key) }
  }

  func requestedAddresses() -> Set<String> {
    addresses
  }
}
