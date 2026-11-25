import Foundation

/// Actor-based cache for reverse DNS lookups with TTL and size-bounded eviction.
///
/// Each lookup is a PTR query through the system's DNS daemon (``ReverseDNSLookup``), which holds
/// no thread while it waits and is stopped when its caller stops waiting. Only answers are
/// cached: "no such record" cannot be told apart from a question the daemon suppressed, and a
/// timeout, an error or a cancellation says nothing about the name, so an address without one is
/// asked again by the next lookup, with one exception: an address whose question was asked and
/// timed out is held off for ``stalledAddressHoldoff`` (see there).
///
/// When an insertion takes the cache past `maxSize`, the entry stored longest ago is evicted; a
/// cache hit does not refresh an entry, so this is insertion-order eviction, not
/// least-recently-used.
actor RDNSCache {
  /// One lookup of `address`, allowed `timeout` seconds from the call, including any wait for a
  /// permit. It must return by then: the cache does not race it against a timer of its own.
  typealias Resolver =
    @Sendable (_ address: String, _ timeout: TimeInterval) async -> ReverseDNSLookupOutcome

  private struct CacheEntry {
    let hostname: String
    let timestamp: ContinuousClock.Instant
  }

  /// How long a single reverse lookup may take before the caller stops waiting for it.
  ///
  /// Hostnames are cosmetic enrichment, so a trace degrades to numeric addresses rather than
  /// waiting. Sized generously because ``batchLookup(_:)`` issues lookups concurrently: this
  /// bounds the reverse-DNS phase as a whole rather than being paid once per hop. Links with
  /// legitimately slow resolvers should not lose hostnames, so the budget favors them over
  /// shaving a failure case that the stall breaker already handles after two stalls.
  /// Callers override it with `SwiftFTRConfig.rdnsLookupTimeout`.
  static let lookupDeadline: TimeInterval = SwiftFTRConfig.defaultRDNSLookupTimeout

  /// How long a lookup of a link-local address (fe80::/10, 169.254.0.0/16) may take, when that is
  /// shorter than the lookup deadline.
  ///
  /// The daemon asks these by multicast DNS on the link, and multicast never answers "no such
  /// name", so a lookup of an address whose owner advertises no name runs until its deadline.
  /// Without a cap of its own every IPv6 trace whose first hop has no name would wait out the
  /// whole budget. A proposed value: on one home network four neighbors that advertise a name
  /// answered a cold query in 330 to 360 ms, and five others never answered.
  static let linkLocalLookupDeadline: TimeInterval = 1.0

  /// Consecutive stalled lookups after which the cache stops attempting reverse DNS.
  ///
  /// A stall is a unicast question that was asked and got no answer by its deadline
  /// (``ReverseDNSLookupOutcome/timedOut``). Without the breaker, every trace re-pays
  /// ``lookupDeadline`` while the resolver stays broken. The breaker resets in ``clear()`` and
  /// ``invalidateNetworkScoped()``, which callers invoke on a network change, the event most
  /// likely to have fixed the resolver.
  static let stallsBeforeSuppressing = 2

  /// How long an address whose question was asked and got no answer by its deadline
  /// (``ReverseDNSLookupOutcome/timedOut``, unicast or link-local) is not asked again.
  ///
  /// Proposed by an agent, not yet confirmed by David (2026-11-24). Only answers are cached, so
  /// without it a hop whose PTR query always times out costs the whole lookup budget on every
  /// trace: a hop that answers "no such record" in the same wave resets the stall count each
  /// time, so the breaker never opens. During the holdoff a lookup of the address returns `nil`
  /// at once, asks nothing, and neither counts toward nor resets the breaker. A holdoff is not a
  /// cached answer, and ``clear()`` and ``invalidateNetworkScoped()`` drop every one, since a
  /// network change may have fixed the resolver.
  static let stalledAddressHoldoff: Duration = .seconds(600)

  private var cache: [String: CacheEntry] = [:]
  private let ttl: Duration
  private let maxSize: Int
  private let resolver: Resolver
  private let lookupDeadline: TimeInterval
  private let linkLocalLookupDeadline: TimeInterval
  private var scopedGeneration: UInt64 = 0
  private var globalGeneration: UInt64 = 0
  private var breakerGeneration: UInt64 = 0
  private var consecutiveStalls = 0
  /// The addresses counted in the current run of stalls: each counts once, so many lookups of one
  /// address in flight together (multipath flows sharing a hop) cannot open the breaker alone.
  private var stalledInStreak: Set<String> = []
  /// When each held-off address timed out. Bounded by `maxSize`, oldest inserted evicted first.
  private var holdoffs: [String: ContinuousClock.Instant] = [:]
  /// When the resolver last responded (an answer or "no such record") about each address, so a
  /// timeout for a question asked before then is recognised as contradicted. Bounded like
  /// `holdoffs`.
  private var lastResponse: [String: ContinuousClock.Instant] = [:]
  private let now: @Sendable () -> ContinuousClock.Instant

  /// Initialize a new rDNS cache.
  /// - Parameters:
  ///   - ttl: Time to live for cache entries in seconds (default: 86400 = 1 day)
  ///   - maxSize: Maximum number of entries to cache (default: 1000)
  ///   - lookupDeadline: Seconds a single lookup may take.
  ///   - linkLocalLookupDeadline: Seconds a lookup of a link-local address may take, when shorter
  ///     than `lookupDeadline`.
  ///   - limiter: Bounds the lookups in flight; by default one limiter shared by the process.
  ///   - resolver: Replaces the lookup through the system daemon, for tests.
  ///   - now: The monotonic clock entries and holdoffs expire by; tests substitute their own.
  init(
    ttl: TimeInterval = 86400,
    maxSize: Int = 1000,
    lookupDeadline: TimeInterval = RDNSCache.lookupDeadline,
    linkLocalLookupDeadline: TimeInterval = RDNSCache.linkLocalLookupDeadline,
    limiter: _ConcurrencySemaphore = ReverseDNSLookup.sharedLimiter,
    resolver: Resolver? = nil,
    now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) {
    self.now = now
    self.ttl = .seconds(ttl)
    self.maxSize = maxSize
    self.lookupDeadline = lookupDeadline
    self.linkLocalLookupDeadline = linkLocalLookupDeadline
    self.resolver =
      resolver
      ?? { address, timeout in
        await ReverseDNSLookup.lookup(address, timeout: timeout, limiter: limiter)
      }
  }

  /// Stalls counted since the breaker last reset, for tests.
  var stallCount: Int { consecutiveStalls }

  /// Whether reverse DNS is currently suppressed because lookups keep stalling.
  var isSuppressingLookups: Bool {
    consecutiveStalls >= Self.stallsBeforeSuppressing
  }

  /// Look up a hostname for an IP address, using cache if available.
  /// - Parameter ip: The IP address to resolve, with a zone if it has one.
  /// - Returns: The hostname if one was found, nil otherwise
  func lookup(_ ip: String) async -> String? {
    let now = self.now()

    // Check cache first
    if let entry = cache[ip], now < entry.timestamp + ttl {
      return entry.hostname
    }

    // Asked recently and unanswered: not asked again until the holdoff passes.
    if let since = holdoffs[ip] {
      if now < since + Self.stalledAddressHoldoff { return nil }
      holdoffs.removeValue(forKey: ip)
    }

    // Lookups keep stalling, so skip the wait and report numerically until the breaker resets.
    guard !isSuppressingLookups else { return nil }

    let isMulticast = ReverseDNSQuestion(address: ip)?.isMulticast ?? false
    let timeout = isMulticast ? min(linkLocalLookupDeadline, lookupDeadline) : lookupDeadline
    let isScoped = ipAddressScope(of: ip) != .global
    let lookupGeneration = isScoped ? scopedGeneration : globalGeneration
    let lookupBreakerGeneration = breakerGeneration
    let outcome = await resolver(ip, timeout)

    // A lookup whose caller cancelled says nothing about the name or the resolver, whatever
    // outcome it reports: recording it could trip the breaker on lookups nobody waited for.
    guard !Task.isCancelled else { return nil }

    // Only lookups initiated under the current breaker generation may update breaker state or
    // hold an address off. Stale lookups from a prior network generation must not re-trip or
    // reset the breaker on the new network. A multicast question is no evidence about the
    // resolver either way, but an unanswered one is held off like any other.
    if lookupBreakerGeneration == breakerGeneration {
      // A timeout for a question asked before the resolver last responded about this address
      // (another lookup of it, in flight at the same time) is contradicted: the resolver did
      // respond, so it neither holds the address off nor counts as a stall.
      let contradicted =
        outcome == .timedOut && lastResponse[ip].map { $0 >= now } == true
      switch outcome {
      case .timedOut where !contradicted:
        holdOff(ip, since: self.now())
      case .answer, .noSuchRecord:
        // A response ends any holdoff a concurrent lookup's timeout set, and contradicts a
        // timeout still to come for a question asked before it.
        holdoffs.removeValue(forKey: ip)
        recordResponse(ip, at: self.now())
      default:
        break
      }
      if !isMulticast {
        switch outcome {
        case .timedOut:
          // Asked and unanswered: the resolver is stalled. Once per address per run of stalls.
          if !contradicted, stalledInStreak.insert(ip).inserted { consecutiveStalls += 1 }
        case .answer, .noSuchRecord:
          // The resolver answered.
          resetStalls()
        case .timedOutBeforeQuery, .error, .cancelled:
          // Never asked, or failed without waiting on the resolver.
          break
        }
      }
    }

    // A result from an invalidated network generation must neither escape to the caller nor
    // repopulate the newly invalidated cache. Network-scoped invalidation rejects in-flight
    // scoped lookups while allowing global lookups to finish; clear() rejects both.
    let currentGeneration = isScoped ? scopedGeneration : globalGeneration
    guard lookupGeneration == currentGeneration else { return nil }

    guard case .answer(let hostname) = outcome else { return nil }
    cache[ip] = CacheEntry(hostname: hostname, timestamp: self.now())

    // Evict oldest entry if cache is too large
    if cache.count > maxSize {
      evictOldest()
    }

    return hostname
  }

  /// Batch lookup multiple IP addresses concurrently, each distinct address once.
  /// - Parameter ips: Array of IP addresses to resolve; an address listed more than once (one
  ///   router answering at several TTLs) is asked once, so it costs one lookup and one stall.
  /// - Returns: Dictionary mapping IP addresses to hostnames (only successful lookups included)
  func batchLookup(_ ips: [String]) async -> [String: String] {
    await withTaskGroup(of: (String, String?).self) { group in
      for ip in Set(ips) {
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
    breakerGeneration &+= 1
    cache.removeAll()
    holdoffs.removeAll()
    lastResponse.removeAll()
    resetStalls()
  }

  /// Invalidate network-scoped (non-global) rDNS cache entries and reset the stall breaker.
  ///
  /// Evicts cached rDNS entries whose address is not globally routable (RFC 1918 private, CGNAT,
  /// link-local, loopback, ULA). Preserves globally routable entries and their TTLs. In-flight
  /// lookups for scoped addresses are discarded, while in-flight global lookups continue to
  /// complete and cache normally. Every holdoff is dropped, global ones included: a timeout says
  /// something about the path to a resolver, which the network change may have fixed.
  func invalidateNetworkScoped() {
    scopedGeneration &+= 1
    breakerGeneration &+= 1
    cache = cache.filter { ip, _ in ipAddressScope(of: ip) == .global }
    holdoffs.removeAll()
    lastResponse.removeAll()
    resetStalls()
  }

  /// Addresses currently held off, expired or not, for tests.
  var holdoffCount: Int { holdoffs.count }

  /// Addresses with a recorded response, for tests.
  var responseRecordCount: Int { lastResponse.count }

  private func resetStalls() {
    consecutiveStalls = 0
    stalledInStreak.removeAll()
  }

  private func recordResponse(_ ip: String, at instant: ContinuousClock.Instant) {
    lastResponse[ip] = instant
    if lastResponse.count > maxSize, let oldest = lastResponse.min(by: { $0.value < $1.value }) {
      lastResponse.removeValue(forKey: oldest.key)
    }
  }

  private func holdOff(_ ip: String, since: ContinuousClock.Instant) {
    holdoffs[ip] = since
    if holdoffs.count > maxSize, let oldest = holdoffs.min(by: { $0.value < $1.value }) {
      holdoffs.removeValue(forKey: oldest.key)
    }
  }

  /// Get the current number of cached entries.
  var count: Int {
    cache.count
  }

  /// Remove expired entries from the cache.
  func pruneExpired() {
    let now = self.now()
    cache = cache.filter { _, entry in
      now < entry.timestamp + ttl
    }
    holdoffs = holdoffs.filter { _, since in now < since + Self.stalledAddressHoldoff }
  }

  private func evictOldest() {
    if let oldest = cache.min(by: { $0.value.timestamp < $1.value.timestamp }) {
      cache.removeValue(forKey: oldest.key)
    }
  }
}
