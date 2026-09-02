import Foundation
import Testing

@testable import SwiftFTR

/// Guards the default resolver strategy: the local database must cover the addresses a DNS
/// lookup would, or switching the default trades accuracy for speed.
///
/// Also prints cold and warm timings, since the cold path is the one production lives in —
/// callers that discard caches on a network change re-pay it every time.
@Suite(.serialized)
struct AsnStrategyBench {
  static var skipsNetwork: Bool {
    ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")
  }

  // A spread of well-known public addresses across several networks.
  static let addresses = [
    "1.1.1.1", "8.8.8.8", "9.9.9.9", "208.67.222.222", "4.2.2.2",
    "104.16.132.229", "151.101.1.140", "13.107.42.14", "142.250.72.206", "17.253.144.10",
  ]

  @Test("Local strategies cover what DNS covers", .enabled(if: !AsnStrategyBench.skipsNetwork))
  func localStrategiesMatchDNSCoverage() async throws {
    for (label, strategy) in [
      (".dns    ", ASNResolverStrategy.dns),
      (".hybrid ", ASNResolverStrategy.hybrid(.embedded, fallbackTimeout: 1.0)),
      (".embedded", ASNResolverStrategy.embedded),
    ] {
      let tracer = SwiftFTR(config: SwiftFTRConfig(asnResolverStrategy: strategy))
      _ = tracer  // resolver is created during init
      let resolver: ASNResolver
      switch strategy {
      case .dns: resolver = CachingASNResolver(base: CymruDNSResolver())
      case .embedded: resolver = LocalASNResolver(source: .embedded)
      case .hybrid(let s, let t): resolver = HybridASNResolver(source: s, fallbackTimeout: t)
      case .remote(let b, let u):
        resolver = LocalASNResolver(source: .remote(bundledPath: b, url: u))
      }

      // Cold pass: includes database load for local strategies, and populates the DNS cache.
      let coldStart = monotonicNow()
      let result = (try? await resolver.resolve(ipv4Addrs: Self.addresses, timeout: 2.0)) ?? [:]
      let cold = monotonicNow() - coldStart

      // Warm pass on the same resolver instance: steady-state lookup cost.
      let warmStart = monotonicNow()
      _ = try? await resolver.resolve(ipv4Addrs: Self.addresses, timeout: 2.0)
      let warm = monotonicNow() - warmStart

      print(
        "  \(label)  resolved \(result.count)/\(Self.addresses.count)  cold=\(String(format: "%.3f", cold))s  warm=\(String(format: "%.4f", warm))s"
      )

      #expect(
        result.count == Self.addresses.count,
        "\(label) resolved \(result.count)/\(Self.addresses.count); the default strategy must not lose coverage"
      )
    }
  }
}
