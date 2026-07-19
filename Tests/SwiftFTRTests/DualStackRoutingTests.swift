import Darwin
import Foundation
import Testing

@testable import SwiftFTR

@Suite("Dual-stack routing invariants")
struct DualStackRoutingTests {
  @Test("Source addresses must match the resolved destination family")
  func sourceAndDestinationFamiliesMustMatch() throws {
    try validateSourceIPFamily("192.0.2.10", destinationFamily: AF_INET)
    try validateSourceIPFamily("2001:db8::10", destinationFamily: AF_INET6)

    #expect {
      try validateSourceIPFamily("192.0.2.10", destinationFamily: AF_INET6)
    } throws: { error in
      guard case TracerouteError.sourceIPBindFailed(_, let code, let details) = error else {
        return false
      }
      return code == EAFNOSUPPORT && details?.contains("destination resolved to IPv6") == true
    }

    #expect {
      try validateSourceIPFamily("not-an-address", destinationFamily: AF_INET)
    } throws: { error in
      guard case TracerouteError.sourceIPBindFailed(_, let code, _) = error else { return false }
      return code == EINVAL
    }
  }

  @Test("TraceResult carries the exact resolved endpoint")
  func traceResultResolvedIP() {
    let resolved = TraceResult(
      destination: "example.test",
      maxHops: 1,
      reached: false,
      hops: [],
      resolvedIP: "2001:db8::42"
    )
    let manuallyConstructed = TraceResult(
      destination: "example.test", maxHops: 1, reached: false, hops: [])

    #expect(resolved.resolvedIP == "2001:db8::42")
    #expect(manuallyConstructed.resolvedIP == nil)
  }

  @Test("Multipath rejects IPv6-only routing configurations")
  func multipathRemainsIPv4Only() throws {
    try validateMultipathAddressFamily(SwiftFTRConfig(preferredFamily: .auto))
    try validateMultipathAddressFamily(
      SwiftFTRConfig(sourceIP: "192.0.2.10", preferredFamily: .v4))

    #expect {
      try validateMultipathAddressFamily(SwiftFTRConfig(preferredFamily: .v6))
    } throws: { error in
      guard case TracerouteError.invalidConfiguration(let reason) = error else { return false }
      return reason.contains("IPv4 destinations")
    }

    #expect {
      try validateMultipathAddressFamily(
        SwiftFTRConfig(sourceIP: "2001:db8::10", preferredFamily: .auto))
    } throws: { error in
      guard case TracerouteError.invalidConfiguration(let reason) = error else { return false }
      return reason.contains("IPv4 source")
    }
  }
}
