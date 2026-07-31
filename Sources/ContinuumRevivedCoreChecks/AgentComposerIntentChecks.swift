import ContinuumRevivedCore
import Foundation

func runAgentComposerIntentNegativeWitness() {
    let state = AgentComposerIntentState(
        executionState: .working,
        capabilities: .sendStop(canSend: true, canStop: false)
    )
    // Deliberately demand the forbidden result from the compiled Core resolver.
    // The parent check requires this exact assertion to be observed red.
    expect(
        state.workingDraftIntent(draft: "not logged") == .steer("not logged"),
        "agent composer intent negative witness: working without an explicit RPC advertised Steer"
    )
}

func runAgentComposerIntentChecks() throws {
    let executionStates: [AgentTurnExecutionState] = [.ready, .working]
    let drafts = ["", "  next turn  \n"]
    var rows = 0

    for executionState in executionStates {
        for bits in 0..<16 {
            let capabilities = AgentTurnCapabilities(
                canSend: bits & 1 != 0,
                canStop: bits & 2 != 0,
                canSteer: bits & 4 != 0,
                canQueue: bits & 8 != 0
            )
            for draft in drafts {
                rows += 1
                let hasDraft = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let state = AgentComposerIntentState(
                    executionState: executionState,
                    capabilities: capabilities
                )

                let expectedPrimary: AgentComposerIntent?
                switch executionState {
                case .ready:
                    expectedPrimary = capabilities.canSend && hasDraft ? .send("next turn") : nil
                case .working:
                    expectedPrimary = capabilities.canStop ? .stop : nil
                }
                expect(
                    state.primaryIntent(draft: draft) == expectedPrimary,
                    "AgentComposerIntent: primary intent disagreed with explicit state/capabilities"
                )

                let expectedWorkingDraft: AgentComposerIntent?
                if executionState != .working || !hasDraft {
                    expectedWorkingDraft = nil
                } else if capabilities.canSteer {
                    expectedWorkingDraft = .steer("next turn")
                } else if capabilities.canQueue {
                    expectedWorkingDraft = .queue("next turn")
                } else {
                    expectedWorkingDraft = nil
                }
                expect(
                    state.workingDraftIntent(draft: draft) == expectedWorkingDraft,
                    "AgentComposerIntent: working draft intent advertised an unsupported operation"
                )

                var expectedAllowed = Set<AgentComposerWorkingDraftIntent>()
                if executionState == .working {
                    if capabilities.canSteer { expectedAllowed.insert(.steer) }
                    if capabilities.canQueue { expectedAllowed.insert(.queue) }
                }
                expect(
                    state.allowedWorkingDraftIntents == expectedAllowed,
                    "AgentComposerIntent: allowed working intents disagreed with explicit capabilities"
                )
            }
        }
    }

    expect(rows == 64, "AgentComposerIntent: expected 64 exhaustive rows, got \(rows)")
    expect(
        AgentTurnCapabilities.sendStop(canSend: true, canStop: true)
            == AgentTurnCapabilities(canSend: true, canStop: true, canSteer: false, canQueue: false),
        "AgentComposerIntent: conservative send/stop floor exposed a future RPC"
    )

    let witness = Process()
    witness.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    witness.arguments = ["--agent-composer-intent-negative-witness"]
    let witnessError = Pipe()
    witness.standardError = witnessError
    try witness.run()
    witness.waitUntilExit()
    let witnessOutput = String(
        data: witnessError.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
    let expectedWitness = "FAIL: agent composer intent negative witness: working without an explicit RPC advertised Steer"
    expect(witness.terminationStatus != 0,
           "AgentComposerIntent: unsupported-Steer negative witness must be observed red")
    expect(witnessOutput.contains(expectedWitness),
           "AgentComposerIntent: negative witness did not fail at the named compiled assertion")

    print("Agent composer intent negative witness observed red (exit \(witness.terminationStatus)): \(expectedWitness)")
    print("Agent composer intent checks passed: \(rows) state/capability/draft rows and conservative send/stop floor")
}
