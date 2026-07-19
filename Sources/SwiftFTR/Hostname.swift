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

/// Validates that a configured source address can be used with a resolved
/// destination before creating or binding a socket.
internal func validateSourceIPFamily(_ sourceIP: String, destinationFamily: Int32) throws {
  let sourceFamily = detectAddressFamily(sourceIP)
  guard sourceFamily == AF_INET || sourceFamily == AF_INET6 else {
    throw TracerouteError.sourceIPBindFailed(
      sourceIP: sourceIP,
      errno: EINVAL,
      details: "Invalid source IP address '\(sourceIP)'. Expected a numeric IPv4 or IPv6 address."
    )
  }

  guard sourceFamily == destinationFamily else {
    let sourceName = sourceFamily == AF_INET6 ? "IPv6" : "IPv4"
    let destinationName = destinationFamily == AF_INET6 ? "IPv6" : "IPv4"
    throw TracerouteError.sourceIPBindFailed(
      sourceIP: sourceIP,
      errno: EAFNOSUPPORT,
      details:
        "Configured source address is \(sourceName), but the destination resolved to \(destinationName). Set preferredFamily to a matching family."
    )
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
  let detected = detectAddressFamily(host)

  // Force-mode fast paths: when the caller explicitly asked for v4 or v6, skip
  // getaddrinfo and use the literal directly. This preserves the original
  // behavior for callers that know their family and want microsecond resolution.
  //
  // In `.auto` mode we always go through getaddrinfo (even for literals) so
  // macOS's resolver can synthesize a v4-mapped v6 address for v4 literals on
  // NAT64 networks (RFC 6147 / Apple's CLAT). On dual-stack networks the
  // resolver returns the v4 literal unchanged; on v6-only NAT64 networks it
  // returns the synthesized v6 address and the trace/probe goes via v6
  // transparently — no caller code changes required. The extra getaddrinfo
  // call costs ~tens of microseconds; the NAT64 transparency it buys is worth
  // it (matches Apple's own guidance for IPv6-compatible apps).
  if prefer == .v4 && detected == AF_INET {
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
  if prefer == .v6 && detected == AF_INET6 {
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
  // Mismatched literal vs preferred family throws.
  if prefer == .v4 && detected == AF_INET6 {
    throw TracerouteError.resolutionFailed(
      host: host, details: "Preferred family v4 but literal is v6")
  }
  if prefer == .v6 && detected == AF_INET {
    throw TracerouteError.resolutionFailed(
      host: host, details: "Preferred family v6 but literal is v4")
  }

  // `.auto` mode (and any hostname path) — let getaddrinfo handle everything,
  // including NAT64 synthesis for v4 literals on v6-only networks. The
  // `AI_V4MAPPED | AI_ADDRCONFIG | AI_DEFAULT` flag set tells Darwin's resolver
  // to synthesize a v4-mapped v6 address when only v6 is configured locally.
  var hints = addrinfo()
  hints.ai_socktype = SOCK_DGRAM
  // AI_DEFAULT == AI_V4MAPPED | AI_ADDRCONFIG. Hardcoded numeric form below
  // because AI_DEFAULT isn't exposed in all Swift overlay versions.
  hints.ai_flags = AI_V4MAPPED | AI_ADDRCONFIG
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
