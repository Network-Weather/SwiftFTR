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

/// Performs a best-effort reverse DNS lookup for the given IP string (IPv4 or IPv6).
/// - Returns: A hostname if one exists, otherwise nil. Blocking but bounded by system resolver.
public func reverseDNS(_ ip: String) -> String? {
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
        getnameinfo(
          saptr, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, 0
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
        getnameinfo(
          saptr, socklen_t(MemoryLayout<sockaddr_in6>.size), &host, socklen_t(host.count), nil, 0,
          0)
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
