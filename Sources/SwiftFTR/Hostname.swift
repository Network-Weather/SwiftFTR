import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// Resolved destination: address family + storage + canonical printable form.
///
/// The canonical string is what shows up in user-facing fields like
/// `PingResult.resolvedIP` and what downstream consumers use as dictionary keys.
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
  // `inet_pton` would read only the text before a NUL and bind that address instead.
  guard !containsNUL(sourceIP) else { return "Invalid source IP address: contains a NUL character" }
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

/// Makes a TCP or UDP probe socket non-blocking, as ``setProbeSocketNonBlocking(_:)`` does for
/// trace and ping. Returns nil on success; on failure, the message the probe reports in its
/// result, naming the failed `fcntl` step and its errno.
///
/// The probes report setup failures in their result rather than throwing. Neither may run on a
/// blocking socket: the TCP probe's `connect` would wait for the kernel's connect timeout, past the
/// probe's timeout and cancellation, and the UDP probe's `recv` would park its queue on a readable
/// event with no datagram.
internal func makeProbeSocketNonBlocking(sockfd: Int32) -> String? {
  do {
    try setProbeSocketNonBlocking(sockfd)
    return nil
  } catch TracerouteError.socketCreateFailed(let code, let step) {
    return
      "Failed to make socket non-blocking: \(step) (errno=\(code)): \(String(cString: strerror(code)))"
  } catch {
    return "Failed to make socket non-blocking: \(error)"
  }
}

/// Dual-stack host resolver shared across `ping()`, `trace()`, and friends, synchronously: the
/// inline answers of ``inlineResolution(host:prefer:)``, otherwise ``blockingResolution(host:prefer:substitute:)``
/// with the task's `TestSeams.resolveHost`. Operations resolve through
/// ``resolveDestination(_:prefer:until:clock:handle:)``, which runs the blocking branch in an
/// executor slot.
///
/// Honors `PreferredFamily`:
/// - `.auto`: hostnames and most literals use `getaddrinfo(AF_UNSPEC)` and take the first answer.
///   Darwin's `getaddrinfo` returns addresses in RFC 6724 source/destination ordering, so the
///   first answer is the system-preferred address for an outgoing connection from this host. A
///   literal goes through it too, so the system can synthesize an IPv6 address for an IPv4
///   literal on a NAT64 network.
/// - `.v4` / `.v6`: forces the family; throws `.resolutionFailed` if unavailable.
///
/// The canonical printable form (`inet_ntop`) is returned in `ResolvedHost.canonical`,
/// with link-local scope suffix preserved as `addr%ifname` (downstream contract).
internal func resolveHost(host: String, prefer: PreferredFamily) throws -> ResolvedHost {
  if let answer = try inlineResolution(host: host, prefer: prefer) { return answer }
  return try blockingResolution(host: host, prefer: prefer, substitute: TestSeams.resolveHost)
}

/// The answer for `host` that needs no resolver, or `nil` when it needs one. Throws for a NUL and
/// for a literal of the other family than a forced one.
///
/// Answered here: a literal of a forced family; under `.auto`, an IPv4 loopback literal, which
/// the system never synthesizes for (Libinfo's `_gai_nat64_can_v4_address_be_synthesized`), and
/// an IPv6 literal with no zone outside fe80::/10, fec0::/10 and ff00::/8, which `getaddrinfo`
/// returns unchanged. A zoned or scoped IPv6 literal (`getaddrinfo` turns `fe80:1::1` into
/// `fe80::1` with scope 1) and every other `.auto` IPv4 literal (NAT64) are left to the resolver.
/// Never consults a test seam, so it can run on any thread.
internal func inlineResolution(host: String, prefer: PreferredFamily) throws -> ResolvedHost? {
  // `getaddrinfo` and `inet_pton` would see only the text before a NUL and resolve that instead.
  guard !containsNUL(host) else {
    throw TracerouteError.resolutionFailed(host: host, details: "contains a NUL character")
  }
  switch (prefer, detectAddressFamily(host)) {
  case (.v4, AF_INET): return ipv4Literal(host)
  case (.v6, AF_INET6): return ipv6Literal(host)
  case (.v4, AF_INET6):
    throw TracerouteError.resolutionFailed(
      host: host, details: "Preferred family v4 but literal is v6")
  case (.v6, AF_INET):
    throw TracerouteError.resolutionFailed(
      host: host, details: "Preferred family v6 but literal is v4")
  case (.auto, AF_INET):
    var addr = in_addr()
    _ = inet_pton(AF_INET, host, &addr)
    return UInt32(bigEndian: addr.s_addr) >> 24 == 127 ? ipv4Literal(host) : nil
  case (.auto, AF_INET6):
    var addr = in6_addr()
    guard !host.contains("%"), inet_pton(AF_INET6, host, &addr) == 1 else { return nil }
    let (first, second) = (addr.__u6_addr.__u6_addr8.0, addr.__u6_addr.__u6_addr8.1)
    let scoped = first == 0xFF || (first == 0xFE && second & 0x80 == 0x80)
    return scoped ? nil : ipv6Literal(host)
  default:
    return nil
  }
}

/// The resolver branch for `host`: `substitute` when a test supplies one, otherwise
/// `getaddrinfo`. Blocks for as long as the system resolver takes, so it runs in an executor slot.
internal func blockingResolution(
  host: String, prefer: PreferredFamily, substitute: TestSeams.ResolveHost?
) throws -> ResolvedHost {
  if let substitute { return try substitute(host, prefer) }
  // `AI_V4MAPPED | AI_ADDRCONFIG` (`AI_DEFAULT`, not exposed in every Swift overlay) lets Darwin
  // synthesize an IPv6 address for an IPv4 literal when only IPv6 is configured (NAT64).
  var hints = addrinfo()
  hints.ai_socktype = SOCK_DGRAM
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
      _ = withUnsafeMutablePointer(to: &storage) { dst in
        memcpy(dst, addr, MemoryLayout<sockaddr_in>.size)
      }
      return ResolvedHost(
        family: AF_INET, address: storage,
        addressLen: socklen_t(MemoryLayout<sockaddr_in>.size), canonical: ipString(sin))
    }
    if fam == AF_INET6, let addr = ai.pointee.ai_addr {
      let sin6 = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
      var storage = sockaddr_storage()
      _ = withUnsafeMutablePointer(to: &storage) { dst in
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

/// How long a trace or ping waits for its destination to resolve (docs/BLOCKING-IO.md, decision 7).
let forwardResolutionLimit: TimeInterval = 20

/// Resolves `host` for an operation: inline when ``inlineResolution(host:prefer:)`` answers,
/// otherwise in an executor slot, a literal on the Literal Lane (``literalLookupExecutor``) and a
/// name on the main executor, so stalled name lookups cannot hold back a numeric destination.
///
/// The wait ends at `deadline` on `clock` with `resolutionFailed(details: "timed out")`, and at
/// once when the calling task is cancelled (`CancellationError`) or `handle` is (its reason's
/// error); a `getaddrinfo` already running finishes in its slot. The seam and the executor are
/// read here, on the async side.
internal func resolveDestination(
  _ host: String, prefer: PreferredFamily, until deadline: TimeInterval, clock: DiscoveryClock,
  handle: TraceHandle? = nil
) async throws -> ResolvedHost {
  if let answer = try inlineResolution(host: host, prefer: prefer) { return answer }
  let substitute = TestSeams.resolveHost
  // Numeric for lane selection is wider than a literal the library parses: the system resolver
  // also takes IPv4 shorthand ("127.1"), which `inet_aton` recognizes and `inet_pton` does not.
  var shorthand = in_addr()
  let numeric = detectAddressFamily(host) != -1 || inet_aton(host, &shorthand) == 1
  let lane = numeric ? (TestSeams.literalLookupExecutor ?? literalLookupExecutor) : nil
  let found = try await withTraceCancellation(handle: handle) {
    try await awaitBlockingLookup(until: deadline, clock: clock, on: lane) {
      try blockingResolution(host: host, prefer: prefer, substitute: substitute)
    }
  }
  guard let found else {
    throw TracerouteError.resolutionFailed(host: host, details: "timed out")
  }
  return found
}

/// A literal of IPv4, parsed without the resolver. `host` must be one (``detectAddressFamily(_:)``).
private func ipv4Literal(_ host: String) -> ResolvedHost {
  var sin = sockaddr_in()
  sin.sin_family = sa_family_t(AF_INET)
  sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  _ = inet_pton(AF_INET, host, &sin.sin_addr)
  var storage = sockaddr_storage()
  _ = withUnsafePointer(to: &sin) { src in
    withUnsafeMutablePointer(to: &storage) { dst in
      memcpy(dst, src, MemoryLayout<sockaddr_in>.size)
    }
  }
  return ResolvedHost(
    family: AF_INET, address: storage,
    addressLen: socklen_t(MemoryLayout<sockaddr_in>.size), canonical: ipString(sin))
}

/// A literal of IPv6, with its `%zone` as the scope, parsed without the resolver.
private func ipv6Literal(_ host: String) -> ResolvedHost {
  let (bare, scopeID) = parseIPv6Scoped(host)
  var sin6 = sockaddr_in6()
  sin6.sin6_family = sa_family_t(AF_INET6)
  sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
  sin6.sin6_scope_id = scopeID
  _ = inet_pton(AF_INET6, bare, &sin6.sin6_addr)
  var storage = sockaddr_storage()
  _ = withUnsafePointer(to: &sin6) { src in
    withUnsafeMutablePointer(to: &storage) { dst in
      memcpy(dst, src, MemoryLayout<sockaddr_in6>.size)
    }
  }
  return ResolvedHost(
    family: AF_INET6, address: storage,
    addressLen: socklen_t(MemoryLayout<sockaddr_in6>.size),
    canonical: ipv6String(sin6.sin6_addr, scopeID: scopeID))
}
