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
  /// Fast (~10μs), works offline. Adds ~6MB memory footprint.
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
  private typealias LoadTask = Task<[String: ASNInfo], Error>

  private struct LookupKey: Hashable {
    let scope: _ASNResolverScope
    let address: String
    let timeout: TimeInterval
  }

  private struct Flight {
    let id: UInt64
    let keys: [LookupKey]
    let task: LoadTask
    var joinCount: Int
  }

  static let shared = _ASNMemoryCache()
  private var map: [String: ASNInfo] = [:]
  private var order: [String] = []
  private var flightIDByKey: [LookupKey: UInt64] = [:]
  private var flightsByID: [UInt64: Flight] = [:]
  private var nextFlightID: UInt64 = 1
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

  /// Returns cached values and coalesces overlapping cache misses.
  ///
  /// A flight reserves each `(address, timeout)` key before its resolver task starts. Calls with
  /// overlapping keys await that shared task, while calls for disjoint keys start independent
  /// tasks. The task, rather than its first caller, owns the reservation, so caller cancellation
  /// cannot cancel or poison work shared with another caller.
  fileprivate func resolve(
    _ addresses: [String],
    timeout: TimeInterval,
    using resolver: ASNResolver,
    scope: _ASNResolverScope
  ) async throws -> [String: ASNInfo] {
    try Task.checkCancellation()

    var resolved = getMany(addresses)
    let missing = addresses.filter { resolved[$0] == nil }
    guard !missing.isEmpty else { return resolved }

    var tasksByFlightID: [UInt64: LoadTask] = [:]
    var joinedFlightIDs: Set<UInt64> = []
    var unreserved: [String] = []

    for address in missing {
      let key = LookupKey(scope: scope, address: address, timeout: timeout)
      if let flightID = flightIDByKey[key], let flight = flightsByID[flightID] {
        joinedFlightIDs.insert(flightID)
        tasksByFlightID[flightID] = flight.task
      } else {
        unreserved.append(address)
      }
    }

    for flightID in joinedFlightIDs {
      flightsByID[flightID]?.joinCount += 1
    }

    if !unreserved.isEmpty {
      let flight = startFlight(
        addresses: unreserved,
        timeout: timeout,
        using: resolver,
        scope: scope
      )
      tasksByFlightID[flight.id] = flight.task
    }

    for task in tasksByFlightID.values {
      let loaded = try await Self.waitForLoad(task)
      for address in addresses {
        if let info = loaded[address] { resolved[address] = info }
      }
    }

    return resolved
  }

  private func startFlight(
    addresses: [String],
    timeout: TimeInterval,
    using resolver: ASNResolver,
    scope: _ASNResolverScope
  ) -> Flight {
    let flightID = nextFlightID
    nextFlightID &+= 1
    let flightGeneration = generation
    let keys = addresses.map { LookupKey(scope: scope, address: $0, timeout: timeout) }
    let task = Self.makeLoadTask(
      resolver: resolver,
      addresses: addresses,
      timeout: timeout,
      cache: self,
      flightID: flightID,
      generation: flightGeneration
    )

    let flight = Flight(
      id: flightID,
      keys: keys,
      task: task,
      joinCount: 0
    )
    flightsByID[flightID] = flight
    for key in keys {
      flightIDByKey[key] = flightID
    }
    return flight
  }

  /// Creates shared resolver work outside the cache actor.
  nonisolated private static func makeLoadTask(
    resolver: ASNResolver,
    addresses: [String],
    timeout: TimeInterval,
    cache: _ASNMemoryCache,
    flightID: UInt64,
    generation: UInt64
  ) -> LoadTask {
    Task.detached(priority: Task.currentPriority) {
      do {
        try Task.checkCancellation()
        let result = try await resolver.resolve(ipv4Addrs: addresses, timeout: timeout)
        try Task.checkCancellation()
        guard await cache.completeFlight(id: flightID, generation: generation, result: result)
        else {
          throw CancellationError()
        }
        return result
      } catch {
        await cache.releaseFlight(id: flightID, generation: generation)
        throw error
      }
    }
  }

  /// Waits for shared work while allowing this caller to stop waiting independently.
  nonisolated private static func waitForLoad(_ task: LoadTask) async throws -> [String: ASNInfo] {
    let pair = AsyncThrowingStream<[String: ASNInfo], Error>.makeStream()
    _ = Task.detached {
      do {
        pair.continuation.yield(try await task.value)
        pair.continuation.finish()
      } catch {
        pair.continuation.finish(throwing: error)
      }
    }

    return try await withTaskCancellationHandler {
      do {
        var iterator = pair.stream.makeAsyncIterator()
        guard let result = try await iterator.next() else { throw CancellationError() }
        try Task.checkCancellation()
        return result
      } catch {
        try Task.checkCancellation()
        throw error
      }
    } onCancel: {
      pair.continuation.finish(throwing: CancellationError())
    }
  }

  private func completeFlight(
    id: UInt64,
    generation flightGeneration: UInt64,
    result: [String: ASNInfo]
  ) -> Bool {
    guard flightGeneration == generation, flightsByID[id] != nil else { return false }
    setMany(result)
    releaseFlight(id: id, generation: flightGeneration)
    return true
  }

  private func releaseFlight(id: UInt64, generation flightGeneration: UInt64) {
    guard flightGeneration == generation, let flight = flightsByID.removeValue(forKey: id) else {
      return
    }
    for key in flight.keys where flightIDByKey[key] == id {
      flightIDByKey.removeValue(forKey: key)
    }
  }

  /// Clear all cached entries. Internal for testing via @testable import.
  func clear() {
    let tasks = flightsByID.values.map(\.task)
    generation &+= 1
    map.removeAll()
    order.removeAll()
    flightIDByKey.removeAll()
    flightsByID.removeAll()
    for task in tasks {
      task.cancel()
    }
  }

  /// Current cache size. Internal for testing via @testable import.
  var count: Int { map.count }

  /// Number of callers that joined an existing flight. Internal for deterministic tests.
  var inFlightJoinCount: Int {
    flightsByID.values.reduce(0) { $0 + $1.joinCount }
  }
}

/// Decorator that caches results from an underlying ASNResolver in-memory.
///
/// Concurrent misses made through the same resolver instance are coalesced by address and timeout.
/// Canceling one caller stops that caller's wait without canceling a shared lookup needed by other
/// callers. The underlying resolver remains responsible for honoring its per-lookup timeout.
public struct CachingASNResolver: ASNResolver {
  private let base: ASNResolver
  private let scope: _ASNResolverScope

  public init(base: ASNResolver) {
    self.base = base
    self.scope = _ASNResolverScope()
  }
  #if compiler(>=6.2)
    @concurrent
  #endif
  public func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo]
  {
    let ips = Array(Set(ipv4Addrs.filter { !$0.isEmpty }))
    if ips.isEmpty { return [:] }
    return try await _ASNMemoryCache.shared.resolve(
      ips,
      timeout: timeout,
      using: base,
      scope: scope
    )
  }
}

// Actor-based semaphore for limiting concurrent DNS queries.
private actor _ConcurrencySemaphore {
  private var available: Int
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(maxConcurrent: Int) { self.available = maxConcurrent }

  func wait() async {
    if available > 0 {
      available -= 1
    } else {
      await withCheckedContinuation { continuation in
        waiters.append(continuation)
      }
    }
  }

  func signal() {
    if !waiters.isEmpty {
      let waiter = waiters.removeFirst()
      waiter.resume()
    } else {
      available += 1
    }
  }
}

// Intermediate result from origin ASN lookup.
private struct _OriginASNResult: Sendable {
  let asn: Int
  let prefix: String?
  let cc: String?
  let registry: String?
}

// Team Cymru DNS-based resolver using TXT queries.
/// Team Cymru DNS-based resolver using TXT queries for origin ASN and AS names.
public struct CymruDNSResolver: ASNResolver {
  public init() {}

  /// Resolves origin ASN metadata through Team Cymru's DNS service.
  ///
  /// - Parameters:
  ///   - ipv4Addrs: IP addresses to resolve. IPv4 and IPv6 literals are supported; empty entries
  ///     are ignored.
  ///   - timeout: The per-query timeout in seconds. It must be finite and greater than zero.
  /// - Returns: A map from each resolved input address to its ASN metadata.
  /// - Throws: ``DNSError/invalidTimeout(_:)`` if `timeout` is not finite and greater than zero.
  #if compiler(>=6.2)
    @concurrent
  #endif
  public func resolve(ipv4Addrs: [String], timeout: TimeInterval = 1.0) async throws -> [String:
    ASNInfo]
  {
    try _validateDNSTimeout(timeout)

    let ips = Array(Set(ipv4Addrs.filter { !$0.isEmpty }))
    if ips.isEmpty { return [:] }

    // Cymru only has meaningful origin data for globally routable addresses.
    // Mapped IPv4 is normalized so it uses origin.asn.cymru.com, not origin6.
    let lookupIPs = Array(Set(ips.compactMap(asnLookupAddress)))
    if lookupIPs.isEmpty { return [:] }

    let semaphore = _ConcurrencySemaphore(maxConcurrent: 8)

    // Phase 1: Parallel origin ASN lookups
    let originResults: [String: _OriginASNResult] = await withTaskGroup(
      of: (String, _OriginASNResult?).self
    ) { group in
      for ip in lookupIPs {
        group.addTask {
          await semaphore.wait()
          defer { Task { await semaphore.signal() } }
          return (ip, await self.lookupOriginASN(ip: ip, timeout: timeout))
        }
      }

      var results: [String: _OriginASNResult] = [:]
      for await (ip, result) in group {
        if let r = result { results[ip] = r }
      }
      return results
    }

    if originResults.isEmpty { return [:] }

    // Phase 2: Parallel AS name lookups for unique ASNs only
    let uniqueASNs = Array(Set(originResults.values.map { $0.asn }))
    let asnNames: [Int: String] = await withTaskGroup(of: (Int, String?).self) { group in
      for asn in uniqueASNs {
        group.addTask {
          await semaphore.wait()
          defer { Task { await semaphore.signal() } }
          return (asn, await self.lookupASName(asn: asn, timeout: timeout))
        }
      }

      var names: [Int: String] = [:]
      for await (asn, name) in group {
        if let n = name { names[asn] = n }
      }
      return names
    }

    // Combine results
    var lookupResults: [String: ASNInfo] = [:]
    for (ip, origin) in originResults {
      lookupResults[ip] = ASNInfo(
        asn: origin.asn,
        name: asnNames[origin.asn] ?? "",
        prefix: origin.prefix,
        countryCode: origin.cc,
        registry: origin.registry
      )
    }

    // Preserve the protocol contract that results are keyed by the caller's
    // input presentation, even when the network query used a normalized key.
    var result: [String: ASNInfo] = [:]
    for ip in ips {
      if let lookupIP = asnLookupAddress(for: ip), let info = lookupResults[lookupIP] {
        result[ip] = info
      }
    }
    return result
  }

  /// Look up origin ASN for a single IP address. Dispatches v4 to
  /// `origin.asn.cymru.com` (dotted-quad reverse) and v6 to
  /// `origin6.asn.cymru.com` (full nibble reverse, RFC 1886 §2.5 style).
  private func lookupOriginASN(ip: String, timeout: TimeInterval) async -> _OriginASNResult? {
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

    // Keep the synchronous resolver off Swift's cooperative executor.
    let txts = try? await runDetachedBlockingIO(priority: .userInitiated) {
      DNSClient.queryTXT(name: q, timeout: timeout)
    }
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
  private func lookupASName(asn: Int, timeout: TimeInterval) async -> String? {
    let qn = "AS\(asn).asn.cymru.com"

    // Keep the synchronous resolver off Swift's cooperative executor.
    let txts = try? await runDetachedBlockingIO(priority: .userInitiated) {
      DNSClient.queryTXT(name: qn, timeout: timeout)
    }
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
