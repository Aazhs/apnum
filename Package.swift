// swift-tools-version: 6.2
import PackageDescription

// Each feature is its own target that depends only on ApnumCore.
// The app target is the composition root that wires them together.
let features = ["ApnumAlarms", "ApnumTimers", "ApnumNotes", "ApnumCalendar", "ApnumSystem", "ApnumSky", "ApnumUpdate"]

let package = Package(
    name: "apnum",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Apnum", targets: ["ApnumApp"]),
        .library(name: "ApnumCore", targets: ["ApnumCore"]),
    ],
    targets: [
        .target(name: "ApnumCore"),
        .executableTarget(
            name: "ApnumApp",
            dependencies: ["ApnumCore", "ApnumLink"] + features.map { .target(name: $0) }
        ),
        .target(name: "ApnumLink", dependencies: ["ApnumCore", "ApnumLinkCore"]),
        .testTarget(name: "ApnumLinkTests", dependencies: ["ApnumLink", "ApnumLinkCore", "ApnumCore"]),
        .testTarget(name: "ApnumCoreTests", dependencies: ["ApnumCore"]),
        // Shared Rust link core. Run scripts/build-rust.sh mac once to create the xcframework.
        .binaryTarget(name: "ApnumLinkFFI", path: "build/rust/ApnumLinkFFI.xcframework"),
        .target(
            name: "ApnumLinkCore",
            dependencies: ["ApnumLinkFFI"],
            swiftSettings: [.swiftLanguageMode(.v5)]  // UniFFI-generated code is not Swift 6 clean
        ),
        .testTarget(name: "ApnumLinkCoreTests", dependencies: ["ApnumLinkCore"]),
    ]
    + features.map { name in
        name == "ApnumSky"
            ? .target(name: name, dependencies: ["ApnumCore"], resources: [.process("Resources")])
            : .target(name: name, dependencies: ["ApnumCore"])
    }
    + features.map { .testTarget(name: "\($0)Tests", dependencies: [.target(name: $0), "ApnumCore"]) }
)
