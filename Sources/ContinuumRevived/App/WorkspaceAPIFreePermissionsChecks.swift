import AppKit
import ContinuumRevivedCore
import Foundation

/// `--workspace-api-free-permissions-check`: Settings ▸ Agents ▸ Agent
/// permissions, through the production mount (which points the supervisor at
/// `qaSettingsDefaults`, an isolated suite here) and the production dispatch.
///
/// Free within a project, the default: delegating, messaging any agent in the
/// project (child, parent, sibling, one the user started), inspecting it and
/// arranging the canvas never reach the approval UI, and each one really
/// happens. What Free must NOT loosen: a message into another project is
/// refused, inspecting or opening across projects still asks, the per-agent
/// switch still revokes, and a chain of agent-started turns stops. Leaving Free
/// takes its grants back; Off creates agents without workspace tools.
///
/// The approval stand-in DECLINES everything, so a gated request that succeeds
/// here was approved by the policy and nothing else.
@MainActor
func runWorkspaceAPIFreePermissionsChecks() async throws {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }
    guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil else {
        throw Failure(message: "refusing to run without CONTINUUM_APP_SUPPORT — this leg mints durable agent records and must never write a real store")
    }
    guard Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
        throw Failure(message: "refusing to run from the PROD bundle — dev channel only")
    }

    // A fake `pi --mode rpc` that logs each prompt in its cwd and settles at
    // once. No model, no auth, no network.
    let fileManager = FileManager.default
    let binDir = fileManager.temporaryDirectory
        .appendingPathComponent("continuum-free-permissions-bin-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: binDir) }
    let fakePi = """
    #!/usr/bin/env python3
    import json, os, sys, threading, time

    def emit(obj):
        sys.stdout.write(json.dumps(obj) + "\\n")
        sys.stdout.flush()

    def handle(cmd):
        kind = cmd.get("type")
        if kind == "prompt":
            with open(os.path.join(os.getcwd(), "prompts.log"), "a") as log:
                log.write(json.dumps(cmd.get("message") or cmd.get("prompt") or "") + "\\n")
            emit({"type": "response", "id": cmd.get("id"), "command": "prompt", "success": True})
            emit({"type": "agent_start"})
            emit({"type": "turn_start"})
            emit({"type": "turn_end"})
            emit({"type": "agent_end", "willRetry": False})
            emit({"type": "agent_settled"})
        else:
            emit({"type": "response", "id": cmd.get("id"), "command": kind, "success": True, "data": {}})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        threading.Thread(target=handle, args=(obj,), daemon=True).start()

    time.sleep(0.3)
    """
    let executable = binDir.appendingPathComponent("pi")
    try fakePi.write(to: executable, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    setenv("PATH", "\(binDir.path):\(originalPath)", 1)
    defer { setenv("PATH", originalPath, 1) }
    let model = "openai-codex/gpt-5.6-sol"
    AgentModelCatalog.shared.resetForQA(snapshot: .init(
        harness: .pi, readiness: .ready, models: [model],
        displayNames: [model: "Fixture"], contextWindows: [model: 200_000]))

    // MARK: The default is Free, and the mount reads it from Settings

    guard let settings = QAIsolatedDefaults(isolatedSuiteName: "array.qa.free-permissions.\(UUID().uuidString)") else {
        throw Failure(message: "setup: no isolated defaults suite")
    }
    defer { settings.removePersistentDomain(forName: settings.suiteDomainName) }
    try expect(WorkspaceToolsConfig.permission(defaults: settings) == .free,
               "with nothing set, Agent permissions must be Free within a project")

    let f = try WorkspaceAPIChecks.makeFixture(settings: settings)
    defer { f.tearDown() }
    let supervisor = f.delegate.qaAgentSupervisor
    defer { supervisor.stopAll() }
    let api = f.api
    let parentId = f.agentId

    settings.set(WorkspaceToolsPermission.askFirst.rawValue, forKey: WorkspaceToolsConfig.permissionKey)
    try expect(supervisor.workspaceToolsPermission() == .askFirst,
               "after the boot mount the supervisor must read Agent permissions from Settings, live")
    settings.removeObject(forKey: WorkspaceToolsConfig.permissionKey)
    try expect(supervisor.workspaceToolsPermission() == .free, "back to the default, Free")

    // A new agent under Free starts with workspace tools; nobody turned them on.
    try expect(supervisor.records[parentId]?.workspaceToolsEnabled == true,
               "an agent created under Free must start with Workspace Tools on")

    var prompts: [WorkspaceAPIService.ScopeApprovalPrompt] = []
    api.approvalHandler = { prompt in prompts.append(prompt); return .deny }

    var counter = 0
    func dispatch(_ caller: AgentID, _ op: String, _ payload: [String: Any]) -> WorkspaceAPIService.Reply {
        counter += 1
        return api.dispatch(agentId: caller, requestId: "free-\(counter)", op: op, payload: payload)
    }
    func result(_ reply: WorkspaceAPIService.Reply, _ what: String) throws -> [String: AnyHashableJSON] {
        guard case let .result(object) = reply else { throw Failure(message: "\(what): expected a result, got \(reply)") }
        return object
    }
    func failure(_ reply: WorkspaceAPIService.Reply, _ code: WorkspaceAPIError.Code, _ what: String) throws -> WorkspaceAPIError {
        guard case let .error(error) = reply, error.code == code else {
            throw Failure(message: "\(what): expected \(code.rawValue), got \(reply)")
        }
        return error
    }
    func promptLog(_ root: URL) -> String {
        (try? String(contentsOf: root.appendingPathComponent("prompts.log"), encoding: .utf8)) ?? ""
    }
    func idle(_ ids: AgentID...) async throws {
        let settled = await waitUntil(timeout: 30, pollInterval: 0.05) { ids.allSatisfy { !supervisor.isRunning($0) } }
        try expect(settled, "agents must settle between turns; the fake pi settles at once")
    }
    func message(_ from: AgentID, _ to: AgentID, _ text: String) -> WorkspaceAPIService.Reply {
        dispatch(from, "agent.message", ["agentId": to.rawValue.uuidString, "text": text, "idempotencyKey": "key-\(UUID().uuidString)"])
    }
    func delivered(_ from: AgentID, _ to: AgentID, _ marker: String, _ what: String, in root: URL? = nil) async throws {
        try await idle(from, to)
        let before = prompts.count
        let reply = try result(message(from, to, "\(marker): \(what)"), what)
        try expect(reply["delivery"]?.string == "delivered", "\(what): the message must be delivered, got \(reply)")
        try expect(prompts.count == before, "\(what): Free must not ask the user, but the approval UI saw \(prompts.suffix(from: before).map(\.op))")
        let arrived = await waitUntil(timeout: 10, pollInterval: 0.05) { promptLog(root ?? f.pbRoot).contains(marker) }
        try expect(arrived, "\(what): the text must reach the target's own runner")
    }

    // MARK: Context reports the gated operations as callable

    let context = try result(dispatch(parentId, "workspace.context", [:]), "context")
    let capabilities = Set(context["capabilities"]?.array?.compactMap(\.string) ?? [])
    try expect(capabilities.isSuperset(of: ["agent.delegate", "agent.message", "canvas.apply"]),
               "under Free the context must list delegate, message and canvas.apply as callable: \(capabilities)")
    try expect(context["approvalRequired"]?.array?.isEmpty ?? true,
               "under Free nothing inside the project is approval-required: \(String(describing: context["approvalRequired"]))")

    // MARK: Delegate twice, no prompt

    func delegate(_ marker: String, _ key: String) throws -> AgentID {
        let reply = try result(dispatch(parentId, "agent.delegate", ["task": "\(marker): run the leg", "title": marker, "idempotencyKey": key]), "delegate \(marker)")
        guard let id = reply["childAgentId"]?.string.flatMap(UUID.init(uuidString:)).map(AgentID.init(rawValue:)) else {
            throw Failure(message: "delegate \(marker): no childAgentId in \(reply)")
        }
        return id
    }
    let childA = try delegate("FREE-CHILD-A", "free-d1")
    let childB = try delegate("FREE-CHILD-B", "free-d2")
    try expect(prompts.isEmpty, "delegating under Free must not ask the user: \(prompts.map(\.op))")
    try expect(api.policyApprovalCount == 1,
               "one policy approval covers the session's delegations, got \(api.policyApprovalCount)")
    try expect(supervisor.records[childA]?.parentAgentID == parentId && supervisor.records[childB]?.parentAgentID == parentId,
               "both children are the caller's, by record")
    try expect(supervisor.records[childA]?.workspaceToolsEnabled == true,
               "a child created under Free gets Workspace Tools, so it can orchestrate too")

    // MARK: Message down, up, sideways, and to an agent the user started

    let userAgent = try supervisor.spawn(
        role: nil, prompt: nil, cwd: f.pbRoot, harness: .pi, model: model, thinking: "high",
        projectId: f.projectPb, projectRoot: f.pbRoot, isolated: false)
    let stranger = try supervisor.spawn(
        role: nil, prompt: nil, cwd: f.paRoot, harness: .pi, model: model, thinking: "high",
        projectId: f.projectPa, projectRoot: f.paRoot, isolated: false)
    try await delivered(parentId, childA, "FREE-DOWN", "parent to its child")
    try await delivered(childA, parentId, "FREE-UP", "child to its parent")
    try await delivered(childA, childB, "FREE-SIDEWAYS", "sibling to sibling")
    try await delivered(parentId, userAgent, "FREE-NEIGHBOUR", "to an agent the user started in the same project")

    // The same project in another checkout (a worktree, say): findable and
    // reachable under Free, though agent.find otherwise covers own checkouts.
    let otherCheckout = f.pbRoot.deletingLastPathComponent().appendingPathComponent("Pb-other-checkout", isDirectory: true)
    try fileManager.createDirectory(at: otherCheckout, withIntermediateDirectories: true)
    let otherCheckoutAgent = try supervisor.spawn(
        role: nil, prompt: nil, cwd: otherCheckout, harness: .pi, model: model, thinking: "high",
        projectId: f.projectPb, projectRoot: otherCheckout, isolated: false)
    let found = try result(dispatch(parentId, "agent.find", ["query": otherCheckoutAgent.rawValue.uuidString]), "find across the project's checkouts")
    let foundIds = found["candidates"]?.array?.compactMap { $0.object?["agent"]?.object?["agentId"]?.string } ?? []
    try expect(foundIds.contains(otherCheckoutAgent.rawValue.uuidString),
               "under Free agent.find must list an agent in another checkout of the same project: \(foundIds)")
    try await delivered(parentId, otherCheckoutAgent, "FREE-OTHER-CHECKOUT", "to an agent in another checkout of the same project", in: otherCheckout)

    // MARK: What Free must not loosen

    let promptsBefore = prompts.count
    let crossProject = try failure(message(parentId, stranger, "FREE-CROSS: reach another project"),
                                   .permissionDenied, "a message into another project")
    try expect(prompts.count == promptsBefore, "a message into another project is refused, not asked")
    try expect(!crossProject.message.contains("/") && crossProject.message.range(of: "[0-9A-Fa-f]{8}-", options: .regularExpression) == nil,
               "the refusal names no path and no id: \(crossProject.message)")
    try expect(!promptLog(f.paRoot).contains("FREE-CROSS"), "nothing reached the other project's agent")

    _ = try result(dispatch(parentId, "agent.inspect", ["agentId": userAgent.rawValue.uuidString]),
                   "inspect an agent in the same project")
    try expect(prompts.count == promptsBefore, "inspecting an agent in the same project must not ask under Free")
    _ = try failure(dispatch(parentId, "agent.inspect", ["agentId": stranger.rawValue.uuidString]),
                    .permissionDenied, "inspect an agent in another project, declined")
    try expect(prompts.count == promptsBefore + 1 && prompts.last?.op == .agentInspect && prompts.last?.targetAgentId == stranger,
               "inspecting across projects must still ask the user, naming the agent: \(prompts.map(\.op))")
    _ = try failure(dispatch(parentId, "artifact.open", ["checkoutHandle": f.paHandle.rawValue, "relativePath": "notes.md"]),
                    .permissionDenied, "open a file in another project, declined")
    try expect(prompts.count == promptsBefore + 2 && prompts.last?.op == .artifactOpen,
               "opening a file in another project must still ask the user: \(prompts.map(\.op))")

    // The per-agent switch still revokes at once, Free or not.
    try expect(supervisor.setWorkspaceToolsEnabled(agentID: parentId, false), "turn the parent's tools off")
    _ = try failure(message(parentId, userAgent, "FREE-REVOKED"), .permissionDenied, "a message after the switch is off")
    try expect(supervisor.setWorkspaceToolsEnabled(agentID: parentId, true), "turn the parent's tools back on")

    // MARK: A chain of agent-started turns stops

    // Parent and the user's agent bounce one message each way. Hop n is the nth
    // agent-started turn since anything else prompted; the limit's next hop is
    // refused and delivers nothing.
    var hop = 0
    var from = parentId, to = userAgent
    var refusal: WorkspaceAPIError?
    while hop <= WorkspaceAPIService.messageHopLimit + 1 {
        try await idle(from, to)
        let reply = message(from, to, "FREE-CHAIN-\(hop)")
        if case let .error(error) = reply {
            refusal = error
            break
        }
        _ = try result(reply, "chain hop \(hop + 1)")
        hop += 1
        swap(&from, &to)
    }
    // The bounce started on the parent's FREE-UP turn, which was hop 1, so the
    // first refusal lands one hop before the bounce's own count reaches the limit.
    try expect(refusal?.code == .unsupported && hop >= WorkspaceAPIService.messageHopLimit - 2 && hop < WorkspaceAPIService.messageHopLimit,
               "an endless agent-to-agent chain must stop near \(WorkspaceAPIService.messageHopLimit) hops; stopped after \(hop) with \(String(describing: refusal))")
    try expect(!promptLog(f.pbRoot).contains("FREE-CHAIN-\(hop)\""), "the refused hop delivered nothing")
    try expect(refusal?.message.contains("user") == true, "the refusal tells the agent to hand back to the user: \(refusal?.message ?? "")")
    // A prompt from the user breaks the chain.
    try await idle(from, to)
    try expect(supervisor.send("the user steps in", to: from), "a user prompt to the agent whose hop was refused")
    try await delivered(from, to, "FREE-AFTER-USER", "the first agent message after the user prompts")

    // MARK: Leaving Free takes its grants back

    settings.set(WorkspaceToolsPermission.askFirst.rawValue, forKey: WorkspaceToolsConfig.permissionKey)
    try await idle(parentId, childA, userAgent)
    let askBefore = prompts.count
    _ = try failure(message(parentId, userAgent, "ASK-NEIGHBOUR"), .permissionDenied, "Ask first: an unrelated agent")
    try expect(prompts.count == askBefore, "under Ask first an unrelated agent is out of reach, refused without asking")
    _ = try failure(message(parentId, childA, "ASK-CHILD"), .permissionDenied, "Ask first: own child, declined")
    try expect(prompts.count == askBefore + 1 && prompts.last?.op == .agentMessage,
               "the Free grant must be gone: messaging a child asks again under Ask first: \(prompts.map(\.op))")
    _ = try failure(dispatch(parentId, "agent.delegate", ["task": "ASK-DELEGATE", "idempotencyKey": "ask-d1"]),
                    .permissionDenied, "Ask first: delegate, declined")
    try expect(prompts.count == askBefore + 2 && prompts.last?.op == .agentDelegate,
               "delegating asks again under Ask first: \(prompts.map(\.op))")
    try expect(!promptLog(f.pbRoot).contains("ASK-"), "nothing declined under Ask first reached any agent")

    // MARK: Off creates agents without workspace tools

    settings.set(WorkspaceToolsPermission.off.rawValue, forKey: WorkspaceToolsConfig.permissionKey)
    let offAgent = try supervisor.spawn(
        role: nil, prompt: nil, cwd: f.pbRoot, harness: .pi, model: model, thinking: "high",
        projectId: f.projectPb, projectRoot: f.pbRoot, isolated: false)
    try expect(supervisor.records[offAgent]?.workspaceToolsEnabled == false,
               "under Off a new agent starts without Workspace Tools")
    try expect(supervisor.records[parentId]?.workspaceToolsEnabled == true,
               "Off changes new agents only; an existing agent keeps its own switch")
}
