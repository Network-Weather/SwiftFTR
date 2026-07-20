import Foundation

#if canImport(Darwin)
  import Darwin
#endif

// MARK: - Configuration

/// Configuration for a bufferbloat/responsiveness test.
///
/// Values are validated by ``SwiftFTR/testBufferbloat(config:)`` before the test starts.
public struct BufferbloatConfig: Sendable {
  /// Target to ping for latency measurement (default: 1.1.1.1)
  public let target: String

  /// Duration of baseline (idle) measurement in seconds
  public let baselineDuration: TimeInterval

  /// Duration of load generation in seconds.
  ///
  /// Set this to zero for a baseline-only latency measurement. In that mode, only
  /// ``BufferbloatResult/baseline`` and baseline entries in ``BufferbloatResult/pingResults`` are
  /// meaningful; loaded statistics and derived bufferbloat metrics are placeholders and must not
  /// be interpreted.
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

  /// Network interface to bind to for latency measurements during a baseline-only test.
  ///
  /// URLSession does not expose a public API for binding HTTP traffic to an interface. To avoid
  /// comparing latency and load from different routes, loaded tests reject this option (and a
  /// globally configured interface) with ``TracerouteError/invalidConfiguration(reason:)``.
  /// A bound baseline-only run exposes usable baseline latency, but its loaded statistics,
  /// latency increase, RPM score, and grade are not meaningful.
  ///
  /// Example:
  /// ```swift
  /// let snapshot = await NetworkInterfaceDiscovery().discover()
  /// if let selectedInterface = snapshot.activeInterfaces.first {
  ///   // Measure baseline latency via a discovered interface without generating load.
  ///   let result = try await ftr.testBufferbloat(
  ///     config: BufferbloatConfig(
  ///       target: "1.1.1.1",
  ///       loadDuration: 0,
  ///       interface: selectedInterface.name
  ///     )
  ///   )
  /// }
  /// ```
  public let interface: String?

  /// Source IP address to bind to for latency measurements during a baseline-only test.
  ///
  /// Loaded tests reject this option (and a globally configured source IP), because their HTTP
  /// traffic cannot be bound to the same source using public URLSession APIs.
  /// A bound baseline-only run exposes usable baseline latency, but its loaded statistics,
  /// latency increase, RPM score, and grade are not meaningful.
  public let sourceIP: String?

  public init(
    target: String = "1.1.1.1",
    baselineDuration: TimeInterval = 5.0,
    loadDuration: TimeInterval = 10.0,
    loadType: LoadType = .bidirectional,
    parallelStreams: Int = 4,
    pingInterval: TimeInterval = 0.1,
    calculateRPM: Bool = true,
    uploadURL: String? = nil,
    downloadURL: String? = nil,
    interface: String? = nil,
    sourceIP: String? = nil
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
    self.interface = interface
    self.sourceIP = sourceIP
  }
}

/// Type of network load to generate
public enum LoadType: String, Sendable, Codable {
  case upload = "Upload"
  case download = "Download"
  case bidirectional = "Bidirectional"
}

// MARK: - Results

/// Result from a bufferbloat test or baseline-only latency measurement.
///
/// When the configuration's load duration is zero, only ``baseline`` and baseline entries in
/// ``pingResults`` are meaningful. The loaded statistics, latency increase, RPM score, grade, and
/// video-call assessment require a loaded phase and must not be interpreted for a baseline-only
/// result.
public struct BufferbloatResult: Sendable, Codable {
  /// Target tested
  public let target: String

  /// Load type used
  public let loadType: LoadType

  /// Baseline (idle) measurements
  public let baseline: LatencyMeasurements

  /// Loaded measurements, meaningful only when a loaded phase produced samples.
  public let loaded: LatencyMeasurements

  /// Latency increase statistics, meaningful only when baseline and loaded phases produced
  /// samples.
  public let latencyIncrease: LatencyIncrease

  /// RPM (Round-trips Per Minute) score, meaningful only when baseline and loaded phases produced
  /// samples.
  public let rpm: RPMScore?

  /// Overall bufferbloat grade, meaningful only when a loaded phase produced samples.
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

/// Generates network load using multiple parallel HTTP streams.
struct LoadGenerator: Sendable {
  private let config: BufferbloatConfig

  init(config: BufferbloatConfig) {
    self.config = config
  }

  /// Generates load until the duration expires or the calling task is cancelled.
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

// MARK: - Bufferbloat Runner

/// Injectable effects used by the bufferbloat orchestrator.
struct BufferbloatDependencies: Sendable {
  let ping: @Sendable (String, PingConfig) async throws -> PingResult
  let generateLoad: @Sendable (TimeInterval, LoadType) async -> Void

  static func live(
    testConfig: BufferbloatConfig,
    swiftFTRConfig: SwiftFTRConfig
  ) -> BufferbloatDependencies {
    BufferbloatDependencies(
      ping: { target, pingConfig in
        let executor = PingExecutor(config: swiftFTRConfig)
        return try await executor.ping(to: target, config: pingConfig)
      },
      generateLoad: { duration, type in
        let generator = LoadGenerator(config: testConfig)
        await generator.startLoad(duration: duration, type: type)
      }
    )
  }
}

/// Runs the bufferbloat orchestration.
struct BufferbloatRunner: Sendable {
  let testConfig: BufferbloatConfig
  let swiftConfig: SwiftFTRConfig
  let dependencies: BufferbloatDependencies

  init(
    testConfig: BufferbloatConfig,
    swiftConfig: SwiftFTRConfig,
    dependencies: BufferbloatDependencies? = nil
  ) {
    self.testConfig = testConfig
    self.swiftConfig = swiftConfig
    self.dependencies =
      dependencies
      ?? .live(
        testConfig: testConfig,
        swiftFTRConfig: swiftConfig
      )
  }

  func run() async throws -> BufferbloatResult {
    try validateRouteConfiguration()

    var allPingResults: [BufferbloatPingResult] = []

    if testConfig.baselineDuration > 0 {
      print("📊 Bufferbloat Test Started")
      print("Target: \(testConfig.target)")
      print("Load Type: \(testConfig.loadType.rawValue)")
      print("")
    }

    // Phase 1: Baseline measurement (idle network)
    if testConfig.baselineDuration > 0 {
      print("Phase 1/2: Measuring baseline latency (idle network)...")
    }

    let baselineResults = try await measureBaseline(
      target: testConfig.target,
      duration: testConfig.baselineDuration,
      interval: testConfig.pingInterval,
      interface: testConfig.interface,
      sourceIP: testConfig.sourceIP,
      ping: dependencies.ping
    )
    allPingResults.append(contentsOf: baselineResults)

    let baselineStats = computeStatistics(baselineResults)

    if testConfig.baselineDuration > 0 {
      if baselineStats.sampleCount > 0 {
        print(
          "✓ Baseline: avg=\(String(format: "%.1f", baselineStats.avgMs))ms, "
            + "p95=\(String(format: "%.1f", baselineStats.p95Ms))ms")
      } else {
        print("⚠️ Baseline: Failed (0 samples received)")
      }
      print("")
    }

    // Phase 2: Load generation + latency measurement
    if testConfig.loadDuration > 0 {
      print(
        "Phase 2/2: Generating \(testConfig.loadType.rawValue.lowercased()) load "
          + "(\(testConfig.parallelStreams) streams per direction)...")
    }

    let loadedResults = try await measureUnderLoad(
      target: testConfig.target,
      loadDuration: testConfig.loadDuration,
      loadType: testConfig.loadType,
      interval: testConfig.pingInterval,
      interface: testConfig.interface,
      sourceIP: testConfig.sourceIP,
      dependencies: dependencies
    )
    allPingResults.append(contentsOf: loadedResults)

    // Only analyze sustained load phase
    let sustainedResults = loadedResults.filter { $0.phase == .sustained }
    let loadedStats = computeStatistics(sustainedResults)

    if testConfig.loadDuration > 0 {
      if loadedStats.sampleCount > 0 {
        print(
          "✓ Under Load: avg=\(String(format: "%.1f", loadedStats.avgMs))ms, "
            + "p95=\(String(format: "%.1f", loadedStats.p95Ms))ms")
      } else {
        print("⚠️ Under Load: Failed (0 samples received)")
      }
      print("")
    }

    // Phase 3: Analysis
    if testConfig.loadDuration > 0 {
      print("Analyzing results...")
    }

    let latencyIncrease: LatencyIncrease
    if baselineStats.sampleCount > 0 && loadedStats.sampleCount > 0 {
      latencyIncrease = LatencyIncrease(
        absoluteMs: loadedStats.avgMs - baselineStats.avgMs,
        percentageIncrease: ((loadedStats.avgMs - baselineStats.avgMs)
          / max(baselineStats.avgMs, 0.001)) * 100,
        p99IncreaseMs: loadedStats.p99Ms - baselineStats.p99Ms
      )
    } else {
      // If samples are missing, we can't calculate a valid increase.
      // Treat as "Infinite" or "Failure".
      latencyIncrease = LatencyIncrease(
        absoluteMs: 0.0,  // Placeholder
        percentageIncrease: 0.0,
        p99IncreaseMs: 0.0
      )
    }

    // Calculate RPM
    var rpm: RPMScore? = nil
    if testConfig.calculateRPM {
      if baselineStats.sampleCount > 0 && loadedStats.sampleCount > 0 {
        rpm = calculateRPM(baseline: baselineStats, loaded: loadedStats)
      } else {
        // If we have no samples (100% packet loss), that's effectively 0 RPM (Poor)
        rpm = RPMScore(workingRPM: 0, idleRPM: 0, grade: .poor)
      }
    }

    // Grade bufferbloat
    let grade: BufferbloatGrade
    if loadedStats.sampleCount == 0 {
      // 100% packet loss during load is a critical failure (Grade F)
      grade = .f
    } else if baselineStats.sampleCount == 0 {
      // Baseline failed? Also F.
      grade = .f
    } else {
      grade = gradeBufferbloat(latencyIncrease: latencyIncrease)
    }

    // Assess video call impact
    let videoImpact = assessVideoCallImpact(
      grade: grade,
      latencyIncrease: latencyIncrease,
      jitter: loadedStats.jitterMs,
      rpm: rpm?.workingRPM
    )

    // Load details
    let loadDetails = LoadGenerationDetails(
      streamsPerDirection: testConfig.parallelStreams,
      bytesUploaded: nil,
      bytesDownloaded: nil,
      avgThroughputMbps: nil
    )

    // Print summary
    if testConfig.loadDuration > 0 {
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
      target: testConfig.target,
      loadType: testConfig.loadType,
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

  private func validateRouteConfiguration() throws {
    guard testConfig.loadDuration > 0 else { return }

    let effectiveInterface = testConfig.interface ?? swiftConfig.interface
    let effectiveSourceIP = testConfig.sourceIP ?? swiftConfig.sourceIP
    guard effectiveInterface == nil, effectiveSourceIP == nil else {
      throw TracerouteError.invalidConfiguration(
        reason: "Loaded bufferbloat tests do not support interface or sourceIP binding because "
          + "URLSession load traffic cannot be bound to the same route as latency probes. "
          + "Remove interface/sourceIP or set loadDuration to 0 for a baseline-only measurement."
      )
    }
  }
}

// MARK: - Free Functions (non-actor-isolated)

/// Measure baseline latency (idle network)
/// Non-actor-isolated to avoid Swift 6.2 actor scheduling issues
#if compiler(>=6.2)
  @concurrent
#endif
private func measureBaseline(
  target: String,
  duration: TimeInterval,
  interval: TimeInterval,
  interface: String?,
  sourceIP: String?,
  ping: @Sendable (String, PingConfig) async throws -> PingResult
) async throws -> [BufferbloatPingResult] {
  guard duration > 0 else { return [] }

  let count = Int(duration / interval)
  guard count > 0 else { return [] }

  // Use PingExecutor with count > 1 to do all pings in a single session
  // This creates only ONE socket and ONE receiver Task for all pings
  let pingConfig = PingConfig(
    count: count,
    interval: interval,
    timeout: 2.0,
    interface: interface,
    sourceIP: sourceIP
  )

  let pingResult = try await ping(target, pingConfig)

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
#if compiler(>=6.2)
  @concurrent
#endif
private func measureUnderLoad(
  target: String,
  loadDuration: TimeInterval,
  loadType: LoadType,
  interval: TimeInterval,
  interface: String?,
  sourceIP: String?,
  dependencies: BufferbloatDependencies
) async throws -> [BufferbloatPingResult] {
  guard loadDuration > 0 else { return [] }

  let count = Int(loadDuration / interval)
  guard count > 0 else { return [] }

  // Keep load generation as a structured child. If ping fails or the caller cancels,
  // scope exit cancels and awaits this child before propagating the error.
  async let load: Void = dependencies.generateLoad(loadDuration, loadType)

  // Use PingExecutor with count > 1 to do all pings in a single session
  // This creates only ONE socket and ONE receiver Task for all pings
  let pingConfig = PingConfig(
    count: count,
    interval: interval,
    timeout: 2.0,
    interface: interface,
    sourceIP: sourceIP
  )

  let pingResult = try await dependencies.ping(target, pingConfig)

  // On success, do not return until every load request has completed.
  await load
  try Task.checkCancellation()

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
