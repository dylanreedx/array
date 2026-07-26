import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P2C.5-per-agent-diff.md
//
// Every git-touching check here runs against a TEMP `git init` repository built
// per check and deleted after (P2C.1's inherited trap: `git worktree add` is
// never pointed at the real repository). `makeWorktreeTempRepo` / `runTempGit`
// are `WorktreeManagerChecks`' own helpers, reused rather than copied.
//
// Five properties:
//   1. An isolated agent reports ACCURATE counts — files, insertions and
//      deletions measured against real commits in its own worktree.
//   2. THE MERGE BASE, not the branch tip: commits landing on the base branch
//      after the fork do not move the agent's numbers. Asserted with a
//      discriminator — the two-dot diff of the same pair IS different, so the
//      property cannot pass by the base having stayed still.
//   3. A non-isolated agent reports `nil`, from both `counts` and
//      `reviewSource`. The repository diff belongs to whoever touched it.
//   4. `parseNumstat` is pure and handles git's real output: a binary file
//      (`-`/`-`) is a changed file with no line counts, and a rename row counts
//      once.
//   5. An agent forked from a branch that is NOT `main` reports its own counts
//      against THAT branch, and reports different (wrong) ones against `main` —
//      so the caller's obligation to name the real fork point is executable
//      rather than a comment. See the owner note at that check.

func runAgentDiffSourceChecks() {
    do {
        try runAgentDiffNumstatParsingCheck()
        try runAgentDiffNonIsolatedCheck()
        try runAgentDiffIsolatedCountsCheck()
        try runAgentDiffMergeBaseCheck()
        try runAgentDiffNonMainForkCheck()
        print("AgentDiffSource checks: numstat parsing, non-isolated nil, isolated counts, merge-base attribution, and a non-main fork point passed")
    } catch {
        fputs("FAIL: AgentDiffSource checks failed: \(error)\n", stderr)
        Foundation.exit(1)
    }
}

private func diffExpect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw WorktreeCheckError(message()) }
}

private func diffAgentRecord(cwd: String, worktreeBranch: String?) -> AgentRecord {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    return AgentRecord(
        id: AgentID(rawValue: UUID(uuidString: "A0000000-0000-4000-8000-00000000d1ff")!),
        displayName: "implementer",
        role: "implementer",
        model: "openai-codex/gpt-5.6-sol",
        thinking: "medium",
        cwd: cwd,
        worktreeBranch: worktreeBranch,
        createdAt: now,
        lastActivityAt: now
    )
}

/// Commits `files` (path -> full contents) in `directory`, with an identity that
/// does not depend on the host's global git config.
private func diffCommit(_ files: [String: String], in directory: URL, message: String) throws {
    for (path, contents) in files {
        try contents.write(to: directory.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    // Named paths, never `-A`: a commit in the MAIN checkout would otherwise pick
    // up `<repo>/.worktrees/<slug>` as a gitlink (measured: the two-dot
    // discriminator reported 4 files / 5 deletions instead of 3 / 4). The real
    // repository gitignores that directory; a bare `git init` does not.
    try runTempGit(["add", "--"] + files.keys.sorted(), in: directory)
    try runTempGit([
        "-c", "user.email=qa@continuum.test",
        "-c", "user.name=Continuum QA",
        "commit", "-q", "--no-gpg-sign", "-m", message,
    ], in: directory)
}

// MARK: - 4. numstat parsing

/// Negative test observed red with the final code: with the binary row dropped
/// (`guard Int(fields[0]) != nil else { continue }`) this check reported
///   FAIL: AgentDiffSource checks failed: a binary file is still a changed file —
///   got 2 file(s), expected 3
private func runAgentDiffNumstatParsingCheck() throws {
    let output = """
    12\t3\tSources/App.swift
    -\t-\tdocs/screenshot.png
    4\t0\tSources/{Old.swift => New.swift}
    not-a-numstat-line
    """
    let counts = GitDiffEngine.parseNumstat(output)
    try diffExpect(
        counts.filesChanged == 3,
        "a binary file is still a changed file — got \(counts.filesChanged) file(s), expected 3"
    )
    try diffExpect(
        counts.insertions == 16,
        "insertions summed wrong — got \(counts.insertions), expected 16"
    )
    try diffExpect(
        counts.deletions == 3,
        "deletions summed wrong — got \(counts.deletions), expected 3"
    )
    try diffExpect(
        GitDiffEngine.parseNumstat("") == GitDiffEngine.Counts.zero,
        "an empty diff must be zero counts, not a phantom file"
    )
}

// MARK: - 3. A non-isolated agent has no attributable diff

/// Negative test observed red with the final code: with `reviewSource` falling
/// back to `DiffReviewSource(kind: .workingTreeVsHEAD)` instead of returning nil,
/// this check reported
///   FAIL: AgentDiffSource checks failed: a non-isolated agent must have NO
///   review source — got Optional(...workingTreeVsHEAD...)
///
/// No repository is needed: the answer must come from the record alone, without a
/// git call. `cwd` points at a directory that does not exist, so a `counts` that
/// shelled out anyway would throw rather than return nil.
private func runAgentDiffNonIsolatedCheck() throws {
    let record = diffAgentRecord(cwd: "/nonexistent/continuum-p2c5", worktreeBranch: nil)
    let source = AgentDiffSource.reviewSource(for: record, baseBranch: "main")
    try diffExpect(
        source == nil,
        "a non-isolated agent must have NO review source — got \(String(describing: source))"
    )
    let counts = try AgentDiffSource().counts(for: record, baseBranch: "main")
    try diffExpect(
        counts == nil,
        "a non-isolated agent must report nil counts — got \(String(describing: counts))"
    )
}

// MARK: - 1. Accurate counts for an isolated agent

/// Negative test observed red with the final code: with `counts` passing
/// `.workingTreeVsHEAD` instead of the record's branch range, this check reported
///   FAIL: AgentDiffSource checks failed: filesChanged — got 0, expected 2
private func runAgentDiffIsolatedCountsCheck() throws {
    let repo = try makeWorktreeTempRepo()
    defer { try? FileManager.default.removeItem(at: repo) }

    let worktree = try WorktreeManager().add(repo: repo, slug: "per-agent-diff-0d1ff000")
    let record = diffAgentRecord(cwd: worktree.path.path, worktreeBranch: worktree.branch)

    // README.md is "seed\n" in the base commit: rewriting it is 1 insertion and
    // 1 deletion, and a.txt is 3 fresh lines. Two files, 4 insertions, 1 deletion.
    try diffCommit(
        ["a.txt": "one\ntwo\nthree\n", "README.md": "changed\n"],
        in: worktree.path,
        message: "agent work"
    )

    let source = AgentDiffSource.reviewSource(for: record, baseBranch: "main")
    try diffExpect(source?.kind == .branchVsBase, "an isolated agent's review source must be branchVsBase — got \(String(describing: source?.kind))")
    try diffExpect(source?.branch == worktree.branch, "the review source must name the AGENT's branch — got \(String(describing: source?.branch))")
    try diffExpect(source?.baseBranch == "main", "the review source must name the base branch — got \(String(describing: source?.baseBranch))")

    guard let counts = try AgentDiffSource().counts(for: record, baseBranch: "main") else {
        throw WorktreeCheckError("an isolated agent must report counts, got nil")
    }
    try diffExpect(counts.filesChanged == 2, "filesChanged — got \(counts.filesChanged), expected 2")
    try diffExpect(counts.insertions == 4, "insertions — got \(counts.insertions), expected 4")
    try diffExpect(counts.deletions == 1, "deletions — got \(counts.deletions), expected 1")

    // The full payload is the same range, so the two answers cannot disagree about
    // what the agent changed.
    guard let model = try AgentDiffSource().diff(for: record, baseBranch: "main") else {
        throw WorktreeCheckError("an isolated agent must report a diff payload, got nil")
    }
    try diffExpect(
        model.files.count == counts.filesChanged,
        "the payload and the counts disagree — \(model.files.count) file(s) vs \(counts.filesChanged)"
    )
}

// MARK: - 2. The merge base, not the moving base branch tip

/// Negative test observed red with the final code: with `GitDiffEngine.counts`
/// emitting the two-dot `\(base)..\(branch)` range, this check reported
///   FAIL: AgentDiffSource checks failed: a commit on the base branch after the
///   fork was attributed to the agent — filesChanged 3, expected 2
private func runAgentDiffMergeBaseCheck() throws {
    let repo = try makeWorktreeTempRepo()
    defer { try? FileManager.default.removeItem(at: repo) }

    let worktree = try WorktreeManager().add(repo: repo, slug: "merge-base-0d1ff001")
    let record = diffAgentRecord(cwd: worktree.path.path, worktreeBranch: worktree.branch)

    try diffCommit(
        ["a.txt": "one\ntwo\nthree\n", "README.md": "changed\n"],
        in: worktree.path,
        message: "agent work"
    )
    // Somebody else's work, landing on the base branch AFTER the agent forked.
    try diffCommit(
        ["base.txt": "not\nthe\nagent's\n"],
        in: repo,
        message: "base moves on"
    )

    guard let counts = try AgentDiffSource().counts(for: record, baseBranch: "main") else {
        throw WorktreeCheckError("an isolated agent must report counts, got nil")
    }
    try diffExpect(
        counts.filesChanged == 2,
        "a commit on the base branch after the fork was attributed to the agent — filesChanged \(counts.filesChanged), expected 2"
    )
    try diffExpect(
        counts.insertions == 4 && counts.deletions == 1,
        "the agent's line counts moved when the base branch did — \(counts.insertions)/+\(counts.deletions)-, expected 4/1"
    )

    // Discriminator: the property above must not be able to pass because the base
    // branch happened to stay still. The two-dot range over the SAME pair reports
    // the base's commit as the agent deleting a file it never saw.
    let twoDot = GitDiffEngine.parseNumstat(try runTempGit(
        ["diff", "--numstat", "main..\(worktree.branch ?? "")"],
        in: worktree.path
    ))
    try diffExpect(
        twoDot.filesChanged == 3 && twoDot.deletions == 4,
        "the discriminator is not discriminating: the two-dot range reports \(twoDot.filesChanged) file(s)/\(twoDot.deletions) deletion(s), expected 3/4 — the base branch never moved, so the merge-base assertion above proves nothing"
    )
}

// MARK: - 5. The fork point is the CALLER's to name, and it matters

/// OWNER NOTE (from the codex cross-review of this ticket): nothing records the
/// branch an isolated agent forked from. `WorktreeManager.add` cuts `agent/<slug>`
/// from whatever the main checkout's HEAD was at spawn time, and neither
/// `AgentRecord` nor `AgentSupervisor` keeps that name. So `counts` takes the base
/// branch from its caller and this check makes the consequence measurable rather
/// than a comment: an agent forked from `release/foo` reports ITS OWN work against
/// `release/foo`, and reports somebody else's against `main`.
///
/// This ticket does not close that hole — recording a fork point means a field on
/// `AgentRecord` (P2A.1's schema) set by the spawn path (P2C.2), and this packet's
/// `## Files` name neither. Refusing to guess is the part that belongs here: a
/// `baseBranch` defaulted to "main", or read from the main checkout at RENDER time,
/// would silently produce the wrong number below instead of making the caller say
/// which fork point it means.
///
/// Negative test observed red with the final code: with `reviewSource` ignoring its
/// `baseBranch` argument and hardcoding `baseBranch: "main"`, this check reported
///   FAIL: AgentDiffSource checks failed: an agent forked from release/foo must
///   report ITS OWN work against release/foo — filesChanged 3, expected 2
///   (+6/-1, expected 4/1)
private func runAgentDiffNonMainForkCheck() throws {
    let repo = try makeWorktreeTempRepo()
    defer { try? FileManager.default.removeItem(at: repo) }

    // The project is NOT on main when the agent is spawned.
    try runTempGit(["checkout", "-q", "-b", "release/foo"], in: repo)
    try diffCommit(["release.txt": "release\nonly\n"], in: repo, message: "release work")

    let worktree = try WorktreeManager().add(repo: repo, slug: "non-main-fork-0d1ff002")
    let record = diffAgentRecord(cwd: worktree.path.path, worktreeBranch: worktree.branch)
    try diffCommit(
        ["a.txt": "one\ntwo\nthree\n", "README.md": "changed\n"],
        in: worktree.path,
        message: "agent work"
    )

    let source = AgentDiffSource()
    guard let correct = try source.counts(for: record, baseBranch: "release/foo") else {
        throw WorktreeCheckError("an isolated agent must report counts, got nil")
    }
    try diffExpect(
        correct.filesChanged == 2 && correct.insertions == 4 && correct.deletions == 1,
        "an agent forked from release/foo must report ITS OWN work against release/foo — filesChanged \(correct.filesChanged), expected 2 (+\(correct.insertions)/-\(correct.deletions), expected 4/1)"
    )

    // The same agent, measured against the wrong fork point. `release.txt` is not
    // this agent's work, and the number says so.
    guard let wrong = try source.counts(for: record, baseBranch: "main") else {
        throw WorktreeCheckError("an isolated agent must report counts, got nil")
    }
    try diffExpect(
        wrong.filesChanged == 3 && wrong.insertions == 6,
        "naming the wrong base branch must visibly change the answer — got \(wrong.filesChanged) file(s)/+\(wrong.insertions), expected 3/+6; if these matched the correct base the caller's fork-point obligation would be untestable"
    )
}
