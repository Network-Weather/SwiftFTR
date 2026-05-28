import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// Resolved destination: address family + storage + canonical printable form.
///
/// The canonical string is what shows up in user-facing fields like
/// `PingResult.resolvedIP` and what NWX-style consumers use as dictionary keys.
/// For IPv6 link-local destinations the canonical includes the `%<ifname>` zone
/// suffix (see `ipv6String` in `Utils.swift`). Consistency matters: the same
/// input string must always produce the same canonical form.
public struct ResolvedHost: Sendable {
  public let family: Int32  // AF_INET or AF_INET6
  public let address: sockaddr_storage
  public let addressLen: socklen_t
  public let canonical: String
}

/// Family-aware source-IP bind shared across ping, trace, probes, and STUN.
/// Returns nil on success; returns an error message string on failure. Callers
/// that report errors via thrown types (e.g. `Traceroute`) wrap this and
/// translate the string; callers that report via result types (probes) use the
/// string directly.
///
/// For v6 the link-local `%zone` suffix is honored via `parseIPv6Scoped`.
internal func bindSourceIP(sockfd: Int32, family: Int32, sourceIP: String) -> String? {
  switch family {
  case AF_INET:
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    if inet_pton(AF_INET, sourceIP, &addr.sin_addr) != 1 {
      return "Invalid source IPv4 address '\(sourceIP)'"
    }
    let rc = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        Darwin.bind(sockfd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if rc < 0 {
      return "Failed to bind to source IP '\(sourceIP)': \(String(cString: strerror(errno)))"
    }
    return nil
  case AF_INET6:
    let (bare, scopeID) = parseIPv6Scoped(sourceIP)
    var addr = sockaddr_in6()
    addr.sin6_family = sa_family_t(AF_INET6)
    addr.sin6_port = 0
    addr.sin6_scope_id = scopeID
    if inet_pton(AF_INET6, bare, &addr.sin6_addr) != 1 {
      return "Invalid source IPv6 address '\(sourceIP)'"
    }
    let rc = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        Darwin.bind(sockfd, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
      }
    }
    if rc < 0 {
      return "Failed to bind to source IP '\(sourceIP)': \(String(cString: strerror(errno)))"
    }
    return nil
  default:
    return "Unsupported family for source bind: \(family)"
  }
}

/// Family-aware interface bind via `IP_BOUND_IF` (v4) or `IPV6_BOUND_IF` (v6).
/// Returns nil on success; an error message string on failure. Caller is
/// responsible for resolving `interfaceName` to `ifIndex` (typically via
/// `if_nametoindex`) and for handling the `ifIndex == 0` failure case before
/// invoking this — that lets callers produce more specific error messages
/// (e.g. "interface not found" vs. "setsockopt failed").
internal func bindInterface(sockfd: Int32, family: Int32, ifIndex: UInt32) -> String? {
  var index = ifIndex
  let level = family == AF_INET6 ? IPPROTO_IPV6 : IPPROTO_IP
  let opt = family == AF_INET6 ? IPV6_BOUND_IF : IP_BOUND_IF
  if setsockopt(sockfd, level, opt, &index, socklen_t(MemoryLayout<UInt32>.size)) != 0 {
    return
      "setsockopt(\(family == AF_INET6 ? "IPV6_BOUND_IF" : "IP_BOUND_IF")) failed: \(String(cString: strerror(errno)))"
  }
  return nil
}

/// Dual-stack host resolver shared across `ping()`, `trace()`, and friends.
///
/// Honors `PreferredFamily`:
/// - `.auto`: literal IPs are dispatched by `detectAddressFamily`; hostnames use
///   `getaddrinfo(AF_UNSPEC)` and take the first answer. Darwin's `getaddrinfo`
///   returns addresses in RFC 6724 source/destination ordering, so the first
///   answer is the system-preferred address for an outgoing connection from this
///   host — not an arbitrary one. On a dual-stack host this typically means v6
///   first when a routable v6 path exists, v4 otherwise.
/// - `.v4` / `.v6`: forces the family; throws `.resolutionFailed` if unavailable.
///
/// The canonical printable form (`inet_ntop`) is returned in `ResolvedHost.canonical`,
/// with link-local scope suffix preserved as `addr%ifname` (NWX downstream contract).
///
/// This helper lives at file scope rather than inside a particular executor so
/// `Ping`, `Trace`, and (eventually) the probes can share it without duplication
/// or cross-module coupling. The full resolver-dedup across `TCPProbe.swift` /
/// `UDPProbe.swift` is Stage 5 in `docs/IPV6.md`; this is the smaller extraction
/// that unblocks Stage 2 traceroute.
internal func resolveHost(host: String, prefer: PreferredFamily) throws -> ResolvedHost {
  // Numeric literal fast path.
  let detected = detectAddressFamily(host)
  if detected == AF_INET {
    if prefer == .v6 {
      throw TracerouteError.resolutionFailed(
        host: host, details: "Preferred family v6 but literal is v4")
    }
    var sin = sockaddr_in()
    sin.sin_family = sa_family_t(AF_INET)
    sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    _ = inet_pton(AF_INET, host, &sin.sin_addr)
    var storage = sockaddr_storage()
    withUnsafePointer(to: &sin) { src in
      withUnsafeMutablePointer(to: &storage) { dst in
        memcpy(dst, src, MemoryLayout<sockaddr_in>.size)
      }
    }
    return ResolvedHost(
      family: AF_INET, address: storage,
      addressLen: socklen_t(MemoryLayout<sockaddr_in>.size), canonical: ipString(sin))
  }
  if detected == AF_INET6 {
    if prefer == .v4 {
      throw TracerouteError.resolutionFailed(
        host: host, details: "Preferred family v4 but literal is v6")
    }
    let (bare, scopeID) = parseIPv6Scoped(host)
    var sin6 = sockaddr_in6()
    sin6.sin6_family = sa_family_t(AF_INET6)
    sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    sin6.sin6_scope_id = scopeID
    _ = inet_pton(AF_INET6, bare, &sin6.sin6_addr)
    var storage = sockaddr_storage()
    withUnsafePointer(to: &sin6) { src in
      withUnsafeMutablePointer(to: &storage) { dst in
        memcpy(dst, src, MemoryLayout<sockaddr_in6>.size)
      }
    }
    return ResolvedHost(
      family: AF_INET6, address: storage,
      addressLen: socklen_t(MemoryLayout<sockaddr_in6>.size),
      canonical: ipv6String(sin6.sin6_addr, scopeID: scopeID))
  }

  // Hostname path — let getaddrinfo do dual-stack lookup; pick the first answer
  // that matches `prefer` (or any if .auto).
  var hints = addrinfo()
  hints.ai_socktype = SOCK_DGRAM
  switch prefer {
  case .v4: hints.ai_family = AF_INET
  case .v6: hints.ai_family = AF_INET6
  case .auto: hints.ai_family = AF_UNSPEC
  }
  var result: UnsafeMutablePointer<addrinfo>?
  let rc = getaddrinfo(host, nil, &hints, &result)
  guard rc == 0, let head = result else {
    throw TracerouteError.resolutionFailed(
      host: host,
      details: rc == 0 ? "no addresses returned" : String(cString: gai_strerror(rc)))
  }
  defer { freeaddrinfo(result) }

  var cursor: UnsafeMutablePointer<addrinfo>? = head
  while let ai = cursor {
    let fam = ai.pointee.ai_family
    if fam == AF_INET, let addr = ai.pointee.ai_addr {
      let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
      var storage = sockaddr_storage()
      withUnsafeMutablePointer(to: &storage) { dst in
        memcpy(dst, addr, MemoryLayout<sockaddr_in>.size)
      }
      return ResolvedHost(
        family: AF_INET, address: storage,
        addressLen: socklen_t(MemoryLayout<sockaddr_in>.size), canonical: ipString(sin))
    }
    if fam == AF_INET6, let addr = ai.pointee.ai_addr {
      let sin6 = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
      var storage = sockaddr_storage()
      withUnsafeMutablePointer(to: &storage) { dst in
        memcpy(dst, addr, MemoryLayout<sockaddr_in6>.size)
      }
      return ResolvedHost(
        family: AF_INET6, address: storage,
        addressLen: socklen_t(MemoryLayout<sockaddr_in6>.size),
        canonical: ipv6String(sin6.sin6_addr, scopeID: sin6.sin6_scope_id))
    }
    cursor = ai.pointee.ai_next
  }
  throw TracerouteError.resolutionFailed(
    host: host, details: "No matching address for preferred family")
}
