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

  @Test("invalidateNetworkScoped evicts only non-global entries and preserves global ones")
  func scopedEvictionPreservesGlobal() async {
    let resolver = CountingResolver(result: "resolved.example")
    let cache = RDNSCache(resolver: { ip in await resolver.resolve(ip) })

    let scopedIPs = [
      "192.168.1.1",
      "10.0.0.1",
      "172.16.0.1",
      "100.64.0.1",
      "169.254.1.1",
      "127.0.0.1",
      "::1",
      "fe80::1",
      "fc00::1",
    ]

    let globalIPs = [
      "1.1.1.1",
      "8.8.8.8",
      "2606:4700:4700::1111",
    ]

    for ip in scopedIPs + globalIPs {
      _ = await cache.lookup(ip)
    }
    #expect(await cache.count == scopedIPs.count + globalIPs.count)

    let callsBefore = await resolver.callCount

    // Perform network-scoped eviction
    await cache.invalidateNetworkScoped()

    // Global IPs should remain cached (no additional resolver call)
    for ip in globalIPs {
      #expect(await cache.lookup(ip) == "resolved.example")
    }
    #expect(await resolver.callCount == callsBefore)

    // Scoped IPs were evicted, so looking them up hits the resolver again
    for ip in scopedIPs {
      _ = await cache.lookup(ip)
    }
    #expect(await resolver.callCount == callsBefore + scopedIPs.count)
  }

  @Test("invalidateNetworkScoped resets the stall breaker")
  func scopedEvictionResetsStallBreaker() async {
    let cache = RDNSCache(
      lookupDeadline: 0.05,
      resolver: { _ in
        try? await Task.sleep(for: .milliseconds(60))
        return nil
      }
    )

    _ = await cache.lookup("192.0.2.1")
    _ = await cache.lookup("192.0.2.2")
    #expect(await cache.isSuppressingLookups)

    await cache.invalidateNetworkScoped()
    #expect(await cache.isSuppressingLookups == false)
  }

  @Test("In-flight scoped lookup is rejected while concurrent global lookup succeeds")
  func inFlightScopedVsGlobal() async {
    let lookup = MultiSuspendedLookup()
    let cache = RDNSCache(resolver: { ip in await lookup.resolve(ip) })

    let scopedTask = Task { await cache.lookup("192.168.1.1") }
    let globalTask = Task { await cache.lookup("1.1.1.1") }

    await lookup.waitUntilStarted("192.168.1.1")
    await lookup.waitUntilStarted("1.1.1.1")

    // Invalidate network-scoped rDNS while both are in flight
    await cache.invalidateNetworkScoped()

    await lookup.resume("192.168.1.1", returning: "router.local")
    await lookup.resume("1.1.1.1", returning: "one.one.one.one")

    let scopedResult = await scopedTask.value
    let globalResult = await globalTask.value

    #expect(scopedResult == nil)
    #expect(globalResult == "one.one.one.one")

    // Global result is cached; scoped result is NOT cached
    #expect(await cache.count == 1)
  }

  @Test("SwiftFTR.invalidateNetworkScopedRDNS clears scoped entries via actor")
  func tracerScopedEviction() async {
    let tracer = SwiftFTR(config: SwiftFTRConfig(noReverseDNS: false))
    _ = await tracer.rdnsCache.lookup("192.168.1.1")
    _ = await tracer.rdnsCache.lookup("1.1.1.1")

    await tracer.invalidateNetworkScopedRDNS()
    #expect(await tracer.rdnsCache.count == 1)
  }
}

private actor MultiSuspendedLookup {
  private var startedKeys: Set<String> = []
  private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
  private var continuations: [String: CheckedContinuation<String?, Never>] = [:]

  func resolve(_ key: String) async -> String? {
    startedKeys.insert(key)
    if let waiters = startWaiters.removeValue(forKey: key) {
      for waiter in waiters { waiter.resume() }
    }
    return await withCheckedContinuation { cont in
      continuations[key] = cont
    }
  }

  func waitUntilStarted(_ key: String) async {
    if startedKeys.contains(key) { return }
    await withCheckedContinuation { cont in
      startWaiters[key, default: []].append(cont)
    }
  }

  func resume(_ key: String, returning value: String?) {
    continuations.removeValue(forKey: key)?.resume(returning: value)
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
