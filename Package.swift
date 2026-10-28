// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Bosun",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Bosun", targets: ["Bosun"]),
        .library(name: "BosunCore", targets: ["BosunCore"]),
        .library(name: "BosunTerminal", targets: ["BosunTerminal"]),
    ],
    targets: [
        .target(name: "BosunCore"),
        // libghostty (Ghostty 1.3.1) as built by Calyx; fetched into the
        // gitignored Vendor/ by `make vendor` (scripts/fetch-ghosttykit.sh).
        .binaryTarget(name: "GhosttyKit", path: "Vendor/GhosttyKit.xcframework"),
        .target(
            name: "BosunTerminal",
            dependencies: ["GhosttyKit"],
            exclude: ["Vendored/CALYX-LICENSE"],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreText"),
                .linkedFramework("Carbon"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
            ]
        ),
        .executableTarget(name: "Bosun", dependencies: ["BosunCore", "BosunTerminal"]),
        .testTarget(name: "BosunCoreTests", dependencies: ["BosunCore"]),
        .testTarget(name: "BosunTests", dependencies: ["Bosun", "BosunCore"]),
    ]
)
