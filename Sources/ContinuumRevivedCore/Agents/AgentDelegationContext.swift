import Foundation

/// Local retry provenance. The original task stays separate from the augmented
/// prompt so retry chains never recursively copy earlier handoffs into context.
public struct AgentDelegationContext: Codable, Equatable, Sendable {
    public var brief: String
    public var baseHead: String?
    public var retryOf: AgentID?
    public var createdWorktree: Bool
    public var checkoutNotice: String?
    /// The lead's stated contract, kept beside the brief. Absent for a helper
    /// delegated without one.
    public var contract: AgentDelegationContract?

    public init(brief: String, baseHead: String?, retryOf: AgentID?, createdWorktree: Bool, checkoutNotice: String?, contract: AgentDelegationContract? = nil) {
        self.brief = brief
        self.baseHead = baseHead
        self.retryOf = retryOf
        self.createdWorktree = createdWorktree
        self.checkoutNotice = checkoutNotice
        self.contract = contract
    }

    /// At most 300 whitespace-delimited words / 4,800 characters of additional
    /// context. Reserve space per section: a long brief cannot crowd out Next.
    public static func handoff(from old: AgentRecord, changedFiles: [String]?) -> String {
        func clip(_ text: String, _ words: Int, _ characters: Int = 900) -> String {
            let tokens = text.split(whereSeparator: \.isWhitespace)
            let clipped = String(tokens.prefix(words).joined(separator: " ").prefix(characters))
            return clipped + (tokens.count > words || text.count > characters ? " …" : "")
        }
        let report = old.lastReport?.report
        let files = changedFiles.map { names in
            names.isEmpty ? "none" : names.prefix(12).map { String(reflecting: $0) }.joined(separator: ", ")
                + (names.count > 12 ? " (more omitted)" : "")
        } ?? "unavailable"
        let sections = [
            "Retry context (bounded). Full brief, transcript and report: inspect old helper \(old.id.rawValue.uuidString).",
            "Prior checkout: \(clip(old.checkoutRoot, 8, 512)). Work is retained there; a new checkout does not copy uncommitted changes.",
            "Earlier brief: \(clip(old.delegationContext?.brief ?? "unavailable for this legacy helper; inspect its transcript", 55))",
            "Changed files (checkout-wide git names): \(clip(files, 30, 700))",
            "Summary: \(clip(report?.summary ?? "no report filed", 40, 600))",
            "Failed checks: \(clip(report?.checks.filter { $0.result == .fail }.map(\.what).joined(separator: "; ") ?? "none reported", 30, 500))",
            "Findings: \(clip(report?.findings.map { "\($0.level.rawValue): \($0.text)" }.joined(separator: "; ") ?? "none reported", 35, 600))",
            "Next: \(clip(report?.next ?? "none reported", 20, 250))"
        ]
        return clip(sections.joined(separator: "\n"), 298, 4798)
    }
}

/// What a lead states a helper owns and owes (`.plans/116` part 4). The lead's
/// words: Array stores them, tells the helper once and compares claimed paths
/// with live siblings as advice. Nothing here is enforced or refused.
public struct AgentDelegationContract: Codable, Equatable, Sendable {
    /// Checkout-relative files or directories the helper owns.
    public var owns: [String]
    /// Checkout-relative paths the helper may touch that other helpers touch too.
    public var shared: [String]
    /// Checkout-relative paths the helper must not touch.
    public var mustNotTouch: [String]
    /// Checks the helper owes, by flag or invocation.
    public var checks: [String]
    /// Owner decisions that bind the helper.
    public var decisions: [String]
    /// A hot-path cost limit, when one applies.
    public var costLimit: String?
    /// What the helper reports back.
    public var report: String?

    public init(owns: [String] = [], shared: [String] = [], mustNotTouch: [String] = [], checks: [String] = [],
                decisions: [String] = [], costLimit: String? = nil, report: String? = nil) {
        self.owns = owns
        self.shared = shared
        self.mustNotTouch = mustNotTouch
        self.checks = checks
        self.decisions = decisions
        self.costLimit = costLimit
        self.report = report
    }

    private enum CodingKeys: String, CodingKey { case owns, shared, mustNotTouch, checks, decisions, costLimit, report }

    /// Any subset of the fields; an absent list is empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owns = try c.decodeIfPresent([String].self, forKey: .owns) ?? []
        shared = try c.decodeIfPresent([String].self, forKey: .shared) ?? []
        mustNotTouch = try c.decodeIfPresent([String].self, forKey: .mustNotTouch) ?? []
        checks = try c.decodeIfPresent([String].self, forKey: .checks) ?? []
        decisions = try c.decodeIfPresent([String].self, forKey: .decisions) ?? []
        costLimit = try c.decodeIfPresent(String.self, forKey: .costLimit)
        report = try c.decodeIfPresent(String.self, forKey: .report)
    }

    /// Empty fields are left out.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        for (key, list) in [(CodingKeys.owns, owns), (.shared, shared), (.mustNotTouch, mustNotTouch), (.checks, checks), (.decisions, decisions)]
        where !list.isEmpty { try c.encode(list, forKey: key) }
        try c.encodeIfPresent(costLimit, forKey: .costLimit)
        try c.encodeIfPresent(report, forKey: .report)
    }

    public var isEmpty: Bool {
        owns.isEmpty && shared.isEmpty && mustNotTouch.isEmpty && checks.isEmpty && decisions.isEmpty
            && costLimit == nil && report == nil
    }

    /// The contract Array keeps, and a note for every entry it could not use.
    /// Never refuses: an unusable entry is left out and named. Paths become
    /// checkout-relative (`./` and `a/./b//c` read as `.` and `a/b/c`); an
    /// absolute path inside `checkoutRoot` is made relative. Nil when nothing
    /// usable is left, which is the same as no contract.
    public func prepared(checkoutRoot: String) -> (contract: AgentDelegationContract?, notes: [String]) {
        var notes: [String] = []
        var root = checkoutRoot
        while root.count > 1, root.hasSuffix("/") { root.removeLast() }
        /// One pass over the bytes: most entries are already clean.
        func isClean(_ raw: String) -> Bool {
            var previous: UInt8 = UInt8(ascii: "/"), dots = 0, count = 0
            for byte in raw.utf8 {
                switch byte {
                case UInt8(ascii: "/"):
                    if previous == UInt8(ascii: "/") || (dots > 0 && dots == count) { return false }
                    dots = 0; count = 0
                case UInt8(ascii: "."): dots += 1; count += 1
                case UInt8(ascii: "~"), UInt8(ascii: "*"), UInt8(ascii: "?"), UInt8(ascii: "["): return false
                case 0...32, 127...: return false
                default: count += 1
                }
                previous = byte
            }
            return previous != UInt8(ascii: "/") && !(dots > 0 && dots == count)
        }
        func path(_ raw: String) -> String? {
            if isClean(raw) { return raw }
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let shown = String(reflecting: raw)
            if text.isEmpty { notes.append("ignored: \(shown), empty"); return nil }
            if text.hasPrefix("~") { notes.append("ignored: \(shown), a home path is not in the checkout"); return nil }
            if text.hasPrefix("/") {
                if text.compare(root, options: .caseInsensitive) == .orderedSame { text = "." }
                else if let inside = text.range(of: root + "/", options: [.caseInsensitive, .anchored]) { text = String(text[inside.upperBound...]) }
                else { notes.append("ignored: \(shown), outside the helper's checkout"); return nil }
            }
            let parts = text.split(separator: "/").filter { $0 != "." }
            if parts.contains("..") { notes.append("ignored: \(shown), a '..' step leaves the checkout"); return nil }
            let path = parts.isEmpty ? "." : parts.joined(separator: "/")
            if path.contains(where: { "*?[".contains($0) }) { notes.append("not expanded: \(shown) is compared as written") }
            return path
        }
        func text(_ raw: String?) -> String? {
            raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let kept = AgentDelegationContract(
            owns: owns.compactMap(path), shared: shared.compactMap(path), mustNotTouch: mustNotTouch.compactMap(path),
            checks: checks.compactMap(text), decisions: decisions.compactMap(text),
            costLimit: text(costLimit), report: text(report))
        return (kept.isEmpty ? nil : kept, notes)
    }

    /// Paths this contract and `other` both claim (owned or shared), as the more
    /// specific path of each pair. Case-insensitive, like the default macOS
    /// volume; symlinks are not resolved. A path both sides list as shared is
    /// expected and left out. Hash lookups of each path's parents keep it
    /// O((m + n) x depth), with no sort and no pairwise comparison.
    public func claimOverlap(with other: AgentDelegationContract) -> [String] {
        typealias Claim = (path: String, shared: Bool)
        typealias Key = ArraySlice<UInt8>
        /// Lowercased UTF-8; ASCII without allocating a String.
        func key(_ path: String) -> Key {
            path.utf8.allSatisfy { $0 < 128 }
                ? Key(path.utf8.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 })
                : Key(path.lowercased().utf8)
        }
        func index(_ c: AgentDelegationContract) -> (keys: [(Key, Claim)], byKey: [Key: Claim]) {
            let keys = c.owns.map { (key($0), Claim($0, false)) } + c.shared.map { (key($0), Claim($0, true)) }
            var byKey: [Key: Claim] = [:]
            byKey.reserveCapacity(keys.count)
            for (key, claim) in keys where byKey[key] == nil { byKey[key] = claim }
            return (keys, byKey)
        }
        let mine = index(self), theirs = index(other)
        let root = Key(".".utf8), slash = UInt8(ascii: "/")
        var found: [String] = [], seen: Set<Key> = []
        func add(_ mine: Claim, _ their: Claim, _ specific: Claim, _ specificKey: Key) {
            if mine.shared && their.shared { return }
            if seen.insert(specificKey).inserted { found.append(specific.path) }
        }
        /// Calls `body` with each parent of `key` ("a/b/c" -> "a/b", "a", "."),
        /// and with `key` itself first when `including` it.
        func parents(of key: Key, including: Bool, _ body: (Key) -> Void) {
            if including { body(key) }
            guard key != root else { return }
            var end = key.endIndex
            while let cut = key[key.startIndex..<end].lastIndex(of: slash) { end = cut; body(key[key.startIndex..<end]) }
            body(root)
        }
        // Mine is, or is inside, one of theirs.
        for (key, claim) in mine.keys {
            parents(of: key, including: true) { if let their = theirs.byKey[$0] { add(claim, their, claim, key) } }
        }
        // Theirs is inside one of mine.
        for (key, claim) in theirs.keys {
            parents(of: key, including: false) { if let own = mine.byKey[$0] { add(own, claim, claim, key) } }
        }
        return found
    }

    /// The one block the helper is told. Each field is one line and each entry
    /// is quoted with its newlines and control characters escaped, so the
    /// lead's words cannot pass for lines of Array's own.
    public var promptText: String {
        func quoted(_ entry: String) -> String {
            var out = "\""
            for scalar in entry.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\t": out += "\\t"
                default:
                    switch scalar.properties.generalCategory {
                    case .control, .format, .lineSeparator, .paragraphSeparator:
                        out += "\\u{" + String(scalar.value, radix: 16) + "}"
                    default: out.unicodeScalars.append(scalar)
                    }
                }
            }
            return out + "\""
        }
        func line(_ name: String, _ entries: [String]) -> String? {
            entries.isEmpty ? nil : "\(name): " + entries.map(quoted).joined(separator: ", ")
        }
        let fields = [line("owns", owns), line("shared", shared), line("must not touch", mustNotTouch),
                      line("checks", checks), line("decisions", decisions),
                      line("cost limit", costLimit.map { [$0] } ?? []), line("report", report.map { [$0] } ?? [])]
        return (["Your lead's contract for this task, in your lead's words (Array stored it and checked nothing):", "<lead-contract>"]
            + fields.compactMap { $0 } + ["</lead-contract>"]).joined(separator: "\n")
    }
}
