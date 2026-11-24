import Foundation
import SwiftIP2ASN

/// ASN resolver using local IP2ASN database for microsecond lookups.
///
/// This resolver uses Swift-IP2ASN's embedded or remote database for fast, offline
/// ASN lookups. No network requests are made after initial database load.
///
/// The loaded database is shared process-wide: every `LocalASNResolver` (and therefore every
/// `SwiftFTR` instance and `HybridASNResolver`) built for the same ``LocalASNSource`` reads one
/// copy, loaded once, through an internal process-wide store. The copy is released when the last
/// resolver using it goes away, so keep one resolver alive to keep the database resident.
///
/// Usage:
/// ```swift
/// // Use package-embedded database
/// let resolver = LocalASNResolver(source: .embedded)
///
/// // Use app-bundled database with auto-updates
/// let resolver = LocalASNResolver(source: .remote(
///     bundledPath: Bundle.main.path(forResource: "ip2asn", ofType: "ultra"),
///     url: nil  // Uses default URL
/// ))
/// ```
public actor LocalASNResolver: ASNResolver {
  private enum LoadState: Sendable {
    case notLoaded
    /// The shared load this resolver is waiting on. Holding it keeps its database alive for this
    /// resolver once it finishes, even when every caller stopped waiting before then.
    case loading(SharedWork<LocalASNDatabaseHandle>)
    case loaded(LocalASNDatabaseHandle)
    case failed
  }

  private var loadState: LoadState = .notLoaded
  private let source: LocalASNSource
  private let store: LocalASNDatabaseStore

  public init(source: LocalASNSource = .embedded) {
    self.init(source: source, store: .shared)
  }

  /// Creates a resolver that loads through `store` instead of the process-wide one.
  ///
  /// Tests use a private store so load counts are exact and independent of other tests.
  init(source: LocalASNSource, store: LocalASNDatabaseStore) {
    self.source = source
    self.store = store
  }

  /// Preload the database (call early to avoid first-use latency).
  ///
  /// Loading the embedded database takes tens of milliseconds. Because the database is shared per
  /// source, preloading through any one resolver also serves every other resolver for that source
  /// that exists while this one is alive. Waits for the load to finish, or returns when the calling
  /// task is cancelled, leaving the load running.
  public func preload() async {
    _ = try? await database(until: nil)
  }

  /// The loaded database, or `nil` when it failed to load or `deadline` passed first.
  ///
  /// Only a failed load is remembered. A caller that stops waiting, at its deadline or because it
  /// was cancelled, leaves the shared load running for every other caller and for this resolver's
  /// next lookup.
  ///
  /// - Throws: `CancellationError` when the calling task is cancelled before the database is ready.
  private func database(until deadline: ContinuousClock.Instant?) async throws -> (
    any LocalASNTable
  )? {
    let load: SharedWork<LocalASNDatabaseHandle>
    switch loadState {
    case .loaded(let handle):
      return handle.database
    case .failed:
      return nil
    case .loading(let task):
      load = task
    case .notLoaded:
      // Concurrent callers on this actor all reach the store, which coalesces them into one load.
      let task = await store.loadTask(for: source)
      if case .notLoaded = loadState { loadState = .loading(task) }
      return try await database(until: deadline)
    }

    do {
      guard let handle = try await load.value(until: deadline) else { return nil }
      if case .loading = loadState { loadState = .loaded(handle) }
      return handle.database
    } catch {
      if Task.isCancelled { throw CancellationError() }
      if case .loading = loadState { loadState = .failed }
      return nil
    }
  }

  /// Resolves `ipv4Addrs` from the database. `timeout` bounds the whole call: the wait for a
  /// database that is still loading, and the lookups, which run off the resolver so one caller's
  /// batch does not hold up another's.
  ///
  /// - Throws: `CancellationError` when the calling task is cancelled while the database loads.
  #if compiler(>=6.2)
    @concurrent
  #endif
  public func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo]
  {
    try await resolve(ipv4Addrs: ipv4Addrs, until: asnDeadline(after: timeout))
  }

  /// Resolves `ipv4Addrs`, returning what it has at `deadline`: only acquiring the database runs
  /// on the resolver, and the batch checks the deadline as it goes.
  #if compiler(>=6.2)
    @concurrent
  #endif
  nonisolated func resolve(ipv4Addrs: [String], until deadline: ContinuousClock.Instant?)
    async throws -> [String: ASNInfo]
  {
    // Each input with a lookup key; several inputs can share one (mapped IPv4, for example).
    guard let keyByInput = prepareASNBatch(ipv4Addrs, until: deadline, key: asnLookupAddress),
      !keyByInput.isEmpty
    else { return [:] }

    guard let db = try await database(until: deadline) else {
      return [:]  // Failed to load, or still loading at the deadline
    }

    var clock = DeadlineClock(deadline)
    var infoByKey: [String: ASNInfo?] = [:]
    var results: [String: ASNInfo] = [:]
    for (ip, key) in keyByInput {
      if clock.expired() { break }
      let info: ASNInfo?
      if let known = infoByKey[key] {
        info = known
      } else {
        info = db.lookup(key).map { ASNInfo(asn: Int($0.asn), name: $0.name ?? "") }
        infoByKey[key] = info
      }
      if let info { results[ip] = info }
    }
    return results
  }
}

// MARK: - Shared database store

/// Hashable identity of a ``LocalASNSource``, used to key the shared database store.
///
/// Two sources with the same key load byte-identical databases, so their resolvers share one copy.
enum LocalASNSourceKey: Hashable, Sendable {
  case embedded
  case bundled(String)
  case remote(bundledPath: String?, url: URL?)

  init(_ source: LocalASNSource) {
    switch source {
    case .embedded:
      self = .embedded
    case .bundled(let path):
      self = .bundled(path)
    case .remote(let bundledPath, let url):
      self = .remote(bundledPath: bundledPath, url: url)
    }
  }
}

/// One loaded database, shared by every resolver that asked for the same source.
///
/// Resolvers hold the handle strongly and the store holds it weakly, so the database stays resident
/// exactly as long as at least one resolver for its source is alive.
final class LocalASNDatabaseHandle: Sendable {
  let database: any LocalASNTable

  init(_ database: any LocalASNTable) {
    self.database = database
  }
}

/// What a loaded database answers: the origin ASN and AS name of an address.
///
/// The embedded and remote databases conform; tests load a small table through
/// ``LocalASNDatabaseStore/init(loader:)`` instead of the real 15 MB one.
protocol LocalASNTable: Sendable {
  func lookup(_ ipString: String) -> (asn: UInt32, name: String?)?
}

extension UltraCompactDatabase: LocalASNTable {}

/// Process-wide store that loads each ``LocalASNSource`` once and shares it between resolvers.
///
/// Requests for a source whose load is still in flight join that load instead of starting another,
/// so N tracers constructed at once cost one decompression, not N. A failed load is not remembered
/// here: the next request retries, while the resolver that observed the failure keeps its own
/// failed state. A caller that stops waiting does not stop the load.
actor LocalASNDatabaseStore {
  static let shared = LocalASNDatabaseStore()

  private struct WeakHandle {
    weak var handle: LocalASNDatabaseHandle?
  }

  /// Loads the database for one source.
  typealias Loader = @Sendable (LocalASNSource) async throws -> any LocalASNTable

  private var resident: [LocalASNSourceKey: WeakHandle] = [:]
  private var inFlight: [LocalASNSourceKey: SharedWork<LocalASNDatabaseHandle>] = [:]
  private let loader: Loader

  /// Number of loads this store has started. Tests read it to prove that resolvers share.
  private(set) var loadCount = 0

  /// Creates a store that loads each source with `loader`: the real databases by default, a test's
  /// own table otherwise.
  init(loader: @escaping Loader = { try await LocalASNDatabaseStore.load($0) }) {
    self.loader = loader
  }

  /// The load of `source`'s database: one already finished when a live resolver holds it, the one
  /// in flight when there is one, or a new one.
  ///
  /// The load belongs to the store, not to any caller: it is never cancelled, and it records its
  /// own result here when it ends, however many callers are still waiting for it.
  func loadTask(for source: LocalASNSource) -> SharedWork<LocalASNDatabaseHandle> {
    let key = LocalASNSourceKey(source)
    if let handle = resident[key]?.handle {
      return SharedWork(finished: handle)
    }
    if let task = inFlight[key] {
      return task
    }

    loadCount += 1
    let loader = self.loader
    let task = Task<LocalASNDatabaseHandle, any Error>.detached {
      do {
        let handle = LocalASNDatabaseHandle(try await loader(source))
        await self.finishLoad(key, handle: handle)
        return handle
      } catch {
        await self.finishLoad(key, handle: nil)
        throw error
      }
    }
    let work = SharedWork(task)
    inFlight[key] = work
    return work
  }

  private func finishLoad(_ key: LocalASNSourceKey, handle: LocalASNDatabaseHandle?) {
    inFlight[key] = nil
    if let handle {
      resident[key] = WeakHandle(handle: handle)
    }
  }

  /// Whether at least one live resolver currently holds the database for `source`.
  func isResident(_ source: LocalASNSource) -> Bool {
    resident[LocalASNSourceKey(source)]?.handle != nil
  }

  /// Loads a database off the actor so decompression never blocks other sources' requests.
  #if compiler(>=6.2)
    @concurrent
  #endif
  private static func load(_ source: LocalASNSource) async throws -> any LocalASNTable {
    switch source {
    case .embedded:
      return try EmbeddedDatabase.loadUltraCompact()
    case .bundled(let path):
      return try UltraCompactDatabase(path: path)
    case .remote(let bundledPath, let url):
      // Works offline immediately when bundledPath is provided.
      let remote: RemoteDatabase
      if let url = url {
        remote = RemoteDatabase(remoteURL: url, bundledDatabasePath: bundledPath)
      } else {
        remote = RemoteDatabase(bundledDatabasePath: bundledPath)
      }
      return try await remote.load()
    }
  }
}
