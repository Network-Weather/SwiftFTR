import Foundation
import Testing

@testable import SwiftFTR

@Suite("Configuration Validation")
struct ConfigurationValidationTests {
  @Test("SwiftFTR configuration retains invalid input without trapping")
  func swiftFTRConfigurationRetainsInvalidInput() {
    let config = SwiftFTRConfig(
      maxHops: 0,
      maxWaitMs: -1,
      payloadSize: -1,
      rdnsCacheTTL: .nan,
      rdnsCacheSize: -1
    )

    #expect(config.maxHops == 0)
    #expect(config.maxWaitMs == -1)
    #expect(config.payloadSize == -1)
    #expect(config.rdnsCacheTTL?.isNaN == true)
    #expect(config.rdnsCacheSize == -1)

    // Cache construction uses safe internal fallbacks until a throwing operation validates config.
    _ = SwiftFTR(config: config)
  }

  @Test("Trace rejects invalid numeric configuration before network work")
  func traceRejectsInvalidConfiguration() async {
    let cases: [(name: String, config: SwiftFTRConfig)] = [
      ("zero hops", SwiftFTRConfig(maxHops: 0)),
      ("too many hops", SwiftFTRConfig(maxHops: 256)),
      ("zero wait", SwiftFTRConfig(maxWaitMs: 0)),
      ("oversized wait", SwiftFTRConfig(maxWaitMs: Int.max)),
      ("negative payload", SwiftFTRConfig(payloadSize: -1)),
      ("oversized payload", SwiftFTRConfig(payloadSize: 65_508)),
      ("non-finite cache TTL", SwiftFTRConfig(rdnsCacheTTL: .infinity)),
      ("oversized cache TTL", SwiftFTRConfig(rdnsCacheTTL: .greatestFiniteMagnitude)),
      ("negative cache size", SwiftFTRConfig(rdnsCacheSize: -1)),
      (
        "non-finite ASN fallback timeout",
        SwiftFTRConfig(asnResolverStrategy: .hybrid(.embedded, fallbackTimeout: .nan))
      ),
    ]

    for testCase in cases {
      let tracer = SwiftFTR(config: testCase.config)
      let reason = await invalidConfigurationReason {
        _ = try await tracer.trace(to: "127.0.0.1")
      }
      #expect(
        !reason.isEmpty,
        Comment(rawValue: "\(testCase.name) should fail as invalid configuration"))
    }
  }

  @Test("Streaming trace rejects invalid timeout, retry, and hop values")
  func streamingTraceRejectsInvalidConfiguration() async {
    let cases: [(name: String, config: StreamingTraceConfig)] = [
      ("zero hops", StreamingTraceConfig(maxHops: 0)),
      ("too many hops", StreamingTraceConfig(maxHops: 256)),
      ("zero timeout", StreamingTraceConfig(probeTimeout: 0)),
      ("negative timeout", StreamingTraceConfig(probeTimeout: -1)),
      ("non-finite timeout", StreamingTraceConfig(probeTimeout: .infinity)),
      ("zero retry", StreamingTraceConfig(retryAfter: 0)),
      ("negative retry", StreamingTraceConfig(retryAfter: -1)),
      ("non-finite retry", StreamingTraceConfig(retryAfter: .nan)),
    ]
    let tracer = SwiftFTR()

    for testCase in cases {
      let reason = await invalidConfigurationReason {
        for try await _ in tracer.traceStream(to: "127.0.0.1", config: testCase.config) {}
      }
      #expect(
        !reason.isEmpty,
        Comment(rawValue: "\(testCase.name) should fail as invalid configuration"))
    }
  }

  @Test("TCP probe rejects ports and timeouts that cannot reach socket APIs")
  func tcpProbeRejectsInvalidConfiguration() async {
    let cases: [(name: String, config: TCPProbeConfig)] = [
      ("zero port", TCPProbeConfig(host: "127.0.0.1", port: 0)),
      ("negative port", TCPProbeConfig(host: "127.0.0.1", port: -1)),
      ("oversized port", TCPProbeConfig(host: "127.0.0.1", port: 65_536)),
      ("zero timeout", TCPProbeConfig(host: "127.0.0.1", port: 80, timeout: 0)),
      ("negative timeout", TCPProbeConfig(host: "127.0.0.1", port: 80, timeout: -1)),
      ("NaN timeout", TCPProbeConfig(host: "127.0.0.1", port: 80, timeout: .nan)),
      (
        "oversized timeout",
        TCPProbeConfig(host: "127.0.0.1", port: 80, timeout: .greatestFiniteMagnitude)
      ),
    ]

    for testCase in cases {
      let reason = await invalidConfigurationReason {
        _ = try await tcpProbe(config: testCase.config)
      }
      #expect(
        !reason.isEmpty,
        Comment(rawValue: "\(testCase.name) should fail as invalid configuration"))
    }
  }

  @Test("UDP probe rejects invalid ports, timeouts, and oversized payloads")
  func udpProbeRejectsInvalidConfiguration() async {
    let cases: [(name: String, config: UDPProbeConfig)] = [
      ("zero port", UDPProbeConfig(host: "127.0.0.1", port: 0)),
      ("negative port", UDPProbeConfig(host: "127.0.0.1", port: -1)),
      ("oversized port", UDPProbeConfig(host: "127.0.0.1", port: 65_536)),
      ("zero timeout", UDPProbeConfig(host: "127.0.0.1", port: 53, timeout: 0)),
      ("infinite timeout", UDPProbeConfig(host: "127.0.0.1", port: 53, timeout: .infinity)),
      (
        "oversized payload",
        UDPProbeConfig(host: "127.0.0.1", port: 53, payload: Data(count: 65_508))
      ),
    ]

    for testCase in cases {
      let reason = await invalidConfigurationReason {
        _ = try await udpProbe(config: testCase.config)
      }
      #expect(
        !reason.isEmpty,
        Comment(rawValue: "\(testCase.name) should fail as invalid configuration"))
    }
  }

  @Test("Bufferbloat rejects invalid values before deriving sample counts")
  func bufferbloatRejectsInvalidConfiguration() async {
    let cases: [(name: String, config: BufferbloatConfig)] = [
      ("empty target", BufferbloatConfig(target: "")),
      ("negative baseline", BufferbloatConfig(baselineDuration: -1)),
      ("non-finite load", BufferbloatConfig(loadDuration: .nan)),
      ("zero streams", BufferbloatConfig(parallelStreams: 0)),
      ("negative streams", BufferbloatConfig(parallelStreams: -1)),
      ("too many streams", BufferbloatConfig(parallelStreams: Int.max)),
      ("zero interval", BufferbloatConfig(pingInterval: 0)),
      ("non-finite interval", BufferbloatConfig(pingInterval: .infinity)),
      (
        "too many samples",
        BufferbloatConfig(baselineDuration: 65_536, loadDuration: 0, pingInterval: 1)
      ),
      ("invalid upload URL", BufferbloatConfig(uploadURL: "ftp://example.com/file")),
      ("invalid download URL", BufferbloatConfig(downloadURL: "not a URL")),
    ]
    let tracer = SwiftFTR()

    for testCase in cases {
      let reason = await invalidConfigurationReason {
        _ = try await tracer.testBufferbloat(config: testCase.config)
      }
      #expect(
        !reason.isEmpty,
        Comment(rawValue: "\(testCase.name) should fail as invalid configuration"))
    }
  }

  @Test("Multipath rejects ranges that would overflow or trap")
  func multipathRejectsInvalidConfiguration() async {
    let cases: [(name: String, config: MultipathConfig)] = [
      ("zero variations", MultipathConfig(flowVariations: 0)),
      ("negative variations", MultipathConfig(flowVariations: -1)),
      ("too many variations", MultipathConfig(flowVariations: 65_537)),
      ("zero paths", MultipathConfig(maxPaths: 0)),
      ("zero early-stop threshold", MultipathConfig(earlyStopThreshold: 0)),
      ("negative early-stop threshold", MultipathConfig(earlyStopThreshold: -1)),
      ("zero timeout", MultipathConfig(timeoutMs: 0)),
      ("oversized timeout", MultipathConfig(timeoutMs: Int.max)),
      ("zero hops", MultipathConfig(maxHops: 0)),
      ("too many hops", MultipathConfig(maxHops: 256)),
    ]
    let tracer = SwiftFTR()

    for testCase in cases {
      let reason = await invalidConfigurationReason {
        _ = try await tracer.discoverPaths(to: "127.0.0.1", config: testCase.config)
      }
      #expect(
        !reason.isEmpty,
        Comment(rawValue: "\(testCase.name) should fail as invalid configuration"))
    }
  }

  @Test("Flow identifier generation wraps extreme public variation values")
  func flowIdentifierGenerationHandlesExtremeValues() {
    let minimum = FlowIdentifier.generate(variation: .min)
    let maximum = FlowIdentifier.generate(variation: .max)

    #expect(minimum.variation == .min)
    #expect(maximum.variation == .max)
  }

  @Test("Documented upper boundaries remain valid")
  func upperBoundariesRemainValid() throws {
    try SwiftFTRConfig(
      maxHops: 255,
      maxWaitMs: ConfigurationLimits.maximumTimeoutMilliseconds,
      payloadSize: ConfigurationLimits.maximumProbePayloadSize,
      rdnsCacheTTL: 0,
      rdnsCacheSize: 0
    ).validateForOperation()
    try StreamingTraceConfig(
      probeTimeout: ConfigurationLimits.maximumTimeout,
      retryAfter: nil,
      maxHops: 255
    ).validateForOperation()
    try TCPProbeConfig(
      host: "127.0.0.1",
      port: 65_535,
      timeout: ConfigurationLimits.maximumTimeout
    ).validateForOperation()
    try UDPProbeConfig(
      host: "127.0.0.1",
      port: 65_535,
      timeout: ConfigurationLimits.maximumTimeout,
      payload: Data(count: ConfigurationLimits.maximumProbePayloadSize)
    ).validateForOperation()
    try BufferbloatConfig(
      baselineDuration: 0,
      loadDuration: 0,
      parallelStreams: ConfigurationLimits.maximumParallelStreams,
      pingInterval: ConfigurationLimits.maximumTimeout
    ).validateForOperation()
    try MultipathConfig(
      flowVariations: Int(UInt16.max) + 1,
      maxPaths: 1,
      earlyStopThreshold: 1,
      timeoutMs: ConfigurationLimits.maximumTimeoutMilliseconds,
      maxHops: 255
    ).validateForOperation()
  }
}

private func invalidConfigurationReason(
  _ operation: @Sendable () async throws -> Void
) async -> String {
  do {
    try await operation()
    Issue.record("Expected TracerouteError.invalidConfiguration")
    return ""
  } catch TracerouteError.invalidConfiguration(let reason) {
    return reason
  } catch {
    Issue.record("Expected invalid configuration, got \(error)")
    return ""
  }
}
