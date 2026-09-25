// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Pearfy",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PearfyCore", targets: ["PearfyCore"]),
        .executable(name: "HelloPearfy", targets: ["HelloPearfy"])
    ],
    targets: [
        .target(name: "PearfyCore"),
        .executableTarget(name: "HelloPearfy", dependencies: ["PearfyCore"]),
        .testTarget(name: "PearfyCoreTests", dependencies: ["PearfyCore"])
    ]
)
