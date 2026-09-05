import Foundation

// Ticket: TR-01 — per-operation line counts for the transcript's change card.
//
// The card used to print "line counts unavailable" for every file change ever
// made, because nothing in the app computed a count. This is where the numbers
// come from, and the rule it exists to enforce is: a count is either MEASURED
// from what the provider actually said this operation did, or it is absent.
// There is no third state, and a worktree-wide `git diff` is not a substitute —
// it contains the user's own edits and every other agent's, and it cannot be
// attributed to one tool call.
public enum AgentFileChangeCounting {
    /// Lines in a chunk of file text.
    ///
    /// Counted over UNICODE SCALARS, not Characters. Swift renders "\r\n" as a
    /// single grapheme cluster, so a Character-wise `== "\n"` sees no line
    /// breaks at all in a CRLF file and `hasSuffix("\n")` is false for text
    /// that plainly ends in a newline — a CRLF file would have reported one
    /// enormous line.
    ///
    /// A trailing newline terminates the last line rather than starting a new
    /// empty one: "a\nb" and "a\nb\n" are both two lines. A file whose final
    /// line has no newline is the common case in the wild and must not read as
    /// one line shorter than the editor shows.
    public static func lineCount(_ text: String) -> UInt {
        guard !text.isEmpty else { return 0 }
        var count = 0
        for scalar in text.unicodeScalars where scalar == "\n" { count += 1 }
        if text.unicodeScalars.last != "\n" { count += 1 }
        return UInt(count)
    }

    /// Counts for replacing `old` with `new` — claude's `Edit`, one element of a
    /// `MultiEdit`, and pi's `edits[]`.
    ///
    /// A real line diff, because the cheap version is wrong on the commonest
    /// edit there is. Peeling identical leading and trailing lines and calling
    /// the remainder changed reports "+4 −3" for pi's captured edit —
    /// alpha/beta/delta → ALPHA/beta/delta/gamma — because changing the first
    /// line and appending to the last leaves no common prefix OR suffix, so the
    /// untouched middle counts as rewritten. Git says +2 −1, and so does this.
    ///
    /// `nil` when the replaced region is too large to diff within a fixed
    /// budget: an overcount is not a safe fallback here, because the card
    /// presents these as measurements.
    public static func replacementCounts(old: String, new: String) -> (added: UInt, removed: UInt)? {
        var oldLines = splitLines(old)
        var newLines = splitLines(new)
        // The peel is still worth doing: it is linear, and it usually leaves
        // the quadratic pass a handful of lines to look at.
        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count, oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        oldLines.removeFirst(prefix)
        newLines.removeFirst(prefix)
        var suffix = 0
        while suffix < oldLines.count, suffix < newLines.count,
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }
        oldLines.removeLast(suffix)
        newLines.removeLast(suffix)
        guard !oldLines.isEmpty else { return (added: UInt(newLines.count), removed: 0) }
        guard !newLines.isEmpty else { return (added: 0, removed: UInt(oldLines.count)) }
        guard let common = longestCommonSubsequenceLength(oldLines, newLines) else { return nil }
        return (added: UInt(newLines.count - common), removed: UInt(oldLines.count - common))
    }

    /// Two-row LCS over lines, with a hard cell budget. Bounded on purpose:
    /// this runs on a provider event, and a model may hand over a
    /// whole-file replacement.
    private static let maximumDiffCells = 250_000

    private static func longestCommonSubsequenceLength(
        _ lhs: [Substring], _ rhs: [Substring]
    ) -> Int? {
        guard lhs.count * rhs.count <= maximumDiffCells else { return nil }
        var previous = [Int](repeating: 0, count: rhs.count + 1)
        var current = previous
        for i in 1...lhs.count {
            for j in 1...rhs.count {
                current[j] = lhs[i - 1] == rhs[j - 1]
                    ? previous[j - 1] + 1
                    : max(previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }

    /// Counts from a unified diff, or `nil` when the text is not one.
    ///
    /// `nil` is the important half. Codex sends a `changes[].diff` whose real
    /// shape is not pinned by any captured fixture — the one committed
    /// app-server capture carries the literal `"edited\n"` — so a parser that
    /// assumed unified format would invent "+1 −0" for it. Requiring a hunk
    /// header before believing anything makes an unrecognised shape unknown
    /// rather than wrong.
    public static func unifiedDiffCounts(_ diff: String) -> (added: UInt, removed: UInt)? {
        var sawHunkHeader = false
        var added: UInt = 0
        var removed: UInt = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@") { sawHunkHeader = true; continue }
            // File headers, not content lines.
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            guard sawHunkHeader else { continue }
            if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
        }
        return sawHunkHeader ? (added: added, removed: removed) : nil
    }

    private static func splitLines(_ text: String) -> [Substring] {
        guard !text.isEmpty else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // A trailing newline produces one empty trailing element that is a
        // terminator, not a line — the same rule `lineCount` applies.
        if text.unicodeScalars.last == "\n" { lines.removeLast() }
        return lines
    }
}
