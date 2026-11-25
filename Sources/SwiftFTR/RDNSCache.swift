import Foundation

/// Actor-based cache for reverse DNS lookups with TTL and size-bounded eviction.
///
/// Each lookup is a PTR query through the system's DNS daemon (``ReverseDNSLookup``), which holds
/// no thread while it waits and ends at its deadline. Only answers are
/// cached: "no such record" cannot be told apart from a question the daemon suppressed, and a
/// timeout, an error or a cancellation says nothing about the name, so an address without one is
/// asked again by the next lookup, with one exception: an address whose question was asked and
/// timed out is held off for ``stalledAddressHoldoff`` (see there).
///
/// Lookups of one address share one query (David, 2026-11-24: "Build share lookups"): a lookup
/// that arrives while a query for its address is in flight awaits that query, so every address
/// has at most one query at a time, taking one permit, and the query's one outcome is applied to
/// the cache, the breaker and the holdoffs once, whoever is still waiting for it. A query is
/// never cancelled because a caller left: it is bounded by its own timeout, and its outcome is
/// true evidence about the address. A caller cancelled before it calls ``lookup(_:)`` starts and
/// joins nothing; one cancelled while it waits gets `nil` when the query ends, so a caller that
/// must be released at once races the wait itself, as the traces do with `withTraceCancellation`.
///
/// One identity, one write rule (David, 2026-11-24: "Let's go with one identity, one write
/// rule"). A lookup's identity is the ``ReverseDNSQuestion`` built once from the caller's string:
/// it keys the sharing, the answer cache, the holdoffs and the stall run, says whether the address
/// is global, and is the question the resolver is asked, on the interface it captured. So an IPv4
/// address and its IPv4-mapped spelling, or two spellings of one IPv6 address, are one address,
/// and a link-local address keeps its zone's interface. A string that is not an address literal
/// has no question: its lookup returns `nil` at once, asks nothing and records nothing. A query
/// writes (an answer, a holdoff, a stall, a reset of the count) only if it is still the current
/// query for its key when it ends; ``clear()`` and ``invalidateNetworkScoped()`` drop every query
/// in flight, so one from before a reset writes nothing, and its waiters get `nil`.
///
/// When an insertion takes the cache past `maxSize`, the entry stored longest ago is evicted; a
/// cache hit does not refresh an entry, so this is insertion-order eviction, not
/// least-recently-used.
actor RDNSCache {
  /// One lookup of `question`, allowed `timeout` seconds from the call, including any wait for a
  /// permit. It must return by then: the cache does not race it against a timer of its own.
  typealias Resolver =
    @Sendable (_ question: ReverseDNSQuestion, _ timeout: TimeInterval) async ->
    ReverseDNSLookupOutcome

  private struct CacheEntry {
    let hostname: String
    let timestamp: ContinuousClock.Instant
    /// Whether the address is globally routable, so ``invalidateNetworkScoped()`` keeps it.
    let isGlobal: Bool
  }

  /// The query in flight for one address key. Its task returns the hostname it wrote, if any.
  private struct InFlight {
    let id: UInt64
    let task: Task<String?, Never>
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
  /// David, 2026-11-24: "10 minutes is a reasonable in-memory cache of no response for a reverse DNS lookup". Only answers are cached, so
  /// without it a hop whose PTR query always times out costs the whole lookup budget on every
  /// trace: a hop that answers "no such record" in the same wave resets the stall count each
  /// time, so the breaker never opens. During the holdoff a lookup of the address returns `nil`
  /// at once, asks nothing, and neither counts toward nor resets the breaker. A holdoff is not a
  /// cached answer. ``clear()`` and ``invalidateNetworkScoped()`` drop every one, since a network
  /// change may have fixed the resolver. Once the holdoff ends the address is asked again, unless
  /// the breaker is open: that stays open until a reset.
  static let stalledAddressHoldoff: Duration = .seconds(600)

  private var cache: [String: CacheEntry] = [:]
  private let ttl: Duration
  private let maxSize: Int
  private let resolver: Resolver
  private let lookupDeadline: TimeInterval
  private let linkLocalLookupDeadline: TimeInterval
  private var consecutiveStalls = 0
  /// The addresses counted in the current run of stalls: each counts once, so an address asked
  /// again in the same run, after its holdoff ended or was evicted, cannot open the breaker by
  /// itself. Proposed by an agent, not yet confirmed by David (2026-11-24).
  private var stalledInStreak: Set<String> = []
  /// When each held-off address timed out. Bounded by `maxSize`, oldest inserted evicted first.
  private var holdoffs: [String: ContinuousClock.Instant] = [:]
  /// The query in flight for each address key, which a new lookup of it awaits. Removed when it
  /// ends, or on a reset, so a lookup after a reset starts a fresh one.
  private var inFlight: [String: InFlight] = [:]
  private var nextQueryID: UInt64 = 0
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
      ?? { question, timeout in
        await ReverseDNSLookup.lookup(question, timeout: timeout, limiter: limiter)
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
  /// - Returns: The hostname if one was found, nil otherwise, and nil for a cancelled caller.
  func lookup(_ ip: String) async -> String? {
    // A caller cancelled already starts nothing and joins nothing.
    guard !Task.isCancelled, let question = ReverseDNSQuestion(address: ip) else { return nil }
    let key = question.key
    let now = self.now()

    if let entry = cache[key], now < entry.timestamp + ttl {
      return entry.hostname
    }

    let task: Task<String?, Never>
    if let running = inFlight[key] {
      // The breaker and the holdoff stop a query from starting, not a lookup from joining one.
      task = running.task
    } else {
      // Asked recently and unanswered: not asked again until the holdoff passes.
      if let since = holdoffs[key] {
        if now < since + Self.stalledAddressHoldoff { return nil }
        holdoffs.removeValue(forKey: key)
      }
      // Lookups keep stalling, so skip the wait and report numerically until the breaker resets.
      guard !isSuppressingLookups else { return nil }
      task = startQuery(question)
    }

    awaiting += 1
    let hostname = await task.value
    awaiting -= 1
    return Task.isCancelled ? nil : hostname
  }

  /// Starts the one query for `question`. Its timeout depends only on the question and this
  /// cache's settings, so it is the timeout any lookup awaiting it would have had.
  private func startQuery(_ question: ReverseDNSQuestion) -> Task<String?, Never> {
    let timeout =
      question.isMulticast ? min(linkLocalLookupDeadline, lookupDeadline) : lookupDeadline
    let resolver = self.resolver
    let id = nextQueryID
    nextQueryID &+= 1
    let task = Task {
      let outcome = await resolver(question, timeout)
      return self.finish(question, id: id, outcome: outcome)
    }
    inFlight[question.key] = InFlight(id: id, task: task)
    return task
  }

  /// Applies a query's one outcome, if it is still the current query for its key, and returns
  /// the hostname it wrote. One that a reset dropped writes nothing and returns `nil`.
  private func finish(_ question: ReverseDNSQuestion, id: UInt64, outcome: ReverseDNSLookupOutcome)
    -> String?
  {
    let key = question.key
    guard inFlight[key]?.id == id else { return nil }
    inFlight.removeValue(forKey: key)

    // A multicast question is no evidence about the resolver either way, but an unanswered one
    // is held off like any other.
    switch outcome {
    case .timedOut:
      holdOff(key, since: now())
      // Asked and unanswered: the resolver is stalled.
      if !question.isMulticast, stalledInStreak.insert(key).inserted { consecutiveStalls += 1 }
    case .answer, .noSuchRecord:
      // The resolver answered.
      if !question.isMulticast { resetStalls() }
    case .timedOutBeforeQuery, .error, .cancelled:
      // Never asked, or failed without waiting on the resolver.
      break
    }

    guard case .answer(let name) = outcome else { return nil }
    cache[key] = CacheEntry(hostname: name, timestamp: now(), isGlobal: question.isGlobal)
    if cache.count > maxSize { evictOldest() }
    return name
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

  /// Forgets every query in flight and cancels it, so a request from before a reset neither
  /// goes out afterwards nor keeps a lookup slot from the new network's questions.
  private func dropInFlight() {
    for query in inFlight.values { query.task.cancel() }
    inFlight.removeAll()
  }

  /// Clear all cached entries.
  func clear() {
    cache.removeAll()
    holdoffs.removeAll()
    dropInFlight()
    resetStalls()
  }

  /// Invalidate network-scoped (non-global) rDNS cache entries and reset the stall breaker.
  ///
  /// Evicts cached rDNS entries whose address is not globally routable (RFC 1918 private, CGNAT,
  /// link-local, loopback, ULA). Preserves globally routable entries and their TTLs. Every query
  /// in flight is dropped, global ones included, so none writes and their waiters get `nil`; a
  /// global address looked up just before is asked again afterwards. Every holdoff is dropped
  /// too: a timeout says something about the path to a resolver, which the change may have fixed.
  func invalidateNetworkScoped() {
    cache = cache.filter { _, entry in entry.isGlobal }
    holdoffs.removeAll()
    dropInFlight()
    resetStalls()
  }

  /// Addresses currently held off, expired or not, for tests.
  var holdoffCount: Int { holdoffs.count }

  /// Queries in flight, for tests.
  var inFlightCount: Int { inFlight.count }

  /// Lookups awaiting a query, for tests: they can tell when every lookup has joined.
  private(set) var awaiting = 0

  private func resetStalls() {
    consecutiveStalls = 0
    stalledInStreak.removeAll()
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
