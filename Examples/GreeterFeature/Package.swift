// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PearfyGreeterFeature",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PearfyGreeterFeature", targets: ["PearfyGreeterFeature"])
    ],
    dependencies: [
        .package(name: "Pearfy", path: "../..")
    ],
    targets: [
        .target(
            name: "PearfyGreeterFeature",
            dependencies: [
                .product(name: "PearfyDI", package: "Pearfy"),
                .product(name: "PearfyMacros", package: "Pearfy")
            ],
            plugins: [.plugin(name: "PearfyDiscoveryPlugin", package: "Pearfy")]
        )
    ]
)
