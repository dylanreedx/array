import ContinuumRevivedCore
import CryptoKit
import Foundation

extension WorkspaceAPIService {
    /// `agent.notify`: the caller's own task, nothing else. needs_input holds a
    /// request on the caller's bound run, which the relay's task policy turns
    /// into at most one alert; completed never alerts by itself. The message is
    /// the agent's transcript's business and goes nowhere from here.
    func notify(agentId: AgentID, requestId: String, payload: [String: Any], isCancelled: () -> Bool) -> Reply {
        let request: AgentNotifyRequest
        do {
            request = try JSONDecoder().decode(AgentNotifyRequest.self, from: JSONSerialization.data(withJSONObject: payload))
        } catch {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "reason (needs_input or completed) and message are required."))
        }
        let message = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.count <= AgentNotifyRequest.messageLimit else {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "message must say what you need or did, in at most \(AgentNotifyRequest.messageLimit) characters. Nothing was recorded."))
        }
        let key = request.idempotencyKey ?? requestId
        var normalized = request
        normalized.idempotencyKey = nil
        guard let encoded = try? Self.encoder.encode(normalized) else {
            return .error(WorkspaceAPIError(code: .invalidRequest, message: "The request could not be encoded."))
        }
        let hash = String(decoding: encoded, as: UTF8.self)
        if let cached = agentNotifyIdempotency[agentId]?[key] {
            guard cached.payloadHash == hash else {
                return .error(WorkspaceAPIError(code: .idempotencyConflict, message: "This idempotencyKey was already used with a different request."))
            }
            return .result(Self.jsonObject(cached.result)!)
        }
        if isCancelled() {
            remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .agentNotify, outcome: "cancelledBeforeEffect"))
            return .cancelled(result: nil)
        }

        let delivery = companionNotifyDelivery()
        let outcome: AgentNotifyResult.Outcome
        var explanation: String
        switch request.reason {
        case .needsInput:
            switch supervisor.requestCompanionAttention(agentID: agentId, requestID: Self.attentionRequestID(agentId: agentId, key: key)) {
            case .recorded?, .alreadyRecorded?:
                outcome = .recorded
                explanation = "Recorded: your task now needs the user until someone sends you your next turn. " + Self.deliverySentence(delivery)
            case .coalesced?:
                outcome = .coalesced
                explanation = "This turn already asked for the user, so nothing new was sent."
            case .notRunning?, nil:
                outcome = .unavailable
                explanation = "Nothing was recorded: Array is not tracking a running task for you, so no alert will follow. Ask in your reply instead."
            }
        case .completed:
            switch supervisor.withdrawCompanionAttention(agentID: agentId) {
            case nil:
                outcome = .unavailable
                explanation = "Nothing was recorded: Array is not tracking a task for you, so no completion alert will follow."
            case let withdrew?:
                outcome = .coalesced
                explanation = (withdrew ? "Your earlier request for the user was withdrawn. " : "")
                    + "Nothing separate is sent: Array announces the task once, when it and every agent in it has finished."
            }
        }
        let result = AgentNotifyResult(operationId: requestId, agentId: agentId, reason: request.reason,
                                       outcome: outcome, phoneDelivery: delivery, explanation: explanation)
        remember(agentId: agentId, WorkspaceRecentOperation(requestId: requestId, op: .agentNotify, outcome: outcome.rawValue))
        agentNotifyIdempotency[agentId, default: [:]][key] = CachedAgentNotify(payloadHash: hash, result: result)
        agentNotifyIdempotencyOrder[agentId, default: []].append(key)
        while (agentNotifyIdempotencyOrder[agentId]?.count ?? 0) > Self.idempotencyCapacity {
            let evicted = agentNotifyIdempotencyOrder[agentId]!.removeFirst()
            agentNotifyIdempotency[agentId]?[evicted] = nil
        }
        return .result(Self.jsonObject(result)!)
    }

    /// Stable per agent and key, and carries neither: the relay only sees it as
    /// part of a decision identity.
    static func attentionRequestID(agentId: AgentID, key: String) -> String {
        let digest = SHA256.hash(data: Data("\(agentId.rawValue.uuidString)|\(key)".utf8))
        return "notify-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func deliverySentence(_ delivery: AgentNotifyResult.PhoneDelivery) -> String {
        switch delivery {
        case .taskAlerts: return "The paired phone is alerted under the task policy."
        case .noPairedPhone: return "No phone is paired, so no phone alert will arrive; tell the user in your reply."
        case .relayWithoutTaskAlerts: return "The relay does not support task alerts yet, so no phone alert will arrive; tell the user in your reply."
        case .unknown: return "Whether a phone alert can arrive is not known yet."
        }
    }
}
