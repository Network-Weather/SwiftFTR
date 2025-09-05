import XCTest

@testable import SwiftFTR

final class SwiftFTRCacheTests: XCTestCase {
  private final class CountingResolver: ASNResolver, @unchecked Sendable {
    private var count = 0
    private let lock = NSLock()
    func resolve(ipv4Addrs: [String], timeout: TimeInterval) throws -> [String: ASNInfo] {
      lock.lock()
      defer { lock.unlock() }
      count += 1
      var out: [String: ASNInfo] = [:]
      for ip in ipv4Addrs { out[ip] = ASNInfo(asn: 65000, name: "X") }
      return out
    }
    func calls() -> Int {
      lock.lock()
      defer { lock.unlock() }
      return count
    }
  }

  func testCachingResolverHitsCache() throws {
    let base = CountingResolver()
    let caching = CachingASNResolver(base: base)
    // First call should consult base
    let _ = try caching.resolve(ipv4Addrs: ["203.0.113.1"], timeout: 0.1)
    XCTAssertEqual(base.calls(), 1)
    // Second call with same key should be served from cache
    let _ = try caching.resolve(ipv4Addrs: ["203.0.113.1"], timeout: 0.1)
    XCTAssertEqual(base.calls(), 1)
    // Mixed: one cached, one new => base called once more
    let _ = try caching.resolve(ipv4Addrs: ["203.0.113.1", "203.0.113.2"], timeout: 0.1)
    XCTAssertEqual(base.calls(), 2)
  }
}
