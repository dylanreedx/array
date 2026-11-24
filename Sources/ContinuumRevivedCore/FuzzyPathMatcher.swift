import Foundation

/// Scores a typed query against one relative path and says WHICH characters
/// matched, so a list can highlight exactly those.
///
/// The old ranker accepted any subsequence of the path, so "palmod" lit
/// "P…a…l…m…o…d" scattered across a long docs name and ranked it beside
/// `LaunchPaletteModel.swift`. This one scores like fzf: a matched character
/// earns a base amount plus a bonus when it starts a word (after `/ - _ . `,
/// at a camelCase hump, at the start of the filename); a character that
/// continues the previous match earns a run bonus; a gap costs. A match wholly
/// inside the filename beats one that needs the directories. A match made only
/// of scattered single letters is refused.
public enum FuzzyPathMatcher {
    public struct Match: Equatable, Sendable {
        public let score: Int
        /// Byte offsets into the path, ascending. Equal to character offsets
        /// for an ASCII path, which is the only kind the caller maps back.
        public let positions: [Int]
    }

    private static let base = 16
    private static let run = 8
    private static let gapStart = 3
    private static let filenameBonus = 30
    private static let negativeInfinity = Int.min / 4

    /// - Parameters:
    ///   - needle: the query, lowercased, ASCII-folded as the index folds it.
    ///   - path: the relative path as bytes with its ORIGINAL case, so humps are visible.
    public static func match(needle: [UInt8], path: [UInt8]) -> Match? {
        let m = needle.count
        let n = path.count
        guard m > 0, n >= m, n <= 1024 else { return nil }
        let lower = path.map(lowered)
        guard isSubsequence(needle, of: lower) else { return nil }
        let slash = UInt8(ascii: "/")
        let filenameStart = (path.lastIndex(of: slash) ?? -1) + 1

        var bonus = [Int](repeating: 0, count: n)
        for j in 0..<n { bonus[j] = boundaryBonus(path, j, filenameStart: filenameStart) }

        // score[i][j]: best score matching needle[0...i] with needle[i] at j.
        let impossible = negativeInfinity
        var score = [[Int]](repeating: [Int](repeating: impossible, count: n), count: m)
        // from[i][j]: where needle[i-1] sat for that best, to read positions back.
        var from = [[Int32]](repeating: [Int32](repeating: -1, count: n), count: m)

        for j in 0..<n where lower[j] == needle[0] {
            score[0][j] = base + bonus[j]
        }
        if m > 1 {
            for i in 1..<m {
                var carry = impossible
                var carryIndex = -1
                for j in i..<n {
                    // Fold k = j-2 into the running "after a gap" candidate; older
                    // ones lose one more point for each position they trail.
                    if carry > impossible { carry -= 1 }
                    if j >= 2, score[i - 1][j - 2] > impossible {
                        let candidate = score[i - 1][j - 2] - gapStart
                        if candidate > carry { carry = candidate; carryIndex = j - 2 }
                    }
                    guard lower[j] == needle[i] else { continue }
                    var best = impossible
                    var bestFrom = -1
                    if score[i - 1][j - 1] > impossible {
                        // A continued run keeps the better of its own and the first
                        // character's bonus, so "Palette" stays one unit.
                        best = score[i - 1][j - 1] + base + run + max(0, bonus[j] / 2)
                        bestFrom = j - 1
                    }
                    if carry > impossible, carry + base + bonus[j] > best {
                        best = carry + base + bonus[j]
                        bestFrom = carryIndex
                    }
                    if best > impossible { score[i][j] = best; from[i][j] = Int32(bestFrom) }
                }
            }
        }

        var bestScore = impossible
        var end = -1
        for j in (m - 1)..<n where score[m - 1][j] > bestScore {
            bestScore = score[m - 1][j]
            end = j
        }
        guard end >= 0 else { return nil }

        var positions = [Int](repeating: 0, count: m)
        var cursor = end
        for i in stride(from: m - 1, through: 0, by: -1) {
            positions[i] = cursor
            if i > 0 { cursor = Int(from[i][cursor]) }
        }

        // Scattered single letters are not a match: more than a third of the needle's
        // characters standing alone, past two characters, is noise.
        if m >= 3 {
            var runs = 1
            for i in 1..<m where positions[i] != positions[i - 1] + 1 { runs += 1 }
            if runs > max(2, m / 3) { return nil }
        }

        var total = bestScore
        if positions[0] >= filenameStart { total += filenameBonus }
        return Match(score: total, positions: positions)
    }

    private static func lowered(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }

    static func isSubsequence(_ needle: [UInt8], of hay: [UInt8]) -> Bool {
        var i = 0
        for byte in hay where i < needle.count && byte == needle[i] { i += 1 }
        return i == needle.count
    }

    private static func isLetter(_ b: UInt8) -> Bool { (b >= 65 && b <= 90) || (b >= 97 && b <= 122) }
    private static func isUpper(_ b: UInt8) -> Bool { b >= 65 && b <= 90 }
    private static func isLower(_ b: UInt8) -> Bool { b >= 97 && b <= 122 }
    private static func isDigit(_ b: UInt8) -> Bool { b >= 48 && b <= 57 }

    private static func boundaryBonus(_ path: [UInt8], _ j: Int, filenameStart: Int) -> Int {
        if j == filenameStart { return 14 }
        if j == 0 { return 10 }
        let previous = path[j - 1]
        let current = path[j]
        switch previous {
        case UInt8(ascii: "/"): return 10
        case UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: " "): return 8
        default: break
        }
        if isLower(previous), isUpper(current) { return 7 }
        if isDigit(current), isLetter(previous) { return 4 }
        return 0
    }
}
