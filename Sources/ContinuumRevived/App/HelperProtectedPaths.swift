import ContinuumRevivedCore
import CryptoKit
import Foundation

/// `.plans/117` part 2, stage one: record when a helper changes a check file
/// that already existed when it was delegated and that its contract did not
/// give it. Recording only: nothing is refused, shown or sent to any agent.
///
/// The protected set, per helper:
/// - a path that existed when the helper started (in the baseline commit, or
///   untracked or dirty in its checkout at delegation) and that is a check file:
///   under `Sources/*Checks/`, `scripts/check-*`, `scripts/checks/`,
///   `scripts/test-*`, `scripts/tests/` or `checks/`; a `*Checks.swift` or
///   `*Check.swift` file anywhere under `Sources/` (the app's own checks); the
///   matrix script; a recorded fixture under `scripts/fixtures/`; a pixel
///   baseline under any `baselines/` directory;
///   or named by a `checkFiles` glob in the baseline's coverage manifest;
/// - minus anything inside the contract's `owns` or `shared`;
/// - plus anything inside `mustNotTouch`, which wins over `owns` and `shared`.
/// A file the helper created is never a violation, `mustNotTouch` included.
///
/// Contract paths are matched the way `AgentDelegationContract.claimOverlap`
/// compares them: case-insensitive, a directory covers what is inside it,
/// `.` covers the checkout, and glob characters are compared as written.
///
/// Built and read on the run ledger's queue. Paths that differed from the
/// baseline at delegation are judged by a fingerprint taken then, not by git,
/// so the lead's uncommitted work in a shared checkout is not the helper's.
/// The fingerprint is taken when the ledger queue reaches the delegation; a
/// helper that writes before then is not seen (recorded in the plan as a gap).
///
/// Changes are read from git with rename detection off, so a staged `git mv`
/// of a check reads as its old path deleted (and a new file added). The sweep
/// runs at each report and at each end of the helper's turn, so a helper that
/// never reports is still swept; one that edits and reverts between sweeps is
/// not seen.
///
/// What a row does NOT prove. `unattributed` and `sharedObservedEdit` rows come
/// from a checkout the lead or a sibling also writes: no later stage may treat
/// them as the helper's doing. `observedEdit` means an edit call the helper made
/// named the path; it does not say the call succeeded. When git cannot be read
/// at a sweep, nothing is judged and one `unknown` row says so.
struct HelperProtectedPaths {
    struct Change: Equatable {
        /// Nil only for an `unknown` change.
        var path: String?
        /// modified, deleted, unknown.
        var change: String
        /// checkFile, mustNotTouch; for unknown: noBaseline, baselineUnreadable,
        /// changesUnverifiable.
        var reason: String
        /// observedEdit: its own checkout, and an edit call it made named the path.
        /// git: its own checkout, no edit seen (a shell write, a subagent).
        /// sharedObservedEdit: a shared checkout and an edit call named the path;
        /// another writer is possible.
        /// unattributed: a shared checkout, no edit seen.
        var attribution: String?
    }

    static let gitInvocations = LeadCheckoutWatch.Locked(0)
    static func git(_ arguments: [String], _ root: URL) throws -> Data {
        gitInvocations.withLock { $0 += 1 }
        return try HelperEvidence.git(["--no-optional-locks"] + arguments, root)
    }
    static let conventions = [
        "Sources/*Checks/**", "Sources/**/*Checks.swift", "Sources/**/*Check.swift",
        "scripts/check-*", "scripts/checks/**", "scripts/test-*", "scripts/tests/**", "checks/**",
        "scripts/run-matrix.sh", "scripts/fixtures/**", "**/baselines/**",
    ].compactMap(HelperEvidence.Manifest.glob)

    let root: URL
    let base: String?
    let shared: Bool
    let contract: AgentDelegationContract?
    /// noBaseline or baselineUnreadable; nothing can be judged.
    private(set) var problem: String?
    private var atBase: Set<String> = []
    private var manifestCheckFiles: [NSRegularExpression] = []
    /// Paths that differed from the baseline at delegation: their fingerprint
    /// then, nil when absent.
    private var startedDirty: [String: String?] = [:]
    /// Checkout-relative paths the helper's edit calls named.
    private var edited: Set<String> = []
    private var recorded: Set<String> = []

    init(root: URL, base: String?, shared: Bool, contract: AgentDelegationContract?) {
        self.root = root; self.base = base; self.shared = shared; self.contract = contract
        guard let base else { problem = "noBaseline"; return }
        guard let tree = try? Self.git(["ls-tree", "-r", "-z", "--name-only", base], root),
              let dirty = Self.changed(root: root, base: base) else {
            problem = "baselineUnreadable"; return
        }
        atBase = Set(tree.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
        if let data = try? Self.git(["show", "\(base):\(HelperEvidence.Manifest.relativePath)"], root) {
            manifestCheckFiles = HelperEvidence.Manifest(json: data).entries.flatMap(\.checkFiles)
        }
        // updateValue: a subscript assignment of nil would drop a path absent at delegation.
        for path in dirty { startedDirty.updateValue(fingerprint(path), forKey: path) }
    }

    /// Paths that differ from `base` in the working tree, renames split into a
    /// deletion and an addition, plus untracked files. Nil when git fails.
    static func changed(root: URL, base: String) -> Set<String>? {
        let scope = ["--", ".", ":(exclude).array", ":(exclude).worktrees"]
        guard let diff = try? Self.git(["diff-index", "--name-only", "-z", "--no-renames", "--no-ext-diff", "--no-textconv", base] + scope, root),
              let others = try? Self.git(["ls-files", "--others", "--exclude-standard", "-z"] + scope, root) else { return nil }
        return Set((diff + others).split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
    }

    /// A path inside one of `entries`, as the contract compares paths.
    static func covered(_ path: String, by entries: [String]) -> Bool {
        let path = path.lowercased()
        return entries.contains { entry in
            let entry = entry.lowercased()
            return entry == "." || path == entry || path.hasPrefix(entry + "/")
        }
    }

    /// Why an existing path is protected for this helper, or nil.
    func reason(_ path: String) -> String? {
        if let contract, Self.covered(path, by: contract.mustNotTouch) { return "mustNotTouch" }
        if let contract, Self.covered(path, by: contract.owns + contract.shared) { return nil }
        if HelperEvidence.matches(Self.conventions, path) || HelperEvidence.matches(manifestCheckFiles, path) { return "checkFile" }
        return nil
    }

    /// One of the helper's own tool calls, as the ledger receives it.
    mutating func observe(_ sighting: HelperEvidence.Sighting) {
        guard case let .edit(targets) = sighting.kind else { return }
        for target in targets { if let path = HelperEvidence.relative(target, root: root) { edited.insert(path) } }
    }

    private func fingerprint(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: root.appendingPathComponent(path).path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func exists(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path, isDirectory: &directory) && !directory.boolValue
    }

    /// New violations since the last sweep. Each path and kind of change, and
    /// each unknown reason, is recorded once.
    mutating func sweep() -> [Change] {
        func once(_ change: Change) -> [Change] {
            recorded.insert([change.path ?? "", change.change, change.reason].joined(separator: "\n")).inserted ? [change] : []
        }
        if let problem { return once(Change(path: nil, change: "unknown", reason: problem, attribution: nil)) }
        guard let base, let now = Self.changed(root: root, base: base) else {
            return once(Change(path: nil, change: "unknown", reason: "changesUnverifiable", attribution: nil))
        }
        var found: [Change] = []
        for path in now.union(startedDirty.keys).sorted() {
            let change: String
            if let before = startedDirty[path] {
                let after = fingerprint(path)
                guard before != nil, after != before else { continue }  // created by the helper, or untouched
                change = after == nil ? "deleted" : "modified"
            } else {
                guard atBase.contains(path) else { continue }  // created by the helper
                change = exists(path) ? "modified" : "deleted"
            }
            guard let reason = reason(path) else { continue }
            let attribution = edited.contains(path) ? (shared ? "sharedObservedEdit" : "observedEdit") : (shared ? "unattributed" : "git")
            found += once(Change(path: path, change: change, reason: reason, attribution: attribution))
        }
        return found
    }
}

extension ManagedRunLedger {
    /// The `protectedPathChanged` rows for one sweep: one per path, with the
    /// checkout-relative path, `modified` or `deleted`, why and how attributed;
    /// or one `unknown` row, with no path, when nothing could be judged.
    /// `trigger` is `report` or `turnEnded`.
    static func protectedPathRows(_ changes: [HelperProtectedPaths.Change], task: UUID, agent: UUID, part: UUID?,
                                  at: Date, trigger: String) -> [Row] {
        changes.map { change in
            var row = Row(kind: "protectedPathChanged", task: task, agent: agent, part: part,
                          source: "protected/\(agent)/\(at.timeIntervalSinceReferenceDate)/\(change.change)/\(change.path ?? change.reason)")
            row.paths = change.path.map { [$0] }
            row.outcome = change.change
            var evidence = ["reason": change.reason, "trigger": trigger]
            if let attribution = change.attribution { evidence["attribution"] = attribution }
            row.evidence = evidence
            return row
        }
    }
}
