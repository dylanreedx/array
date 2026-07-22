// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "continuum-revived",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .executable(name: "continuum-revived", targets: ["ContinuumRevived"]),
        .executable(name: "ContinuumRevivedPaletteChecks", targets: ["ContinuumRevivedPaletteChecks"]),
        .library(name: "ContinuumRevivedCore", targets: ["ContinuumRevivedCore"]),
        .library(name: "ContinuumRevivedSync", targets: ["ContinuumRevivedSync"])
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
        // `linkedFramework("CloudKit")` (ticket 57): CloudKit is a system
        // framework, not a Swift package; this library target needs the
        // explicit link since it doesn't inherit the app target's link phase.
        .target(
            name: "ContinuumRevivedSync",
            dependencies: ["ContinuumRevivedCore"],
            linkerSettings: [
                .linkedFramework("CloudKit")
            ]
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
                "Canvas/TileNSView.swift",
                "Canvas/UserInputCardView.swift",
                // Ticket 57 (round-2 concern #4): see the same exclude entry
                // on the ContinuumRevived target below for why.
                "ContinuumRevived.entitlements"
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
                "ContinuumRevivedSync",
                "GhosttyKit"
            ],
            exclude: [
                "Canvas/FileTreeGitStatusProbe.swift",
                "Canvas/FileTreeScanner.swift",
                "Canvas/FileTreeViewModel.swift",
                "Canvas/FileTreeOutlineModel.swift",
                // Ticket 57 (round-2 concern #4): the packaging artifact for a
                // signed app, not a source file SwiftPM's automatic target
                // discovery understands — excluding it avoids the "found 1
                // file(s) which are unhandled" build warning.
                "ContinuumRevived.entitlements"
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
            name: "ContinuumRevivedRelayChecks",
            dependencies: ["ContinuumRevivedSync", "ContinuumRevivedCore"]
        ),
        .executableTarget(
            name: "continuum-relay",
            dependencies: ["ContinuumRevivedSync", "ContinuumRevivedCore"]
        ),
        .executableTarget(
            name: "continuum-pi-smoke",
            dependencies: ["ContinuumRevivedCore"]
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
        ),
        // Ticket 57: the real-CloudKit backend leg. Gated on CLOUDKIT_ENABLED=1
        // (absent in the overnight matrix and any unprovisioned/unsigned
        // environment); skips gracefully otherwise. See the ticket's
        // "How we test it / Backend" and "Execution mode".
        .executableTarget(
            name: "ContinuumRevivedSyncIntegrationChecks",
            dependencies: ["ContinuumRevivedSync", "ContinuumRevivedCore"]
        )
    ]
)
