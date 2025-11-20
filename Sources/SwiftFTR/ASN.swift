import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// Autonomous System Number (ASN) metadata for an IP address or prefix.
public struct ASNInfo: Sendable, Hashable, Codable {
  public let asn: Int
  public let name: String
  public let prefix: String?
  public let countryCode: String?
  public let registry: String?
  public init(
    asn: Int, name: String, prefix: String? = nil, countryCode: String? = nil,
    registry: String? = nil
  ) {
    self.asn = asn
    self.name = name
    self.prefix = prefix
    self.countryCode = countryCode
    self.registry = registry
  }
}

/// Resolves origin ASNs and related metadata for IPv4 addresses.
public protocol ASNResolver: Sendable {
  /// Resolve metadata for the given IPv4 addresses.
  /// - Parameters:
  ///   - ipv4Addrs: IPv4 addresses as dotted-quad strings.
  ///   - timeout: Per-lookup timeout in seconds.
  /// - Returns: Map of input IP -> ASNInfo for addresses with public routing data.
  func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo]
}

// Simple in-memory cache for ASN lookups with a soft capacity cap.
actor _ASNMemoryCache {
  static let shared = _ASNMemoryCache()
  private var map: [String: ASNInfo] = [:]
  private var order: [String] = []
  private let capacity = 2048

  func getMany(_ keys: [String]) -> [String: ASNInfo] {
    var out: [String: ASNInfo] = [:]
    for k in keys { if let v = map[k] { out[k] = v } }
    return out
  }

  func setMany(_ items: [String: ASNInfo]) {
    for (k, v) in items {
      if map[k] == nil { order.append(k) }
      map[k] = v
    }
    // naive eviction
    if map.count > capacity {
      let over = map.count - capacity
      if over > 0 && over <= order.count {
        let drop = order.prefix(over)
        for k in drop { map.removeValue(forKey: k) }
        order.removeFirst(over)
      }
    }
  }
}

/// Decorator that caches results from an underlying ASNResolver in-memory.
public struct CachingASNResolver: ASNResolver {
  private let base: ASNResolver
  public init(base: ASNResolver) { self.base = base }
  #if compiler(>=6.2)
    @concurrent
  #endif
  public func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo]
  {
    let ips = Array(Set(ipv4Addrs.filter { !$0.isEmpty }))
    if ips.isEmpty { return [:] }
    let cached = await _ASNMemoryCache.shared.getMany(ips)
    let missing = ips.filter { cached[$0] == nil }
    var resolved: [String: ASNInfo] = cached
    if !missing.isEmpty {
      let res = try await base.resolve(ipv4Addrs: missing, timeout: timeout)
      if !res.isEmpty { await _ASNMemoryCache.shared.setMany(res) }
      for (k, v) in res { resolved[k] = v }
    }
    return resolved
  }
}

// Team Cymru DNS-based resolver using TXT queries.
/// Team Cymru DNS-based resolver using TXT queries for origin ASN and AS names.
public struct CymruDNSResolver: ASNResolver {
  public init() {}

  #if compiler(>=6.2)
    @concurrent
  #endif
  public func resolve(ipv4Addrs: [String], timeout: TimeInterval = 1.0) async throws -> [String:
    ASNInfo]
  {
    let ips = Array(Set(ipv4Addrs.filter { !$0.isEmpty }))
    var result: [String: ASNInfo] = [:]
    var asnNameCache: [Int: String] = [:]
    for ip in ips {
      // Skip non-public ranges; origin service maps only public routes
      if isPrivateIPv4(ip) || isCGNATIPv4(ip) { continue }
      // origin ASN
      let octs = ip.split(separator: ".")
      let rev = octs.reversed().joined(separator: ".")
      let q = "\(rev).origin.asn.cymru.com"
      guard let txts = DNSClient.queryTXT(name: q, timeout: timeout) else { continue }
      // Pick first TXT string and parse
      if let first = txts.first {
        // Format: "AS | BGP Prefix | CC | Registry | Allocated"
        let parts = first.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 4, let asField = parts.first {
          // Some responses might contain multiple ASNs separated by spaces; take the first token
          let tokens = asField.split(whereSeparator: { $0 == " " || $0 == "," })
          if let tok = tokens.first,
            let asn = Int(tok) ?? Int(tok.replacingOccurrences(of: "AS", with: ""))
          {
            // Get AS Name via AS{asn}.asn.cymru.com
            var name: String? = asnNameCache[asn]
            if name == nil {
              let qn = "AS\(asn).asn.cymru.com"
              if let txts2 = DNSClient.queryTXT(name: qn, timeout: timeout), let f2 = txts2.first {
                // Typical format: "AS | AS Name | CC | Registry | Allocated" (fields may vary).
                // Extract a plausible AS name from the TXT payload.
                let p2 = f2.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                name = pickASName(from: p2)
                if let n = name, !n.isEmpty { asnNameCache[asn] = n }
              }
            }
            let prefix = parts.count > 1 ? parts[1] : nil
            let cc = parts.count > 2 ? parts[2] : nil
            let reg = parts.count > 3 ? parts[3] : nil
            result[ip] = ASNInfo(
              asn: asn, name: name ?? "", prefix: prefix, countryCode: cc, registry: reg)
          }
        }
      }
    }
    return result
  }
}

private func pickASName(from fields: [String]) -> String? {
  // Heuristics: prefer index 1 if present; else choose the first field that isn't a 2-letter country code or a known registry, and contains a letter.
  if fields.indices.contains(1) {
    let v = fields[1].trimmingCharacters(in: .whitespaces)
    let registries: Set<String> = [
      "arin", "lacnic", "ripe", "ripencc", "apnic", "afrinic", "jpnic", "krnic",
    ]
    if !v.isEmpty && !(v.count == 2 && v == v.uppercased()) && !registries.contains(v.lowercased())
    {
      return v
    }
  }
  let registries: Set<String> = [
    "arin", "lacnic", "ripe", "ripencc", "apnic", "afrinic", "jpnic", "krnic",
  ]
  for f in fields {
    let s = f.trimmingCharacters(in: .whitespaces)
    if s.isEmpty { continue }
    let lower = s.lowercased()
    if registries.contains(lower) { continue }
    if s.count == 2 && s == s.uppercased() { continue }  // likely country code
    if s.range(of: "[A-Za-z]", options: .regularExpression) != nil {
      return s
    }
  }
  return fields.last
}
