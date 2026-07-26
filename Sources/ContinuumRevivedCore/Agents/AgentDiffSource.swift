import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P2C.5-per-agent-diff.md
//
// "What did this agent actually change?" — answerable ONLY for an isolated agent
// (P2C.2). A non-isolated agent shares the project's one working tree with the
// human and with every other non-isolated agent, so the repository's diff is not
// attributable to it; this type returns `nil` there rather than handing back
// somebody else's work under an agent's name.
//
// MERGE-BASE, NOT THE BRANCH TIP. `agent/<slug>` is cut from the base branch and
// the base branch keeps moving underneath it. A two-dot `base..agent/<slug>`
// diff would attribute every commit that landed on the base since the fork to
// the agent. `DiffReviewSource.branchVsBase` already emits git's three-dot form
// (`base...branch` in `GitDiffEngine.diff`), which diffs against the merge base —
// that is the reuse, not a re-implementation.
//
// I5 (sync-boundary purity): `Counts` carries three integers and NO PATHS. The
// packet's watch-out is explicit — counts are safe to send to the phone, file
// paths are host-bound and are not. The full `DiffReviewSource` payload is for a
// desktop view; it names branches, never a path.
// Not `Sendable`: `GitDiffEngine` is not, and declaring conformance here would
// mean either an unchecked claim or retrofitting a type this ticket does not own.
public struct AgentDiffSource {
    private let engine: GitDiffEngine

    public init(engine: GitDiffEngine = GitDiffEngine()) {
        self.engine = engine
    }

    /// The review source for an isolated agent's work, or `nil` when the agent is
    /// not isolated.
    ///
    /// Pure — no git, no I/O. `worktreeBranch != nil` is the isolation test, the
    /// same one `AgentRowContext.isIsolated` uses (P2C.4): only the isolated spawn
    /// path sets it.
    ///
    /// `baseBranch` is the caller's to supply because nothing records it: the
    /// worktree is cut from whatever the main checkout was on at spawn time, and
    /// that branch is not stored on the record. Guessing it here — "main", or the
    /// main checkout's branch right now — would silently produce a diff against
    /// the wrong fork point. A caller that wants the live answer asks
    /// `WorktreeManager.currentBranch(repo:)` for the MAIN checkout.
    public static func reviewSource(for record: AgentRecord, baseBranch: String) -> DiffReviewSource? {
        guard let branch = record.worktreeBranch else { return nil }
        return DiffReviewSource(kind: .branchVsBase, branch: branch, baseBranch: baseBranch)
    }

    /// `(filesChanged, insertions, deletions)` for an isolated agent's branch
    /// against its merge base with `baseBranch`, or `nil` when the agent is not
    /// isolated.
    ///
    /// Runs in the agent's OWN checkout (`record.cwd`). A worktree shares the
    /// repository's object store and refs, so the base branch resolves there
    /// without touching the main checkout — and the agent's branch is the one
    /// checked out here, which is where its uncommitted work would live if a
    /// later ticket wants it.
    public func counts(for record: AgentRecord, baseBranch: String) throws -> GitDiffEngine.Counts? {
        guard let source = Self.reviewSource(for: record, baseBranch: baseBranch) else { return nil }
        let repository = URL(fileURLWithPath: record.cwd)
        let gitSource = try source.gitSource(repositoryURL: repository) { _ in
            // Unreachable: `reviewSource` only ever builds `.branchVsBase`, which
            // does not consult the resolver. Throwing rather than returning a
            // plausible branch name means a future kind change fails loudly
            // instead of diffing against something invented here.
            throw GitDiffEngine.DiffError.invalidRepository(record.cwd)
        }
        return try engine.counts(repositoryURL: repository, source: gitSource)
    }

    /// The full diff payload for the same range, for a desktop review view.
    /// `nil` on the same condition as `counts`.
    public func diff(for record: AgentRecord, baseBranch: String) throws -> GitDiffModel? {
        guard let source = Self.reviewSource(for: record, baseBranch: baseBranch) else { return nil }
        let repository = URL(fileURLWithPath: record.cwd)
        let gitSource = try source.gitSource(repositoryURL: repository) { _ in
            throw GitDiffEngine.DiffError.invalidRepository(record.cwd)
        }
        return try engine.diff(repositoryURL: repository, source: gitSource)
    }
}
