import AppKit
import Foundation
import ContinuumRevivedCore
import ContinuumRevivedFileTree

/// WS3 permanent structural invariant #3: **a file-tree scan must apply a
/// BOUNDED number of main-actor snapshots and full outline reloads, however many
/// the scanner produces.**
///
/// `FileTreeScanner` emits a growing FULL snapshot every 512 processed nodes.
/// The view model used to hop each one onto the main actor in its own task, and
/// every accepted snapshot rebuilt `FileTreeOutlineModel`, called
/// `NSOutlineView.reloadData` and re-ran the collapse/expansion/selection
/// restore. At the scanner's 50k node cap that is ~97 unbounded main-actor tasks
/// carrying ~2.4M node copies between them, 96 of whose reloads draw a tree that
/// is already superseded. The work is quadratic in the snapshot count and none of
/// it is visible to the user.
///
/// The fix is a latest-wins mailbox. This leg proves the bound and, just as
/// importantly, that coalescing did not cost correctness: the FINAL snapshot is
/// always the one on screen.
///
/// Owned by the **Array** binary (`--file-tree-snapshot-coalescing-check`).
enum FileTreeSnapshotCoalescingChecks {
    struct CheckError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckError(message: message) }
    }

    /// The declared ceiling. A burst offered without yielding the main actor can
    /// only ever drain once; two is slack for a drain that lands mid-burst.
    private static let maxAppliesPerBurst = 2
    private static let burstSize = 200

    @MainActor
    static func run() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/ws3-file-tree-coalescing", isDirectory: true)

        // ── Case 1: a burst through the production mailbox ──────────────────
        //
        // 200 growing snapshots offered without yielding the main actor, which is
        // exactly what a detached scanner thread does to a busy main thread.
        let viewModel = FileTreeViewModel()
        let tileId = UUID(uuidString: "00000000-0000-0000-0000-0000F17E7EE0")!
        let tile = Tile(id: tileId, kind: .fileTree, title: "FILE_TREE_COALESCING",
                        frame: TileFrame(x: 0, y: 0, width: 420, height: 520),
                        zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        let fileTreeTile = FileTreeTile(
            tileId: tileId, rootPath: root.path, expandedPaths: [], selectedPath: nil,
            searchQuery: "", ignoredNames: [], gitBadges: .off
        )
        let view = FileTreeTileNSView(tile: tile, fileTreeTile: fileTreeTile, viewModel: viewModel)
        view.frame = CGRect(x: 0, y: 0, width: 420, height: 520)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontOffscreenForChecks()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        let reloadsBeforeBurst = view.qaOutlineReloadCount
        for count in 1...burstSize {
            viewModel.qaOfferSnapshot(FileTreeSnapshot(
                root: root,
                nodes: (0..<count).map {
                    FileTreeNode(relativePath: "f\($0).txt", displayName: "f\($0).txt",
                                 isDirectory: false, childCount: 0, isIgnored: false, gitStatus: nil)
                },
                isTruncated: false,
                nodeLimit: 50_000
            ))
        }
        // Let every scheduled drain run.
        try drainMainActor()

        let offered = viewModel.qaSnapshotsOffered
        let applied = viewModel.qaSnapshotsApplied
        let reloads = view.qaOutlineReloadCount - reloadsBeforeBurst

        // ANTI-TEETH: the burst must actually have happened. A mailbox that
        // dropped everything scores a perfect bound.
        try expect(offered == burstSize,
                   "the burst must offer \(burstSize) snapshots through the production mailbox; the inbox counted \(offered)")
        try expect(applied >= 1, "no snapshot reached the main actor at all")
        try expect(reloads >= 1, "the outline was never reloaded, so the bound below proves nothing")

        // THE TEETH.
        try expect(applied <= maxAppliesPerBurst,
                   "\(offered) scanner snapshots produced \(applied) main-actor applies; the declared bound is \(maxAppliesPerBurst) — snapshots are not being coalesced")
        try expect(reloads <= maxAppliesPerBurst,
                   "\(offered) scanner snapshots produced \(reloads) full outline reloads; the declared bound is \(maxAppliesPerBurst)")
        // The two bounds above are satisfied by the pending slot ALONE: a later
        // offer overwrites an unread snapshot, so most drains find nothing even
        // with the one-drain-at-a-time flag deleted. This is the only assertion
        // that witnesses that flag, and the flag is what keeps the scan from
        // queueing one unbounded main-actor task per snapshot.
        let scheduled = viewModel.qaDrainsScheduled
        try expect(scheduled >= 1, "no drain was ever scheduled, so the bound below proves nothing")
        try expect(scheduled <= maxAppliesPerBurst,
                   "\(offered) scanner snapshots scheduled \(scheduled) main-actor drain tasks; the "
                   + "declared bound is \(maxAppliesPerBurst) — the mailbox is queueing one task per "
                   + "snapshot, each retaining a full copy of the tree")

        // ANTI-TEETH: correctness. Coalescing must drop only SUPERSEDED
        // snapshots, so the newest one is what the user is looking at.
        try expect(viewModel.latestSnapshot?.nodes.count == burstSize,
                   "the last snapshot offered had \(burstSize) nodes; the tree is showing \(viewModel.latestSnapshot?.nodes.count.description ?? "none")")

        // ── Case 2: the same mailbox on the REAL scanner, over a real tree ───
        //
        // Case 1 proves the bound under a burst; this proves the production
        // scan path is wired to the same mailbox and still ends on the truth.
        let fixtureRoot = try makeFixtureTree(fileCount: 2_000)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let scanModel = FileTreeViewModel(scanner: FileTreeScanner(batchSize: 64),
                                          gitStatusProvider: { _ in [:] })
        var scanApplies = 0
        scanModel.onSnapshotChange = { _ in scanApplies += 1 }
        scanModel.start(rootPath: fixtureRoot.path, ignoreList: [], gitBadgeMode: .off)
        var spins = 0
        while (scanModel.latestSnapshot?.nodes.count ?? 0) < 2_000 && spins < 6_000 {
            try drainMainActor()
            spins += 1
        }
        let scanOffered = scanModel.qaSnapshotsOffered
        try expect(scanOffered >= 10,
                   "the real scan must produce many partial snapshots for the bound to mean anything; it produced \(scanOffered)")
        try expect(scanApplies <= scanOffered,
                   "impossible: \(scanApplies) applies from \(scanOffered) offers")
        try expect(scanModel.latestSnapshot?.nodes.count == 2_000,
                   "the real scan must end on the complete tree; it ended on \(scanModel.latestSnapshot?.nodes.count.description ?? "nothing") of 2000 nodes")
        scanModel.cancel()

        let manifest: [String: Any] = [
            "check": "file-tree-snapshot-coalescing",
            "burst": [
                "offered": offered,
                "applied": applied,
                "outlineReloads": reloads,
                "declaredMaxApplies": maxAppliesPerBurst,
                "finalNodeCount": viewModel.latestSnapshot?.nodes.count ?? -1
            ],
            "realScan": [
                "fileCount": 2_000,
                "batchSize": 64,
                "offered": scanOffered,
                "applied": scanApplies,
                "finalNodeCount": scanModel.latestSnapshot?.nodes.count ?? -1
            ]
        ]
        let fm = FileManager.default
        let directory = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent("file-tree-snapshot-coalescing-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: artifact, options: .atomic)
        return artifact
    }

    /// Run the main run loop long enough for every queued main-actor task to
    /// land, without a wall-clock sleep the machine's load can invalidate.
    @MainActor
    private static func drainMainActor() throws {
        for _ in 0..<8 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.002))
        }
    }

    private static func makeFixtureTree(fileCount: Int) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("ws3-file-tree-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // 20 directories x 99 files = 1980, plus the 20 directories = 2000 nodes.
        for directoryIndex in 0..<20 {
            let directory = root.appendingPathComponent("d\(directoryIndex)", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            for fileIndex in 0..<((fileCount / 20) - 1) {
                try Data().write(to: directory.appendingPathComponent("f\(fileIndex).txt"))
            }
        }
        return root
    }
}
