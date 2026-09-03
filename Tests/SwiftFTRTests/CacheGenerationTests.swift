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

  @Test("Stale lookups finishing after invalidateNetworkScoped do not re-trip the breaker")
  func staleScopedLookupsDoNotRetripBreaker() async {
    let lookup = MultiSuspendedLookup()
    let cache = RDNSCache(
      lookupDeadline: 0.05,
      resolver: { ip in
        _ = await lookup.resolve(ip)
        try? await Task.sleep(for: .milliseconds(60))
        return nil
      }
    )

    // Start 2 scoped lookups on the old network
    let task1 = Task { await cache.lookup("192.168.1.1") }
    let task2 = Task { await cache.lookup("192.168.1.2") }

    await lookup.waitUntilStarted("192.168.1.1")
    await lookup.waitUntilStarted("192.168.1.2")

    // Invalidate network-scoped rDNS and reset breaker
    await cache.invalidateNetworkScoped()
    #expect(await cache.isSuppressingLookups == false)

    // Resume the stale lookups so they complete with stall durations
    await lookup.resume("192.168.1.1", returning: nil)
    await lookup.resume("192.168.1.2", returning: nil)

    _ = await task1.value
    _ = await task2.value

    // The breaker must NOT be re-tripped by stale lookups
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

  @Test("seedPublicIP accepts valid global IPv4 and IPv6 and canonicalizes")
  func seedValidPublicIP() async {
    let tracer = SwiftFTR(config: SwiftFTRConfig(noReverseDNS: true))

    #expect(await tracer.seedPublicIP("1.1.1.1", source: .validatedCallerCache))
    #expect(await tracer.publicIP == "1.1.1.1")

    #expect(
      await tracer.seedPublicIP("2606:4700:4700:0:0:0:0:1111", source: .gatewayReported))
    #expect(await tracer.publicIP == "2606:4700:4700::1111")

    // IANA Special-Purpose registry entries marked Globally Reachable
    #expect(await tracer.seedPublicIP("192.0.0.9", source: .validatedCallerCache))
    #expect(await tracer.publicIP == "192.0.0.9")
    #expect(await tracer.seedPublicIP("192.0.0.10", source: .validatedCallerCache))
    #expect(await tracer.publicIP == "192.0.0.10")
    #expect(await tracer.seedPublicIP("64:ff9b::1", source: .validatedCallerCache))
    #expect(await tracer.publicIP == "64:ff9b::1")
    #expect(await tracer.seedPublicIP("2001:1::1", source: .validatedCallerCache))
    #expect(await tracer.publicIP == "2001:1::1")
    #expect(await tracer.seedPublicIP("2001:3::1", source: .validatedCallerCache))
    #expect(await tracer.publicIP == "2001:3::1")
    #expect(await tracer.seedPublicIP("2001:4:112::1", source: .validatedCallerCache))
    #expect(await tracer.publicIP == "2001:4:112::1")
    #expect(await tracer.seedPublicIP("2001:20::1", source: .validatedCallerCache))
    #expect(await tracer.publicIP == "2001:20::1")
    #expect(await tracer.seedPublicIP("2001:30::1", source: .validatedCallerCache))
    #expect(await tracer.publicIP == "2001:30::1")
  }

  @Test("seedPublicIP rejects non-global, malformed, and sentinel strings")
  func seedRejectsNonGlobalAndSentinels() async {
    let tracer = SwiftFTR(config: SwiftFTRConfig(noReverseDNS: true))
    #expect(await tracer.seedPublicIP("8.8.8.8", source: .validatedCallerCache))
    #expect(await tracer.publicIP == "8.8.8.8")

    let invalidSeeds = [
      "unknown",
      "",
      "not-an-ip",
      "192.168.1.1",  // RFC 1918
      "10.0.0.1",  // RFC 1918
      "172.16.0.1",  // RFC 1918
      "100.64.1.1",  // CGNAT
      "169.254.1.1",  // link-local
      "127.0.0.1",  // loopback
      "::1",  // loopback v6
      "fe80::1",  // link-local v6
      "fc00::1",  // ULA v6
      "224.0.0.1",  // multicast
      "0.0.0.0",  // unspecified
      "192.0.0.1",  // RFC 6890 non-reachable in 192.0.0.0/24
      "192.0.2.1",  // RFC 5737 TEST-NET-1
      "198.18.0.1",  // RFC 2544 Benchmarking
      "198.51.100.1",  // RFC 5737 TEST-NET-2
      "203.0.113.1",  // RFC 5737 TEST-NET-3
      "240.0.0.1",  // RFC 1112 Class E reserved
      "255.255.255.255",  // Limited broadcast
      "64:ff9b:1::1",  // RFC 8215 Local-Use IPv4/IPv6 translation
      "100::1",  // RFC 6666 Discard-only
      "100:0:0:1::1",  // RFC 9780 Dummy IPv6 prefix
      "2001::1",  // RFC 4380 Teredo in 2001::/23
      "2001:2::1",  // RFC 5180 Benchmarking in 2001::/23
      "2001:5::1",  // Unallocated / reserved within 2001::/23 umbrella
      "2001:10::1",  // RFC 4843 Deprecated ORCHID in 2001::/23
      "2001:db8::1",  // RFC 3849 IPv6 documentation
      "3fff::1",  // RFC 9637 IPv6 documentation
      "5f00::1",  // RFC 9602 SRv6 SIDs
      "2606:4700::1%en0",  // Global IPv6 with zone suffix
      "2606:4700::1%invalid",  // Global IPv6 with invalid zone suffix
      "%en0",  // Malformed zone-only string
    ]

    for seed in invalidSeeds {
      let accepted = await tracer.seedPublicIP(seed, source: .validatedCallerCache)
      #expect(!accepted, Comment(rawValue: "\(seed) should have been rejected by seedPublicIP"))
      // Existing seed remains untouched
      #expect(await tracer.publicIP == "8.8.8.8")
    }
  }

  @Test("In-flight discovery cannot overwrite a newer manual seed")
  func discoveryCannotOverwriteManualSeed() async {
    let lookup = SuspendedLookup()
    let tracer = SwiftFTR(config: SwiftFTRConfig(noReverseDNS: true))

    let task = Task {
      await tracer.effectivePublicIPForClassification {
        await lookup.resolve("public-ip")
      }
    }
    await lookup.waitUntilStarted()

    // Caller seeds a newer public IP while discovery is in-flight
    #expect(await tracer.seedPublicIP("1.1.1.1", source: .validatedCallerCache))
    #expect(await tracer.publicIP == "1.1.1.1")

    // Older discovery now finishes with a different IP
    await lookup.resume(returning: "8.8.8.8")

    let result = await task.value
    // Should return the newer seed, NOT the discovered IP
    #expect(result == "1.1.1.1")
    #expect(await tracer.publicIP == "1.1.1.1")
  }

  @Test("seedPublicIP does not survive invalidation, clear, or network change")
  func seedInvalidationLifecycle() async {
    let tracer = SwiftFTR(config: SwiftFTRConfig(noReverseDNS: true))

    // Test invalidatePublicIP
    #expect(await tracer.seedPublicIP("1.1.1.1", source: .validatedCallerCache))
    #expect(await tracer.publicIP == "1.1.1.1")
    await tracer.invalidatePublicIP()
    #expect(await tracer.publicIP == nil)

    // Test clearCaches
    #expect(await tracer.seedPublicIP("1.1.1.1", source: .validatedCallerCache))
    #expect(await tracer.publicIP == "1.1.1.1")
    await tracer.clearCaches()
    #expect(await tracer.publicIP == nil)

    // Test networkChanged
    #expect(await tracer.seedPublicIP("1.1.1.1", source: .validatedCallerCache))
    #expect(await tracer.publicIP == "1.1.1.1")
    await tracer.networkChanged()
    #expect(await tracer.publicIP == nil)
  }

  @Test("seedPublicIP bypasses discovery in effectivePublicIPForClassification")
  func seedBypassesDiscovery() async {
    let tracer = SwiftFTR(config: SwiftFTRConfig(noReverseDNS: true))
    #expect(await tracer.seedPublicIP("9.9.9.9", source: .validatedCallerCache))

    let discovered = await tracer.effectivePublicIPForClassification {
      Issue.record("Discovery should not run when seeded")
      return "1.2.3.4"
    }
    #expect(discovered == "9.9.9.9")
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
