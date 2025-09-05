import ArgumentParser
import Foundation
import SwiftFTR

@main
struct SwiftFTRCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "swift-ftr",
    abstract: "Fast traceroute on macOS using ICMP datagram sockets"
  )

  @Flag(name: .customLong("json"), help: "Emit JSON with ASN categories and public IP")
  var json: Bool = false

  @Flag(name: .customLong("no-rdns"), help: "Disable reverse DNS lookups")
  var noRDNS: Bool = false

  @Flag(name: .customLong("no-stun"), help: "Skip STUN public IP discovery")
  var noSTUN: Bool = false

  @Option(name: .customLong("public-ip"), help: "Override public IP (bypasses STUN)")
  var publicIP: String?

  @Option(name: [.short, .customLong("max-hops")], help: "Maximum TTL/hops to probe")
  var maxHops: Int = 30

  @Option(
    name: [.short, .customLong("timeout")], help: "Overall wait after sending probes (seconds)")
  var timeout: Double = 1.0

  @Argument(help: "Destination hostname or IPv4 address")
  var host: String

  mutating func run() async throws {
    let tracer = SwiftFTR()
    if noSTUN { setenv("PTR_SKIP_STUN", "1", 1) }
    if let pip = publicIP { setenv("PTR_PUBLIC_IP", pip, 1) }

    do {
      if json {
        try await runJSON(tracer: tracer)
      } else {
        try await runPretty(tracer: tracer)
      }
    } catch {
      fputs("Error: \(error)\n", stderr)
      Foundation.exit(1)
    }
  }

  private func runJSON(tracer: SwiftFTR) async throws {
    let classified = try await tracer.traceClassified(to: host, maxHops: maxHops, timeout: timeout)
    var allIPs = classified.hops.compactMap { $0.ip }
    allIPs.append(classified.destinationIP)
    if let pip = classified.publicIP { allIPs.append(pip) }
    let resolver = CymruDNSResolver()
    let asnMap = (try? resolver.resolve(ipv4Addrs: allIPs, timeout: max(0.8, timeout))) ?? [:]
    struct ISPObj: Codable {
      let asn: String
      let name: String
      let hostname: String
    }
    struct DestASNObj: Codable {
      let asn: Int
      let name: String
      let country_code: String?
    }
    struct HopASN: Codable {
      let asn: Int
      let prefix: String
      let country_code: String
      let name: String
    }
    struct HopObj: Codable {
      let ttl: Int
      let segment: String?
      let address: String?
      let hostname: String?
      let asn_info: HopASN?
      let rtt_ms: Double?
    }
    struct Root: Codable {
      let version: String
      let target: String
      let target_ip: String
      let public_ip: String?
      let isp: ISPObj?
      let destination_asn: DestASNObj?
      let hops: [HopObj]
      let protocol_: String
      let socket_mode: String
      enum CodingKeys: String, CodingKey {
        case version, target, target_ip, public_ip, isp, destination_asn, hops
        case protocol_ = "protocol"
        case socket_mode
      }
    }
    func segString(_ c: HopCategory?) -> String? {
      guard let c = c else { return nil }
      switch c {
      case .local: return "LAN"
      case .isp: return "ISP"
      case .transit: return "TRANSIT"
      case .destination: return "DESTINATION"
      case .unknown: return nil
      }
    }
    func oneDecimal(_ v: Double) -> Double { (v * 10).rounded() / 10 }
    // Concurrent reverse DNS for all relevant IPs
    let rdnsIPs = Set(allIPs)
    var hostnameMap: [String: String] = [:]
    await withTaskGroup(of: (String, String?).self) { group in
      for ip in rdnsIPs { group.addTask { (ip, reverseDNS(ip)) } }
      for await (ip, name) in group { if let n = name { hostnameMap[ip] = n } }
    }
    var hops: [HopObj] = []
    for h in classified.hops {
      if let ip = h.ip {
        let rdns = hostnameMap[ip]
        let asninfo = asnMap[ip].map {
          HopASN(
            asn: $0.asn, prefix: $0.prefix ?? "", country_code: $0.countryCode ?? "", name: $0.name)
        }
        let seg = segString(h.category)
        hops.append(
          HopObj(
            ttl: h.ttl, segment: seg, address: ip, hostname: rdns, asn_info: asninfo,
            rtt_ms: h.rtt.map { oneDecimal($0 * 1000) }))
      } else {
        hops.append(
          HopObj(ttl: h.ttl, segment: nil, address: nil, hostname: nil, asn_info: nil, rtt_ms: nil))
      }
    }
    let ispObj: ISPObj? = classified.publicIP.map { pip in
      let name = asnMap[pip]?.name ?? ""
      let asnStr = asnMap[pip].map { String($0.asn) } ?? ""
      let host = hostnameMap[pip] ?? pip
      return ISPObj(asn: asnStr, name: name, hostname: host)
    }
    let destObj: DestASNObj? = asnMap[classified.destinationIP].map { d in
      DestASNObj(asn: d.asn, name: d.name, country_code: d.countryCode)
    }
    let root = Root(
      version: "0.1.0",
      target: classified.destinationHost,
      target_ip: classified.destinationIP,
      public_ip: classified.publicIP,
      isp: ispObj,
      destination_asn: destObj,
      hops: hops,
      protocol_: "ICMP",
      socket_mode: "Datagram"
    )
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try enc.encode(root)
    if let s = String(data: data, encoding: .utf8) { print(s) }
  }

  private func runPretty(tracer: SwiftFTR) async throws {
    let classified = try await tracer.traceClassified(to: host, maxHops: maxHops, timeout: timeout)
    let probeMs = Int(timeout * 1000)
    let overallMs = probeMs * 3
    print(
      "ftr to \(classified.destinationHost) (\(classified.destinationIP)), \(maxHops) max hops, \(probeMs)ms probe timeout, \(overallMs)ms overall timeout"
    )
    print("")
    print("Performing ASN lookups, reverse DNS lookups and classifying segments...")
    func catLabel(_ c: HopCategory) -> String {
      switch c {
      case .local: return "[LAN   ]"
      case .isp: return "[ISP   ]"
      case .transit: return "[TRANSIT]"
      case .destination: return "[DESTINATION]"
      case .unknown: return "[UNKNOWN]"
      }
    }
    var hopHostnameMap: [String: String] = [:]
    if !noRDNS {
      var ips = Set(classified.hops.compactMap { $0.ip })
      if let pip = classified.publicIP { ips.insert(pip) }
      await withTaskGroup(of: (String, String?).self) { group in
        for ip in ips { group.addTask { (ip, reverseDNS(ip)) } }
        for await (ip, name) in group { if let n = name { hopHostnameMap[ip] = n } }
      }
    }
    for hop in classified.hops {
      if hop.ip == nil {
        print(String(format: "%2d", hop.ttl))
        continue
      }
      let ip = hop.ip!
      let rdns = (!noRDNS ? (hopHostnameMap[ip] ?? ip) : ip)
      let label = catLabel(hop.category)
      let rttMs = hop.rtt.map { String(format: "%.3f ms", $0 * 1000) } ?? "timeout"
      let right: String
      if isPrivateIPv4(ip) {
        right = "[Private Network]"
      } else if isCGNATIPv4(ip) {
        right = "[CGNAT]"
      } else if let asn = hop.asn {
        right = "[AS\(asn) - \(hop.asName ?? "?")]"
      } else {
        right = ""
      }
      print(String(format: "%2d %@ %@ (%@) %@ %@", hop.ttl, label, rdns, ip, rttMs, right))
    }
    print("")
    if let pub = classified.publicIP {
      let rd = (!noRDNS ? (hopHostnameMap[pub] ?? pub) : pub)
      print("Detected public IP: \(pub) (\(rd))")
    }
    if let casn = classified.clientASN {
      print("Detected ISP: AS\(casn) (\(classified.clientASName ?? "?"))")
    }
    if let dasn = classified.destinationASN {
      print("Destination ASN: AS\(dasn) (\(classified.destinationASName ?? "?"))")
    }
  }
}
