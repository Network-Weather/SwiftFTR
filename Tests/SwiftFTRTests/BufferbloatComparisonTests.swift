import Testing

@testable import SwiftFTR

/// Verifies that loaded measurements never compare latency and traffic from different routes.
@Suite("Bufferbloat Route Validity Tests")
struct BufferbloatRouteValidityTests {
  @Test(
    "Loaded tests reject route binding before network work",
    arguments: RouteBindingCase.cases
  )
  func loadedTestsRejectRouteBinding(testCase: RouteBindingCase) async {
    let calls = BufferbloatCallRecorder()
    let dependencies = BufferbloatDependencies(
      ping: { _, _ in
        await calls.recordPing()
        return stubRoutePingResult()
      },
      generateLoad: { _, _ in
        await calls.recordLoad()
      }
    )
    let runner = BufferbloatRunner(
      testConfig: testCase.testConfig,
      swiftConfig: testCase.swiftConfig,
      dependencies: dependencies
    )

    do {
      _ = try await runner.run()
      Issue.record("Expected route-bound load generation to be rejected")
    } catch TracerouteError.invalidConfiguration(let reason) {
      #expect(reason.contains("same route"))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    let counts = await calls.counts
    #expect(counts.ping == 0)
    #expect(counts.load == 0)
  }
}

struct RouteBindingCase: Sendable, CustomTestStringConvertible {
  let name: String
  let testConfig: BufferbloatConfig
  let swiftConfig: SwiftFTRConfig

  var testDescription: String { name }

  static let cases: [RouteBindingCase] = [
    RouteBindingCase(
      name: "operation interface",
      testConfig: loadedConfig(interface: "synthetic-interface"),
      swiftConfig: SwiftFTRConfig()
    ),
    RouteBindingCase(
      name: "operation source IP",
      testConfig: loadedConfig(sourceIP: "192.0.2.10"),
      swiftConfig: SwiftFTRConfig()
    ),
    RouteBindingCase(
      name: "global interface",
      testConfig: loadedConfig(),
      swiftConfig: SwiftFTRConfig(interface: "synthetic-interface")
    ),
    RouteBindingCase(
      name: "global source IP",
      testConfig: loadedConfig(),
      swiftConfig: SwiftFTRConfig(sourceIP: "192.0.2.10")
    ),
  ]

  private static func loadedConfig(
    interface: String? = nil,
    sourceIP: String? = nil
  ) -> BufferbloatConfig {
    BufferbloatConfig(
      baselineDuration: 1,
      loadDuration: 1,
      parallelStreams: 1,
      pingInterval: 1,
      interface: interface,
      sourceIP: sourceIP
    )
  }
}

private actor BufferbloatCallRecorder {
  private var pingCalls = 0
  private var loadCalls = 0

  var counts: (ping: Int, load: Int) {
    (pingCalls, loadCalls)
  }

  func recordPing() {
    pingCalls += 1
  }

  func recordLoad() {
    loadCalls += 1
  }
}

private func stubRoutePingResult() -> PingResult {
  PingResult(
    target: "192.0.2.1",
    resolvedIP: "192.0.2.1",
    responses: [],
    statistics: PingStatistics(
      sent: 0,
      received: 0,
      packetLoss: 0,
      minRTT: nil,
      avgRTT: nil,
      maxRTT: nil,
      jitter: nil
    )
  )
}
