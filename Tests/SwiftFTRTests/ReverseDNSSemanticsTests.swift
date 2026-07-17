import Darwin
import Foundation
import Testing

@testable import SwiftFTR

@Suite("Reverse DNS hostname semantics")
struct ReverseDNSSemanticsTests {
  @Test("IPv4 and IPv6 lookups require a hostname")
  func lookupRequiresName() {
    for address in ["192.0.2.1", "2001:db8::1"] {
      var receivedFlags: Int32 = 0
      let hostname = reverseDNS(address) {
        _, _, host, hostLength, _, _, flags in
        receivedFlags = flags
        writeCString("router.example", to: host, capacity: hostLength)
        return 0
      }

      #expect(hostname == "router.example")
      #expect((receivedFlags & NI_NAMEREQD) != 0)
    }
  }

  @Test("A missing PTR record returns nil instead of numeric fallback text")
  func missingNameReturnsNil() {
    let hostname = reverseDNS("192.0.2.1") {
      _, _, _, _, _, _, flags in
      #expect((flags & NI_NAMEREQD) != 0)
      return EAI_NONAME
    }

    #expect(hostname == nil)
  }

  @Test("Invalid numeric input never invokes the resolver")
  func invalidInputSkipsLookup() {
    var invoked = false
    let hostname = reverseDNS("not-an-address") {
      _, _, _, _, _, _, _ in
      invoked = true
      return 0
    }

    #expect(hostname == nil)
    #expect(!invoked)
  }
}

private func writeCString(
  _ value: String,
  to destination: UnsafeMutablePointer<CChar>?,
  capacity: socklen_t
) {
  guard let destination, capacity > 0 else { return }
  let bytes = Array(value.utf8.prefix(Int(capacity) - 1))
  for (index, byte) in bytes.enumerated() {
    destination[index] = CChar(bitPattern: byte)
  }
  destination[bytes.count] = 0
}
