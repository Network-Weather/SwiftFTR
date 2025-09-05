import Foundation

#if canImport(Darwin)
  import Darwin
#endif

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

public protocol ASNResolver: Sendable {
  func resolve(ipv4Addrs: [String], timeout: TimeInterval) throws -> [String: ASNInfo]
}

// Simple in-memory cache for ASN lookups with a soft capacity cap.
final class _ASNMemoryCache: @unchecked Sendable {
  static let shared = _ASNMemoryCache()
  private let lock = NSLock()
  private var map: [String: ASNInfo] = [:]
  private var order: [String] = []
  private let capacity = 2048

  func getMany(_ keys: [String]) -> [String: ASNInfo] {
    lock.lock()
    defer { lock.unlock() }
    var out: [String: ASNInfo] = [:]
    for k in keys { if let v = map[k] { out[k] = v } }
    return out
  }

  func setMany(_ items: [String: ASNInfo]) {
    lock.lock()
    defer { lock.unlock() }
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

public struct CachingASNResolver: ASNResolver {
  private let base: ASNResolver
  public init(base: ASNResolver) { self.base = base }
  public func resolve(ipv4Addrs: [String], timeout: TimeInterval) throws -> [String: ASNInfo] {
    let ips = Array(Set(ipv4Addrs.filter { !$0.isEmpty }))
    if ips.isEmpty { return [:] }
    let cached = _ASNMemoryCache.shared.getMany(ips)
    let missing = ips.filter { cached[$0] == nil }
    var resolved: [String: ASNInfo] = cached
    if !missing.isEmpty {
      let res = try base.resolve(ipv4Addrs: missing, timeout: timeout)
      if !res.isEmpty { _ASNMemoryCache.shared.setMany(res) }
      for (k, v) in res { resolved[k] = v }
    }
    return resolved
  }
}

// Team Cymru bulk WHOIS client (port 43). Batches queries to reduce load.
public struct CymruWhoisResolver: ASNResolver {
  public init() {}

  public func resolve(ipv4Addrs: [String], timeout: TimeInterval = 1.5) throws -> [String: ASNInfo]
  {
    let ips = Array(Set(ipv4Addrs.filter { !$0.isEmpty }))
    if ips.isEmpty { return [:] }
    let addr = try connectWhois(host: "whois.cymru.com", port: 43, timeout: timeout)
    defer { close(addr) }
    let filtered = ips.filter { !(isPrivateIPv4($0) || isCGNATIPv4($0)) }
    if filtered.isEmpty { return [:] }
    let query = (["begin", "verbose"] + filtered + ["end"]).joined(separator: "\n") + "\n"
    _ = query.withCString { cs in write(addr, cs, strlen(cs)) }

    // Read response
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
      let n = read(addr, &buf, buf.count)
      if n > 0 { out.append(buf, count: n) } else { break }
      if out.count > 1_000_000 { break }
    }
    guard let text = String(data: out, encoding: .utf8) else { return [:] }
    var map: [String: ASNInfo] = [:]
    for line in text.split(separator: "\n") {
      let s = line.trimmingCharacters(in: .whitespaces)
      if s.isEmpty { continue }
      if s.hasPrefix("AS") && s.contains("| IP |") { continue }  // header
      let parts = s.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
      // Expected verbose format: AS | IP | BGP Prefix | CC | Registry | Allocated | AS Name
      if parts.count >= 7 {
        let asStr = parts[0]
        let ipStr = parts[1]
        let asName = parts[6]
        let prefix = parts[2]
        let cc = parts[3]
        let reg = parts[4]
        if let asn = Int(asStr) {
          map[String(ipStr)] = ASNInfo(
            asn: asn, name: String(asName), prefix: prefix, countryCode: cc, registry: reg)
        }
      }
    }
    return map
  }

  private func connectWhois(host: String, port: UInt16, timeout: TimeInterval) throws -> Int32 {
    var hints = addrinfo(
      ai_flags: AI_ADDRCONFIG, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
      ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var res: UnsafeMutablePointer<addrinfo>? = nil
    guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else {
      throw TracerouteError.resolutionFailed
    }
    defer { freeaddrinfo(info) }
    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    if fd < 0 { throw TracerouteError.socketCreateFailed(errno: errno) }

    // Set non-blocking connect with timeout
    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    var sa = sockaddr_in()
    memcpy(
      &sa, info.pointee.ai_addr, min(MemoryLayout<sockaddr_in>.size, Int(info.pointee.ai_addrlen)))
    let rv = withUnsafePointer(to: &sa) { aptr in
      aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
        connect(fd, saptr, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if rv < 0 && errno == EINPROGRESS {
      var pfd = Darwin.pollfd(fd: fd, events: Int16(Darwin.POLLOUT), revents: 0)
      let ms = Int32(timeout * 1000)
      let pr = withUnsafeMutablePointer(to: &pfd) { Darwin.poll($0, 1, ms) }
      if pr <= 0 {
        close(fd)
        throw TracerouteError.socketCreateFailed(errno: ETIMEDOUT)
      }
      // Check for error
      var err: Int32 = 0
      var len = socklen_t(MemoryLayout<Int32>.size)
      if getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) != 0 || err != 0 {
        close(fd)
        throw TracerouteError.socketCreateFailed(errno: err)
      }
    } else if rv < 0 {
      close(fd)
      throw TracerouteError.socketCreateFailed(errno: errno)
    }
    // Set timeouts for read/write
    var tv = timeval(
      tv_sec: Int(timeout), tv_usec: __darwin_suseconds_t((timeout - floor(timeout)) * 1_000_000))
    _ = withUnsafePointer(to: &tv) { p in
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, p, socklen_t(MemoryLayout<timeval>.size))
    }
    _ = withUnsafePointer(to: &tv) { p in
      setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, p, socklen_t(MemoryLayout<timeval>.size))
    }
    return fd
  }
}

// Team Cymru DNS-based resolver using TXT queries.
public struct CymruDNSResolver: ASNResolver {
  public init() {}

  public func resolve(ipv4Addrs: [String], timeout: TimeInterval = 1.0) throws -> [String: ASNInfo]
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
