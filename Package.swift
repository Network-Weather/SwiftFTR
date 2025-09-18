// swift-tools-version: 6.2
import PackageDescription

/// Apply Swift 6.2 "Approachable Concurrency" defaults to every target.
let concurrencySettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances")
]

let package = Package(
    name: "SwiftFTR",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Primary library product
        .library(name: "SwiftFTR", targets: ["SwiftFTR"]),
        // CLI tool
        .executable(name: "swift-ftr", targets: ["swift-ftr"])
        // Note: Test and fuzzing executables are internal targets only
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.1"),
        // Enables `swift package generate-documentation`
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.4.0")
    ],
    targets: [
        .target(
            name: "SwiftFTR",
            path: "Sources/SwiftFTR",
            swiftSettings: concurrencySettings
        ),
        .executableTarget(
            name: "swift-ftr",
            dependencies: [
                "SwiftFTR",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/swift-ftr",
            swiftSettings: concurrencySettings
        ),
        .executableTarget(
            name: "icmpfuzz",
            dependencies: ["SwiftFTR"],
            swiftSettings: concurrencySettings
        ),
        .executableTarget(
            name: "icmpfuzzer",
            dependencies: ["SwiftFTR"],
            swiftSettings: [
                // On Linux, enable libFuzzer main and sanitizers. On macOS this flag is unsupported.
                .unsafeFlags(["-sanitize=fuzzer,address,undefined", "-D", "WITH_LIBFUZZER"], .when(platforms: [.linux]))
            ] + concurrencySettings
        ),
        .executableTarget(
            name: "genseeds",
            swiftSettings: concurrencySettings
        ),
        .executableTarget(
            name: "ptrtests",
            dependencies: ["SwiftFTR"],
            swiftSettings: concurrencySettings
        ),
        .executableTarget(
            name: "integrationtest",
            dependencies: ["SwiftFTR"],
            swiftSettings: concurrencySettings
        ),
        .testTarget(
            name: "SwiftFTRTests",
            dependencies: ["SwiftFTR"],
            path: "Tests/SwiftFTRTests",
            swiftSettings: concurrencySettings
        )
    ],
    // Swift 6 language mode with strict concurrency checking
    swiftLanguageModes: [.v6]
)
