// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "array-relay-linux",
    products: [.executable(name: "continuum-relay", targets: ["continuum-relay"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.0"),
    ],
    targets: [
        .target(name: "ContinuumRevivedRelayProtocol", path: "Sources/ContinuumRevivedRelayProtocol"),
        .target(
            name: "ContinuumRevivedRelayCore",
            dependencies: [
                "ContinuumRevivedRelayProtocol",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/ContinuumRevivedRelayCore"
        ),
        .target(
            name: "ContinuumRevivedRelayNIO",
            dependencies: [
                "ContinuumRevivedRelayProtocol", "ContinuumRevivedRelayCore",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
            ],
            path: "Sources/ContinuumRevivedRelayNIO"
        ),
        .executableTarget(
            name: "continuum-relay",
            dependencies: ["ContinuumRevivedRelayCore", "ContinuumRevivedRelayNIO"],
            path: "Sources/continuum-relay"
        ),
    ]
)
