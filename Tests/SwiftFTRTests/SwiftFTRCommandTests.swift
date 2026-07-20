import Testing

@testable import swift_ftr

@Suite("swift-ftr command parsing")
struct SwiftFTRCommandTests {
  @Test("Ping parses distinct interval and interface short options")
  func pingShortOptions() throws {
    let command = try SwiftFTRCommand.Ping.parse([
      "example.com", "-i", "0.25", "-I", "test-interface",
    ])

    #expect(command.target == "example.com")
    #expect(command.interval == 0.25)
    #expect(command.interface == "test-interface")
  }

  @Test("Ping preserves interval and interface long options")
  func pingLongOptions() throws {
    let command = try SwiftFTRCommand.Ping.parse([
      "example.com", "--interval", "0.5", "--interface", "test-interface-a",
    ])

    #expect(command.interval == 0.5)
    #expect(command.interface == "test-interface-a")
  }

  @Test("Ping help documents both distinct short options")
  func pingHelp() {
    let help = SwiftFTRCommand.Ping.helpMessage()

    #expect(help.contains("-i, --interval <interval>"))
    #expect(help.contains("-I, --interface <interface>"))
  }
}
