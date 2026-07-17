import Testing

@testable import swift_ftr

@Suite("CLI reverse-DNS policy")
struct CLIReverseDNSTests {
  actor LookupRecorder {
    private(set) var addresses: [String] = []

    func lookup(_ address: String) -> String? {
      addresses.append(address)
      return "hostname-for-\(address)"
    }
  }

  struct AddressFamilyCase: Sendable, CustomTestStringConvertible {
    let name: String
    let addresses: [String]

    var testDescription: String { name }
  }

  static let addressFamilies = [
    AddressFamilyCase(
      name: "IPv4",
      addresses: ["192.0.2.1", "198.51.100.2", "203.0.113.3"]
    ),
    AddressFamilyCase(
      name: "IPv6",
      addresses: ["2001:db8::1", "2001:db8:1::2", "2001:db8:2::3"]
    ),
  ]

  @Test("--no-rdns skips target, hop, and public-address lookups", arguments: addressFamilies)
  func noReverseDNSSkipsEveryLookup(addressFamily: AddressFamilyCase) async {
    let recorder = LookupRecorder()

    let hostnames = await resolveCLIHostnames(
      for: addressFamily.addresses,
      skipReverseDNS: true,
      lookup: { address in await recorder.lookup(address) }
    )

    #expect(hostnames.isEmpty)
    #expect(await recorder.addresses.isEmpty)
  }

  @Test("JSON's default policy resolves IPv4 and IPv6 addresses", arguments: addressFamilies)
  func defaultPolicyResolvesEveryUniqueAddress(addressFamily: AddressFamilyCase) async {
    let recorder = LookupRecorder()
    let addresses = addressFamily.addresses + [addressFamily.addresses[1]]

    let hostnames = await resolveCLIHostnames(
      for: addresses,
      skipReverseDNS: false,
      lookup: { address in await recorder.lookup(address) }
    )

    #expect(Set(await recorder.addresses) == Set(addressFamily.addresses))
    #expect(hostnames.count == addressFamily.addresses.count)
    for address in addressFamily.addresses {
      #expect(hostnames[address] == "hostname-for-\(address)")
    }
  }
}
