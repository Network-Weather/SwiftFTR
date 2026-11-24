import SwiftFTR
import Testing

@testable import swift_ftr

@Suite("swift-ftr command parsing")
struct SwiftFTRCommandTests {
  @Test("Root command reports the library version")
  func rootVersion() {
    #expect(SwiftFTRCommand.configuration.version == swiftFTRVersion)
  }

  @Test("--public-ip disables discovery for trace and multipath, whatever the address")
  func publicIPDisablesDiscovery() throws {
    func disabled(_ config: SwiftFTRConfig) -> Bool {
      if case .disabled = config.publicIPResolver { return true }
      return false
    }
    // Public, refused and other-family addresses all mean "do not discover"; no flag keeps it.
    for address in ["9.9.9.9", "203.0.113.7", "2606:4700::1111"] {
      let trace = try SwiftFTRCommand.Trace.parse(["--public-ip", address, "example.com"])
      #expect(disabled(trace.config), "trace --public-ip \(address)")
      #expect(trace.config.publicIP == address)
      let multipath = try SwiftFTRCommand.Multipath.parse(["--public-ip", address, "example.com"])
      #expect(disabled(multipath.config), "multipath --public-ip \(address)")
    }
    let plainTrace = try SwiftFTRCommand.Trace.parse(["example.com"]).config
    let plainMultipath = try SwiftFTRCommand.Multipath.parse(["example.com"]).config
    #expect(!disabled(plainTrace))
    #expect(!disabled(plainMultipath))
  }

  @Test("Ping parses distinct interval and interface short options")
  func pingShortOptions() throws {
    let command = try SwiftFTRCommand.Ping.parse([
      "example.com", "-i", "0.25", "-I", "synthetic-interface",
    ])

    #expect(command.target == "example.com")
    #expect(command.interval == 0.25)
    #expect(command.interface == "synthetic-interface")
  }

  @Test("Ping preserves interval and interface long options")
  func pingLongOptions() throws {
    let command = try SwiftFTRCommand.Ping.parse([
      "example.com", "--interval", "0.5", "--interface", "alternate-interface",
    ])

    #expect(command.interval == 0.5)
    #expect(command.interface == "alternate-interface")
  }

  @Test("Ping help documents both distinct short options")
  func pingHelp() {
    let help = SwiftFTRCommand.Ping.helpMessage()

    #expect(help.contains("-i, --interval <interval>"))
    #expect(help.contains("-I, --interface <interface>"))
  }
}
