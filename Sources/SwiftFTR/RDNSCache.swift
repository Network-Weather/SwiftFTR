import Foundation

/// Actor-based cache for reverse DNS lookups with TTL and LRU eviction.
///
/// This cache provides thread-safe storage for hostname lookups with automatic
/// expiration and size-based eviction. It uses Swift 6.1's actor isolation for
/// thread safety and the Clock API for accurate timing.
actor RDNSCache {
  typealias Resolver = @Sendable (String) async -> String?

  private struct CacheEntry {
    let hostname: String?
    let timestamp: ContinuousClock.Instant
  }

  /// How long a single reverse lookup may take before the caller stops waiting for it.
  ///
  /// `getnameinfo` consults the system resolver and holds its worker for 30 seconds when DNS
  /// queries go unanswered, against a healthy-network cost of a few milliseconds. Hostnames are
  /// cosmetic enrichment, so a trace degrades to numeric addresses rather than waiting.
  ///
  /// Sized generously because ``batchLookup(_:)`` issues lookups concurrently: this bounds the
  /// reverse-DNS phase as a whole rather than being paid once per hop. Links with legitimately
  /// slow resolvers should not lose hostnames, so the budget favors them over shaving a failure
  /// case that the circuit breaker already handles after two stalls.
  /// Callers override it with `SwiftFTRConfig.rdnsLookupTimeout`.
  static let lookupDeadline: TimeInterval = SwiftFTRConfig.defaultRDNSLookupTimeout

  /// Consecutive stalled lookups after which the cache stops attempting reverse DNS.
  ///
  /// Without this, every trace re-pays ``lookupDeadline`` per hop while the resolver stays broken.
  /// The breaker resets in ``clear()``, which callers invoke on a network change — the event most
  /// likely to have fixed the resolver.
  static let stallsBeforeSuppressing = 2

  private var cache: [String: CacheEntry] = [:]
  private let ttl: Duration
  private let maxSize: Int
  private let clock = ContinuousClock()
  private let resolver: Resolver
  private let lookupDeadline: TimeInterval
  private var scopedGeneration: UInt64 = 0
  private var globalGeneration: UInt64 = 0
  private var consecutiveStalls = 0

  /// Initialize a new rDNS cache.
  /// - Parameters:
  ///   - ttl: Time to live for cache entries in seconds (default: 86400 = 1 day)
  ///   - maxSize: Maximum number of entries to cache (default: 1000)
  ///   - lookupDeadline: Seconds a single lookup may take before it counts as stalled.
  init(
    ttl: TimeInterval = 86400,
    maxSize: Int = 1000,
    lookupDeadline: TimeInterval = RDNSCache.lookupDeadline,
    resolver: Resolver? = nil
  ) {
    self.ttl = .seconds(ttl)
    self.maxSize = maxSize
    self.lookupDeadline = lookupDeadline
    self.resolver =
      resolver
      ?? { ip in
        // `.background` keeps reverse DNS behind probe and ASN work on the shared executor. The
        // deadline is what bounds the caller, so queue position cannot extend a trace.
        try? await runDetachedBlockingIO(priority: .background, deadline: lookupDeadline) {
          reverseDNS(ip)
        }
      }
  }

  /// Whether reverse DNS is currently suppressed because lookups keep stalling.
  var isSuppressingLookups: Bool {
    consecutiveStalls >= Self.stallsBeforeSuppressing
  }

  /// Look up a hostname for an IP address, using cache if available.
  /// - Parameter ip: The IP address to resolve
  /// - Returns: The hostname if found, nil otherwise
  func lookup(_ ip: String) async -> String? {
    let now = clock.now

    // Check cache first
    if let entry = cache[ip], now < entry.timestamp + ttl {
      return entry.hostname
    }

    // Lookups keep stalling, so skip the wait and report numerically until `clear()` reopens.
    guard !isSuppressingLookups else { return nil }

    let isScoped = ipAddressScope(of: ip) != .global
    let lookupGeneration = isScoped ? scopedGeneration : globalGeneration
    let startedAt = clock.now
    let hostname = await resolver(ip)
    let elapsed = startedAt.duration(to: clock.now)

    // A lookup that consumed its whole budget did not answer; it timed out or was starved. Track
    // that separately from a resolver that answered "no such name", which is a normal fast result.
    if elapsed >= .seconds(lookupDeadline * 0.9) {
      consecutiveStalls += 1
    } else {
      consecutiveStalls = 0
    }

    // A result from an invalidated network generation must neither escape to the caller nor
    // repopulate the newly invalidated cache. Network-scoped invalidation rejects in-flight
    // scoped lookups while allowing global lookups to finish; clear() rejects both.
    let currentGeneration = isScoped ? scopedGeneration : globalGeneration
    guard lookupGeneration == currentGeneration else { return nil }

    // Cache the result
    cache[ip] = CacheEntry(hostname: hostname, timestamp: clock.now)

    // Evict oldest entry if cache is too large
    if cache.count > maxSize {
      evictOldest()
    }

    return hostname
  }

  /// Batch lookup multiple IP addresses concurrently.
  /// - Parameter ips: Array of IP addresses to resolve
  /// - Returns: Dictionary mapping IP addresses to hostnames (only successful lookups included)
  func batchLookup(_ ips: [String]) async -> [String: String] {
    await withTaskGroup(of: (String, String?).self) { group in
      for ip in ips {
        group.addTask {
          await (ip, self.lookup(ip))
        }
      }

      var results: [String: String] = [:]
      for await (ip, hostname) in group {
        if let hostname = hostname {
          results[ip] = hostname
        }
      }
      return results
    }
  }

  /// Clear all cached entries.
  func clear() {
    scopedGeneration &+= 1
    globalGeneration &+= 1
    cache.removeAll()
    consecutiveStalls = 0
  }

  /// Invalidate network-scoped (non-global) rDNS cache entries and reset the stall breaker.
  ///
  /// Evicts cached rDNS entries (positive and negative) whose address is not globally routable
  /// (RFC 1918 private, CGNAT, link-local, loopback, ULA). Preserves globally routable entries
  /// and their TTLs. In-flight lookups for scoped addresses are discarded, while in-flight
  /// global lookups continue to complete and cache normally.
  func invalidateNetworkScoped() {
    scopedGeneration &+= 1
    cache = cache.filter { ip, _ in ipAddressScope(of: ip) == .global }
    consecutiveStalls = 0
  }

  /// Get the current number of cached entries.
  var count: Int {
    cache.count
  }

  /// Remove expired entries from the cache.
  func pruneExpired() {
    let now = clock.now
    cache = cache.filter { _, entry in
      now < entry.timestamp + ttl
    }
  }

  private func evictOldest() {
    if let oldest = cache.min(by: { $0.value.timestamp < $1.value.timestamp }) {
      cache.removeValue(forKey: oldest.key)
    }
  }
}
