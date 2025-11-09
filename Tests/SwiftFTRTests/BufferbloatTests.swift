import Foundation
import Testing

@testable import SwiftFTR

@Suite("Bufferbloat Tests")
struct BufferbloatTests {

  // MARK: - Configuration Tests

  @Test("Default configuration values")
  func testDefaultConfig() {
    let config = BufferbloatConfig()

    #expect(config.target == "1.1.1.1")
    #expect(config.baselineDuration == 5.0)
    #expect(config.loadDuration == 10.0)
    #expect(config.loadType == .bidirectional)
    #expect(config.parallelStreams == 4)
    #expect(config.pingInterval == 0.1)
    #expect(config.calculateRPM == true)
    #expect(config.uploadURL == nil)
    #expect(config.downloadURL == nil)
  }

  @Test("Custom configuration values")
  func testCustomConfig() {
    let config = BufferbloatConfig(
      target: "8.8.8.8",
      baselineDuration: 3.0,
      loadDuration: 8.0,
      loadType: .upload,
      parallelStreams: 2,
      pingInterval: 0.2,
      calculateRPM: false,
      uploadURL: "https://example.com/upload",
      downloadURL: "https://example.com/download"
    )

    #expect(config.target == "8.8.8.8")
    #expect(config.baselineDuration == 3.0)
    #expect(config.loadDuration == 8.0)
    #expect(config.loadType == .upload)
    #expect(config.parallelStreams == 2)
    #expect(config.pingInterval == 0.2)
    #expect(config.calculateRPM == false)
    #expect(config.uploadURL == "https://example.com/upload")
    #expect(config.downloadURL == "https://example.com/download")
  }

  // MARK: - Grade Tests

  @Test("Bufferbloat grade enum values")
  func testGradeValues() {
    #expect(BufferbloatGrade.a.rawValue == "A")
    #expect(BufferbloatGrade.b.rawValue == "B")
    #expect(BufferbloatGrade.c.rawValue == "C")
    #expect(BufferbloatGrade.d.rawValue == "D")
    #expect(BufferbloatGrade.f.rawValue == "F")
  }

  @Test("Bufferbloat grade comparison")
  func testGradeComparison() {
    #expect(BufferbloatGrade.a < BufferbloatGrade.b)
    #expect(BufferbloatGrade.b < BufferbloatGrade.c)
    #expect(BufferbloatGrade.c < BufferbloatGrade.d)
    #expect(BufferbloatGrade.d < BufferbloatGrade.f)
  }

  // MARK: - RPM Tests

  @Test("RPM grade enum values")
  func testRPMGradeValues() {
    #expect(RPMGrade.poor.rawValue == "Poor")
    #expect(RPMGrade.fair.rawValue == "Fair")
    #expect(RPMGrade.good.rawValue == "Good")
    #expect(RPMGrade.excellent.rawValue == "Excellent")
  }

  @Test("RPM score structure")
  func testRPMScore() {
    let rpm = RPMScore(workingRPM: 500, idleRPM: 800, grade: .fair)

    #expect(rpm.workingRPM == 500)
    #expect(rpm.idleRPM == 800)
    #expect(rpm.grade == .fair)
  }

  // MARK: - Video Call Impact Tests

  @Test("Video call severity enum values")
  func testVideoCallSeverity() {
    #expect(VideoCallSeverity.none.rawValue == "None")
    #expect(VideoCallSeverity.minor.rawValue == "Minor")
    #expect(VideoCallSeverity.moderate.rawValue == "Moderate")
    #expect(VideoCallSeverity.severe.rawValue == "Severe")
  }

  @Test("Video call impact structure")
  func testVideoCallImpact() {
    let impact = VideoCallImpact(
      impactsVideoCalls: true,
      severity: .moderate,
      description: "Moderate impact on video calls"
    )

    #expect(impact.impactsVideoCalls == true)
    #expect(impact.severity == .moderate)
    #expect(impact.description == "Moderate impact on video calls")
  }

  // MARK: - Result Structure Tests

  @Test("LatencyMeasurements structure")
  func testLatencyMeasurements() {
    let measurements = LatencyMeasurements(
      sampleCount: 50,
      minMs: 10.0,
      avgMs: 15.0,
      maxMs: 25.0,
      p50Ms: 14.0,
      p95Ms: 22.0,
      p99Ms: 24.0,
      jitterMs: 3.0
    )

    #expect(measurements.sampleCount == 50)
    #expect(measurements.minMs == 10.0)
    #expect(measurements.avgMs == 15.0)
    #expect(measurements.maxMs == 25.0)
    #expect(measurements.p50Ms == 14.0)
    #expect(measurements.p95Ms == 22.0)
    #expect(measurements.p99Ms == 24.0)
    #expect(measurements.jitterMs == 3.0)
  }

  @Test("LatencyIncrease structure")
  func testLatencyIncrease() {
    let increase = LatencyIncrease(
      absoluteMs: 60.0,
      percentageIncrease: 400.0,
      p99IncreaseMs: 120.0
    )

    #expect(increase.absoluteMs == 60.0)
    #expect(increase.percentageIncrease == 400.0)
    #expect(increase.p99IncreaseMs == 120.0)
  }

  @Test("LoadGenerationDetails structure")
  func testLoadDetails() {
    let details = LoadGenerationDetails(
      streamsPerDirection: 4,
      bytesUploaded: 500_000,
      bytesDownloaded: 1_000_000,
      avgThroughputMbps: 10.5
    )

    #expect(details.streamsPerDirection == 4)
    #expect(details.bytesUploaded == 500_000)
    #expect(details.bytesDownloaded == 1_000_000)
    #expect(details.avgThroughputMbps == 10.5)
  }

  @Test("BufferbloatPingResult structure")
  func testBufferbloatPingResult() {
    let timestamp = Date()
    let result = BufferbloatPingResult(
      timestamp: timestamp,
      phase: .baseline,
      rtt: 0.015,
      sequence: 1
    )

    #expect(result.timestamp == timestamp)
    #expect(result.phase == .baseline)
    #expect(result.rtt == 0.015)
    #expect(result.sequence == 1)
  }

  @Test("TestPhase enum values")
  func testTestPhaseValues() {
    #expect(TestPhase.baseline.rawValue == "Baseline")
    #expect(TestPhase.rampUp.rawValue == "Ramp Up")
    #expect(TestPhase.sustained.rawValue == "Sustained Load")
    #expect(TestPhase.rampDown.rawValue == "Ramp Down")
  }

  // MARK: - Load Type Tests

  @Test("LoadType enum values")
  func testLoadTypes() {
    #expect(LoadType.upload.rawValue == "Upload")
    #expect(LoadType.download.rawValue == "Download")
    #expect(LoadType.bidirectional.rawValue == "Bidirectional")
  }

  @Test("LoadType is Codable")
  func testLoadTypeCodable() throws {
    let types: [LoadType] = [.upload, .download, .bidirectional]

    for loadType in types {
      let encoder = JSONEncoder()
      let data = try encoder.encode(loadType)

      let decoder = JSONDecoder()
      let decoded = try decoder.decode(LoadType.self, from: data)

      #expect(decoded == loadType)
    }
  }

  // MARK: - Integration Tests

  @Test(
    "Bufferbloat quick test with minimal duration",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS"))
  )
  func testBufferbloatQuickTest() async throws {
    // Very short test to exercise code paths without taking too long
    let config = BufferbloatConfig(
      target: "1.1.1.1",
      baselineDuration: 0.5,  // 500ms baseline
      loadDuration: 1.0,  // 1s load
      loadType: .download,
      parallelStreams: 1,  // Single stream to reduce overhead
      pingInterval: 0.1,
      calculateRPM: true,
      uploadURL: nil,
      downloadURL: nil
    )

    let tracer = SwiftFTR()
    let result = try await tracer.testBufferbloat(config: config)

    // Verify result structure
    #expect(result.target == "1.1.1.1")
    #expect(result.loadType == .download)
    #expect(result.baseline.sampleCount > 0)
    #expect(result.loaded.sampleCount > 0)

    // Should have baseline measurements
    #expect(result.baseline.avgMs > 0)
    #expect(result.baseline.minMs > 0)

    // Should have loaded measurements
    #expect(result.loaded.avgMs > 0)
    #expect(result.loaded.minMs > 0)

    // Should have valid grade
    let validGrades: [BufferbloatGrade] = [.a, .b, .c, .d, .f]
    #expect(validGrades.contains(result.grade))

    // Latency increase can be negative due to network variance, especially with short durations
    // With only 0.5s baseline, variance can be extreme. Just verify it's finite.
    #expect(result.latencyIncrease.absoluteMs.isFinite)
    #expect(result.latencyIncrease.absoluteMs.magnitude < 100000)  // Sanity check: not absurdly large

    // Should have RPM if enabled
    #expect(result.rpm != nil)
    if let rpm = result.rpm {
      #expect(rpm.workingRPM > 0)
      #expect(rpm.idleRPM > 0)
    }

    // Should have video call impact
    let validSeverities: [VideoCallSeverity] = [.none, .minor, .moderate, .severe]
    #expect(validSeverities.contains(result.videoCallImpact.severity))

    // Should have ping results
    #expect(result.pingResults.count > 0)

    // Should have load details
    #expect(result.loadDetails.streamsPerDirection == 1)
  }

  @Test(
    "Bufferbloat zero duration baseline only",
    .enabled(if: !ProcessInfo.processInfo.environment.keys.contains("SKIP_NETWORK_TESTS"))
  )
  func testBufferbloatZeroDurationLoad() async throws {
    // Test with zero load duration - baseline only
    let config = BufferbloatConfig(
      target: "1.1.1.1",
      baselineDuration: 0.5,
      loadDuration: 0.0,  // No load phase
      loadType: .download,
      parallelStreams: 1,
      pingInterval: 0.1,
      calculateRPM: false,  // No RPM calculation
      uploadURL: nil,
      downloadURL: nil
    )

    let tracer = SwiftFTR()
    let result = try await tracer.testBufferbloat(config: config)

    #expect(result.baseline.sampleCount > 0)
    #expect(result.rpm == nil)  // RPM disabled
  }
}
