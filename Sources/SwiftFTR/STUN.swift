import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// Public IP discovered via a STUN Binding request. The `ip` string is in
/// canonical `inet_ntop` form for v4 (`x.x.x.x`) or v6 (for example,
/// `2001:4860:4860::8888`).
struct STUNPublicIP: Sendable {
  let ip: String
  /// Address family of the discovered IP. `AF_INET` (2) or `AF_INET6` (30 on Darwin).
  let family: Int32

  init(ip: String, family: Int32 = AF_INET) {
    self.ip = ip
    self.family = family
  }
}

/// Public IPs discovered across both v4 and v6 in a single sweep. Either field
/// may be nil if that family's STUN sweep didn't succeed. Downstream
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
/// Uses multiple independent providers on distinct networks for genuine redundancy.
/// Cloudflare and Google's STUN servers resolve to both v4 and v6 records; the family
/// preference passed to the resolver determines which is used.
let stunServers: [(host: String, port: UInt16)] = [
  ("stun.l.google.com", 19302),  // Google (port 19302)
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

/// Resolves a STUN server host and port for the given family.
internal func resolveSTUNServer(
  host: String,
  port: UInt16,
  family: Int32
) -> (server: sockaddr_storage, serverLen: socklen_t)? {
  var hints = addrinfo(
    ai_flags: AI_ADDRCONFIG, ai_family: family, ai_socktype: SOCK_DGRAM,
    ai_protocol: IPPROTO_UDP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
  var res: UnsafeMutablePointer<addrinfo>? = nil
  let resolveResult = getaddrinfo(host, String(port), &hints, &res)
  guard resolveResult == 0, let info = res, let sa = info.pointee.ai_addr else {
    return nil
  }
  defer { freeaddrinfo(info) }

  var server = sockaddr_storage()
  let serverLen = socklen_t(min(MemoryLayout<sockaddr_storage>.size, Int(info.pointee.ai_addrlen)))
  _ = withUnsafeMutablePointer(to: &server) { dst in
    memcpy(dst, sa, Int(serverLen))
  }
  return (server, serverLen)
}

/// A UDP socket of `family` bound to `interface` and `sourceIP`, where given, for one STUN
/// exchange. Nothing has been sent on it. The caller owns the descriptor.
///
/// This comes before the server's name is resolved, so a bind that fails ends the attempt before
/// any traffic, the lookup included.
internal func makeBoundSTUNSocket(
  family: Int32, interface: String?, sourceIP: String?, enableLogging: Bool
) throws -> Int32 {
  let fd = socket(family, SOCK_DGRAM, IPPROTO_UDP)
  if fd < 0 {
    let error = errno
    throw STUNError.socketFailed(
      errno: error,
      details: "Unable to create UDP socket for STUN. May indicate system resource limits.")
  }
  do {
    try bindSTUNSocket(
      fd, family: family, interface: interface, sourceIP: sourceIP, enableLogging: enableLogging)
    return fd
  } catch {
    close(fd)
    throw error
  }
}

private func bindSTUNSocket(
  _ fd: Int32, family: Int32, interface: String?, sourceIP: String?, enableLogging: Bool
) throws {
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
}

/// A bound STUN socket made before its server's name is resolved, handed to the one attempt that
/// uses it. Whichever of that attempt and the last reference to this object comes first closes
/// the descriptor: an attempt that takes it closes it when done, and an attempt that never runs
/// (abandoned while queued, or never started because the sweep ended) leaves it to `deinit`.
final class BoundSTUNSocket: @unchecked Sendable {
  private let lock = NSLock()
  private var descriptor: Int32

  init(family: Int32, interface: String?, sourceIP: String?, enableLogging: Bool) throws {
    descriptor = try makeBoundSTUNSocket(
      family: family, interface: interface, sourceIP: sourceIP, enableLogging: enableLogging)
  }

  /// The descriptor, which the caller now owns and must close; `nil` if it was taken before.
  func take() -> Int32? {
    lock.withLock {
      let fd = descriptor
      descriptor = -1
      return fd >= 0 ? fd : nil
    }
  }

  deinit {
    if descriptor >= 0 { close(descriptor) }
  }
}

/// Family-parameterized STUN core with pre-resolved endpoint. Builds the binding request,
/// sends it, and parses the XOR-MAPPED-ADDRESS attribute. Supports both AF_INET and AF_INET6.
internal func stunGetPublicIP(
  family: Int32,
  server: sockaddr_storage,
  serverLen: socklen_t,
  serverLabel: String,
  timeout: TimeInterval = 1.0,
  interface: String? = nil,
  sourceIP: String? = nil,
  enableLogging: Bool = false
) throws -> STUNPublicIP {
  guard timeout.isFinite, timeout > 0, timeout <= TimeInterval(Int32.max) else {
    throw STUNError.invalidTimeout(timeout)
  }
  let fd = try makeBoundSTUNSocket(
    family: family, interface: interface, sourceIP: sourceIP, enableLogging: enableLogging)
  defer { close(fd) }
  return try stunExchange(
    fd: fd, family: family, server: server, serverLen: serverLen, serverLabel: serverLabel,
    timeout: timeout)
}

/// One STUN Binding exchange on `fd`, a socket already bound by ``makeBoundSTUNSocket(family:interface:sourceIP:enableLogging:)``:
/// connect to `server`, send the request with `send` (the system call by default), and parse the
/// reply. Blocks for up to `timeout` on each of the send and the receive. Does not close `fd`.
internal func stunExchange(
  fd: Int32,
  family: Int32,
  server: sockaddr_storage,
  serverLen: socklen_t,
  serverLabel: String,
  timeout: TimeInterval,
  send: TestSeams.SendDatagram? = nil
) throws -> STUNPublicIP {
  guard timeout.isFinite, timeout > 0, timeout <= TimeInterval(Int32.max) else {
    throw STUNError.invalidTimeout(timeout)
  }
  var server = server

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
      errno: error, details: "Failed to connect to \(serverLabel)")
  }

  // Set timeouts. A zero timeval disables SO_RCVTIMEO, so invalid values are
  // rejected above and option failures are surfaced rather than ignored.
  // A positive timeout that rounds down to zero microseconds must still be a timeout.
  var tv = timeval(
    tv_sec: Int(timeout), tv_usec: __darwin_suseconds_t((timeout - floor(timeout)) * 1_000_000))
  if tv.tv_sec == 0, tv.tv_usec == 0 { tv.tv_usec = 1 }
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
    send?(fd, raw) ?? Darwin.send(fd, raw.baseAddress!, raw.count, 0)
  }
  if sent < 0 {
    let error = errno
    throw STUNError.sendFailed(
      errno: error, details: "Failed to send STUN request to \(serverLabel)")
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

/// Queries a STUN server by hostname and port. The socket is bound before the name is resolved,
/// so a failed bind sends nothing, the lookup included.
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
  let fd = try makeBoundSTUNSocket(
    family: family, interface: interface, sourceIP: sourceIP, enableLogging: enableLogging)
  defer { close(fd) }
  guard let (server, serverLen) = resolveSTUNServer(host: host, port: port, family: family) else {
    let error = errno
    let famName = family == AF_INET6 ? "v6" : "v4"
    throw STUNError.resolveFailed(
      errno: error,
      details: "Failed to resolve STUN server '\(host):\(port)' (\(famName))")
  }
  return try stunExchange(
    fd: fd, family: family, server: server, serverLen: serverLen,
    serverLabel: "\(host):\(port)", timeout: timeout)
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

/// A STUN server whose name has been resolved for one address family.
private struct STUNEndpoint: Sendable {
  let host: String
  let port: UInt16
  let server: sockaddr_storage
  let serverLen: socklen_t
}

/// How long the executor waits for one STUN attempt with per-server `timeout`, counted from
/// submission: twice `timeout`.
///
/// A running attempt is bounded by its socket's own send and receive timeouts, each `timeout`.
/// This deadline is the backstop for both together, and it also bounds the wait for a free
/// executor slot. A stalled attempt keeps its slot until its `recv` returns, but the sweep moves
/// on at this deadline.
func stunAttemptDeadline(_ timeout: TimeInterval) -> TimeInterval { 2 * timeout }

/// Seconds from now until `deadline`, an instant on `monotonicNow()`'s clock, and never less than
/// zero; `nil` when there is no deadline.
func secondsLeft(until deadline: TimeInterval?) -> TimeInterval? {
  deadline.map { max($0 - monotonicNow(), 0) }
}

/// The endpoint for a numeric `host` of `family`, built without the resolver, or `nil` when
/// `host` is not such a literal.
private func literalSTUNEndpoint(host: String, port: UInt16, family: Int32) -> STUNEndpoint? {
  var storage = sockaddr_storage()
  let length: socklen_t
  if family == AF_INET6 {
    var sin6 = sockaddr_in6()
    guard inet_pton(AF_INET6, host, &sin6.sin6_addr) == 1 else { return nil }
    sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    sin6.sin6_family = sa_family_t(AF_INET6)
    sin6.sin6_port = port.bigEndian
    withUnsafeMutableBytes(of: &storage) { dst in
      withUnsafeBytes(of: sin6) { dst.copyMemory(from: $0) }
    }
    length = socklen_t(MemoryLayout<sockaddr_in6>.size)
  } else {
    var sin = sockaddr_in()
    guard inet_pton(AF_INET, host, &sin.sin_addr) == 1 else { return nil }
    sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    sin.sin_family = sa_family_t(AF_INET)
    sin.sin_port = port.bigEndian
    withUnsafeMutableBytes(of: &storage) { dst in
      withUnsafeBytes(of: sin) { dst.copyMemory(from: $0) }
    }
    length = socklen_t(MemoryLayout<sockaddr_in>.size)
  }
  return STUNEndpoint(host: host, port: port, server: storage, serverLen: length)
}

/// Resolves every server in `servers` for `family` at once, each name as its own executor
/// request, and returns the endpoints in list order once every lookup has ended, `nil` where
/// resolution failed. A numeric address needs no resolver and no executor slot.
///
/// Each lookup is abandoned at `deadline`, an instant on `monotonicNow()`'s clock, and counts as
/// failed; its `getaddrinfo` runs on in its executor slot. With no deadline a lookup is waited for
/// as long as it takes, but cancelling the calling task still ends the wait at once.
///
/// - Throws: `CancellationError` when the calling task is cancelled.
private func resolveSTUNEndpoints(
  _ servers: [(host: String, port: UInt16)], family: Int32, deadline: TimeInterval?
) async throws -> [STUNEndpoint?] {
  try await withThrowingTaskGroup(of: (Int, STUNEndpoint?).self) { group in
    for (index, server) in servers.enumerated() {
      group.addTask {
        if let literal = literalSTUNEndpoint(host: server.host, port: server.port, family: family) {
          return (index, literal)
        }
        let resolve = TestSeams.resolveSTUNServer ?? resolveSTUNServer
        do {
          let resolved = try await runDetachedBlockingIO(deadline: secondsLeft(until: deadline)) {
            resolve(server.host, server.port, family).map {
              STUNEndpoint(
                host: server.host, port: server.port, server: $0.server, serverLen: $0.serverLen)
            }
          }
          return (index, resolved)
        } catch is BlockingIOTimeout {
          return (index, nil)
        }
      }
    }
    var endpoints = [STUNEndpoint?](repeating: nil, count: servers.count)
    for try await (index, endpoint) in group { endpoints[index] = endpoint }
    return endpoints
  }
}

/// Attempts to discover the public IP of a given family by trying multiple STUN servers in
/// sequence, after resolving all their names at once. Falls back through the server list until
/// one succeeds.
///
/// One socket per server is created and bound to `interface` and `sourceIP` first, before any
/// name is resolved. If a bind fails the sweep throws that failure at once, having sent nothing
/// and looked up no name. The lookups use the system resolver, which is not bound.
///
/// Each attempt is a blocking exchange submitted to the executor on its own, under
/// ``stunAttemptDeadline(_:)``, so the sweep waits on no thread, and cancelling the calling task
/// ends it at once.
///
/// `deadline`, an instant on `monotonicNow()`'s clock, bounds the whole sweep: name lookups and
/// every attempt are abandoned when it passes, and no attempt starts after it. `nil` leaves only
/// the per-server bound.
///
/// - Parameters:
///   - family: `AF_INET` for v4 or `AF_INET6` for v6.
///   - timeout: Timeout per server attempt (default 1.0s)
///   - interface: Network interface to bind to (optional)
///   - sourceIP: Source IP address to bind to (optional)
///   - enableLogging: Enable debug logging
///   - deadline: When the whole sweep gives up, or `nil`
/// - Returns: Public IP if any server responds
/// - Throws: The last attempt's error if all servers fail (`STUNError.recvTimeout` for an attempt
///   that outlived its deadline), or `CancellationError`.
internal func stunGetPublicIPWithFallback(
  family: Int32,
  timeout: TimeInterval = 1.0,
  interface: String? = nil,
  sourceIP: String? = nil,
  enableLogging: Bool = false,
  deadline: TimeInterval? = nil
) async throws -> STUNPublicIP {
  guard timeout.isFinite, timeout > 0, timeout <= TimeInterval(Int32.max) else {
    throw STUNError.invalidTimeout(timeout)
  }

  let servers = TestSeams.stunServers?(family) ?? stunServers
  var lastError: Error = STUNError.recvTimeout
  let famName = family == AF_INET6 ? "v6" : "v4"

  // Admitted first, one sweep per executor worker, so a sweep waiting its turn holds no socket;
  // the wait ends with the caller's cancellation (a discovery's deadline cancels it too).
  try Task.checkCancellation()
  let admission = (TestSeams.blockingIOExecutor ?? blockingIOExecutor).stunSweepAdmission
  try await admission.wait()
  defer { Task { await admission.signal() } }
  // Bound first: nothing is resolved or sent unless every socket could be bound.
  let sockets = try servers.map { _ in
    try BoundSTUNSocket(
      family: family, interface: interface, sourceIP: sourceIP, enableLogging: enableLogging)
  }
  let send = TestSeams.sendSTUNRequest

  if enableLogging {
    print("[STUN] Resolving \(servers.count) servers concurrently (\(famName))...")
  }
  let endpoints = try await resolveSTUNEndpoints(servers, family: family, deadline: deadline)

  for (index, resolved) in endpoints.enumerated() {
    try Task.checkCancellation()
    var attemptDeadline = stunAttemptDeadline(timeout)
    if let left = secondsLeft(until: deadline) {
      guard left > 0 else {
        if enableLogging { print("[STUN] Discovery deadline passed (\(famName))") }
        lastError = STUNError.recvTimeout
        break
      }
      attemptDeadline = min(attemptDeadline, left)
    }
    guard let endpoint = resolved else {
      let (host, port) = servers[index]
      if enableLogging {
        print("[STUN] Resolution failed for \(host):\(port) (\(famName))")
      }
      lastError = STUNError.resolveFailed(
        errno: 0,
        details: "Failed to resolve STUN server '\(host):\(port)' (\(famName))")
      continue
    }

    let label = "\(endpoint.host):\(endpoint.port)"
    if enableLogging {
      print("[STUN] Trying \(label) (\(famName))...")
    }
    do {
      let socket = sockets[index]
      let result = try await runDetachedBlockingIO(deadline: attemptDeadline) {
        guard let fd = socket.take() else { throw STUNError.recvTimeout }
        defer { close(fd) }
        return try stunExchange(
          fd: fd, family: family, server: endpoint.server, serverLen: endpoint.serverLen,
          serverLabel: label, timeout: timeout, send: send)
      }
      if enableLogging {
        print("[STUN] Success from \(label) (\(famName)) -> \(result.ip)")
      }
      return result
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if enableLogging {
        print("[STUN] Failed \(label) (\(famName)): \(error)")
      }
      lastError = error is BlockingIOTimeout ? STUNError.recvTimeout : error
    }
  }

  throw lastError
}

// MARK: - Unified Public IP Discovery

/// Why ``SwiftFTR/discoverPublicIPWithHostname()`` found no public address.
public enum PublicIPError: Error, CustomStringConvertible, Sendable {
  /// ``SwiftFTRConfig/publicIPResolver`` is ``PublicIPResolverStrategy/disabled``, so nothing was
  /// asked and nothing sent.
  case discoveryDisabled
  /// The strategy gave no globally routable IPv4 address before
  /// ``SwiftFTRConfig/publicIPDiscoveryTimeout`` passed. `reason` says what happened instead, for
  /// a log: STUN's failure, the resolver's own error, no answer in time, or an answer refused.
  case noAddress(reason: String)

  public var description: String {
    switch self {
    case .discoveryDisabled:
      return "Public-IP discovery is disabled (publicIPResolver is .disabled)"
    case .noAddress(let reason):
      return "No public IP address found: \(reason)"
    }
  }
}

/// Gives up on public-IP discovery that outlived its budget.
struct PublicIPDiscoveryTimeout: Error, CustomStringConvertible {
  var description: String { "no STUN answer before the discovery deadline" }
}

/// The outcome of a budgeted public-IP discovery whose first finished child gave `result`,
/// decided at `now` against `deadline`.
///
/// Cancellation of the calling task comes first. Then a failure once `deadline` has passed is
/// reported as ``PublicIPDiscoveryTimeout``, whichever timer noticed first, so a discovery that ran
/// out of time is always told apart from one that got definite failures in time. An address
/// that was found is returned.
func publicIPDiscoveryOutcome<Found>(
  _ result: Result<Found, Error>, now: TimeInterval, deadline: TimeInterval,
  cancelled: Bool
) throws -> Found {
  if cancelled { throw CancellationError() }
  switch result {
  case .success(let address):
    return address
  case .failure(let error):
    if now >= deadline { throw PublicIPDiscoveryTimeout() }
    throw error
  }
}

/// Discovers both v4 and v6 public IPs in parallel via STUN. Returns whatever
/// succeeded — either or both fields of `PublicIPs` may be nil. Never throws:
/// callers see "no IP discovered" as `PublicIPs(v4: nil, v6: nil)` rather than
/// having to handle exceptions for the common "this network is v4-only" or
/// "this network is v6-only" cases.
///
/// Each family asks the library's own resolver, the one a classified trace uses by default: STUN
/// only, every socket bound before anything is sent. Unlike a trace's question, there is no
/// overall deadline and the address is reported as the STUN server gave it, whether or not it is
/// globally routable.
///
/// The two sweeps are child tasks of the caller's. Cancelling the calling task ends both at once,
/// and the call returns what had been found by then. Each server attempt is bounded by
/// `stunTimeout`; resolving the server names has no deadline of its own.
///
/// - Parameters:
///   - stunTimeout: Per-server timeout (default 0.8s).
///   - interface: Optional interface to bind to (applied to both families).
///   - sourceIP: Optional source IP. Only the sweep of its own family runs, bound to it; the
///               other family sends nothing and is `nil`. A value that is not an IP address
///               sends nothing for either family.
///   - enableLogging: Verbose logging.
public func getPublicIPs(
  stunTimeout: TimeInterval = 0.8,
  interface: String? = nil,
  sourceIP: String? = nil,
  enableLogging: Bool = false
) async -> PublicIPs {
  async let v4 = stunSweepAddress(
    family: AF_INET, timeout: stunTimeout, interface: interface, sourceIP: sourceIP,
    enableLogging: enableLogging)
  async let v6 = stunSweepAddress(
    family: AF_INET6, timeout: stunTimeout, interface: interface, sourceIP: sourceIP,
    enableLogging: enableLogging)
  return await PublicIPs(v4: v4, v6: v6)
}

/// One family's question to the library's resolver for
/// ``getPublicIPs(stunTimeout:interface:sourceIP:enableLogging:)``, with no overall deadline: the
/// address, or `nil` if there was none or the call was cancelled.
private func stunSweepAddress(
  family: Int32, timeout: TimeInterval, interface: String?, sourceIP: String?,
  enableLogging: Bool
) async -> String? {
  do {
    return try await publicIPDiscovery(
      family: family == AF_INET6 ? .v6 : .v4, stunTimeout: timeout, interface: interface,
      sourceIP: sourceIP, enableLogging: enableLogging, budget: .infinity
    )?.address
  } catch {
    if enableLogging {
      print("[STUN] \(family == AF_INET6 ? "v6" : "v4") sweep failed: \(error)")
    }
    return nil
  }
}
