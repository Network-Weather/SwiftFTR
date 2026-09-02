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
  /// that exists while this one is alive.
  public func preload() async {
    _ = await getDatabase()
  }

  private func getDatabase() async -> UltraCompactDatabase? {
    switch loadState {
    case .loaded(let handle):
      return handle.database
    case .failed:
      return nil
    case .notLoaded:
      // Concurrent callers on this actor all reach the store, which coalesces them into one load.
      do {
        let handle = try await store.handle(for: source)
        loadState = .loaded(handle)
        return handle.database
      } catch {
        loadState = .failed
        return nil
      }
    }
  }

  #if compiler(>=6.2)
    @concurrent
  #endif
  public func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo]
  {
    let inputIPs = Set(ipv4Addrs)
    let lookupIPs = Set(inputIPs.compactMap(asnLookupAddress))
    guard !lookupIPs.isEmpty else { return [:] }

    guard let db = await getDatabase() else {
      return [:]  // Database failed to load
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
  static let shared = LocalASNDatabaseStore()

  private struct WeakHandle {
    weak var handle: LocalASNDatabaseHandle?
  }

  private var resident: [LocalASNSourceKey: WeakHandle] = [:]
  private var inFlight: [LocalASNSourceKey: Task<LocalASNDatabaseHandle, any Error>] = [:]

  /// Number of loads this store has started. Tests read it to prove that resolvers share.
  private(set) var loadCount = 0

  init() {}

  /// Returns the shared handle for `source`, loading it if no live resolver already holds one.
  func handle(for source: LocalASNSource) async throws -> LocalASNDatabaseHandle {
    let key = LocalASNSourceKey(source)
    if let handle = resident[key]?.handle {
      return handle
    }
    if let task = inFlight[key] {
      return try await task.value
    }

    loadCount += 1
    let task = Task<LocalASNDatabaseHandle, any Error> {
      LocalASNDatabaseHandle(try await Self.load(source))
    }
    inFlight[key] = task
    defer { inFlight[key] = nil }

    let handle = try await task.value
    resident[key] = WeakHandle(handle: handle)
    return handle
  }

  /// Whether at least one live resolver currently holds the database for `source`.
  func isResident(_ source: LocalASNSource) -> Bool {
    resident[LocalASNSourceKey(source)]?.handle != nil
  }

  /// Loads a database off the actor so decompression never blocks other sources' requests.
  #if compiler(>=6.2)
    @concurrent
  #endif
  private static func load(_ source: LocalASNSource) async throws -> UltraCompactDatabase {
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
