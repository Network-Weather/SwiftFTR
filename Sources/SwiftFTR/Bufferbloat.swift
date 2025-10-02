import Foundation

#if canImport(Darwin)
  import Darwin
#endif

// MARK: - Configuration

/// Configuration for bufferbloat/responsiveness test
public struct BufferbloatConfig: Sendable {
  /// Target to ping for latency measurement (default: 1.1.1.1)
  public let target: String

  /// Duration of baseline (idle) measurement in seconds
  public let baselineDuration: TimeInterval

  /// Duration of load generation in seconds
  public let loadDuration: TimeInterval

  /// Type of load to generate
  public let loadType: LoadType

  /// Number of parallel TCP streams per direction
  public let parallelStreams: Int

  /// Ping interval during test in seconds
  public let pingInterval: TimeInterval

  /// Calculate RPM (Round-trips Per Minute) metric
  public let calculateRPM: Bool

  /// Custom upload URL (default: httpbin.org/post)
  public let uploadURL: String?

  /// Custom download URL (default: Cloudflare speed test)
  public let downloadURL: String?

  public init(
    target: String = "1.1.1.1",
    baselineDuration: TimeInterval = 5.0,
    loadDuration: TimeInterval = 10.0,
    loadType: LoadType = .bidirectional,
    parallelStreams: Int = 4,
    pingInterval: TimeInterval = 0.1,
    calculateRPM: Bool = true,
    uploadURL: String? = nil,
    downloadURL: String? = nil
  ) {
    self.target = target
    self.baselineDuration = baselineDuration
    self.loadDuration = loadDuration
    self.loadType = loadType
    self.parallelStreams = parallelStreams
    self.pingInterval = pingInterval
    self.calculateRPM = calculateRPM
    self.uploadURL = uploadURL
    self.downloadURL = downloadURL
  }
}

/// Type of network load to generate
public enum LoadType: String, Sendable, Codable {
  case upload = "Upload"
  case download = "Download"
  case bidirectional = "Bidirectional"
}

// MARK: - Results

/// Result from bufferbloat test
public struct BufferbloatResult: Sendable, Codable {
  /// Target tested
  public let target: String

  /// Load type used
  public let loadType: LoadType

  /// Baseline (idle) measurements
  public let baseline: LatencyMeasurements

  /// Loaded measurements
  public let loaded: LatencyMeasurements

  /// Latency increase statistics
  public let latencyIncrease: LatencyIncrease

  /// RPM (Round-trips Per Minute) score
  public let rpm: RPMScore?

  /// Overall bufferbloat grade
  public let grade: BufferbloatGrade

  /// Impact on video calling
  public let videoCallImpact: VideoCallImpact

  /// Individual ping results during test
  public let pingResults: [BufferbloatPingResult]

  /// Load generation details
  public let loadDetails: LoadGenerationDetails

  public init(
    target: String,
    loadType: LoadType,
    baseline: LatencyMeasurements,
    loaded: LatencyMeasurements,
    latencyIncrease: LatencyIncrease,
    rpm: RPMScore?,
    grade: BufferbloatGrade,
    videoCallImpact: VideoCallImpact,
    pingResults: [BufferbloatPingResult],
    loadDetails: LoadGenerationDetails
  ) {
    self.target = target
    self.loadType = loadType
    self.baseline = baseline
    self.loaded = loaded
    self.latencyIncrease = latencyIncrease
    self.rpm = rpm
    self.grade = grade
    self.videoCallImpact = videoCallImpact
    self.pingResults = pingResults
    self.loadDetails = loadDetails
  }
}

/// Latency measurements from a test phase
public struct LatencyMeasurements: Sendable, Codable {
  public let sampleCount: Int
  public let minMs: Double
  public let avgMs: Double
  public let maxMs: Double
  public let p50Ms: Double
  public let p95Ms: Double
  public let p99Ms: Double
  public let jitterMs: Double  // Standard deviation

  public init(
    sampleCount: Int,
    minMs: Double,
    avgMs: Double,
    maxMs: Double,
    p50Ms: Double,
    p95Ms: Double,
    p99Ms: Double,
    jitterMs: Double
  ) {
    self.sampleCount = sampleCount
    self.minMs = minMs
    self.avgMs = avgMs
    self.maxMs = maxMs
    self.p50Ms = p50Ms
    self.p95Ms = p95Ms
    self.p99Ms = p99Ms
    self.jitterMs = jitterMs
  }
}

/// Latency increase from baseline to loaded
public struct LatencyIncrease: Sendable, Codable {
  /// Absolute increase in avg latency (ms)
  public let absoluteMs: Double

  /// Percentage increase
  public let percentageIncrease: Double

  /// Increase in p99 latency (ms)
  public let p99IncreaseMs: Double

  public init(absoluteMs: Double, percentageIncrease: Double, p99IncreaseMs: Double) {
    self.absoluteMs = absoluteMs
    self.percentageIncrease = percentageIncrease
    self.p99IncreaseMs = p99IncreaseMs
  }
}

/// RPM (Round-trips Per Minute) score per IETF draft-ietf-ippm-responsiveness
public struct RPMScore: Sendable, Codable {
  /// Working RPM (under load)
  public let workingRPM: Int

  /// Idle RPM (baseline)
  public let idleRPM: Int

  /// RPM grade per IETF spec
  public let grade: RPMGrade

  public init(workingRPM: Int, idleRPM: Int, grade: RPMGrade) {
    self.workingRPM = workingRPM
    self.idleRPM = idleRPM
    self.grade = grade
  }
}

/// RPM grading per IETF specification
public enum RPMGrade: String, Sendable, Codable {
  case poor = "Poor"  // <300 RPM (>200ms RTT)
  case fair = "Fair"  // 300-1000 RPM (60-200ms RTT)
  case good = "Good"  // 1000-6000 RPM (10-60ms RTT)
  case excellent = "Excellent"  // >6000 RPM (<10ms RTT)
}

/// Bufferbloat grade based on latency increase
public enum BufferbloatGrade: String, Sendable, Codable, Comparable {
  case a = "A"  // <25ms increase - excellent
  case b = "B"  // 25-75ms - good
  case c = "C"  // 75-150ms - acceptable
  case d = "D"  // 150-300ms - poor
  case f = "F"  // >300ms - critical bufferbloat

  public static func < (lhs: BufferbloatGrade, rhs: BufferbloatGrade) -> Bool {
    let order: [BufferbloatGrade] = [.a, .b, .c, .d, .f]
    guard let lhsIndex = order.firstIndex(of: lhs),
      let rhsIndex = order.firstIndex(of: rhs)
    else {
      return false
    }
    return lhsIndex < rhsIndex
  }
}

/// Impact on video calling applications (Zoom, Teams, etc.)
public struct VideoCallImpact: Sendable, Codable {
  /// Whether bufferbloat will impact video calls
  public let impactsVideoCalls: Bool

  /// Severity of impact
  public let severity: VideoCallSeverity

  /// Human-readable description
  public let description: String

  public init(impactsVideoCalls: Bool, severity: VideoCallSeverity, description: String) {
    self.impactsVideoCalls = impactsVideoCalls
    self.severity = severity
    self.description = description
  }
}

/// Severity of video call impact
public enum VideoCallSeverity: String, Sendable, Codable {
  case none = "None"  // No impact expected
  case minor = "Minor"  // May see occasional glitches
  case moderate = "Moderate"  // Noticeable quality issues
  case severe = "Severe"  // Calls will be problematic
}

/// Single ping result during bufferbloat test
public struct BufferbloatPingResult: Sendable, Codable {
  public let timestamp: Date
  public let phase: TestPhase
  public let rtt: TimeInterval?
  public let sequence: Int

  public init(timestamp: Date, phase: TestPhase, rtt: TimeInterval?, sequence: Int) {
    self.timestamp = timestamp
    self.phase = phase
    self.rtt = rtt
    self.sequence = sequence
  }
}

/// Test phase during bufferbloat test
public enum TestPhase: String, Sendable, Codable {
  case baseline = "Baseline"
  case rampUp = "Ramp Up"
  case sustained = "Sustained Load"
  case rampDown = "Ramp Down"
}

/// Details about load generation
public struct LoadGenerationDetails: Sendable, Codable {
  /// Number of streams per direction
  public let streamsPerDirection: Int

  /// Total bytes uploaded (if applicable)
  public let bytesUploaded: Int64?

  /// Total bytes downloaded (if applicable)
  public let bytesDownloaded: Int64?

  /// Average throughput during load (Mbps)
  public let avgThroughputMbps: Double?

  public init(
    streamsPerDirection: Int,
    bytesUploaded: Int64? = nil,
    bytesDownloaded: Int64? = nil,
    avgThroughputMbps: Double? = nil
  ) {
    self.streamsPerDirection = streamsPerDirection
    self.bytesUploaded = bytesUploaded
    self.bytesDownloaded = bytesDownloaded
    self.avgThroughputMbps = avgThroughputMbps
  }
}

// MARK: - Load Generator

/// Generates network load using multiple parallel HTTP streams
actor LoadGenerator {
  private let config: BufferbloatConfig
  private var activeTasks: [Task<Void, Never>] = []

  init(config: BufferbloatConfig) {
    self.config = config
  }

  /// Start generating load
  func startLoad(duration: TimeInterval, type: LoadType) async {
    let endTime = Date().addingTimeInterval(duration)

    switch type {
    case .upload:
      await generateUploadLoad(until: endTime)
    case .download:
      await generateDownloadLoad(until: endTime)
    case .bidirectional:
      // Run both simultaneously
      async let upload: Void = generateUploadLoad(until: endTime)
      async let download: Void = generateDownloadLoad(until: endTime)
      _ = await (upload, download)
    }
  }

  /// Stop all load generation
  func stopLoad() {
    for task in activeTasks {
      task.cancel()
    }
    activeTasks.removeAll()
  }

  /// Generate upload load (POST requests with random data)
  private func generateUploadLoad(until endTime: Date) async {
    let url = URL(string: config.uploadURL ?? "https://httpbin.org/post")!

    // Create chunk of random data (256 KB - smaller for faster requests)
    let chunkSize = 256 * 1024
    let randomData = Data((0..<chunkSize).map { _ in UInt8.random(in: 0...255) })

    // Spawn multiple parallel upload streams
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<config.parallelStreams {
        group.addTask {
          while Date() < endTime && !Task.isCancelled {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = randomData
            request.timeoutInterval = 3  // Short timeout

            // Just fire off the request, ignore errors
            _ = try? await URLSession.shared.data(for: request)
          }
        }
      }
    }
  }

  /// Generate download load (GET requests)
  private func generateDownloadLoad(until endTime: Date) async {
    // 1 MB download - smaller for quicker iteration
    let url = URL(
      string: config.downloadURL ?? "https://speed.cloudflare.com/__down?bytes=1000000")!

    // Spawn multiple parallel download streams
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<config.parallelStreams {
        group.addTask {
          while Date() < endTime && !Task.isCancelled {
            _ = try? await URLSession.shared.data(from: url)
          }
        }
      }
    }
  }
}

// MARK: - SwiftFTR Bufferbloat Extension

extension SwiftFTR {
  /// Internal implementation of bufferbloat test
  /// Runs on the SwiftFTR actor, can call self.ping() without actor re-entrancy issues
  internal func _testBufferbloat(config: BufferbloatConfig) async throws -> BufferbloatResult {

    var allPingResults: [BufferbloatPingResult] = []

    if config.baselineDuration > 0 {
      print("📊 Bufferbloat Test Started")
      print("Target: \(config.target)")
      print("Load Type: \(config.loadType.rawValue)")
      print("")
    }

    // Phase 1: Baseline measurement (idle network)
    if config.baselineDuration > 0 {
      print("Phase 1/2: Measuring baseline latency (idle network)...")
    }

    let baselineResults = try await measureBaseline(
      target: config.target,
      duration: config.baselineDuration,
      interval: config.pingInterval,
      swiftFTRConfig: self.config
    )
    allPingResults.append(contentsOf: baselineResults)

    let baselineStats = computeStatistics(baselineResults)

    if config.baselineDuration > 0 {
      print(
        "✓ Baseline: avg=\(String(format: "%.1f", baselineStats.avgMs))ms, "
          + "p95=\(String(format: "%.1f", baselineStats.p95Ms))ms")
      print("")
    }

    // Phase 2: Load generation + latency measurement
    if config.loadDuration > 0 {
      print(
        "Phase 2/2: Generating \(config.loadType.rawValue.lowercased()) load "
          + "(\(config.parallelStreams) streams per direction)...")
    }

    let loadedResults = try await measureUnderLoad(
      target: config.target,
      loadDuration: config.loadDuration,
      loadType: config.loadType,
      interval: config.pingInterval,
      config: config,
      swiftFTRConfig: self.config
    )
    allPingResults.append(contentsOf: loadedResults)

    // Only analyze sustained load phase
    let sustainedResults = loadedResults.filter { $0.phase == .sustained }
    let loadedStats = computeStatistics(sustainedResults)

    if config.loadDuration > 0 {
      print(
        "✓ Under Load: avg=\(String(format: "%.1f", loadedStats.avgMs))ms, "
          + "p95=\(String(format: "%.1f", loadedStats.p95Ms))ms")
      print("")
    }

    // Phase 3: Analysis
    if config.loadDuration > 0 {
      print("Analyzing results...")
    }

    let latencyIncrease = LatencyIncrease(
      absoluteMs: loadedStats.avgMs - baselineStats.avgMs,
      percentageIncrease: ((loadedStats.avgMs - baselineStats.avgMs)
        / max(baselineStats.avgMs, 0.001)) * 100,
      p99IncreaseMs: loadedStats.p99Ms - baselineStats.p99Ms
    )

    // Calculate RPM
    var rpm: RPMScore? = nil
    if config.calculateRPM {
      rpm = calculateRPM(baseline: baselineStats, loaded: loadedStats)
    }

    // Grade bufferbloat
    let grade = gradeBufferbloat(latencyIncrease: latencyIncrease)

    // Assess video call impact
    let videoImpact = assessVideoCallImpact(
      grade: grade,
      latencyIncrease: latencyIncrease,
      jitter: loadedStats.jitterMs,
      rpm: rpm?.workingRPM
    )

    // Load details
    let loadDetails = LoadGenerationDetails(
      streamsPerDirection: config.parallelStreams,
      bytesUploaded: nil,
      bytesDownloaded: nil,
      avgThroughputMbps: nil
    )

    // Print summary
    if config.loadDuration > 0 {
      print("")
      print("=== Results ===")
      print("Grade: \(grade.rawValue)")
      print(
        "Latency Increase: +\(String(format: "%.1f", latencyIncrease.absoluteMs))ms "
          + "(\(String(format: "%.0f", latencyIncrease.percentageIncrease))%)")
      if let rpm = rpm {
        print("Working RPM: \(rpm.workingRPM) (\(rpm.grade.rawValue))")
      }
      print("Video Call Impact: \(videoImpact.severity.rawValue)")
      print(videoImpact.description)
    }

    return BufferbloatResult(
      target: config.target,
      loadType: config.loadType,
      baseline: baselineStats,
      loaded: loadedStats,
      latencyIncrease: latencyIncrease,
      rpm: rpm,
      grade: grade,
      videoCallImpact: videoImpact,
      pingResults: allPingResults,
      loadDetails: loadDetails
    )
  }
}

// MARK: - Free Functions (non-actor-isolated)

/// Measure baseline latency (idle network)
/// Non-actor-isolated to avoid Swift 6.2 actor scheduling issues
private func measureBaseline(
  target: String,
  duration: TimeInterval,
  interval: TimeInterval,
  swiftFTRConfig: SwiftFTRConfig
) async throws -> [BufferbloatPingResult] {
  guard duration > 0 else { return [] }

  let count = Int(duration / interval)
  guard count > 0 else { return [] }

  // Use PingExecutor with count > 1 to do all pings in a single session
  // This creates only ONE socket and ONE receiver Task for all pings
  let executor = PingExecutor(config: swiftFTRConfig)
  let pingConfig = PingConfig(count: count, interval: interval, timeout: 2.0)

  let pingResult = try await executor.ping(to: target, config: pingConfig)

  // Convert PingResponse to BufferbloatPingResult
  return pingResult.responses.enumerated().map { (seq, response) in
    BufferbloatPingResult(
      timestamp: response.timestamp,
      phase: .baseline,
      rtt: response.rtt,
      sequence: seq
    )
  }
}

/// Measure latency under network load
/// Non-actor-isolated to avoid Swift 6.2 actor scheduling issues
private func measureUnderLoad(
  target: String,
  loadDuration: TimeInterval,
  loadType: LoadType,
  interval: TimeInterval,
  config: BufferbloatConfig,
  swiftFTRConfig: SwiftFTRConfig
) async throws -> [BufferbloatPingResult] {
  guard loadDuration > 0 else { return [] }

  let count = Int(loadDuration / interval)
  guard count > 0 else { return [] }

  // Start load generation in background
  let loadGen = LoadGenerator(config: config)
  let loadTask = Task {
    await loadGen.startLoad(duration: loadDuration, type: loadType)
  }

  // Use PingExecutor with count > 1 to do all pings in a single session
  // This creates only ONE socket and ONE receiver Task for all pings
  let executor = PingExecutor(config: swiftFTRConfig)
  let pingConfig = PingConfig(count: count, interval: interval, timeout: 2.0)

  let pingResult = try await executor.ping(to: target, config: pingConfig)

  // Wait for load generation to finish
  await loadTask.value
  await loadGen.stopLoad()

  // Convert PingResponse to BufferbloatPingResult with phase classification
  let rampUpCount = max(1, count / 10)  // First 10% is ramp-up
  let rampDownCount = max(1, count / 10)  // Last 10% is ramp-down

  return pingResult.responses.enumerated().map { (seq, response) in
    let phase: TestPhase
    if seq < rampUpCount {
      phase = .rampUp
    } else if seq >= count - rampDownCount {
      phase = .rampDown
    } else {
      phase = .sustained
    }

    return BufferbloatPingResult(
      timestamp: response.timestamp,
      phase: phase,
      rtt: response.rtt,
      sequence: seq
    )
  }
}

/// Compute statistics from ping results
private func computeStatistics(_ results: [BufferbloatPingResult]) -> LatencyMeasurements {
  let rtts = results.compactMap { $0.rtt }.map { $0 * 1000 }  // Convert to ms
  guard !rtts.isEmpty else {
    return LatencyMeasurements(
      sampleCount: 0, minMs: 0, avgMs: 0, maxMs: 0,
      p50Ms: 0, p95Ms: 0, p99Ms: 0, jitterMs: 0)
  }

  let sorted = rtts.sorted()
  let min = sorted.first!
  let max = sorted.last!
  let avg = rtts.reduce(0, +) / Double(rtts.count)
  let p50 = percentile(sorted, 0.50)
  let p95 = percentile(sorted, 0.95)
  let p99 = percentile(sorted, 0.99)

  // Jitter = standard deviation
  let variance = rtts.map { pow($0 - avg, 2) }.reduce(0, +) / Double(rtts.count)
  let jitter = sqrt(variance)

  return LatencyMeasurements(
    sampleCount: rtts.count,
    minMs: min,
    avgMs: avg,
    maxMs: max,
    p50Ms: p50,
    p95Ms: p95,
    p99Ms: p99,
    jitterMs: jitter
  )
}

/// Calculate RPM (Round-trips Per Minute) score per IETF spec
private func calculateRPM(baseline: LatencyMeasurements, loaded: LatencyMeasurements)
  -> RPMScore
{
  // RPM = 60 / avg_rtt_seconds
  let workingRTT = max(loaded.avgMs / 1000, 0.001)  // Convert to seconds, avoid divide by zero
  let idleRTT = max(baseline.avgMs / 1000, 0.001)

  let workingRPM = Int(60.0 / workingRTT)
  let idleRPM = Int(60.0 / idleRTT)

  // Grade based on working RPM per IETF thresholds
  let grade: RPMGrade
  switch workingRPM {
  case ..<300:
    grade = .poor  // >200ms RTT
  case 300..<1000:
    grade = .fair  // 60-200ms RTT
  case 1000..<6000:
    grade = .good  // 10-60ms RTT
  default:
    grade = .excellent  // <10ms RTT
  }

  return RPMScore(workingRPM: workingRPM, idleRPM: idleRPM, grade: grade)
}

/// Grade bufferbloat based on latency increase
private func gradeBufferbloat(latencyIncrease: LatencyIncrease) -> BufferbloatGrade {
  let increase = latencyIncrease.absoluteMs

  switch increase {
  case ..<25: return .a
  case 25..<75: return .b
  case 75..<150: return .c
  case 150..<300: return .d
  default: return .f
  }
}

/// Assess impact on video calling (Zoom, Teams, etc.)
private func assessVideoCallImpact(
  grade: BufferbloatGrade,
  latencyIncrease: LatencyIncrease,
  jitter: Double,
  rpm: Int?
) -> VideoCallImpact {
  // Zoom/Teams requirements:
  // - <150ms latency
  // - <50ms jitter
  // - Stable connection

  let impacts = grade >= .d || jitter > 50 || (rpm ?? 1000) < 1000

  let severity: VideoCallSeverity
  let description: String

  switch (grade, jitter) {
  case (.a, ..<30):
    severity = .none
    description = "Excellent network quality. Video calls will work great."

  case (.b, ..<50):
    severity = .minor
    description = "Good network quality. Video calls should work well."

  case (.c, ..<50):
    severity = .moderate
    description = "Acceptable quality. May see occasional glitches during video calls."

  case (.c, 50...):
    severity = .moderate
    description =
      "High jitter (\(String(format: "%.0f", jitter))ms). Video may stutter during busy periods."

  case (.d, _):
    severity = .severe
    description =
      "Significant bufferbloat detected. Video calls will freeze when network is busy."

  case (.f, _):
    severity = .severe
    description =
      "Critical bufferbloat (\(String(format: "%.0f", latencyIncrease.absoluteMs))ms spike). "
      + "Video calls unusable when network is busy. Enable QoS/SQM on router."

  default:
    severity = .moderate
    description = "Network quality may impact video calls."
  }

  return VideoCallImpact(
    impactsVideoCalls: impacts,
    severity: severity,
    description: description
  )
}

/// Calculate percentile from sorted array
private func percentile(_ sorted: [Double], _ p: Double) -> Double {
  let index = Int(Double(sorted.count) * p)
  return sorted[min(index, sorted.count - 1)]
}
