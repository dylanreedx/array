import Foundation
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// A character set a shared agent's host draws, as the guest resolved it. The
/// set is the host's own when it validated; otherwise the guest's built-in set.
/// `key` names its atlases: it carries the content hash, so a guest's own set
/// with the same id can never stand in for the host's.
struct SharedAgentCharacterSet: Equatable {
    let theme: AgentCharacterTheme
    let key: String
    /// Why the host's set is not the one drawn; nil when it is.
    let fallbackReason: String?

    /// The character to draw for `agentID`: the host's assignment when it fits
    /// this set, else the host's rule over the agent's pick, in this set.
    func assignment(for agentID: UUID, shipped: AgentCharacterAssignment?, name: String?) -> AgentCharacterAssignment? {
        if let shipped, fallbackReason == nil {
            let count = shipped.kind == .lead ? (theme.leadSet?.characters.count ?? 0) : theme.characters.count
            if shipped.index >= 0, shipped.index < count { return shipped }
        }
        return AgentCharacterAssignment.resolve(agentID: agentID, name: name, role: nil, theme: theme)
    }
}

/// The guest's in-memory copy of the sets shared agents' hosts sent. Never
/// written to disk, never added to the guest's own library or settings.
/// Each file is validated once, with the validator `--validate-agent-character-theme`
/// uses; a set that fails, or is too large, falls back to the built-in set.
@MainActor
enum SharedAgentCharacterSets {
    typealias Wire = SharedAgentTranscriptWire
    /// Validated sets by hash, newest last; failures are remembered too, so a
    /// bad file is judged once, not on every chrome update.
    private static var validated: [(hash: String, result: Result<AgentCharacterTheme, AgentCharacterThemeProblems>)] = []
    static let maximumKept = 8
    private(set) static var validations = 0

    static func resolve(_ reference: Wire.Chrome.ThemeReference,
                        files: [String: Wire.CharacterTheme]) -> SharedAgentCharacterSet? {
        guard let builtIn = AgentCharacterBundled.theme() else { return nil }
        func fallback(_ reason: String) -> SharedAgentCharacterSet {
            .init(theme: builtIn, key: "builtin:" + builtIn.id, fallbackReason: reason)
        }
        guard let hash = reference.hash else {
            return reference.id == builtIn.id ? .init(theme: builtIn, key: "builtin:" + builtIn.id, fallbackReason: nil)
                : fallback("The owner's set \(reference.id) did not come with its file.")
        }
        let result: Result<AgentCharacterTheme, AgentCharacterThemeProblems>
        if let known = validated.first(where: { $0.hash == hash }) {
            result = known.result
        } else if let file = files[hash] {
            validations += 1
            if let data = file.file() {
                result = AgentCharacterValidator.validate(data: data).flatMap { theme in
                    theme.id == reference.id ? .success(theme) : .failure(.init(messages: ["the file's id is not \(reference.id)"]))
                }
            } else {
                result = .failure(.init(messages: ["the file is too large, damaged, or not the file its hash names"]))
            }
            validated.append((hash, result))
            if validated.count > maximumKept { validated.removeFirst(validated.count - maximumKept) }
        } else {
            return fallback("The owner's set has not arrived.")
        }
        switch result {
        case let .success(theme): return .init(theme: theme, key: "shared:" + hash, fallbackReason: nil)
        case let .failure(problems): return fallback("The owner's set could not be used: " + (problems.messages.first ?? "invalid"))
        }
    }

    /// Checks only: forget every set, as a fresh launch would.
    static func qaReset() { validated.removeAll(); validations = 0 }
}

extension AgentCharacterController {
    /// The atlas for one character of a shared set, cached by the set's key
    /// (which carries its hash), apart from the guest's own set's atlases.
    /// nil while characters are off on this Mac.
    func atlas(shared set: SharedAgentCharacterSet, assignment: AgentCharacterAssignment,
               appearance: AgentCharacterAtlas.Appearance) -> AgentCharacterSpriteAtlas? {
        guard isEnabled else { return nil }
        return sharedAtlas(set: set, assignment: assignment, appearance: appearance)
    }
}
