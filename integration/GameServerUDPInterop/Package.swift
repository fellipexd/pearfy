// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PearfyGameServerUDPInterop",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.3.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0")
    ],
    targets: [
        .target(
            name: "PearfyNetwork",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            path: "Sources/PearfyNetwork"
        ),
        .testTarget(
            name: "GameServerUDPInteropTests",
            dependencies: [
                .product(name: "PearfyGameServer", package: "pearfy"),
                .product(name: "PearfyGameServerGRPC", package: "pearfy"),
                .product(name: "PearfyGameServerTransport", package: "pearfy"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
                "PearfyNetwork"
            ]
        )
    ]
)
