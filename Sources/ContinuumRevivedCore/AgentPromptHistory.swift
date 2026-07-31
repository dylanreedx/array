import Foundation

/// Host-local accepted prompt history, partitioned by durable agent identity.
///
/// Prompt bodies deliberately have no persistence, logging, or diagnostic
/// representation here. The owner records a prompt only after its send intent
/// has been accepted.
public final class AgentPromptHistory: @unchecked Sendable {
    private struct AgentState {
        var prompts: [String] = [] // oldest to newest
        var acceptedSubmissionCount: UInt64 = 0
        var navigationIndex: Int?
        var preservedDraft: String?
    }

    public let capacityPerAgent: Int

    private let lock = NSLock()
    private var states: [AgentID: AgentState] = [:]

    public init(capacityPerAgent: Int = 50) {
        self.capacityPerAgent = max(1, capacityPerAgent)
    }

    /// Adds an accepted prompt. Empty prompts are ignored and adjacent exact
    /// duplicates occupy one history slot.
    public func recordAccepted(_ prompt: String, for agentID: AgentID) {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        var state = states[agentID] ?? AgentState()
        state.acceptedSubmissionCount &+= 1
        if state.prompts.last != prompt {
            state.prompts.append(prompt)
            if state.prompts.count > capacityPerAgent {
                state.prompts.removeFirst(state.prompts.count - capacityPerAgent)
            }
        }
        state.navigationIndex = nil
        state.preservedDraft = nil
        states[agentID] = state
    }

    /// Enters history from the newest item, preserving the current draft once,
    /// then walks toward older accepted prompts.
    public func previous(for agentID: AgentID, preserving currentDraft: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard var state = states[agentID], !state.prompts.isEmpty else { return nil }
        if let index = state.navigationIndex {
            state.navigationIndex = max(0, index - 1)
        } else {
            state.preservedDraft = currentDraft
            state.navigationIndex = state.prompts.count - 1
        }
        states[agentID] = state
        return state.prompts[state.navigationIndex!]
    }

    /// Walks toward newer history. Moving beyond the newest item restores the
    /// exact draft captured when navigation began and exits history mode.
    public func next(for agentID: AgentID) -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard var state = states[agentID], let index = state.navigationIndex else { return nil }
        let result: String
        if index < state.prompts.count - 1 {
            state.navigationIndex = index + 1
            result = state.prompts[index + 1]
        } else {
            result = state.preservedDraft ?? ""
            state.navigationIndex = nil
            state.preservedDraft = nil
        }
        states[agentID] = state
        return result
    }

    public func isNavigating(for agentID: AgentID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return states[agentID]?.navigationIndex != nil
    }

    public func count(for agentID: AgentID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return states[agentID]?.prompts.count ?? 0
    }

    /// Accepted send occurrences are distinct from retained history slots: two
    /// adjacent identical accepted prompts occupy one slot but still represent
    /// two submissions. This body-free count also makes duplicate recorder calls
    /// observable without exposing prompt text.
    public func acceptedSubmissionCount(for agentID: AgentID) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return states[agentID]?.acceptedSubmissionCount ?? 0
    }

    public func cancelNavigation(for agentID: AgentID) {
        lock.lock()
        defer { lock.unlock() }
        guard var state = states[agentID] else { return }
        state.navigationIndex = nil
        state.preservedDraft = nil
        states[agentID] = state
    }
}
