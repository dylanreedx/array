// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "continuum-revived",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "continuum-revived", targets: ["ContinuumRevived"]),
        .library(name: "ContinuumRevivedCore", targets: ["ContinuumRevivedCore"])
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "ThirdParty/GhosttyKit.xcframework"
        ),
        .target(name: "ContinuumRevivedCore"),
        .executableTarget(
            name: "ContinuumRevived",
            dependencies: [
                "ContinuumRevivedCore",
                "GhosttyKit"
            ],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedLibrary("stdc++")
            ]
        ),
        .executableTarget(
            name: "ContinuumRevivedCoreChecks",
            dependencies: ["ContinuumRevivedCore"]
        )
    ]
)
