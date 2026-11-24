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
public struct HybridASNResolver: ASNResolver, Sendable {
  private let localResolver: LocalASNResolver
  private let dnsResolver: ASNResolver
  private let fallbackTimeout: TimeInterval

  public init(source: LocalASNSource, fallbackTimeout: TimeInterval = 1.0) {
    self.localResolver = LocalASNResolver(source: source)
    self.dnsResolver = CachingASNResolver(base: CymruDNSResolver())
    self.fallbackTimeout = fallbackTimeout
  }

  /// A resolver over `local` and `dns`. Tests pass a local resolver with its own store and a DNS
  /// resolver that records what it is asked.
  init(local: LocalASNResolver, dns: ASNResolver, fallbackTimeout: TimeInterval) {
    self.localResolver = local
    self.dnsResolver = dns
    self.fallbackTimeout = fallbackTimeout
  }

  /// Preload the local database for faster first lookups.
  public func preload() async {
    await localResolver.preload()
  }

  /// Resolves `ipv4Addrs` from the local database, then asks DNS for the addresses it lacks.
  ///
  /// `timeout` bounds the whole call: a database still loading is waited for only until it runs
  /// out, and the DNS fallback gets `fallbackTimeout` or the time left, whichever is shorter (none
  /// once it has run out). A value that is not finite and positive sets no bound, and the fallback
  /// gets `fallbackTimeout`.
  #if compiler(>=6.2)
    @concurrent
  #endif
  public func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo]
  {
    let deadline = asnDeadline(after: timeout)

    // Filter and deduplicate input
    let publicIPs = Set(ipv4Addrs)
      .filter(isGloballyRoutableIPAddress)
    guard !publicIPs.isEmpty else { return [:] }

    // Try local first
    let localResults = try? await localResolver.resolve(
      ipv4Addrs: Array(publicIPs), until: deadline)

    // Find missing IPs
    let resolvedIPs: Set<String>
    if let keys = localResults?.keys {
      resolvedIPs = Set(keys)
    } else {
      resolvedIPs = []
    }
    let missingIPs = publicIPs.filter { !resolvedIPs.contains($0) }

    guard !missingIPs.isEmpty, let dnsTimeout = fallbackTimeout(before: deadline) else {
      return localResults ?? [:]
    }

    // Fall back to DNS for missing IPs
    let dnsResults = try? await dnsResolver.resolve(
      ipv4Addrs: Array(missingIPs), timeout: dnsTimeout)

    // Merge results (local takes precedence)
    var merged = localResults ?? [:]
    if let dns = dnsResults {
      for (k, v) in dns where merged[k] == nil {
        merged[k] = v
      }
    }
    return merged
  }

  /// The DNS fallback's timeout: `fallbackTimeout`, cut to the time left before `deadline`, or
  /// `nil` when none is left. Kept exact when there is time to spare, so concurrent lookups of one
  /// address share a cached flight, which is keyed by timeout.
  private func fallbackTimeout(before deadline: ContinuousClock.Instant?) -> TimeInterval? {
    guard let deadline else { return fallbackTimeout }
    let left = secondsUntil(deadline)
    guard left > 0 else { return nil }
    return left < fallbackTimeout ? left : fallbackTimeout
  }
}
