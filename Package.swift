// swift-tools-version: 6.2
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "Pearfy",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PearfyCore", targets: ["PearfyCore"]),
        .library(name: "PearfyDI", targets: ["PearfyDI"]),
        .library(name: "PearfyConfiguration", targets: ["PearfyConfiguration"]),
        .library(name: "PearfyContext", targets: ["PearfyContext"]),
        .library(name: "PearfyWeb", targets: ["PearfyWeb"]),
        .library(name: "PearfyConnect", targets: ["PearfyConnect"]),
        .library(name: "PearfyNIO", targets: ["PearfyNIO"]),
        .library(name: "PearfyValidation", targets: ["PearfyValidation"]),
        .library(name: "PearfySecurity", targets: ["PearfySecurity"]),
        .library(name: "PearfyData", targets: ["PearfyData"]),
        .library(name: "PearfyPopulateCore", targets: ["PearfyPopulateCore"]),
        .library(name: "PearfyPopulatePostgres", targets: ["PearfyPopulatePostgres"]),
        .library(name: "PearfyTransactions", targets: ["PearfyTransactions"]),
        .library(name: "PearfyPostgres", targets: ["PearfyPostgres"]),
        .library(name: "PearfyRedis", targets: ["PearfyRedis"]),
        .library(name: "PearfySocial", targets: ["PearfySocial"]),
        .library(name: "PearfySocialPostgres", targets: ["PearfySocialPostgres"]),
        .library(name: "PearfyCache", targets: ["PearfyCache"]),
        .library(name: "PearfyMessaging", targets: ["PearfyMessaging"]),
        .library(name: "PearfyJobs", targets: ["PearfyJobs"]),
        .library(name: "PearfyCloud", targets: ["PearfyCloud"]),
        .library(name: "PearfyAI", targets: ["PearfyAI"]),
        .library(name: "PearfyObservability", targets: ["PearfyObservability"]),
        .library(name: "PearfyDevKitUI", targets: ["PearfyDevKitUI"]),
        .library(name: "PearfyGatewayLab", targets: ["PearfyGatewayLab"]),
        .library(name: "PearfyTesting", targets: ["PearfyTesting"]),
        .library(name: "PearfyMacros", targets: ["PearfyMacros"]),
        .plugin(name: "PearfyDiscoveryPlugin", targets: ["PearfyDiscoveryPlugin"]),
        .executable(name: "pearfy-bench", targets: ["PearfyBenchmarks"]),
        .executable(name: "pearfy", targets: ["PearfyCLI"]),
        .executable(name: "HelloPearfy", targets: ["HelloPearfy"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/swift-server/RediStack.git", from: "1.6.2"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.3")
    ],
    targets: [
        .target(name: "PearfyCore"),
        .target(name: "PearfyDI", dependencies: ["PearfyCore"]),
        .target(name: "PearfyConfiguration", dependencies: ["PearfyCore"]),
        .target(name: "PearfyContext", dependencies: ["PearfyCore", "PearfyDI", "PearfyConfiguration"]),
        .target(name: "PearfyWeb"),
        .target(
            name: "PearfyConnect",
            dependencies: [
                "PearfyWeb",
                .product(name: "Crypto", package: "swift-crypto")
            ]
        ),
        .target(name: "PearfyValidation", dependencies: ["PearfyCore"]),
        .target(
            name: "PearfySecurity",
            dependencies: ["PearfyWeb", .product(name: "Crypto", package: "swift-crypto")]
        ),
        .target(
            name: "PearfyData",
            dependencies: [
                "PearfyCore",
                .product(name: "Crypto", package: "swift-crypto")
            ]
        ),
        .target(name: "PearfyPopulateCore", dependencies: ["PearfyData"]),
        .target(
            name: "PearfyPopulatePostgres",
            dependencies: [
                "PearfyData",
                "PearfyPostgres",
                "PearfyPopulateCore",
                .product(name: "Crypto", package: "swift-crypto")
            ]
        ),
        .target(
            name: "PearfyPopulateCLI",
            dependencies: [
                "PearfyPopulateCore",
                "PearfyPopulatePostgres",
                "PearfyPostgres",
                .product(name: "Crypto", package: "swift-crypto")
            ]
        ),
        .target(name: "PearfyTransactions"),
        .target(
            name: "PearfyPostgres",
            dependencies: [
                "PearfyContext",
                "PearfyData",
                "PearfyTransactions",
                "PearfyObservability",
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .target(name: "PearfyCache", dependencies: ["PearfyObservability"]),
        .target(name: "PearfyMessaging", dependencies: ["PearfyCore"]),
        .target(name: "PearfySocial", dependencies: ["PearfyData"]),
        .target(
            name: "PearfySocialPostgres",
            dependencies: [
                "PearfySocial",
                "PearfyData",
                "PearfyPostgres",
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Crypto", package: "swift-crypto")
            ]
        ),
        .target(name: "PearfyJobs", dependencies: ["PearfyContext"]),
        .target(name: "PearfyCloud", dependencies: ["PearfyObservability"]),
        .target(name: "PearfyAI", dependencies: ["PearfyCloud"]),
        .target(
            name: "PearfyObservability",
            dependencies: ["PearfyWeb", .product(name: "Crypto", package: "swift-crypto")]
        ),
        .target(
            name: "PearfyDevKitUI",
            dependencies: ["PearfyWeb", "PearfyObservability"],
            resources: [.process("Resources")]
        ),
        .target(name: "PearfyGatewayLab"),
        .target(
            name: "PearfyRedis",
            dependencies: [
                "PearfyCache",
                "PearfyMessaging",
                "PearfyContext",
                .product(name: "RediStack", package: "RediStack"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio")
            ]
        ),
        .target(
            name: "PearfyNIO",
            dependencies: [
                "PearfyContext",
                "PearfyWeb",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio")
            ]
        ),
        .target(name: "PearfyTesting", dependencies: ["PearfyDI"]),
        .target(
            name: "PearfyMacros",
            dependencies: ["PearfyDI", "PearfyWeb", "PearfyValidation", "PearfyData", "PearfyMacrosImpl"]
        ),
        .macro(
            name: "PearfyMacrosImpl",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax")
            ]
        ),
        .executableTarget(
            name: "PearfyDiscoveryGenerator",
            dependencies: [
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax")
            ]
        ),
        .plugin(
            name: "PearfyDiscoveryPlugin",
            capability: .buildTool(),
            dependencies: ["PearfyDiscoveryGenerator"]
        ),
        .executableTarget(
            name: "PearfyBenchmarks",
            dependencies: [
                "PearfyDI",
                "PearfyNIO",
                "PearfyValidation",
                "PearfyWeb",
                "PearfyObservability",
                "PearfyCache",
                "PearfyMessaging",
                "PearfyJobs",
                "PearfyCloud",
                "PearfyContext",
                "PearfyConfiguration",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio")
            ]
        ),
        .target(
            name: "PearfyCLIKit",
            dependencies: [
                "PearfyPopulateCLI",
                "PearfyDevKitUI",
                "PearfyGatewayLab",
                "PearfyData",
                "PearfyPostgres",
                .product(name: "Crypto", package: "swift-crypto")
            ],
            resources: [.process("module-registry.json")]
        ),
        .executableTarget(name: "PearfyCLI", dependencies: ["PearfyCLIKit", "PearfyPopulateCLI"]),
        .executableTarget(
            name: "HelloPearfy",
            dependencies: ["PearfyDI", "PearfyContext", "PearfyConfiguration", "PearfyMacros"],
            plugins: [.plugin(name: "PearfyDiscoveryPlugin")]
        ),
        .testTarget(
            name: "PearfyCoreTests",
            dependencies: [
                "PearfyCore",
                "PearfyDI",
                "PearfyConfiguration",
                "PearfyContext",
                "PearfyWeb",
                "PearfyConnect",
                "PearfyNIO",
                "PearfyValidation",
                "PearfySecurity",
                "PearfyData",
                "PearfyPopulateCore",
                "PearfyPopulatePostgres",
                "PearfyPopulateCLI",
                "PearfyTransactions",
                "PearfyPostgres",
                "PearfySocial",
                "PearfySocialPostgres",
                .product(name: "PostgresNIO", package: "postgres-nio"),
                "PearfyRedis",
                "PearfyCache",
                "PearfyMessaging",
                "PearfyJobs",
                "PearfyCloud",
                "PearfyAI",
                "PearfyObservability",
                "PearfyDevKitUI",
                "PearfyGatewayLab",
                "PearfyTesting",
                "PearfyMacros",
                "PearfyCLIKit"
            ],
            plugins: [.plugin(name: "PearfyDiscoveryPlugin")]
        )
    ]
)
