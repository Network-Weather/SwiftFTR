import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// What `seedPublicIP` (through `isGloballyRoutablePublicIP`) accepts as a public address, checked
/// against the IANA IPv4 and IPv6 Special-Purpose Address Registries and the IPv6 Address Space
/// registry (all as last updated October 2025). Hop classification is a separate question: some
/// of these ranges classify as `.global` there on purpose, which this table does not change.
@Suite("Public-IP validation follows the IANA registries")
struct PublicIPValidationTests {
  struct Case: Sendable, CustomTestStringConvertible {
    let address: String
    let accepted: Bool
    let why: String
    var testDescription: String { "\(address) (\(why))" }
  }

  static func accept(_ address: String, _ why: String) -> Case {
    Case(address: address, accepted: true, why: why)
  }

  static func reject(_ address: String, _ why: String) -> Case {
    Case(address: address, accepted: false, why: why)
  }

  static let ipv4: [Case] = [
    accept("8.8.8.8", "ordinary unicast"),
    reject("0.1.2.3", "0.0.0.0/8 this network, RFC 791"),
    reject("0.0.0.0", "0.0.0.0/32 this host, RFC 1122"),
    reject("10.1.2.3", "10.0.0.0/8 private, RFC 1918"),
    reject("100.64.0.1", "100.64.0.0/10 shared address space, RFC 6598"),
    reject("127.0.0.1", "127.0.0.0/8 loopback, RFC 1122"),
    reject("169.254.1.1", "169.254.0.0/16 link local, RFC 3927"),
    reject("172.16.0.1", "172.16.0.0/12 private, RFC 1918"),
    reject("192.0.0.1", "192.0.0.0/29 service continuity, RFC 7335"),
    reject("192.0.0.8", "192.0.0.8/32 dummy, RFC 7600"),
    accept("192.0.0.9", "192.0.0.9/32 PCP anycast, RFC 7723, globally reachable"),
    accept("192.0.0.10", "192.0.0.10/32 TURN anycast, RFC 8155, globally reachable"),
    reject("192.0.0.170", "192.0.0.170/32 NAT64 discovery, RFC 8880"),
    reject("192.0.0.200", "192.0.0.0/24 IETF protocol assignments, RFC 6890"),
    reject("192.0.2.1", "192.0.2.0/24 TEST-NET-1, RFC 5737"),
    accept("192.31.196.1", "192.31.196.0/24 AS112-v4, RFC 7535, globally reachable"),
    accept("192.52.193.1", "192.52.193.0/24 AMT, RFC 7450, globally reachable"),
    reject("192.88.99.1", "192.88.99.0/24 deprecated 6to4 relay anycast, RFC 7526"),
    reject("192.88.99.2", "192.88.99.2/32 6a44 relay anycast, RFC 6751"),
    reject("192.168.1.1", "192.168.0.0/16 private, RFC 1918"),
    accept("192.175.48.1", "192.175.48.0/24 AS112 direct delegation, RFC 7534"),
    reject("198.18.0.1", "198.18.0.0/15 benchmarking, RFC 2544"),
    reject("198.19.255.254", "198.18.0.0/15 benchmarking, RFC 2544"),
    reject("198.51.100.1", "198.51.100.0/24 TEST-NET-2, RFC 5737"),
    reject("203.0.113.1", "203.0.113.0/24 TEST-NET-3, RFC 5737"),
    reject("224.0.0.1", "224.0.0.0/4 multicast, RFC 5771"),
    reject("240.0.0.1", "240.0.0.0/4 reserved, RFC 1112"),
    reject("255.255.255.255", "limited broadcast, RFC 919"),
  ]

  /// The IPv4 table again, written as IPv4-mapped IPv6 (`::ffff:a.b.c.d`, RFC 4291), which has
  /// IPv4 routing semantics.
  static let ipv4Mapped: [Case] = ipv4.map {
    Case(address: "::ffff:\($0.address)", accepted: $0.accepted, why: "mapped: \($0.why)")
  }

  /// The IPv4 table again, embedded in the NAT64 well-known prefix (`64:ff9b::a.b.c.d`). RFC 6052
  /// section 3.1 forbids that prefix for non-global IPv4 addresses, so each embedded address is
  /// judged by the IPv4 rules.
  static let ipv4NAT64: [Case] = ipv4.map {
    Case(address: "64:ff9b::\($0.address)", accepted: $0.accepted, why: "NAT64: \($0.why)")
  }

  static let ipv6: [Case] = [
    accept("2606:4700:4700::1111", "ordinary global unicast in 2000::/3"),
    reject("::1", "::1/128 loopback, RFC 4291"),
    reject("::", "::/128 unspecified, RFC 4291"),
    reject("::8.8.8.8", "::/96 IPv4-compatible, deprecated by RFC 4291; reserved by IETF"),
    reject("::2:1", "::/8 reserved by IETF, RFC 4291"),
    accept(
      "64:ff9b::808:808", "64:ff9b::/96 NAT64 well-known prefix, RFC 6052, globally reachable"),
    reject("64:ff9b:1::1", "64:ff9b:1::/48 local-use translation, RFC 8215"),
    reject("100::1", "100::/64 discard-only, RFC 6666"),
    reject("100:0:0:1::1", "100:0:0:1::/64 dummy prefix, RFC 9780"),
    reject("100:1::1", "100::/8 reserved by IETF, RFC 4291"),
    reject("200::1", "200::/7 reserved by IETF, RFC 4048"),
    reject("1000::1", "1000::/4 reserved by IETF, RFC 4291"),
    reject("2001::1", "2001::/32 Teredo, RFC 4380"),
    accept("2001:1::1", "2001:1::1/128 PCP anycast, RFC 7723"),
    accept("2001:1::2", "2001:1::2/128 TURN anycast, RFC 8155"),
    accept("2001:1::3", "2001:1::3/128 DNS-SD SRP anycast, RFC 9665"),
    reject("2001:1::4", "2001::/23 IETF protocol assignments, RFC 2928"),
    reject("2001:2::1", "2001:2::/48 benchmarking, RFC 5180"),
    accept("2001:3::1", "2001:3::/32 AMT, RFC 7450"),
    accept("2001:4:112::1", "2001:4:112::/48 AS112-v6, RFC 7535"),
    reject("2001:10::1", "2001:10::/28 deprecated ORCHID, RFC 4843"),
    accept("2001:20::1", "2001:20::/28 ORCHIDv2, RFC 7343"),
    accept("2001:30::1", "2001:30::/28 DETs, RFC 9374"),
    reject("2001:1ff::1", "2001::/23 IETF protocol assignments, RFC 2928"),
    accept("2001:200::1", "global unicast just past 2001::/23"),
    reject("2001:db8::1", "2001:db8::/32 documentation, RFC 3849"),
    accept("2002:808:808::1", "2002::/16 6to4, RFC 3056, globally reachable N/A: left accepted"),
    accept("2620:4f:8000::1", "2620:4f:8000::/48 AS112 direct delegation, RFC 7534"),
    reject("3fff::1", "3fff::/20 documentation, RFC 9637"),
    accept("3fff:1000::1", "global unicast just past 3fff::/20"),
    reject("4000::1", "4000::/3 reserved by IETF, RFC 4291"),
    reject("5f00::1", "5f00::/16 SRv6 SIDs, RFC 9602"),
    reject("8000::1", "8000::/3 reserved by IETF, RFC 4291"),
    reject("e000::1", "e000::/4 reserved by IETF, RFC 4291"),
    reject("fc00::1", "fc00::/7 unique local, RFC 4193"),
    reject("fd12:3456::1", "fc00::/7 unique local, RFC 4193"),
    reject("fe00::1", "fe00::/9 reserved by IETF, RFC 4291"),
    reject("fe80::1", "fe80::/10 link-local, RFC 4291"),
    reject("fec0::1", "fec0::/10 site-local, deprecated by RFC 3879"),
    reject("feff:ffff::1", "fec0::/10 site-local, deprecated by RFC 3879"),
    reject("ff02::1", "ff00::/8 multicast, RFC 4291"),
  ]

  @Test("IPv4", arguments: ipv4)
  func ipv4Validation(_ entry: Case) {
    #expect(isGloballyRoutablePublicIP(entry.address) == entry.accepted)
  }

  @Test("IPv4-mapped IPv6", arguments: ipv4Mapped)
  func ipv4MappedValidation(_ entry: Case) {
    #expect(isGloballyRoutablePublicIP(entry.address) == entry.accepted)
  }

  @Test("IPv4 in the NAT64 well-known prefix", arguments: ipv4NAT64)
  func nat64Validation(_ entry: Case) {
    #expect(isGloballyRoutablePublicIP(entry.address) == entry.accepted)
  }

  @Test("IPv6", arguments: ipv6)
  func ipv6Validation(_ entry: Case) {
    #expect(isGloballyRoutablePublicIP(entry.address) == entry.accepted)
  }

  @Test("seedPublicIP rejects deprecated IPv6 site-local")
  func seedRejectsSiteLocal() async {
    let tracer = SwiftFTR(config: SwiftFTRConfig(noReverseDNS: true))
    #expect(await tracer.seedPublicIP("fec0::1", source: .gatewayReported) == false)
    #expect(await tracer.publicIP(for: .v4)?.address == nil)
  }

  @Test(
    "seedPublicIP rejects a NAT64 address embedding a private IPv4 address and keeps a public one")
  func seedNAT64() async {
    let tracer = SwiftFTR(config: SwiftFTRConfig(noReverseDNS: true))
    #expect(await tracer.seedPublicIP("64:ff9b::192.168.1.1", source: .gatewayReported) == false)
    #expect(await tracer.publicIP(for: .v6)?.address == nil)
    #expect(await tracer.seedPublicIP("64:ff9b::8.8.8.8", source: .gatewayReported))
    #expect(await tracer.publicIP(for: .v6)?.address == "64:ff9b::808:808")
  }

  /// Strings that hold a valid address up to an embedded NUL. A C-string conversion stops at the
  /// NUL, so a parser that converted first would accept the address before it.
  static let nulTerminatedAddresses = [
    "8.8.8.8\u{0}junk", "8.8.8.8\u{0}", "2606:4700:4700::1111\u{0}junk", "::ffff:8.8.8.8\u{0}x",
    "64:ff9b::8.8.8.8\u{0}x",
  ]

  @Test("seedPublicIP rejects a string with an embedded NUL", arguments: nulTerminatedAddresses)
  func seedRejectsEmbeddedNUL(_ address: String) async {
    let tracer = SwiftFTR(config: SwiftFTRConfig(noReverseDNS: true))
    #expect(await tracer.seedPublicIP(address, source: .gatewayReported) == false)
    #expect(await tracer.publicIP(for: .v4)?.address == nil)
  }

  @Test("The explicit-server reverse queries reject an address with an embedded NUL")
  func reverseQueriesRejectEmbeddedNUL() async {
    // Thrown before a socket is opened, so the loopback server is never asked.
    let server = "127.0.0.1"
    let v4 = "127.0.0.1\u{0}junk"
    let v6 = "2001:db8::1\u{0}junk"
    func isInvalidIP(_ operation: () async throws -> Void) async -> Bool {
      do {
        try await operation()
        return false
      } catch DNSError.invalidIP {
        return true
      } catch {
        return false
      }
    }
    let queriesV4 = await isInvalidIP {
      _ = try await SwiftFTR().dns.reverseIPv4(ip: v4, server: server, timeout: 1)
    }
    let queriesV6 = await isInvalidIP {
      _ = try await SwiftFTR().dns.reverseIPv6(ip: v6, server: server, timeout: 1)
    }
    let legacyV4 = await isInvalidIP {
      _ = try await reverseDNS(ip: v4, server: server, timeout: 1)
    }
    let legacyV6 = await isInvalidIP {
      _ = try await reverseIPv6(ip: v6, server: server, timeout: 1)
    }
    #expect(queriesV4, "DNSQueries.reverseIPv4 accepted an address with an embedded NUL")
    #expect(queriesV6, "DNSQueries.reverseIPv6 accepted an address with an embedded NUL")
    #expect(legacyV4, "reverseDNS(ip:server:) accepted an address with an embedded NUL")
    #expect(legacyV6, "reverseIPv6(ip:server:) accepted an address with an embedded NUL")
  }

  @Test("The address parsers reject a string with an embedded NUL")
  func parsersRejectEmbeddedNUL() {
    #expect(detectAddressFamily("127.0.0.1\u{0}junk") == -1)
    #expect(detectAddressFamily("::1\u{0}junk") == -1)
    #expect(canonicalIPAddress("8.8.8.8\u{0}junk") == nil)
    #expect(ParsedIPAddress("8.8.8.8\u{0}junk") == nil)
    #expect(ipAddressScope(of: "10.0.0.1\u{0}junk") == nil)
    #expect(asnLookupAddress(for: "8.8.8.8\u{0}junk") == nil)
    #expect(isPrivateIPv4("10.0.0.1\u{0}junk") == false)
    #expect(isCGNATIPv4("100.64.0.1\u{0}junk") == false)
    #expect(reverseIPv6Nibbles("2001:db8::1\u{0}junk") == nil)
    // Positive controls: the same strings without the NUL.
    #expect(detectAddressFamily("127.0.0.1") == AF_INET)
    #expect(isPrivateIPv4("10.0.0.1") && isCGNATIPv4("100.64.0.1"))
    #expect(reverseIPv6Nibbles("2001:db8::1") != nil)
  }

  @Test("Reverse DNS does not look up the address before an embedded NUL")
  func reverseDNSRejectsEmbeddedNUL() {
    let lookups = FaultCounter()
    let lookup: NameInfoLookup = { _, _, host, _, _, _, _ in
      lookups.increment()
      host?.pointee = 0x61  // "a"
      host?.advanced(by: 1).pointee = 0
      return 0
    }
    #expect(reverseDNS("127.0.0.1\u{0}junk", using: lookup) == nil)
    #expect(reverseDNS("::1\u{0}junk", using: lookup) == nil)
    #expect(lookups.value == 0)
    // Positive control: the same lookup answers for the address alone.
    #expect(reverseDNS("127.0.0.1", using: lookup) == "a")
  }

  @Test("Destination resolution rejects a name with an embedded NUL")
  func resolutionRejectsEmbeddedNUL() throws {
    for prefer in [PreferredFamily.auto, .v4] {
      #expect(throws: TracerouteError.self) {
        try resolveHost(host: "127.0.0.1\u{0}junk", prefer: prefer)
      }
    }
    #expect(throws: TracerouteError.self) { try resolveHost(host: "::1\u{0}junk", prefer: .v6) }
    // Positive control: the literal alone resolves without a lookup.
    #expect(try resolveHost(host: "127.0.0.1", prefer: .v4).canonical == "127.0.0.1")
  }

  @Test("A source address with an embedded NUL is rejected")
  func sourceAddressRejectsEmbeddedNUL() {
    #expect(throws: TracerouteError.self) {
      try validateSourceIPFamily("127.0.0.1\u{0}junk", destinationFamily: AF_INET)
    }
  }

  @Test("Binding a socket to a source address with an embedded NUL fails")
  func sourceBindRejectsEmbeddedNUL() throws {
    for address in ["127.0.0.1\u{0}junk", "127.0.0.1"] {
      let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
      try #require(fd >= 0)
      defer { close(fd) }
      let error = bindSourceIP(sockfd: fd, family: AF_INET, sourceIP: address)
      // Positive control: the address alone binds, on a socket of its own.
      #expect(
        (error == nil) == !address.contains("\u{0}"),
        "\(address.debugDescription): \(error ?? "bound")")
    }
  }

  @Test("A ping from a source address with an embedded NUL fails before it sends")
  func pingSourceRejectsEmbeddedNUL() async throws {
    let network = try FakeICMPNetwork { probe in
      [.init(ICMPWire.echoReply(family: AF_INET, id: probe.identifier, seq: probe.sequence))]
    }
    defer { network.stop() }
    let tracer = offlineTracer(SwiftFTRConfig())
    let config = PingConfig(count: 1, timeout: 5, sourceIP: "127.0.0.1\u{0}junk")
    let (thrown, _) = try await measure(within: 20) {
      await EventBasedDNSTests.error {
        try await network.install { try await tracer.ping(to: "fake.test", config: config) }
      }
    }
    if case TracerouteError.sourceIPBindFailed? = thrown {
    } else {
      Issue.record("expected sourceIPBindFailed, got \(String(describing: thrown))")
    }
    #expect(network.probes.value == 0)
  }

  @Test("A DNS query to a server address with an embedded NUL fails as an invalid address")
  func dnsServerRejectsEmbeddedNUL() async {
    // Rejected before any socket opens; without the check the query would go to 127.0.0.1.
    do {
      _ = try await SwiftFTR().dns.a(
        hostname: "nul.example", server: "127.0.0.1\u{0}junk", timeout: 1)
      Issue.record("the query succeeded")
    } catch DNSError.invalidIP(let server) {
      #expect(server == "127.0.0.1\u{0}junk")
    } catch {
      Issue.record("expected DNSError.invalidIP, got \(error)")
    }
  }

  /// Hop classification is unchanged: documentation and reserved ranges still classify as
  /// `.global` so their hops reach the ASN resolver, as docs/reference/AI_REFERENCE.md describes.
  @Test("Hop scope is unchanged for ranges only the public-IP check rejects")
  func hopScopeUnchanged() {
    for address in ["192.0.2.1", "198.51.100.1", "2001:db8::1", "fec0::1", "4000::1"] {
      #expect(ipAddressScope(of: address) == .global, "\(address)")
    }
  }
}
