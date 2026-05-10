import ContinuumRevivedFileTree
import ContinuumRevivedCore
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        Foundation.exit(1)
    }
}

func makeDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

func makeFile(_ url: URL, contents: String = "") throws {
    try contents.data(using: .utf8)?.write(to: url)
}

let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("continuum-file-tree-checks-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: scratch) }

try makeDirectory(scratch)
try makeDirectory(scratch.appendingPathComponent("Sources", isDirectory: true))
try makeFile(scratch.appendingPathComponent("Sources/App.swift"))
try makeDirectory(scratch.appendingPathComponent(".git", isDirectory: true))
try makeFile(scratch.appendingPathComponent(".git/config"))
try makeDirectory(scratch.appendingPathComponent("linked-dir-target", isDirectory: true))
try makeFile(scratch.appendingPathComponent("linked-dir-target/inside.txt"))
try FileManager.default.createSymbolicLink(
    at: scratch.appendingPathComponent("linked-dir", isDirectory: false),
    withDestinationURL: scratch.appendingPathComponent("linked-dir-target", isDirectory: true)
)
try FileManager.default.createSymbolicLink(
    at: scratch.appendingPathComponent("linked-file", isDirectory: false),
    withDestinationURL: scratch.appendingPathComponent("Sources/App.swift")
)

let scanner = FileTreeScanner()
let scannerRecorder = SnapshotRecorder()
try await scanner.scan(root: scratch, ignoreList: FileTreeScanner.defaultIgnoredNames) { snapshot in
    Task { await scannerRecorder.append(snapshot) }
}

try await scannerRecorder.waitForSnapshot(timeoutNanoseconds: 2_000_000_000)
let finalSnapshot = try await scannerRecorder.lastSnapshot() ?? { throw CheckError("scanner produced no snapshots") }()
let paths = Set(finalSnapshot.nodes.map(\.relativePath))
expect(paths.contains("Sources"), "scanner should include visible directories")
expect(paths.contains("Sources/App.swift"), "scanner should include visible files")
expect(paths.contains("linked-file"), "scanner should include symlinked files")
expect(paths.contains("linked-dir"), "scanner should include symlinked directories as leaves")
expect(!paths.contains(".git/config"), "scanner should not descend into ignored directories")
expect(finalSnapshot.nodes.first(where: { $0.relativePath == ".git" })?.isIgnored == true, "ignored directory node should be marked ignored")
expect(finalSnapshot.nodes.first(where: { $0.relativePath == "Sources/App.swift" })?.gitStatus == nil, "scanner should leave git status unset")

let batchedRecorder = SnapshotRecorder()
try await FileTreeScanner(batchSize: 2).scan(root: scratch, ignoreList: FileTreeScanner.defaultIgnoredNames) { snapshot in
    Task { await batchedRecorder.append(snapshot) }
}
try await batchedRecorder.waitForSnapshotCount(2, timeoutNanoseconds: 2_000_000_000)

let viewModel = await MainActor.run { FileTreeViewModel(scanner: scanner) }
let observed = SnapshotRecorder()
await MainActor.run {
    viewModel.onSnapshotChange = { snapshot in
        Task { await observed.append(snapshot) }
    }
    viewModel.start(rootPath: scratch.path, ignoreList: FileTreeScanner.defaultIgnoredNames)
}

try await observed.waitForSnapshot(timeoutNanoseconds: 2_000_000_000)
let latest = await MainActor.run { viewModel.latestSnapshot }
expect(latest != nil, "view model should apply scanner snapshots on the main actor")

await MainActor.run {
    viewModel.start(rootPath: scratch.appendingPathComponent("Sources", isDirectory: true).path, ignoreList: [])
    viewModel.cancel()
}

struct CheckError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

actor SnapshotRecorder {
    private var snapshots: [FileTreeSnapshot] = []

    func append(_ snapshot: FileTreeSnapshot) {
        snapshots.append(snapshot)
    }

    func waitForSnapshot(timeoutNanoseconds: UInt64) async throws {
        try await waitForSnapshotCount(1, timeoutNanoseconds: timeoutNanoseconds)
    }

    func waitForSnapshotCount(_ count: Int, timeoutNanoseconds: UInt64) async throws {
        let deadline = ContinuousClock.now + .nanoseconds(Int(timeoutNanoseconds))
        while snapshots.count < count {
            if ContinuousClock.now >= deadline {
                throw CheckError("timed out waiting for view model snapshot")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func lastSnapshot() -> FileTreeSnapshot? {
        snapshots.last
    }
}
