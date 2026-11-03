// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentsSessionHopper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SessionHopperCore", targets: ["SessionHopperCore"]),
        .executable(name: "sessionhopper", targets: ["sessionhopper"])
    ],
    targets: [
        // Engine: profiles, limits, hand-off policy, hooks, status-line bridge, supervisor. No UI, no network.
        .target(name: "SessionHopperCore"),
        // The CLI (`sessionhopper`). Ships inside the app bundle at Contents/Helpers/.
        .executableTarget(name: "sessionhopper", dependencies: ["SessionHopperCore"]),
        .testTarget(name: "SessionHopperCoreTests", dependencies: ["SessionHopperCore"]),
        // Drives the built CLI against a fake `claude` stub. Depends on the CLI so it is built first.
        .testTarget(name: "SessionHopperIntegrationTests", dependencies: ["SessionHopperCore", "sessionhopper"])
    ]
)

// The menu-bar app is macOS only; Linux builds the engine and the CLI.
#if os(macOS)
package.products.append(.executable(name: "AgentsSessionHopper", targets: ["AgentsSessionHopper"]))
package.targets += [
    // The menu-bar app: control plane over the same state directory.
    .executableTarget(name: "AgentsSessionHopper", dependencies: ["SessionHopperCore"]),
    .testTarget(name: "ScreenshotTests", dependencies: ["AgentsSessionHopper", "SessionHopperCore"])
]
#endif
