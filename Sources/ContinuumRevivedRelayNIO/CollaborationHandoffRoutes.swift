import Foundation
import NIOHTTP1
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationService

enum CollaborationHandoffRoutes {
    static func route(head: HTTPRequestHead, body: Data, token: String, store: CollaborationStore) async throws -> Response? {
        let p = head.uri.split(separator: "/").map(String.init)
        guard p.count >= 5, p[2] == "areas", let area = UUID(uuidString: p[3]) else { return nil }
        let decoder = JSONDecoder()
        if p.count == 5, p[4] == "agent-hosts", head.method == .POST {
            return .json(.ok, try await store.registerAgentHost(token: token, area: area,
                request: decoder.decode(Collaboration.AgentHostRegistration.self, from: body)))
        }
        if p.count == 7, p[4] == "agents", let object = UUID(uuidString: p[5]) {
            if p[6] == "control", head.method == .GET {
                return .json(.ok, try await store.agentControl(token: token, area: area, object: .init(object)))
            }
            if p[6] == "control", head.method == .POST {
                return .json(.ok, try await store.changeAgentControl(token: token, area: area, object: .init(object),
                    request: decoder.decode(Collaboration.AgentControlMutation.self, from: body)))
            }
            if p[6] == "prompts", head.method == .POST {
                return .json(.ok, try await store.enqueueAgentPrompt(token: token, area: area, object: .init(object),
                    request: decoder.decode(Collaboration.AgentPromptRequest.self, from: body)))
            }
        }
        if p.count == 7, p[4] == "agent-hosts", p[6] == "commands", let host = UUID(uuidString: p[5]), head.method == .GET {
            return .json(.ok, try await store.pendingAgentDispatches(token: token, area: area, host: .init(host)))
        }
        if p.count >= 6, p[4] == "agent-commands", let id = UUID(uuidString: p[5]) {
            if p.count == 6, head.method == .GET {
                return .json(.ok, try await store.agentDispatchReceipt(token: token, area: area, id: id))
            }
            if p.count == 7, head.method == .POST {
                if p[6] == "claim" || p[6] == "admit" {
                    return .json(.ok, try await store.claimAgentDispatch(token: token, area: area, id: id,
                        claim: decoder.decode(Collaboration.AgentHostClaim.self, from: body), admit: p[6] == "admit"))
                }
                if p[6] == "outcome" {
                    return .json(.ok, try await store.finishAgentDispatch(token: token, area: area, id: id,
                        outcome: decoder.decode(Collaboration.AgentHostOutcome.self, from: body)))
                }
            }
        }
        return nil
    }
}
