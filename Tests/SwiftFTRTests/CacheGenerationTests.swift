import Foundation
import Testing

@testable import SwiftFTR

@Suite("Cache generation invalidation")
struct CacheGenerationTests {
  @Test(
    "Clearing rDNS during a lookup prevents stale cache repopulation", .timeLimit(.minutes(1)))
  func rdnsClearWinsAgainstInFlightLookup() async {
    let lookup = SuspendedLookup()
    let cache = RDNSCache(
      resolver: { ip in await lookup.resolve(ip) }
    )

    let task = Task { await cache.lookup("192.0.2.1") }
    await lookup.waitUntilStarted()
    await cache.clear()
    await lookup.resume(returning: "old-network.example")

    #expect(await task.value == nil)
    #expect(await cache.count == 0)
  }

  @Test("An unchanged rDNS generation caches the lookup")
  func rdnsLookupCachesNormally() async {
    let resolver = CountingResolver(result: "router.example")
    let cache = RDNSCache(
      resolver: { ip in await resolver.resolve(ip) }
    )

    #expect(await cache.lookup("192.0.2.2") == "router.example")
    #expect(await cache.lookup("192.0.2.2") == "router.example")
    #expect(await resolver.callCount == 1)
    #expect(await cache.count == 1)
  }

  @Test("Public IP discovery cannot cross an invalidation boundary", .timeLimit(.minutes(1)))
  func publicIPInvalidationWinsAgainstDiscovery() async {
    let lookup = SuspendedLookup()
    let tracer = SwiftFTR(config: SwiftFTRConfig(noReverseDNS: true))

    let task = Task {
      await tracer.effectivePublicIPForClassification {
        await lookup.resolve("public-ip")
      }
    }
    await lookup.waitUntilStarted()
    await tracer.invalidatePublicIP()
    await lookup.resume(returning: "198.51.100.7")

    #expect(await task.value == nil)
    #expect(await tracer.publicIP == nil)

    let current = await tracer.effectivePublicIPForClassification {
      "198.51.100.8"
    }
    #expect(current == "198.51.100.8")
    #expect(await tracer.publicIP == "198.51.100.8")
  }
}

private actor SuspendedLookup {
  private var didStart = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var resultContinuation: CheckedContinuation<String?, Never>?

  func resolve(_ key: String) async -> String? {
    _ = key
    didStart = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters { waiter.resume() }

    return await withCheckedContinuation { continuation in
      precondition(resultContinuation == nil)
      resultContinuation = continuation
    }
  }

  func waitUntilStarted() async {
    if didStart { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func resume(returning value: String?) {
    let continuation = resultContinuation
    resultContinuation = nil
    continuation?.resume(returning: value)
  }
}

private actor CountingResolver {
  private let result: String?
  private(set) var callCount = 0

  init(result: String?) {
    self.result = result
  }

  func resolve(_ ip: String) -> String? {
    _ = ip
    callCount += 1
    return result
  }
}
