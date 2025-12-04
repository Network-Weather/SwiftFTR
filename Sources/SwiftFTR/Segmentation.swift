import Foundation

/// Coarse category for a hop in the path.
public enum HopCategory: String, Sendable, Codable {
  case local = "LOCAL"
  case isp = "ISP"
  case transit = "TRANSIT"
  case destination = "DESTINATION"
  case unknown = "UNKNOWN"
  case vpn = "VPN"  // Any hop through a VPN tunnel (CGNAT, private IPs after tunnel, etc.)
}

/// A hop annotated with ASN and category information.
public struct ClassifiedHop: Sendable, Codable {
  public let ttl: Int
  public let ip: String?
  public let rtt: TimeInterval?
  public let asn: Int?
  public let asName: String?
  public let category: HopCategory
  /// Hostname from reverse DNS lookup
  public let hostname: String?

  public init(
    ttl: Int,
    ip: String?,
    rtt: TimeInterval?,
    asn: Int?,
    asName: String?,
    category: HopCategory,
    hostname: String? = nil
  ) {
    self.ttl = ttl
    self.ip = ip
    self.rtt = rtt
    self.asn = asn
    self.asName = asName
    self.category = category
    self.hostname = hostname
  }
}

/// Result of a classified trace including destination/public IP metadata.
public struct ClassifiedTrace: Sendable, Codable {
  public let destinationHost: String
  public let destinationIP: String
  /// Hostname of the destination IP from reverse DNS
  public let destinationHostname: String?
  public let publicIP: String?
  /// Hostname of the public IP from reverse DNS
  public let publicHostname: String?
  public let clientASN: Int?
  public let clientASName: String?
  public let destinationASN: Int?
  public let destinationASName: String?
  public let hops: [ClassifiedHop]

  public init(
    destinationHost: String,
    destinationIP: String,
    destinationHostname: String? = nil,
    publicIP: String? = nil,
    publicHostname: String? = nil,
    clientASN: Int? = nil,
    clientASName: String? = nil,
    destinationASN: Int? = nil,
    destinationASName: String? = nil,
    hops: [ClassifiedHop]
  ) {
    self.destinationHost = destinationHost
    self.destinationIP = destinationIP
    self.destinationHostname = destinationHostname
    self.publicIP = publicIP
    self.publicHostname = publicHostname
    self.clientASN = clientASN
    self.clientASName = clientASName
    self.destinationASN = destinationASN
    self.destinationASName = destinationASName
    self.hops = hops
  }
}

/// Context for VPN-aware hop classification.
///
/// When tracing through a VPN tunnel interface, CGNAT addresses (100.64.0.0/10)
/// should be classified as VPN/OVERLAY rather than ISP CGNAT.
public struct VPNContext: Sendable {
  /// Interface being traced (if known)
  public let traceInterface: String?

  /// Whether the trace interface is a VPN tunnel
  public let isVPNTrace: Bool

  /// VPN-assigned local IPs (to help identify VPN hops)
  public let vpnLocalIPs: Set<String>

  public init(
    traceInterface: String? = nil,
    isVPNTrace: Bool = false,
    vpnLocalIPs: Set<String> = []
  ) {
    self.traceInterface = traceInterface
    self.isVPNTrace = isVPNTrace
    self.vpnLocalIPs = vpnLocalIPs
  }

  /// Create context by auto-detecting from interface name.
  ///
  /// If the interface name matches VPN patterns (utun*, ipsec*, ppp*),
  /// the context will be configured for VPN-aware classification.
  public static func forInterface(_ name: String?) -> VPNContext {
    guard let name = name else {
      return VPNContext()
    }
    let isVPN = NetworkInterfaceDiscovery.isVPNInterface(name)
    return VPNContext(
      traceInterface: name,
      isVPNTrace: isVPN,
      vpnLocalIPs: []
    )
  }
}

/// Known hostname patterns for VPN overlay networks.
/// Used to detect VPN entry points via reverse DNS.
public struct VPNHostnamePatterns: Sendable {
  /// Hostname suffixes that indicate VPN infrastructure
  public static let suffixes: [String] = [
    ".ts.net",  // Tailscale MagicDNS
    ".tailscale.com",  // Tailscale public relays
    ".wg.run",  // WireGuard hosting
    ".mullvad.net",  // Mullvad VPN
    ".nordvpn.com",  // NordVPN
    ".expressvpn.com",  // ExpressVPN
    ".privateinternetaccess.com",  // PIA
  ]

  /// Check if a hostname matches any known VPN pattern.
  public static func isVPNHostname(_ hostname: String?) -> Bool {
    guard let hostname = hostname?.lowercased() else { return false }
    for suffix in suffixes {
      if hostname.hasSuffix(suffix) { return true }
    }
    return false
  }
}

/// Classifies plain traceroute results into segments and attaches ASN metadata.
public struct TraceClassifier: Sendable {
  public init() {}

  /// Classify a TraceResult into segments using ASN lookups and heuristics.
  /// - Parameters:
  ///   - trace: Plain traceroute output to classify.
  ///   - destinationIP: Destination IPv4 address (numeric string) for ASN matching.
  ///   - resolver: ASN resolver to use (DNS- or WHOIS-based).
  ///   - timeout: Per-lookup timeout in seconds.
  ///   - publicIP: Override public IP (bypasses STUN if provided).
  ///   - interface: Network interface to use for STUN discovery (if needed).
  ///   - sourceIP: Source IP address to bind to for STUN discovery (if needed).
  ///   - vpnContext: Context for VPN-aware classification (optional).
  ///   - enableLogging: Enable verbose logging for debugging.
  /// - Returns: A ClassifiedTrace with per-hop categories and ASNs when available.
  public func classify(
    trace: TraceResult,
    destinationIP: String,
    resolver: ASNResolver,
    timeout: TimeInterval = 1.5,
    publicIP: String? = nil,
    interface: String? = nil,
    sourceIP: String? = nil,
    vpnContext: VPNContext? = nil,
    enableLogging: Bool = false
  ) async throws -> ClassifiedTrace {
    // Gather IPs
    let hopIPs: [String] = trace.hops.compactMap { $0.ipAddress }
    var allIPs = Set(hopIPs)
    allIPs.insert(destinationIP)
    var resolvedPublicIP: String? = publicIP
    if let providedIP = publicIP {
      allIPs.insert(providedIP)
    } else {
      // Try STUN (best effort) if no public IP provided
      if let pub = try? stunGetPublicIPv4(
        timeout: 0.8, interface: interface, sourceIP: sourceIP, enableLogging: enableLogging)
      {
        resolvedPublicIP = pub.ip
        allIPs.insert(pub.ip)
      }
    }

    // Lookup ASNs in batch
    let asnMap = try? await resolver.resolve(ipv4Addrs: Array(allIPs), timeout: timeout)
    let clientAS = resolvedPublicIP.flatMap { asnMap?[$0] }
    let clientASN = clientAS?.asn
    let clientASName = clientAS?.name
    let destAS = asnMap?[destinationIP]
    let destASN = destAS?.asn
    let destASName = destAS?.name

    // Classify hops
    var out: [ClassifiedHop] = []
    var seenPublicIP = false  // Track if we've seen any public IP yet
    var inVPNTerritory = false  // Track if we've entered VPN territory
    var lastPublicASN: Int? = nil  // Track the last public ASN we saw
    let isVPNTrace = vpnContext?.isVPNTrace ?? false

    for hop in trace.hops {
      let ip = hop.ipAddress
      var cat: HopCategory = .unknown
      var asn: Int? = nil
      var name: String? = nil
      if let ip = ip {
        let isPrivate = isPrivateIPv4(ip)
        let isCGNAT = isCGNATIPv4(ip)
        let hostname = hop.hostname

        // Get ASN info regardless of IP type
        asn = asnMap?[ip]?.asn
        name = asnMap?[ip]?.name

        // Check for VPN entry point (multiple signals)
        // 1. CGNAT in VPN trace context
        // 2. Hostname matches known VPN patterns (e.g., .ts.net)
        let isVPNEntryPoint =
          isVPNTrace
          && (isCGNAT || VPNHostnamePatterns.isVPNHostname(hostname)
            || vpnContext?.vpnLocalIPs.contains(ip) == true)

        if isVPNEntryPoint {
          inVPNTerritory = true
        }

        // VPN-aware classification
        if isVPNTrace {
          // Once we enter VPN territory, everything is VPN until destination
          if inVPNTerritory {
            // Check if this is the destination
            if ip == destinationIP {
              cat = .destination
            } else {
              cat = .vpn
            }
          }
          // Private IP before VPN entry = local network
          else if isPrivate {
            cat = .local
          }
          // Public IP before VPN entry (unusual but possible)
          else {
            seenPublicIP = true
            if let asn = asn {
              lastPublicASN = asn
              if let cASN = clientASN, asn == cASN {
                cat = .isp
              } else if let dASN = destASN, asn == dASN {
                cat = .destination
              } else {
                cat = .transit
              }
            } else {
              cat = .transit
            }
          }
        }
        // Standard (non-VPN) classification
        else if isPrivate {
          // Private IP classification depends on context
          if !seenPublicIP {
            // Private IP before any public IP = LOCAL (LAN)
            cat = .local
          } else {
            // Private IP after public IP = likely ISP internal routing
            // If the last public ASN was the client's ISP, this is ISP routing
            if let lastASN = lastPublicASN, let cASN = clientASN, lastASN == cASN {
              cat = .isp
            } else {
              // Could be ISP or transit provider's internal routing
              cat = .isp  // Default to ISP since it's most common
            }
          }
        } else if isCGNAT {
          // CGNAT indicates ISP (in non-VPN context)
          cat = .isp
        } else {
          // Public IP
          seenPublicIP = true
          if let asn = asn {
            lastPublicASN = asn
            if let cASN = clientASN, asn == cASN {
              cat = .isp
            } else if let dASN = destASN, asn == dASN {
              cat = .destination
            } else {
              cat = .transit
            }
          } else {
            // No ASN found for a public IP: mark as TRANSIT per spec
            cat = .transit
          }
        }
      }
      out.append(
        ClassifiedHop(
          ttl: hop.ttl,
          ip: ip,
          rtt: hop.rtt,
          asn: asn,
          asName: name,
          category: cat,
          hostname: hop.hostname
        )
      )
    }

    // Interpolate non-reported segments (ip == nil) that are sandwiched between
    // identical categories (and, when possible, the same ASN) on both sides.
    if out.count >= 3 {
      var filled = out
      var i = 0
      while i < filled.count {
        // Find a run of missing replies
        if filled[i].ip == nil {
          let start = i
          var end = i
          while end < filled.count && filled[end].ip == nil { end += 1 }
          let leftIdx = start - 1
          let rightIdx = end
          if leftIdx >= 0 && rightIdx < filled.count {
            let left = filled[leftIdx]
            let right = filled[rightIdx]
            if left.category != .unknown && right.category != .unknown
              && left.category == right.category
            {
              // Category to fill
              let cat = left.category
              // ASN to fill if consistent on both sides
              var fillASN: Int? = nil
              var fillName: String? = nil
              if let la = left.asn, let ra = right.asn, la == ra {
                fillASN = la
                fillName = left.asName ?? right.asName
              }
              for k in start..<end {
                let hop = filled[k]
                filled[k] = ClassifiedHop(
                  ttl: hop.ttl,
                  ip: hop.ip,
                  rtt: hop.rtt,
                  asn: fillASN,
                  asName: fillName,
                  category: cat,
                  hostname: hop.hostname
                )
              }
            }
          }
          i = end
        } else {
          i += 1
        }
      }
      out = filled
    }

    return ClassifiedTrace(
      destinationHost: trace.destination,
      destinationIP: destinationIP,
      destinationHostname: nil,  // Will be filled by SwiftFTR.traceClassified
      publicIP: resolvedPublicIP,
      publicHostname: nil,  // Will be filled by SwiftFTR.traceClassified
      clientASN: clientASN,
      clientASName: clientASName,
      destinationASN: destASN,
      destinationASName: destASName,
      hops: out
    )
  }
}
