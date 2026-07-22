import Foundation
import SwiftFTR

@main
struct TestLibraryUsage {
  static func main() {
    // Compile the v0.13 callable shapes from a separate Swift package. These references complement
    // the package's unit tests by proving that no testable or implementation-only API is required.
    let legacyTraceResultInitializer: (String, Int, Bool, [TraceHop], TimeInterval) -> TraceResult =
      TraceResult.init(destination:maxHops:reached:hops:duration:)
    let legacyUDPConfigInitializer:
      (String, Int, TimeInterval, Data, PreferredFamily) -> UDPProbeConfig =
        UDPProbeConfig.init(host:port:timeout:payload:preferredFamily:)
    let legacyUDPProbe: (String, Int, TimeInterval, Data) async throws -> UDPProbeResult =
      udpProbe(host:port:timeout:payload:)

    let result = legacyTraceResultInitializer("example.com", 8, false, [], 0.25)
    let config = legacyUDPConfigInitializer("example.com", 53, 1.0, Data(), .auto)

    precondition(result.resolvedIP == nil)
    precondition(config.interface == nil)
    print("SwiftFTR \(swiftFTRVersion) external API compiled successfully")

    _ = legacyUDPProbe
  }
}
