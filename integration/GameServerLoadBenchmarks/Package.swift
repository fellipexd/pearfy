// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PearfyGameServerLoadBenchmarks",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .executableTarget(
            name: "pearfy-gameserver-loadbench-server",
            dependencies: [
                .product(name: "PearfyGameServer", package: "pearfy"),
                .product(name: "PearfyGameServerTransport", package: "pearfy"),
                .product(name: "Crypto", package: "swift-crypto")
            ]
        ),
        .executableTarget(
            name: "pearfy-gameserver-fps-bench-server",
            dependencies: [
                .product(name: "PearfyGameServer", package: "pearfy"),
                .product(name: "PearfyGameServerRealtime", package: "pearfy"),
                .product(name: "PearfyGameServerTransport", package: "pearfy"),
                .product(name: "Crypto", package: "swift-crypto")
            ]
        )
    ]
)
