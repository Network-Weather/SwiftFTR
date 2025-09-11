// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TestLibraryUsage",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../")
    ],
    targets: [
        .executableTarget(
            name: "TestLibraryUsage",
            dependencies: ["SwiftFTR"]
        )
    ]
)
