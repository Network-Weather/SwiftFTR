// Embedded ASN database load cost across tracer instances.
//
// Measures what constructing N `SwiftFTR` instances with the embedded ASN database costs:
// per-instance `preloadASNDatabase()` wall time (sequential and concurrent) and resident memory
// growth for the process. A shared database store shows one load time and one database's worth
// of memory regardless of N; per-instance loading shows both scaling with N.
//
// Run:
//     swift run -c release asnloadprobe [instanceCount]

import Foundation
import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

@main
struct ASNLoadProbe {
  static func main() async {
    let count = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 8
    let config = SwiftFTRConfig(asnResolverStrategy: .embedded)

    print("Embedded ASN database load across \(count) SwiftFTR instances")
    print("Resident memory before: \(formatBytes(residentBytes()))\n")

    // Sequential: each instance preloads after the previous one finished.
    var sequential: [SwiftFTR] = []
    let sequentialStart = ContinuousClock.now
    for index in 1...count {
      let tracer = SwiftFTR(config: config)
      sequential.append(tracer)
      let start = ContinuousClock.now
      await tracer.preloadASNDatabase()
      print(
        "  sequential #\(index): \(millis(since: start)) ms, resident \(formatBytes(residentBytes()))"
      )
    }
    let sequentialTotal = millis(since: sequentialStart)
    let afterSequential = residentBytes()
    print("Sequential total: \(sequentialTotal) ms")
    print("Resident memory after sequential: \(formatBytes(afterSequential))\n")

    // Concurrent: all instances preload at once, the topology-discovery pattern.
    let concurrent = (1...count).map { _ in SwiftFTR(config: config) }
    let concurrentStart = ContinuousClock.now
    await withTaskGroup(of: Void.self) { group in
      for tracer in concurrent {
        group.addTask { await tracer.preloadASNDatabase() }
      }
    }
    print("Concurrent total (\(count) at once): \(millis(since: concurrentStart)) ms")
    print("Resident memory after concurrent: \(formatBytes(residentBytes()))")

    // Keep every instance alive through the measurements so nothing is released early.
    withExtendedLifetime((sequential, concurrent)) {}
  }

  static func millis(since start: ContinuousClock.Instant) -> String {
    let elapsed = start.duration(to: .now)
    let ms =
      Double(elapsed.components.seconds) * 1000
      + Double(elapsed.components.attoseconds) / 1e15
    return String(format: "%.1f", ms)
  }

  static func residentBytes() -> Int {
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
    String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
  }
}
