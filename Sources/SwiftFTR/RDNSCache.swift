import Foundation

/// Actor-based cache for reverse DNS lookups with TTL and LRU eviction.
///
/// This cache provides thread-safe storage for hostname lookups with automatic
/// expiration and size-based eviction. It uses Swift 6.1's actor isolation for
/// thread safety and the Clock API for accurate timing.
actor RDNSCache {
  private struct CacheEntry {
    let hostname: String?
    let timestamp: ContinuousClock.Instant
  }

  private var cache: [String: CacheEntry] = [:]
  private let ttl: Duration
  private let maxSize: Int
  private let clock = ContinuousClock()

  /// Initialize a new rDNS cache.
  /// - Parameters:
  ///   - ttl: Time to live for cache entries in seconds (default: 86400 = 1 day)
  ///   - maxSize: Maximum number of entries to cache (default: 1000)
  init(ttl: TimeInterval = 86400, maxSize: Int = 1000) {
    self.ttl = .seconds(ttl)
    self.maxSize = maxSize
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

    // Perform lookup in background
    let hostname = await Task.detached(priority: .background) {
      reverseDNS(ip)
    }.value

    // Cache the result
    cache[ip] = CacheEntry(hostname: hostname, timestamp: now)

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
    cache.removeAll()
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
