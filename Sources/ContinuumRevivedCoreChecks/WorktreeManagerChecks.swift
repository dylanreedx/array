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
//
// P2C.3 (docs/38-tickets/90-agent-ux/P2C.3-worktree-cleanup.md) adds three more:
//   9. `isMerged` is true for a branch with no commits of its own and false the
//      moment it carries one; `deleteBranch` REFUSES an unmerged branch (it is
//      `git branch -d`, never `-D`), so no caller bug can discard agent commits.
//  10. `orphans` reports only container worktrees with no known agent behind
//      them: never the main checkout, never a worktree elsewhere in the repo,
//      and never a live agent whose recorded `cwd` is the unresolved form of
//      the path git reports.
//  11. `repair` deletes a clean orphan, RETAINS a dirty one with a reason, keeps
//      every branch, and prunes the admin record of one whose directory is gone.
//
// P2C.4 (docs/38-tickets/90-agent-ux/P2C.4-branch-on-rows.md) adds one:
//  12. `currentBranch` reports a checkout's branch (nil when detached), a fresh
//      worktree is on the branch `add` created, an agent that checks out something
//      else is visible as such, git REFUSES the main checkout onto a branch a
//      worktree holds, and `CheckedOutBranchCache` serves repeats from cache.

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
        try runWorktreeMergedBranchCheck()
        try runWorktreeOrphanCheck()
        try runWorktreeRepairCheck()
        try runWorktreeCurrentBranchCheck()
        print("WorktreeManager checks: slug purity/determinism, add+list, duplicate slug, existing branch, remove, porcelain parsing, invalid repository, merged-branch deletion, orphan detection, repair, and the checked-out branch + its cache passed")
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

// MARK: - 9. Merged-only branch deletion (P2C.3)

/// The packet's headline prohibition: **never `git branch -D` unmerged work.**
///
/// Both safe cases and the unsafe one are exercised on a real repository, in the
/// order the archive path takes them (remove the checkout, then decide about the
/// branch), because a branch checked out in a worktree cannot be deleted at all.
///
/// Negative test observed red with the final code: with `deleteBranch` shelling
/// out to `git branch -D` instead of `-d`, this check reported
///   FAIL: WorktreeManager checks failed: deleteBranch destroyed unmerged branch
///   agent/carries-a-commit-9dbcd1a1 — `git branch -d` must refuse it
private func runWorktreeMergedBranchCheck() throws {
    let repo = try makeWorktreeTempRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    let manager = WorktreeManager()

    // (a) A branch with no commits of its own still points at the commit it was cut
    // from, so it is merged by definition and safe to delete.
    let emptySlug = WorktreeManager.slug(role: nil, prompt: "no commits", id: worktreeAgentId("00601"))
    let empty = try manager.add(repo: repo, slug: emptySlug)
    let emptyBranch = "agent/\(emptySlug)"
    try worktreeExpect(
        try manager.isMerged(repo: repo, branch: emptyBranch),
        "a branch with no commits of its own reads as unmerged"
    )
    try manager.remove(repo: repo, path: empty.path, force: false)
    try manager.deleteBranch(repo: repo, branch: emptyBranch)
    try worktreeExpect(
        !(try manager.branchExists(repo: repo, branch: emptyBranch)),
        "branch \(emptyBranch) survived deleteBranch"
    )

    // (b) One commit in the worktree, and the branch must be REFUSED.
    let workSlug = WorktreeManager.slug(role: nil, prompt: "carries a commit", id: worktreeAgentId("00602"))
    let work = try manager.add(repo: repo, slug: workSlug)
    let workBranch = "agent/\(workSlug)"
    try "the agent's work\n".write(to: work.path.appendingPathComponent("agent.txt"), atomically: true, encoding: .utf8)
    try runTempGit(["add", "agent.txt"], in: work.path)
    try runTempGit([
        "-c", "user.email=qa@continuum.test",
        "-c", "user.name=Continuum QA",
        "commit", "-q", "--no-gpg-sign", "-m", "agent work",
    ], in: work.path)
    try worktreeExpect(
        !(try manager.isMerged(repo: repo, branch: workBranch)),
        "a branch carrying a commit the repository does not have reads as merged"
    )
    // Committed, so the tree is clean and `remove` succeeds without force — which is
    // exactly the packet's "worktree gone but branch retained" case.
    try manager.remove(repo: repo, path: work.path, force: false)
    do {
        try manager.deleteBranch(repo: repo, branch: workBranch)
        throw WorktreeCheckError("deleteBranch destroyed unmerged branch \(workBranch) — `git branch -d` must refuse it")
    } catch let error as WorktreeManager.WorktreeError {
        guard case .gitFailed = error else {
            throw WorktreeCheckError("expected .gitFailed refusing an unmerged branch, got \(error)")
        }
    }
    try worktreeExpect(
        try manager.branchExists(repo: repo, branch: workBranch),
        "the refused deleteBranch still removed \(workBranch)"
    )

    // (c) Once the repository has the work, the same branch becomes deletable —
    // proof that (b) refused because of mergedness, not because of the name.
    try runTempGit([
        "-c", "user.email=qa@continuum.test",
        "-c", "user.name=Continuum QA",
        "merge", "-q", "--no-ff", "--no-gpg-sign", "-m", "merge agent", workBranch,
    ], in: repo)
    try worktreeExpect(
        try manager.isMerged(repo: repo, branch: workBranch),
        "\(workBranch) still reads as unmerged after being merged into HEAD"
    )
    try manager.deleteBranch(repo: repo, branch: workBranch)
    try worktreeExpect(
        !(try manager.branchExists(repo: repo, branch: workBranch)),
        "a merged branch was not deleted"
    )
}

// MARK: - 10. Orphan detection (P2C.3)

/// An orphan is a container worktree with no agent record behind it. What must
/// NEVER be one: the main checkout, a worktree a human put elsewhere in the
/// repository, or a live agent whose record stores the unresolved form of the path
/// git reports.
///
/// Negative test observed red with the final code: with `orphans` comparing raw
/// `path` strings instead of `WorktreeManager.resolved`, this check reported
///   FAIL: WorktreeManager checks failed: expected exactly 1 orphan, got
///   [".../.worktrees/known-work-28b005bd@agent/known-work-28b005bd",
///    ".../.worktrees/record-deleted-25b00104@agent/record-deleted-25b00104"]
/// — the count guard fires before the named LIVE-agent assertion below, which is the
/// same defect reported at a coarser grain.
private func runWorktreeOrphanCheck() throws {
    let repo = try makeWorktreeTempRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    let manager = WorktreeManager()

    let knownSlug = WorktreeManager.slug(role: nil, prompt: "known work", id: worktreeAgentId("00701"))
    let known = try manager.add(repo: repo, slug: knownSlug)
    let goneSlug = WorktreeManager.slug(role: nil, prompt: "record deleted", id: worktreeAgentId("00702"))
    let gone = try manager.add(repo: repo, slug: goneSlug)

    // A worktree inside the repository but NOT under `.worktrees/`: somebody else's,
    // and not this manager's to classify.
    let side = repo.appendingPathComponent("side-tree", isDirectory: true)
    try runTempGit(["worktree", "add", "-q", "-b", "side", side.path], in: repo)

    // The known set holds the path as a RECORD would: the /var form the spawn was
    // given, not the /private/var form git reports.
    let orphans = try manager.orphans(repo: repo, knownAgents: [known.path.path])
    guard orphans.count == 1 else {
        throw WorktreeCheckError("expected exactly 1 orphan, got \(orphans.map { "\($0.path.path)@\($0.branch ?? "detached")" })")
    }
    try worktreeExpect(
        resolved(orphans[0].path) == resolved(gone.path),
        "orphans reported \(orphans[0].path.path), expected \(gone.path.path)"
    )
    try worktreeExpect(
        orphans[0].branch == "agent/\(goneSlug)",
        "the orphan does not name its branch: \(String(describing: orphans[0].branch))"
    )
    try worktreeExpect(
        !orphans.contains(where: { resolved($0.path) == resolved(known.path) }),
        "orphans reported the LIVE agent at \(resolved(known.path)) — the known set stores the unresolved \(known.path.path) git does not use"
    )

    // With NO agents known at all, both container worktrees are orphans — and the
    // main checkout and the side worktree still are not. Without this the check
    // could pass on an implementation that simply reports one thing.
    let all = try manager.orphans(repo: repo, knownAgents: [])
    try worktreeExpect(all.count == 2, "with no known agents both container worktrees are orphans, got \(all.count)")
    try worktreeExpect(
        !all.contains(where: { resolved($0.path) == resolved(repo) }),
        "orphans reported the MAIN checkout \(repo.path)"
    )
    try worktreeExpect(
        !all.contains(where: { resolved($0.path) == resolved(side) }),
        "orphans reported \(side.path), a worktree outside \(WorktreeManager.containerDirectoryName)/ that no agent created"
    )
}

// MARK: - 11. Repair (P2C.3)

/// `repair` frees disk without discarding work: a clean orphan goes, a dirty one is
/// retained and named, every branch survives, and an orphan whose directory has
/// already gone is pruned out of git's admin records.
///
/// Negative test observed red with the final code: with `repair` passing
/// `force: true` to `remove`, this check reported
///   FAIL: WorktreeManager checks failed: repair removed
///   [".../.worktrees/clean-orphan-67a39cf7", ".../.worktrees/dirty-orphan-66a39b64"],
///   expected only .../.worktrees/clean-orphan-67a39cf7
/// — the `removed` list is asserted before the retention guard below, so the dirty
/// orphan is named there first.
private func runWorktreeRepairCheck() throws {
    let repo = try makeWorktreeTempRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    let manager = WorktreeManager()

    let keptSlug = WorktreeManager.slug(role: nil, prompt: "still has an agent", id: worktreeAgentId("00801"))
    let kept = try manager.add(repo: repo, slug: keptSlug)
    let cleanSlug = WorktreeManager.slug(role: nil, prompt: "clean orphan", id: worktreeAgentId("00802"))
    let clean = try manager.add(repo: repo, slug: cleanSlug)
    let dirtySlug = WorktreeManager.slug(role: nil, prompt: "dirty orphan", id: worktreeAgentId("00803"))
    let dirty = try manager.add(repo: repo, slug: dirtySlug)
    try "uncommitted work nobody has seen\n".write(
        to: dirty.path.appendingPathComponent("README.md"),
        atomically: true,
        encoding: .utf8
    )
    let vanishedSlug = WorktreeManager.slug(role: nil, prompt: "directory deleted", id: worktreeAgentId("00804"))
    let vanished = try manager.add(repo: repo, slug: vanishedSlug)

    // The comparable forms are captured while every directory still exists: this
    // check's own `resolved` is the naive one, and a path that has been deleted
    // (which is the point of two of these three orphans) cannot be resolved after
    // the fact. Capturing first keeps the expectation independent of the
    // canonicalisation the manager itself uses.
    let expectedClean = resolved(clean.path)
    let expectedDirty = resolved(dirty.path)
    let expectedVanished = resolved(vanished.path)

    // Deleted behind git's back: `list` still reports it, and only `prune` clears it.
    try FileManager.default.removeItem(at: vanished.path)

    let report = try manager.repair(repo: repo, knownAgents: [kept.path.path])

    try worktreeExpect(report.found.count == 3, "repair found \(report.found.count) orphans, expected 3")
    try worktreeExpect(
        report.removed.map { WorktreeManager.resolved($0) } == [expectedClean],
        "repair removed \(report.removed.map(\.path)), expected only \(expectedClean)"
    )
    try worktreeExpect(
        !FileManager.default.fileExists(atPath: clean.path.path),
        "the clean orphan is still on disk after repair"
    )
    try worktreeExpect(
        report.pruned.map { WorktreeManager.resolved($0) } == [expectedVanished],
        "repair pruned \(report.pruned.map(\.path)), expected only \(expectedVanished)"
    )
    guard report.retained.count == 1, resolved(report.retained[0].path) == expectedDirty else {
        throw WorktreeCheckError("repair force-removed the dirty orphan \(expectedDirty) — uncommitted work must be retained and reported")
    }
    try worktreeExpect(
        !report.retained[0].reason.isEmpty,
        "a retained orphan was reported without a reason"
    )
    try worktreeExpect(
        FileManager.default.fileExists(atPath: dirty.path.appendingPathComponent("README.md").path),
        "the dirty orphan's uncommitted file is gone"
    )

    // Not one branch was deleted, in any of the three cases.
    for slug in [cleanSlug, dirtySlug, vanishedSlug] {
        try worktreeExpect(
            try manager.branchExists(repo: repo, branch: "agent/\(slug)"),
            "repair deleted branch agent/\(slug) — it is all that is left of that agent's work"
        )
        try worktreeExpect(
            report.branchesKept.contains("agent/\(slug)"),
            "repair did not report keeping agent/\(slug): \(report.branchesKept)"
        )
    }

    // The live agent is untouched, and git's own view matches the report.
    try worktreeExpect(
        FileManager.default.fileExists(atPath: kept.path.appendingPathComponent("README.md").path),
        "repair damaged the live agent's worktree"
    )
    let listed = try manager.list(repo: repo).map { resolved($0.path) }
    try worktreeExpect(
        listed.sorted() == [resolved(repo), resolved(kept.path), resolved(dirty.path)].sorted(),
        "after repair git lists \(listed), expected the main checkout, the live agent, and the retained dirty orphan"
    )
}

// MARK: - 12. The checked-out branch, and its cache (P2C.4)

/// What a branch chip renders, and the two facts that decide WHICH checkout it is
/// compared against.
///
/// Five properties:
///   (a) `currentBranch` reports the short name for a normal checkout and nil —
///       never the literal "HEAD" — when detached.
///   (b) A freshly added worktree's HEAD IS the branch `add` recorded, so the
///       ordinary isolated agent MATCHES and shows no warning. This is the state
///       P2C.4's chip calls "isolated, matching".
///   (c) A `git checkout` inside that worktree moves it, and `currentBranch`
///       follows — the mismatch the chip warns about is a real reachable state,
///       not a hypothetical.
///   (d) MEASURED GIT FACT, recorded because it rules out the other candidate
///       comparison: the MAIN checkout cannot be moved onto an agent's branch at
///       all (git refuses a branch already checked out in another worktree). So
///       comparing an isolated agent's branch against the main checkout's would
///       flag every isolated agent forever, and the comparison is against the
///       agent's OWN checkout instead.
///   (e) `CheckedOutBranchCache` answers a repeat read from cache — asserted with
///       its own `gitReads` counter — while a changed checkout is picked up once
///       the entry is invalidated, and an unreadable path is cached as nil rather
///       than re-launching git per render.
private func runWorktreeCurrentBranchCheck() throws {
    let repo = try makeWorktreeTempRepo()
    defer { try? FileManager.default.removeItem(at: repo) }
    let manager = WorktreeManager()

    // (a)
    let seedBranch = try manager.currentBranch(repo: repo)
    try worktreeExpect(seedBranch == "main", "the seed repository reads as \(String(describing: seedBranch)), not main")
    let head = try runTempGit(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
    try runTempGit(["checkout", "-q", "--detach", head], in: repo)
    let detached = try manager.currentBranch(repo: repo)
    try worktreeExpect(
        detached == nil,
        "a detached HEAD must read as nil, got \(String(describing: detached)) — the literal \"HEAD\" is not a branch name"
    )
    try runTempGit(["checkout", "-q", "main"], in: repo)

    // (b)
    let slug = WorktreeManager.slug(role: "implementer", prompt: "fix auth", id: worktreeAgentId("00701"))
    let worktree = try manager.add(repo: repo, slug: slug)
    let branch = WorktreeManager.branchName(slug: slug)
    let fresh = try manager.currentBranch(repo: worktree.path)
    try worktreeExpect(
        fresh == branch,
        "a fresh worktree is on \(String(describing: fresh)), not the branch add created (\(branch))"
    )
    let mainAfterAdd = try manager.currentBranch(repo: repo)
    try worktreeExpect(
        mainAfterAdd == "main",
        "adding a worktree moved the MAIN checkout to \(String(describing: mainAfterAdd))"
    )

    // (d) — asserted before (c) so the worktree is still on its own branch.
    var mainCheckoutRefused: String?
    do {
        _ = try runTempGit(["checkout", branch], in: repo)
    } catch let error as WorktreeCheckError {
        mainCheckoutRefused = error.description
    }
    guard let refusal = mainCheckoutRefused else {
        throw WorktreeCheckError(
            "git let the MAIN checkout move onto \(branch) while a worktree holds it — if that were "
                + "allowed, comparing an isolated agent against the main checkout would be a usable rule"
        )
    }
    try worktreeExpect(
        refusal.contains("already used by worktree"),
        "the main checkout refused \(branch) for an unexpected reason: \(refusal)"
    )
    let mainAfterRefusal = try manager.currentBranch(repo: repo)
    try worktreeExpect(
        mainAfterRefusal == "main",
        "the refused checkout still moved the main checkout to \(String(describing: mainAfterRefusal))"
    )

    // (c)
    try runTempGit(["checkout", "-q", "-b", "wandered-off"], in: worktree.path)
    let wandered = try manager.currentBranch(repo: worktree.path)
    try worktreeExpect(
        wandered == "wandered-off",
        "an agent that checked out another branch still reads as \(String(describing: wandered))"
    )

    // (e)
    let clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let cache = CheckedOutBranchCache(ttl: 2)
    try worktreeExpect(cache.gitReads == 0, "a fresh cache has already run git \(cache.gitReads) time(s)")
    try worktreeExpect(cache.branch(repo: repo, now: clock) == "main", "the cache's first read is wrong")
    try worktreeExpect(cache.gitReads == 1, "the first read took \(cache.gitReads) git call(s), expected 1")
    for offset in [0.0, 0.5, 1.9] {
        try worktreeExpect(
            cache.branch(repo: repo, now: clock.addingTimeInterval(offset)) == "main",
            "a cached read inside the TTL changed its answer at +\(offset)s"
        )
    }
    try worktreeExpect(
        cache.gitReads == 1,
        "three reads inside the TTL cost \(cache.gitReads) git call(s) — a header re-render must not shell out"
    )
    // A second repository is a second entry, not a cache hit on the first.
    try worktreeExpect(
        cache.branch(repo: worktree.path, now: clock) == "wandered-off",
        "the cache answered for the wrong repository"
    )
    try worktreeExpect(cache.gitReads == 2, "a different repository must be its own read, got \(cache.gitReads)")
    // Past the TTL, and a checkout that moved underneath it.
    try runTempGit(["checkout", "-q", "-b", "moved-on"], in: repo)
    try worktreeExpect(
        cache.branch(repo: repo, now: clock.addingTimeInterval(1.0)) == "main",
        "the cache abandoned a valid entry when the checkout moved — the TTL is what expires it"
    )
    try worktreeExpect(
        cache.branch(repo: repo, now: clock.addingTimeInterval(2.5)) == "moved-on",
        "past the TTL the cache still reports the old branch"
    )
    // A backwards clock (sleep/wake, an NTP step) must not make a future-stamped
    // entry immortal — the same guard `CrossProjectManagedSessionWalk` carries.
    try worktreeExpect(
        cache.branch(repo: repo, now: clock.addingTimeInterval(-3600)) == "moved-on",
        "an entry stamped in the future was served to a read before it"
    )
    let readsBeforeInvalidate = cache.gitReads
    cache.invalidate()
    _ = cache.branch(repo: repo, now: clock.addingTimeInterval(2.5))
    try worktreeExpect(
        cache.gitReads == readsBeforeInvalidate + 1,
        "invalidate() did not force a re-read"
    )
    // An unreadable path: nil, cached, and never thrown at a renderer.
    let missing = repo.appendingPathComponent("not-a-checkout", isDirectory: true)
    let readsBeforeMissing = cache.gitReads
    try worktreeExpect(cache.branch(repo: missing, now: clock) == nil, "a path that is not a repository resolved a branch")
    try worktreeExpect(cache.branch(repo: missing, now: clock) == nil, "the second read of a missing path disagreed with the first")
    try worktreeExpect(
        cache.gitReads == readsBeforeMissing + 1,
        "a nil answer is not cached — \(cache.gitReads - readsBeforeMissing) git call(s) for two reads of a missing path"
    )
}
