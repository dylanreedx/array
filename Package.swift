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
        .library(name: "ContinuumRevivedAgentContent", targets: ["ContinuumRevivedAgentContent"]),
        .library(name: "ContinuumRevivedAgentUI", targets: ["ContinuumRevivedAgentUI"]),
        .library(name: "ContinuumRevivedCore", targets: ["ContinuumRevivedCore"]),
        .library(name: "ContinuumRevivedSync", targets: ["ContinuumRevivedSync"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        // Reviewed source: https://github.com/swiftlang/swift-markdown/tree/0.8.0
        // Apache-2.0 with Runtime Library Exception: LICENSE.txt at that tag.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0")
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "ThirdParty/GhosttyKit.xcframework"
        ),
        // Ticket P1.1: the shared agent-UI module both platforms consume —
        // presentation models and (from P1.2 on) the visual token system.
        // Foundation only, and deliberately NO dependencies: the direction is
        // Core → AgentUI, never the reverse, so visual tokens can never end up
        // coupled to storage/sync/registry logic.
        .target(
            name: "ContinuumRevivedAgentUI"
        ),
        // Ticket 91/P0.2: the platform-neutral home for the agent transcript's
        // semantic document and Markdown parser. Foundation plus the reviewed
        // swift-markdown adapter dependency only: the direction is
        // Core → AgentContent, never the reverse, and no AppKit/SwiftUI or
        // visual token may ever reach the semantic tree. Adding a dependency
        // here that names another Continuum target or GhosttyKit is caught by
        // ContinuumRevivedAgentContentChecks, which also scans the sources for
        // a forbidden `import`.
        .target(
            name: "ContinuumRevivedAgentContent",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
            ]
        ),
        .target(
            name: "ContinuumRevivedCore",
            dependencies: [
                "ContinuumRevivedAgentContent",
                "ContinuumRevivedAgentUI",
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
            dependencies: ["ContinuumRevivedAgentUI", "ContinuumRevivedCore"],
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
                "ContinuumRevivedAgentUI",
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
            dependencies: ["ContinuumRevivedAgentContent", "ContinuumRevivedAgentUI", "ContinuumRevivedCore", "ContinuumRevivedSync"]
        ),
        // Ticket P1.1: depends on AgentUI ALONE, so a token reaching back into
        // Core fails to compile here rather than being caught in review.
        .executableTarget(
            name: "ContinuumRevivedAgentUIChecks",
            dependencies: ["ContinuumRevivedAgentUI"]
        ),
        // Ticket 91/P0.2: the fast semantic-content leg. Depends on
        // AgentContent ALONE — that is the gate: if the semantic tree ever
        // reaches into Core, Sync, AgentUI or GhosttyKit, this executable stops
        // compiling instead of the coupling being caught in review.
        .executableTarget(
            name: "ContinuumRevivedAgentContentChecks",
            dependencies: ["ContinuumRevivedAgentContent"]
        ),
        .executableTarget(
            name: "ContinuumRevivedSyncChecks",
            dependencies: ["ContinuumRevivedAgentUI", "ContinuumRevivedSync", "ContinuumRevivedCore"]
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
