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
  ///   - timeout: How long the whole call may take, in seconds. The built-in resolvers return
  ///     what they have when it runs out, through every stage they pass a lookup to. DNS-backed
  ///     resolvers require a finite value greater than zero; for the others, a value that is not
  ///     finite and positive sets no bound.
  /// - Returns: Map of input IP -> ASNInfo for addresses with public routing data.
  func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo]
}

/// The instant `timeout` seconds from now, by which an ASN lookup returns what it has, or `nil`
/// for no bound when `timeout` is not finite and positive, or longer than
/// `ConfigurationLimits.maximumTimeout` (about 68 years), past which an instant on the clock could
/// not be waited for.
func asnDeadline(after timeout: TimeInterval) -> ContinuousClock.Instant? {
  guard timeout.isFinite, timeout > 0, timeout <= ConfigurationLimits.maximumTimeout else {
    return nil
  }
  return .now + .seconds(timeout)
}

/// A deadline checked once every 64 steps of a pass over a batch, so that preparing or scanning a
/// large batch stops when the time does, for little more than the cost of the pass.
struct DeadlineClock {
  private let deadline: ContinuousClock.Instant?
  private var steps = 0

  init(_ deadline: ContinuousClock.Instant?) { self.deadline = deadline }

  /// Counts one step, and on every 64th says whether the deadline has passed.
  mutating func expired() -> Bool {
    steps &+= 1
    guard let deadline, steps & 63 == 0 else { return false }
    return ContinuousClock.now >= deadline
  }
}

/// Each distinct, non-empty address of `addresses` with the key `key` gives it, leaving out those
/// it gives none; `nil` if `deadline` passes first.
func prepareASNBatch(
  _ addresses: [String], until deadline: ContinuousClock.Instant?, key: (String) -> String?
) -> [String: String]? {
  var clock = DeadlineClock(deadline)
  var keys: [String: String] = [:]
  for address in addresses {
    if clock.expired() { return nil }
    guard !address.isEmpty, keys[address] == nil, let found = key(address) else { continue }
    keys[address] = found
  }
  return keys
}

/// The answers one shared ASN lookup has received so far, keyed by the caller's address.
///
/// The resolver doing the lookup publishes each answer here as it arrives (a Team Cymru origin
/// before its AS name, then the entry again with the name), and a caller whose time runs out
/// takes what is here for its own addresses. ``publish(_:)`` is the one place a lookup's progress
/// is recorded.
final class ASNAnswerLog: @unchecked Sendable {
  private let lock = NSLock()
  private var answers: [String: ASNInfo] = [:]

  /// Records `new`, replacing earlier answers for the same addresses.
  func publish(_ new: [String: ASNInfo]) {
    lock.lock()
    defer { lock.unlock() }
    answers.merge(new) { _, latest in latest }
  }

  /// The answers received so far for `addresses`.
  func answers(for addresses: [String]) -> [String: ASNInfo] {
    lock.lock()
    defer { lock.unlock() }
    var out: [String: ASNInfo] = [:]
    for address in addresses {
      if let info = answers[address] { out[address] = info }
    }
    return out
  }
}

/// A resolver that publishes its answers as they arrive, so a cached lookup's callers whose time
/// runs out get what it has learned. A caller's own ``ASNResolver`` has no way to do this: its
/// answers reach waiting callers only when its call returns.
protocol ASNProgressReporting: ASNResolver {
  func resolve(ipv4Addrs: [String], timeout: TimeInterval, publishing log: ASNAnswerLog)
    async throws -> [String: ASNInfo]
}

/// Work shared by several callers, each of which may stop waiting on its own.
///
/// One observer per piece of work waits for its task. A caller registers while it waits and takes
/// its registration with it when it stops, at its deadline or because it was cancelled, so nothing
/// of a caller that left stays behind while the work runs on. Neither a deadline nor a caller's
/// cancellation cancels the task.
final class SharedWork<Value: Sendable>: @unchecked Sendable {
  let task: Task<Value, Error>

  private let lock = NSLock()
  private var outcome: Result<Value, Error>?
  /// Callers waiting, by registration.
  private var waiters: [UInt64: CheckedContinuation<Value?, Error>] = [:]
  /// Registrations not yet ended.
  private var pending: Set<UInt64> = []
  /// How a registration ended before its caller had suspended: by its deadline or cancellation.
  private var endedEarly: [UInt64: Result<Value?, Error>] = [:]
  private var nextID: UInt64 = 0

  init(_ task: Task<Value, Error>) {
    self.task = task
    Task.detached { [self] in
      let result: Result<Value, Error>
      do {
        result = .success(try await task.value)
      } catch {
        result = .failure(error)
      }
      finish(result)
    }
  }

  /// Work that has already produced `value`.
  init(finished value: Value) {
    task = Task { value }
    outcome = .success(value)
  }

  /// How the work ended, or `nil` while it runs; never waits.
  var finishedResult: Result<Value, Error>? {
    lock.lock()
    defer { lock.unlock() }
    return outcome
  }

  /// Waits until the work ends or `deadline` passes, without taking its result.
  ///
  /// - Returns: Whether the work ended, with a value or an error.
  /// - Throws: `CancellationError` when the calling task is cancelled.
  func waitForEnd(until deadline: ContinuousClock.Instant?) async throws -> Bool {
    do {
      return try await value(until: deadline) != nil
    } catch {
      if Task.isCancelled { throw CancellationError() }
      return true
    }
  }

  /// Callers registered and not yet released. For tests.
  var waiterCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return pending.count
  }

  /// The work's value, or `nil` once `deadline` has passed without it.
  ///
  /// - Throws: `CancellationError` when the calling task is cancelled, or the work's own error.
  func value(until deadline: ContinuousClock.Instant?) async throws -> Value? {
    let id = register()

    let timer = deadline.map { deadline in
      Task.detached { [weak self] in
        do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
        self?.release(id, with: .success(nil))
      }
    }
    defer { timer?.cancel() }

    do {
      let value = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          register(id, continuation)
        }
      } onCancel: {
        release(id, with: .failure(CancellationError()))
      }
      try Task.checkCancellation()
      return value
    } catch {
      try Task.checkCancellation()
      throw error
    }
  }

  /// A new registration for a caller about to wait.
  private func register() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    let id = nextID
    nextID &+= 1
    pending.insert(id)
    return id
  }

  private func register(_ id: UInt64, _ continuation: CheckedContinuation<Value?, Error>) {
    lock.lock()
    if let outcome {
      pending.remove(id)
      endedEarly[id] = nil
      lock.unlock()
      continuation.resume(with: outcome.map { Optional($0) })
    } else if let ended = endedEarly.removeValue(forKey: id) {
      pending.remove(id)
      lock.unlock()
      continuation.resume(with: ended)
    } else {
      waiters[id] = continuation
      lock.unlock()
    }
  }

  /// Ends one registration, whether or not its caller has suspended yet; the first end wins.
  private func release(_ id: UInt64, with result: Result<Value?, Error>) {
    lock.lock()
    guard pending.contains(id) else {
      lock.unlock()
      return
    }
    if let continuation = waiters.removeValue(forKey: id) {
      pending.remove(id)
      lock.unlock()
      continuation.resume(with: result)
    } else {
      if endedEarly[id] == nil { endedEarly[id] = result }
      lock.unlock()
    }
  }

  private func finish(_ result: Result<Value, Error>) {
    lock.lock()
    outcome = result
    let waiting = waiters
    waiters.removeAll()
    for id in waiting.keys { pending.remove(id) }
    lock.unlock()
    for continuation in waiting.values {
      continuation.resume(with: result.map { Optional($0) })
    }
  }
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

    /// Preserve exact timeout identity while keeping dictionary equality reflexive for NaN.
    let timeoutBitPattern: UInt64

    init(scope: _ASNResolverScope, address: String, timeout: TimeInterval) {
      self.scope = scope
      self.address = address
      self.timeoutBitPattern = timeout.bitPattern
    }
  }

  private struct Flight {
    let id: UInt64
    let keys: [LookupKey]
    let work: SharedWork<[String: ASNInfo]>
    /// What the lookup has answered so far, for callers whose time runs out before it ends.
    let answers: ASNAnswerLog
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
  /// cannot cancel or poison work shared with another caller. Each caller stops waiting at
  /// `deadline`, and the flights run on.
  ///
  /// A caller gets every answer it has when it returns, whatever order it looked at its flights
  /// in: cached ones, those of flights that ended, and those a flight still running has published
  /// (see ``ASNAnswerLog``). It throws only when it has none and one of its flights failed: the
  /// error of the earliest such flight.
  fileprivate func resolve(
    _ addresses: [String],
    timeout: TimeInterval,
    until deadline: ContinuousClock.Instant?,
    using resolver: ASNResolver,
    scope: _ASNResolverScope
  ) async throws -> [String: ASNInfo] {
    try Task.checkCancellation()

    var clock = DeadlineClock(deadline)
    var resolved: [String: ASNInfo] = [:]
    var addressesByFlight: [UInt64: [String]] = [:]
    var unreserved: [String] = []
    for address in addresses {
      // Out of time before any lookup was asked: what the cache had is the answer.
      if clock.expired() { return resolved }
      if let info = map[address] {
        resolved[address] = info
        continue
      }
      let key = LookupKey(scope: scope, address: address, timeout: timeout)
      if let flightID = flightIDByKey[key], flightsByID[flightID] != nil {
        addressesByFlight[flightID, default: []].append(address)
      } else {
        unreserved.append(address)
      }
    }
    var flights: [Flight] = []
    for flightID in addressesByFlight.keys {
      flightsByID[flightID]?.joinCount += 1
      if let flight = flightsByID[flightID] { flights.append(flight) }
    }
    if !unreserved.isEmpty {
      let flight = startFlight(
        addresses: unreserved, timeout: timeout, using: resolver, scope: scope)
      addressesByFlight[flight.id] = unreserved
      flights.append(flight)
    }
    flights.sort { $0.id < $1.id }

    // Wait for every flight to end, or for the deadline; then read each, in one fixed order, so
    // the outcome does not depend on which ended first.
    for flight in flights {
      guard try await flight.work.waitForEnd(until: deadline) else { break }
    }
    var failure: Error?
    for flight in flights {
      let mine = addressesByFlight[flight.id] ?? []
      switch flight.work.finishedResult {
      case .success(let loaded)?:
        for address in mine {
          if let info = loaded[address] { resolved[address] = info }
        }
      case .failure(let error)?:
        if failure == nil { failure = error }
      case nil:
        resolved.merge(flight.answers.answers(for: mine)) { cached, _ in cached }
      }
    }
    if resolved.isEmpty, let failure { throw failure }
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
    let answers = ASNAnswerLog()
    let work = SharedWork(
      Self.makeLoadTask(
        resolver: resolver,
        addresses: addresses,
        timeout: timeout,
        answers: answers,
        cache: self,
        flightID: flightID,
        generation: flightGeneration
      ))

    let flight = Flight(
      id: flightID,
      keys: keys,
      work: work,
      answers: answers,
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
    answers: ASNAnswerLog,
    cache: _ASNMemoryCache,
    flightID: UInt64,
    generation: UInt64
  ) -> LoadTask {
    Task.detached(priority: Task.currentPriority) {
      do {
        try Task.checkCancellation()
        let result: [String: ASNInfo]
        if let reporting = resolver as? any ASNProgressReporting {
          result = try await reporting.resolve(
            ipv4Addrs: addresses, timeout: timeout, publishing: answers)
        } else {
          result = try await resolver.resolve(ipv4Addrs: addresses, timeout: timeout)
        }
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
    let tasks = flightsByID.values.map(\.work.task)
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

  /// Number of keys currently reserved by in-flight work. Internal for deterministic tests.
  var inFlightReservationCount: Int { flightIDByKey.count }
}

/// Decorator that caches results from an underlying ASNResolver in-memory.
///
/// Concurrent misses made through the same resolver instance are coalesced by address and timeout.
/// Canceling one caller stops that caller's wait without canceling a shared lookup needed by other
/// callers. Each caller also stops waiting once its own `timeout` has passed, returning what is
/// cached or has arrived by then, even when the underlying resolver overruns; the shared lookup
/// runs on and fills the cache when it ends.
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
    try await resolve(ipv4Addrs: ipv4Addrs, timeout: timeout, waitingUntil: nil)
  }

  /// Resolves through a shared flight keyed by `timeout`, which the resolver behind is given, and
  /// waits for it until `timeout` has passed or `waitingUntil`, whichever is first.
  ///
  /// A caller with less time left than `timeout` passes its own deadline here rather than a
  /// shorter timeout, so concurrent callers of one address still share a flight.
  func resolve(
    ipv4Addrs: [String], timeout: TimeInterval,
    waitingUntil callerDeadline: ContinuousClock.Instant?
  ) async throws -> [String: ASNInfo] {
    var deadline = asnDeadline(after: timeout)
    if let callerDeadline, deadline.map({ callerDeadline < $0 }) ?? true {
      deadline = callerDeadline
    }
    guard let prepared = prepareASNBatch(ipv4Addrs, until: deadline, key: { $0 }),
      !prepared.isEmpty
    else { return [:] }
    return try await _ASNMemoryCache.shared.resolve(
      Array(prepared.keys),
      timeout: timeout,
      until: deadline,
      using: base,
      scope: scope
    )
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

// Team Cymru DNS-based resolver using TXT queries.
/// Team Cymru DNS-based resolver using TXT queries for origin ASN and AS names.
public struct CymruDNSResolver: ASNResolver, ASNProgressReporting {
  /// One TXT query for `name` to one server, answered by `deadline` or not at all.
  typealias TXTQuery =
    @Sendable (_ name: String, _ server: String, _ deadline: ContinuousClock.Instant) async ->
    [String]?

  /// Queries in flight at once for one ``resolve(ipv4Addrs:timeout:)`` call. Each holds one UDP
  /// socket and no thread.
  private static let maxConcurrentQueries = 8

  /// DNS servers each query tries, in order.
  private let servers: [String]

  /// Sends one query; the event-based DNS transport outside tests.
  private let query: TXTQuery

  public init() { self.init(servers: DNSClient.defaultTXTServers) }

  /// A resolver that sends its queries to `servers` through `query`. Tests point it at a
  /// loopback responder, or record what each query is given.
  init(servers: [String], query: @escaping TXTQuery = CymruDNSResolver.sendTXTQuery) {
    self.servers = servers
    self.query = query
  }

  /// One query on the event-based DNS transport, given the time left until `deadline`.
  private static func sendTXTQuery(
    name: String, server: String, deadline: ContinuousClock.Instant
  ) async -> [String]? {
    let timeout = secondsUntil(deadline)
    guard timeout > 0 else { return nil }
    return await DNSClient.queryTXT(name: name, timeout: timeout, servers: [server])
  }

  /// Resolves origin ASN metadata through Team Cymru's DNS service.
  ///
  /// - Parameters:
  ///   - ipv4Addrs: IP addresses to resolve. IPv4 and IPv6 literals are supported; empty entries
  ///     are ignored.
  ///   - timeout: How long the whole call may take, in seconds: every origin and AS-name query
  ///     and the fallback to the next server share it, and the call returns what has answered
  ///     when it runs out. It must be finite and greater than zero.
  /// - Returns: A map from each resolved input address to its ASN metadata.
  /// - Throws: ``DNSError/invalidTimeout(_:)`` if `timeout` is not finite and greater than zero.
  #if compiler(>=6.2)
    @concurrent
  #endif
  public func resolve(ipv4Addrs: [String], timeout: TimeInterval = 1.0) async throws -> [String:
    ASNInfo]
  {
    try _validateDNSTimeout(timeout)
    return await resolve(ipv4Addrs: ipv4Addrs, until: .now + .seconds(timeout), publishing: nil)
  }

  /// Resolves as ``resolve(ipv4Addrs:timeout:)`` does, publishing each answer to `log` as it
  /// arrives: an origin with an empty AS name at once, and the entry again when its name comes.
  func resolve(ipv4Addrs: [String], timeout: TimeInterval, publishing log: ASNAnswerLog)
    async throws -> [String: ASNInfo]
  {
    try _validateDNSTimeout(timeout)
    return await resolve(ipv4Addrs: ipv4Addrs, until: .now + .seconds(timeout), publishing: log)
  }

  /// Resolves `ipv4Addrs`, returning by `deadline` with whatever has answered, and publishing each
  /// answer to `log`, when given, as it arrives.
  func resolve(
    ipv4Addrs: [String], until deadline: ContinuousClock.Instant,
    publishing log: ASNAnswerLog? = nil
  ) async -> [String: ASNInfo] {
    // Cymru only has meaningful origin data for globally routable addresses. Mapped IPv4 is
    // normalized so it uses origin.asn.cymru.com, not origin6; results stay keyed by the caller's
    // own presentation of each address.
    guard let keyByInput = prepareASNBatch(ipv4Addrs, until: deadline, key: asnLookupAddress)
    else { return [:] }
    var clock = DeadlineClock(deadline)
    var inputsByKey: [String: [String]] = [:]
    for (input, key) in keyByInput {
      if clock.expired() { return [:] }
      inputsByKey[key, default: []].append(input)
    }
    if inputsByKey.isEmpty { return [:] }

    func info(_ origin: _OriginASNResult, name: String) -> ASNInfo {
      ASNInfo(
        asn: origin.asn, name: name, prefix: origin.prefix, countryCode: origin.cc,
        registry: origin.registry)
    }

    // Phase 1: origin ASNs, each published, without its name, as it arrives.
    var keysByASN: [Int: [String]] = [:]
    let originResults = await Self.concurrentLookups(
      of: Array(inputsByKey.keys), until: deadline,
      { key in await self.lookupOriginASN(ip: key, until: deadline) },
      onResult: { key, origin in
        keysByASN[origin.asn, default: []].append(key)
        guard let log else { return }
        let answered = info(origin, name: "")
        log.publish(
          Dictionary(uniqueKeysWithValues: (inputsByKey[key] ?? []).map { ($0, answered) }))
      })
    if originResults.isEmpty { return [:] }

    // Phase 2: AS names for unique ASNs only, each published, with its entries, as it arrives.
    let asnNames = await Self.concurrentLookups(
      of: Array(keysByASN.keys), until: deadline,
      { asn in await self.lookupASName(asn: asn, until: deadline) },
      onResult: { asn, name in
        guard let log else { return }
        var named: [String: ASNInfo] = [:]
        for key in keysByASN[asn] ?? [] {
          guard let origin = originResults[key] else { continue }
          for input in inputsByKey[key] ?? [] { named[input] = info(origin, name: name) }
        }
        log.publish(named)
      })

    // Combine, keyed by the caller's input presentation.
    var result: [String: ASNInfo] = [:]
    for (key, origin) in originResults {
      let answered = info(origin, name: asnNames[origin.asn] ?? "")
      for input in inputsByKey[key] ?? [] { result[input] = answered }
    }
    return result
  }

  /// Look up origin ASN for a single IP address. Dispatches v4 to
  /// `origin.asn.cymru.com` (dotted-quad reverse) and v6 to
  /// `origin6.asn.cymru.com` (full nibble reverse, RFC 1886 §2.5 style).
  private func lookupOriginASN(
    ip: String, until deadline: ContinuousClock.Instant
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

    let txts = await queryTXT(name: q, until: deadline)
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

  /// Runs `lookup` for each of `keys`, at most ``maxConcurrentQueries`` at a time, and starts the
  /// next only while `deadline` has not passed and the calling task is not cancelled, so a large
  /// batch stops when its time does instead of waking every queued key to find it gone.
  private static func concurrentLookups<Key: Hashable & Sendable, Value: Sendable>(
    of keys: [Key], until deadline: ContinuousClock.Instant,
    _ lookup: @escaping @Sendable (Key) async -> Value?,
    onResult: (Key, Value) -> Void = { _, _ in }
  ) async -> [Key: Value] {
    await withTaskGroup(of: (Key, Value?).self) { group in
      var remaining = keys.makeIterator()
      func startNext() -> Bool {
        guard ContinuousClock.now < deadline, !Task.isCancelled, let key = remaining.next()
        else { return false }
        group.addTask { (key, await lookup(key)) }
        return true
      }
      for _ in 0..<maxConcurrentQueries where !startNext() { break }
      var results: [Key: Value] = [:]
      while let (key, value) = await group.next() {
        if let value {
          results[key] = value
          onResult(key, value)
        }
        _ = startNext()
      }
      return results
    }
  }

  /// TXT strings for `name` from the first of `servers` that answers by `deadline`, or `nil`.
  ///
  /// Each server still to try gets an equal share of the time left, so a silent server cannot use
  /// up the time the next one needs, and a server that fails at once leaves its share to the rest.
  private func queryTXT(name: String, until deadline: ContinuousClock.Instant) async -> [String]? {
    for (index, server) in servers.enumerated() {
      if Task.isCancelled { return nil }
      // Past the deadline the attempt is given the deadline itself, already passed, and the real
      // query sends nothing for it.
      let now = ContinuousClock.now
      let attemptDeadline =
        now < deadline ? now + now.duration(to: deadline) / (servers.count - index) : deadline
      if let answer = await query(name, server, attemptDeadline) { return answer }
    }
    return nil
  }

  /// Look up AS name for a single ASN.
  private func lookupASName(asn: Int, until deadline: ContinuousClock.Instant) async -> String? {
    let qn = "AS\(asn).asn.cymru.com"

    let txts = await queryTXT(name: qn, until: deadline)
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
