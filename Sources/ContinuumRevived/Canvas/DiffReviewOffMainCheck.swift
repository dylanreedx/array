import AppKit
import ContinuumRevivedCore
import Foundation

/// `--diff-review-off-main-check`: a diff review tile must never run git on the
/// main thread. Creating one (palette, boot, every zone hydration and workspace
/// switch) used to run `git diff` once per BRANCH synchronously in `init`, which
/// froze the app for seconds on a repo with many branches.
///
/// The witness counts every git process the tile starts through a logging
/// wrapper passed as its git executable, so it watches what actually ran rather
/// than what the code meant to run.
@MainActor
enum DiffReviewOffMainCheck {
    struct CheckError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw CheckError(message: message) }
    }

    private static func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CheckError(message: "fixture git \(arguments.joined(separator: " ")) failed (\(process.terminationStatus))")
        }
    }

    static func run() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("array-diff-off-main-\(UUID().uuidString)", isDirectory: true)
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try "one\n".write(to: repo.appendingPathComponent("sample.txt"), atomically: true, encoding: .utf8)
        try git(["init", "-q"], in: repo)
        try git(["config", "user.email", "qa@example.invalid"], in: repo)
        try git(["config", "user.name", "Array QA"], in: repo)
        try git(["add", "sample.txt"], in: repo)
        try git(["commit", "-q", "-m", "baseline"], in: repo)
        try git(["branch", "-M", "main"], in: repo)
        try git(["checkout", "-q", "-b", "feature"], in: repo)
        try "one\nfeature branch\n".write(to: repo.appendingPathComponent("sample.txt"), atomically: true, encoding: .utf8)
        try git(["commit", "-q", "-am", "feature"], in: repo)
        try git(["checkout", "-q", "main"], in: repo)
        let branchCount = 40
        for index in 0..<branchCount { try git(["branch", "topic-\(index)"], in: repo) }
        try "one\ntwo\n".write(to: repo.appendingPathComponent("sample.txt"), atomically: true, encoding: .utf8)

        // Every git process the tile starts appends one line here.
        let log = root.appendingPathComponent("git-invocations.log")
        fm.createFile(atPath: log.path, contents: Data())
        let wrapper = root.appendingPathComponent("git-wrapper")
        try "#!/bin/sh\necho \"$*\" >> '\(log.path)'\nexec /usr/bin/git \"$@\"\n"
            .write(to: wrapper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        func invocations() -> [String] {
            (try? String(contentsOf: log, encoding: .utf8))?
                .split(separator: "\n").map(String.init) ?? []
        }

        let tile = Tile(
            id: UUID(), kind: .diffReview, title: "diff",
            frame: TileFrame(x: 0, y: 0, width: 720, height: 420),
            zPosition: .fromLegacyRank(1), runtimeRef: nil,
            metadata: DiffReviewSource(kind: .workingTreeVsHEAD).applying(to: TileMetadata())
        )

        // 1. Creating the tile runs NO git on the calling (main) thread.
        let view = DiffReviewTileNSView(tile: tile, repositoryURL: repo, gitExecutableURL: wrapper)
        let duringInit = invocations()
        try expect(duringInit.isEmpty,
                   "creating a diff review tile ran \(duringInit.count) git processes on the main thread: \(duringInit.prefix(6))")

        // 2. In a window it fills itself in off main: the working-tree diff, and
        //    the branch picker, in a bounded number of git processes.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        try expect(view.waitForPendingLoadsForQA(timeout: 15), "diff/branch loads did not finish")
        try expect(view.qaRenderedText.contains("+two"), "working-tree diff never rendered: \(view.qaRenderedText.prefix(160))")
        try expect(view.qaSourcePickerTitles.contains("Branch topic-7 vs main")
                   && view.qaSourcePickerTitles.contains("Branch feature vs main"),
                   "branch picker was not populated: \(view.qaSourcePickerTitles.prefix(6))")
        let afterLoad = invocations()
        try expect(afterLoad.count <= 6,
                   "\(branchCount + 2) branches cost \(afterLoad.count) git processes; the picker must not diff per branch")

        // 3. Switching source runs the diff off main, and a newer choice
        //    supersedes an older one still in flight.
        let beforeSwitch = invocations().count
        try expect(view.selectSourcePickerItemForQA(title: "Branch feature vs main"), "branch item missing")
        try expect(invocations().count == beforeSwitch, "switching source ran git on the main thread")
        try expect(view.selectSourcePickerItemForQA(title: "Working tree vs HEAD"), "working-tree item missing")
        try expect(view.waitForPendingLoadsForQA(timeout: 15), "source switch loads did not finish")
        try expect(view.qaRenderedText.contains("+two") && !view.qaRenderedText.contains("+feature branch"),
                   "a superseded diff landed after the newer choice: \(view.qaRenderedText.prefix(160))")
        try expect(view.tile.metadata.diffSource == "workingTreeVsHEAD", "selected source was not persisted to the tile")

        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("diff-review-off-main", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        let manifest: [String: Any] = [
            "check": "diff-review-off-main",
            "branches": branchCount + 2,
            "gitProcessesDuringInit": duringInit.count,
            "gitProcessesAfterLoad": afterLoad.count,
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: artifact, options: .atomic)
        return artifact
    }
}
