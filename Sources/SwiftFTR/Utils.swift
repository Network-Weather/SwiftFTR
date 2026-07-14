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
