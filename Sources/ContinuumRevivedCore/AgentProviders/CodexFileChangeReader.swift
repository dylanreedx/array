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
