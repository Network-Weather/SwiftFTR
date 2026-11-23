import Foundation
import SwiftFTR
import Testing

@Suite("SwiftFTR API compatibility")
struct APICompatibilityTests {
  @Test("TraceResult retains its 0.13 initializer reference")
  func traceResultInitializerReference() {
    let initializer: (String, Int, Bool, [TraceHop], TimeInterval) -> TraceResult =
      TraceResult.init(destination:maxHops:reached:hops:duration:)

    let result = initializer("example.com", 8, false, [], 0.25)

    #expect(result.destination == "example.com")
    #expect(result.resolvedIP == nil)
    #expect(result.duration == 0.25)
  }

  @Test("UDPProbeConfig retains its 0.13 initializer reference")
  func udpProbeConfigInitializerReference() {
    let initializer: (String, Int, TimeInterval, Data, PreferredFamily) -> UDPProbeConfig =
      UDPProbeConfig.init(host:port:timeout:payload:preferredFamily:)

    let config = initializer("example.com", 53, 1.5, Data([0x01]), .v4)

    #expect(config.host == "example.com")
    #expect(config.interface == nil)
    #expect(config.sourceIP == nil)
    #expect(config.preferredFamily == .v4)
  }

  @Test("udpProbe retains its 0.13 function reference")
  func udpProbeFunctionReference() {
    let probe: (String, Int, TimeInterval, Data) async throws -> UDPProbeResult =
      udpProbe(host:port:timeout:payload:)

    _ = probe
  }

  @Test("UDP source-only overloads accept an optional selection")
  func optionalSourceOnlyOverloads() {
    let initializer: (String, Int, TimeInterval, Data, String?, PreferredFamily) -> UDPProbeConfig =
      UDPProbeConfig.init(host:port:timeout:payload:sourceIP:preferredFamily:)
    let probe: (String, Int, TimeInterval, Data, String?) async throws -> UDPProbeResult =
      udpProbe(host:port:timeout:payload:sourceIP:)

    let config = initializer("example.com", 53, 1.0, Data(), nil, .auto)

    #expect(config.interface == nil)
    #expect(config.sourceIP == nil)
    _ = probe
  }

  /// Compiles only while these are exactly ``DNSError``'s cases: a case added or removed breaks
  /// this exhaustive switch, as it would a consumer's. 0.19 added `connectionRefused` and
  /// `unreachable`.
  @Test("DNSError has exactly the cases a consumer's exhaustive switch names")
  func dnsErrorCasesAreExhaustive() {
    func name(_ error: DNSError) -> String {
      switch error {
      case .invalidIP: "invalidIP"
      case .invalidHostname: "invalidHostname"
      case .invalidTimeout: "invalidTimeout"
      case .socketCreationFailed: "socketCreationFailed"
      case .setsockoptFailed: "setsockoptFailed"
      case .bindFailed: "bindFailed"
      case .sendFailed: "sendFailed"
      case .connectionRefused: "connectionRefused"
      case .unreachable: "unreachable"
      case .timeout: "timeout"
      case .malformedResponse: "malformedResponse"
      case .noRecords: "noRecords"
      case .serverError: "serverError"
      }
    }
    #expect(name(.connectionRefused) == "connectionRefused")
    #expect(name(.unreachable) == "unreachable")
  }
}
