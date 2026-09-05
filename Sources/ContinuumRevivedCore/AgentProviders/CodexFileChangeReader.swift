import Foundation

// Ticket: TR-01 — one reader for codex's `changes[]`, shared by the exec and
// app-server translators.
//
// It was two copies, and they had already drifted from the wire: exec sends
// `"kind": "add"` while app-server sends `"kind": {"type": "add"}` (see
// `codex-appserver-single-agent.jsonl`), and both copies read `kind` as a
// String — so every app-server file change was reported as an UNKNOWN action
// while the capture that proves otherwise sat in the checks fixtures.
enum CodexFileChangeReader {
    static func fileDetails(_ item: [String: Any]) -> [AgentToolDetailObservation.FileChange] {
        guard let changes = item["changes"] as? [[String: Any]] else { return [] }
        return changes.compactMap { change in
            guard let path = change["path"] as? String, !path.isEmpty else { return nil }
            let diff = change["diff"] as? String
            // Only a real unified diff yields counts. Codex's `diff` shape is
            // not pinned by any capture we hold, so an unrecognised body leaves
            // the counts unknown rather than inventing "+1 −0" for it. The
            // preview is bounded downstream (80 lines / 2 000 chars), so a
            // count taken from a body at that ceiling is a floor, not a total.
            let counts = diff.flatMap(AgentFileChangeCounting.unifiedDiffCounts)
            let truncated = diff.map {
                $0.utf8.count >= AgentToolDetailObservation.FileChange.maxDiffCharacters
                    || $0.split(separator: "\n", omittingEmptySubsequences: false).count > 80
            } ?? false
            return .init(
                action: action(change),
                path: path,
                renamePath: (change["new_path"] as? String) ?? (change["newPath"] as? String)
                    ?? (change["to"] as? String),
                diffPreview: diff,
                addedLines: counts?.added,
                removedLines: counts?.removed,
                countsAreLowerBound: counts != nil && truncated
            )
        }
    }

    /// TR-01 — codex's `apply_patch` envelope, which is the ONLY place codex
    /// states what a file change actually did.
    ///
    /// Captured live from codex-cli 0.153.4 on 2026-09-05: the exec stream's
    /// `file_change` item carries `changes[].path` and `kind` and NOTHING else —
    /// no `diff` field at all — so a live codex card cannot have counts. The
    /// rollout, however, records the patch verbatim:
    ///
    ///     *** Begin Patch
    ///     *** Update File: /abs/notes.txt
    ///     @@
    ///     -alpha
    ///     +ALPHA
    ///      beta
    ///     +gamma
    ///     *** Add File: /abs/extra.txt
    ///     +hello
    ///     *** End Patch
    ///
    /// so a RESTORED codex change can show counts a live one cannot. That is
    /// the right way round to be wrong: history gains detail, and nothing is
    /// invented for the live row.
    ///
    /// A deleted file's section has no body, so its counts stay absent — codex
    /// never says how many lines it removed, and "−0" would be a lie.
    static func fileChanges(applyPatchEnvelope envelope: String) -> [AgentToolDetailObservation.FileChange] {
        var result: [AgentToolDetailObservation.FileChange] = []
        var path: String?
        var action: AgentToolDetailObservation.FileAction = .unknown
        var renamePath: String?
        var added: UInt = 0
        var removed: UInt = 0
        var sawBody = false

        func flush() {
            guard let current = path else { return }
            let measured = sawBody || action == .add
            result.append(.init(
                action: action, path: current, renamePath: renamePath,
                addedLines: measured ? added : nil,
                removedLines: measured ? removed : nil))
            path = nil
            renamePath = nil
            action = .unknown
            added = 0
            removed = 0
            sawBody = false
        }

        for line in envelope.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("*** ") {
                let directive = line.dropFirst(4)
                if let name = directive.hasPrefix("Update File: ") ? directive.dropFirst(13) : nil {
                    flush(); path = String(name); action = .edit
                } else if let name = directive.hasPrefix("Add File: ") ? directive.dropFirst(10) : nil {
                    flush(); path = String(name); action = .add
                } else if let name = directive.hasPrefix("Delete File: ") ? directive.dropFirst(13) : nil {
                    flush(); path = String(name); action = .delete
                } else if directive.hasPrefix("Move to: ") {
                    // Rides the section it follows, so it renames THAT file.
                    renamePath = String(directive.dropFirst(9))
                    action = .rename
                } else if directive.hasPrefix("End Patch") {
                    flush()
                }
                continue
            }
            guard path != nil else { continue }
            if line.hasPrefix("+") { added += 1; sawBody = true }
            else if line.hasPrefix("-") { removed += 1; sawBody = true }
        }
        flush()
        return result
    }

    /// The first file the envelope names, unabbreviated, for the detail store's
    /// affected-file list. `FileChange.path` is reduced to a basename at the
    /// privacy boundary, so the card needs this to keep the directory.
    static func firstEnvelopePath(_ envelope: String) -> String? {
        for line in envelope.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("*** ") else { continue }
            let directive = line.dropFirst(4)
            for prefix in ["Update File: ", "Add File: ", "Delete File: "] where directive.hasPrefix(prefix) {
                return String(directive.dropFirst(prefix.count))
            }
        }
        return nil
    }

    /// exec: `"kind": "add"`. app-server: `"kind": {"type": "add"}`. Some
    /// builds spell the field `type`. All three resolve here.
    private static func action(_ change: [String: Any]) -> AgentToolDetailObservation.FileAction {
        let raw = (change["kind"] as? String)
            ?? ((change["kind"] as? [String: Any])?["type"] as? String)
            ?? (change["type"] as? String)
            ?? ""
        switch raw.lowercased() {
        case "add", "create": return .add
        case "update", "edit", "modify": return .edit
        case "write": return .write
        case "delete", "remove": return .delete
        case "rename", "move": return .rename
        default: return .unknown
        }
    }
}
