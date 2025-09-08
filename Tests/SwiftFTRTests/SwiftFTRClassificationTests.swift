import XCTest

@testable import SwiftFTR

private struct MockASNResolver: ASNResolver {
  let mapping: [String: ASNInfo]
  func resolve(ipv4Addrs: [String], timeout: TimeInterval) throws -> [String: ASNInfo] {
    var out: [String: ASNInfo] = [:]
    for ip in ipv4Addrs {
      if let v = mapping[ip] { out[ip] = v }
    }
    return out
  }
}

final class SwiftFTRClassificationTests: XCTestCase {
  override func setUp() {
    // Ensure no STUN is attempted during tests
    setenv("PTR_SKIP_STUN", "1", 1)
  }

  func testClassificationRulesAndHoleFilling() throws {
    // Synthetic trace: private -> CGNAT -> transit -> timeout -> destination
    let hops: [TraceHop] = [
      .init(ttl: 1, ipAddress: "192.168.1.1", rtt: 0.001, reachedDestination: false),
      .init(ttl: 2, ipAddress: "100.64.0.5", rtt: 0.002, reachedDestination: false),
      .init(ttl: 3, ipAddress: "203.0.113.10", rtt: 0.003, reachedDestination: false),
      .init(ttl: 4, ipAddress: nil, rtt: nil, reachedDestination: false),
      .init(ttl: 5, ipAddress: "93.184.216.34", rtt: 0.010, reachedDestination: true),
    ]
    let tr = TraceResult(destination: "example.com", maxHops: 5, reached: true, hops: hops)
    let destIP = "93.184.216.34"

    // Mock ASN mapping: client(198.51.100.50)->AS64501, transit->AS64500, dest->AS15133
    let mapping: [String: ASNInfo] = [
      "203.0.113.10": ASNInfo(asn: 64500, name: "TransitNet", prefix: "203.0.113.0/24"),
      destIP: ASNInfo(asn: 15133, name: "ExampleNet", prefix: "93.184.216.0/24"),
      "198.51.100.50": ASNInfo(asn: 64501, name: "ISPNet", prefix: "198.51.100.0/24"),
    ]
    let resolver = MockASNResolver(mapping: mapping)
    // Provide public IP directly to classifier
    let classified = try TraceClassifier().classify(
      trace: tr, destinationIP: destIP, resolver: resolver, timeout: 0.1, publicIP: "198.51.100.50")

    XCTAssertEqual(classified.destinationIP, destIP)
    XCTAssertEqual(classified.clientASN, 64501)
    XCTAssertEqual(classified.destinationASN, 15133)
    XCTAssertEqual(classified.hops.count, 5)

    // Categories per hop
    XCTAssertEqual(classified.hops[0].category, .local)
    XCTAssertEqual(classified.hops[1].category, .isp)  // CGNAT
    XCTAssertEqual(classified.hops[2].category, .transit)
    // Hole-filling: between transit and destination, single timeout should remain unknown or be filled.
    // Our logic fills only when both sides share the same category; TRANSIT vs DESTINATION differ, so remain UNKNOWN.
    XCTAssertEqual(classified.hops[3].category, .unknown)
    XCTAssertEqual(classified.hops[4].category, .destination)
  }

  func testISPWhenClientASNMatchesHop() throws {
    let hops: [TraceHop] = [
      .init(ttl: 1, ipAddress: "198.51.100.1", rtt: 0.001, reachedDestination: false),
      .init(ttl: 2, ipAddress: "203.0.113.2", rtt: 0.003, reachedDestination: false),
    ]
    let tr = TraceResult(destination: "dst", maxHops: 2, reached: false, hops: hops)
    let mapping: [String: ASNInfo] = [
      "198.51.100.1": ASNInfo(asn: 64501, name: "ISPNet"),
      "203.0.113.2": ASNInfo(asn: 64500, name: "TransitNet"),
      "198.51.100.50": ASNInfo(asn: 64501, name: "ISPNet"),
    ]
    let resolver = MockASNResolver(mapping: mapping)
    let classified = try TraceClassifier().classify(
      trace: tr, destinationIP: "203.0.113.200", resolver: resolver, timeout: 0.1, publicIP: "198.51.100.50")
    XCTAssertEqual(classified.hops[0].category, .isp)
    XCTAssertEqual(classified.hops[1].category, .transit)
  }

  func testCGNATClassifiedAsISP() throws {
    let hops: [TraceHop] = [
      .init(ttl: 1, ipAddress: "100.64.12.34", rtt: 0.001, reachedDestination: false)
    ]
    let tr = TraceResult(destination: "dst", maxHops: 1, reached: false, hops: hops)
    let resolver = MockASNResolver(mapping: [:])
    let classified = try TraceClassifier().classify(
      trace: tr, destinationIP: "203.0.113.1", resolver: resolver, timeout: 0.1)
    XCTAssertEqual(classified.hops[0].category, .isp)
    XCTAssertNil(classified.hops[0].asn)
  }

  func testDestinationCategoryWhenASMatchesDestination() throws {
    let hops: [TraceHop] = [
      .init(ttl: 1, ipAddress: "203.0.113.10", rtt: 0.001, reachedDestination: false),
      .init(ttl: 2, ipAddress: "93.184.216.34", rtt: 0.010, reachedDestination: true),
    ]
    let tr = TraceResult(destination: "example.com", maxHops: 2, reached: true, hops: hops)
    let mapping: [String: ASNInfo] = [
      "93.184.216.34": ASNInfo(asn: 15133, name: "ExampleNet", prefix: "93.184.216.0/24"),
      "203.0.113.10": ASNInfo(asn: 15133, name: "ExampleNet"),
    ]
    let resolver = MockASNResolver(mapping: mapping)
    let classified = try TraceClassifier().classify(
      trace: tr, destinationIP: "93.184.216.34", resolver: resolver, timeout: 0.1)
    XCTAssertEqual(classified.hops[1].category, .destination)
    XCTAssertEqual(classified.hops[0].category, .destination)  // same ASN as destination
  }

  func testHoleFillingSameCategorySameASN() throws {
    // TRANSIT -> timeout -> TRANSIT, same ASN on both sides => fill category + ASN
    let hops: [TraceHop] = [
      .init(ttl: 1, ipAddress: "203.0.113.1", rtt: 0.001, reachedDestination: false),
      .init(ttl: 2, ipAddress: nil, rtt: nil, reachedDestination: false),
      .init(ttl: 3, ipAddress: "203.0.113.2", rtt: 0.003, reachedDestination: false),
    ]
    let tr = TraceResult(destination: "dst", maxHops: 3, reached: false, hops: hops)
    let mapping: [String: ASNInfo] = [
      "203.0.113.1": ASNInfo(asn: 64500, name: "TransitNet", prefix: "203.0.113.0/24"),
      "203.0.113.2": ASNInfo(asn: 64500, name: "TransitNet", prefix: "203.0.113.0/24"),
    ]
    let resolver = MockASNResolver(mapping: mapping)
    let classified = try TraceClassifier().classify(
      trace: tr, destinationIP: "198.51.100.10", resolver: resolver, timeout: 0.1)
    XCTAssertEqual(classified.hops[1].category, .transit)
    XCTAssertEqual(classified.hops[1].asn, 64500)
  }

  func testHoleFillingSameCategoryDifferentASN() throws {
    // TRANSIT -> timeout -> TRANSIT, different ASN on each side => fill category only
    let hops: [TraceHop] = [
      .init(ttl: 1, ipAddress: "198.51.100.1", rtt: 0.001, reachedDestination: false),
      .init(ttl: 2, ipAddress: nil, rtt: nil, reachedDestination: false),
      .init(ttl: 3, ipAddress: "198.51.100.2", rtt: 0.003, reachedDestination: false),
    ]
    let tr = TraceResult(destination: "dst", maxHops: 3, reached: false, hops: hops)
    let mapping: [String: ASNInfo] = [
      "198.51.100.1": ASNInfo(asn: 64500, name: "TransitA", prefix: "198.51.100.0/24"),
      "198.51.100.2": ASNInfo(asn: 64501, name: "TransitB", prefix: "198.51.100.0/24"),
    ]
    let resolver = MockASNResolver(mapping: mapping)
    let classified = try TraceClassifier().classify(
      trace: tr, destinationIP: "203.0.113.10", resolver: resolver, timeout: 0.1)
    XCTAssertEqual(classified.hops[1].category, .transit)
    XCTAssertNil(classified.hops[1].asn)
  }
}
