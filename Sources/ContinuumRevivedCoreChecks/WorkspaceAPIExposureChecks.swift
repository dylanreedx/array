import ContinuumRevivedCore
import Foundation

func runWorkspaceAPIExposureChecks() {
    // The bare CoreChecks run has an inherited RED before the API suites.
    // Keep the exposed operation's request/result coding reachable in the gate.
    runWorkspaceAPIContractChecks()
    expect(WorkspaceMCPToolCatalog.tools.contains { $0.operation == .browserSelect } &&
        WorkspaceAPIOp.approvalGatedOperations.contains(.browserSelect), "browser.select remains published and control-granted")
    // The policy is persisted inside delegationContext, so auditing only the
    // parent AgentRecord key would silently miss a new snapshot field.
    let dietKey = "agent.delegationContext.contextDietRequested"
    expect(WorkspaceAPIExposure.fields.contains(dietKey), "exposure census must include the real persisted helper diet key")
    let snapshot = AgentDelegationContext(brief: "synthetic brief", baseHead: "synthetic head",
        retryOf: AgentID(rawValue: UUID()), createdWorktree: true, checkoutNotice: "synthetic notice",
        contract: AgentDelegationContract(decisions: ["synthetic decision"]), chooserWriteRequest: UUID(),
        chooserWriteInProgress: true, contextDietRequested: true)
    guard let encoded = try? JSONEncoder().encode(snapshot),
          let keys = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] else {
        expect(false, "delegation context must encode for the real-key census"); return
    }
    expect(keys["contextDietRequested"] as? Bool == true, "snapshot request remains on its actual persisted coding key")
    expect((try? JSONDecoder().decode(AgentDelegationContext.self, from: encoded)) == snapshot, "explicit nested keys preserve the complete snapshot round trip")
    for key in keys.keys {
        expect(WorkspaceAPIExposure.fields.contains("agent.delegationContext." + key), "every serialized delegation key must enter the census: \(key)")
    }
    expect(WorkspaceAPIExposure.decisions[dietKey] == .internal, "helper diet snapshot is host-owned, never an update grant")
    var withoutDietDecision = WorkspaceAPIExposure.decisions
    withoutDietDecision.removeValue(forKey: dietKey)
    expect(WorkspaceAPIExposure.violations(decisions: withoutDietDecision).contains("Unclassified field: " + dietKey), "removing the snapshot decision must fail the actual census")
    let failures = WorkspaceAPIExposure.violations()
    for failure in failures { expect(false, "WorkspaceAPIExposure: \(failure)") }
    let sample: Set<String> = ["field"]
    expect(WorkspaceAPIExposure.violations(fields: sample, decisions: [:]).contains("Unclassified field: field"), "exposure audit rejects missing decisions")
    expect(WorkspaceAPIExposure.violations(fields: [], decisions: ["old": .internal]).contains("Stale API decision: old"), "exposure audit rejects stale decisions")
    expect(!WorkspaceAPIExposure.violations(fields: sample, decisions: ["field": .notExposed(" \n")]).isEmpty, "exposure audit rejects blank reasons")
    expect(!WorkspaceAPIExposure.violations(fields: sample, decisions: ["field": .exposed(.agentUpdate)], exposedOperations: []).isEmpty, "exposure audit requires a callable tool")
    expect(WorkspaceAPIExposure.decisions["agent.identityColor"] == .exposed(.agentUpdate), "agent colour remains exposed")
    expect(WorkspaceAPIExposure.decisions["agent.displayName"] == .exposed(.agentUpdate), "agent name is exposed through agent.update")
    if failures.isEmpty { print("WorkspaceAPIExposureChecks passed: \(WorkspaceAPIExposure.fields.count) real coding keys classified") }
}
