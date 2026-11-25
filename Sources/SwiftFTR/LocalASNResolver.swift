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
public actor LocalASNResolver: ASNResolver, PublishingASNResolver {
  private enum LoadState: Sendable {
    case notLoaded
    case loading(SharedASNWork<LocalASNDatabaseHandle>)
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
  /// that exists while this one is alive. Cancelling the calling task ends the wait, not the load.
  public func preload() async {
    _ = await database(until: nil)
  }

  /// The database, waiting for its load until `deadline` (`nil` waits as long as it takes) or
  /// until the calling task is cancelled.
  ///
  /// The load is the store's ``SharedASNWork``, asked for by the first caller whose deadline has
  /// not passed and whose task is not cancelled, and never stopped by a caller leaving. Only a
  /// load that failed is remembered as failed.
  private func database(until deadline: TimeInterval?) async -> UltraCompactDatabase? {
    let load: SharedASNWork<LocalASNDatabaseHandle>
    switch loadState {
    case .loaded(let handle):
      return handle.database
    case .failed:
      return nil
    case .loading(let running):
      load = running
    case .notLoaded:
      guard !DiscoveryClock.current.hasPassed(deadline), !Task.isCancelled else { return nil }
      // Concurrent resolvers for one source share the store's one load.
      load = await store.load(source)
      loadState = .loading(load)
    }
    let outcome = await load.wait(until: deadline).outcome
    if case .loading(let current) = loadState, current === load {
      switch outcome {
      case .success(let handle)?: loadState = .loaded(handle)
      case .failure?: loadState = .failed
      case nil: break
      }
    }
    return try? outcome?.get().database
  }

  /// - Parameter timeout: Bounds the wait for a database that is still loading. A lookup in a
  ///   loaded database answers whatever the timeout. One that runs out of time, or whose task is
  ///   cancelled, while the database loads leaves the load running for every other caller.
  /// - Throws: `CancellationError` when the calling task is cancelled while the database loads.
  #if compiler(>=6.2)
    @concurrent
  #endif
  public func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo]
  {
    try await resolve(
      ipv4Addrs, timeout: timeout, deadline: asnDeadline(timeout), publish: { _ in })
  }

  nonisolated func resolve(
    _ addresses: [String], timeout: TimeInterval, deadline: TimeInterval,
    publish: @escaping ASNPublish
  ) async throws -> [String: ASNInfo] {
    let inputIPs = Set(addresses)
    let lookupIPs = Set(inputIPs.compactMap(asnLookupAddress))
    guard !lookupIPs.isEmpty else { return [:] }

    guard let db = await database(until: deadline) else {
      try Task.checkCancellation()
      return [:]  // Database failed to load, or is still loading at the deadline
    }

    var lookupResults: [String: ASNInfo] = [:]
    for ip in lookupIPs {
      if let (asn, name) = db.lookup(ip) {
        lookupResults[ip] = ASNInfo(
          asn: Int(asn),
          name: name ?? "",
          prefix: nil,
          countryCode: nil,
          registry: nil
        )
      }
    }

    var results: [String: ASNInfo] = [:]
    for ip in inputIPs {
      if let lookupIP = asnLookupAddress(for: ip), let info = lookupResults[lookupIP] {
        results[ip] = info
      }
    }
    if !results.isEmpty { publish(results) }
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
  let database: UltraCompactDatabase

  init(_ database: UltraCompactDatabase) {
    self.database = database
  }
}

/// Process-wide store that loads each ``LocalASNSource`` once and shares it between resolvers.
///
/// Requests for a source whose load is still in flight join that load instead of starting another,
/// so N tracers constructed at once cost one decompression, not N. A failed load is not remembered
/// here: the next request retries, while the resolver that observed the failure keeps its own
/// failed state.
actor LocalASNDatabaseStore {
  typealias Loader = @Sendable (LocalASNSource) async throws -> UltraCompactDatabase

  static let shared = LocalASNDatabaseStore()

  private struct WeakHandle {
    weak var handle: LocalASNDatabaseHandle?
  }

  private var resident: [LocalASNSourceKey: WeakHandle] = [:]
  private var inFlight: [LocalASNSourceKey: SharedASNWork<LocalASNDatabaseHandle>] = [:]
  private let loader: Loader

  /// Number of loads this store has started. Tests read it to prove that resolvers share.
  private(set) var loadCount = 0

  /// - Parameter loader: Loads a database; tests substitute one they can hold or fail.
  init(loader: @escaping Loader = { try await LocalASNDatabaseStore.load($0) }) {
    self.loader = loader
  }

  /// The shared load of `source`: one already finished when a live resolver holds its database,
  /// else the load in flight, else a new one. Nothing a caller does stops it.
  func load(_ source: LocalASNSource) -> SharedASNWork<LocalASNDatabaseHandle> {
    let key = LocalASNSourceKey(source)
    if let handle = resident[key]?.handle {
      return SharedASNWork(finished: handle)
    }
    if let running = inFlight[key] {
      return running
    }

    loadCount += 1
    let loader = self.loader
    let work = SharedASNWork<LocalASNDatabaseHandle> { _ in
      do {
        let handle = LocalASNDatabaseHandle(try await loader(source))
        await self.landed(key, handle)
        return handle
      } catch {
        await self.landed(key, nil)
        throw error
      }
    }
    inFlight[key] = work
    return work
  }

  private func landed(_ key: LocalASNSourceKey, _ handle: LocalASNDatabaseHandle?) {
    inFlight[key] = nil
    if let handle { resident[key] = WeakHandle(handle: handle) }
  }

  /// Whether at least one live resolver currently holds the database for `source`.
  func isResident(_ source: LocalASNSource) -> Bool {
    resident[LocalASNSourceKey(source)]?.handle != nil
  }

  /// Loads a database off the actor so decompression never blocks other sources' requests.
  #if compiler(>=6.2)
    @concurrent
  #endif
  static func load(_ source: LocalASNSource) async throws -> UltraCompactDatabase {
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
