import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P2C.1-worktree-manager.md
//
// Everything here runs against a TEMP `git init` repository created per check
// and deleted after — `git worktree add` is never pointed at the real
// repository (the packet's explicit trap).
//
// Eight properties:
//   1. Slug purity: `[a-z0-9-]` only, no `/`, no spaces, no uppercase, no
//      leading/trailing or repeated `-`, truncated, and never empty.
//   2. Slug determinism: same inputs → same slug; two different ids with
//      IDENTICAL role+prompt → different slugs (the collision the packet names).
//   3. `add` creates `<repo>/.worktrees/<slug>` on branch `agent/<slug>`, and
//      `list` reports both, with the main checkout flagged and reported too.
//   4. Adding the same slug twice fails cleanly and leaves the first intact.
//   5. A branch that already exists is NEVER silently reused — `add` throws and
//      creates nothing.
//   6. `remove` deletes the checkout and drops it from `list`, while leaving the
//      branch (the agent's work) alone.
//   7. `parseWorktreeList` handles a detached HEAD without inventing a branch.
//   8. A directory that is not a repository is `invalidRepository`, not a raw
//      git failure.

func runWorktreeManagerChecks() {
    do {
        try runWorktreeSlugPurityCheck()
        try runWorktreeSlugDeterminismCheck()
        try runWorktreeAddAndListCheck()
        try runWorktreeDuplicateSlugCheck()
        try runWorktreeExistingBranchCheck()
        try runWorktreeRemoveCheck()
        try runWorktreeListParsingCheck()
        try runWorktreeInvalidRepositoryCheck()
        print("WorktreeManager checks: slug purity/determinism, add+list, duplicate slug, existing branch, remove, porcelain parsing, and invalid repository passed")
    } catch {
        fputs("FAIL: WorktreeManager checks failed: \(error)\n", stderr)
        Foundation.exit(1)
    }
}

private struct WorktreeCheckError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func worktreeExpect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw WorktreeCheckError(message()) }
}

private func worktreeAgentId(_ suffix: String) -> AgentID {
    AgentID(rawValue: UUID(uuidString: "A0000000-0000-4000-8000-0000000\(suffix)")!)
}

// MARK: - Temp repository

/// A real repository with one commit, in a temp directory. `git worktree add`
/// needs a HEAD, so the commit is not optional.
///
/// `-c` identity and `--no-gpg-sign` keep the check independent of whatever the
/// host's global git config says; a machine with no `user.email` set would
/// otherwise fail here for a reason that has nothing to do with the ticket.
private func makeWorktreeTempRepo() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("continuum-worktree-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try runTempGit(["init", "-q", "-b", "main"], in: root)
    try "seed\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try runTempGit(["add", "README.md"], in: root)
    try runTempGit([
        "-c", "user.email=qa@continuum.test",
        "-c", "user.name=Continuum QA",
        "commit", "-q", "--no-gpg-sign", "-m", "seed",
    ], in: root)
    return root
}

@discardableResult
private func runTempGit(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw WorktreeCheckError("temp git \(arguments.joined(separator: " ")) failed (\(process.terminationStatus)): \(String(data: errData, encoding: .utf8) ?? "")")
    }
    return String(data: outData, encoding: .utf8) ?? ""
}

/// macOS temp directories live under a `/var` symlink to `/private/var`, and
/// git reports the RESOLVED path in `worktree list --porcelain`. Comparing
/// unresolved URLs here would fail for a reason that has nothing to do with the
/// manager, so both sides are resolved before comparison.
private func resolved(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
}

// MARK: - 1. Slug purity

/// Negative test observed red with the final code: with `sanitize` returning
/// `text.lowercased()` unchanged (no character mapping), this check reported
///   FAIL: WorktreeManager checks failed: slug "fix auth/login (urgent)!-99b77365"
///   contains a character outside [a-z0-9-]
private func runWorktreeSlugPurityCheck() throws {
    let cases: [String?] = [
        "Fix Auth/login (urgent)!",
        "   ",
        "___",
        "Ünïcødé role",
        "a/b/c",
        "-leading and trailing-",
        "..",
        "HEAD.lock",
        String(repeating: "very long prompt ", count: 20),
    ]
    let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")

    for (index, text) in cases.enumerated() {
        let slug = WorktreeManager.slug(role: text, prompt: nil, id: worktreeAgentId(String(format: "%05d", index)))
        try worktreeExpect(!slug.isEmpty, "slug for \(String(describing: text)) is empty")
        try worktreeExpect(
            slug.allSatisfy { allowed.contains($0) },
            "slug \"\(slug)\" contains a character outside [a-z0-9-]"
        )
        try worktreeExpect(!slug.hasPrefix("-"), "slug \"\(slug)\" starts with '-', which git rejects as a refname")
        try worktreeExpect(!slug.hasSuffix("-"), "slug \"\(slug)\" ends with '-'")
        try worktreeExpect(!slug.contains("--"), "slug \"\(slug)\" contains a collapsed-separator run")
        try worktreeExpect(!slug.hasSuffix(".lock"), "slug \"\(slug)\" ends with .lock, which git rejects as a refname")
        try worktreeExpect(slug != "." && slug != "..", "slug \"\(slug)\" is a relative path component")
        // Body limit (32) + '-' + 8 hex digits.
        try worktreeExpect(slug.count <= 41, "slug \"\(slug)\" is \(slug.count) characters, over the 41 the truncation guarantees")
    }

    // Empty inputs still produce a usable, non-empty slug.
    let empty = WorktreeManager.slug(role: nil, prompt: nil, id: worktreeAgentId("00099"))
    try worktreeExpect(empty.hasPrefix("agent-"), "empty role+prompt should fall back to agent-<id>, got \"\(empty)\"")

    // Role and prompt are BOTH used, so "reviewer"+"fix auth" and
    // "implementer"+"fix auth" are distinguishable at a glance.
    let joined = WorktreeManager.slug(role: "reviewer", prompt: "fix auth", id: worktreeAgentId("00098"))
    try worktreeExpect(joined.hasPrefix("reviewer-fix-auth-"), "role and prompt should both appear, got \"\(joined)\"")
}

// MARK: - 2. Slug determinism

/// The fixture ids here differ only in their LAST digits, which is how ids
/// actually look in this repo (`A0000000-0000-4000-8000-…`). That is deliberate:
/// with the first implementation's `uuidString.prefix(8)` suffix this check was
/// observed red —
///   FAIL: WorktreeManager checks failed: two agents with identical role+prompt
///   collided on slug "implementer-fix-auth-a0000000"
/// — which is why the suffix folds all sixteen id bytes instead.
private func runWorktreeSlugDeterminismCheck() throws {
    let first = worktreeAgentId("00101")
    let second = worktreeAgentId("00102")

    let a = WorktreeManager.slug(role: "implementer", prompt: "fix auth", id: first)
    let b = WorktreeManager.slug(role: "implementer", prompt: "fix auth", id: first)
    try worktreeExpect(a == b, "slug is not stable across calls: \"\(a)\" vs \"\(b)\"")

    let other = WorktreeManager.slug(role: "implementer", prompt: "fix auth", id: second)
    try worktreeExpect(
        a != other,
        "two agents with identical role+prompt collided on slug \"\(a)\""
    )
    try worktreeExpect(
        a.hasPrefix("implementer-fix-auth-") && other.hasPrefix("implementer-fix-auth-"),
        "the readable body should survive the id suffix: \"\(a)\" / \"\(other)\""
    )

    // A prompt long enough to be truncated must still differ per id.
    let long = String(repeating: "refactor the session supervisor ", count: 5)
    let c = WorktreeManager.slug(role: nil, prompt: long, id: first)
    let d = WorktreeManager.slug(role: nil, prompt: long, id: second)
    try worktreeExpect(c != d, "truncated slugs collided: \"\(c)\"")
}

// MARK: - 3. add + list

/// Negative test observed red with the final code: with `add` shelling out to
/// `git worktree add <path>` (no `-b`, so git picks a name off the directory),
/// this check reported
///   FAIL: WorktreeManager checks failed: branch agent/implementer-fix-auth-e4bc66a4
///   does not exist after add
private func runWorktreeAddAndListCheck() throws {
    let repo = try makeWorktreeTempRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    let manager = WorktreeManager()

    let slug = WorktreeManager.slug(role: "implementer", prompt: "fix auth", id: worktreeAgentId("00201"))
    let created = try manager.add(repo: repo, slug: slug)

    let expectedPath = repo
        .appendingPathComponent(".worktrees", isDirectory: true)
        .appendingPathComponent(slug, isDirectory: true)
    try worktreeExpect(
        created.path.path == expectedPath.path,
        "worktree landed at \(created.path.path), expected \(expectedPath.path)"
    )
    var isDirectory: ObjCBool = false
    try worktreeExpect(
        FileManager.default.fileExists(atPath: expectedPath.path, isDirectory: &isDirectory) && isDirectory.boolValue,
        "no directory at \(expectedPath.path) after add"
    )
    try worktreeExpect(
        FileManager.default.fileExists(atPath: expectedPath.appendingPathComponent("README.md").path),
        "the worktree has no checkout — README.md from HEAD is missing"
    )
    try worktreeExpect(created.branch == "agent/\(slug)", "branch is \(String(describing: created.branch)), expected agent/\(slug)")
    try worktreeExpect(
        try manager.branchExists(repo: repo, branch: "agent/\(slug)"),
        "branch agent/\(slug) does not exist after add"
    )
    try worktreeExpect(!created.isMain, "a new agent worktree must not be flagged as the main checkout")

    let listed = try manager.list(repo: repo)
    try worktreeExpect(listed.count == 2, "expected main + 1 worktree, got \(listed.count)")
    try worktreeExpect(listed[0].isMain, "the first porcelain record should be the main checkout")
    try worktreeExpect(
        resolved(listed[0].path) == resolved(repo),
        "main checkout reported at \(listed[0].path.path), expected \(repo.path)"
    )
    guard let entry = listed.first(where: { resolved($0.path) == resolved(expectedPath) }) else {
        throw WorktreeCheckError("list did not report \(expectedPath.path); it reported \(listed.map(\.path.path))")
    }
    try worktreeExpect(entry.branch == "agent/\(slug)", "list reported branch \(String(describing: entry.branch))")
    try worktreeExpect(!entry.isMain, "the agent worktree is flagged as main")
}

// MARK: - 4. Duplicate slug

private func runWorktreeDuplicateSlugCheck() throws {
    let repo = try makeWorktreeTempRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    let manager = WorktreeManager()
    let slug = WorktreeManager.slug(role: "reviewer", prompt: "same slug twice", id: worktreeAgentId("00301"))

    let first = try manager.add(repo: repo, slug: slug)
    do {
        _ = try manager.add(repo: repo, slug: slug)
        throw WorktreeCheckError("adding the same slug twice succeeded; it must fail")
    } catch let error as WorktreeManager.WorktreeError {
        guard case .worktreeExists = error else {
            throw WorktreeCheckError("expected .worktreeExists on a duplicate slug, got \(error)")
        }
    }

    // Cleanly: the first worktree is still checked out and still listed.
    try worktreeExpect(
        FileManager.default.fileExists(atPath: first.path.appendingPathComponent("README.md").path),
        "the duplicate add corrupted the first worktree"
    )
    let listed = try manager.list(repo: repo)
    try worktreeExpect(listed.count == 2, "expected main + 1 worktree after the failed duplicate, got \(listed.count)")
}

// MARK: - 5. Pre-existing branch is never reused

/// The packet's headline trap: reusing an existing branch would put two agents
/// on one branch, which is the clobbering this whole ticket exists to prevent.
///
/// Negative test observed red with the final code: with the `branchExists`
/// guard in `add` disabled, this check reported
///   FAIL: WorktreeManager checks failed: expected .branchExists(agent/branch-already-taken-00ad882e),
///   got git worktree add -b agent/branch-already-taken-00ad882e … failed (255):
///   Preparing worktree (new branch 'agent/branch-already-taken-00ad882e')
/// i.e. git itself also refuses, but only after leaving a half-prepared state
/// and a raw 255 the caller cannot distinguish from any other git failure. The
/// guard is what makes the refusal typed and clean, per "fails cleanly rather
/// than corrupting".
private func runWorktreeExistingBranchCheck() throws {
    let repo = try makeWorktreeTempRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    let manager = WorktreeManager()
    let slug = WorktreeManager.slug(role: nil, prompt: "branch already taken", id: worktreeAgentId("00401"))
    let branch = "agent/\(slug)"

    // Someone else's branch, with no worktree attached to it.
    try runTempGit(["branch", branch], in: repo)

    do {
        _ = try manager.add(repo: repo, slug: slug)
        throw WorktreeCheckError("add reused the existing branch \(branch); it must refuse")
    } catch let error as WorktreeManager.WorktreeError {
        guard case let .branchExists(reported) = error, reported == branch else {
            throw WorktreeCheckError("expected .branchExists(\(branch)), got \(error)")
        }
    }
    try worktreeExpect(
        !FileManager.default.fileExists(atPath: WorktreeManager.worktreeURL(repo: repo, slug: slug).path),
        "the refused add still created a directory"
    )
    try worktreeExpect(try manager.list(repo: repo).count == 1, "the refused add still registered a worktree")
}

// MARK: - 6. remove

private func runWorktreeRemoveCheck() throws {
    let repo = try makeWorktreeTempRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    let manager = WorktreeManager()
    let slug = WorktreeManager.slug(role: nil, prompt: "remove me", id: worktreeAgentId("00501"))
    let created = try manager.add(repo: repo, slug: slug)

    try manager.remove(repo: repo, path: created.path, force: false)
    try worktreeExpect(
        !FileManager.default.fileExists(atPath: created.path.path),
        "the worktree directory survived remove"
    )
    let listed = try manager.list(repo: repo)
    try worktreeExpect(listed.count == 1 && listed[0].isMain, "remove left \(listed.count) worktrees listed")
    // The branch is deliberately kept: it holds the agent's work. P2C.3 owns
    // whether and when a branch is deleted.
    try worktreeExpect(
        try manager.branchExists(repo: repo, branch: "agent/\(slug)"),
        "remove deleted branch agent/\(slug) — the agent's work would be gone"
    )

    // A dirty worktree needs `force`, and gets removed with it.
    let dirtySlug = WorktreeManager.slug(role: nil, prompt: "dirty", id: worktreeAgentId("00502"))
    let dirty = try manager.add(repo: repo, slug: dirtySlug)
    try "uncommitted\n".write(to: dirty.path.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    do {
        try manager.remove(repo: repo, path: dirty.path, force: false)
        throw WorktreeCheckError("removing a modified worktree without force succeeded; git should refuse")
    } catch let error as WorktreeManager.WorktreeError {
        guard case .gitFailed = error else {
            throw WorktreeCheckError("expected .gitFailed removing a dirty worktree, got \(error)")
        }
    }
    try manager.remove(repo: repo, path: dirty.path, force: true)
    try worktreeExpect(
        !FileManager.default.fileExists(atPath: dirty.path.path),
        "force remove left the dirty worktree on disk"
    )
}

// MARK: - 7. Porcelain parsing

/// A detached worktree must report `nil`, not a fabricated branch name — the
/// reason `Worktree.branch` is optional at all.
private func runWorktreeListParsingCheck() throws {
    let porcelain = """
    worktree /repo
    HEAD 1111111111111111111111111111111111111111
    branch refs/heads/main

    worktree /repo/.worktrees/fix-auth-1a2b3c4d
    HEAD 2222222222222222222222222222222222222222
    branch refs/heads/agent/fix-auth-1a2b3c4d

    worktree /repo/.worktrees/detached-5e6f7a8b
    HEAD 3333333333333333333333333333333333333333
    detached

    """
    let parsed = WorktreeManager.parseWorktreeList(porcelain)
    try worktreeExpect(parsed.count == 3, "expected 3 records, got \(parsed.count)")
    try worktreeExpect(parsed[0].isMain && parsed[0].branch == "main", "main record wrong: \(parsed[0])")
    try worktreeExpect(!parsed[1].isMain, "only the first record is the main checkout")
    try worktreeExpect(
        parsed[1].branch == "agent/fix-auth-1a2b3c4d",
        "an agent branch under refs/heads/agent/ must keep its slash: \(String(describing: parsed[1].branch))"
    )
    try worktreeExpect(
        parsed[2].branch == nil,
        "a detached worktree must report no branch, got \(String(describing: parsed[2].branch))"
    )
    try worktreeExpect(
        parsed[2].path.path == "/repo/.worktrees/detached-5e6f7a8b",
        "path parsed as \(parsed[2].path.path)"
    )
}

// MARK: - 8. Not a repository

private func runWorktreeInvalidRepositoryCheck() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("continuum-not-a-repo-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = WorktreeManager()

    for operation in ["add", "list"] {
        do {
            if operation == "add" {
                _ = try manager.add(repo: root, slug: "anything-0a0a0a0a")
            } else {
                _ = try manager.list(repo: root)
            }
            throw WorktreeCheckError("\(operation) succeeded outside a repository")
        } catch let error as WorktreeManager.WorktreeError {
            guard case .invalidRepository = error else {
                throw WorktreeCheckError("expected .invalidRepository from \(operation), got \(error)")
            }
        }
    }

    let missing = root.appendingPathComponent("does-not-exist", isDirectory: true)
    do {
        _ = try manager.list(repo: missing)
        throw WorktreeCheckError("list succeeded on a nonexistent path")
    } catch let error as WorktreeManager.WorktreeError {
        guard case .invalidRepository = error else {
            throw WorktreeCheckError("expected .invalidRepository for a missing path, got \(error)")
        }
    }
}
