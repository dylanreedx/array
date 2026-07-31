import ContinuumRevivedCore
import Foundation

/// Deliberately asserts cross-agent leakage. The parent requires this process to
/// fail at the production isolation assertion as a deterministic red witness.
func runAgentPromptHistoryIsolationNegativeWitness() {
    let history = AgentPromptHistory(capacityPerAgent: 3)
    let agentA = AgentID(rawValue: UUID(uuidString: "A0000000-0000-4000-8000-000000009451")!)
    let agentB = AgentID(rawValue: UUID(uuidString: "A0000000-0000-4000-8000-000000009452")!)
    history.recordAccepted("agent A private prompt", for: agentA)
    expect(history.previous(for: agentB, preserving: "") != nil,
           "negative witness: prompt history crossed AgentID")
}

// Ticket 91/P4.5: bounded accepted history is isolated per agent, preserves the
// pre-navigation draft, and never treats ordinary non-history Down as history.
func runAgentPromptHistoryChecks() throws {
    let history = AgentPromptHistory(capacityPerAgent: 3)
    let agentA = AgentID(rawValue: UUID(uuidString: "A0000000-0000-4000-8000-000000009451")!)
    let agentB = AgentID(rawValue: UUID(uuidString: "A0000000-0000-4000-8000-000000009452")!)

    history.recordAccepted("first", for: agentA)
    history.recordAccepted("second", for: agentA)
    history.recordAccepted("second", for: agentA)
    expect(history.count(for: agentA) == 2,
           "adjacent identical accepted prompts must be deduplicated")
    expect(history.acceptedSubmissionCount(for: agentA) == 3,
           "adjacent deduplication must not hide the number of accepted submissions")
    expect(history.count(for: agentB) == 0,
           "an independent agent must start with no prompt history")
    expect(history.next(for: agentA) == nil,
           "Down outside history mode must remain available to ordinary text movement")

    expect(history.previous(for: agentA, preserving: "unfinished\nmultiline draft") == "second",
           "first Up at the visual boundary must select the newest accepted prompt")
    expect(history.previous(for: agentA, preserving: "ignored after entry") == "first",
           "repeated Up must walk toward older prompts without replacing the preserved draft")
    expect(history.previous(for: agentA, preserving: "also ignored") == "first",
           "Up at the oldest prompt must remain bounded")
    expect(history.next(for: agentA) == "second",
           "Down in history mode must walk toward newer prompts")
    expect(history.next(for: agentA) == "unfinished\nmultiline draft",
           "Down beyond the newest prompt must restore the exact pre-navigation draft")
    expect(!history.isNavigating(for: agentA),
           "restoring the draft must exit history mode")

    history.recordAccepted("third", for: agentA)
    history.recordAccepted("fourth", for: agentA)
    expect(history.count(for: agentA) == 3,
           "accepted prompt history must stay within its per-agent capacity")
    expect(history.previous(for: agentA, preserving: "draft") == "fourth",
           "bounded history must retain the newest prompt")
    expect(history.previous(for: agentA, preserving: "draft") == "third",
           "bounded history must retain the next-newest prompt")
    expect(history.previous(for: agentA, preserving: "draft") == "second",
           "capacity eviction must remove only the oldest prompt")

    history.recordAccepted("agent B only", for: agentB)
    expect(history.previous(for: agentB, preserving: "B draft") == "agent B only",
           "agent B must navigate only its own accepted prompts")
    history.cancelNavigation(for: agentB)
    expect(history.next(for: agentB) == nil,
           "cancelled history navigation must return Down to native text handling")

    let witness = Process()
    witness.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    witness.arguments = ["--agent-prompt-history-isolation-negative-witness"]
    let witnessError = Pipe()
    witness.standardError = witnessError
    try witness.run()
    witness.waitUntilExit()
    let witnessOutput = String(
        data: witnessError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
    ) ?? ""
    expect(witness.terminationStatus != 0,
           "the cross-agent history regression negative witness must be observed red")
    let expectedWitness = "FAIL: negative witness: prompt history crossed AgentID"
    expect(witnessOutput.contains(expectedWitness),
           "the negative witness must fail at the named production isolation assertion")

    print("AgentPromptHistory checks passed: bounded accepted-only navigation, adjacent deduplication, exact draft restoration, native Down fallback, per-agent isolation, and subprocess red witness")
}
