import Foundation

/// Coarse category for a hop in the path.
public enum HopCategory: String, Sendable, Codable {
  case local = "LOCAL"
  case isp = "ISP"
  case transit = "TRANSIT"
  case destination = "DESTINATION"
  case unknown = "UNKNOWN"
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
  ///   - sourceIP: Source IPv4 address to bind ASN/STUN lookups to when explicit binding is required.
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
    enableLogging: Bool = false
  ) throws -> ClassifiedTrace {
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
    let asnMap = try? resolver.resolve(ipv4Addrs: Array(allIPs), timeout: timeout)
    let clientAS = resolvedPublicIP.flatMap { asnMap?[$0] }
    let clientASN = clientAS?.asn
    let clientASName = clientAS?.name
    let destAS = asnMap?[destinationIP]
    let destASN = destAS?.asn
    let destASName = destAS?.name

    // Classify hops
    var out: [ClassifiedHop] = []
    var seenPublicIP = false  // Track if we've seen any public IP yet
    var lastPublicASN: Int? = nil  // Track the last public ASN we saw

    for hop in trace.hops {
      let ip = hop.ipAddress
      var cat: HopCategory = .unknown
      var asn: Int? = nil
      var name: String? = nil
      if let ip = ip {
        let isPrivate = isPrivateIPv4(ip)
        let isCGNAT = isCGNATIPv4(ip)

        // Get ASN info regardless of IP type
        asn = asnMap?[ip]?.asn
        name = asnMap?[ip]?.name

        if isPrivate {
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
          // CGNAT always indicates ISP
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
