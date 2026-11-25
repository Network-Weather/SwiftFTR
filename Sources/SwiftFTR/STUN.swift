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
  /// The server's host or the network answered the request with an error: `ECONNREFUSED` (nothing
  /// listening), `EHOSTUNREACH`, `ENETUNREACH`, or another receive error.
  case receiveFailed(errno: Int32, details: String?)
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
    case .receiveFailed(let errno, let details):
      let errStr = String(cString: strerror(errno))
      let baseMsg = "STUN request failed (errno=\(errno)): \(errStr)"
      return details.map { "\(baseMsg). \($0)" } ?? baseMsg
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
/// uses it. Whichever of that attempt and the end of the sweep comes first closes the descriptor:
/// an attempt that takes it hands it to its exchange, which closes it, and a socket no attempt
/// took (its lookup failed or was abandoned, or the sweep ended first) is closed by the sweep on
/// its way out, or by `deinit`.
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

/// Queries one STUN server at an already-resolved endpoint, from a new socket bound to
/// `interface` and `sourceIP` where given.
internal func stunGetPublicIP(
  family: Int32,
  server: sockaddr_storage,
  serverLen: socklen_t,
  serverLabel: String,
  timeout: TimeInterval = 1.0,
  interface: String? = nil,
  sourceIP: String? = nil,
  enableLogging: Bool = false
) async throws -> STUNPublicIP {
  guard timeout.isFinite, timeout > 0, timeout <= TimeInterval(Int32.max) else {
    throw STUNError.invalidTimeout(timeout)
  }
  try Task.checkCancellation()
  let fd = try makeBoundSTUNSocket(
    family: family, interface: interface, sourceIP: sourceIP, enableLogging: enableLogging)
  return try await stunExchange(
    fd: fd, family: family, server: server, serverLen: serverLen, serverLabel: serverLabel,
    timeout: timeout)
}

/// A STUN Binding Request (RFC 5389 §6) with a fresh random transaction ID, and that ID.
func makeSTUNBindingRequest() -> (request: [UInt8], transactionID: [UInt8]) {
  let transactionID = (0..<12).map { _ in UInt8.random(in: 0...255) }
  // Type 0x0001 (Binding Request), length 0, then the magic cookie 0x2112A442.
  return ([0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42] + transactionID, transactionID)
}

/// Whether `datagram` is a STUN message answering the request that carried `transactionID`: a
/// whole 20-byte header with the magic cookie and that transaction ID. Anything else (empty, too
/// short, another cookie, another ID) is not addressed to this request.
func isSTUNReply(_ datagram: ArraySlice<UInt8>, to transactionID: [UInt8]) -> Bool {
  let bytes = Array(datagram)
  return bytes.count >= 20 && bytes[4..<8] == [0x21, 0x12, 0xA4, 0x42]
    && Array(bytes[8..<20]) == transactionID
}

/// One STUN Binding exchange on `fd`, a socket already bound by ``makeBoundSTUNSocket(family:interface:sourceIP:enableLogging:)``
/// and not yet sent on: connect it to `server`, send the request with `send` (the system call by
/// default), and parse the reply. Holds no thread: the exchange is a ``UDPExchange``.
///
/// A datagram that is not a STUN reply to this request (``isSTUNReply(_:to:)``) is ignored and the
/// wait goes on to the same deadline, `timeout` seconds from now. One that does carry the
/// transaction ID but is otherwise invalid fails the exchange with
/// ``STUNError/invalidResponse(_:)``. A refusal or unreachable report ends it at once. `cutoff`,
/// when given, is an instant on `monotonicNow()`'s clock that the exchange never runs past, its
/// setup included.
///
/// Takes ownership of `fd` and closes it exactly once, whatever the outcome.
///
/// - Throws: ``STUNError``, or `CancellationError` when the calling task is cancelled.
internal func stunExchange(
  fd: Int32,
  family: Int32,
  server: sockaddr_storage,
  serverLen: socklen_t,
  serverLabel: String,
  timeout: TimeInterval,
  cutoff: TimeInterval? = nil,
  send: TestSeams.SendDatagram? = nil
) async throws -> STUNPublicIP {
  guard timeout.isFinite, timeout > 0, timeout <= TimeInterval(Int32.max) else {
    close(fd)
    throw STUNError.invalidTimeout(timeout)
  }
  let (request, transactionID) = makeSTUNBindingRequest()
  // Connected, so the kernel delivers only the server's datagrams to this socket.
  let connectToServer: (Int32) throws -> Void = { fd in
    var server = server
    let connected = withUnsafePointer(to: &server) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, serverLen) }
    }
    guard connected == 0 else {
      throw STUNError.connectFailed(errno: errno, details: "Failed to connect to \(serverLabel)")
    }
  }
  let reply: UDPExchangeReply
  do {
    reply = try await UDPExchange.perform(
      adopting: fd, request: request, timeout: timeout, cutoff: cutoff, receiveCapacity: 512,
      accepts: { isSTUNReply($0, to: transactionID) },
      send: send ?? { fd, bytes in Darwin.send(fd, bytes.baseAddress, bytes.count, 0) },
      configure: connectToServer)
  } catch let failure as UDPExchangeFailure {
    throw STUNError(failure, serverLabel: serverLabel)
  }
  return try parseSTUNBindingResponse(
    reply.bytes, transactionID: transactionID, expectedFamily: family)
}

extension STUNError {
  /// The STUN meaning of a transport failure in an exchange with `serverLabel`.
  init(_ failure: UDPExchangeFailure, serverLabel: String) {
    switch failure {
    case .socketCreationFailed(let code):
      self = .socketFailed(errno: code, details: nil)
    case .nonBlockingFailed(let code):
      self = .socketFailed(errno: code, details: "Failed to make the STUN socket non-blocking")
    case .sendFailed(let code):
      self = .sendFailed(
        errno: code ?? 0, details: "Failed to send STUN request to \(serverLabel)")
    case .refused:
      self = .receiveFailed(errno: ECONNREFUSED, details: "\(serverLabel) refused the request")
    case .unreachable(let code, _), .receiveFailed(let code):
      self = .receiveFailed(errno: code, details: "No reply from \(serverLabel)")
    case .timedOut:
      self = .recvTimeout
    }
  }
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
/// so a failed bind sends nothing, the lookup included. The lookup is waited for as a sweep's is
/// (``stunNameLookupLimit``).
internal func stunGetPublicIP(
  family: Int32,
  host: String,
  port: UInt16,
  timeout: TimeInterval = 1.0,
  interface: String? = nil,
  sourceIP: String? = nil,
  enableLogging: Bool = false
) async throws -> STUNPublicIP {
  guard timeout.isFinite, timeout > 0, timeout <= TimeInterval(Int32.max) else {
    throw STUNError.invalidTimeout(timeout)
  }
  try Task.checkCancellation()
  let socket = try BoundSTUNSocket(
    family: family, interface: interface, sourceIP: sourceIP, enableLogging: enableLogging)
  return try await stunAttempt(
    (host, port), socket: socket, family: family, timeout: timeout, deadline: nil,
    resolve: TestSeams.resolveSTUNServer ?? resolveSTUNServer, send: TestSeams.sendSTUNRequest,
    enableLogging: enableLogging
  ).get()
}

/// Back-compat wrapper for v4-only callers; delegates to the family-parameterized
/// `stunGetPublicIP`.
func stunGetPublicIPv4(
  host: String = "stun.l.google.com", port: UInt16 = 19302, timeout: TimeInterval = 1.0,
  interface: String? = nil, sourceIP: String? = nil, enableLogging: Bool = false
) async throws -> STUNPublicIP {
  try await stunGetPublicIP(
    family: AF_INET, host: host, port: port, timeout: timeout,
    interface: interface, sourceIP: sourceIP, enableLogging: enableLogging)
}

/// v6 companion to `stunGetPublicIPv4`. Forces the resolver and socket to v6.
func stunGetPublicIPv6(
  host: String = "stun.cloudflare.com", port: UInt16 = 3478, timeout: TimeInterval = 1.0,
  interface: String? = nil, sourceIP: String? = nil, enableLogging: Bool = false
) async throws -> STUNPublicIP {
  try await stunGetPublicIP(
    family: AF_INET6, host: host, port: port, timeout: timeout,
    interface: interface, sourceIP: sourceIP, enableLogging: enableLogging)
}

// MARK: - Concurrent STUN sweep

/// The longest a STUN server's name lookup is waited for when the sweep has no deadline of its
/// own, as in ``getPublicIPs(stunTimeout:interface:sourceIP:enableLogging:)``: the forward-
/// resolution budget a trace gets by default (docs/BLOCKING-IO.md, decision 7). A sweep with a
/// deadline waits for the earlier of the two. The `getaddrinfo` itself runs on in its executor
/// slot when the wait ends.
let stunNameLookupLimit: TimeInterval = 20

/// Seconds from now until `deadline`, an instant on `monotonicNow()`'s clock, and never less than
/// zero (a deadline that is not a number has passed); `nil` when there is no deadline.
func secondsLeft(until deadline: TimeInterval?) -> TimeInterval? {
  deadline.map { $0.isNaN ? 0 : max($0 - monotonicNow(), 0) }
}

/// The endpoint for a numeric `host` of `family`, built without the resolver, or `nil` when
/// `host` is not such a literal.
private func literalSTUNEndpoint(host: String, port: UInt16, family: Int32) -> (
  server: sockaddr_storage, serverLen: socklen_t
)? {
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
  return (storage, length)
}

/// `server`'s name resolved for `family` on the executor, or `nil` when the lookup failed or its
/// wait ended first. With no time left before `deadline`, nothing is submitted.
///
/// - Throws: `CancellationError` when the calling task is cancelled.
func lookUpSTUNServer(
  _ server: (host: String, port: UInt16), family: Int32, deadline: TimeInterval?,
  resolve: @escaping TestSeams.ResolveSTUNServer
) async throws -> (server: sockaddr_storage, serverLen: socklen_t)? {
  let wait = min(secondsLeft(until: deadline) ?? stunNameLookupLimit, stunNameLookupLimit)
  // No time left: nothing is submitted, so no lookup starts after the deadline.
  guard wait > 0 else { return nil }
  do {
    return try await runDetachedBlockingIO(deadline: wait) {
      // A worker can pick this up as the deadline passes, before its timer has withdrawn it.
      if let deadline, !(monotonicNow() < deadline) { return nil }
      return resolve(server.host, server.port, family)
    }
  } catch is BlockingIOTimeout {
    return nil
  }
}

/// One server's attempt in a sweep: its name resolved (a numeric address needs no lookup), then
/// one exchange from `socket`. Never throws; the outcome is returned.
///
/// The wait on the lookup ends at the earlier of `deadline` and ``stunNameLookupLimit``, and at
/// once when the calling task is cancelled; `getaddrinfo` runs on in its executor slot. The
/// exchange ends at the earlier of `timeout` and `deadline`, and an attempt with no time left
/// sends nothing.
private func stunAttempt(
  _ server: (host: String, port: UInt16),
  socket: BoundSTUNSocket,
  family: Int32,
  timeout: TimeInterval,
  deadline: TimeInterval?,
  resolve: @escaping TestSeams.ResolveSTUNServer,
  send: TestSeams.SendDatagram?,
  enableLogging: Bool
) async -> Result<STUNPublicIP, Error> {
  let label = "\(server.host):\(server.port)"
  let famName = family == AF_INET6 ? "v6" : "v4"
  do {
    try Task.checkCancellation()
    let endpoint: (server: sockaddr_storage, serverLen: socklen_t)
    if let literal = literalSTUNEndpoint(host: server.host, port: server.port, family: family) {
      endpoint = literal
    } else {
      let resolved = try await lookUpSTUNServer(
        server, family: family, deadline: deadline, resolve: resolve)
      guard let resolved else {
        throw STUNError.resolveFailed(
          errno: 0, details: "Failed to resolve STUN server '\(label)' (\(famName))")
      }
      endpoint = resolved
    }
    if enableLogging { print("[STUN] Trying \(label) (\(famName))...") }
    // The deadline goes to the exchange as an instant, so its setup cannot push it later.
    guard secondsLeft(until: deadline) ?? 1 > 0, let fd = socket.take() else {
      throw STUNError.recvTimeout
    }
    let found = try await stunExchange(
      fd: fd, family: family, server: endpoint.server, serverLen: endpoint.serverLen,
      serverLabel: label, timeout: timeout, cutoff: deadline, send: send)
    if enableLogging { print("[STUN] Success from \(label) (\(famName)) -> \(found.ip)") }
    return .success(found)
  } catch {
    if enableLogging { print("[STUN] Failed \(label) (\(famName)): \(error)") }
    return .failure(error)
  }
}

/// Suspends until `deadline`, an instant on `clock` (`monotonicNow()`'s, which counts system
/// sleep), has passed, or until the task is cancelled. It sleeps on the continuous clock, which
/// also counts system sleep, and checks `clock` again on every wake, so it never ends early.
func sleep(
  untilMonotonic deadline: TimeInterval,
  clock: @Sendable () -> TimeInterval = monotonicNow
) async {
  while !Task.isCancelled {
    let left = deadline - clock()
    // Also a deadline that is not a number: it has passed.
    guard left > 0 else { return }
    try? await Task.sleep(until: .now + .seconds(min(left, 1e9)), clock: .continuous)
  }
}

/// Waits for a permit from `admission`, giving up at `deadline` (an instant on `monotonicNow()`'s
/// clock; `nil` waits for as long as it takes). A permit taken is the caller's to signal.
///
/// - Throws: ``STUNError/recvTimeout`` when the deadline passes first, `CancellationError` when
///   the calling task is cancelled. Neither leaves a permit taken.
private func admitSweep(_ admission: _ConcurrencySemaphore, deadline: TimeInterval?) async throws {
  guard let deadline else { return try await admission.wait() }
  enum Event { case admitted, gaveUp, deadline }
  let first = await withTaskGroup(of: Event.self) { group -> Event in
    group.addTask {
      do {
        try await admission.wait()
        return .admitted
      } catch {
        return .gaveUp
      }
    }
    group.addTask {
      await sleep(untilMonotonic: deadline)
      return .deadline
    }
    let first = await group.next() ?? .deadline
    group.cancelAll()
    // A permit the waiter took after the other child finished first is given back.
    for await other in group where other == .admitted && first != .admitted {
      await admission.signal()
    }
    return first
  }
  if first == .admitted, !Task.isCancelled { return }
  if first == .admitted { await admission.signal() }
  try Task.checkCancellation()
  throw STUNError.recvTimeout
}

/// Discovers the public IP of `family` by asking every STUN server at the same time.
///
/// One socket per server is created and bound to `interface` and `sourceIP` first, before any
/// name is resolved. If a bind fails the sweep throws that failure at once, having sent nothing
/// and looked up no name. The lookups use the system resolver, which is not bound.
///
/// Then each server's attempt starts at once and sends as soon as its name has resolved, holding
/// no thread while it waits for the reply. The first valid reply from any server is the answer
/// (David, 2026-11-24): it ends the sweep at once, and every other attempt is cancelled, its
/// socket closed. With no answer, the sweep ends when every attempt has failed, which is by
/// `deadline` at the latest, with no timer of its own. Cancelling the calling task ends it at
/// once.
///
/// Sweeps are admitted one per executor worker before they open sockets, so at most that many
/// sweeps hold `servers.count` sockets each.
///
/// - Parameters:
///   - family: `AF_INET` for v4 or `AF_INET6` for v6.
///   - timeout: Timeout for each server's exchange (default 1.0s), counted from its send.
///   - interface: Network interface to bind to (optional)
///   - sourceIP: Source IP address to bind to (optional)
///   - enableLogging: Enable debug logging
///   - deadline: When the whole sweep gives up, an instant on `monotonicNow()`'s clock, or `nil`
///     to leave each attempt only its own bounds.
/// - Returns: The first public IP a server reported.
/// - Throws: The last server's error in list order when none answered, whatever order they
///   failed in; ``STUNError/recvTimeout`` when the deadline passed before the sweep could start;
///   or `CancellationError`.
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
  let famName = family == AF_INET6 ? "v6" : "v4"

  // Admitted first, one sweep per executor worker, so a sweep waiting its turn holds no socket;
  // the wait ends at the deadline or with the caller's cancellation.
  try Task.checkCancellation()
  if let left = secondsLeft(until: deadline), left <= 0 { throw STUNError.recvTimeout }
  let admission = (TestSeams.blockingIOExecutor ?? blockingIOExecutor).stunSweepAdmission
  try await admitSweep(admission, deadline: deadline)
  defer { Task { await admission.signal() } }
  // Bound first: nothing is resolved or sent unless every socket could be bound.
  let sockets = try servers.map { _ in
    try BoundSTUNSocket(
      family: family, interface: interface, sourceIP: sourceIP, enableLogging: enableLogging)
  }
  // On the way out, close what no attempt took.
  defer { for socket in sockets { socket.take().map { _ = close($0) } } }
  if let left = secondsLeft(until: deadline), left <= 0 { throw STUNError.recvTimeout }
  // Read on the async side, where the task-local seams are visible.
  let send = TestSeams.sendSTUNRequest
  let resolve = TestSeams.resolveSTUNServer ?? resolveSTUNServer

  if enableLogging {
    print("[STUN] Asking \(servers.count) servers at once (\(famName))...")
  }
  var failures = [Error?](repeating: nil, count: servers.count)
  let first = await withTaskGroup(of: (Int, Result<STUNPublicIP, Error>).self) {
    group -> STUNPublicIP? in
    for (index, server) in servers.enumerated() {
      let socket = sockets[index]
      group.addTask {
        let outcome = await stunAttempt(
          server, socket: socket, family: family, timeout: timeout, deadline: deadline,
          resolve: resolve, send: send, enableLogging: enableLogging)
        return (index, outcome)
      }
    }
    for await (index, outcome) in group {
      switch outcome {
      case .success(let found):
        // The first answer is decisive: the other attempts are cancelled, not consulted.
        group.cancelAll()
        return found
      case .failure(let error):
        failures[index] = error
      }
    }
    return nil
  }
  try Task.checkCancellation()
  if let first { return first }
  throw failures.last(where: { $0 != nil }).flatMap { $0 } ?? STUNError.recvTimeout
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
/// only, every socket bound before anything is sent, every server asked at once, and the first
/// address any server reports is the family's answer. Unlike a trace's question, there is no overall deadline and the address is reported as the STUN servers
/// gave it, whether or not it is globally routable.
///
/// The two sweeps are child tasks of the caller's. Cancelling the calling task ends both at once,
/// and the call returns what had been found by then. Each server's exchange is bounded by
/// `stunTimeout`, and the wait on each server's name lookup by 20 s.
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
