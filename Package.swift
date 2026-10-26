// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Bosun",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Bosun", targets: ["Bosun"]),
        .library(name: "BosunCore", targets: ["BosunCore"]),
    ],
    targets: [
        .target(name: "BosunCore"),
        .executableTarget(name: "Bosun", dependencies: ["BosunCore"]),
    ]
)
