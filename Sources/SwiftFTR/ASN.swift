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

// Actor-based semaphore for limiting concurrent DNS queries.
private actor _ConcurrencySemaphore {
  private var available: Int
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(maxConcurrent: Int) { self.available = maxConcurrent }

  func wait() async {
    if available > 0 {
      available -= 1
    } else {
      await withCheckedContinuation { continuation in
        waiters.append(continuation)
      }
    }
  }

  func signal() {
    if !waiters.isEmpty {
      let waiter = waiters.removeFirst()
      waiter.resume()
    } else {
      available += 1
    }
  }
}

// Intermediate result from origin ASN lookup.
private struct _OriginASNResult: Sendable {
  let asn: Int
  let prefix: String?
  let cc: String?
  let registry: String?
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
    if ips.isEmpty { return [:] }

    // Filter to only public IPs
    let publicIPs = ips.filter { !isPrivateIPv4($0) && !isCGNATIPv4($0) }
    if publicIPs.isEmpty { return [:] }

    let semaphore = _ConcurrencySemaphore(maxConcurrent: 8)

    // Phase 1: Parallel origin ASN lookups
    let originResults: [String: _OriginASNResult] = await withTaskGroup(
      of: (String, _OriginASNResult?).self
    ) { group in
      for ip in publicIPs {
        group.addTask {
          await semaphore.wait()
          defer { Task { await semaphore.signal() } }
          return (ip, await self.lookupOriginASN(ip: ip, timeout: timeout))
        }
      }

      var results: [String: _OriginASNResult] = [:]
      for await (ip, result) in group {
        if let r = result { results[ip] = r }
      }
      return results
    }

    if originResults.isEmpty { return [:] }

    // Phase 2: Parallel AS name lookups for unique ASNs only
    let uniqueASNs = Array(Set(originResults.values.map { $0.asn }))
    let asnNames: [Int: String] = await withTaskGroup(of: (Int, String?).self) { group in
      for asn in uniqueASNs {
        group.addTask {
          await semaphore.wait()
          defer { Task { await semaphore.signal() } }
          return (asn, await self.lookupASName(asn: asn, timeout: timeout))
        }
      }

      var names: [Int: String] = [:]
      for await (asn, name) in group {
        if let n = name { names[asn] = n }
      }
      return names
    }

    // Combine results
    var result: [String: ASNInfo] = [:]
    for (ip, origin) in originResults {
      result[ip] = ASNInfo(
        asn: origin.asn,
        name: asnNames[origin.asn] ?? "",
        prefix: origin.prefix,
        countryCode: origin.cc,
        registry: origin.registry
      )
    }
    return result
  }

  /// Look up origin ASN for a single IP address.
  private func lookupOriginASN(ip: String, timeout: TimeInterval) async -> _OriginASNResult? {
    let octs = ip.split(separator: ".")
    let rev = octs.reversed().joined(separator: ".")
    let q = "\(rev).origin.asn.cymru.com"

    // Wrap blocking DNS call in detached task
    let txts = await Task.detached(priority: .userInitiated) {
      DNSClient.queryTXT(name: q, timeout: timeout)
    }.value
    guard let txts = txts, let first = txts.first else { return nil }

    // Format: "AS | BGP Prefix | CC | Registry | Allocated"
    let parts = first.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count >= 4, let asField = parts.first else { return nil }

    // Some responses contain multiple ASNs separated by spaces; take the first token
    let tokens = asField.split(whereSeparator: { $0 == " " || $0 == "," })
    guard let tok = tokens.first,
      let asn = Int(tok) ?? Int(tok.replacingOccurrences(of: "AS", with: ""))
    else { return nil }

    let prefix = parts.count > 1 ? parts[1] : nil
    let cc = parts.count > 2 ? parts[2] : nil
    let reg = parts.count > 3 ? parts[3] : nil

    return _OriginASNResult(asn: asn, prefix: prefix, cc: cc, registry: reg)
  }

  /// Look up AS name for a single ASN.
  private func lookupASName(asn: Int, timeout: TimeInterval) async -> String? {
    let qn = "AS\(asn).asn.cymru.com"

    // Wrap blocking DNS call in detached task
    let txts = await Task.detached(priority: .userInitiated) {
      DNSClient.queryTXT(name: qn, timeout: timeout)
    }.value
    guard let txts = txts, let first = txts.first else { return nil }

    // Typical format: "AS | AS Name | CC | Registry | Allocated"
    let parts = first.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    return pickASName(from: parts)
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
