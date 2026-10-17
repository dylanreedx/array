import ContinuumRevivedCore
import Foundation

func runWorkspaceAPIExposureChecks() {
    // The bare CoreChecks run has an inherited RED before the API suites.
    // Keep the exposed operation's request/result coding reachable in the gate.
    runWorkspaceAPIContractChecks()
    let failures = WorkspaceAPIExposure.violations()
    for failure in failures { expect(false, "WorkspaceAPIExposure: \(failure)") }
    let sample: Set<String> = ["field"]
    expect(WorkspaceAPIExposure.violations(fields: sample, decisions: [:]).contains("Unclassified field: field"), "exposure audit rejects missing decisions")
    expect(WorkspaceAPIExposure.violations(fields: [], decisions: ["old": .internal]).contains("Stale API decision: old"), "exposure audit rejects stale decisions")
    expect(!WorkspaceAPIExposure.violations(fields: sample, decisions: ["field": .notExposed(" \n")]).isEmpty, "exposure audit rejects blank reasons")
    expect(!WorkspaceAPIExposure.violations(fields: sample, decisions: ["field": .exposed(.agentUpdate)], exposedOperations: []).isEmpty, "exposure audit requires a callable tool")
    expect(WorkspaceAPIExposure.decisions["agent.identityColor"] == .exposed(.agentUpdate), "agent colour remains exposed")
    if failures.isEmpty { print("WorkspaceAPIExposureChecks passed: \(WorkspaceAPIExposure.fields.count) real coding keys classified") }
}
