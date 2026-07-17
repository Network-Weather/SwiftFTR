import Foundation

/// Numeric limits shared by public network-operation configurations.
enum ConfigurationLimits {
  /// Largest ICMP Echo or UDP payload that fits in an IPv4 packet.
  static let maximumProbePayloadSize = 65_507

  /// A conservative timeout whose nanosecond representation fits in a signed 64-bit timer.
  static let maximumTimeout: TimeInterval = TimeInterval(Int32.max)

  /// Millisecond form of ``maximumTimeout``.
  static let maximumTimeoutMilliseconds = Int(Int32.max) * 1_000

  /// ICMP sequence numbers are 16-bit and zero is reserved by the ping implementation.
  static let maximumPingCount = Int(UInt16.max)

  /// A defensive ceiling that prevents pathological task creation while allowing large load tests.
  static let maximumParallelStreams = 1_024
}

extension SwiftFTRConfig {
  /// Validates values used by trace and related operations before they reach socket APIs.
  func validateForOperation() throws {
    guard (1...255).contains(maxHops) else {
      throw TracerouteError.invalidConfiguration(reason: "maxHops must be in 1...255")
    }
    guard (1...ConfigurationLimits.maximumTimeoutMilliseconds).contains(maxWaitMs) else {
      throw TracerouteError.invalidConfiguration(
        reason:
          "maxWaitMs must be in 1...\(ConfigurationLimits.maximumTimeoutMilliseconds)"
      )
    }
    guard (0...ConfigurationLimits.maximumProbePayloadSize).contains(payloadSize) else {
      throw TracerouteError.invalidConfiguration(
        reason:
          "payloadSize must be in 0...\(ConfigurationLimits.maximumProbePayloadSize)"
      )
    }

    if let rdnsCacheTTL {
      guard
        rdnsCacheTTL.isFinite, rdnsCacheTTL >= 0,
        rdnsCacheTTL <= ConfigurationLimits.maximumTimeout
      else {
        throw TracerouteError.invalidConfiguration(
          reason:
            "rdnsCacheTTL must be finite and in 0...\(ConfigurationLimits.maximumTimeout) seconds"
        )
      }
    }
    if let rdnsCacheSize {
      guard rdnsCacheSize >= 0 else {
        throw TracerouteError.invalidConfiguration(
          reason: "rdnsCacheSize must be non-negative")
      }
    }
    if case .hybrid(_, let fallbackTimeout) = asnResolverStrategy {
      try validatePositiveTimeout(fallbackTimeout, named: "ASN fallbackTimeout")
    }
  }

  /// A safe cache TTL used while retaining invalid public input for operation-time validation.
  var cacheTTLForConstruction: TimeInterval {
    guard
      let rdnsCacheTTL, rdnsCacheTTL.isFinite, rdnsCacheTTL >= 0,
      rdnsCacheTTL <= ConfigurationLimits.maximumTimeout
    else { return 86_400 }
    return rdnsCacheTTL
  }

  /// A safe cache size used while retaining invalid public input for operation-time validation.
  var cacheSizeForConstruction: Int {
    guard let rdnsCacheSize, rdnsCacheSize >= 0 else { return 1_000 }
    return rdnsCacheSize
  }
}

extension StreamingTraceConfig {
  /// Validates streaming values before timers and packet buffers are created.
  func validateForOperation() throws {
    guard (1...255).contains(maxHops) else {
      throw TracerouteError.invalidConfiguration(reason: "maxHops must be in 1...255")
    }
    try validatePositiveTimeout(probeTimeout, named: "probeTimeout")
    if let retryAfter {
      try validatePositiveTimeout(retryAfter, named: "retryAfter")
    }
  }
}

extension PingConfig {
  /// Validates values before constructing packets, sequence numbers, sleeps, or timers.
  func validateForOperation() throws {
    guard (1...ConfigurationLimits.maximumPingCount).contains(count) else {
      throw TracerouteError.invalidConfiguration(
        reason: "count must be in 1...\(ConfigurationLimits.maximumPingCount)")
    }
    try validateNonnegativeDuration(interval, named: "interval")
    try validatePositiveTimeout(timeout, named: "timeout")
    guard (0...ConfigurationLimits.maximumProbePayloadSize).contains(payloadSize) else {
      throw TracerouteError.invalidConfiguration(
        reason:
          "payloadSize must be in 0...\(ConfigurationLimits.maximumProbePayloadSize)"
      )
    }

    // Ping's safety timer is twice the send schedule plus the reply timeout,
    // with five seconds of cleanup headroom. Bound that derived value before
    // converting it to integer nanoseconds.
    let sendSchedule = TimeInterval(count - 1) * interval
    let safetyBudget = 2 * (sendSchedule + timeout) + 5
    let maximumNanosecondInterval = TimeInterval(Int.max / 1_000_000_000)
    guard safetyBudget.isFinite, safetyBudget <= maximumNanosecondInterval else {
      throw TracerouteError.invalidConfiguration(
        reason: "count, interval, and timeout produce an unsupported operation duration")
    }
  }
}

extension TCPProbeConfig {
  /// Validates values before narrowing the port or scheduling a timer.
  func validateForOperation() throws {
    try validatePort(port)
    try validatePositiveTimeout(timeout, named: "timeout")
  }
}

extension UDPProbeConfig {
  /// Validates values before narrowing the port, allocating a packet, or scheduling a timer.
  func validateForOperation() throws {
    try validatePort(port)
    try validatePositiveTimeout(timeout, named: "timeout")
    guard payload.count <= ConfigurationLimits.maximumProbePayloadSize else {
      throw TracerouteError.invalidConfiguration(
        reason:
          "payload must contain at most \(ConfigurationLimits.maximumProbePayloadSize) bytes"
      )
    }
  }
}

extension BufferbloatConfig {
  /// Validates durations and counts before deriving ping samples or task ranges.
  func validateForOperation() throws {
    guard !target.isEmpty else {
      throw TracerouteError.invalidConfiguration(reason: "target must not be empty")
    }
    try validateNonnegativeDuration(baselineDuration, named: "baselineDuration")
    try validateNonnegativeDuration(loadDuration, named: "loadDuration")
    guard (1...ConfigurationLimits.maximumParallelStreams).contains(parallelStreams) else {
      throw TracerouteError.invalidConfiguration(
        reason:
          "parallelStreams must be in 1...\(ConfigurationLimits.maximumParallelStreams)"
      )
    }
    try validatePositiveTimeout(pingInterval, named: "pingInterval")

    try validatePingSampleCount(for: baselineDuration, interval: pingInterval)
    try validatePingSampleCount(for: loadDuration, interval: pingInterval)

    if let uploadURL {
      try validateHTTPURL(uploadURL, named: "uploadURL")
    }
    if let downloadURL {
      try validateHTTPURL(downloadURL, named: "downloadURL")
    }
  }
}

extension MultipathConfig {
  /// Validates values before constructing ranges, flow identifiers, or trace timers.
  func validateForOperation() throws {
    guard (1...(Int(UInt16.max) + 1)).contains(flowVariations) else {
      throw TracerouteError.invalidConfiguration(
        reason: "flowVariations must be in 1...\(Int(UInt16.max) + 1)")
    }
    guard maxPaths > 0 else {
      throw TracerouteError.invalidConfiguration(reason: "maxPaths must be positive")
    }
    guard earlyStopThreshold > 0 else {
      throw TracerouteError.invalidConfiguration(reason: "earlyStopThreshold must be positive")
    }
    guard (1...ConfigurationLimits.maximumTimeoutMilliseconds).contains(timeoutMs) else {
      throw TracerouteError.invalidConfiguration(
        reason:
          "timeoutMs must be in 1...\(ConfigurationLimits.maximumTimeoutMilliseconds)"
      )
    }
    guard (1...255).contains(maxHops) else {
      throw TracerouteError.invalidConfiguration(reason: "maxHops must be in 1...255")
    }
  }
}

private func validatePort(_ port: Int) throws {
  guard (1...Int(UInt16.max)).contains(port) else {
    throw TracerouteError.invalidConfiguration(reason: "port must be in 1...65535")
  }
}

private func validatePositiveTimeout(_ timeout: TimeInterval, named name: String) throws {
  guard timeout.isFinite, timeout > 0, timeout <= ConfigurationLimits.maximumTimeout else {
    throw TracerouteError.invalidConfiguration(
      reason:
        "\(name) must be finite and in (0, \(ConfigurationLimits.maximumTimeout)] seconds"
    )
  }
}

private func validateNonnegativeDuration(_ duration: TimeInterval, named name: String) throws {
  guard duration.isFinite, duration >= 0, duration <= ConfigurationLimits.maximumTimeout else {
    throw TracerouteError.invalidConfiguration(
      reason:
        "\(name) must be finite and in 0...\(ConfigurationLimits.maximumTimeout) seconds"
    )
  }
}

private func validatePingSampleCount(for duration: TimeInterval, interval: TimeInterval) throws {
  let sampleCount = duration / interval
  guard sampleCount < TimeInterval(ConfigurationLimits.maximumPingCount + 1) else {
    throw TracerouteError.invalidConfiguration(
      reason:
        "duration divided by pingInterval must produce at most \(ConfigurationLimits.maximumPingCount) samples"
    )
  }
}

private func validateHTTPURL(_ value: String, named name: String) throws {
  guard
    let url = URL(string: value), let scheme = url.scheme?.lowercased(),
    scheme == "http" || scheme == "https", url.host != nil
  else {
    throw TracerouteError.invalidConfiguration(
      reason: "\(name) must be an absolute HTTP or HTTPS URL")
  }
}
