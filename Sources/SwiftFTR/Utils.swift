import Foundation

#if canImport(Darwin)
  import Darwin
#endif

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
@inline(__always)
public func isCGNATIPv4(_ ip: String) -> Bool {
  // 100.64.0.0/10
  let parts = ip.split(separator: ".").compactMap { Int($0) }
  guard parts.count == 4 else { return false }
  let a = parts[0]
  let b = parts[1]
  return a == 100 && (64...127).contains(b)
}

/// Performs a best-effort reverse DNS lookup for the given IPv4 string.
/// - Returns: A hostname if one exists, otherwise nil. Blocking but bounded by system resolver.
public func reverseDNS(_ ipv4: String) -> String? {
  var sin = sockaddr_in()
  sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  sin.sin_family = sa_family_t(AF_INET)
  let ok = ipv4.withCString { cs in inet_pton(AF_INET, cs, &sin.sin_addr) }
  guard ok == 1 else { return nil }
  var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
  let res = withUnsafePointer(to: &sin) { aptr in
    aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
      getnameinfo(
        saptr, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, 0)
    }
  }
  if res == 0 {
    return host.withUnsafeBufferPointer { ptr in
      String(cString: ptr.baseAddress!)
    }
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
