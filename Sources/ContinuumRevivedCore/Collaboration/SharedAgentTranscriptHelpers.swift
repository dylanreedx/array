import Foundation

/// A shared agent's helpers (its child agents, at any depth) as the transcript
/// lane's body carries them: `Checkpoint.helpers` and `Op.helpers`. Body only,
/// so the relay never reads it and an older guest skips it as an unknown op.
/// Model: `~/array-scratch/mp-polish/transcript-subagents/STATE.md`.
extension SharedAgentTranscriptWire {
    /// Helpers one roster carries, breadth first, parents before children.
    public static let maxHelpers = 32
    public static let maxHelperNameBytes = 160

    /// The host chip's state words (`InboxState` raw values), plus `stopped`
    /// for a helper with no live runner, which the host chip shows with none.
    public enum HelperState: String, Codable, Sendable, CaseIterable { case working, approval, input, failed, ready, stopped }
    /// `delegated`: a managed agent Array runs (`array_delegate`, a pi spawn).
    /// `provider`: a subagent the CLI runs and Array only watches.
    public enum HelperOrigin: String, Codable, Sendable { case delegated, provider }

    /// One helper. `id` is the host's agent id, which the document's agent
    /// reference and agent message blocks already carry. No prompt, transcript
    /// text, error text, path or provider id.
    public struct Helper: Codable, Equatable, Sendable {
        public let id: UUID
        /// Nil for a direct child of the shared agent; else another helper's id.
        public let parent: UUID?
        public var name: String
        public var origin: HelperOrigin
        /// `claude`, `codex` or `pi`.
        public var harness: String?
        public var state: HelperState
        /// The host's identity colour token name, never a colour value.
        public var identityColor: String?
        public let spawnedAt: Date
        public init(id: UUID, parent: UUID?, name: String, origin: HelperOrigin, harness: String?,
                    state: HelperState, identityColor: String?, spawnedAt: Date) {
            self.id = id; self.parent = parent; self.name = name; self.origin = origin; self.harness = harness
            self.state = state; self.identityColor = identityColor; self.spawnedAt = spawnedAt
        }
    }

    /// What the helpers add up to: the facts the host lead's outline and working
    /// glyph read (`ChildRollup`). Derived, never sent.
    public struct HelperRollup: Equatable, Sendable {
        public let helpers: Int
        public let working: Int
        public let needsYou: Int
        public let failed: Int
        public init(_ helpers: [Helper]) {
            self.helpers = helpers.count
            working = helpers.filter { $0.state == .working }.count
            needsYou = helpers.filter { $0.state == .approval || $0.state == .input }.count
            failed = helpers.filter { $0.state == .failed }.count
        }
        /// The lead shows the working glyph while any helper works.
        public var anyWorking: Bool { working > 0 }
    }

    public static func valid(helpers: [Helper]) -> Bool {
        guard helpers.count <= maxHelpers, Set(helpers.map(\.id)).count == helpers.count else { return false }
        var seen = Set<UUID>()
        for helper in helpers {
            guard helper.name.utf8.count <= maxHelperNameBytes, (helper.harness?.utf8.count ?? 0) <= 16,
                  (helper.identityColor?.utf8.count ?? 0) <= 32 else { return false }
            if let parent = helper.parent { guard seen.contains(parent) else { return false } }
            seen.insert(helper.id)
        }
        return true
    }

    /// A name bounded at a character boundary and otherwise unchanged: the
    /// guest shows what the host shows.
    public static func helperName(_ value: String) -> String {
        var bounded = "", budget = maxHelperNameBytes
        for character in value {
            let size = String(character).utf8.count
            guard size <= budget else { break }
            bounded.append(character); budget -= size
        }
        return bounded
    }
}
