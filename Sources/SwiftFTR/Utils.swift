import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// Returns `AF_INET` for IPv4, `AF_INET6` for IPv6, or `-1` if the string is not a valid IP.
/// Strips scope ID (e.g. `%en0`) from IPv6 link-local addresses before parsing.
@inline(__always)
func detectAddressFamily(_ ip: String) -> Int32 {
  var addr4 = in_addr()
  if inet_pton(AF_INET, ip, &addr4) == 1 { return Int32(AF_INET) }
  let bare = ip.split(separator: "%", maxSplits: 1).first.map(String.init) ?? ip
  var addr6 = in6_addr()
  if inet_pton(AF_INET6, bare, &addr6) == 1 { return Int32(AF_INET6) }
  return -1
}

/// Parse an IPv6 server string like `fe80::1%en0` into (bareIP, scopeID).
/// `scopeID` is the numeric interface index (from the `%zone` suffix), or 0 if absent.
func parseIPv6Scoped(_ server: String) -> (ip: String, scopeID: UInt32) {
  let parts = server.split(separator: "%", maxSplits: 1)
  let bare = String(parts[0])
  if parts.count == 2 {
    let zone = String(parts[1])
    let idx = if_nametoindex(zone)  // returns 0 if not found
    return (bare, idx != 0 ? idx : UInt32(zone) ?? 0)
  }
  return (bare, 0)
}

@inline(__always)
func ipString(_ sin: sockaddr_in) -> String {
  var sin = sin
  var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
  _ = withUnsafePointer(to: &sin.sin_addr) { ptr in
    inet_ntop(AF_INET, ptr, &buf, socklen_t(INET_ADDRSTRLEN))
  }
  return buf.withUnsafeBufferPointer { ptr in
    return String(cString: ptr.baseAddress!)
  }
}

/// Canonical IPv6 string form via `inet_ntop`. Appends `%<ifname>` zone suffix when
/// `scopeID != 0` so link-local addresses round-trip as `fe80::1%en0` rather than
/// losing their zone (which would collide on string keys across interfaces).
///
/// Downstream contract (NWX): every address SwiftFTR emits goes through this
/// formatter so that `String → resolve → String` is stable for any input.
@inline(__always)
func ipv6String(_ addr: in6_addr, scopeID: UInt32 = 0) -> String {
  var a = addr
  var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
  _ = withUnsafePointer(to: &a) { ptr in
    inet_ntop(AF_INET6, ptr, &buf, socklen_t(INET6_ADDRSTRLEN))
  }
  let bare = buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
  guard scopeID != 0 else { return bare }
  var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
  if if_indextoname(scopeID, &nameBuf) != nil {
    let name = nameBuf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    if !name.isEmpty { return "\(bare)%\(name)" }
  }
  // Fall back to numeric scope if the interface name isn't resolvable.
  return "\(bare)%\(scopeID)"
}

/// The routing scope of a numeric IP address.
enum IPAddressScope: Sendable, Equatable {
  case global
  case privateNetwork
  case carrierGradeNAT
  case linkLocal
  case loopback
  case unspecified
  case multicast
}

/// A parsed numeric IP address whose IPv4-mapped IPv6 form is normalized to IPv4.
struct ParsedIPAddress: Hashable, Sendable {
  private enum Family: Hashable, Sendable {
    case ipv4
    case ipv6
  }

  private let family: Family
  private let bytes: [UInt8]

  init?(_ presentation: String) {
    var address4 = in_addr()
    if presentation.withCString({ inet_pton(AF_INET, $0, &address4) }) == 1 {
      self.family = .ipv4
      self.bytes = withUnsafeBytes(of: &address4) { Array($0) }
      return
    }

    let bare =
      presentation.split(separator: "%", maxSplits: 1).first.map(String.init)
      ?? presentation
    var address6 = in6_addr()
    guard bare.withCString({ inet_pton(AF_INET6, $0, &address6) }) == 1 else {
      return nil
    }

    let ipv6Bytes = withUnsafeBytes(of: &address6) { Array($0) }
    guard ipv6Bytes.count == 16 else { return nil }

    // IPv4-mapped IPv6 addresses (::ffff:a.b.c.d) have IPv4 routing semantics.
    if ipv6Bytes[0..<10].allSatisfy({ $0 == 0 })
      && ipv6Bytes[10] == 0xff
      && ipv6Bytes[11] == 0xff
    {
      self.family = .ipv4
      self.bytes = Array(ipv6Bytes[12..<16])
    } else {
      self.family = .ipv6
      self.bytes = ipv6Bytes
    }
  }

  var scope: IPAddressScope {
    switch family {
    case .ipv4:
      let first = bytes[0]
      let second = bytes[1]
      if first == 10
        || (first == 172 && (16...31).contains(second))
        || (first == 192 && second == 168)
      {
        return .privateNetwork
      }
      if first == 100 && (64...127).contains(second) { return .carrierGradeNAT }
      if first == 169 && second == 254 { return .linkLocal }
      if first == 127 { return .loopback }
      if bytes.allSatisfy({ $0 == 0 }) { return .unspecified }
      if first & 0xf0 == 0xe0 { return .multicast }
      return .global

    case .ipv6:
      if bytes.allSatisfy({ $0 == 0 }) { return .unspecified }
      if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return .loopback }
      if bytes[0] & 0xfe == 0xfc { return .privateNetwork }
      if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return .linkLocal }
      if bytes[0] == 0xff { return .multicast }
      return .global
    }
  }

  /// The canonical dotted-quad form when the address has IPv4 routing semantics.
  var canonicalIPv4Presentation: String? {
    guard family == .ipv4 else { return nil }
    return bytes.map(String.init).joined(separator: ".")
  }
}

private enum IPAddressScopeIdentifier: Hashable {
  case interfaceIndex(UInt32)
  case interfaceName(String)
}

private func ipAddressScopeIdentifier(in presentation: String) -> IPAddressScopeIdentifier? {
  let parts = presentation.split(separator: "%", maxSplits: 1)
  guard parts.count == 2 else { return nil }

  let identifier = String(parts[1])
  if let index = UInt32(identifier) {
    return .interfaceIndex(index)
  }
  let index = if_nametoindex(identifier)
  if index != 0 {
    return .interfaceIndex(index)
  }
  return .interfaceName(identifier)
}

/// Returns the routing scope of a numeric IPv4 or IPv6 address.
@inline(__always)
func ipAddressScope(of presentation: String) -> IPAddressScope? {
  ParsedIPAddress(presentation)?.scope
}

/// Returns whether two numeric address presentations identify the same IP address.
///
/// IPv6 compression and hexadecimal case are ignored. When either presentation
/// includes a scope suffix, both suffixes must identify the same interface.
/// IPv4-mapped IPv6 addresses compare equal to their embedded IPv4 address.
@inline(__always)
func ipAddressesAreEqual(_ lhs: String, _ rhs: String) -> Bool {
  guard let left = ParsedIPAddress(lhs), let right = ParsedIPAddress(rhs) else {
    return lhs == rhs
  }
  guard left == right else { return false }
  let leftScopeIdentifier = ipAddressScopeIdentifier(in: lhs)
  let rightScopeIdentifier = ipAddressScopeIdentifier(in: rhs)
  guard leftScopeIdentifier != nil || rightScopeIdentifier != nil else { return true }
  return leftScopeIdentifier == rightScopeIdentifier
}

/// Returns whether the numeric address can be routed globally.
@inline(__always)
func isGloballyRoutableIPAddress(_ presentation: String) -> Bool {
  ipAddressScope(of: presentation) == .global
}

/// Returns the address presentation to send to an ASN resolver.
///
/// IPv4-mapped IPv6 addresses use their canonical dotted-quad form so resolvers
/// select the IPv4 lookup path. Non-global and invalid addresses return `nil`.
@inline(__always)
func asnLookupAddress(for presentation: String) -> String? {
  guard let address = ParsedIPAddress(presentation), address.scope == .global else {
    return nil
  }
  return address.canonicalIPv4Presentation ?? presentation
}

/// Reverse-nibble form of an IPv6 address for DNS-based lookups (Cymru
/// `origin6.asn.cymru.com`, IP6.ARPA reverse zones, etc.). Returns the fully
/// expanded address with each hex digit reversed and dot-separated, e.g.
/// `2001:db8::1` → `"1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2"`.
/// Returns nil if the input isn't a parseable IPv6 address. Scope suffix `%zone`
/// is stripped before parsing.
public func reverseIPv6Nibbles(_ ip: String) -> String? {
  let (bare, _) = parseIPv6Scoped(ip)
  var addr = in6_addr()
  guard bare.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
  // in6_addr is 16 bytes (8 UInt16s in big-endian). Walk byte-by-byte for
  // straightforward nibble extraction.
  let bytes: [UInt8] = withUnsafeBytes(of: &addr) { raw in
    Array(raw.bindMemory(to: UInt8.self))
  }
  guard bytes.count == 16 else { return nil }
  let hexDigits = "0123456789abcdef"
  let hexArr = Array(hexDigits)
  var nibbles: [Character] = []
  nibbles.reserveCapacity(32)
  for b in bytes {
    nibbles.append(hexArr[Int(b >> 4)])
    nibbles.append(hexArr[Int(b & 0x0F)])
  }
  // Reverse and dot-join.
  return nibbles.reversed().map(String.init).joined(separator: ".")
}

/// Returns true if the IPv4 string is in RFC1918 private or 169.254/16 link-local space.
@inline(__always)
public func isPrivateIPv4(_ ip: String) -> Bool {
  // 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, link-local 169.254/16
  let parts = ip.split(separator: ".").compactMap { Int($0) }
  guard parts.count == 4 else { return false }
  let a = parts[0]
  let b = parts[1]
  if a == 10 { return true }
  if a == 172 && (16...31).contains(b) { return true }
  if a == 192 && b == 168 { return true }
  if a == 169 && b == 254 { return true }
  return false
}

/// Returns true if the IPv4 string is in RFC6598 CGNAT range (100.64.0.0/10).
///
/// Note: This range is used by both ISP CGNAT and overlay networks like Tailscale.
/// Use `VPNContext` to distinguish between them during classification.
@inline(__always)
public func isCGNATIPv4(_ ip: String) -> Bool {
  // 100.64.0.0/10
  let parts = ip.split(separator: ".").compactMap { Int($0) }
  guard parts.count == 4 else { return false }
  let a = parts[0]
  let b = parts[1]
  return a == 100 && (64...127).contains(b)
}

typealias NameInfoLookup = (
  UnsafePointer<sockaddr>?,
  socklen_t,
  UnsafeMutablePointer<CChar>?,
  socklen_t,
  UnsafeMutablePointer<CChar>?,
  socklen_t,
  Int32
) -> Int32

/// Performs a best-effort reverse DNS lookup for the given IP string (IPv4 or IPv6).
///
/// Numeric fallback text is not a hostname and is therefore rejected.
/// - Returns: A hostname if one exists, otherwise nil. Blocking but bounded by system resolver.
public func reverseDNS(_ ip: String) -> String? {
  reverseDNS(ip, using: getnameinfo)
}

/// Testable implementation that accepts the platform name-info lookup function.
func reverseDNS(_ ip: String, using lookup: NameInfoLookup) -> String? {
  let family = detectAddressFamily(ip)
  if family == AF_INET {
    var sin = sockaddr_in()
    sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    sin.sin_family = sa_family_t(AF_INET)
    let ok = ip.withCString { cs in inet_pton(AF_INET, cs, &sin.sin_addr) }
    guard ok == 1 else { return nil }
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let res = withUnsafePointer(to: &sin) { aptr in
      aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
        lookup(
          saptr, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0,
          NI_NAMEREQD
        )
      }
    }
    if res == 0 {
      return host.withUnsafeBufferPointer { ptr in
        String(cString: ptr.baseAddress!)
      }
    }
    return nil
  } else if family == AF_INET6 {
    let (bare, scopeID) = parseIPv6Scoped(ip)
    var sin6 = sockaddr_in6()
    sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    sin6.sin6_family = sa_family_t(AF_INET6)
    sin6.sin6_scope_id = scopeID
    let ok = bare.withCString { cs in inet_pton(AF_INET6, cs, &sin6.sin6_addr) }
    guard ok == 1 else { return nil }
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let res = withUnsafePointer(to: &sin6) { aptr in
      aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
        lookup(
          saptr, socklen_t(MemoryLayout<sockaddr_in6>.size), &host, socklen_t(host.count), nil, 0,
          NI_NAMEREQD)
      }
    }
    if res == 0 {
      return host.withUnsafeBufferPointer { ptr in
        String(cString: ptr.baseAddress!)
      }
    }
    return nil
  }
  return nil
}

@inline(__always)
func monotonicNow() -> TimeInterval {
  var ts = timespec()
  #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    _ = clock_gettime(CLOCK_MONOTONIC, &ts)
  #else
    _ = clock_gettime(CLOCK_MONOTONIC, &ts)
  #endif
  return TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000
}

/// Runs a blocking syscall (socket I/O, STUN, legacy DNS clients) on a detached task so we do not
/// monopolize the cooperative executor backing the caller (usually `SwiftFTR`'s actor).
/// Callers should pass lightweight closures that capture only the values required by the syscall.
#if compiler(>=6.2)
  @concurrent
#endif
@inline(__always)
func runDetachedBlockingIO<T>(
  priority: TaskPriority = .userInitiated,
  _ operation: @Sendable @escaping () throws -> T
) async throws -> T {
  let boxed = try await Task.detached(priority: priority) {
    try _UncheckedSendable(value: operation())
  }.value
  return boxed.value
}

@usableFromInline
struct _UncheckedSendable<T>: @unchecked Sendable {
  let value: T
}
