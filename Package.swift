// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftFTR",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SwiftFTR", targets: ["SwiftFTR"]),
        .executable(name: "swift-ftr", targets: ["swift-ftr"]),
        .executable(name: "icmpfuzz", targets: ["icmpfuzz"]),
        .executable(name: "icmpfuzzer", targets: ["icmpfuzzer"]),
        .executable(name: "genseeds", targets: ["genseeds"]),
        .executable(name: "ptrtests", targets: ["ptrtests"]),
        .executable(name: "integrationtest", targets: ["integrationtest"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.1"),
        // Enables `swift package generate-documentation`
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.4.0")
    ],
    targets: [
        .target(name: "SwiftFTR", path: "Sources/SwiftFTR"),
        .executableTarget(
            name: "swift-ftr",
            dependencies: [
                "SwiftFTR",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/swift-ftr"
        ),
        .executableTarget(name: "icmpfuzz", dependencies: ["SwiftFTR"]),
        .executableTarget(
            name: "icmpfuzzer",
            dependencies: ["SwiftFTR"],
            swiftSettings: [
                // On Linux, enable libFuzzer main and sanitizers. On macOS this flag is unsupported.
                .unsafeFlags(["-sanitize=fuzzer,address,undefined", "-D", "WITH_LIBFUZZER"], .when(platforms: [.linux]))
            ]
        ),
        .executableTarget(name: "genseeds"),
        .executableTarget(name: "ptrtests", dependencies: ["SwiftFTR"]),
        .executableTarget(name: "integrationtest", dependencies: ["SwiftFTR"]),
        .testTarget(
            name: "SwiftFTRTests",
            dependencies: ["SwiftFTR"],
            path: "Tests/SwiftFTRTests"
        )
    ],
    // Support building with Swift 5 and Swift 6 toolchains.
    swiftLanguageModes: [.v5, .v6]
)
