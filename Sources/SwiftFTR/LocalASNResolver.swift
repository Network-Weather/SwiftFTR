import Foundation
import SwiftIP2ASN

/// ASN resolver using local IP2ASN database for microsecond lookups.
///
/// This resolver uses Swift-IP2ASN's embedded or remote database for fast, offline
/// ASN lookups. No network requests are made after initial database load.
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
    case loading(Task<UltraCompactDatabase?, any Error>)
    case loaded(UltraCompactDatabase)
    case failed
  }

  private var loadState: LoadState = .notLoaded
  private let source: LocalASNSource
  private var remoteDatabase: RemoteDatabase?

  public init(source: LocalASNSource = .embedded) {
    self.source = source
  }

  /// Preload the database (call early to avoid first-use latency).
  /// Typical load time is ~35-40ms.
  public func preload() async {
    _ = await getDatabase()
  }

  private func getDatabase() async -> UltraCompactDatabase? {
    switch loadState {
    case .loaded(let db): return db
    case .failed: return nil
    case .loading(let task): return try? await task.value
    case .notLoaded:
      let task = Task<UltraCompactDatabase?, any Error> { [source] in
        switch source {
        case .embedded:
          return try EmbeddedDatabase.loadUltraCompact()
        case .bundled(let path):
          return try UltraCompactDatabase(path: path)
        case .remote(let bundledPath, let url):
          // Use RemoteDatabase with optional bundled fallback (0.2.0 API)
          // Works offline immediately if bundledPath provided
          let remote: RemoteDatabase
          if let url = url {
            remote = RemoteDatabase(
              remoteURL: url,
              bundledDatabasePath: bundledPath
            )
          } else {
            remote = RemoteDatabase(bundledDatabasePath: bundledPath)
          }
          return try await remote.load()
        }
      }
      loadState = .loading(task)
      if let db = try? await task.value {
        loadState = .loaded(db)
        return db
      }
      loadState = .failed
      return nil
    }
  }

  #if compiler(>=6.2)
    @concurrent
  #endif
  public func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo]
  {
    let publicIPs = Set(ipv4Addrs)
      .filter { !$0.isEmpty && !isPrivateIPv4($0) && !isCGNATIPv4($0) }
    guard !publicIPs.isEmpty else { return [:] }

    guard let db = await getDatabase() else {
      return [:]  // Database failed to load
    }

    var results: [String: ASNInfo] = [:]
    for ip in publicIPs {
      if let (asn, name) = db.lookup(ip) {
        results[ip] = ASNInfo(
          asn: Int(asn),
          name: name ?? "",
          prefix: nil,
          countryCode: nil,
          registry: nil
        )
      }
    }
    return results
  }
}
