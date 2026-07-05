// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "continuum-revived",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "continuum-revived", targets: ["ContinuumRevived"]),
        .executable(name: "ContinuumRevivedPaletteChecks", targets: ["ContinuumRevivedPaletteChecks"]),
        .library(name: "ContinuumRevivedCore", targets: ["ContinuumRevivedCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1")
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "ThirdParty/GhosttyKit.xcframework"
        ),
        .target(
            name: "ContinuumRevivedCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        // Sync layer (ticket 06's home; stood up by ticket 05 with the
        // tombstone vocabulary). Pure Swift, depends only on Core.
        .target(
            name: "ContinuumRevivedSync",
            dependencies: ["ContinuumRevivedCore"]
        ),
        .target(
            name: "ContinuumRevivedFileTree",
            dependencies: ["ContinuumRevivedCore"],
            path: "Sources/ContinuumRevived",
            exclude: [
                "App",
                "BrowserEngine",
                "TerminalEngine",
                "Canvas/BrowserInspectorTileNSView.swift",
                "Canvas/BrowserRestartTileNSView.swift",
                "Canvas/BrowserSnapshotTileNSView.swift",
                "Canvas/BrowserTileNSView.swift",
                "Canvas/ConductorQueueTileNSView.swift",
                "Canvas/CanvasNSView.swift",
                "Canvas/DescriptorTileNSView.swift",
                "Canvas/DiffReviewTileNSView.swift",
                "Canvas/FileTileNSView.swift",
                "Canvas/FileTreeTileNSView.swift",
                "Canvas/NoteTileNSView.swift",
                "Canvas/RunArtifactsTileNSView.swift",
                "Canvas/TerminalRestartTileNSView.swift",
                "Canvas/TerminalTileNSView.swift",
                "Canvas/TicketQueueTileNSView.swift",
                "Canvas/TileNSView.swift"
            ],
            sources: [
                "Canvas/FileTreeGitStatusProbe.swift",
                "Canvas/FileTreeScanner.swift",
                "Canvas/FileTreeViewModel.swift",
                "Canvas/FileTreeOutlineModel.swift"
            ]
        ),
        .executableTarget(
            name: "ContinuumRevived",
            dependencies: [
                "ContinuumRevivedFileTree",
                "ContinuumRevivedCore",
                "GhosttyKit"
            ],
            exclude: [
                "Canvas/FileTreeGitStatusProbe.swift",
                "Canvas/FileTreeScanner.swift",
                "Canvas/FileTreeViewModel.swift",
                "Canvas/FileTreeOutlineModel.swift"
            ],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedLibrary("stdc++")
            ]
        ),
        .executableTarget(
            name: "ContinuumRevivedCoreChecks",
            // Ticket 07 (convergence fuzz) drives materialize/compact/applySnapshot
            // from the op-log core, which lives in ContinuumRevivedSync.
            dependencies: ["ContinuumRevivedCore", "ContinuumRevivedSync"]
        ),
        .executableTarget(
            name: "ContinuumRevivedSyncChecks",
            dependencies: ["ContinuumRevivedSync", "ContinuumRevivedCore"]
        ),
        .executableTarget(
            name: "ContinuumRevivedPaletteChecks",
            dependencies: ["ContinuumRevivedCore"]
        ),
        .executableTarget(
            name: "ContinuumRevivedPerfChecks",
            dependencies: ["ContinuumRevivedCore"]
        ),
        .executableTarget(
            name: "ContinuumRevivedFileTreeChecks",
            dependencies: [
                "ContinuumRevivedFileTree",
                "ContinuumRevivedCore"
            ]
        )
    ]
)
