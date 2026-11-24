import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// The flow workers `discoverPaths()` runs must honour every setting of the tracer that started
/// them: its reverse-DNS budget and cache, its ASN resolver, and each `SwiftFTRConfig` field
/// other than the flow-specific overrides.
@Suite("Multipath: flow workers inherit the caller's configuration")
struct MultipathWorkerConfigTests {
  /// Longer than any default budget a flow could fall back to (5 s reverse DNS, 6 s public IP).
  static let watchdog: TimeInterval = 20

  @Test("A flow's reverse DNS goes through the caller's cache, under its deadline")
  func flowHonoursRDNSLookupTimeout() async throws {
    let lookups = FaultCounter()
    let deadline: TimeInterval = 0.3
    let wrongTimeouts = FaultCounter()
    // The deadline the caller's cache was built with, as `SwiftFTR(config:)` builds it from
    // `rdnsLookupTimeout`. A flow that built its own cache would never reach this resolver.
    let rdns = RDNSCache(lookupDeadline: deadline) { _, timeout in
      lookups.increment()
      if timeout != deadline { wrongTimeouts.increment() }
      return .timedOut
    }
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 3))
    defer { network.stop() }
    let tracer = offlineTracer(
      SwiftFTRConfig(maxHops: 4, rdnsLookupTimeout: deadline), rdns: rdns, publicIP: "198.51.100.10"
    )
    let config = MultipathConfig(
      flowVariations: 1, maxPaths: 4, earlyStopThreshold: 1, timeoutMs: 2000, maxHops: 4)

    let topology = try await network.install {
      try await measure(within: Self.watchdog) {
        try await tracer.discoverPaths(to: "fake.test", config: config)
      }.0
    }
    #expect(lookups.value > 0, "the flow never consulted the caller's reverse-DNS cache")
    #expect(wrongTimeouts.value == 0, "a lookup was not given the caller's deadline")
    #expect(topology.paths.count == 1)
    #expect(topology.paths.first?.trace.hops.allSatisfy { $0.hostname == nil } == true)
  }

  @Test("A flow classifies with the caller's ASN resolver")
  func flowUsesCallerASNResolver() async throws {
    let publicIP = "198.51.100.10"
    let resolver = MultipathRecordingASNResolver(
      mapping: [publicIP: ASNInfo(asn: 64500, name: "CALLER-RESOLVER")])
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    let tracer = SwiftFTR(
      config: SwiftFTRConfig(maxHops: 4, noReverseDNS: true, asnResolverStrategy: .embedded),
      rdnsCache: RDNSCache { _, _ in .noSuchRecord },
      asnResolver: resolver,
      publicIPCache: testPublicIPCache(publicIP))
    let config = MultipathConfig(
      flowVariations: 1, maxPaths: 4, earlyStopThreshold: 1, timeoutMs: 2000, maxHops: 4)

    let topology = try await network.install {
      try await measure(within: Self.watchdog) {
        try await tracer.discoverPaths(to: "fake.test", config: config)
      }.0
    }
    #expect(await resolver.requestedAddresses().contains(publicIP))
    #expect(topology.paths.first?.trace.clientASN == 64500)
    #expect(topology.paths.first?.trace.clientASName == "CALLER-RESOLVER")
  }

  /// Every stored property of `SwiftFTRConfig`. A field added to the type fails this test until it
  /// is listed here and given a non-default value in `callerConfig`, which then checks that flows
  /// carry it.
  static let configFields: Set<String> = [
    "maxHops", "maxWaitMs", "payloadSize", "publicIP", "enableLogging", "noReverseDNS",
    "rdnsCacheTTL", "rdnsCacheSize", "rdnsLookupTimeout", "publicIPDiscoveryTimeout",
    "interface", "sourceIP", "asnResolverStrategy", "preferredFamily", "publicIPResolver",
  ]

  /// A caller configuration with every field away from its default.
  static let callerConfig = SwiftFTRConfig(
    maxHops: 17,
    maxWaitMs: 1234,
    payloadSize: 99,
    publicIP: "9.9.9.9",
    enableLogging: true,
    noReverseDNS: true,
    rdnsCacheTTL: 42,
    rdnsCacheSize: 7,
    rdnsLookupTimeout: 0.7,
    publicIPDiscoveryTimeout: 1.9,
    interface: "lo0",
    sourceIP: "127.0.0.1",
    asnResolverStrategy: .dns,
    preferredFamily: .auto,
    publicIPResolver: .disabled
  )

  static func fields(of config: SwiftFTRConfig) -> [String: String] {
    var result: [String: String] = [:]
    for child in Mirror(reflecting: config).children {
      guard let label = child.label else { continue }
      result[label] = String(describing: child.value)
    }
    return result
  }

  @Test("A flow's configuration is the caller's except the documented overrides")
  func flowConfigCopiesEveryField() async {
    let caller = Self.fields(of: Self.callerConfig)
    let defaults = Self.fields(of: SwiftFTRConfig())
    #expect(
      Set(caller.keys) == Self.configFields,
      "SwiftFTRConfig's fields changed: update configFields and callerConfig")
    #expect(SwiftFTRConfig.multipathFlowOverrides == ["maxHops", "maxWaitMs", "preferredFamily"])
    for label in Self.configFields.subtracting(SwiftFTRConfig.multipathFlowOverrides) {
      #expect(caller[label] != defaults[label], "callerConfig leaves \(label) at its default")
    }

    let rdns = RDNSCache { _, _ in .noSuchRecord }
    let resolver = MultipathRecordingASNResolver(mapping: [:])
    let spawner = SwiftFTR.MultipathWorkerSpawner(
      baseConfig: Self.callerConfig, rdnsCache: rdns, asnResolver: resolver, publicIP: nil)
    let flow = spawner.makeFlowTracer(maxHops: 5, timeoutMs: 321)
    let worker = Self.fields(of: flow.config)

    #expect(Set(worker.keys) == Self.configFields)
    for label in Self.configFields.subtracting(SwiftFTRConfig.multipathFlowOverrides) {
      #expect(worker[label] == caller[label], "a flow dropped the caller's \(label)")
    }
    #expect(flow.config.maxHops == 5)
    #expect(flow.config.maxWaitMs == 321)
    #expect(flow.config.preferredFamily == .v4)
    let flowCache = await flow.rdnsCache
    let flowResolver = await flow.asnResolver
    // Compared outside `#expect`: Swift 6.1 crashes lowering the identity comparison of an
    // existential with an actor when the macro captures its operands.
    let sharesCache = flowCache === rdns
    let sharesResolver = (flowResolver as AnyObject) === (resolver as AnyObject)
    #expect(sharesCache, "a flow must share the caller's reverse-DNS cache")
    #expect(sharesResolver, "a flow must use the caller's ASN resolver")
    #expect(await flow.publicIP(for: .v4)?.address == "9.9.9.9")
  }

}

private actor MultipathRecordingASNResolver: ASNResolver {
  private let mapping: [String: ASNInfo]
  private var addresses: Set<String> = []

  init(mapping: [String: ASNInfo]) {
    self.mapping = mapping
  }

  func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
    addresses.formUnion(ipv4Addrs)
    return mapping.filter { ipv4Addrs.contains($0.key) }
  }

  func requestedAddresses() -> Set<String> {
    addresses
  }
}
