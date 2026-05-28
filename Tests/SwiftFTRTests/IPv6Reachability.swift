import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// Tests an actual routable IPv6 path from this host. Used to gate v6 integration
/// tests so they skip cleanly on CI runners (GitHub-hosted macOS runners notably
/// lack public IPv6 reachability) rather than failing spuriously.
///
/// Probe: open `AF_INET6 UDP` socket, attempt a non-blocking `connect()` to
/// `[2606:4700:4700::1111]:443` (Cloudflare DNS, well-known dual-stack anycast),
/// and wait up to 500 ms for the connect to succeed. UDP connect is purely a
/// kernel-level association — no packets are sent — so this only checks that the
/// kernel has a route, an IPv6 source address, and the route's gateway is reachable
/// in the ND cache. That's the cheapest "is v6 actually usable" question.
///
/// Result is cached for the test process lifetime so we probe at most once.
///
/// Overrides:
/// - `FORCE_IPV6_TESTS=1` short-circuits the probe and returns `true` (useful for
///   local development when you know your environment is fine).
/// - `SKIP_IPV6_TESTS=1` short-circuits the probe and returns `false` (useful for
///   forcing the skip path on a v6-capable host, e.g. while reproducing a CI flake).
public enum IPv6Reachability {
  /// Cached result. `nil` means "not probed yet".
  nonisolated(unsafe) private static var cached: Bool?
  private static let lock = NSLock()

  /// Synchronous probe (cached). Safe to call from `@Test(.enabled(if: …))`.
  public static func isAvailable() -> Bool {
    if let env = ProcessInfo.processInfo.environment["FORCE_IPV6_TESTS"], env == "1" {
      return true
    }
    if let env = ProcessInfo.processInfo.environment["SKIP_IPV6_TESTS"], env == "1" {
      return false
    }
    lock.lock()
    if let c = cached {
      lock.unlock()
      return c
    }
    lock.unlock()
    let result = probe()
    lock.lock()
    cached = result
    lock.unlock()
    return result
  }

  /// Logs a one-line skip message when called from a test that gated on `isAvailable`.
  public static func logSkip(_ testName: String) {
    print("⏭️ Skipping \(testName): no routable IPv6 detected on this host")
  }

  private static func probe() -> Bool {
    let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    // Non-blocking so we can bound the probe duration.
    let flags = fcntl(fd, F_GETFL, 0)
    if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }

    var sin6 = sockaddr_in6()
    sin6.sin6_family = sa_family_t(AF_INET6)
    sin6.sin6_port = UInt16(443).bigEndian
    guard inet_pton(AF_INET6, "2606:4700:4700::1111", &sin6.sin6_addr) == 1 else {
      return false
    }

    let connectResult = withUnsafePointer(to: &sin6) { ptr -> Int32 in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
      }
    }

    // UDP connect typically returns 0 immediately if the kernel has a route. If
    // it returns -1 with EINPROGRESS, wait briefly with poll. Any other error means
    // no route, no source address, or some other v6 blocker.
    if connectResult == 0 { return true }
    if errno != EINPROGRESS { return false }

    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    let pollResult = poll(&pfd, 1, 500)  // 500ms
    guard pollResult > 0, (pfd.revents & Int16(POLLOUT)) != 0 else { return false }

    var soerr: Int32 = 0
    var solen = socklen_t(MemoryLayout<Int32>.size)
    if getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &solen) < 0 { return false }
    return soerr == 0
  }
}
