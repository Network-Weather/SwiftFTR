import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// Autonomous System Number (ASN) metadata for an IP address or prefix.
public struct ASNInfo: Sendable, Hashable, Codable {
  public let asn: Int
  public let name: String
  public let prefix: String?
  public let countryCode: String?
  public let registry: String?
  public init(
    asn: Int, name: String, prefix: String? = nil, countryCode: String? = nil,
    registry: String? = nil
  ) {
    self.asn = asn
    self.name = name
    self.prefix = prefix
    self.countryCode = countryCode
    self.registry = registry
  }
}

/// Configuration for ASN resolution strategy.
public enum ASNResolverStrategy: Sendable {
  /// Use DNS-based lookups (Team Cymru). Always current, requires network.
  case dns

  /// Use embedded local database from SwiftIP2ASN package resources.
  /// Fast (~10μs), works offline. The database is loaded once per process and shared by every
  /// resolver that uses it, so additional resolvers cost nothing. One copy is about 15 MB;
  /// the first load takes process footprint to roughly 50 MB, because the decoder's scratch
  /// buffers are retained by the allocator rather than returned to the system.
  case embedded

  /// Use remote database with optional bundled fallback.
  /// - bundledPath: Path to .ultra file bundled with app (offline fallback)
  /// - url: URL to fetch updates (defaults to pkgs.networkweather.com)
  /// Works offline immediately if bundledPath provided, auto-updates when online.
  case remote(bundledPath: String? = nil, url: URL? = nil)

  /// Try local/remote first, fall back to DNS on miss.
  case hybrid(LocalASNSource, fallbackTimeout: TimeInterval = 1.0)
}

/// Source for local ASN database.
public enum LocalASNSource: Sendable {
  /// Bundled in SwiftIP2ASN package resources
  case embedded
  /// App-provided .ultra file path
  case bundled(String)
  /// Remote with optional offline fallback
  case remote(bundledPath: String?, url: URL?)
}

/// Resolves origin ASNs and related metadata for IPv4 addresses.
public protocol ASNResolver: Sendable {
  /// Resolve metadata for the given IPv4 addresses.
  /// - Parameters:
  ///   - ipv4Addrs: IPv4 addresses as dotted-quad strings.
  ///   - timeout: The per-lookup timeout in seconds. DNS-backed resolvers require a finite value
  ///     greater than zero.
  /// - Returns: Map of input IP -> ASNInfo for addresses with public routing data.
  func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo]
}

/// Identity shared by copies of one caching resolver.
private final class _ASNResolverScope: Sendable, Hashable {
  static func == (lhs: _ASNResolverScope, rhs: _ASNResolverScope) -> Bool {
    lhs === rhs
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
}

// Simple in-memory cache for ASN lookups with a soft capacity cap.
actor _ASNMemoryCache {
  private struct LookupKey: Hashable {
    let scope: _ASNResolverScope
    let address: String

    /// Preserve exact timeout identity while keeping dictionary equality reflexive for NaN.
    let timeoutBitPattern: UInt64

    init(scope: _ASNResolverScope, address: String, timeout: TimeInterval) {
      self.scope = scope
      self.address = address
      self.timeoutBitPattern = timeout.bitPattern
    }
  }

  static let shared = _ASNMemoryCache()
  private var map: [String: ASNInfo] = [:]
  private var order: [String] = []
  private var flights: [LookupKey: SharedASNWork<Void>] = [:]
  private var joins: [_ASNResolverScope: Int] = [:]
  private var generation: UInt64 = 0
  private let capacity = 2048

  func getMany(_ keys: [String]) -> [String: ASNInfo] {
    var out: [String: ASNInfo] = [:]
    for k in keys { if let v = map[k] { out[k] = v } }
    return out
  }

  func setMany(_ items: [String: ASNInfo]) {
    for (k, v) in items {
      if map[k] == nil { order.append(k) }
      map[k] = v
    }
    // naive eviction
    if map.count > capacity {
      let over = map.count - capacity
      if over > 0 && over <= order.count {
        let drop = order.prefix(over)
        for k in drop { map.removeValue(forKey: k) }
        order.removeFirst(over)
      }
    }
  }

  /// Returns cached values and coalesces overlapping cache misses into shared flights.
  ///
  /// A flight reserves each `(address, timeout)` key for as long as it runs; a call whose keys
  /// are reserved joins those flights, and starts one flight for the rest, unless `deadline` has
  /// passed. The result is assembled only from the hits read on entry and one snapshot of each
  /// flight, read in a fixed order as its wait ends, so an answer a flight has published (an
  /// origin whose name is still pending included) is returned even when the caller's deadline
  /// ends its wait first. The call throws only when it has no answer and one of its flights
  /// failed (the first such, in that order), or when its task is cancelled. No caller's leaving
  /// stops a flight.
  nonisolated fileprivate func resolve(
    _ addresses: [String],
    timeout: TimeInterval,
    deadline: TimeInterval,
    using resolver: ASNResolver,
    scope: _ASNResolverScope,
    publish: @escaping ASNPublish
  ) async throws -> [String: ASNInfo] {
    try Task.checkCancellation()
    let (hits, flights) = await join(
      addresses, timeout: timeout, deadline: deadline, using: resolver, scope: scope,
      publish: publish)
    if !hits.isEmpty { publish(hits) }
    let wanted = Set(addresses)
    var resolved = hits
    var failure: Error?
    for flight in flights {
      let snapshot = await flight.wait(until: deadline)
      for (address, info) in snapshot.answers where wanted.contains(address) {
        resolved[address] = info
      }
      if failure == nil, case .failure(let error)? = snapshot.outcome { failure = error }
    }
    try Task.checkCancellation()
    if resolved.isEmpty, let failure { throw failure }
    publish(resolved)
    return resolved
  }

  /// The cache hits for `addresses`, and the flights that answer the rest: those already holding
  /// a key, in address order, then a new one for the unreserved addresses if `deadline` has not
  /// passed.
  private func join(
    _ addresses: [String],
    timeout: TimeInterval,
    deadline: TimeInterval,
    using resolver: ASNResolver,
    scope: _ASNResolverScope,
    publish: @escaping ASNPublish
  ) -> (hits: [String: ASNInfo], flights: [SharedASNWork<Void>]) {
    var hits: [String: ASNInfo] = [:]
    var joined: [SharedASNWork<Void>] = []
    var seen: Set<ObjectIdentifier> = []
    var unreserved: [String] = []
    for address in addresses {
      if let info = map[address] {
        hits[address] = info
      } else if let flight = flights[LookupKey(scope: scope, address: address, timeout: timeout)] {
        if seen.insert(ObjectIdentifier(flight)).inserted {
          joined.append(flight)
          joins[scope, default: 0] += 1
        }
      } else {
        unreserved.append(address)
      }
    }
    if !unreserved.isEmpty, !DiscoveryClock.current.hasPassed(deadline) {
      joined.append(
        startFlight(
          unreserved, timeout: timeout, deadline: deadline, using: resolver, scope: scope,
          publish: publish))
    }
    return (hits, joined)
  }

  /// Starts one flight for `addresses`, bounded by the deadline of the caller that starts it.
  /// It publishes to its own record and to that caller, so a caller that is itself a flight
  /// (a cache in front of this one) sees each answer as it arrives.
  private func startFlight(
    _ addresses: [String],
    timeout: TimeInterval,
    deadline: TimeInterval,
    using resolver: ASNResolver,
    scope: _ASNResolverScope,
    publish starter: @escaping ASNPublish
  ) -> SharedASNWork<Void> {
    let keys = addresses.map { LookupKey(scope: scope, address: $0, timeout: timeout) }
    let flightGeneration = generation
    let flight = SharedASNWork<Void> { publish in
      let both: ASNPublish = {
        publish($0)
        starter($0)
      }
      do {
        let found: [String: ASNInfo]
        if let resolver = resolver as? PublishingASNResolver {
          found = try await resolver.resolve(
            addresses, timeout: timeout, deadline: deadline, publish: both)
        } else {
          found = try await resolver.resolve(ipv4Addrs: addresses, timeout: timeout)
        }
        both(found)
        await self.land(keys, generation: flightGeneration, found: found)
      } catch {
        await self.land(keys, generation: flightGeneration, found: [:])
        throw error
      }
    }
    for key in keys { flights[key] = flight }
    return flight
  }

  /// Releases a finished flight's keys and caches its answers that carry an AS name. One without
  /// a name is not cached, so a later lookup still asks for the name. A flight started before
  /// ``clear()`` changes nothing.
  private func land(
    _ keys: [LookupKey], generation flightGeneration: UInt64, found: [String: ASNInfo]
  ) {
    guard flightGeneration == generation else { return }
    for key in keys { flights.removeValue(forKey: key) }
    setMany(found.filter { !$0.value.name.isEmpty })
  }

  /// Clear all cached entries and forget running flights, which run on but cache nothing.
  /// Internal for testing via @testable import.
  func clear() {
    generation &+= 1
    map.removeAll()
    order.removeAll()
    flights.removeAll()
    joins.removeAll()
  }

  /// Current cache size. Internal for testing via @testable import.
  var count: Int { map.count }

  /// Number of times a caller joined a running flight since the last ``clear()``. Internal for
  /// deterministic tests.
  var joinCount: Int { joins.values.reduce(0, +) }

  /// Number of times a caller of one caching resolver joined a running flight since the last
  /// ``clear()``. Internal for deterministic tests.
  fileprivate func joinCount(_ scope: _ASNResolverScope) -> Int { joins[scope] ?? 0 }

  /// Number of keys currently reserved by in-flight work. Internal for deterministic tests.
  var inFlightReservationCount: Int { flights.count }
}

/// Decorator that caches results from an underlying ASNResolver in-memory.
///
/// Concurrent misses made through the same resolver instance are coalesced by address and timeout
/// into one shared lookup. Each caller stops waiting at its own timeout, or when its task is
/// cancelled, and returns every answer it has by then, an AS number whose name is still pending
/// included; neither stops the shared lookup, which runs on for its other callers and fills the
/// cache. Only entries with an AS name are cached.
public struct CachingASNResolver: ASNResolver, PublishingASNResolver {
  private let base: ASNResolver
  private let scope: _ASNResolverScope

  public init(base: ASNResolver) {
    self.base = base
    self.scope = _ASNResolverScope()
  }

  /// - Parameters:
  ///   - ipv4Addrs: IP addresses to resolve; empty entries are ignored.
  ///   - timeout: Bounds the whole call, waiting on a shared lookup included.
  #if compiler(>=6.2)
    @concurrent
  #endif
  public func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo]
  {
    try await resolve(
      ipv4Addrs, timeout: timeout, deadline: asnDeadline(timeout), publish: { _ in })
  }

  /// How many times a caller of this resolver joined a running flight. For tests.
  var joinCount: Int {
    get async { await _ASNMemoryCache.shared.joinCount(scope) }
  }

  func resolve(
    _ addresses: [String], timeout: TimeInterval, deadline: TimeInterval,
    publish: @escaping ASNPublish
  ) async throws -> [String: ASNInfo] {
    let ips = Set(addresses.filter { !$0.isEmpty }).sorted()
    if ips.isEmpty { return [:] }
    return try await _ASNMemoryCache.shared.resolve(
      ips, timeout: timeout, deadline: deadline, using: base, scope: scope, publish: publish)
  }
}

/// Limits how many Team Cymru queries one resolve call has in flight, and so how many sockets it
/// holds at once.
actor _ConcurrencySemaphore {
  private var available: Int
  private struct Waiter {
    let id: UInt64
    let continuation: CheckedContinuation<Void, Error>
  }

  private var waiters: [Waiter] = []
  private var nextWaiterID: UInt64 = 0

  init(maxConcurrent: Int) { self.available = maxConcurrent }

  /// Takes a permit, waiting without a thread until one is free.
  ///
  /// - Throws: `CancellationError` if the calling task is cancelled before a permit is free. A
  ///   cancelled waiter takes no permit, so it must not call ``signal()``.
  func wait() async throws {
    if available > 0 {
      available -= 1
      return
    }
    let id = nextWaiterID
    nextWaiterID &+= 1
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        waiters.append(Waiter(id: id, continuation: continuation))
      }
    } onCancel: {
      // The actor is busy until this wait suspends, so `cancelWaiter` always runs after the
      // waiter is listed, even when the task was cancelled before it called `wait()`.
      Task { await self.cancelWaiter(id) }
    }
  }

  /// Tasks waiting for a permit now. For tests, which wait on it to know a caller has reached
  /// the wait.
  var waitingCount: Int { waiters.count }

  func signal() {
    if !waiters.isEmpty {
      let waiter = waiters.removeFirst()
      waiter.continuation.resume()
    } else {
      available += 1
    }
  }

  private func cancelWaiter(_ id: UInt64) {
    // A waiter that `signal()` already resumed holds a permit and is no longer listed.
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    waiters.remove(at: index).continuation.resume(throwing: CancellationError())
  }
}

// Intermediate result from origin ASN lookup.
private struct _OriginASNResult: Sendable {
  let asn: Int
  let prefix: String?
  let cc: String?
  let registry: String?
}

extension ASNInfo {
  fileprivate init(_ origin: _OriginASNResult, name: String) {
    self.init(
      asn: origin.asn, name: name, prefix: origin.prefix, countryCode: origin.cc,
      registry: origin.registry)
  }
}

// Team Cymru DNS-based resolver using TXT queries.
/// Team Cymru DNS-based resolver using TXT queries for origin ASN and AS names.
public struct CymruDNSResolver: ASNResolver, PublishingASNResolver {
  /// Queries in flight at once for one ``resolve(ipv4Addrs:timeout:)`` call. Each holds one UDP
  /// socket and no thread.
  private static let maxConcurrentQueries = 8

  /// DNS servers each query tries, in order.
  private let servers: [String]

  public init() { self.servers = DNSClient.defaultTXTServers }

  /// A resolver that sends its queries to `servers`. Tests point it at a loopback responder.
  init(servers: [String]) { self.servers = servers }

  /// Resolves origin ASN metadata through Team Cymru's DNS service.
  ///
  /// - Parameters:
  ///   - ipv4Addrs: IP addresses to resolve. IPv4 and IPv6 literals are supported; empty entries
  ///     are ignored.
  ///   - timeout: Bounds the whole call: every origin and AS-name query, on every server, ends by
  ///     `timeout` seconds after the call starts. It must be finite and greater than zero. An
  ///     origin whose AS-name query did not answer in time is returned with an empty name.
  /// - Returns: A map from each resolved input address to its ASN metadata.
  /// - Throws: ``DNSError/invalidTimeout(_:)`` if `timeout` is not finite and greater than zero.
  #if compiler(>=6.2)
    @concurrent
  #endif
  public func resolve(ipv4Addrs: [String], timeout: TimeInterval = 1.0) async throws -> [String:
    ASNInfo]
  {
    try await resolve(
      ipv4Addrs, timeout: timeout, deadline: asnDeadline(timeout), publish: { _ in })
  }

  func resolve(
    _ addresses: [String], timeout: TimeInterval, deadline: TimeInterval,
    publish: @escaping ASNPublish
  ) async throws -> [String: ASNInfo] {
    try _validateDNSTimeout(timeout)

    // Each input presentation, by the address its query uses. Cymru only has meaningful origin
    // data for globally routable addresses; mapped IPv4 is normalized so it uses
    // origin.asn.cymru.com, not origin6.
    var inputsByLookup: [String: [String]] = [:]
    for ip in Set(addresses.filter { !$0.isEmpty }) {
      if let lookupIP = asnLookupAddress(for: ip) {
        inputsByLookup[lookupIP, default: []].append(ip)
      }
    }
    if inputsByLookup.isEmpty { return [:] }

    let semaphore = _ConcurrencySemaphore(maxConcurrent: Self.maxConcurrentQueries)
    // Answers keyed by input presentation, published as each one is learned.
    var result: [String: ASNInfo] = [:]
    func learn(_ lookupIP: String, _ info: ASNInfo) {
      var found: [String: ASNInfo] = [:]
      for ip in inputsByLookup[lookupIP] ?? [] { found[ip] = info }
      result.merge(found) { $1 }
      publish(found)
    }

    // Phase 1: Parallel origin ASN lookups
    var originResults: [String: _OriginASNResult] = [:]
    await withTaskGroup(of: (String, _OriginASNResult?).self) { group in
      for ip in inputsByLookup.keys {
        group.addTask {
          guard (try? await semaphore.wait()) != nil else { return (ip, nil) }
          defer { Task { await semaphore.signal() } }
          return (ip, await self.lookupOriginASN(ip: ip, timeout: timeout, cutoff: deadline))
        }
      }
      for await (ip, origin) in group {
        guard let origin else { continue }
        originResults[ip] = origin
        learn(ip, ASNInfo(origin, name: ""))
      }
    }

    if originResults.isEmpty { return [:] }

    // Phase 2: Parallel AS name lookups for unique ASNs only
    let uniqueASNs = Set(originResults.values.map { $0.asn })
    await withTaskGroup(of: (Int, String?).self) { group in
      for asn in uniqueASNs {
        group.addTask {
          guard (try? await semaphore.wait()) != nil else { return (asn, nil) }
          defer { Task { await semaphore.signal() } }
          return (asn, await self.lookupASName(asn: asn, timeout: timeout, cutoff: deadline))
        }
      }
      for await (asn, name) in group {
        guard let name else { continue }
        for (ip, origin) in originResults where origin.asn == asn {
          learn(ip, ASNInfo(origin, name: name))
        }
      }
    }
    return result
  }

  /// Look up origin ASN for a single IP address. Dispatches v4 to
  /// `origin.asn.cymru.com` (dotted-quad reverse) and v6 to
  /// `origin6.asn.cymru.com` (full nibble reverse, RFC 1886 §2.5 style).
  private func lookupOriginASN(
    ip: String, timeout: TimeInterval, cutoff: TimeInterval
  ) async -> _OriginASNResult? {
    let fam = detectAddressFamily(ip)
    let q: String
    if fam == AF_INET6 {
      guard let nibblesReverse = reverseIPv6Nibbles(ip) else { return nil }
      q = "\(nibblesReverse).origin6.asn.cymru.com"
    } else {
      let octs = ip.split(separator: ".")
      let rev = octs.reversed().joined(separator: ".")
      q = "\(rev).origin.asn.cymru.com"
    }

    let txts = await DNSClient.queryTXT(
      name: q, timeout: timeout, servers: servers, cutoff: cutoff)
    guard let txts = txts, let first = txts.first else { return nil }

    // Format: "AS | BGP Prefix | CC | Registry | Allocated"
    let parts = first.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    guard parts.count >= 4, let asField = parts.first else { return nil }

    // Some responses contain multiple ASNs separated by spaces; take the first token
    let tokens = asField.split(whereSeparator: { $0 == " " || $0 == "," })
    guard let tok = tokens.first,
      let asn = Int(tok) ?? Int(tok.replacingOccurrences(of: "AS", with: ""))
    else { return nil }

    let prefix = parts.count > 1 ? parts[1] : nil
    let cc = parts.count > 2 ? parts[2] : nil
    let reg = parts.count > 3 ? parts[3] : nil

    return _OriginASNResult(asn: asn, prefix: prefix, cc: cc, registry: reg)
  }

  /// Look up AS name for a single ASN.
  private func lookupASName(asn: Int, timeout: TimeInterval, cutoff: TimeInterval) async -> String?
  {
    let qn = "AS\(asn).asn.cymru.com"

    let txts = await DNSClient.queryTXT(
      name: qn, timeout: timeout, servers: servers, cutoff: cutoff)
    guard let txts = txts, let first = txts.first else { return nil }

    // Typical format: "AS | AS Name | CC | Registry | Allocated"
    let parts = first.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    return pickASName(from: parts)
  }
}

private func pickASName(from fields: [String]) -> String? {
  // Heuristics: prefer index 1 if present; else choose the first field that isn't a 2-letter country code or a known registry, and contains a letter.
  if fields.indices.contains(1) {
    let v = fields[1].trimmingCharacters(in: .whitespaces)
    let registries: Set<String> = [
      "arin", "lacnic", "ripe", "ripencc", "apnic", "afrinic", "jpnic", "krnic",
    ]
    if !v.isEmpty && !(v.count == 2 && v == v.uppercased()) && !registries.contains(v.lowercased())
    {
      return v
    }
  }
  let registries: Set<String> = [
    "arin", "lacnic", "ripe", "ripencc", "apnic", "afrinic", "jpnic", "krnic",
  ]
  for f in fields {
    let s = f.trimmingCharacters(in: .whitespaces)
    if s.isEmpty { continue }
    let lower = s.lowercased()
    if registries.contains(lower) { continue }
    if s.count == 2 && s == s.uppercased() { continue }  // likely country code
    if s.range(of: "[A-Za-z]", options: .regularExpression) != nil {
      return s
    }
  }
  return fields.last
}
