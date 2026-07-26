import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P2C.1-worktree-manager.md
//
// `AgentDescriptor.worktreePath` / `AgentRecord.worktreeBranch` have existed
// since P2A.1, but nothing ever ran `git worktree` — every real caller passed
// the project root, so N parallel agents would edit ONE working tree. This is
// the piece that gives an agent its own checkout, and it is a hard prerequisite
// for the orchestrator in 2D.
//
// Layout: `<repo>/.worktrees/<slug>` on branch `agent/<slug>`. `.worktrees/` is
// gitignored in this repo (added by this ticket) so an agent's checkout never
// shows up as untracked noise in the host repo's status.
//
// The process/executable-resolution pattern is `GitDiffEngine`'s, deliberately:
// an injectable `gitExecutableURL` defaulting to `/usr/bin/git`, a `Process`
// with pipes drained by readability handlers, a polled deadline, and everything
// touching `Process` behind `#if os(macOS)` — Core builds for iOS, where
// `Process` does not exist (P0.1's iOS leg goes red at exit 65 on a bare
// `Process()` in Core while `swift build` stays green).
public struct WorktreeManager: Sendable {
    /// Directory, relative to the repository root, that holds every agent
    /// worktree. Public because `.gitignore` and the cleanup ticket (P2C.3)
    /// both need to name the same thing.
    public static let containerDirectoryName = ".worktrees"

    /// Prefix of every branch this manager creates.
    public static let branchPrefix = "agent/"

    /// One entry of `git worktree list`.
    ///
    /// `branch` is optional and `isMain` exists even though the packet sketched
    /// a `(path, branch)` pair: `git worktree list` reports the main checkout
    /// first and can report a detached HEAD, and silently dropping or faking
    /// either would make `list` lie to P2C.3/P2C.4 about what is on disk.
    public struct Worktree: Equatable, Sendable {
        public let path: URL
        /// Short branch name (`agent/fix-auth-1a2b3c4d`), or nil when detached.
        public let branch: String?
        /// True for the repository's own checkout, which is not removable.
        public let isMain: Bool

        public init(path: URL, branch: String?, isMain: Bool) {
            self.path = path
            self.branch = branch
            self.isMain = isMain
        }
    }

    public enum WorktreeError: Error, Equatable, Sendable, CustomStringConvertible {
        case invalidRepository(String)
        case branchExists(String)
        case worktreeExists(String)
        case gitFailed(arguments: [String], exitCode: Int32, stderr: String)
        case timedOut(arguments: [String])
        case unsupportedPlatform

        public var description: String {
            switch self {
            case let .invalidRepository(path): return "not a git repository: \(path)"
            case let .branchExists(branch): return "branch already exists: \(branch)"
            case let .worktreeExists(path): return "worktree path already exists: \(path)"
            case let .gitFailed(arguments, exitCode, stderr):
                return "git \(arguments.joined(separator: " ")) failed (\(exitCode)): \(stderr)"
            case let .timedOut(arguments): return "git \(arguments.joined(separator: " ")) timed out"
            case .unsupportedPlatform: return "git worktrees are only available on macOS"
            }
        }
    }

    public var timeoutSeconds: TimeInterval
    private let gitExecutableURL: URL

    public init(timeoutSeconds: TimeInterval = 20, gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git")) {
        self.timeoutSeconds = timeoutSeconds
        self.gitExecutableURL = gitExecutableURL
    }

    // MARK: - Slug

    /// Longest a slug's human-readable part may be, before the id suffix.
    private static let slugBodyLimit = 32

    /// Deterministic, filesystem- and ref-safe name for one agent's worktree.
    ///
    /// Pure: same inputs, same output, no I/O — so the caller can compute the
    /// path and the branch without touching git.
    ///
    /// `[a-z0-9-]` only, no leading/trailing or repeated `-`, body truncated,
    /// and always suffixed with eight hex digits derived from the agent id, so
    /// two agents told to "fix auth" get different slugs. The suffix also means
    /// a slug can never be empty, never start with `-` (which git rejects as a
    /// refname), never be `.` or `..`, and never end in `.lock`.
    public static func slug(role: String?, prompt: String?, id: AgentID) -> String {
        let source = [role, prompt]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var body = sanitize(source)
        if body.count > slugBodyLimit {
            body = String(body.prefix(slugBodyLimit))
            while body.hasSuffix("-") { body.removeLast() }
        }
        let suffix = idSuffix(id)
        return body.isEmpty ? "agent-\(suffix)" : "\(body)-\(suffix)"
    }

    /// Eight hex digits folded from ALL SIXTEEN bytes of the id.
    ///
    /// Not `uuidString.prefix(8)`: ids that share a prefix are common in
    /// practice (every fixture in this repo is `A0000000-0000-4000-8000-…`, and
    /// sequential generators exist), and two such agents would land on one
    /// slug — the collision this suffix exists to prevent. FNV-1a is used
    /// because it is a fixed algorithm: Swift's `Hasher` is seeded per process,
    /// so its output is not stable across launches and a slug must be.
    private static func idSuffix(_ id: AgentID) -> String {
        let bytes = id.rawValue.uuid
        var hash: UInt32 = 2_166_136_261
        for byte in [
            bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7,
            bytes.8, bytes.9, bytes.10, bytes.11, bytes.12, bytes.13, bytes.14, bytes.15,
        ] {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return String(format: "%08x", hash)
    }

    /// Lowercase, map anything outside `[a-z0-9]` to `-`, collapse runs, trim.
    private static func sanitize(_ text: String) -> String {
        var out = ""
        var pendingSeparator = false
        for character in text.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                if pendingSeparator, !out.isEmpty { out.append("-") }
                pendingSeparator = false
                out.append(character)
            } else {
                pendingSeparator = true
            }
        }
        return out
    }

    /// Where `add(repo:slug:)` will put this slug's checkout. Pure.
    public static func worktreeURL(repo: URL, slug: String) -> URL {
        repo.appendingPathComponent(containerDirectoryName, isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
    }

    /// Branch `add(repo:slug:)` will create for this slug. Pure.
    public static func branchName(slug: String) -> String { branchPrefix + slug }

    // MARK: - Operations

    /// Create `<repo>/.worktrees/<slug>` on a NEW branch `agent/<slug>`.
    ///
    /// An existing branch is an error, never a silent reuse: reusing it would
    /// put two agents on one branch, which is exactly the clobbering this
    /// ticket exists to prevent.
    @discardableResult
    public func add(repo: URL, slug: String) throws -> Worktree {
        try requireRepository(repo)
        let path = Self.worktreeURL(repo: repo, slug: slug)
        let branch = Self.branchName(slug: slug)

        if FileManager.default.fileExists(atPath: path.path) {
            throw WorktreeError.worktreeExists(path.path)
        }
        if try branchExists(repo: repo, branch: branch) {
            throw WorktreeError.branchExists(branch)
        }

        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try runGit(["worktree", "add", "-b", branch, path.path], repo: repo)
        return Worktree(path: path, branch: branch, isMain: false)
    }

    /// Every worktree git knows about, main checkout included.
    public func list(repo: URL) throws -> [Worktree] {
        try requireRepository(repo)
        let output = try runGit(["worktree", "list", "--porcelain"], repo: repo)
        return Self.parseWorktreeList(output)
    }

    /// Remove a worktree. `force` also removes one with local modifications.
    ///
    /// The branch is left behind on purpose — deleting it would throw away the
    /// agent's work. Branch cleanup is P2C.3's decision, not this call's.
    public func remove(repo: URL, path: URL, force: Bool) throws {
        try requireRepository(repo)
        var arguments = ["worktree", "remove"]
        if force { arguments.append("--force") }
        arguments.append(path.path)
        _ = try runGit(arguments, repo: repo)
    }

    /// True when `refs/heads/<branch>` resolves.
    public func branchExists(repo: URL, branch: String) throws -> Bool {
        do {
            _ = try runGit(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], repo: repo)
            return true
        } catch let error as WorktreeError {
            // `--verify --quiet` exits 1 with no stderr for "no such ref"; any
            // other failure is a real git error and must not read as "absent".
            if case let .gitFailed(_, exitCode, stderr) = error, exitCode == 1, stderr.isEmpty {
                return false
            }
            throw error
        }
    }

    /// Parses `git worktree list --porcelain`. Pure, so the format handling is
    /// testable without a repository.
    ///
    /// Records are blank-line separated; the first is always the main checkout.
    /// `branch refs/heads/<name>` is absent for a detached HEAD.
    public static func parseWorktreeList(_ output: String) -> [Worktree] {
        var results: [Worktree] = []
        var path: String?
        var branch: String?

        func flush() {
            guard let path else { branch = nil; return }
            results.append(Worktree(path: URL(fileURLWithPath: path), branch: branch, isMain: results.isEmpty))
            branch = nil
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("worktree ") {
                flush()
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/") {
                branch = String(line.dropFirst("branch refs/heads/".count))
            } else if line.isEmpty {
                flush()
                path = nil
            }
        }
        flush()
        return results
    }

    private func requireRepository(_ repo: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repo.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw WorktreeError.invalidRepository(repo.path)
        }
        do {
            _ = try runGit(["rev-parse", "--git-dir"], repo: repo)
        } catch let error as WorktreeError {
            if case .gitFailed = error { throw WorktreeError.invalidRepository(repo.path) }
            throw error
        }
    }

    @discardableResult
    private func runGit(_ arguments: [String], repo: URL) throws -> String {
        #if os(macOS)
        let process = Process()
        process.executableURL = gitExecutableURL
        process.arguments = arguments
        process.currentDirectoryURL = repo

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let output = WorktreeProcessOutput()
        let errorOutput = WorktreeProcessOutput()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            output.append(chunk)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            errorOutput.append(chunk)
        }
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
        }

        try process.run()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.05)
            if process.isRunning { process.interrupt() }
            throw WorktreeError.timedOut(arguments: arguments)
        }
        Thread.sleep(forTimeInterval: 0.02)

        let text = String(data: output.data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let stderrText = (String(data: errorOutput.data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw WorktreeError.gitFailed(arguments: arguments, exitCode: process.terminationStatus, stderr: stderrText)
        }
        return text
        #else
        _ = arguments
        _ = repo
        throw WorktreeError.unsupportedPlatform
        #endif
    }
}

#if os(macOS)
private final class WorktreeProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }
}
#endif
