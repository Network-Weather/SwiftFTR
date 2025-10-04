import XCTest

@testable import SwiftFTR

final class SwiftFTRCacheTests: XCTestCase {
  private actor CountingResolver: ASNResolver {
    private var count = 0
    func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
      count += 1
      var out: [String: ASNInfo] = [:]
      for ip in ipv4Addrs { out[ip] = ASNInfo(asn: 65000, name: "X") }
      return out
    }
    func calls() -> Int {
      return count
    }
  }

  func testCachingResolverHitsCache() async throws {
    let base = CountingResolver()
    let caching = CachingASNResolver(base: base)
    // First call should consult base
    let _ = try await caching.resolve(ipv4Addrs: ["203.0.113.1"], timeout: 0.1)
    let count1 = await base.calls()
    XCTAssertEqual(count1, 1)
    // Second call with same key should be served from cache
    let _ = try await caching.resolve(ipv4Addrs: ["203.0.113.1"], timeout: 0.1)
    let count2 = await base.calls()
    XCTAssertEqual(count2, 1)
    // Mixed: one cached, one new => base called once more
    let _ = try await caching.resolve(ipv4Addrs: ["203.0.113.1", "203.0.113.2"], timeout: 0.1)
    let count3 = await base.calls()
    XCTAssertEqual(count3, 2)
  }
}
