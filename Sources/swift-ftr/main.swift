import ArgumentParser
import Foundation
import SwiftFTR

@main
struct SwiftFTRCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "swift-ftr",
    abstract: "Fast traceroute and network diagnostics on macOS",
    discussion: """
      Provides fast, parallel traceroute using ICMP datagram sockets and ping capabilities.

      Use subcommands:
        trace     - Perform traceroute with ASN classification
        ping      - Send ICMP echo requests to measure latency
        multipath - Discover ECMP paths using Dublin Traceroute

      Or run trace directly (default behavior):
        swift-ftr example.com
      """,
    subcommands: [Trace.self, Ping.self, Multipath.self],
    defaultSubcommand: Trace.self
  )
}

// MARK: - Trace Subcommand

extension SwiftFTRCommand {
  struct Trace: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "trace",
      abstract: "Perform fast parallel traceroute",
      discussion: """
        Performs parallel traceroute by sending all probes at once, then waiting for responses.

        Examples:
          swift-ftr trace example.com
          swift-ftr trace 1.1.1.1 -m 10 -t 2.0
          swift-ftr trace --json 8.8.8.8
          swift-ftr trace -i en0 google.com
        """
    )

    @Flag(name: .customLong("json"), help: "Emit JSON with ASN categories and public IP")
    var json: Bool = false

    @Flag(name: .customLong("no-rdns"), help: "Disable reverse DNS lookups")
    var noRDNS: Bool = false

    @Option(name: .customLong("public-ip"), help: "Override public IP (bypasses STUN)")
    var publicIP: String?

    @Option(name: [.short, .customLong("interface")], help: "Network interface to use (e.g., en0)")
    var interface: String?

    @Option(name: [.short, .customLong("source")], help: "Source IP address to bind to")
    var sourceIP: String?

    @Option(name: [.short, .customLong("payload-size")], help: "ICMP payload size in bytes")
    var payloadSize: Int = 56

    @Flag(name: .customLong("verbose"), help: "Enable verbose logging")
    var verbose: Bool = false

    @Option(name: [.short, .customLong("max-hops")], help: "Maximum TTL/hops to probe")
    var maxHops: Int = 30

    @Option(
      name: [.short, .customLong("timeout")], help: "Overall wait after sending probes (seconds)")
    var timeout: Double = 1.0

    @Argument(help: "Destination hostname or IPv4 address")
    var host: String

    mutating func run() async throws {
      let config = SwiftFTRConfig(
        maxHops: maxHops,
        maxWaitMs: Int(timeout * 1000),
        payloadSize: payloadSize,
        publicIP: publicIP,
        enableLogging: verbose,
        noReverseDNS: noRDNS,
        interface: interface,
        sourceIP: sourceIP
      )
      let tracer = SwiftFTR(config: config)

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
      let classified = try await tracer.traceClassified(to: host)
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
              asn: $0.asn, prefix: $0.prefix ?? "", country_code: $0.countryCode ?? "",
              name: $0.name)
          }
          let seg = segString(h.category)
          hops.append(
            HopObj(
              ttl: h.ttl, segment: seg, address: ip, hostname: rdns, asn_info: asninfo,
              rtt_ms: h.rtt.map { oneDecimal($0 * 1000) }))
        } else {
          hops.append(
            HopObj(
              ttl: h.ttl, segment: nil, address: nil, hostname: nil, asn_info: nil, rtt_ms: nil)
          )
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
        version: "0.5.0",
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
      let classified = try await tracer.traceClassified(to: host)
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
}

// MARK: - Ping Subcommand

extension SwiftFTRCommand {
  struct Ping: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "ping",
      abstract: "Send ICMP ping to measure latency and packet loss",
      discussion: """
        Sends ICMP Echo Request packets and computes statistics including latency, jitter, and packet loss.

        Examples:
          swift-ftr ping 8.8.8.8
          swift-ftr ping example.com -c 10 -i 0.5
          swift-ftr ping 1.1.1.1 --interface en0 --json
        """
    )

    @Option(name: [.short, .customLong("count")], help: "Number of pings (default: 5)")
    var count: Int = 5

    @Option(
      name: [.short, .customLong("interval")],
      help: "Interval between pings in seconds (default: 1.0)"
    )
    var interval: Double = 1.0

    @Option(
      name: [.short, .customLong("timeout")], help: "Timeout per ping in seconds (default: 2.0)")
    var timeout: Double = 2.0

    @Option(name: [.short, .customLong("payload-size")], help: "ICMP payload size (default: 56)")
    var payloadSize: Int = 56

    @Option(name: [.short, .customLong("interface")], help: "Network interface (e.g., en0)")
    var interface: String?

    @Option(name: [.short, .customLong("source")], help: "Source IP address")
    var sourceIP: String?

    @Flag(name: .customLong("json"), help: "Output JSON format")
    var json: Bool = false

    @Flag(name: .customLong("verbose"), help: "Enable verbose logging")
    var verbose: Bool = false

    @Argument(help: "Target hostname or IP address")
    var target: String

    func run() async throws {
      let ftrConfig = SwiftFTRConfig(
        enableLogging: verbose,
        interface: interface,
        sourceIP: sourceIP
      )
      let tracer = SwiftFTR(config: ftrConfig)

      let pingConfig = PingConfig(
        count: count,
        interval: interval,
        timeout: timeout,
        payloadSize: payloadSize
      )

      do {
        let result = try await tracer.ping(to: target, config: pingConfig)

        if json {
          printJSON(result)
        } else {
          printPretty(result)
        }
      } catch {
        fputs("Error: \(error)\n", stderr)
        Foundation.exit(1)
      }
    }

    private func printPretty(_ result: PingResult) {
      print("PING \(result.target) (\(result.resolvedIP))")

      for response in result.responses {
        if let rtt = response.rtt {
          let rttMs = rtt * 1000
          let ttlStr = response.ttl.map { " ttl=\($0)" } ?? ""
          print(
            "Reply from \(result.resolvedIP): seq=\(response.sequence) time=\(String(format: "%.3f", rttMs)) ms\(ttlStr)"
          )
        } else {
          print("Request timeout for seq=\(response.sequence)")
        }
      }

      let stats = result.statistics
      print("\n--- \(result.target) ping statistics ---")
      print(
        "\(stats.sent) packets transmitted, \(stats.received) received, \(String(format: "%.1f", stats.packetLoss * 100))% packet loss"
      )

      if let min = stats.minRTT, let avg = stats.avgRTT, let max = stats.maxRTT {
        print(
          "rtt min/avg/max = \(String(format: "%.3f", min * 1000))/\(String(format: "%.3f", avg * 1000))/\(String(format: "%.3f", max * 1000)) ms"
        )
        if let jitter = stats.jitter {
          print("jitter (stddev) = \(String(format: "%.3f", jitter * 1000)) ms")
        }
      }
    }

    private func printJSON(_ result: PingResult) {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try! encoder.encode(result)
      print(String(data: data, encoding: .utf8)!)
    }
  }
}

// MARK: - Multipath Subcommand

extension SwiftFTRCommand {
  struct Multipath: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "multipath",
      abstract: "Discover ECMP paths using Dublin Traceroute",
      discussion: """
        Systematically varies flow identifiers to discover multiple paths to a destination,
        using Paris Traceroute consistency within each flow.

        Examples:
          swift-ftr multipath example.com
          swift-ftr multipath 8.8.8.8 --flows 16 --max-paths 32
          swift-ftr multipath 1.1.1.1 --json
          swift-ftr multipath google.com -m 20 -t 1.5
        """
    )

    @Option(
      name: [.short, .customLong("flows")],
      help: "Number of flow variations to try (default: 8)")
    var flows: Int = 8

    @Option(name: .customLong("max-paths"), help: "Max unique paths to discover (default: 16)")
    var maxPaths: Int = 16

    @Option(
      name: .customLong("early-stop"), help: "Stop after N consecutive duplicate paths (default: 3)"
    )
    var earlyStop: Int = 3

    @Option(
      name: [.short, .customLong("max-hops")], help: "Maximum TTL/hops to probe (default: 30)")
    var maxHops: Int = 30

    @Option(
      name: [.short, .customLong("timeout")], help: "Timeout per flow in seconds (default: 2.0)")
    var timeout: Double = 2.0

    @Option(
      name: [.short, .customLong("payload-size")], help: "ICMP payload size in bytes (default: 56)")
    var payloadSize: Int = 56

    @Option(name: [.short, .customLong("interface")], help: "Network interface to use (e.g., en0)")
    var interface: String?

    @Option(name: [.short, .customLong("source")], help: "Source IP address to bind to")
    var sourceIP: String?

    @Option(name: .customLong("public-ip"), help: "Override public IP (bypasses STUN)")
    var publicIP: String?

    @Flag(name: .customLong("no-rdns"), help: "Disable reverse DNS lookups")
    var noRDNS: Bool = false

    @Flag(name: .customLong("json"), help: "Output JSON format")
    var json: Bool = false

    @Flag(name: .customLong("verbose"), help: "Enable verbose logging")
    var verbose: Bool = false

    @Argument(help: "Destination hostname or IPv4 address")
    var target: String

    func run() async throws {
      let ftrConfig = SwiftFTRConfig(
        maxHops: maxHops,
        maxWaitMs: Int(timeout * 1000),
        payloadSize: payloadSize,
        publicIP: publicIP,
        enableLogging: verbose,
        noReverseDNS: noRDNS,
        interface: interface,
        sourceIP: sourceIP
      )
      let tracer = SwiftFTR(config: ftrConfig)

      let multipathConfig = MultipathConfig(
        flowVariations: flows,
        maxPaths: maxPaths,
        earlyStopThreshold: earlyStop,
        timeoutMs: Int(timeout * 1000),
        maxHops: maxHops
      )

      do {
        let topology = try await tracer.discoverPaths(to: target, config: multipathConfig)

        if json {
          printJSON(topology)
        } else {
          printPretty(topology)
        }
      } catch {
        fputs("Error: \(error)\n", stderr)
        Foundation.exit(1)
      }
    }

    private func printPretty(_ topology: NetworkTopology) {
      print(
        "Multipath discovery to \(topology.destination) (\(topology.destinationIP)), \(maxHops) max hops, \(Int(timeout * 1000))ms timeout per flow"
      )
      print("")
      print(
        "Discovered \(topology.uniquePathCount) unique path(s) from \(topology.paths.count) flow variation(s) in \(String(format: "%.2f", topology.discoveryDuration))s"
      )
      print("")

      // Show divergence analysis
      if let divergence = topology.divergencePoint() {
        print("⚡ Paths diverge at TTL \(divergence) (ECMP load balancing detected)")
        print("")
      } else if topology.uniquePathCount > 1 {
        print("⚠️  Multiple paths found but no clear divergence point")
        print("")
      } else {
        print("ℹ️  Single path detected (no ECMP)")
        print("")
      }

      // Show each unique path
      for (index, path) in topology.paths.filter({ $0.isUnique }).enumerated() {
        print("=== Path \(index + 1) ===")
        print("Flow ID: 0x\(String(path.flowIdentifier.icmpID, radix: 16, uppercase: true))")
        print("Fingerprint: \(path.fingerprint)")
        print("Hops: \(path.trace.hops.count)")
        print("")

        // Show hop details
        for hop in path.trace.hops {
          if let ip = hop.ip {
            let hostname = (!noRDNS && hop.hostname != nil) ? hop.hostname! : ip
            let rttStr = hop.rtt.map { String(format: "%.3f ms", $0 * 1000) } ?? "timeout"
            let asnStr: String
            if isPrivateIPv4(ip) {
              asnStr = "[Private Network]"
            } else if isCGNATIPv4(ip) {
              asnStr = "[CGNAT]"
            } else if let asn = hop.asn {
              asnStr = "[AS\(asn) - \(hop.asName ?? "?")]"
            } else {
              asnStr = ""
            }
            let categoryLabel = categoryString(hop.category)
            print(
              String(
                format: "  %2d %@ %@ (%@) %@ %@", hop.ttl, categoryLabel, hostname, ip, rttStr,
                asnStr))
          } else {
            print(String(format: "  %2d * * *", hop.ttl))
          }
        }
        print("")
      }

      // Show summary statistics
      print("=== Summary ===")
      let uniqueHops = topology.uniqueHops()
      print("Total unique hops: \(uniqueHops.count)")

      if let prefix = topology.commonPrefix().last {
        print("Common path prefix: TTL 1-\(prefix.ttl)")
      }

      // Show monitoring targets
      if uniqueHops.count > 0 {
        print("")
        print("Monitoring targets (unique IPs):")
        for hop in uniqueHops.prefix(10) {
          if let ip = hop.ip {
            let hostname = (!noRDNS && hop.hostname != nil) ? " (\(hop.hostname!))" : ""
            print("  • \(ip)\(hostname)")
          }
        }
        if uniqueHops.count > 10 {
          print("  ... and \(uniqueHops.count - 10) more")
        }
      }
    }

    private func categoryString(_ cat: HopCategory) -> String {
      switch cat {
      case .local: return "[LAN   ]"
      case .isp: return "[ISP   ]"
      case .transit: return "[TRANSIT]"
      case .destination: return "[DESTINATION]"
      case .unknown: return "[UNKNOWN]"
      }
    }

    private func printJSON(_ topology: NetworkTopology) {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      let data = try! encoder.encode(topology)
      print(String(data: data, encoding: .utf8)!)
    }
  }
}
