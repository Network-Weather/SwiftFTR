import Foundation
import Testing

@testable import SwiftFTR

/// The classifier's output for a fixed table of inputs, recorded from `TraceClassifier.classify`
/// before it was split into its ASN lookup and its categorization. Both the public entry point and
/// the split parts must keep producing exactly these digests.
@Suite("Classifier split keeps today's output")
struct ClassifierSplitTests {
  /// Answers from `mapping`, or throws when `fails`, and records what it was asked.
  final class RecordingASNResolver: ASNResolver, @unchecked Sendable {
    let mapping: [String: ASNInfo]
    let fails: Bool
    private let lock = NSLock()
    private var asked: [String] = []
    private var timeouts: [TimeInterval] = []

    init(_ mapping: [String: ASNInfo], fails: Bool = false) {
      self.mapping = mapping
      self.fails = fails
    }

    func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
      lock.withLock {
        asked += ipv4Addrs
        timeouts.append(timeout)
      }
      struct Refused: Error {}
      if fails { throw Refused() }
      return mapping.filter { ipv4Addrs.contains($0.key) }
    }

    var record: String {
      lock.withLock { "asked=\(asked.sorted()) timeouts=\(timeouts)" }
    }
  }

  struct Case: Sendable, CustomStringConvertible {
    let name: String
    let hops: [String?]
    let destination: String
    let publicIP: String?
    let vpn: VPNContext?
    let mapping: [String: ASNInfo]
    let fails: Bool
    let expected: String
    var description: String { name }
  }

  static let isp = ASNInfo(asn: 64501, name: "ISPNet")
  static let transit = ASNInfo(asn: 64500, name: "TransitNet")
  static let dest = ASNInfo(asn: 15133, name: "ExampleNet")

  static let cases: [Case] = [
    Case(
      name: "ISP, transit and destination, with a gap filled",
      hops: ["192.168.1.1", "100.64.0.5", "8.8.4.4", nil, "8.8.4.5", "1.1.1.1"],
      destination: "1.1.1.1", publicIP: "9.9.9.9", vpn: nil,
      mapping: ["9.9.9.9": isp, "8.8.4.4": transit, "8.8.4.5": transit, "1.1.1.1": dest],
      fails: false,
      expected:
        "host=dest.example ip=1.1.1.1 pub=9.9.9.9 client=64501/ISPNet dest=15133/ExampleN"
        + "et src=- dh=- ph=- | 1:192.168.1.1:LOCAL:-:-:h1-192.168.1.1:replied 2:100.64.0.5"
        + ":ISP:-:-:h2-100.64.0.5:replied 3:8.8.4.4:TRANSIT:64500:TransitNet:h3-8.8.4.4:rep"
        + "lied 4:*:TRANSIT:64500:TransitNet:-:timedOut 5:8.8.4.5:TRANSIT:64500:TransitNet:"
        + "h5-8.8.4.5:replied 6:1.1.1.1:DESTINATION:15133:ExampleNet:h6-1.1.1.1:replied || "
        + "asked=[\"1.1.1.1\", \"8.8.4.4\", \"8.8.4.5\", \"9.9.9.9\"] timeouts=[1.5]"),
    Case(
      name: "A resolver that throws classifies without ASN data",
      hops: ["192.168.1.1", "9.9.9.10", nil, "8.8.4.4", "1.1.1.1"],
      destination: "1.1.1.1", publicIP: "9.9.9.9", vpn: nil,
      mapping: ["9.9.9.9": isp, "8.8.4.4": transit, "1.1.1.1": dest],
      fails: true,
      expected:
        "host=dest.example ip=1.1.1.1 pub=9.9.9.9 client=-/- dest=-/- src=- dh=- ph=- | 1"
        + ":192.168.1.1:LOCAL:-:-:h1-192.168.1.1:replied 2:9.9.9.10:TRANSIT:-:-:h2-9.9.9.10"
        + ":replied 3:*:TRANSIT:-:-:-:timedOut 4:8.8.4.4:TRANSIT:-:-:h4-8.8.4.4:replied 5:1"
        + ".1.1.1:DESTINATION:-:-:h5-1.1.1.1:replied || asked=[\"1.1.1.1\", \"8.8.4.4\", \""
        + "9.9.9.10\", \"9.9.9.9\"] timeouts=[1.5]"),
    Case(
      name: "Non-global after public, and a gap between different ASNs",
      hops: ["10.0.0.1", "9.9.9.10", "10.1.1.1", nil, "8.8.4.4", nil, nil, "1.1.1.1"],
      destination: "1.1.1.1", publicIP: "9.9.9.9", vpn: nil,
      mapping: ["9.9.9.9": isp, "9.9.9.10": isp, "8.8.4.4": transit, "1.1.1.1": dest],
      fails: false,
      expected:
        "host=dest.example ip=1.1.1.1 pub=9.9.9.9 client=64501/ISPNet dest=15133/ExampleN"
        + "et src=- dh=- ph=- | 1:10.0.0.1:LOCAL:-:-:h1-10.0.0.1:replied 2:9.9.9.10:ISP:645"
        + "01:ISPNet:h2-9.9.9.10:replied 3:10.1.1.1:ISP:-:-:h3-10.1.1.1:replied 4:*:UNKNOWN"
        + ":-:-:-:timedOut 5:8.8.4.4:TRANSIT:64500:TransitNet:h5-8.8.4.4:replied 6:*:UNKNOW"
        + "N:-:-:-:timedOut 7:*:UNKNOWN:-:-:-:timedOut 8:1.1.1.1:DESTINATION:15133:ExampleN"
        + "et:h8-1.1.1.1:replied || asked=[\"1.1.1.1\", \"8.8.4.4\", \"9.9.9.10\", \"9.9.9."
        + "9\"] timeouts=[1.5]"),
    Case(
      name: "VPN trace: private and CGNAT are VPN, public after is classified",
      hops: ["10.8.0.1", "100.64.1.1", "8.8.4.4", "1.1.1.1"],
      destination: "1.1.1.1", publicIP: nil,
      vpn: VPNContext(traceInterface: "utun9", isVPNTrace: true, vpnLocalIPs: ["10.8.0.2"]),
      mapping: ["8.8.4.4": transit, "1.1.1.1": dest], fails: false,
      expected:
        "host=dest.example ip=1.1.1.1 pub=- client=-/- dest=15133/ExampleNet src=- dh=- p"
        + "h=- | 1:10.8.0.1:VPN:-:-:h1-10.8.0.1:replied 2:100.64.1.1:VPN:-:-:h2-100.64.1.1:"
        + "replied 3:8.8.4.4:TRANSIT:64500:TransitNet:h3-8.8.4.4:replied 4:1.1.1.1:DESTINAT"
        + "ION:15133:ExampleNet:h4-1.1.1.1:replied || asked=[\"1.1.1.1\", \"8.8.4.4\"] time"
        + "outs=[1.5]"),
    Case(
      name: "IPv6 with link-local, global and a public address of the same AS as a hop",
      hops: ["fe80::1%lo0", "2001:4860:4860::8888", nil, "2606:4700:4700::1111"],
      destination: "2606:4700:4700::1111", publicIP: "2001:4860:4860::8844", vpn: nil,
      mapping: [
        "2001:4860:4860::8844": isp, "2001:4860:4860::8888": isp,
        "2606:4700:4700::1111": dest,
      ],
      fails: false,
      expected:
        "host=dest.example ip=2606:4700:4700::1111 pub=2001:4860:4860::8844 client=64501/"
        + "ISPNet dest=15133/ExampleNet src=- dh=- ph=- | 1:fe80::1%lo0:LOCAL:-:-:h1-fe80::"
        + "1%lo0:replied 2:2001:4860:4860::8888:ISP:64501:ISPNet:h2-2001:4860:4860::8888:re"
        + "plied 3:*:UNKNOWN:-:-:-:timedOut 4:2606:4700:4700::1111:DESTINATION:15133:Exampl"
        + "eNet:h4-2606:4700:4700::1111:replied || asked=[\"2001:4860:4860::8844\", \"2001:"
        + "4860:4860::8888\", \"2606:4700:4700::1111\"] timeouts=[1.5]"),
    Case(
      name: "Nothing answered",
      hops: [nil, nil, nil], destination: "1.1.1.1", publicIP: nil, vpn: nil,
      mapping: [:], fails: false,
      expected:
        "host=dest.example ip=1.1.1.1 pub=- client=-/- dest=-/- src=- dh=- ph=- | 1:*:UNK"
        + "NOWN:-:-:-:timedOut 2:*:UNKNOWN:-:-:-:timedOut 3:*:UNKNOWN:-:-:-:timedOut || ask"
        + "ed=[\"1.1.1.1\"] timeouts=[1.5]"),
  ]

  static func trace(_ c: Case) -> TraceResult {
    let hops = c.hops.enumerated().map { index, ip in
      TraceHop(
        ttl: index + 1, ipAddress: ip, rtt: ip == nil ? nil : 0.001 * Double(index + 1),
        reachedDestination: ip == c.destination, hostname: ip.map { "h\(index + 1)-\($0)" })
    }
    return TraceResult(
      destination: "dest.example", maxHops: c.hops.count, reached: true, hops: hops,
      resolvedIP: c.destination)
  }

  static func digest(_ t: ClassifiedTrace) -> String {
    let hops = t.hops.map {
      "\($0.ttl):\($0.ip ?? "*"):\($0.category.rawValue):\($0.asn.map(String.init) ?? "-"):"
        + "\($0.asName ?? "-"):\($0.hostname ?? "-"):\($0.outcome)"
    }
    return
      "host=\(t.destinationHost) ip=\(t.destinationIP) pub=\(t.publicIP ?? "-") "
      + "client=\(t.clientASN.map(String.init) ?? "-")/\(t.clientASName ?? "-") "
      + "dest=\(t.destinationASN.map(String.init) ?? "-")/\(t.destinationASName ?? "-") "
      + "src=\(t.publicIPSource?.rawValue ?? "-") dh=\(t.destinationHostname ?? "-") "
      + "ph=\(t.publicHostname ?? "-") | " + hops.joined(separator: " ")
  }

  @Test("classify gives the recorded output", arguments: cases)
  func classifyMatchesRecording(_ c: Case) async throws {
    let resolver = RecordingASNResolver(c.mapping, fails: c.fails)
    let result = try await TraceClassifier().classify(
      trace: Self.trace(c), destinationIP: c.destination, resolver: resolver, timeout: 1.5,
      publicIP: c.publicIP, vpnContext: c.vpn)
    let observed = Self.digest(result) + " || " + resolver.record
    #expect(observed == c.expected)
  }

  /// The split parts, composed by hand as the trace will compose them, give the same output and
  /// ask the same addresses; a lookup that throws is a `nil` map, as `try?` makes it.
  @Test("The lookup addresses and categorization give the recorded output", arguments: cases)
  func splitPartsMatchRecording(_ c: Case) async throws {
    let classifier = TraceClassifier()
    let trace = Self.trace(c)
    let resolver = RecordingASNResolver(c.mapping, fails: c.fails)
    let addresses = classifier.asnLookupAddresses(
      trace: trace, destinationIP: c.destination, publicIP: c.publicIP)
    let asnMap = try? await resolver.resolve(ipv4Addrs: addresses, timeout: 1.5)
    let result = classifier.categorize(
      trace: trace, destinationIP: c.destination, asnMap: asnMap, publicIP: c.publicIP,
      vpnContext: c.vpn)
    #expect(Self.digest(result) + " || " + resolver.record == c.expected)
  }
}
