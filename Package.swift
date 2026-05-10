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
        .target(
            name: "ContinuumRevivedFileTree",
            dependencies: ["ContinuumRevivedCore"],
            path: "Sources/ContinuumRevived",
            exclude: [
                "App",
                "BrowserEngine",
                "TerminalEngine",
                "Canvas/BrowserRestartTileNSView.swift",
                "Canvas/BrowserTileNSView.swift",
                "Canvas/CanvasEmptyStateNSView.swift",
                "Canvas/CanvasNSView.swift",
                "Canvas/DescriptorTileNSView.swift",
                "Canvas/FileTileNSView.swift",
                "Canvas/FileTreeTileNSView.swift",
                "Canvas/NoteTileNSView.swift",
                "Canvas/TerminalRestartTileNSView.swift",
                "Canvas/TerminalTileNSView.swift",
                "Canvas/TileNSView.swift"
            ],
            sources: [
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
                "Canvas/FileTreeScanner.swift",
                "Canvas/FileTreeViewModel.swift",
                "Canvas/FileTreeOutlineModel.swift"
            ],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedLibrary("stdc++")
            ]
        ),
        // Executable checks are the regression suite for this package; do not
        // add empty test targets just to make swift test discover suite names.
        .executableTarget(
            name: "ContinuumRevivedCoreChecks",
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
        )
    ]
)
