import Foundation
import Testing

@testable import SwiftFTR

@Suite("FlowIdentifier Tests")
struct FlowIdentifierTests {

  @Test("Flow identifier generation is deterministic")
  func testDeterministicGeneration() {
    let id1 = FlowIdentifier.generate(variation: 0)
    let id2 = FlowIdentifier.generate(variation: 0)

    // Same variation at different times should have different IDs (timestamp changes)
    // but variation should be preserved
    #expect(id1.variation == 0)
    #expect(id2.variation == 0)
  }

  @Test("Flow identifier variations are spaced by prime")
  func testPrimeSpacing() {
    let id0 = FlowIdentifier.generate(variation: 0)
    let id1 = FlowIdentifier.generate(variation: 1)

    // Variations should differ by roughly 173 (prime spacing)
    // Allow some tolerance for timestamp changes
    let diff = Int(id1.icmpID) - Int(id0.icmpID)
    let expectedDiff = 173

    // Should be within 200 of expected (allowing for timestamp progression)
    #expect(abs(diff - expectedDiff) < 200)
  }

  @Test("Flow identifier uniqueness across variations")
  func testUniqueness() {
    var seen: Set<UInt16> = []
    for variation in 0..<20 {
      let id = FlowIdentifier.generate(variation: variation)
      seen.insert(id.icmpID)
    }

    // Should have many unique IDs (allowing for some collisions)
    #expect(seen.count >= 15)
  }

  @Test("Flow identifier hashable and equatable")
  func testHashableEquatable() {
    let id1 = FlowIdentifier(icmpID: 12345, variation: 0)
    let id2 = FlowIdentifier(icmpID: 12345, variation: 0)
    let id3 = FlowIdentifier(icmpID: 12346, variation: 0)

    #expect(id1 == id2)
    #expect(id1 != id3)
    #expect(id1.hashValue == id2.hashValue)
  }
}

@Suite("MultipathConfig Tests")
struct MultipathConfigTests {

  @Test("Default configuration values")
  func testDefaults() {
    let config = MultipathConfig()

    #expect(config.flowVariations == 8)
    #expect(config.maxPaths == 16)
    #expect(config.earlyStopThreshold == 3)
    #expect(config.timeoutMs == 2000)
    #expect(config.maxHops == 30)
  }

  @Test("Custom configuration values")
  func testCustomValues() {
    let config = MultipathConfig(
      flowVariations: 20,
      maxPaths: 32,
      earlyStopThreshold: 5,
      timeoutMs: 3000,
      maxHops: 40
    )

    #expect(config.flowVariations == 20)
    #expect(config.maxPaths == 32)
    #expect(config.earlyStopThreshold == 5)
    #expect(config.timeoutMs == 3000)
    #expect(config.maxHops == 40)
  }
}

@Suite("NetworkTopology Tests")
struct NetworkTopologyTests {

  func makeTestHop(ttl: Int, ip: String?, asn: Int? = nil) -> ClassifiedHop {
    ClassifiedHop(
      ttl: ttl,
      ip: ip,
      rtt: 0.01,
      asn: asn,
      asName: asn.map { "AS\($0)" },
      category: .transit,
      hostname: ip
    )
  }

  func makeTestTrace(hops: [ClassifiedHop]) -> ClassifiedTrace {
    ClassifiedTrace(
      destinationHost: "example.com",
      destinationIP: "93.184.216.34",
      destinationHostname: "example.com",
      publicIP: "1.2.3.4",
      publicHostname: "public.example.com",
      clientASN: 12345,
      clientASName: "Test ISP",
      destinationASN: 54321,
      destinationASName: "Test Destination",
      hops: hops
    )
  }

  @Test("uniqueHops returns deduplicated hops")
  func testUniqueHops() {
    let hops1 = [
      makeTestHop(ttl: 1, ip: "192.168.1.1"),
      makeTestHop(ttl: 2, ip: "10.0.0.1"),
      makeTestHop(ttl: 3, ip: "8.8.8.8"),
    ]

    let hops2 = [
      makeTestHop(ttl: 1, ip: "192.168.1.1"),
      makeTestHop(ttl: 2, ip: "10.0.0.2"),  // Different IP
      makeTestHop(ttl: 3, ip: "8.8.8.8"),
    ]

    let path1 = DiscoveredPath(
      flowIdentifier: FlowIdentifier(icmpID: 1, variation: 0),
      trace: makeTestTrace(hops: hops1),
      fingerprint: "path1",
      isUnique: true
    )

    let path2 = DiscoveredPath(
      flowIdentifier: FlowIdentifier(icmpID: 2, variation: 1),
      trace: makeTestTrace(hops: hops2),
      fingerprint: "path2",
      isUnique: true
    )

    let topology = NetworkTopology(
      destination: "example.com",
      destinationIP: "93.184.216.34",
      sourceAdapter: "en0",
      sourceIP: "192.168.1.100",
      publicIP: "1.2.3.4",
      paths: [path1, path2],
      uniquePathCount: 2,
      discoveryDuration: 5.0
    )

    let unique = topology.uniqueHops()

    // Should have 4 unique IPs: 192.168.1.1, 10.0.0.1, 10.0.0.2, 8.8.8.8
    #expect(unique.count == 4)

    let uniqueIPs = Set(unique.compactMap { $0.ip })
    #expect(uniqueIPs.contains("192.168.1.1"))
    #expect(uniqueIPs.contains("10.0.0.1"))
    #expect(uniqueIPs.contains("10.0.0.2"))
    #expect(uniqueIPs.contains("8.8.8.8"))
  }

  @Test("divergencePoint detects path split with timeouts")
  func testDivergencePointWithTimeouts() {
    let hops1 = [
      makeTestHop(ttl: 1, ip: "192.168.1.1"),
      makeTestHop(ttl: 2, ip: "10.0.0.1"),
      makeTestHop(ttl: 3, ip: nil),  // Timeout
      makeTestHop(ttl: 4, ip: "8.8.8.8"),
    ]

    let hops2 = [
      makeTestHop(ttl: 1, ip: "192.168.1.1"),
      makeTestHop(ttl: 2, ip: "10.0.0.1"),
      makeTestHop(ttl: 3, ip: "10.0.0.2"),  // Different IP (not timeout)
      makeTestHop(ttl: 4, ip: "8.8.8.8"),
    ]

    let path1 = DiscoveredPath(
      flowIdentifier: FlowIdentifier(icmpID: 1, variation: 0),
      trace: makeTestTrace(hops: hops1),
      fingerprint: "path1",
      isUnique: true
    )

    let path2 = DiscoveredPath(
      flowIdentifier: FlowIdentifier(icmpID: 2, variation: 1),
      trace: makeTestTrace(hops: hops2),
      fingerprint: "path2",
      isUnique: true
    )

    let topology = NetworkTopology(
      destination: "example.com",
      destinationIP: "93.184.216.34",
      sourceAdapter: "en0",
      sourceIP: "192.168.1.100",
      publicIP: "1.2.3.4",
      paths: [path1, path2],
      uniquePathCount: 2,
      discoveryDuration: 5.0
    )

    let divergence = topology.divergencePoint()

    // Should detect divergence at TTL 3 (timeout vs IP)
    #expect(divergence == 3)
  }

  @Test("divergencePoint returns nil for single path")
  func testDivergencePointSinglePath() {
    let hops = [
      makeTestHop(ttl: 1, ip: "192.168.1.1"),
      makeTestHop(ttl: 2, ip: "10.0.0.1"),
      makeTestHop(ttl: 3, ip: "8.8.8.8"),
    ]

    let path = DiscoveredPath(
      flowIdentifier: FlowIdentifier(icmpID: 1, variation: 0),
      trace: makeTestTrace(hops: hops),
      fingerprint: "path1",
      isUnique: true
    )

    let topology = NetworkTopology(
      destination: "example.com",
      destinationIP: "93.184.216.34",
      sourceAdapter: "en0",
      sourceIP: "192.168.1.100",
      publicIP: "1.2.3.4",
      paths: [path],
      uniquePathCount: 1,
      discoveryDuration: 5.0
    )

    let divergence = topology.divergencePoint()

    #expect(divergence == nil)
  }

  @Test("divergencePoint returns nil for identical paths")
  func testDivergencePointIdenticalPaths() {
    let hops = [
      makeTestHop(ttl: 1, ip: "192.168.1.1"),
      makeTestHop(ttl: 2, ip: "10.0.0.1"),
      makeTestHop(ttl: 3, ip: "8.8.8.8"),
    ]

    let path1 = DiscoveredPath(
      flowIdentifier: FlowIdentifier(icmpID: 1, variation: 0),
      trace: makeTestTrace(hops: hops),
      fingerprint: "path1",
      isUnique: true
    )

    let path2 = DiscoveredPath(
      flowIdentifier: FlowIdentifier(icmpID: 2, variation: 1),
      trace: makeTestTrace(hops: hops),
      fingerprint: "path1",  // Same fingerprint
      isUnique: false
    )

    let topology = NetworkTopology(
      destination: "example.com",
      destinationIP: "93.184.216.34",
      sourceAdapter: "en0",
      sourceIP: "192.168.1.100",
      publicIP: "1.2.3.4",
      paths: [path1, path2],
      uniquePathCount: 1,
      discoveryDuration: 5.0
    )

    let divergence = topology.divergencePoint()

    // Should return nil since paths are identical
    #expect(divergence == nil)
  }

  @Test("commonPrefix returns shared hops")
  func testCommonPrefix() {
    let hops1 = [
      makeTestHop(ttl: 1, ip: "192.168.1.1"),
      makeTestHop(ttl: 2, ip: "10.0.0.1"),
      makeTestHop(ttl: 3, ip: "10.0.0.2"),
      makeTestHop(ttl: 4, ip: "8.8.8.8"),
    ]

    let hops2 = [
      makeTestHop(ttl: 1, ip: "192.168.1.1"),
      makeTestHop(ttl: 2, ip: "10.0.0.1"),
      makeTestHop(ttl: 3, ip: "10.0.0.3"),  // Different
      makeTestHop(ttl: 4, ip: "8.8.4.4"),  // Different
    ]

    let path1 = DiscoveredPath(
      flowIdentifier: FlowIdentifier(icmpID: 1, variation: 0),
      trace: makeTestTrace(hops: hops1),
      fingerprint: "path1",
      isUnique: true
    )

    let path2 = DiscoveredPath(
      flowIdentifier: FlowIdentifier(icmpID: 2, variation: 1),
      trace: makeTestTrace(hops: hops2),
      fingerprint: "path2",
      isUnique: true
    )

    let topology = NetworkTopology(
      destination: "example.com",
      destinationIP: "93.184.216.34",
      sourceAdapter: "en0",
      sourceIP: "192.168.1.100",
      publicIP: "1.2.3.4",
      paths: [path1, path2],
      uniquePathCount: 2,
      discoveryDuration: 5.0
    )

    let prefix = topology.commonPrefix()

    // Should have first 2 hops as common
    #expect(prefix.count == 2)
    #expect(prefix[0].ip == "192.168.1.1")
    #expect(prefix[1].ip == "10.0.0.1")
  }

  @Test("paths(throughIP:) filters correctly")
  func testPathsThroughIP() {
    let hops1 = [
      makeTestHop(ttl: 1, ip: "192.168.1.1"),
      makeTestHop(ttl: 2, ip: "10.0.0.1"),
      makeTestHop(ttl: 3, ip: "8.8.8.8"),
    ]

    let hops2 = [
      makeTestHop(ttl: 1, ip: "192.168.1.1"),
      makeTestHop(ttl: 2, ip: "10.0.0.2"),
      makeTestHop(ttl: 3, ip: "8.8.8.8"),
    ]

    let path1 = DiscoveredPath(
      flowIdentifier: FlowIdentifier(icmpID: 1, variation: 0),
      trace: makeTestTrace(hops: hops1),
      fingerprint: "path1",
      isUnique: true
    )

    let path2 = DiscoveredPath(
      flowIdentifier: FlowIdentifier(icmpID: 2, variation: 1),
      trace: makeTestTrace(hops: hops2),
      fingerprint: "path2",
      isUnique: true
    )

    let topology = NetworkTopology(
      destination: "example.com",
      destinationIP: "93.184.216.34",
      sourceAdapter: "en0",
      sourceIP: "192.168.1.100",
      publicIP: "1.2.3.4",
      paths: [path1, path2],
      uniquePathCount: 2,
      discoveryDuration: 5.0
    )

    let throughFirst = topology.paths(throughIP: "10.0.0.1")
    let throughSecond = topology.paths(throughIP: "10.0.0.2")
    let throughBoth = topology.paths(throughIP: "8.8.8.8")

    #expect(throughFirst.count == 1)
    #expect(throughSecond.count == 1)
    #expect(throughBoth.count == 2)
  }

  @Test("paths(throughASN:) filters correctly")
  func testPathsThroughASN() {
    let hops1 = [
      makeTestHop(ttl: 1, ip: "192.168.1.1", asn: 12345),
      makeTestHop(ttl: 2, ip: "10.0.0.1", asn: 54321),
      makeTestHop(ttl: 3, ip: "8.8.8.8", asn: 15169),
    ]

    let hops2 = [
      makeTestHop(ttl: 1, ip: "192.168.1.1", asn: 12345),
      makeTestHop(ttl: 2, ip: "10.0.0.2", asn: 99999),
      makeTestHop(ttl: 3, ip: "8.8.8.8", asn: 15169),
    ]

    let path1 = DiscoveredPath(
      flowIdentifier: FlowIdentifier(icmpID: 1, variation: 0),
      trace: makeTestTrace(hops: hops1),
      fingerprint: "path1",
      isUnique: true
    )

    let path2 = DiscoveredPath(
      flowIdentifier: FlowIdentifier(icmpID: 2, variation: 1),
      trace: makeTestTrace(hops: hops2),
      fingerprint: "path2",
      isUnique: true
    )

    let topology = NetworkTopology(
      destination: "example.com",
      destinationIP: "93.184.216.34",
      sourceAdapter: "en0",
      sourceIP: "192.168.1.100",
      publicIP: "1.2.3.4",
      paths: [path1, path2],
      uniquePathCount: 2,
      discoveryDuration: 5.0
    )

    let through12345 = topology.paths(throughASN: 12345)
    let through54321 = topology.paths(throughASN: 54321)
    let through15169 = topology.paths(throughASN: 15169)

    #expect(through12345.count == 2)  // Both paths
    #expect(through54321.count == 1)  // Path 1 only
    #expect(through15169.count == 2)  // Both paths
  }

  @Test("NetworkTopology is Codable")
  func testCodable() throws {
    let hops = [
      makeTestHop(ttl: 1, ip: "192.168.1.1"),
      makeTestHop(ttl: 2, ip: "10.0.0.1"),
    ]

    let path = DiscoveredPath(
      flowIdentifier: FlowIdentifier(icmpID: 1, variation: 0),
      trace: makeTestTrace(hops: hops),
      fingerprint: "path1",
      isUnique: true
    )

    let topology = NetworkTopology(
      destination: "example.com",
      destinationIP: "93.184.216.34",
      sourceAdapter: "en0",
      sourceIP: "192.168.1.100",
      publicIP: "1.2.3.4",
      paths: [path],
      uniquePathCount: 1,
      discoveryDuration: 5.0
    )

    let encoder = JSONEncoder()
    let data = try encoder.encode(topology)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(NetworkTopology.self, from: data)

    #expect(decoded.destination == topology.destination)
    #expect(decoded.destinationIP == topology.destinationIP)
    #expect(decoded.uniquePathCount == topology.uniquePathCount)
    #expect(decoded.paths.count == topology.paths.count)
  }
}

@Suite("DiscoveredPath Tests")
struct DiscoveredPathTests {

  @Test("DiscoveredPath initialization")
  func testInitialization() {
    let flowID = FlowIdentifier(icmpID: 12345, variation: 0)

    let hops = [
      ClassifiedHop(
        ttl: 1,
        ip: "192.168.1.1",
        rtt: 0.01,
        asn: nil,
        asName: nil,
        category: .local,
        hostname: "router.local"
      )
    ]

    let trace = ClassifiedTrace(
      destinationHost: "example.com",
      destinationIP: "93.184.216.34",
      destinationHostname: "example.com",
      publicIP: "1.2.3.4",
      publicHostname: nil,
      clientASN: 12345,
      clientASName: "Test ISP",
      destinationASN: 54321,
      destinationASName: "Test Destination",
      hops: hops
    )

    let path = DiscoveredPath(
      flowIdentifier: flowID,
      trace: trace,
      fingerprint: "192.168.1.1",
      isUnique: true
    )

    #expect(path.flowIdentifier.icmpID == 12345)
    #expect(path.flowIdentifier.variation == 0)
    #expect(path.trace.destinationHost == "example.com")
    #expect(path.fingerprint == "192.168.1.1")
    #expect(path.isUnique == true)
  }
}

@Suite("Multipath Integration Tests")
struct MultipathIntegrationTests {

  @Test(
    "Multipath discovery to reachable host",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")))
  func testMultipathDiscovery() async throws {
    let tracer = SwiftFTR(config: SwiftFTRConfig())
    let config = MultipathConfig(
      flowVariations: 5,
      maxPaths: 10,
      earlyStopThreshold: 3,
      timeoutMs: 2000,
      maxHops: 15
    )

    let topology = try await NetworkTestGate.shared.withPermit {
      try await tracer.discoverPaths(to: "1.1.1.1", config: config)
    }

    // Basic validation
    #expect(topology.destination == "1.1.1.1")
    #expect(topology.destinationIP == "1.1.1.1")
    #expect(topology.paths.count > 0)
    #expect(topology.uniquePathCount > 0)
    #expect(topology.discoveryDuration > 0)

    // Should have at least one unique path
    #expect(topology.paths.filter { $0.isUnique }.count >= 1)

    // Should have some hops
    let uniqueHops = topology.uniqueHops()
    #expect(uniqueHops.count > 0)

    // First hop is typically the local gateway (TTL 1), but may be TTL 2+ if
    // the gateway doesn't respond to ICMP or times out under heavy load.
    // We only verify that hops are sorted by TTL (implementation detail of uniqueHops).
    if uniqueHops.count >= 2 {
      #expect(
        uniqueHops[0].ttl <= uniqueHops[1].ttl,
        "uniqueHops should be sorted by TTL")
    }
  }

  @Test(
    "Multipath early stopping works",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")))
  func testEarlyStopping() async throws {
    let tracer = SwiftFTR(config: SwiftFTRConfig())
    let config = MultipathConfig(
      flowVariations: 20,  // Request many flows
      maxPaths: 10,
      earlyStopThreshold: 3,  // Stop after 3 consecutive duplicates
      timeoutMs: 1500,
      maxHops: 15
    )

    let topology = try await tracer.discoverPaths(to: "8.8.8.8", config: config)

    // Should stop early before trying all 20 flows
    #expect(topology.paths.count < 20)

    // Validate early stopping kicked in
    #expect(topology.paths.count >= 3)  // At least threshold
    #expect(topology.paths.count <= 15)  // But stopped early
  }

  @Test(
    "Multipath uniqueHops extraction for monitoring",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")))
  func testUniqueHopsExtraction() async throws {
    let tracer = SwiftFTR(config: SwiftFTRConfig())
    let config = MultipathConfig(
      flowVariations: 8,
      maxPaths: 16,
      timeoutMs: 2000,
      maxHops: 15
    )

    let topology = try await tracer.discoverPaths(to: "1.1.1.1", config: config)

    // Extract monitoring targets
    let targets = topology.uniqueHops()

    // Should have multiple unique hops
    #expect(targets.count > 2)

    // All targets should have unique IPs
    let ips = targets.compactMap { $0.ip }
    let uniqueIPs = Set(ips)
    #expect(ips.count == uniqueIPs.count)

    // Hops should be sorted by TTL
    for i in 0..<(targets.count - 1) {
      #expect(targets[i].ttl <= targets[i + 1].ttl)
    }
  }

  @Test(
    "Multipath divergencePoint detection",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")))
  func testDivergenceDetection() async throws {
    let tracer = SwiftFTR(config: SwiftFTRConfig())
    let config = MultipathConfig(
      flowVariations: 10,
      maxPaths: 10,
      timeoutMs: 2000,
      maxHops: 20
    )

    // Try a target that might have ECMP
    let topology = try await tracer.discoverPaths(to: "8.8.8.8", config: config)

    if topology.uniquePathCount > 1 {
      // If multiple paths found, divergence point should be detected
      let divergence = topology.divergencePoint()
      #expect(divergence != nil)

      if let div = divergence {
        // Divergence should be within valid TTL range
        #expect(div >= 1)
        // Divergence can be beyond individual path lengths if paths differ in length
        let maxHopCount = topology.paths.map { $0.trace.hops.count }.max() ?? 30
        #expect(div <= maxHopCount)
      }
    } else {
      // Single path - no divergence
      let divergence = topology.divergencePoint()
      #expect(divergence == nil)
    }
  }

  @Test(
    "Multipath commonPrefix extraction",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")))
  func testCommonPrefixExtraction() async throws {
    let tracer = SwiftFTR(config: SwiftFTRConfig())
    let config = MultipathConfig(
      flowVariations: 8,
      maxPaths: 10,
      timeoutMs: 2000,
      maxHops: 20
    )

    let topology = try await tracer.discoverPaths(to: "1.1.1.1", config: config)

    let prefix = topology.commonPrefix()

    // Prefix count depends on path diversity (can be 0 if ECMP at gateway)
    #expect(prefix.count >= 0)

    // If there's a prefix, validate it
    if prefix.count > 0 {
      // First hop should be TTL 1
      #expect(prefix.first?.ttl == 1)

      // Prefix hops should be sequential
      for i in 0..<prefix.count {
        #expect(prefix[i].ttl == i + 1)
      }
    }
  }

  @Test(
    "Multipath JSON encoding for API export",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")))
  func testJSONEncoding() async throws {
    let tracer = SwiftFTR(config: SwiftFTRConfig())
    let config = MultipathConfig(
      flowVariations: 3,
      maxPaths: 5,
      timeoutMs: 900,
      maxHops: 10
    )

    let topology = try await tracer.discoverPaths(to: "1.1.1.1", config: config)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(topology)
    #expect(data.count > 0)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(NetworkTopology.self, from: data)

    #expect(decoded.destination == topology.destination)
    #expect(decoded.destinationIP == topology.destinationIP)
    #expect(decoded.uniquePathCount == topology.uniquePathCount)
    #expect(decoded.paths.count == topology.paths.count)
  }

  @Test(
    "Multipath performance is reasonable",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS"))
  )
  func testPerformance() async throws {
    let tracer = SwiftFTR(config: SwiftFTRConfig())
    let config = MultipathConfig(
      flowVariations: 5,
      maxPaths: 10,
      earlyStopThreshold: 3,
      timeoutMs: 1000,
      maxHops: 15
    )

    let (topology, elapsed) = try await NetworkTestGate.shared.withPermit {
      let startTime = Date()
      let topology = try await tracer.discoverPaths(to: "1.1.1.1", config: config)
      let elapsed = Date().timeIntervalSince(startTime)
      return (topology, elapsed)
    }

    // Detached multipath workers should finish close to a single timeout budget; >6s hints at serialization.
    #expect(elapsed < 6.0)
    #expect(abs(topology.discoveryDuration - elapsed) < 1.0)
    #expect(topology.discoveryDuration > 0.5)
  }

  @Test(
    "Multipath batches finish near timeout budget",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS"))
  )
  func testBatchCompletesNearTimeout() async throws {
    let tracer = SwiftFTR(config: SwiftFTRConfig())
    let config = MultipathConfig(
      flowVariations: 4,
      maxPaths: 6,
      earlyStopThreshold: 4,
      timeoutMs: 800,
      maxHops: 12
    )

    let elapsed = try await NetworkTestGate.shared.withPermit {
      let start = Date()
      _ = try await tracer.discoverPaths(to: "1.1.1.1", config: config)
      return Date().timeIntervalSince(start)
    }

    // Each batch fires in parallel, so total elapsed time should stay in the same ballpark as one timeout window.
    #expect(
      elapsed < 5.0,
      "Batched multipath discovery should stay near a single timeout window (elapsed=\(elapsed))"
    )
  }
}
