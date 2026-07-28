import ContinuumRevivedFileTree
import ContinuumRevivedCore
import Foundation
#if canImport(Darwin)
import Darwin
#endif

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

let porcelain = " M Sources/App.swift\u{0}A  Sources/New.swift\u{0}D  Sources/Old.swift\u{0}R  Sources/Renamed.swift\u{0}Sources/Original.swift\u{0}?? Sources/Loose.swift\u{0}UU Sources/Conflict.swift\u{0}"
let parsedStatuses = FileTreeGitStatusProbe.parsePorcelain(Data(porcelain.utf8))
expect(parsedStatuses["Sources/App.swift"] == .modified, "git parser should map modified files")
expect(parsedStatuses["Sources/New.swift"] == .added, "git parser should map added files")
expect(parsedStatuses["Sources/Old.swift"] == .deleted, "git parser should map deleted files")
expect(parsedStatuses["Sources/Renamed.swift"] == .renamed, "git parser should map renamed destination files")
expect(parsedStatuses["Sources/Loose.swift"] == .untracked, "git parser should map untracked files")
expect(parsedStatuses["Sources/Conflict.swift"] == .conflicted, "git parser should map conflicted files")
expect(FileTreeGitStatusProbe.parsePorcelain(Data([0x4d])).isEmpty, "git parser should hide badges for malformed output")

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

let statusScannerRecorder = SnapshotRecorder()
try await scanner.scan(
    root: scratch,
    ignoreList: FileTreeScanner.defaultIgnoredNames,
    gitStatuses: ["Sources/App.swift": .modified]
) { snapshot in
    Task { await statusScannerRecorder.append(snapshot) }
}
try await statusScannerRecorder.waitForSnapshot(timeoutNanoseconds: 2_000_000_000)
let statusSnapshot = try await statusScannerRecorder.lastSnapshot() ?? { throw CheckError("scanner produced no status snapshot") }()
expect(
    statusSnapshot.nodes.first(where: { $0.relativePath == "Sources/App.swift" })?.gitStatus == .modified,
    "scanner should attach supplied git statuses by relative path"
)

let unfilteredOutline = FileTreeOutlineModel(snapshot: finalSnapshot, query: "")
expect(unfilteredOutline.rootItems.contains(where: { $0.node.relativePath == "Sources" }), "outline should include root directories without a query")

let filteredOutline = FileTreeOutlineModel(snapshot: finalSnapshot, query: "App.swift")
let filteredRootPaths = Set(filteredOutline.rootItems.map(\.node.relativePath))
expect(filteredRootPaths.contains("Sources"), "outline filter should keep ancestors for matched descendants")
expect(filteredOutline.children(of: filteredOutline.rootItems.first { $0.node.relativePath == "Sources" }).contains(where: {
    $0.node.relativePath == "Sources/App.swift"
}), "outline filter should keep matched descendant file")
expect(!filteredRootPaths.contains("linked-dir-target"), "outline filter should hide unrelated directories")

let batchedRecorder = SnapshotRecorder()
try await FileTreeScanner(batchSize: 2).scan(root: scratch, ignoreList: FileTreeScanner.defaultIgnoredNames) { snapshot in
    Task { await batchedRecorder.append(snapshot) }
}
try await batchedRecorder.waitForSnapshotCount(2, timeoutNanoseconds: 2_000_000_000)

let largeRoot = scratch.appendingPathComponent("large-50k", isDirectory: true)
try makeDirectory(largeRoot)
let syntheticDirectories = 250
let syntheticFilesPerDirectory = 200
for directoryIndex in 0..<syntheticDirectories {
    let directory = largeRoot.appendingPathComponent(String(format: "dir-%03d", directoryIndex), isDirectory: true)
    try makeDirectory(directory)
    for fileIndex in 0..<syntheticFilesPerDirectory {
        try makeFile(directory.appendingPathComponent(String(format: "file-%03d.txt", fileIndex)))
    }
}
let generatedVisibleNodes = syntheticDirectories + (syntheticDirectories * syntheticFilesPerDirectory)
let cap = 10_000
let largeRecorder = SnapshotRecorder()
let largeStart = ContinuousClock.now
try await FileTreeScanner(batchSize: 5_000, nodeLimit: cap).scan(root: largeRoot, ignoreList: FileTreeScanner.defaultIgnoredNames) { snapshot in
    Task { await largeRecorder.append(snapshot) }
}
try await largeRecorder.waitForSnapshot(timeoutNanoseconds: 10_000_000_000)
let largeElapsed = largeStart.duration(to: ContinuousClock.now)
let largeElapsedMs = Double(largeElapsed.components.seconds) * 1000.0 + Double(largeElapsed.components.attoseconds) / 1_000_000_000_000_000.0
let largeFinal = try await largeRecorder.lastSnapshot() ?? { throw CheckError("large scanner produced no snapshot") }()
let largeSnapshotCount = await largeRecorder.snapshotCount()
let largeTable: [String: Any] = [
    "generatedVisibleNodes": generatedVisibleNodes,
    "nodeBudget": cap,
    "emittedNodes": largeFinal.nodes.count,
    "snapshotCount": largeSnapshotCount,
    "capHit": largeFinal.isTruncated,
    "nodeLimit": largeFinal.nodeLimit ?? -1,
    "elapsedMs": Int(largeElapsedMs.rounded())
]
print("FileTreeChecks largeScanCap table: \(largeTable)")
expect(generatedVisibleNodes >= 50_000, "large scanner fixture should synthesize at least 50k visible nodes")
expect(largeFinal.nodes.count == cap, "large scanner should stop exactly at configured cap")
expect(largeFinal.isTruncated, "large scanner should report truncation honestly")
expect(largeFinal.nodeLimit == cap, "large scanner should include node limit in final snapshot")
expect(largeSnapshotCount <= 4, "large scanner should bound snapshot count for capped scan")
expect(largeElapsedMs < 10_000, "large capped scanner should finish under 10s")

let viewModel = await MainActor.run { FileTreeViewModel(scanner: scanner) }
let observed = SnapshotRecorder()
await MainActor.run {
    viewModel.onSnapshotChange = { snapshot in
        Task { await observed.append(snapshot) }
    }
    viewModel.start(rootPath: scratch.path, ignoreList: FileTreeScanner.defaultIgnoredNames)
}

try await observed.waitForSnapshot(timeoutNanoseconds: 10_000_000_000)
let latest = await MainActor.run { viewModel.latestSnapshot }
expect(latest != nil, "view model should apply scanner snapshots on the main actor")

let errorViewModel = await MainActor.run { FileTreeViewModel(scanner: scanner) }
let errorRecorder = ErrorRecorder()
await MainActor.run {
    errorViewModel.onError = { error in
        Task { await errorRecorder.append(error) }
    }
    errorViewModel.start(
        rootPath: scratch.appendingPathComponent("missing", isDirectory: true).path,
        ignoreList: FileTreeScanner.defaultIgnoredNames
    )
}
try await errorRecorder.waitForError(timeoutNanoseconds: 2_000_000_000)
let recordedError = await MainActor.run { errorViewModel.lastError }
expect(recordedError != nil, "view model should expose scanner errors for UI state")

let gitRoot = scratch.appendingPathComponent("git-root", isDirectory: true)
try makeDirectory(gitRoot)
try makeDirectory(gitRoot.appendingPathComponent("Sources", isDirectory: true))
try makeFile(gitRoot.appendingPathComponent("Sources/App.swift"))

let gitViewModel = await MainActor.run {
    FileTreeViewModel(scanner: scanner) { _ in
        ["Sources/App.swift": .modified]
    }
}
let gitObserved = SnapshotRecorder()
await MainActor.run {
    gitViewModel.onSnapshotChange = { snapshot in
        Task { await gitObserved.append(snapshot) }
    }
    gitViewModel.start(
        rootPath: gitRoot.path,
        ignoreList: FileTreeScanner.defaultIgnoredNames,
        gitBadgeMode: .cheap
    )
}
try await gitObserved.waitForGitStatus(
    path: "Sources/App.swift",
    status: nil,
    timeoutNanoseconds: 2_000_000_000
)
try await gitObserved.waitForGitStatus(
    path: "Sources/App.swift",
    status: .modified,
    timeoutNanoseconds: 5_000_000_000
)

try makeDirectory(gitRoot.appendingPathComponent(".git", isDirectory: true))
try makeFile(gitRoot.appendingPathComponent(".git/HEAD"), contents: "ref: refs/heads/main\n")
try runGit(["init", "-q"], in: gitRoot)
try runGit(["config", "user.email", "checks@example.invalid"], in: gitRoot)
try runGit(["config", "user.name", "Continuum Checks"], in: gitRoot)
try runGit(["add", "Sources/App.swift"], in: gitRoot)
try runGit(["commit", "-q", "-m", "seed"], in: gitRoot)
try makeFile(gitRoot.appendingPathComponent("Sources/App.swift"), contents: "changed\n")
let directStatuses = FileTreeGitStatusProbe().statuses(root: gitRoot)
expect(directStatuses["Sources/App.swift"] == .modified, "git probe should return modified file status")
let nonGitStatuses = FileTreeGitStatusProbe().statuses(root: scratch.appendingPathComponent("not-a-repo", isDirectory: true))
expect(nonGitStatuses.isEmpty, "git probe should hide badges when git status fails")

try runHostileFakeGitProbeChecks(scratch: scratch)

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

    func snapshotCount() -> Int {
        snapshots.count
    }

    func waitForGitStatus(
        path: String,
        status: FileTreeGitStatus?,
        timeoutNanoseconds: UInt64
    ) async throws {
        let deadline = ContinuousClock.now + .nanoseconds(Int(timeoutNanoseconds))
        while !snapshots.contains(where: { snapshot in
            snapshot.nodes.contains { node in
                node.relativePath == path && node.gitStatus == status
            }
        }) {
            if ContinuousClock.now >= deadline {
                throw CheckError("timed out waiting for matching view model snapshot")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

actor ErrorRecorder {
    private var errors: [Error] = []

    func append(_ error: Error) {
        errors.append(error)
    }

    func waitForError(timeoutNanoseconds: UInt64) async throws {
        let deadline = ContinuousClock.now + .nanoseconds(Int(timeoutNanoseconds))
        while errors.isEmpty {
            if ContinuousClock.now >= deadline {
                throw CheckError("timed out waiting for view model error")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

func runGit(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", directory.path] + arguments
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw CheckError("git \(arguments.joined(separator: " ")) failed")
    }
}

func runHostileFakeGitProbeChecks(scratch: URL) throws {
    let bin = scratch.appendingPathComponent("fake-git-bin", isDirectory: true)
    try makeDirectory(bin)
    let fakeGit = bin.appendingPathComponent("git")
    let chunk = String(repeating: "X", count: 1024)
    let stderrChunk = String(repeating: "E", count: 1024)
    let script = """
    #!/bin/sh
    case "$FAKE_GIT_MODE" in
      ok)
        printf ' M Sources/App.swift\\000'
        exit 0
        ;;
      huge)
        i=0
        while [ $i -lt 512 ]; do
          printf '\(chunk)'
          i=$((i + 1))
        done
        sleep 5
        ;;
      infinite)
        echo $$ > "$FAKE_GIT_PID_FILE"
        trap '' TERM
        while :; do
          printf '\(chunk)'
        done
        ;;
      ignore-term)
        echo $$ > "$FAKE_GIT_PID_FILE"
        trap '' TERM
        while :; do
          :
        done
        ;;
      stderr-flood)
        i=0
        while [ $i -lt 512 ]; do
          printf '\(stderrChunk)\\n' >&2
          i=$((i + 1))
        done
        exit 1
        ;;
      *)
        exit 2
        ;;
    esac
    """
    try makeFile(fakeGit, contents: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGit.path)

    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "\(bin.path):\(environment["PATH"] ?? "")"

    let validStatuses = try runFakeGitProbe(
        mode: "ok",
        root: scratch,
        environment: environment,
        executableURL: fakeGit,
        timeout: 1.0
    )
    expect(validStatuses.statuses["Sources/App.swift"] == .modified, "fake git valid output should still parse")

    let huge = try runFakeGitProbe(mode: "huge", root: scratch, environment: environment, executableURL: fakeGit)
    expect(huge.statuses.isEmpty, "fake git oversized stdout should hide badges")
    expect(huge.elapsed < 2.0, "fake git oversized stdout should return within bounded time, got \(huge.elapsed)s")

    let stderrFlood = try runFakeGitProbe(mode: "stderr-flood", root: scratch, environment: environment, executableURL: fakeGit)
    expect(stderrFlood.statuses.isEmpty, "fake git stderr flood failure should hide badges")
    expect(stderrFlood.elapsed < 2.0, "fake git stderr flood should not deadlock, got \(stderrFlood.elapsed)s")

    let infinitePIDFile = scratch.appendingPathComponent("fake-git-infinite.pid")
    var infiniteEnvironment = environment
    infiniteEnvironment["FAKE_GIT_PID_FILE"] = infinitePIDFile.path
    let infinite = try runFakeGitProbe(mode: "infinite", root: scratch, environment: infiniteEnvironment, executableURL: fakeGit)
    expect(infinite.statuses.isEmpty, "fake git infinite stdout should hide badges")
    expect(infinite.elapsed < 2.0, "fake git infinite stdout should be hard-killed within bounded time, got \(infinite.elapsed)s")
    try expectNoLiveProcess(pidFile: infinitePIDFile, message: "fake git infinite stdout process should not be left running")

    let ignoreTermPIDFile = scratch.appendingPathComponent("fake-git-ignore-term.pid")
    var ignoreTermEnvironment = environment
    ignoreTermEnvironment["FAKE_GIT_PID_FILE"] = ignoreTermPIDFile.path
    let ignoreTerm = try runFakeGitProbe(mode: "ignore-term", root: scratch, environment: ignoreTermEnvironment, executableURL: fakeGit)
    expect(ignoreTerm.statuses.isEmpty, "fake git ignoring SIGTERM should hide badges")
    expect(ignoreTerm.elapsed < 2.0, "fake git ignoring SIGTERM should be hard-killed within bounded time, got \(ignoreTerm.elapsed)s")
    try expectNoLiveProcess(pidFile: ignoreTermPIDFile, message: "fake git ignoring SIGTERM process should not be left running")
}

func runFakeGitProbe(
    mode: String,
    root: URL,
    environment: [String: String],
    executableURL: URL,
    timeout: TimeInterval = 0.15
) throws -> (statuses: [String: FileTreeGitStatus], elapsed: TimeInterval) {
    var environment = environment
    environment["FAKE_GIT_MODE"] = mode
    let probe = FileTreeGitStatusProbe(
        timeout: timeout,
        terminationGrace: 0.15,
        maxOutputBytes: 4 * 1024,
        environment: environment,
        executableURL: executableURL,
        argumentPrefix: []
    )
    let start = Date()
    let statuses = probe.statuses(root: root)
    return (statuses, Date().timeIntervalSince(start))
}

func expectNoLiveProcess(pidFile: URL, message: String) throws {
    let rawPID = try String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pid = Int32(rawPID) else {
        throw CheckError("could not parse fake git pid from \(pidFile.path)")
    }
    let deadline = Date().addingTimeInterval(1.0)
    while processExists(pid) && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    expect(!processExists(pid), message)
}

func processExists(_ pid: Int32) -> Bool {
#if canImport(Darwin)
    Darwin.kill(pid, 0) == 0
#else
    false
#endif
}
