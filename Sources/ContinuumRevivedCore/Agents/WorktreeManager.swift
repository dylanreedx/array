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

    // MARK: - Cleanup (P2C.3)

    /// True when every commit on `branch` is already reachable from `into`.
    ///
    /// This is ONE predicate for both of the packet's safe-to-delete cases: a branch
    /// with no commits of its own still points at the commit it was cut from, which is
    /// an ancestor of `HEAD`, so it reads as merged. A branch carrying even one commit
    /// the main checkout has not seen reads as unmerged, and unmerged work is never
    /// deleted.
    public func isMerged(repo: URL, branch: String, into: String = "HEAD") throws -> Bool {
        do {
            _ = try runGit(["merge-base", "--is-ancestor", "refs/heads/\(branch)", into], repo: repo)
            return true
        } catch let error as WorktreeError {
            // `--is-ancestor` answers by exit status: 1 with no stderr means "not an
            // ancestor". Anything else is a real git failure and must not read as
            // "unmerged" — that would be a false NEGATIVE, which is the safe
            // direction, but it would also silently hide a broken repository.
            if case let .gitFailed(_, exitCode, stderr) = error, exitCode == 1, stderr.isEmpty {
                return false
            }
            throw error
        }
    }

    /// Delete a branch, refusing anything that is not fully merged.
    ///
    /// `git branch -d`, never `-D`. The caller is expected to have checked
    /// `isMerged` already; using the safe flag anyway means git itself is the second
    /// guard, so a bug in the caller's check cannot destroy an agent's commits.
    public func deleteBranch(repo: URL, branch: String) throws {
        try requireRepository(repo)
        _ = try runGit(["branch", "-d", branch], repo: repo)
    }

    /// `git worktree prune` — drops the admin records of worktrees whose directory
    /// is gone. It does NOT delete any directory, which is why `repair` removes
    /// first and prunes afterwards.
    public func prune(repo: URL) throws {
        try requireRepository(repo)
        _ = try runGit(["worktree", "prune"], repo: repo)
    }

    /// A worktree under `.worktrees/` with no live agent behind it.
    public struct Orphan: Equatable, Sendable {
        public let path: URL
        public let branch: String?

        public init(path: URL, branch: String?) {
            self.path = path
            self.branch = branch
        }
    }

    /// What one `repair` did. Every outcome is named: a caller must be able to say
    /// which trees went away and which were left alone, and why.
    public struct RepairReport: Equatable, Sendable {
        public struct Retained: Equatable, Sendable {
            public let path: URL
            public let reason: String
        }

        public var found: [Orphan] = []
        /// Checkouts this call deleted from disk.
        public var removed: [URL] = []
        /// Orphans whose directory was ALREADY gone, so only git's admin record was
        /// left to drop. Reported separately from `removed` because nothing was
        /// deleted here — a report that conflated the two would claim to have freed
        /// disk it never touched.
        public var pruned: [URL] = []
        public var retained: [Retained] = []
        /// Branches left behind. `repair` NEVER deletes one — see the doc comment.
        public var branchesKept: [String] = []
    }

    /// Worktrees under `<repo>/.worktrees/` that no live agent claims.
    ///
    /// `knownAgents` is the `cwd` of every agent record the caller still has. Both
    /// sides are compared symlink-resolved because git reports the RESOLVED path in
    /// `worktree list --porcelain` while a record stores whatever the spawn was given
    /// (on macOS a temp root is `/var/...`, a symlink to `/private/var/...`), so a
    /// literal string compare reports every live agent as an orphan.
    ///
    /// Scoped to the container directory on purpose: the main checkout and any
    /// worktree a human created elsewhere in the repository are NOT this manager's to
    /// classify, and calling one an orphan would invite `repair` to delete it.
    public func orphans(repo: URL, knownAgents: Set<String>) throws -> [Orphan] {
        let known = Set(knownAgents.map { Self.resolved(URL(fileURLWithPath: $0)) })
        let container = Self.resolved(
            repo.appendingPathComponent(Self.containerDirectoryName, isDirectory: true)
        ) + "/"
        return try list(repo: repo)
            .filter { !$0.isMain }
            .filter { Self.resolved($0.path).hasPrefix(container) }
            .filter { !known.contains(Self.resolved($0.path)) }
            .map { Orphan(path: $0.path, branch: $0.branch) }
    }

    /// Report every orphan, remove the ones that can be removed without discarding
    /// work, then `prune`.
    ///
    /// Two deliberate refusals:
    /// · **No `--force`.** A dirty orphan is retained and reported. There is nobody
    ///   left to ask whether those edits matter, so guessing is not available.
    /// · **No branch deletion.** The record that said which agent owned this branch is
    ///   gone, so the branch is all that is left of its work. Removing the tree frees
    ///   the disk; the branch is reported for a human.
    public func repair(repo: URL, knownAgents: Set<String>) throws -> RepairReport {
        var report = RepairReport()
        report.found = try orphans(repo: repo, knownAgents: knownAgents)
        for orphan in report.found {
            // A directory that is already gone is not handed to `worktree remove`
            // (which fails on it); the trailing `prune` is what drops its record.
            guard FileManager.default.fileExists(atPath: orphan.path.path) else {
                report.pruned.append(orphan.path)
                if let branch = orphan.branch { report.branchesKept.append(branch) }
                continue
            }
            do {
                try remove(repo: repo, path: orphan.path, force: false)
                report.removed.append(orphan.path)
            } catch {
                report.retained.append(RepairReport.Retained(
                    path: orphan.path,
                    reason: String(describing: error)
                ))
            }
            if let branch = orphan.branch { report.branchesKept.append(branch) }
        }
        try prune(repo: repo)
        return report
    }

    /// A comparable form of a worktree path.
    ///
    /// macOS temp roots live under a `/var` -> `/private/var` symlink, and git reports
    /// the RESOLVED path for a worktree it can read — so a raw string compare against a
    /// record's stored `cwd` fails on every agent.
    ///
    /// The second half is a measured trap, not defensiveness: `resolvingSymlinksInPath`
    /// leaves a path that no longer EXISTS alone, and a worktree whose directory has
    /// been deleted is exactly that case — git echoes the unresolved path it recorded
    /// at `add` time, which then failed to match the resolved container and made the
    /// prunable worktree invisible to `orphans` (observed: `repair found 2 orphans,
    /// expected 3`). Resolving the existing PARENT and re-appending the leaf makes the
    /// live and the vanished forms comparable.
    public static func resolved(_ url: URL) -> String {
        let standardized = url.standardizedFileURL
        if FileManager.default.fileExists(atPath: standardized.path) {
            return standardized.resolvingSymlinksInPath().path
        }
        return standardized.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(standardized.lastPathComponent)
            .path
    }

    // MARK: - The checked-out branch (P2C.4)

    /// Short name of the branch `repo`'s own checkout is on, or nil when its HEAD
    /// is detached.
    ///
    /// "The repo" is whichever working copy is passed: for an isolated agent that
    /// is its OWN worktree (`AgentRecord.cwd`), which is the comparison P2C.4
    /// renders — the branch an agent was given versus the branch its checkout is
    /// actually on. Comparing against the MAIN checkout instead would flag every
    /// isolated agent forever, because `worktree add -b` cuts a fresh branch and
    /// git refuses to check out a branch that is already checked out somewhere
    /// else (both asserted in `runWorktreeCurrentBranchCheck`).
    public func currentBranch(repo: URL) throws -> String? {
        try requireRepository(repo)
        let output = try runGit(["rev-parse", "--abbrev-ref", "HEAD"], repo: repo)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // `--abbrev-ref` prints the literal "HEAD" for a detached head. That is
        // not a branch name: rendering it would read as "on HEAD", and comparing
        // it would compare against a string no branch can equal.
        return output.isEmpty || output == "HEAD" ? nil : output
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

// Ticket: docs/38-tickets/90-agent-ux/P2C.4-branch-on-rows.md
//
// READING A BRANCH IS A PROCESS LAUNCH. The chip that shows it lives in a tile
// header that re-renders on every streamed token, so the read has to be cached —
// the packet's own watch-out. Shape follows `CrossProjectManagedSessionWalk`: a
// TTL, a clock guard, and the caller passing `now`.
public final class CheckedOutBranchCache {
    private let manager: WorktreeManager
    private let ttl: TimeInterval
    /// Keyed by `WorktreeManager.resolved`, so the `/var` -> `/private/var` form
    /// of one directory is one entry rather than two.
    private var entries: [String: (readAt: Date, branch: String?)] = [:]

    /// Every `git rev-parse` this cache has actually run. The witness for "do not
    /// shell out per render" — without a counter that claim is unassertable.
    public private(set) var gitReads = 0

    public init(manager: WorktreeManager = WorktreeManager(), ttl: TimeInterval = 2) {
        self.manager = manager
        self.ttl = ttl
    }

    /// The branch `repo`'s checkout is on, or nil when it is detached, missing or
    /// unreadable.
    ///
    /// A nil answer is cached like any other: a record pointing at a directory
    /// that is gone (the P2A.7 stale case) would otherwise pay a failed process
    /// launch on every render. Nothing throws — a chip that cannot be resolved is
    /// simply not drawn, and a header is not the place to report a git error.
    public func branch(repo: URL, now: Date = Date()) -> String? {
        let key = WorktreeManager.resolved(repo)
        if let entry = entries[key],
           now >= entry.readAt,
           now.timeIntervalSince(entry.readAt) < ttl {
            return entry.branch
        }
        gitReads += 1
        let branch = try? manager.currentBranch(repo: repo)
        let resolved = branch ?? nil
        entries[key] = (now, resolved)
        return resolved
    }

    /// The cache's answer WITHOUT ever shelling out. Outer nil: this repo has
    /// never been read. Inner nil: read, and its HEAD is detached. Staleness is
    /// deliberately ignored here: the sidebar rebuild runs on app activate/resign
    /// on the MAIN thread, and with a 2 s TTL every app switch paid two git
    /// spawns per agent repo — ~0.4 s frozen per switch, sampled live
    /// (2026-08-19). `store` is how an off-main warmer fills what this serves.
    public func cachedOnly(repo: URL) -> String?? {
        entries[WorktreeManager.resolved(repo)]?.branch
    }

    /// Record a value read elsewhere (the off-main warmer), so `cachedOnly`
    /// serves it and the TTL path does not immediately re-read it.
    public func store(branch: String?, repo: URL, now: Date = Date()) {
        entries[WorktreeManager.resolved(repo)] = (now, branch)
    }

    /// Forget everything, for a caller that knows a checkout moved (a `git
    /// checkout` the app itself ran, or a manual refresh). The TTL alone would get
    /// there, but only after up to `ttl` of showing the old branch.
    public func invalidate() {
        entries.removeAll()
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
