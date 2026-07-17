import Foundation
import Testing

@testable import SwiftFTR

@Suite("Ping configuration validation")
struct PingConfigurationValidationTests {
  @Test("Ping rejects trap-prone numeric inputs before network work")
  func pingRejectsInvalidConfiguration() async {
    let cases: [(name: String, config: PingConfig)] = [
      ("zero count", PingConfig(count: 0)),
      ("negative count", PingConfig(count: -1)),
      ("oversized count", PingConfig(count: 65_536)),
      ("negative interval", PingConfig(interval: -1)),
      ("non-finite interval", PingConfig(interval: .infinity)),
      ("zero timeout", PingConfig(timeout: 0)),
      ("negative timeout", PingConfig(timeout: -1)),
      ("non-finite timeout", PingConfig(timeout: .nan)),
      ("negative payload", PingConfig(payloadSize: -1)),
      ("oversized payload", PingConfig(payloadSize: 65_508)),
      (
        "overflowing derived duration",
        PingConfig(count: 65_535, interval: TimeInterval(Int32.max), timeout: 1)
      ),
    ]
    let tracer = SwiftFTR()

    for testCase in cases {
      do {
        _ = try await tracer.ping(to: "127.0.0.1", config: testCase.config)
        Issue.record("\(testCase.name) should fail as invalid configuration")
      } catch TracerouteError.invalidConfiguration(let reason) {
        #expect(!reason.isEmpty)
      } catch {
        Issue.record("\(testCase.name) returned unexpected error: \(error)")
      }
    }
  }

  @Test("Ping accepts valid numeric boundaries")
  func pingAcceptsValidBoundaries() throws {
    try PingConfig(
      count: Int(UInt16.max),
      interval: 0,
      timeout: ConfigurationLimits.maximumTimeout,
      payloadSize: ConfigurationLimits.maximumProbePayloadSize
    ).validateForOperation()
  }
}
