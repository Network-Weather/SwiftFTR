import Foundation

/// ASN resolver that tries local database first, falls back to DNS for missing IPs.
///
/// This resolver provides the best of both worlds:
/// - Fast (~10μs) lookups for IPs in the local database
/// - DNS fallback for very recently allocated IPs not yet in the database
///
/// Usage:
/// ```swift
/// let resolver = HybridASNResolver(source: .embedded, fallbackTimeout: 1.0)
/// ```
public struct HybridASNResolver: ASNResolver, PublishingASNResolver, Sendable {
  private let localResolver: LocalASNResolver
  private let dnsResolver: CachingASNResolver
  private let fallbackTimeout: TimeInterval

  public init(source: LocalASNSource, fallbackTimeout: TimeInterval = 1.0) {
    self.init(
      local: LocalASNResolver(source: source), dns: CachingASNResolver(base: CymruDNSResolver()),
      fallbackTimeout: fallbackTimeout)
  }

  /// A resolver on `local` and `dns`. Tests substitute both.
  init(local: LocalASNResolver, dns: CachingASNResolver, fallbackTimeout: TimeInterval) {
    self.localResolver = local
    self.dnsResolver = dns
    self.fallbackTimeout = fallbackTimeout
  }

  /// Preload the local database for faster first lookups.
  public func preload() async {
    await localResolver.preload()
  }

  /// Resolves from the local database, then asks DNS for the addresses it lacks.
  ///
  /// - Parameters:
  ///   - ipv4Addrs: IP addresses to resolve; only globally routable ones are looked up.
  ///   - timeout: Bounds the whole call: the wait for a database that is still loading, then the
  ///     DNS fallback, which also ends `fallbackTimeout` seconds after it starts and is not
  ///     started once `timeout` has run out. An AS number whose name the fallback had not
  ///     learned in time has an empty name.
  #if compiler(>=6.2)
    @concurrent
  #endif
  public func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo]
  {
    try await resolve(
      ipv4Addrs, timeout: timeout, deadline: asnDeadline(timeout), publish: { _ in })
  }

  func resolve(
    _ addresses: [String], timeout: TimeInterval, deadline: TimeInterval,
    publish: @escaping ASNPublish
  ) async throws -> [String: ASNInfo] {
    // Filter and deduplicate input
    let publicIPs = Set(addresses).filter(isGloballyRoutableIPAddress)
    guard !publicIPs.isEmpty else { return [:] }

    // Try local first; its answers are published before the fallback starts.
    var merged =
      (try? await localResolver.resolve(
        Array(publicIPs), timeout: timeout, deadline: deadline, publish: publish)) ?? [:]
    let missingIPs = publicIPs.subtracting(merged.keys)

    // Fall back to DNS for missing IPs. The cache answers what it holds even past the deadline;
    // a new flight, keyed by `fallbackTimeout` so that concurrent fallbacks share it, runs for
    // `fallbackTimeout` whoever starts it, and this caller waits for it until its own deadline.
    guard !missingIPs.isEmpty else { return merged }
    let dnsResults = try? await dnsResolver.resolve(
      Array(missingIPs), timeout: fallbackTimeout, deadline: deadline, publish: publish)

    // Merge results (local takes precedence)
    for (k, v) in dnsResults ?? [:] where merged[k] == nil {
      merged[k] = v
    }
    return merged
  }
}
