// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ParallelTraceroute",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "ParallelTraceroute", targets: ["ParallelTraceroute"]),
        .executable(name: "ptroute", targets: ["ptroute"]),
        .executable(name: "icmpfuzz", targets: ["icmpfuzz"]),
        .executable(name: "icmpfuzzer", targets: ["icmpfuzzer"]),
        .executable(name: "genseeds", targets: ["genseeds"]),
        .executable(name: "ptrtests", targets: ["ptrtests"]) 
    ],
    targets: [
        .target(name: "ParallelTraceroute"),
        .executableTarget(name: "ptroute", dependencies: ["ParallelTraceroute"]),
        .executableTarget(name: "icmpfuzz", dependencies: ["ParallelTraceroute"]),
        .executableTarget(
            name: "icmpfuzzer",
            dependencies: ["ParallelTraceroute"],
            swiftSettings: [
                // On Linux, enable libFuzzer main and sanitizers. On macOS this flag is unsupported.
                .unsafeFlags(["-sanitize=fuzzer,address,undefined", "-D", "WITH_LIBFUZZER"], .when(platforms: [.linux]))
            ]
        ),
        .executableTarget(name: "genseeds"),
        .executableTarget(name: "ptrtests", dependencies: ["ParallelTraceroute"])
    ]
)
