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

  /// Preload the local database for faster first lookups.
  public func preload() async {
    await localResolver.preload()
  }

  #if compiler(>=6.2)
    @concurrent
  #endif
  public func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo]
  {
    // Filter and deduplicate input
    let publicIPs = Set(ipv4Addrs)
      .filter { !$0.isEmpty && !isPrivateIPv4($0) && !isCGNATIPv4($0) }
    guard !publicIPs.isEmpty else { return [:] }

    // Try local first
    let localResults = try? await localResolver.resolve(
      ipv4Addrs: Array(publicIPs), timeout: timeout)

    // Find missing IPs
    let resolvedIPs: Set<String>
    if let keys = localResults?.keys {
      resolvedIPs = Set(keys)
    } else {
      resolvedIPs = []
    }
    let missingIPs = publicIPs.filter { !resolvedIPs.contains($0) }

    guard !missingIPs.isEmpty else {
      return localResults ?? [:]
    }

    // Fall back to DNS for missing IPs
    let dnsResults = try? await dnsResolver.resolve(
      ipv4Addrs: Array(missingIPs), timeout: fallbackTimeout)

    // Merge results (local takes precedence)
    var merged = localResults ?? [:]
    if let dns = dnsResults {
      for (k, v) in dns where merged[k] == nil {
        merged[k] = v
      }
    }
    return merged
  }
}
