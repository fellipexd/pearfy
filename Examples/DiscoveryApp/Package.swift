// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PearfyDiscoveryApp",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(name: "Pearfy", path: "../.."),
        .package(name: "PearfyGreeterFeature", path: "../GreeterFeature")
    ],
    targets: [
        .executableTarget(
            name: "PearfyDiscoveryApp",
            dependencies: [
                .product(name: "PearfyDI", package: "Pearfy"),
                .product(name: "PearfyConfiguration", package: "Pearfy"),
                .product(name: "PearfyContext", package: "Pearfy"),
                .product(name: "PearfyGreeterFeature", package: "PearfyGreeterFeature")
            ]
        )
    ]
)
