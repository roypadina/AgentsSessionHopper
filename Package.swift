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
// In-app updates for the app only; the engine and the CLI never link it.
package.dependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"))
package.targets += [
    // The menu-bar app: control plane over the same state directory.
    .executableTarget(
        name: "AgentsSessionHopper",
        dependencies: ["SessionHopperCore", .product(name: "Sparkle", package: "Sparkle")],
        // Sparkle.framework is embedded in Contents/Frameworks (Scripts/package_app.sh).
        linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
    ),
    .testTarget(name: "ScreenshotTests", dependencies: ["AgentsSessionHopper", "SessionHopperCore"])
]
#endif
