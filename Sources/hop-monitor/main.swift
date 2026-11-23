import Foundation
import SwiftFTR

@main
struct HopMonitor {
  static func main() async {
    // Flush stdout immediately for better output handling
    setbuf(stdout, nil)

    guard CommandLine.arguments.count >= 2 else {
      print("Usage: hop-monitor <destination>")
      Foundation.exit(1)
    }

    let destination = CommandLine.arguments[1]

    print("🔍 Discovering network path to \(destination)...")
    print()

    do {
      // Initial traceroute
      let config = SwiftFTRConfig(
        maxHops: 30,
        maxWaitMs: 1000,
        publicIP: "0.0.0.0"  // Skip STUN for faster startup
      )
      let tracer = SwiftFTR(config: config)

      let trace = try await tracer.trace(to: destination)

      // Extract hops
      let hops = trace.hops.compactMap { hop -> (Int, String)? in
        guard let ip = hop.ipAddress else { return nil }
        return (hop.ttl, ip)
      }

      print("📍 Found \(hops.count) hops:")
      for (ttl, ip) in hops {
        print("  \(ttl): \(ip)")
      }
      print()

      print("🚀 Monitoring hops (Ctrl+C to stop)...")
      print()

      // Create stats actor
      let stats = HopStats()

      // Start monitoring tasks
      await withTaskGroup(of: Void.self) { group in
        // Monitor each hop
        for (ttl, ip) in hops {
          group.addTask {
            await monitorHop(tracer: tracer, ttl: ttl, ip: ip, stats: stats)
          }
        }

        // Display task
        group.addTask {
          await displayStats(destination: destination, hops: hops, stats: stats)
        }
      }
    } catch {
      print("Error: \(error)")
      Foundation.exit(1)
    }
  }
}

func monitorHop(tracer: SwiftFTR, ttl: Int, ip: String, stats: HopStats) async {
  let config = PingConfig(count: 1, interval: 0.0, timeout: 2.0)

  while true {
    do {
      let result = try await tracer.ping(to: ip, config: config)
      if let rtt = result.statistics.avgRTT {
        await stats.record(ttl: ttl, rtt: rtt)
      } else {
        await stats.recordLoss(ttl: ttl)
      }
    } catch {
      await stats.recordLoss(ttl: ttl)
    }

    try? await Task.sleep(for: .seconds(1))
  }
}

func displayStats(destination: String, hops: [(Int, String)], stats: HopStats) async {
  try? await Task.sleep(for: .seconds(2))

  while true {
    print("\u{001B}[2J\u{001B}[H")  // Clear screen

    print("🌐 Monitoring: \(destination)")
    print(String(repeating: "=", count: 90))
    print()

    // Use Swift string padding - header
    let header =
      "\(pad("Hop", 4))  \(pad("IP", 18))  \(pad("Last", 8))  "
      + "\(pad("p50", 8))  \(pad("p90", 8))  \(pad("Loss", 8))  "
      + "\(pad("Jitter", 8))  \(pad("Probes", 7))"
    print(header)
    print(String(repeating: "-", count: 90))

    for (ttl, ip) in hops {
      let (last, p50, p90, loss, jitter, probes) = await stats.get(ttl: ttl)
      let lastStr = last.map { String(format: "%.1fms", $0 * 1000) } ?? "-"
      let p50Str = p50.map { String(format: "%.1fms", $0 * 1000) } ?? "-"
      let p90Str = p90.map { String(format: "%.1fms", $0 * 1000) } ?? "-"
      let lossStr = String(format: "%.0f%%", loss * 100)
      let jitterStr = jitter.map { String(format: "%.1fms", $0 * 1000) } ?? "-"
      let probesStr = "\(probes)"

      let row =
        "\(pad("\(ttl)", 4))  \(pad(ip, 18))  \(pad(lastStr, 8))  "
        + "\(pad(p50Str, 8))  \(pad(p90Str, 8))  \(pad(lossStr, 8))  "
        + "\(pad(jitterStr, 8))  \(pad(probesStr, 7))"
      print(row)
    }

    print()
    print("Updated: \(Date().formatted(date: .omitted, time: .standard))")

    try? await Task.sleep(for: .seconds(1))
  }
}

func pad(_ str: String, _ width: Int) -> String {
  str.padding(toLength: width, withPad: " ", startingAt: 0)
}

actor HopStats {
  private var data: [Int: (rtts: [TimeInterval], losses: Int, total: Int)] = [:]

  func record(ttl: Int, rtt: TimeInterval) {
    var entry = data[ttl] ?? ([], 0, 0)
    entry.rtts.append(rtt)
    if entry.rtts.count > 100 { entry.rtts.removeFirst() }
    entry.total += 1
    data[ttl] = entry
  }

  func recordLoss(ttl: Int) {
    var entry = data[ttl] ?? ([], 0, 0)
    entry.losses += 1
    entry.total += 1
    data[ttl] = entry
  }

  func get(ttl: Int) -> (TimeInterval?, TimeInterval?, TimeInterval?, Double, TimeInterval?, Int) {
    guard let entry = data[ttl] else { return (nil, nil, nil, 0.0, nil, 0) }

    let last = entry.rtts.last
    let loss = entry.total > 0 ? Double(entry.losses) / Double(entry.total) : 0.0
    let probes = entry.total

    guard !entry.rtts.isEmpty else {
      return (last, nil, nil, loss, nil, probes)
    }

    // Calculate percentiles
    let sorted = entry.rtts.sorted()
    let p50 = sorted[sorted.count / 2]
    let p90 = sorted[min(Int(Double(sorted.count) * 0.9), sorted.count - 1)]

    // Calculate jitter (average of absolute differences between consecutive RTTs)
    var jitter: TimeInterval? = nil
    if entry.rtts.count >= 2 {
      let diffs = zip(entry.rtts.dropFirst(), entry.rtts).map { abs($0.0 - $0.1) }
      jitter = diffs.reduce(0, +) / Double(diffs.count)
    }

    return (last, p50, p90, loss, jitter, probes)
  }
}
