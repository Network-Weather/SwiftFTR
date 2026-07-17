import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// Public IP discovered via a STUN Binding request. The `ip` string is in
/// canonical `inet_ntop` form for v4 (`x.x.x.x`) or v6 (`fc00::1`).
public struct STUNPublicIP: Sendable {
  public let ip: String
  /// Address family of the discovered IP. `AF_INET` (2) or `AF_INET6` (30 on Darwin).
  /// Added for Stage-4 dual-stack discovery; older callers can ignore it.
  public let family: Int32

  public init(ip: String, family: Int32 = AF_INET) {
    self.ip = ip
    self.family = family
  }
}

/// Public IPs discovered across both v4 and v6 in a single sweep. Either field
/// may be nil if that family's STUN/DNS path didn't succeed. NWX-style downstream
/// consumers can render both alongside each other (e.g. a status row showing
/// "v4: 203.0.113.5 / v6: 2001:db8::1").
public struct PublicIPs: Sendable {
  public let v4: String?
  public let v6: String?

  public init(v4: String? = nil, v6: String? = nil) {
    self.v4 = v4
    self.v6 = v6
  }

  /// Convenience: any non-nil IP, preferring v6 if both are present. Useful for
  /// callers that just want "what IP is the world likely to see me as" and
  /// don't need the family-specific breakdown.
  public var any: String? { v6 ?? v4 }
}

/// Well-known public STUN servers for fallback.
/// Uses multiple providers and ports for resilience. Cloudflare and Google's
/// STUN servers resolve to both v4 and v6 records; the family preference passed
/// to the resolver determines which is used.
let stunServers: [(host: String, port: UInt16)] = [
  ("stun.l.google.com", 19302),  // Google (port 19302)
  ("stun1.l.google.com", 19302),  // Google backup (port 19302)
  ("stun.cloudflare.com", 3478),  // Cloudflare (port 3478)
]

enum STUNError: Error, CustomStringConvertible {
  case resolveFailed(errno: Int32, details: String?)
  case socketFailed(errno: Int32, details: String?)
  case connectFailed(errno: Int32, details: String?)
  case sendFailed(errno: Int32, details: String?)
  case recvTimeout
  case invalidTimeout(TimeInterval)
  case invalidResponse(String)
  case interfaceBindFailed(interface: String, errno: Int32, details: String?)
  case sourceIPBindFailed(sourceIP: String, errno: Int32, details: String?)

  var description: String {
    switch self {
    case .resolveFailed(let errno, let details):
      let errStr = errno != 0 ? String(cString: strerror(errno)) : "Unknown error"
      let baseMsg = "Failed to resolve STUN server (errno=\(errno)): \(errStr)"
      return details.map { "\(baseMsg). \($0)" } ?? baseMsg
    case .socketFailed(let errno, let details):
      let errStr = String(cString: strerror(errno))
      let baseMsg = "Failed to create UDP socket for STUN (errno=\(errno)): \(errStr)"
      return details.map { "\(baseMsg). \($0)" } ?? baseMsg
    case .connectFailed(let errno, let details):
      let errStr = String(cString: strerror(errno))
      let baseMsg = "Failed to connect STUN socket (errno=\(errno)): \(errStr)"
      return details.map { "\(baseMsg). \($0)" } ?? baseMsg
    case .sendFailed(let errno, let details):
      let errStr = String(cString: strerror(errno))
      let baseMsg = "Failed to send STUN request (errno=\(errno)): \(errStr)"
      return details.map { "\(baseMsg). \($0)" } ?? baseMsg
    case .recvTimeout:
      return "STUN request timed out"
    case .invalidTimeout(let timeout):
      return "Invalid STUN timeout: \(timeout). Timeout must be finite and greater than zero"
    case .invalidResponse(let reason):
      return "Invalid STUN response: \(reason)"
    case .interfaceBindFailed(let interface, let errno, let details):
      let errStr = String(cString: strerror(errno))
      let baseMsg =
        "Failed to bind STUN socket to interface '\(interface)' (errno=\(errno)): \(errStr)"
      return details.map { "\(baseMsg). \($0)" } ?? baseMsg
    case .sourceIPBindFailed(let sourceIP, let errno, let details):
      let errStr = String(cString: strerror(errno))
      let baseMsg =
        "Failed to bind STUN socket to source IP '\(sourceIP)' (errno=\(errno)): \(errStr)"
      return details.map { "\(baseMsg). \($0)" } ?? baseMsg
    }
  }
}

/// Family-parameterized STUN core. Builds the binding request, sends it, and
/// parses the XOR-MAPPED-ADDRESS attribute. Supports both AF_INET and AF_INET6.
///
/// Pass `family: AF_INET6` to discover the v6 public IP; the resolver, socket,
/// and bind paths all dispatch on family. The XOR-MAPPED-ADDRESS parser handles
/// both v4 (Family 0x01) and v6 (Family 0x02) per RFC 5389 §15.2.
internal func stunGetPublicIP(
  family: Int32,
  host: String,
  port: UInt16,
  timeout: TimeInterval = 1.0,
  interface: String? = nil,
  sourceIP: String? = nil,
  enableLogging: Bool = false
) throws -> STUNPublicIP {
  guard timeout.isFinite, timeout > 0, timeout <= TimeInterval(Int32.max) else {
    throw STUNError.invalidTimeout(timeout)
  }

  var hints = addrinfo(
    ai_flags: AI_ADDRCONFIG, ai_family: family, ai_socktype: SOCK_DGRAM,
    ai_protocol: IPPROTO_UDP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
  var res: UnsafeMutablePointer<addrinfo>? = nil
  let resolveResult = getaddrinfo(host, String(port), &hints, &res)
  guard resolveResult == 0, let info = res, let sa = info.pointee.ai_addr else {
    let error = errno
    let famName = family == AF_INET6 ? "v6" : "v4"
    throw STUNError.resolveFailed(
      errno: error,
      details: "Failed to resolve STUN server '\(host):\(port)' (\(famName))")
  }
  defer { freeaddrinfo(info) }

  // Copy the resolved sockaddr into sockaddr_storage so we can sendto from a
  // single family-agnostic value.
  var server = sockaddr_storage()
  let serverLen = socklen_t(min(MemoryLayout<sockaddr_storage>.size, Int(info.pointee.ai_addrlen)))
  _ = withUnsafeMutablePointer(to: &server) { dst in
    memcpy(dst, sa, Int(serverLen))
  }

  let fd = socket(family, SOCK_DGRAM, IPPROTO_UDP)
  if fd < 0 {
    let error = errno
    throw STUNError.socketFailed(
      errno: error,
      details: "Unable to create UDP socket for STUN. May indicate system resource limits.")
  }
  defer { close(fd) }

  if let interfaceName = interface {
    if enableLogging {
      print("[STUN] Binding socket to interface '\(interfaceName)'...")
    }
    #if os(macOS)
      let ifIndex = if_nametoindex(interfaceName)
      if ifIndex == 0 {
        let error = errno
        let details = "Interface '\(interfaceName)' not found for STUN."
        if enableLogging { print("[STUN] ERROR: \(details)") }
        throw STUNError.interfaceBindFailed(
          interface: interfaceName, errno: error, details: details)
      }
      if let errMsg = bindInterface(sockfd: fd, family: family, ifIndex: ifIndex) {
        let error = errno
        if enableLogging { print("[STUN] ERROR: \(errMsg)") }
        throw STUNError.interfaceBindFailed(
          interface: interfaceName, errno: error, details: errMsg)
      }
      if enableLogging {
        print("[STUN] Bound to interface '\(interfaceName)' (index: \(ifIndex))")
      }
    #else
      throw STUNError.interfaceBindFailed(
        interface: interfaceName, errno: ENOTSUP,
        details: "Interface binding for STUN currently only supported on macOS.")
    #endif
  }

  if let srcIP = sourceIP {
    if enableLogging {
      print("[STUN] Binding socket to source IP '\(srcIP)'...")
    }
    if let errMsg = bindSourceIP(sockfd: fd, family: family, sourceIP: srcIP) {
      if enableLogging { print("[STUN] ERROR: \(errMsg)") }
      throw STUNError.sourceIPBindFailed(sourceIP: srcIP, errno: errno, details: errMsg)
    }
    if enableLogging { print("[STUN] Bound to source IP '\(srcIP)'") }
  }

  // Connect the datagram socket before sending. Besides simplifying I/O, this
  // makes the kernel discard datagrams from peers other than the resolved STUN
  // server, so an unrelated packet cannot win the response race.
  let connectResult = withUnsafePointer(to: &server) { aptr in
    aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
      connect(fd, saptr, serverLen)
    }
  }
  guard connectResult == 0 else {
    let error = errno
    throw STUNError.connectFailed(
      errno: error, details: "Failed to connect to \(host):\(port)")
  }

  // Set timeouts. A zero timeval disables SO_RCVTIMEO, so invalid values are
  // rejected above and option failures are surfaced rather than ignored.
  var tv = timeval(
    tv_sec: Int(timeout), tv_usec: __darwin_suseconds_t((timeout - floor(timeout)) * 1_000_000))
  let receiveTimeoutResult = withUnsafePointer(to: &tv) { p in
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, p, socklen_t(MemoryLayout<timeval>.size))
  }
  guard receiveTimeoutResult == 0 else {
    let error = errno
    throw STUNError.socketFailed(errno: error, details: "Failed to configure receive timeout")
  }
  let sendTimeoutResult = withUnsafePointer(to: &tv) { p in
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, p, socklen_t(MemoryLayout<timeval>.size))
  }
  guard sendTimeoutResult == 0 else {
    let error = errno
    throw STUNError.socketFailed(errno: error, details: "Failed to configure send timeout")
  }

  // Build STUN Binding Request (RFC 5389 §6).
  var req = [UInt8](repeating: 0, count: 20)
  // Type 0x0001 (Binding Request), Length 0x0000.
  req[0] = 0x00
  req[1] = 0x01
  req[2] = 0x00
  req[3] = 0x00
  // Magic cookie 0x2112A442.
  req[4] = 0x21
  req[5] = 0x12
  req[6] = 0xA4
  req[7] = 0x42
  // Transaction ID — 12 random bytes. We keep a copy because the IPv6
  // XOR-MAPPED-ADDRESS parse needs them to un-XOR bytes 4..15 of the address.
  var transactionID = [UInt8](repeating: 0, count: 12)
  for i in 0..<12 {
    transactionID[i] = UInt8.random(in: 0...255)
    req[8 + i] = transactionID[i]
  }

  let sent = req.withUnsafeBytes { raw in
    send(fd, raw.baseAddress!, raw.count, 0)
  }
  if sent < 0 {
    let error = errno
    throw STUNError.sendFailed(
      errno: error, details: "Failed to send STUN request to \(host):\(port)")
  }

  // The connected UDP socket accepts responses only from the selected server.
  var buf = [UInt8](repeating: 0, count: 512)
  let n = recv(fd, &buf, buf.count, 0)
  if n <= 0 { throw STUNError.recvTimeout }

  return try parseSTUNBindingResponse(
    Array(buf.prefix(Int(n))), transactionID: transactionID, expectedFamily: family)
}

/// Validates and parses a STUN Binding Success Response (RFC 5389).
///
/// Kept separate from socket I/O so malformed and mismatched responses can be
/// regression-tested deterministically.
internal func parseSTUNBindingResponse(
  _ response: [UInt8], transactionID: [UInt8], expectedFamily: Int32
) throws -> STUNPublicIP {
  guard transactionID.count == 12 else {
    throw STUNError.invalidResponse("request transaction ID must contain 12 bytes")
  }
  guard response.count >= 20 else {
    throw STUNError.invalidResponse("header is shorter than 20 bytes")
  }

  let messageType = UInt16(response[0]) << 8 | UInt16(response[1])
  guard messageType == 0x0101 else {
    throw STUNError.invalidResponse(
      String(format: "unexpected message type 0x%04x", messageType))
  }

  let messageLength = Int(UInt16(response[2]) << 8 | UInt16(response[3]))
  guard messageLength.isMultiple(of: 4), response.count == 20 + messageLength else {
    throw STUNError.invalidResponse("declared message length does not match datagram")
  }

  let cookie =
    UInt32(response[4]) << 24 | UInt32(response[5]) << 16
    | UInt32(response[6]) << 8 | UInt32(response[7])
  let magic: UInt32 = 0x2112_A442
  guard cookie == magic else {
    throw STUNError.invalidResponse("magic cookie mismatch")
  }
  guard Array(response[8..<20]) == transactionID else {
    throw STUNError.invalidResponse("transaction ID mismatch")
  }

  // Parse XOR-MAPPED-ADDRESS (0x0020) or MAPPED-ADDRESS (0x0001) per RFC 5389 §15.
  var ofs = 20
  while ofs < response.count {
    guard ofs + 4 <= response.count else {
      throw STUNError.invalidResponse("truncated attribute header")
    }
    let atype = UInt16(response[ofs]) << 8 | UInt16(response[ofs + 1])
    let alen = Int(UInt16(response[ofs + 2]) << 8 | UInt16(response[ofs + 3]))
    ofs += 4
    guard ofs + alen <= response.count else {
      throw STUNError.invalidResponse("attribute exceeds declared message length")
    }
    if atype == 0x0020 || atype == 0x0001 {
      if alen >= 8 {
        let attrFamily = response[ofs + 1]
        // Reserved/port handling — we don't use the port, just skip past it.
        if attrFamily == 0x01 && alen == 8 && expectedFamily == AF_INET {
          // IPv4 — 4 bytes of address after the 4-byte family/port header.
          var addr: UInt32 =
            (UInt32(response[ofs + 4]) << 24) | (UInt32(response[ofs + 5]) << 16)
            | (UInt32(response[ofs + 6]) << 8) | UInt32(response[ofs + 7])
          if atype == 0x0020 { addr ^= magic }
          let oct1 = (addr >> 24) & 0xFF
          let oct2 = (addr >> 16) & 0xFF
          let oct3 = (addr >> 8) & 0xFF
          let oct4 = addr & 0xFF
          return STUNPublicIP(ip: "\(oct1).\(oct2).\(oct3).\(oct4)", family: AF_INET)
        } else if attrFamily == 0x02 && alen == 20 && expectedFamily == AF_INET6 {
          // IPv6 — 16 bytes of address. For XOR-MAPPED-ADDRESS the first 4
          // bytes XOR against the magic cookie; the remaining 12 bytes XOR
          // against the request transaction ID (RFC 5389 §15.2).
          var v6Bytes = [UInt8](repeating: 0, count: 16)
          for i in 0..<16 { v6Bytes[i] = response[ofs + 4 + i] }
          if atype == 0x0020 {
            v6Bytes[0] ^= UInt8((magic >> 24) & 0xFF)
            v6Bytes[1] ^= UInt8((magic >> 16) & 0xFF)
            v6Bytes[2] ^= UInt8((magic >> 8) & 0xFF)
            v6Bytes[3] ^= UInt8(magic & 0xFF)
            for i in 0..<12 { v6Bytes[4 + i] ^= transactionID[i] }
          }
          // Format as canonical IPv6 string via inet_ntop.
          var in6 = in6_addr()
          withUnsafeMutableBytes(of: &in6) { dst in
            for i in 0..<16 { dst[i] = v6Bytes[i] }
          }
          var strBuf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
          _ = withUnsafePointer(to: &in6) { src in
            inet_ntop(AF_INET6, src, &strBuf, socklen_t(INET6_ADDRSTRLEN))
          }
          let ip = strBuf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
          return STUNPublicIP(ip: ip, family: AF_INET6)
        }
      }
    }
    // Attributes are padded to 4.
    let paddedLength = ((alen + 3) / 4) * 4
    guard ofs + paddedLength <= response.count else {
      throw STUNError.invalidResponse("attribute padding exceeds message length")
    }
    ofs += paddedLength
  }
  throw STUNError.invalidResponse("missing mapped address for requested family")
}

/// Back-compat wrapper for v4-only callers. Same signature/behavior as before
/// Stage 4; delegates to the family-parameterized `stunGetPublicIP`.
func stunGetPublicIPv4(
  host: String = "stun.l.google.com", port: UInt16 = 19302, timeout: TimeInterval = 1.0,
  interface: String? = nil, sourceIP: String? = nil, enableLogging: Bool = false
) throws -> STUNPublicIP {
  return try stunGetPublicIP(
    family: AF_INET, host: host, port: port, timeout: timeout,
    interface: interface, sourceIP: sourceIP, enableLogging: enableLogging)
}

/// v6 companion to `stunGetPublicIPv4`. Forces the resolver and socket to v6.
func stunGetPublicIPv6(
  host: String = "stun.cloudflare.com", port: UInt16 = 3478, timeout: TimeInterval = 1.0,
  interface: String? = nil, sourceIP: String? = nil, enableLogging: Bool = false
) throws -> STUNPublicIP {
  return try stunGetPublicIP(
    family: AF_INET6, host: host, port: port, timeout: timeout,
    interface: interface, sourceIP: sourceIP, enableLogging: enableLogging)
}

// MARK: - Multi-Server STUN Fallback

/// Attempts to discover the public IP of a given family by trying multiple STUN
/// servers in sequence. Falls back through the server list until one succeeds.
///
/// - Parameters:
///   - family: `AF_INET` for v4 or `AF_INET6` for v6.
///   - timeout: Timeout per server attempt (default 1.0s)
///   - interface: Network interface to bind to (optional)
///   - sourceIP: Source IP address to bind to (optional)
///   - enableLogging: Enable debug logging
/// - Returns: Public IP if any server responds
/// - Throws: STUNError.recvTimeout if all servers fail
internal func stunGetPublicIPWithFallback(
  family: Int32,
  timeout: TimeInterval = 1.0,
  interface: String? = nil,
  sourceIP: String? = nil,
  enableLogging: Bool = false
) throws -> STUNPublicIP {
  var lastError: Error = STUNError.recvTimeout
  let famName = family == AF_INET6 ? "v6" : "v4"

  for (host, port) in stunServers {
    if enableLogging {
      print("[STUN] Trying \(host):\(port) (\(famName))...")
    }
    do {
      let result = try stunGetPublicIP(
        family: family, host: host, port: port, timeout: timeout,
        interface: interface, sourceIP: sourceIP, enableLogging: enableLogging)
      if enableLogging {
        print("[STUN] Success from \(host):\(port) (\(famName)) -> \(result.ip)")
      }
      return result
    } catch {
      if enableLogging {
        print("[STUN] Failed \(host):\(port) (\(famName)): \(error)")
      }
      lastError = error
      continue
    }
  }

  throw lastError
}

/// Back-compat shim — v4-only callers.
func stunGetPublicIPv4WithFallback(
  timeout: TimeInterval = 1.0,
  interface: String? = nil,
  sourceIP: String? = nil,
  enableLogging: Bool = false
) throws -> STUNPublicIP {
  return try stunGetPublicIPWithFallback(
    family: AF_INET, timeout: timeout,
    interface: interface, sourceIP: sourceIP, enableLogging: enableLogging)
}

/// v6 companion.
func stunGetPublicIPv6WithFallback(
  timeout: TimeInterval = 1.0,
  interface: String? = nil,
  sourceIP: String? = nil,
  enableLogging: Bool = false
) throws -> STUNPublicIP {
  return try stunGetPublicIPWithFallback(
    family: AF_INET6, timeout: timeout,
    interface: interface, sourceIP: sourceIP, enableLogging: enableLogging)
}

// MARK: - DNS-Based Public IP Discovery

/// Error type for DNS-based public IP discovery
enum DNSPublicIPError: Error, CustomStringConvertible, Sendable {
  case queryFailed(String)
  case noIPInResponse

  var description: String {
    switch self {
    case .queryFailed(let reason):
      return "DNS public IP query failed: \(reason)"
    case .noIPInResponse:
      return "DNS response did not contain an IP address"
    }
  }
}

/// Discovers public IPv4 via DNS TXT query to Akamai's whoami service.
/// This works in captive portal environments where STUN may be blocked,
/// because DNS queries are typically allowed (needed for the captive portal itself).
///
/// Queries: whoami.ds.akahelp.net TXT
/// Response format: "ip" "x.x.x.x", "ecs" "x.x.x.0/24/24", "ns" "x.x.x.x"
///
/// - Parameters:
///   - timeout: Query timeout (default 2.0s)
///   - servers: DNS servers to try (default: Cloudflare + Google)
///   - enableLogging: Enable debug logging
/// - Returns: Public IP from DNS response
/// - Throws: DNSPublicIPError on failure
func getPublicIPv4ViaDNS(
  timeout: TimeInterval = 2.0,
  servers: [String] = ["1.1.1.1", "8.8.8.8"],
  enableLogging: Bool = false
) throws -> STUNPublicIP {
  if enableLogging {
    print("[DNS-IP] Querying whoami.ds.akahelp.net TXT...")
  }

  // Use existing DNSClient.queryTXT which tries multiple servers
  guard
    let txtRecords = DNSClient.queryTXT(
      name: "whoami.ds.akahelp.net",
      timeout: timeout,
      servers: servers
    )
  else {
    throw DNSPublicIPError.queryFailed("No response from DNS servers")
  }

  if enableLogging {
    print("[DNS-IP] Got \(txtRecords.count) TXT records")
  }

  // Parse response - looking for the "ip" record
  // Akamai returns multiple TXT records: "ns<IP>", "ecs<subnet>", "ip<IP>"
  // The TXT character-strings are concatenated, so we see e.g. "ip4.36.162.212"
  for record in txtRecords {
    if enableLogging {
      print("[DNS-IP] Record: \(record)")
    }

    let trimmed = record.trimmingCharacters(in: .whitespaces)

    // Look for record starting with "ip" prefix
    if trimmed.hasPrefix("ip") {
      // Extract the IP address after the "ip" prefix
      var ipPart = String(trimmed.dropFirst(2))
      ipPart = ipPart.trimmingCharacters(in: CharacterSet(charactersIn: " \""))

      // Validate it's a valid IPv4 address
      let octets = ipPart.split(separator: ".").compactMap { Int($0) }
      if octets.count == 4, octets.allSatisfy({ $0 >= 0 && $0 <= 255 }) {
        if enableLogging {
          print("[DNS-IP] Found public IP: \(ipPart)")
        }
        return STUNPublicIP(ip: ipPart)
      }
    }
  }

  throw DNSPublicIPError.noIPInResponse
}

// MARK: - Unified Public IP Discovery

/// Error type for unified public IP discovery
public enum PublicIPError: Error, CustomStringConvertible, Sendable {
  case allMethodsFailed(stunError: String, dnsError: String)

  public var description: String {
    switch self {
    case .allMethodsFailed(let stunError, let dnsError):
      return "Failed to discover public IP. STUN: \(stunError). DNS: \(dnsError)"
    }
  }
}

/// Discovers public IPv4 using a tiered fallback strategy:
/// 1. STUN (fastest, tries multiple servers)
/// 2. DNS whoami (reliable fallback, works behind captive portals)
///
/// - Parameters:
///   - stunTimeout: Timeout per STUN server (default 0.8s)
///   - dnsTimeout: Timeout for DNS query (default 2.0s)
///   - interface: Network interface to bind to (optional)
///   - sourceIP: Source IP address to bind to (optional)
///   - enableLogging: Enable debug logging
/// - Returns: Public IP from first successful method
/// - Throws: PublicIPError if all methods fail
func getPublicIPv4(
  stunTimeout: TimeInterval = 0.8,
  dnsTimeout: TimeInterval = 2.0,
  interface: String? = nil,
  sourceIP: String? = nil,
  enableLogging: Bool = false
) throws -> STUNPublicIP {
  // Tier 1: Try STUN (fastest)
  var stunErrorMsg = "Unknown error"
  do {
    return try stunGetPublicIPv4WithFallback(
      timeout: stunTimeout,
      interface: interface,
      sourceIP: sourceIP,
      enableLogging: enableLogging
    )
  } catch {
    stunErrorMsg = String(describing: error)
    if enableLogging {
      print("[PublicIP] STUN failed, trying DNS fallback...")
    }
  }

  // Tier 2: Try DNS whoami (last resort fallback)
  // WARNING: On carrier networks with CGNAT, DNS traffic exits through a different
  // NAT pool than HTTP/STUN traffic. The Akamai whoami TXT record returns the IP
  // visible to the recursive DNS resolver, not the actual exit IP that websites see.
  // For example, T-Mobile returns 172.32.0.x via DNS but 172.56.x.x via STUN/HTTP.
  // This fallback is only useful when STUN is completely blocked (e.g., UDP-filtered
  // enterprise networks). Callers should prefer HTTP-based IP discovery when available.
  var dnsErrorMsg = "Unknown error"
  do {
    return try getPublicIPv4ViaDNS(
      timeout: dnsTimeout,
      enableLogging: enableLogging
    )
  } catch {
    dnsErrorMsg = String(describing: error)
    if enableLogging {
      print("[PublicIP] DNS fallback also failed")
    }
  }

  throw PublicIPError.allMethodsFailed(stunError: stunErrorMsg, dnsError: dnsErrorMsg)
}

/// Discovers both v4 and v6 public IPs in parallel via STUN. Returns whatever
/// succeeded — either or both fields of `PublicIPs` may be nil. Never throws:
/// callers see "no IP discovered" as `PublicIPs(v4: nil, v6: nil)` rather than
/// having to handle exceptions for the common "this network is v4-only" or
/// "this network is v6-only" cases.
///
/// Each family-specific sweep walks the same STUN server list (`stunServers`)
/// using `stunGetPublicIPWithFallback`. The DNS whoami fallback used by the
/// older `getPublicIPv4` is NOT run here for v6 because Akamai's whoami service
/// returns only v4. v6 discovery is STUN-only.
///
/// - Parameters:
///   - stunTimeout: Per-server timeout (default 0.8s).
///   - interface: Optional interface to bind to (applied to both families).
///   - sourceIP: Optional source IP. If v4, only the v4 STUN sweep gets it;
///               if v6, only the v6 sweep. (Cross-family bind would fail.)
///   - enableLogging: Verbose logging.
public func getPublicIPs(
  stunTimeout: TimeInterval = 0.8,
  interface: String? = nil,
  sourceIP: String? = nil,
  enableLogging: Bool = false
) async -> PublicIPs {
  // Detect family of sourceIP (if provided) so we only pass it to the matching sweep.
  let sourceFamily = sourceIP.map { detectAddressFamily($0) } ?? -1
  let v4Source = (sourceFamily == AF_INET) ? sourceIP : nil
  let v6Source = (sourceFamily == AF_INET6) ? sourceIP : nil

  async let v4Task: String? = Task {
    do {
      let r = try stunGetPublicIPWithFallback(
        family: AF_INET, timeout: stunTimeout, interface: interface,
        sourceIP: v4Source, enableLogging: enableLogging)
      return r.ip
    } catch {
      if enableLogging { print("[STUN] v4 sweep failed: \(error)") }
      return nil
    }
  }.value

  async let v6Task: String? = Task {
    do {
      let r = try stunGetPublicIPWithFallback(
        family: AF_INET6, timeout: stunTimeout, interface: interface,
        sourceIP: v6Source, enableLogging: enableLogging)
      return r.ip
    } catch {
      if enableLogging { print("[STUN] v6 sweep failed: \(error)") }
      return nil
    }
  }.value

  let (v4, v6) = await (v4Task, v6Task)
  return PublicIPs(v4: v4, v6: v6)
}
