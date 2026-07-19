import Testing

@testable import swift_ftr

@Suite("swift-ftr interfaces command parsing")
struct SwiftFTRInterfacesCommandTests {
  @Test("Interfaces excludes inactive interfaces by default")
  func defaultExcludesInactiveInterfaces() throws {
    let command = try SwiftFTRCommand.Interfaces.parse([])

    #expect(command.includeInactive == false)
  }

  @Test("Interfaces accepts an explicit include-inactive flag")
  func includeInactiveFlag() throws {
    let command = try SwiftFTRCommand.Interfaces.parse(["--include-inactive"])

    #expect(command.includeInactive)
  }

  @Test("Interfaces help documents the include-inactive behavior")
  func helpDocumentsIncludeInactiveBehavior() {
    let help = SwiftFTRCommand.Interfaces.helpMessage()

    #expect(help.contains("--include-inactive"))
    #expect(help.contains("Include inactive (down) interfaces"))
  }
}
