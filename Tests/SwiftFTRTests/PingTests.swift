import Foundation
import Testing

@testable import SwiftFTR

@Suite("Ping Statistics Tests")
struct PingStatisticsTests {

  @Test("Statistics with all successful responses")
  func testAllSuccess() {
    let responses = [
      PingResponse(sequence: 1, rtt: 0.010, ttl: 64, timestamp: Date()),
      PingResponse(sequence: 2, rtt: 0.012, ttl: 64, timestamp: Date()),
      PingResponse(sequence: 3, rtt: 0.011, ttl: 64, timestamp: Date()),
      PingResponse(sequence: 4, rtt: 0.013, ttl: 64, timestamp: Date()),
      PingResponse(sequence: 5, rtt: 0.009, ttl: 64, timestamp: Date()),
    ]

    let stats = computeStats(responses: responses, sent: 5)

    #expect(stats.sent == 5)
    #expect(stats.received == 5)
    #expect(stats.packetLoss == 0.0)
    #expect(stats.minRTT == 0.009)
    #expect(stats.maxRTT == 0.013)
    #expect(stats.avgRTT != nil)
    #expect(stats.avgRTT! > 0.010 && stats.avgRTT! < 0.012)
    #expect(stats.jitter != nil)
  }

  @Test("Statistics with partial packet loss")
  func testPartialLoss() {
    let responses = [
      PingResponse(sequence: 1, rtt: 0.010, ttl: 64, timestamp: Date()),
      PingResponse(sequence: 2, rtt: nil, ttl: nil, timestamp: Date()),
      PingResponse(sequence: 3, rtt: 0.011, ttl: 64, timestamp: Date()),
      PingResponse(sequence: 4, rtt: nil, ttl: nil, timestamp: Date()),
      PingResponse(sequence: 5, rtt: 0.012, ttl: 64, timestamp: Date()),
    ]

    let stats = computeStats(responses: responses, sent: 5)

    #expect(stats.sent == 5)
    #expect(stats.received == 3)
    #expect(stats.packetLoss == 0.4)  // 2 out of 5 lost
    #expect(stats.minRTT == 0.010)
    #expect(stats.maxRTT == 0.012)
    #expect(stats.avgRTT != nil)
  }

  @Test("Statistics with complete packet loss")
  func testCompleteLoss() {
    let responses = [
      PingResponse(sequence: 1, rtt: nil, ttl: nil, timestamp: Date()),
      PingResponse(sequence: 2, rtt: nil, ttl: nil, timestamp: Date()),
      PingResponse(sequence: 3, rtt: nil, ttl: nil, timestamp: Date()),
    ]

    let stats = computeStats(responses: responses, sent: 3)

    #expect(stats.sent == 3)
    #expect(stats.received == 0)
    #expect(stats.packetLoss == 1.0)
    #expect(stats.minRTT == nil)
    #expect(stats.maxRTT == nil)
    #expect(stats.avgRTT == nil)
    #expect(stats.jitter == nil)
  }

  @Test("Jitter calculation with known values")
  func testJitterCalculation() {
    // RTTs: 10ms, 20ms, 30ms
    // Mean = 20ms
    // Variance = ((10-20)^2 + (20-20)^2 + (30-20)^2) / 3 = (100 + 0 + 100) / 3 = 66.67
    // Stddev = sqrt(66.67) ≈ 8.165 ms
    let responses = [
      PingResponse(sequence: 1, rtt: 0.010, ttl: 64, timestamp: Date()),
      PingResponse(sequence: 2, rtt: 0.020, ttl: 64, timestamp: Date()),
      PingResponse(sequence: 3, rtt: 0.030, ttl: 64, timestamp: Date()),
    ]

    let stats = computeStats(responses: responses, sent: 3)

    #expect(stats.avgRTT != nil)
    #expect(abs(stats.avgRTT! - 0.020) < 0.0001)
    #expect(stats.jitter != nil)
    // Expected jitter ≈ 0.008165 seconds
    #expect(abs(stats.jitter! - 0.008165) < 0.0001)
  }

  @Test("No jitter with single response")
  func testNoJitterSingleResponse() {
    let responses = [
      PingResponse(sequence: 1, rtt: 0.010, ttl: 64, timestamp: Date())
    ]

    let stats = computeStats(responses: responses, sent: 1)

    #expect(stats.received == 1)
    #expect(stats.jitter == nil)  // Need at least 2 samples for jitter
  }

  @Test("Timeout detection")
  func testTimeoutDetection() {
    let response1 = PingResponse(sequence: 1, rtt: 0.010, ttl: 64, timestamp: Date())
    let response2 = PingResponse(sequence: 2, rtt: nil, ttl: nil, timestamp: Date())

    #expect(response1.didTimeout == false)
    #expect(response2.didTimeout == true)
  }

  // Helper to compute statistics (mirrors implementation)
  private func computeStats(responses: [PingResponse], sent: Int) -> PingStatistics {
    let rtts = responses.compactMap { $0.rtt }
    let received = rtts.count
    let packetLoss = 1.0 - (Double(received) / Double(sent))

    guard !rtts.isEmpty else {
      return PingStatistics(
        sent: sent,
        received: 0,
        packetLoss: 1.0,
        minRTT: nil,
        avgRTT: nil,
        maxRTT: nil,
        jitter: nil
      )
    }

    let minRTT = rtts.min()!
    let maxRTT = rtts.max()!
    let avgRTT = rtts.reduce(0, +) / Double(rtts.count)

    let jitter: TimeInterval? = {
      guard rtts.count >= 2 else { return nil }
      let variance = rtts.map { pow($0 - avgRTT, 2) }.reduce(0, +) / Double(rtts.count)
      return sqrt(variance)
    }()

    return PingStatistics(
      sent: sent,
      received: received,
      packetLoss: packetLoss,
      minRTT: minRTT,
      avgRTT: avgRTT,
      maxRTT: maxRTT,
      jitter: jitter
    )
  }
}

@Suite("Ping Configuration Tests")
struct PingConfigTests {

  @Test("Default configuration values")
  func testDefaultConfig() {
    let config = PingConfig()

    #expect(config.count == 5)
    #expect(config.interval == 1.0)
    #expect(config.timeout == 2.0)
    #expect(config.payloadSize == 56)
  }

  @Test("Custom configuration values")
  func testCustomConfig() {
    let config = PingConfig(
      count: 10,
      interval: 0.5,
      timeout: 3.0,
      payloadSize: 128
    )

    #expect(config.count == 10)
    #expect(config.interval == 0.5)
    #expect(config.timeout == 3.0)
    #expect(config.payloadSize == 128)
  }
}

@Suite("Ping Response Tests")
struct PingResponseTests {

  @Test("Response with successful RTT")
  func testSuccessfulResponse() {
    let response = PingResponse(
      sequence: 1,
      rtt: 0.015,
      ttl: 64,
      timestamp: Date()
    )

    #expect(response.sequence == 1)
    #expect(response.rtt == 0.015)
    #expect(response.ttl == 64)
    #expect(response.didTimeout == false)
  }

  @Test("Response with timeout")
  func testTimeoutResponse() {
    let response = PingResponse(
      sequence: 2,
      rtt: nil,
      ttl: nil,
      timestamp: Date()
    )

    #expect(response.sequence == 2)
    #expect(response.rtt == nil)
    #expect(response.ttl == nil)
    #expect(response.didTimeout == true)
  }
}

@Suite("Ping Result Tests")
struct PingResultTests {

  @Test("Result structure")
  func testResultStructure() {
    let responses = [
      PingResponse(sequence: 1, rtt: 0.010, ttl: 64, timestamp: Date()),
      PingResponse(sequence: 2, rtt: 0.012, ttl: 64, timestamp: Date()),
    ]

    let stats = PingStatistics(
      sent: 2,
      received: 2,
      packetLoss: 0.0,
      minRTT: 0.010,
      avgRTT: 0.011,
      maxRTT: 0.012,
      jitter: 0.001
    )

    let result = PingResult(
      target: "example.com",
      resolvedIP: "93.184.216.34",
      responses: responses,
      statistics: stats
    )

    #expect(result.target == "example.com")
    #expect(result.resolvedIP == "93.184.216.34")
    #expect(result.responses.count == 2)
    #expect(result.statistics.sent == 2)
    #expect(result.statistics.received == 2)
  }
}

@Suite("Ping Integration Tests")
struct PingIntegrationTests {

  @Test(
    "Ping to reachable host",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS"))
  )
  func testPingReachableHost() async throws {
    let tracer = SwiftFTR(config: SwiftFTRConfig())
    let config = PingConfig(count: 3, interval: 0.5, timeout: 2.0)

    let result = try await NetworkTestGate.shared.withPermit {
      try await tracer.ping(to: "1.1.1.1", config: config)
    }

    #expect(result.resolvedIP == "1.1.1.1")
    #expect(result.responses.count == 3)
    #expect(result.statistics.sent == 3)

    // Should have at least some successful responses
    #expect(result.statistics.received > 0, "Expected responses from 1.1.1.1 but got 0")

    // RTT should be reasonable
    // In clean network: < 100ms to 1.1.1.1
    // In saturated test environment: may be much higher due to concurrent network tests
    if let avgRTT = result.statistics.avgRTT {
      #expect(avgRTT > 0.0)
      #expect(avgRTT < 10.0, "RTT should be < 10s (saturated network or connectivity issue)")
    }
  }

  @Test(
    "Ping with hostname resolution",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")))
  func testPingWithHostname() async throws {
    let tracer = SwiftFTR(config: SwiftFTRConfig())
    let config = PingConfig(count: 2, interval: 0.5, timeout: 2.0)

    let result = try await NetworkTestGate.shared.withPermit {
      try await tracer.ping(to: "cloudflare.com", config: config)
    }

    #expect(result.target == "cloudflare.com")
    #expect(result.resolvedIP != "")
    #expect(result.resolvedIP != "cloudflare.com")
    #expect(result.responses.count == 2)
  }

  @Test(
    "Ping with fast interval",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")))
  func testPingFastInterval() async throws {
    let tracer = SwiftFTR(config: SwiftFTRConfig())
    let config = PingConfig(count: 5, interval: 0.2, timeout: 2.0)

    let (result, duration) = try await NetworkTestGate.shared.withPermit {
      let start = Date()
      let r = try await tracer.ping(to: "8.8.8.8", config: config)
      return (r, Date().timeIntervalSince(start))
    }

    #expect(result.responses.count == 5)

    // Should complete in approximately four intervals (0.8s) plus RTT (~20ms).
    // Allow 3s for system scheduling variance.
    #expect(duration < 3.0)
  }

  @Test(
    "Concurrent pings to different targets",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")))
  func testConcurrentPings() async throws {
    let tracer = SwiftFTR(config: SwiftFTRConfig())
    let config = PingConfig(count: 3, interval: 0.3, timeout: 2.0)

    // Ping multiple targets concurrently
    async let result1 = NetworkTestGate.shared.withPermit {
      try await tracer.ping(to: "1.1.1.1", config: config)
    }
    async let result2 = NetworkTestGate.shared.withPermit {
      try await tracer.ping(to: "8.8.8.8", config: config)
    }
    async let result3 = NetworkTestGate.shared.withPermit {
      try await tracer.ping(to: "9.9.9.9", config: config)
    }

    let (r1, r2, r3) = try await (result1, result2, result3)

    #expect(r1.resolvedIP == "1.1.1.1")
    #expect(r2.resolvedIP == "8.8.8.8")
    #expect(r3.resolvedIP == "9.9.9.9")

    #expect(r1.statistics.received > 0)
    #expect(r2.statistics.received > 0)
    #expect(r3.statistics.received > 0)
  }

  @Test(
    "Ping respects per-operation interface binding (v0.7.0)",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")))
  func testPingWithInterface() async throws {
    // Try to get a valid interface
    let interfaces = ["en0", "en1", "en2"]
    var validInterface: String?

    for iface in interfaces {
      let ifIndex = if_nametoindex(iface)
      if ifIndex != 0 {
        validInterface = iface
        break
      }
    }

    guard let interface = validInterface else {
      // Skip test if no valid interface found
      return
    }

    // Test per-operation binding (v0.7.0 feature)
    // Create tracer WITHOUT global interface
    let tracer = SwiftFTR()

    // Bind at operation level
    let pingConfig = PingConfig(
      count: 2,
      interval: 0.5,
      timeout: 2.0,
      interface: interface  // Operation-level interface override
    )

    // Should not throw with valid interface
    let result = try await tracer.ping(to: "1.1.1.1", config: pingConfig)
    #expect(result.responses.count == 2)
  }

  @Test("Ping with invalid hostname fails")
  func testPingInvalidHostname() async throws {
    let tracer = SwiftFTR(config: SwiftFTRConfig())
    let config = PingConfig(count: 2, interval: 0.5, timeout: 1.0)

    await #expect(throws: TracerouteError.self) {
      try await tracer.ping(to: "invalid.host.that.does.not.exist.example", config: config)
    }
  }

  /// Regression test for the deadline-anchoring fix: under realistic Task.sleep
  /// drift (interval=10ms, count=500), the previous implementation reported
  /// false losses on the trailing ~5% of sequences because the precomputed
  /// "total timeout" expired before the last pings could complete. This test
  /// cross-checks against system /sbin/ping so it only fails when SwiftFTR
  /// reports materially more loss than the kernel does.
  @Test(
    "No trailing-block timeouts under sleep drift (regression for false loss)",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS")))
  func testNoTrailingFalseLoss() async throws {
    let tracer = SwiftFTR(config: SwiftFTRConfig())
    let count = 500
    let interval = 0.01
    let timeout = 0.3
    let target = "1.1.1.1"

    let result = try await NetworkTestGate.shared.withPermit {
      try await tracer.ping(
        to: target,
        config: PingConfig(count: count, interval: interval, timeout: timeout))
    }

    #expect(result.responses.count == count)

    // Compute trailing-block loss: timeouts in the last 10% of sequences.
    let cutoff = Int(Double(count) * 0.9)
    let trailingTimeouts = result.responses.suffix(count - cutoff).filter { $0.rtt == nil }.count
    let trailingLossPct = Double(trailingTimeouts) / Double(count - cutoff)

    // If SwiftFTR sees high trailing loss, cross-check against system ping.
    // We tolerate genuine network loss but flag the specific tail-end pattern
    // that the bug used to produce. Cross-check must be available (fail-closed):
    // if /sbin/ping can't run or its output can't be parsed, we fail the test
    // rather than silently passing on missing evidence.
    if trailingLossPct > 0.05 {
      guard let sysLossPct = systemPingLoss(target: target, count: count, intervalSec: interval)
      else {
        Issue.record(
          """
          SwiftFTR reported \(trailingLossPct * 100)% trailing-block loss but the \
          /sbin/ping cross-check was unavailable, so we cannot tell real loss from a \
          regression of the deadline-anchoring fix. Failing closed.
          """)
        return
      }
      #expect(
        trailingLossPct - sysLossPct < 0.05,
        """
        Trailing-block loss \(trailingLossPct * 100)% materially exceeds system \
        ping loss \(sysLossPct * 100)% — likely a regression of the \
        deadline-anchoring fix. Total SwiftFTR loss: \
        \(result.statistics.packetLoss * 100)%.
        """)
    }
  }

  /// Run system `/sbin/ping` with matching parameters and parse the loss percentage.
  /// Returns nil when /sbin/ping cannot be executed or its summary cannot be parsed —
  /// callers must treat that as a test failure rather than a 0% / 100% sentinel.
  private func systemPingLoss(target: String, count: Int, intervalSec: Double) -> Double? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/sbin/ping")
    p.arguments = [
      "-q", "-n",
      "-c", String(count),
      "-i", String(intervalSec),
      target,
    ]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do {
      try p.run()
      p.waitUntilExit()
    } catch {
      return nil
    }
    guard p.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return nil }
    // Look for "X.X% packet loss" in the stats summary.
    for line in output.split(separator: "\n") where line.contains("packet loss") {
      let parts = line.split(separator: ",")
      for part in parts where part.contains("packet loss") {
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        if let pctRange = trimmed.range(of: "%") {
          let numStr = trimmed[..<pctRange.lowerBound]
          if let v = Double(numStr) { return v / 100.0 }
        }
      }
    }
    return nil
  }
}

@Suite("Response Collector Tests")
struct ResponseCollectorTests {

  @Test("Response collector records send times")
  func testRecordSend() async {
    let collector = ResponseCollector()

    collector.recordSend(seq: 1, sendTime: 1.0)
    collector.recordSend(seq: 2, sendTime: 2.0)

    let (sentTimes, _, _) = collector.getResults()

    #expect(sentTimes[1] == 1.0)
    #expect(sentTimes[2] == 2.0)
  }

  @Test("Response collector records receive times")
  func testRecordResponse() async {
    let collector = ResponseCollector()

    collector.recordResponse(seq: 1, receiveTime: 1.5, ttl: 64)
    collector.recordResponse(seq: 2, receiveTime: 2.5, ttl: 64)

    let (_, receiveTimes, ttls) = collector.getResults()

    #expect(receiveTimes[1] == 1.5)
    #expect(receiveTimes[2] == 2.5)
    #expect(ttls[1] == 64)
    #expect(ttls[2] == 64)
  }

  @Test("Response collector counts responses")
  func testResponseCount() async {
    let collector = ResponseCollector()

    let count1 = collector.getResponseCount()
    #expect(count1 == 0)

    collector.recordResponse(seq: 1, receiveTime: 1.0, ttl: 64)
    let count2 = collector.getResponseCount()
    #expect(count2 == 1)

    collector.recordResponse(seq: 2, receiveTime: 2.0, ttl: 64)
    let count3 = collector.getResponseCount()
    #expect(count3 == 2)
  }
}

@Suite("Ping Codable Tests")
struct PingCodableTests {

  @Test("PingResult JSON encoding")
  func testPingResultEncoding() throws {
    let responses = [
      PingResponse(sequence: 1, rtt: 0.010, ttl: 64, timestamp: Date()),
      PingResponse(sequence: 2, rtt: nil, ttl: nil, timestamp: Date()),
    ]

    let stats = PingStatistics(
      sent: 2,
      received: 1,
      packetLoss: 0.5,
      minRTT: 0.010,
      avgRTT: 0.010,
      maxRTT: 0.010,
      jitter: nil
    )

    let result = PingResult(
      target: "example.com",
      resolvedIP: "93.184.216.34",
      responses: responses,
      statistics: stats
    )

    let encoder = JSONEncoder()
    let data = try encoder.encode(result)
    #expect(data.count > 0)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(PingResult.self, from: data)

    #expect(decoded.target == result.target)
    #expect(decoded.resolvedIP == result.resolvedIP)
    #expect(decoded.responses.count == result.responses.count)
    #expect(decoded.statistics.sent == result.statistics.sent)
  }

  @Test("PingStatistics JSON encoding")
  func testPingStatisticsEncoding() throws {
    let stats = PingStatistics(
      sent: 5,
      received: 4,
      packetLoss: 0.2,
      minRTT: 0.008,
      avgRTT: 0.010,
      maxRTT: 0.012,
      jitter: 0.001
    )

    let encoder = JSONEncoder()
    let data = try encoder.encode(stats)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(PingStatistics.self, from: data)

    #expect(decoded.sent == stats.sent)
    #expect(decoded.received == stats.received)
    #expect(decoded.packetLoss == stats.packetLoss)
    #expect(decoded.minRTT == stats.minRTT)
  }
}
