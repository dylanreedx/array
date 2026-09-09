import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// CX-01 Phase 2a (`.plans/59` §11, §14.1, §17 Phase 2): `agent.find` and
// `agent.inspect`. Both are READS over the supervisor's records, its turn facts
// and the semantic transcript projection it already holds. Nothing here calls a
// runner, sends, stops, marks visited/complete, enters focus, moves the camera
// or arms a zone — the app leg `--workspace-api-agents-check` asserts every one
// of those baselines unchanged around each call.
//
// Grant policy (decided here, documented in the Core file): the session preset
// covers `agent.find` over the caller's own checkout and `agent.inspect` of the
// caller itself. Any other agent's evidence needs the trusted approval prompt,
// which names the target agent; once or for the session. Rechecked at dispatch
// and immediately before the content is returned (§14.1).
extension WorkspaceAPIService {

    // MARK: - agent.find

    func findAgents(
        agentId: AgentID, record: AgentRecord, ownHandle: CheckoutHandle,
        payload: [String: Any], runtime: WorkspaceRuntime, canvas: CanvasNSView
    ) -> Reply {
        let request: AgentFindRequest
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            request = try JSONDecoder().decode(AgentFindRequest.self, from: data)
        } catch {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "The find request could not be decoded: \(error.localizedDescription)"))
        }
        let live = grants[agentId] ?? []
        let discoverable = WorkspaceToolGrantEvaluator.discoverableCheckouts(agentId: agentId, grants: live, currentGeneration: revocationGeneration(for: agentId))
        guard !discoverable.isEmpty else {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "This agent may not discover agents."))
        }
        if let explicit = request.checkoutHandle, !discoverable.contains(explicit) {
            // Names nothing about that checkout. Cross-checkout discovery is not a
            // Phase 2a approval seam.
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "agent.find is limited to the checkouts this agent may read; that checkout is not one of them."))
        }
        let inspectable = WorkspaceToolGrantEvaluator.inspectableAgents(agentId: agentId, grants: live, currentGeneration: revocationGeneration(for: agentId))
        let generationAtGrant = revocationGeneration(for: agentId)
        let now = Date()

        let checkouts = request.checkoutHandle.map { Set([$0]) } ?? discoverable
        var facts: [AgentFindCandidateFacts] = []
        for candidate in supervisor.records.values {
            let handle = Self.ownCheckoutHandle(candidate)
            let inCheckout = checkouts.contains(handle)
            // An approved inspect target is discoverable even outside the caller's
            // checkouts, but an explicit checkout filter still binds.
            guard inCheckout || (request.checkoutHandle == nil && inspectable.contains(candidate.id)) else { continue }
            let identity = projectionIdentity(for: candidate, handle: handle, canvas: canvas)
            if let zone = request.zoneId, identity.zoneId != zone { continue }
            let document = supervisor.transcriptDocumentProjection(for: candidate.id)
            facts.append(AgentFindCandidateFacts(
                identity: identity,
                taskTitle: document.flatMap(Self.promptTitle(from:)),
                referencedFiles: document.map { Self.referencedFiles(from: $0, checkoutRoot: candidate.checkoutRoot) } ?? [],
                evidenceAvailable: document != nil,
                isCaller: candidate.id == agentId))
        }
        let context = AgentFindRanker.Context(
            callerCheckout: ownHandle,
            callerZoneId: record.tileId.flatMap { canvas.zoneId(containing: $0) },
            now: now)
        let ranking = AgentFindRanker.rank(query: request.query, context: context, candidates: facts, limit: request.effectiveLimit)
        var response = AgentFindResponse(
            query: request.query, candidates: ranking.candidates, ambiguous: ranking.ambiguous,
            truncated: false, observedAt: now)
        while let data = try? Self.encoder.encode(response),
              data.count > AgentFindResponse.encodedByteCeiling,
              !response.candidates.isEmpty {
            response.candidates.removeLast()
            response.truncated = true
        }
        // §14.1: recheck immediately before content leaves.
        guard supervisor.records[agentId]?.workspaceToolsEnabled == true, revocationGeneration(for: agentId) == generationAtGrant else {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "Access was revoked before the candidates were returned."))
        }
        guard let object = Self.jsonObject(response) else {
            return .error(WorkspaceAPIError(code: .unsupported, message: "Candidates could not be encoded."))
        }
        return .result(object)
    }

    // MARK: - agent.inspect

    func inspectAgent(
        agentId: AgentID, record: AgentRecord, ownHandle: CheckoutHandle,
        payload: [String: Any], canvas: CanvasNSView
    ) -> Reply {
        let request: AgentInspectRequest
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            request = try JSONDecoder().decode(AgentInspectRequest.self, from: data)
        } catch {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "The inspect request needs an agentId: \(error.localizedDescription)"))
        }
        let live = grants[agentId] ?? []
        guard live.contains(where: { $0.revocationGeneration == revocationGeneration(for: agentId) && $0.operations.contains(.agentInspect) }) else {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "This agent may not inspect agents."))
        }
        guard let target = supervisor.records[request.agentId] else {
            return .error(WorkspaceAPIError(code: .notFound, message: "No agent with that id is known to this host. Re-resolve it through array_find_agent."))
        }

        // Grant on the TARGET agent. "Allow once" is spent the moment it authorizes.
        var approvalRequestId: String?
        switch WorkspaceToolGrantEvaluator.evaluateAgentInspect(
            agentId: agentId, target: target.id, grants: live, currentGeneration: revocationGeneration(for: agentId)) {
        case .denied:
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "This agent may not inspect agents."))
        case .scopeApprovalRequired:
            let promptId = UUID().uuidString
            approvalRequestId = promptId
            approvalPromptCount += 1
            let targetHandle = Self.ownCheckoutHandle(target)
            let targetCheckoutName = knownCheckouts()[targetHandle]?.displayName
                ?? URL(fileURLWithPath: CheckoutHandle.canonicalRoot(target.checkoutRoot)).lastPathComponent
            let decision = approvalHandler(ScopeApprovalPrompt(
                requestId: promptId, agentId: agentId, agentDisplayName: record.displayName,
                checkout: targetHandle, checkoutDisplayName: targetCheckoutName,
                op: .agentInspect, relativePath: nil,
                targetAgentId: target.id, targetAgentDisplayName: target.displayName))
            guard supervisor.records[agentId]?.workspaceToolsEnabled == true else {
                return .error(WorkspaceAPIError(code: .permissionDenied, message: "Workspace tools were disabled for this agent.", approvalRequestId: promptId))
            }
            switch decision {
            case .deny:
                return .error(WorkspaceAPIError(code: .permissionDenied, message: "The user declined access to that agent.", approvalRequestId: promptId))
            case .allowOnce:
                mint(WorkspaceToolGrant(
                    agentId: agentId, checkoutHandles: [], operations: [.agentInspect],
                    presentationCeiling: .preserveAll, issuer: .userApprovalOnce(requestId: promptId),
                    revocationGeneration: revocationGeneration(for: agentId), singleUse: true, inspectableAgentIds: [target.id]))
            case .allowForSession:
                mint(WorkspaceToolGrant(
                    agentId: agentId, checkoutHandles: [], operations: [.agentInspect],
                    presentationCeiling: .preserveAll, issuer: .userApprovalSession(requestId: promptId),
                    revocationGeneration: revocationGeneration(for: agentId), inspectableAgentIds: [target.id]))
            }
            guard case .allowed = WorkspaceToolGrantEvaluator.evaluateAgentInspect(
                agentId: agentId, target: target.id, grants: grants[agentId] ?? [], currentGeneration: revocationGeneration(for: agentId)) else {
                return .error(WorkspaceAPIError(code: .permissionDenied, message: "Approval did not take.", approvalRequestId: promptId))
            }
        case .allowed:
            break
        }
        consumeSingleUseInspectGrant(agentId: agentId, target: target.id)
        let generationAtGrant = revocationGeneration(for: agentId)

        // Evidence: a projection of what this host observed. Reads only.
        let now = Date()
        let identity = projectionIdentity(for: target, handle: Self.ownCheckoutHandle(target), canvas: canvas)
        let document = supervisor.transcriptDocumentProjection(for: target.id)
        var response = AgentInspectResponse(
            agent: identity,
            isCaller: target.id == agentId,
            lastActivityAt: target.lastActivityAt,
            latestPromptAt: target.latestPromptAt,
            latestTurnAt: target.latestTurnAt,
            terminalOutcome: target.latestTerminalEvent?.outcome.rawValue,
            promptTitle: nil,
            transcriptAvailable: document != nil,
            recentEvents: [],
            recentEventsTruncated: false,
            referencedFiles: [],
            evidenceSource: document == nil ? "record" : "supervisor.transcriptProjection",
            note: document == nil ? AgentInspectResponse.absentEvidenceNote : nil,
            observedAt: now)
        if let document {
            response.promptTitle = Self.promptTitle(from: document)
            let bounded = AgentInspectExcerpt.bound(
                Self.evidenceItems(from: document),
                maxItems: request.effectiveMaxEvents,
                byteCeiling: AgentInspectResponse.excerptByteCeiling)
            response.recentEvents = bounded.items
            response.recentEventsTruncated = bounded.truncated
            response.referencedFiles = Self.referencedFiles(from: document, checkoutRoot: target.checkoutRoot)
        }
        // Whole-response ceiling: shed the oldest evidence first, then file names;
        // identity and status are never cut.
        while let data = try? Self.encoder.encode(response), data.count > AgentInspectResponse.encodedByteCeiling {
            if !response.recentEvents.isEmpty {
                response.recentEvents.removeFirst()
                response.recentEventsTruncated = true
            } else if !response.referencedFiles.isEmpty {
                response.referencedFiles.removeLast()
            } else {
                break
            }
        }
        // §14.1: recheck immediately before the content is returned.
        guard supervisor.records[agentId]?.workspaceToolsEnabled == true, revocationGeneration(for: agentId) == generationAtGrant else {
            return .error(WorkspaceAPIError(code: .permissionDenied, message: "Access was revoked before the evidence was returned.", approvalRequestId: approvalRequestId))
        }
        guard let object = Self.jsonObject(response) else {
            return .error(WorkspaceAPIError(code: .unsupported, message: "Evidence could not be encoded.", approvalRequestId: approvalRequestId))
        }
        return .result(object)
    }

    private func consumeSingleUseInspectGrant(agentId: AgentID, target: AgentID) {
        guard var live = grants[agentId] else { return }
        let durable = live.contains { !$0.singleUse && $0.operations.contains(.agentInspect) && $0.inspectableAgentIds.contains(target) && $0.revocationGeneration == revocationGeneration(for: agentId) }
        guard !durable, let index = live.firstIndex(where: { $0.singleUse && $0.operations.contains(.agentInspect) && $0.inspectableAgentIds.contains(target) }) else { return }
        live.remove(at: index)
        grants[agentId] = live
    }

    // MARK: - Projection helpers (reads only)

    private func projectionIdentity(for record: AgentRecord, handle: CheckoutHandle, canvas: CanvasNSView) -> AgentProjectionIdentity {
        AgentProjectionIdentity(
            agentId: record.id,
            displayName: record.displayName,
            role: record.role,
            harness: (record.harness ?? AgentHarnessConfig.resolved()).rawValue,
            checkoutHandle: handle,
            projectId: record.projectId,
            zoneId: record.tileId.flatMap { canvas.zoneId(containing: $0) },
            tileId: record.tileId,
            parentAgentId: record.parentAgentID,
            status: observedStatus(for: record.id),
            observedAt: record.lastActivityAt)
    }

    private func observedStatus(for id: AgentID) -> AgentObservedStatus {
        guard let snapshot = supervisor.turnSnapshot(for: id) else { return .unknown }
        switch snapshot.state {
        case .ready: return .ready
        case .starting: return .starting
        case .working: return .working
        case .compacting: return .compacting
        case .queued: return .queued
        case .needsAction: return .needsAction
        case .failed: return .failed
        case .restored: return .restored
        }
    }

    /// The latest user prompt's first line, capped. Data, not a command.
    static func promptTitle(from document: AgentDocument) -> String? {
        for entry in document.entries.reversed() where entry.role == .user {
            for block in entry.blocks {
                if case let .paragraph(inlines) = block.payload {
                    let text = plainText(inlines).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
                    return String(firstLine.prefix(120))
                }
            }
        }
        return nil
    }

    /// Oldest first; the excerpt bounder keeps the newest. Only the block kinds
    /// with an obvious textual reading are projected; opaque and layout blocks
    /// are skipped rather than guessed at.
    static func evidenceItems(from document: AgentDocument) -> [AgentInspectEvidenceItem] {
        var items: [AgentInspectEvidenceItem] = []
        for entry in document.entries {
            let at = entry.createdAt ?? entry.finishedAt
            var blocks = entry.blocks
            var index = 0
            while index < blocks.count {
                let block = blocks[index]
                index += 1
                if !block.children.isEmpty { blocks.insert(contentsOf: block.children, at: index) }
                let item: AgentInspectEvidenceItem?
                switch block.payload {
                case let .paragraph(inlines):
                    item = AgentInspectEvidenceItem(kind: entry.role.rawValue, at: at, text: plainText(inlines))
                case let .heading(_, content):
                    item = AgentInspectEvidenceItem(kind: entry.role.rawValue, at: at, text: plainText(content))
                case let .fencedCode(code):
                    item = AgentInspectEvidenceItem(kind: entry.role.rawValue, at: at, text: code.code)
                case let .toolCall(call):
                    var text = call.name
                    if let summary = call.summary, !summary.isEmpty { text += " — " + summary }
                    text += " [\(call.status.rawValue)]"
                    item = AgentInspectEvidenceItem(kind: "toolCall", at: at, text: text)
                case let .commandOutput(output):
                    item = AgentInspectEvidenceItem(kind: "commandOutput", at: at, text: output.text)
                case let .error(error):
                    item = AgentInspectEvidenceItem(kind: "error", at: at, text: error.message)
                case let .notice(notice):
                    item = AgentInspectEvidenceItem(kind: "notice", at: at, text: plainText(notice.message))
                case let .fileReferences(refs):
                    item = AgentInspectEvidenceItem(kind: "fileReferences", at: at, text: refs.files.map(\.displayName).joined(separator: ", "))
                case let .diff(diff):
                    // A `.fileChange` item projects here (summary = provider label).
                    item = AgentInspectEvidenceItem(kind: "diff", at: at, text: diff.summary ?? diff.text)
                default:
                    item = nil
                }
                if let item, !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    items.append(item)
                }
            }
        }
        return items
    }

    /// Checkout-relative paths named by tool-call arguments and file-reference
    /// blocks. Absolute paths inside the checkout are made relative; anything
    /// outside it is dropped, so no raw path ever crosses (§7.3). Capped.
    static func referencedFiles(from document: AgentDocument, checkoutRoot: String) -> [String] {
        let root = CheckoutHandle.canonicalRoot(checkoutRoot) + "/"
        var seen = Set<String>()
        var files: [String] = []
        func consider(_ raw: String) {
            guard files.count < AgentInspectResponse.referencedFilesCap else { return }
            var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, path.count < 300, !path.contains(where: \.isWhitespace),
                  !path.lowercased().hasPrefix("http") else { return }
            if path.hasPrefix("/") {
                guard path.hasPrefix(root) else { return }
                path = String(path.dropFirst(root.count))
            }
            while path.hasPrefix("./") { path = String(path.dropFirst(2)) }
            guard !path.isEmpty, !path.hasPrefix(".."), !path.contains("/../") else { return }
            let looksLikeFile = path.contains("/") || path.range(of: #"\.[A-Za-z0-9]{1,8}$"#, options: .regularExpression) != nil
            guard looksLikeFile, seen.insert(path).inserted else { return }
            files.append(path)
        }
        func walk(_ value: AgentOpaqueValue) {
            switch value {
            case let .string(string): consider(string)
            case let .array(values): values.forEach(walk)
            case let .object(object): object.keys.sorted().forEach { walk(object[$0]!) }
            case .null, .bool, .integer, .number: break
            }
        }
        for entry in document.entries {
            var blocks = entry.blocks
            var index = 0
            while index < blocks.count {
                let block = blocks[index]
                index += 1
                if !block.children.isEmpty { blocks.insert(contentsOf: block.children, at: index) }
                switch block.payload {
                case let .toolCall(call):
                    if let arguments = call.arguments { walk(arguments) }
                case let .fileReferences(refs):
                    refs.files.map(\.displayName).forEach(consider)
                case let .diff(diff):
                    diff.files.map(\.displayName).forEach(consider)
                    if let summary = diff.summary { consider(summary) }
                default:
                    break
                }
            }
        }
        return files
    }

    private static func plainText(_ inlines: [AgentInline]) -> String {
        var out = ""
        for inline in inlines {
            switch inline {
            case let .text(text): out += text
            case let .code(code): out += code
            case let .emphasis(children), let .strong(children): out += plainText(children)
            case let .link(_, _, children): out += plainText(children)
            case .softBreak: out += " "
            case .hardBreak: out += "\n"
            }
        }
        return out
    }
}
