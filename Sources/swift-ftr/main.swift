import Foundation
import SwiftFTR
import Darwin

@main
struct App {
    static func main() async {
        let args = CommandLine.arguments
        var json = false
        var showHelp = false
        var useRDNS = true
        var noSTUN = false
        var publicIPOverride: String? = nil
        var maxHops: Int = 30
        var timeout: TimeInterval = 1.0
        var host: String? = nil

        func printHelpAndExit() -> Never {
            let help = """
            ftr - fast traceroute (macOS ICMP DGRAM)

            Usage:
              swift-ftr [options] <host>

            Options:
              -m, --max-hops N       Maximum TTL/hops to probe (default 30)
              -w, --timeout SEC      Overall wait after sending probes (default 1.0)
              --json                 Emit JSON with ASN categories and public IP
              --no-rdns              Disable reverse DNS lookups
              --no-stun              Do not perform STUN public IP discovery
              --public-ip IP         Override public IP (bypasses STUN)
              -h, --help             Show this help
            """
            print(help)
            exit(0)
        }

        var it = args.dropFirst().makeIterator()
        while let tok = it.next() {
            switch tok {
            case "--json": json = true
            case "--no-rdns": useRDNS = false
            case "--no-stun": noSTUN = true
            case "--public-ip": publicIPOverride = it.next()
            case "-m", "--max-hops": if let v = it.next(), let n = Int(v) { maxHops = n }
            case "-w", "--timeout": if let v = it.next(), let t = TimeInterval(v) { timeout = t }
            case "-h", "--help": showHelp = true
            default:
                if tok.hasPrefix("-") { fputs("Unknown option: \(tok)\n", stderr); printHelpAndExit() }
                host = tok
                // Optional positional overrides for compatibility: [maxHops] [timeout]
                if let v = it.next(), let n = Int(v) { maxHops = n }
                if let v = it.next(), let t = TimeInterval(v) { timeout = t }
            }
        }
        if showHelp || host == nil { printHelpAndExit() }

        let tracer = SwiftFTR()
        do {
            if noSTUN { setenv("PTR_SKIP_STUN", "1", 1) }
            if let pip = publicIPOverride { setenv("PTR_PUBLIC_IP", pip, 1) }

            if json {
                // Build ftr-compatible JSON
                let classified = try await tracer.traceClassified(to: host!, maxHops: maxHops, timeout: timeout)
                var allIPs = classified.hops.compactMap { $0.ip }
                allIPs.append(classified.destinationIP)
                if let pip = classified.publicIP { allIPs.append(pip) }
                let resolver = CymruDNSResolver()
                let asnMap = (try? resolver.resolve(ipv4Addrs: allIPs, timeout: max(0.8, timeout))) ?? [:]
                struct ISPObj: Codable { let asn: String; let name: String; let hostname: String }
                struct DestASNObj: Codable { let asn: Int; let name: String; let country_code: String? }
                struct HopASN: Codable { let asn: Int; let prefix: String; let country_code: String; let registry: String; let name: String }
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
                    enum CodingKeys: String, CodingKey { case version, target, target_ip, public_ip, isp, destination_asn, hops; case protocol_ = "protocol"; case socket_mode }
                }

                func segString(_ c: HopCategory?) -> String? {
                    guard let c = c else { return nil }
                    switch c { case .local: return "LAN"; case .isp: return "ISP"; case .transit: return "TRANSIT"; case .destination: return "DESTINATION"; case .unknown: return nil }
                }
                func oneDecimal(_ v: Double) -> Double { (v * 10).rounded() / 10 }

                // Concurrent reverse DNS for all relevant IPs
                let rdnsIPs = Set(allIPs)
                var hostnameMap: [String: String] = [:]
                await withTaskGroup(of: (String, String?).self) { group in
                    for ip in rdnsIPs {
                        group.addTask { (ip, reverseDNS(ip)) }
                    }
                    for await (ip, name) in group {
                        if let n = name { hostnameMap[ip] = n }
                    }
                }

                var hops: [HopObj] = []
                for h in classified.hops {
                    if let ip = h.ip {
                        let rdns = hostnameMap[ip]
                        let seg = segString(h.category)
                        var asninfo: HopASN? = nil
                        if isPrivateIPv4(ip) {
                            asninfo = HopASN(asn: 0, prefix: "\(ip)/32", country_code: "N/A", registry: "N/A", name: "Private Network")
                        } else if isCGNATIPv4(ip) {
                            asninfo = HopASN(asn: 0, prefix: "\(ip)/32", country_code: "N/A", registry: "N/A", name: "CGNAT")
                        } else if let info = asnMap[ip] {
                            let pref = info.prefix ?? "\(ip)/32"
                            let cc = info.countryCode ?? ""
                            let reg = info.registry ?? ""
                            asninfo = HopASN(asn: info.asn, prefix: String(pref), country_code: String(cc), registry: String(reg), name: info.name)
                        }
                        hops.append(HopObj(ttl: h.ttl, segment: seg, address: ip, hostname: rdns, asn_info: asninfo, rtt_ms: h.rtt.map { oneDecimal($0 * 1000) }))
                    } else {
                        hops.append(HopObj(ttl: h.ttl, segment: nil, address: nil, hostname: nil, asn_info: nil, rtt_ms: nil))
                    }
                }

                var ispObj: ISPObj? = nil
                var destObj: DestASNObj? = nil
                if let pip = classified.publicIP {
                    let name = asnMap[pip]?.name ?? ""
                    let asnStr = asnMap[pip].map { String($0.asn) } ?? ""
                    let host = hostnameMap[pip] ?? pip
                    ispObj = ISPObj(asn: asnStr, name: name, hostname: host)
                }
                if let dest = asnMap[classified.destinationIP] {
                    destObj = DestASNObj(asn: dest.asn, name: dest.name, country_code: dest.countryCode)
                }

                let root = Root(version: "0.6.0", target: classified.destinationHost, target_ip: classified.destinationIP, public_ip: classified.publicIP, isp: ispObj, destination_asn: destObj, hops: hops, protocol_: "ICMP", socket_mode: "Datagram")
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                let data = try enc.encode(root)
                if let s = String(data: data, encoding: .utf8) { print(s) }
            } else {
                let classified = try await tracer.traceClassified(to: host!, maxHops: maxHops, timeout: timeout)
                // Header matching ftr style
                let probeMs = Int(timeout * 1000)
                let overallMs = probeMs * 3
                print("ftr to \(classified.destinationHost) (\(classified.destinationIP)), \(maxHops) max hops, \(probeMs)ms probe timeout, \(overallMs)ms overall timeout")
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

                for hop in classified.hops {
                    if hop.ip == nil {
                        print(String(format: "%2d", hop.ttl))
                        continue
                    }
                    let ip = hop.ip!
                    let rdns = (useRDNS ? (reverseDNS(ip) ?? ip) : ip)
                    let label = catLabel(hop.category)
                    let rttMs = hop.rtt.map { String(format: "%.3f ms", $0 * 1000) } ?? "timeout"
                    let right: String
                    if isPrivateIPv4(ip) {
                        right = "[Private Network]"
                    } else if isCGNATIPv4(ip) {
                        right = "[CGNAT]"
                    } else if let asn = hop.asn {
                        let name = hop.asName ?? "?"
                        right = "[AS\(asn) - \(name)]"
                    } else {
                        right = ""
                    }
                    print(String(format: "%2d %@ %@ (%@) %@ %@", hop.ttl, label, rdns, ip, rttMs, right))
                }

                print("")
                let pub = classified.publicIP
                if let pub = pub {
                    let rd = reverseDNS(pub) ?? pub
                    print("Detected public IP: \(pub) (\(rd))")
                }
                if let casn = classified.clientASN {
                    let cname = classified.clientASName ?? "?"
                    print("Detected ISP: AS\(casn) (\(cname))")
                }
                if let dasn = classified.destinationASN {
                    let dname = classified.destinationASName ?? "?"
                    print("Destination ASN: AS\(dasn) (\(dname))")
                }
            }
        } catch {
            fputs("Error: \(error)\n", stderr)
            exit(1)
        }
    }
}
