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
        .executable(name: "ptrtests", targets: ["ptrtests"]) 
    ],
    targets: [
        .target(name: "SwiftFTR", path: "Sources/SwiftFTR"),
        .executableTarget(name: "swift-ftr", dependencies: ["SwiftFTR"], path: "Sources/swift-ftr"),
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
        .executableTarget(name: "ptrtests", dependencies: ["SwiftFTR"])
    ]
)
