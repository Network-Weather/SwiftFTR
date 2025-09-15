import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// Public IPv4 discovered via a STUN Binding request.
public struct STUNPublicIP: Sendable {
  public let ip: String
}

enum STUNError: Error, CustomStringConvertible {
  case resolveFailed(errno: Int32, details: String?)
  case socketFailed(errno: Int32, details: String?)
  case sendFailed(errno: Int32, details: String?)
  case recvTimeout
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
    case .sendFailed(let errno, let details):
      let errStr = String(cString: strerror(errno))
      let baseMsg = "Failed to send STUN request (errno=\(errno)): \(errStr)"
      return details.map { "\(baseMsg). \($0)" } ?? baseMsg
    case .recvTimeout:
      return "STUN request timed out"
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

// Minimal STUN RFC 5389 Binding request to obtain public IP address via XOR-MAPPED-ADDRESS.
func stunGetPublicIPv4(
  host: String = "stun.l.google.com", port: UInt16 = 19302, timeout: TimeInterval = 1.0,
  interface: String? = nil, sourceIP: String? = nil, enableLogging: Bool = false
) throws -> STUNPublicIP {
  // Resolve server
  var hints = addrinfo(
    ai_flags: AI_ADDRCONFIG, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: IPPROTO_UDP,
    ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
  var res: UnsafeMutablePointer<addrinfo>? = nil
  let resolveResult = getaddrinfo(host, String(port), &hints, &res)
  guard resolveResult == 0, let info = res, let sa = info.pointee.ai_addr else {
    let error = errno
    throw STUNError.resolveFailed(
      errno: error,
      details: "Failed to resolve STUN server '\(host):\(port)'"
    )
  }
  defer { freeaddrinfo(info) }
  var server = sockaddr_in()
  memcpy(&server, sa, min(MemoryLayout<sockaddr_in>.size, Int(info.pointee.ai_addrlen)))

  let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
  if fd < 0 {
    let error = errno
    throw STUNError.socketFailed(
      errno: error,
      details: "Unable to create UDP socket for STUN. May indicate system resource limits."
    )
  }
  defer { close(fd) }

  // Bind to specific interface if requested
  if let interfaceName = interface {
    if enableLogging {
      print("[STUN] Binding socket to interface '\(interfaceName)'...")
    }

    #if os(macOS)
      let ifIndex = if_nametoindex(interfaceName)
      if ifIndex == 0 {
        let error = errno
        let details =
          "Interface '\(interfaceName)' not found for STUN. Common causes: (1) Interface doesn't exist, (2) Interface is down, (3) Typo in interface name. Use 'ifconfig' to list available interfaces."
        if enableLogging {
          print("[STUN] ERROR: \(details)")
        }
        throw STUNError.interfaceBindFailed(
          interface: interfaceName, errno: error, details: details)
      }

      var index = ifIndex
      if setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size)) != 0
      {
        let error = errno
        let details =
          "Failed to bind STUN socket to interface index \(ifIndex). This may indicate: (1) Insufficient permissions, (2) Interface is not available for UDP binding, (3) Interface doesn't support the operation."
        if enableLogging {
          print("[STUN] ERROR: \(details)")
        }
        throw STUNError.interfaceBindFailed(
          interface: interfaceName, errno: error, details: details)
      }

      if enableLogging {
        print("[STUN] Successfully bound to interface '\(interfaceName)' (index: \(ifIndex))")
      }
    #else
      let error = ENOTSUP
      let details =
        "Interface binding for STUN is currently only supported on macOS. Linux support requires SO_BINDTODEVICE."
      if enableLogging {
        print("[STUN] ERROR: \(details)")
      }
      throw STUNError.interfaceBindFailed(interface: interfaceName, errno: error, details: details)
    #endif
  }

  // Bind to specific source IP if requested
  if let srcIP = sourceIP {
    if enableLogging {
      print("[STUN] Binding socket to source IP '\(srcIP)'...")
    }

    var sourceAddr = sockaddr_in()
    sourceAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    sourceAddr.sin_family = sa_family_t(AF_INET)
    sourceAddr.sin_port = 0  // Any port

    if inet_pton(AF_INET, srcIP, &sourceAddr.sin_addr) != 1 {
      let error = EINVAL
      let details =
        "Invalid source IP address format '\(srcIP)'. Must be valid IPv4 in dotted decimal notation."
      if enableLogging {
        print("[STUN] ERROR: \(details)")
      }
      throw STUNError.sourceIPBindFailed(sourceIP: srcIP, errno: error, details: details)
    }

    let bindResult = withUnsafePointer(to: &sourceAddr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }

    if bindResult != 0 {
      let error = errno
      let details =
        "Failed to bind to source IP. Common causes: (1) IP not assigned to any interface, (2) IP on different interface than specified, (3) Permission denied."
      if enableLogging {
        print("[STUN] ERROR: bind() failed - errno=\(error): \(String(cString: strerror(error)))")
      }
      throw STUNError.sourceIPBindFailed(sourceIP: srcIP, errno: error, details: details)
    }

    if enableLogging {
      print("[STUN] Successfully bound to source IP '\(srcIP)'")
    }
  }

  // Set timeouts
  var tv = timeval(
    tv_sec: Int(timeout), tv_usec: __darwin_suseconds_t((timeout - floor(timeout)) * 1_000_000))
  _ = withUnsafePointer(to: &tv) { p in
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, p, socklen_t(MemoryLayout<timeval>.size))
  }
  _ = withUnsafePointer(to: &tv) { p in
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, p, socklen_t(MemoryLayout<timeval>.size))
  }

  // Build STUN Binding Request
  var req = [UInt8](repeating: 0, count: 20)
  // Type 0x0001, Length 0x0000
  req[0] = 0x00
  req[1] = 0x01
  req[2] = 0x00
  req[3] = 0x00
  // Magic cookie 0x2112A442
  req[4] = 0x21
  req[5] = 0x12
  req[6] = 0xA4
  req[7] = 0x42
  // Transaction ID 12 random bytes
  for i in 0..<12 { req[8 + i] = UInt8.random(in: 0...255) }

  let sent = req.withUnsafeBytes { raw in
    withUnsafePointer(to: &server) { aptr in
      aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
        sendto(fd, raw.baseAddress!, raw.count, 0, saptr, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
  }
  if sent < 0 {
    let error = errno
    throw STUNError.sendFailed(
      errno: error,
      details: "Failed to send STUN request to \(host):\(port)"
    )
  }

  // Receive response
  var buf = [UInt8](repeating: 0, count: 512)
  var from = sockaddr_in()
  var fromlen: socklen_t = socklen_t(MemoryLayout<sockaddr_in>.size)
  let n = withUnsafeMutablePointer(to: &from) { aptr -> ssize_t in
    aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
      recvfrom(fd, &buf, buf.count, 0, saptr, &fromlen)
    }
  }
  if n <= 0 { throw STUNError.recvTimeout }

  // Parse attributes; expect XOR-MAPPED-ADDRESS (0x0020) or MAPPED-ADDRESS (0x0001)
  if n < 20 { throw STUNError.recvTimeout }
  let magic: UInt32 = 0x2112_A442
  var ofs = 20
  while ofs + 4 <= n {
    let atype = UInt16(buf[ofs]) << 8 | UInt16(buf[ofs + 1])
    let alen = Int(UInt16(buf[ofs + 2]) << 8 | UInt16(buf[ofs + 3]))
    ofs += 4
    if ofs + alen > n { break }
    if atype == 0x0020 || atype == 0x0001 {  // XOR-MAPPED-ADDRESS or MAPPED-ADDRESS
      if alen >= 8 {
        let family = buf[ofs + 1]
        if family == 0x01 {  // IPv4
          var port: UInt16 = (UInt16(buf[ofs + 2]) << 8) | UInt16(buf[ofs + 3])
          var addr: UInt32 =
            (UInt32(buf[ofs + 4]) << 24) | (UInt32(buf[ofs + 5]) << 16)
            | (UInt32(buf[ofs + 6]) << 8) | UInt32(buf[ofs + 7])
          if atype == 0x0020 {
            // XOR with magic cookie
            port ^= UInt16((magic >> 16) & 0xFFFF)
            addr ^= magic
          }
          let oct1 = (addr >> 24) & 0xFF
          let oct2 = (addr >> 16) & 0xFF
          let oct3 = (addr >> 8) & 0xFF
          let oct4 = addr & 0xFF
          let ip = "\(oct1).\(oct2).\(oct3).\(oct4)"
          _ = port  // not used currently
          return STUNPublicIP(ip: ip)
        }
      }
    }
    // attributes are padded to 4
    ofs += ((alen + 3) / 4) * 4
  }
  throw STUNError.recvTimeout
}
