import Foundation
import SwiftFTR
import SwiftIP2ASN

#if canImport(Darwin)
  import Darwin
#endif

@main
struct ResourceBenchmark {
  static func main() async throws {
    print("═══════════════════════════════════════════════════════════")
    print("  SwiftFTR ASN Resolver Benchmark")
    print("═══════════════════════════════════════════════════════════\n")

    // Test IPs - mix of well-known services
    let testIPs = [
      "8.8.8.8", "8.8.4.4",  // Google DNS
      "1.1.1.1", "1.0.0.1",  // Cloudflare
      "9.9.9.9",  // Quad9
      "208.67.222.222",  // OpenDNS
      "4.2.2.1",  // Level3
      "199.85.126.10",  // Norton
      "185.228.168.9",  // CleanBrowsing
      "76.76.19.19",  // Alternate DNS
    ]

    // Measure baseline memory
    let baselineMemory = getMemoryUsage()
    print("Baseline memory: \(formatBytes(baselineMemory))\n")

    // Test each strategy
    await testDNSStrategy(testIPs: testIPs, baselineMemory: baselineMemory)
    await testEmbeddedStrategy(testIPs: testIPs, baselineMemory: baselineMemory)
    await testHybridStrategy(testIPs: testIPs, baselineMemory: baselineMemory)
    await testRemoteStrategy(testIPs: testIPs, baselineMemory: baselineMemory)

    print("\n═══════════════════════════════════════════════════════════")
    print("  Benchmark Complete")
    print("═══════════════════════════════════════════════════════════")
  }

  static func testDNSStrategy(testIPs: [String], baselineMemory: Int) async {
    print("───────────────────────────────────────────────────────────")
    print("Strategy: .dns (Team Cymru DNS WHOIS)")
    print("───────────────────────────────────────────────────────────")

    let resolver = CachingASNResolver(base: CymruDNSResolver())

    // Cold lookup
    let coldStart = CFAbsoluteTimeGetCurrent()
    let results = try? await resolver.resolve(ipv4Addrs: testIPs, timeout: 5.0)
    let coldTime = (CFAbsoluteTimeGetCurrent() - coldStart) * 1000

    let memAfterCold = getMemoryUsage()
    print("  Cold lookup (\(testIPs.count) IPs): \(String(format: "%.1f", coldTime))ms")
    print(
      "  Memory after cold: \(formatBytes(memAfterCold)) (+\(formatBytes(memAfterCold - baselineMemory)))"
    )
    print("  Results: \(results?.count ?? 0) resolved")

    // Warm lookup (cached)
    let warmStart = CFAbsoluteTimeGetCurrent()
    _ = try? await resolver.resolve(ipv4Addrs: testIPs, timeout: 5.0)
    let warmTime = (CFAbsoluteTimeGetCurrent() - warmStart) * 1000

    print("  Warm lookup (cached): \(String(format: "%.2f", warmTime))ms")

    // Verify results - show all
    if let r = results {
      print("  Resolved IPs:")
      for ip in testIPs {
        if let info = r[ip] {
          print("    \(ip) → AS\(info.asn) \(info.name)")
        } else {
          print("    \(ip) → NOT FOUND")
        }
      }
    }
    print()
  }

  static func testEmbeddedStrategy(testIPs: [String], baselineMemory: Int) async {
    print("───────────────────────────────────────────────────────────")
    print("Strategy: .embedded (Local database)")
    print("───────────────────────────────────────────────────────────")

    let resolver = LocalASNResolver(source: .embedded)

    // Preload timing
    let preloadStart = CFAbsoluteTimeGetCurrent()
    await resolver.preload()
    let preloadTime = (CFAbsoluteTimeGetCurrent() - preloadStart) * 1000

    let memAfterPreload = getMemoryUsage()
    print("  Preload time: \(String(format: "%.1f", preloadTime))ms")
    print(
      "  Memory after preload: \(formatBytes(memAfterPreload)) (+\(formatBytes(memAfterPreload - baselineMemory)))"
    )

    // Lookup (DB already loaded via preload)
    let coldStart = CFAbsoluteTimeGetCurrent()
    let results = try? await resolver.resolve(ipv4Addrs: testIPs, timeout: 1.0)
    let coldTime = (CFAbsoluteTimeGetCurrent() - coldStart) * 1000

    print("  Lookup (\(testIPs.count) IPs): \(String(format: "%.3f", coldTime))ms")
    print("  Results: \(results?.count ?? 0) resolved")

    // Bulk lookup performance
    let bulkIPs = (0..<1000).map { i in
      "\(8 + (i / 256)).\((i * 17) % 256).\((i * 31) % 256).\((i * 7) % 256)"
    }
    let bulkStart = CFAbsoluteTimeGetCurrent()
    _ = try? await resolver.resolve(ipv4Addrs: bulkIPs, timeout: 1.0)
    let bulkTime = (CFAbsoluteTimeGetCurrent() - bulkStart) * 1000

    print(
      "  Bulk lookup (1000 IPs): \(String(format: "%.2f", bulkTime))ms (\(String(format: "%.1f", bulkTime))μs/IP)"
    )

    // Verify results - show all
    if let r = results {
      print("  Resolved IPs:")
      for ip in testIPs {
        if let info = r[ip] {
          print("    \(ip) → AS\(info.asn) \(info.name)")
        } else {
          print("    \(ip) → NOT FOUND")
        }
      }
    }
    print()
  }

  static func testHybridStrategy(testIPs: [String], baselineMemory: Int) async {
    print("───────────────────────────────────────────────────────────")
    print("Strategy: .hybrid (Local + DNS fallback)")
    print("───────────────────────────────────────────────────────────")

    let resolver = HybridASNResolver(source: .embedded, fallbackTimeout: 1.0)

    // Preload timing
    let preloadStart = CFAbsoluteTimeGetCurrent()
    await resolver.preload()
    let preloadTime = (CFAbsoluteTimeGetCurrent() - preloadStart) * 1000

    let memAfterPreload = getMemoryUsage()
    print("  Preload time: \(String(format: "%.1f", preloadTime))ms")
    print(
      "  Memory after preload: \(formatBytes(memAfterPreload)) (+\(formatBytes(memAfterPreload - baselineMemory)))"
    )

    // Lookup
    let coldStart = CFAbsoluteTimeGetCurrent()
    let results = try? await resolver.resolve(ipv4Addrs: testIPs, timeout: 1.0)
    let coldTime = (CFAbsoluteTimeGetCurrent() - coldStart) * 1000

    print("  Lookup (\(testIPs.count) IPs): \(String(format: "%.2f", coldTime))ms")
    print("  Results: \(results?.count ?? 0) resolved")

    // Verify results
    if let r = results {
      print("  Sample: 8.8.8.8 → AS\(r["8.8.8.8"]?.asn ?? 0) \(r["8.8.8.8"]?.name ?? "?")")
    }
    print()
  }

  static func testRemoteStrategy(testIPs: [String], baselineMemory: Int) async {
    print("───────────────────────────────────────────────────────────")
    print("Strategy: .remote (Download from network)")
    print("───────────────────────────────────────────────────────────")

    // Clear cache using IP2ASN's API
    try? await IP2ASN.clearCache()
    print("  (Cleared IP2ASN cache)")

    // Test without bundled path - will download fresh
    let resolver = LocalASNResolver(source: .remote(bundledPath: nil, url: nil))

    // First lookup triggers download
    let coldStart = CFAbsoluteTimeGetCurrent()
    let results = try? await resolver.resolve(ipv4Addrs: testIPs, timeout: 60.0)
    let coldTime = (CFAbsoluteTimeGetCurrent() - coldStart) * 1000

    let memAfterCold = getMemoryUsage()
    print("  First lookup (incl. download): \(String(format: "%.1f", coldTime))ms")
    print(
      "  Memory after load: \(formatBytes(memAfterCold)) (+\(formatBytes(memAfterCold - baselineMemory)))"
    )
    print("  Results: \(results?.count ?? 0) resolved")

    // Second lookup (cached in memory)
    let warmStart = CFAbsoluteTimeGetCurrent()
    _ = try? await resolver.resolve(ipv4Addrs: testIPs, timeout: 1.0)
    let warmTime = (CFAbsoluteTimeGetCurrent() - warmStart) * 1000

    print("  Cached lookup: \(String(format: "%.3f", warmTime))ms")

    // Verify results
    if let r = results {
      print("  Sample: 8.8.8.8 → AS\(r["8.8.8.8"]?.asn ?? 0) \(r["8.8.8.8"]?.name ?? "?")")
    }
    print()
  }

  static func getMemoryUsage() -> Int {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? Int(info.resident_size) : 0
  }

  static func formatBytes(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
    return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
  }
}
