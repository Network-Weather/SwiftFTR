// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftFTR",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Primary library product
        .library(name: "SwiftFTR", targets: ["SwiftFTR"]),
        // CLI tools
        .executable(name: "swift-ftr", targets: ["swift-ftr"]),
        .executable(name: "hop-monitor", targets: ["hop-monitor"])
        // Note: Test and fuzzing executables are internal targets only
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.1"),
        // Enables `swift package generate-documentation`
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.4.0"),
        // Local ASN database for offline IP-to-ASN lookups
        .package(url: "https://github.com/network-weather/swift-ip2asn", from: "0.2.1")
    ],
    targets: [
        .target(
            name: "SwiftFTR",
            dependencies: [
                .product(name: "SwiftIP2ASN", package: "swift-ip2asn")
            ],
            path: "Sources/SwiftFTR"
        ),
        .executableTarget(
            name: "swift-ftr",
            dependencies: [
                "SwiftFTR",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/swift-ftr"
        ),
        .executableTarget(
            name: "hop-monitor",
            dependencies: [
                "SwiftFTR",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/hop-monitor",
            exclude: ["README.md"]
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
        ),
        .executableTarget(
            name: "ResourceBenchmark",
            dependencies: ["SwiftFTR"],
            path: "Tests/TestSupport"
        )
    ],
    // Swift 6 language mode with strict concurrency checking
    swiftLanguageModes: [.v6]
)
