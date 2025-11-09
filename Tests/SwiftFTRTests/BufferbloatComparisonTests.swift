import Foundation
import Testing

@testable import SwiftFTR

/// Comparison tests for bufferbloat across multiple interfaces
@Suite("Bufferbloat Comparison Tests")
struct BufferbloatComparisonTests {

  var shouldSkipNetworkTests: Bool {
    ProcessInfo.processInfo.environment["SKIP_NETWORK_TESTS"] != nil
  }

  func interfaceAvailable(_ name: String) -> Bool {
    #if canImport(Darwin)
      return if_nametoindex(name) != 0
    #else
      return false
    #endif
  }

  /// Discover available network interfaces (excluding loopback and virtual)
  func discoverNetworkInterfaces() -> [String] {
    #if canImport(Darwin)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
      process.arguments = ["-l"]

      let pipe = Pipe()
      process.standardOutput = pipe

      try? process.run()
      process.waitUntilExit()

      guard let data = try? pipe.fileHandleForReading.readToEnd(),
        let output = String(data: data, encoding: .utf8)
      else {
        return []
      }

      let interfaces = output.trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: " ")
        .map(String.init)
        .filter { iface in
          // Exclude loopback, virtual, and bridge interfaces
          !iface.starts(with: "lo") && !iface.starts(with: "gif") && !iface.starts(with: "stf")
            && !iface.starts(with: "anpi") && !iface.starts(with: "bridge")
            && !iface.starts(with: "ap") && !iface.starts(with: "awdl")
            && !iface.starts(with: "llw") && !iface.starts(with: "utun")
            && interfaceAvailable(iface)
        }

      return interfaces
    #else
      return []
    #endif
  }

  /// Get two different network interfaces for testing
  func getTwoInterfaces() -> (String, String)? {
    let interfaces = discoverNetworkInterfaces()
    guard interfaces.count >= 2 else { return nil }
    return (interfaces[0], interfaces[1])
  }

  @Test("Compare bufferbloat between two interfaces")
  func compareBufferbloatAcrossInterfaces() async throws {
    guard !shouldSkipNetworkTests else {
      print("⏭️  Skipping network test")
      return
    }
    guard let (iface1, iface2) = getTwoInterfaces() else {
      print("⏭️  Skipping: Need at least 2 network interfaces")
      return
    }

    print("\n" + String(repeating: "=", count: 70))
    print("🔬 BUFFERBLOAT COMPARISON: \(iface1) vs \(iface2)")
    print(String(repeating: "=", count: 70))
    print("Target: 1.1.1.1 (Cloudflare DNS)")
    print("Baseline: 5s | Load: 10s | Ping Interval: 0.2s")
    print("")

    let ftr = SwiftFTR()

    // Test first interface
    print("📡 Testing \(iface1)...")
    let config1 = BufferbloatConfig(
      target: "1.1.1.1",
      baselineDuration: 5.0,
      loadDuration: 10.0,
      pingInterval: 0.2,
      interface: iface1
    )
    let result1: BufferbloatResult
    do {
      result1 = try await ftr.testBufferbloat(config: config1)
    } catch {
      // Skip test if interface doesn't have route to target
      if error.localizedDescription.contains("No route to host") {
        print("⏭️  Skipping: \(iface1) has no route to target")
        return
      }
      throw error
    }

    // Test second interface
    print("📡 Testing \(iface2)...")
    let config2 = BufferbloatConfig(
      target: "1.1.1.1",
      baselineDuration: 5.0,
      loadDuration: 10.0,
      pingInterval: 0.2,
      interface: iface2
    )
    let result2: BufferbloatResult
    do {
      result2 = try await ftr.testBufferbloat(config: config2)
    } catch {
      // Skip test if interface doesn't have route to target
      if error.localizedDescription.contains("No route to host") {
        print("⏭️  Skipping: \(iface2) has no route to target")
        return
      }
      throw error
    }

    // Print detailed comparison
    print("\n" + String(repeating: "=", count: 70))
    print("📊 DETAILED RESULTS")
    print(String(repeating: "=", count: 70))

    printResult(interface: "en0", result: result1)
    print("")
    printResult(interface: "en14", result: result2)

    print("\n" + String(repeating: "=", count: 70))
    print("🏆 COMPARISON SUMMARY")
    print(String(repeating: "=", count: 70))

    // Compare grades
    print("\n📊 Grade:")
    print("  \(iface1):  \(result1.grade.rawValue) \(gradeEmoji(result1.grade))")
    print("  \(iface2): \(result2.grade.rawValue) \(gradeEmoji(result2.grade))")

    // Compare latency increase
    let increase1 = result1.latencyIncrease.percentageIncrease
    let increase2 = result2.latencyIncrease.percentageIncrease
    print("\n⏱️  Latency Increase Under Load:")
    print("  \(iface1):  +\(String(format: "%.1f", increase1))%")
    print("  \(iface2): +\(String(format: "%.1f", increase2))%")

    // Compare RPM
    print("\n🚀 RPM (Responsiveness):")
    if let rpm1 = result1.rpm {
      print("  \(iface1):  \(rpm1.workingRPM) (\(rpm1.grade.rawValue))")
    } else {
      print("  \(iface1):  N/A")
    }
    if let rpm2 = result2.rpm {
      print("  \(iface2): \(rpm2.workingRPM) (\(rpm2.grade.rawValue))")
    } else {
      print("  \(iface2): N/A")
    }

    // Compare baseline latency
    print("\n📍 Baseline Latency (p50):")
    print("  \(iface1):  \(String(format: "%.1f", result1.baseline.p50Ms))ms")
    print("  \(iface2): \(String(format: "%.1f", result2.baseline.p50Ms))ms")

    // Compare loaded latency
    print("\n🔥 Loaded Latency (p50):")
    print("  \(iface1):  \(String(format: "%.1f", result1.loaded.p50Ms))ms")
    print("  \(iface2): \(String(format: "%.1f", result2.loaded.p50Ms))ms")

    // Compare jitter
    print("\n📊 Jitter (std dev):")
    print("  \(iface1):  \(String(format: "%.1f", result1.loaded.jitterMs))ms")
    print("  \(iface2): \(String(format: "%.1f", result2.loaded.jitterMs))ms")

    // Determine winner
    print("\n🥇 Winner:")
    if result1.grade < result2.grade {
      print(
        "  ✨ \(iface1) has better bufferbloat grade (\(result1.grade.rawValue) vs \(result2.grade.rawValue))"
      )
    } else if result2.grade < result1.grade {
      print(
        "  ✨ \(iface2) has better bufferbloat grade (\(result2.grade.rawValue) vs \(result1.grade.rawValue))"
      )
    } else if let rpm1 = result1.rpm, let rpm2 = result2.rpm {
      if rpm1.workingRPM > rpm2.workingRPM {
        print("  ✨ \(iface1) has better RPM (\(rpm1.workingRPM) vs \(rpm2.workingRPM))")
      } else if rpm2.workingRPM > rpm1.workingRPM {
        print("  ✨ \(iface2) has better RPM (\(rpm2.workingRPM) vs \(rpm1.workingRPM))")
      } else {
        print("  🤝 Both interfaces perform similarly!")
      }
    } else {
      print("  🤝 Both interfaces perform similarly!")
    }

    print("\n" + String(repeating: "=", count: 70))
    print("")

    // Basic test assertions
    #expect(result1.baseline.sampleCount > 0)
    #expect(result1.loaded.sampleCount > 0)
    #expect(result2.baseline.sampleCount > 0)
    #expect(result2.loaded.sampleCount > 0)
  }

  func printResult(interface: String, result: BufferbloatResult) {
    print("Interface: \(interface)")
    print("  Grade:     \(result.grade.rawValue) \(gradeEmoji(result.grade))")
    if let rpm = result.rpm {
      print("  RPM:       \(rpm.workingRPM) (\(rpm.grade.rawValue))")
    } else {
      print("  RPM:       N/A")
    }
    print(
      "  Baseline:  \(String(format: "%.1f", result.baseline.p50Ms))ms p50 (σ=\(String(format: "%.1f", result.baseline.jitterMs))ms)"
    )
    print(
      "  Loaded:    \(String(format: "%.1f", result.loaded.p50Ms))ms p50 (σ=\(String(format: "%.1f", result.loaded.jitterMs))ms)"
    )
    print("  Increase:  +\(String(format: "%.1f", result.latencyIncrease.percentageIncrease))%")
    print(
      "  Samples:   \(result.baseline.sampleCount) baseline, \(result.loaded.sampleCount) loaded")
  }

  func gradeEmoji(_ grade: BufferbloatGrade) -> String {
    switch grade {
    case .a: return "🌟 Excellent"
    case .b: return "✅ Good"
    case .c: return "⚠️  Fair"
    case .d: return "❌ Poor"
    case .f: return "💥 Very Poor"
    }
  }
}
