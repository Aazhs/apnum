// swift-tools-version: 6.0
import PackageDescription

// Each feature is its own target that depends only on ApnumCore.
// The app target is the composition root that wires them together.
let features = ["ApnumAlarms", "ApnumTimers", "ApnumNotes", "ApnumCalendar", "ApnumSystem"]

let package = Package(
    name: "apnum",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Apnum", targets: ["ApnumApp"]),
        .library(name: "ApnumCore", targets: ["ApnumCore"]),
    ],
    targets: [
        .target(name: "ApnumCore"),
        .executableTarget(
            name: "ApnumApp",
            dependencies: ["ApnumCore"] + features.map { .target(name: $0) }
        ),
        .testTarget(name: "ApnumCoreTests", dependencies: ["ApnumCore"]),
    ]
    + features.map { .target(name: $0, dependencies: ["ApnumCore"]) }
    + features.map { .testTarget(name: "\($0)Tests", dependencies: [.target(name: $0), "ApnumCore"]) }
)
