// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IntegrationPackage",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        // Use the local SwiftFTR package
        .package(path: "../")
    ],
    targets: [
        .executableTarget(
            name: "IntegrationPackage",
            dependencies: ["SwiftFTR"]
        )
    ]
)