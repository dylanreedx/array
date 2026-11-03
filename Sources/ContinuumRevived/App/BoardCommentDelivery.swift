import AppKit
import ContinuumRevivedCore
import ContinuumRevivedAgentUI

/// One project-scoped recipient/loop authority, used by the committed board path.
/// Credits deliberately survive queued turns: a queued prompt must not reset a
/// chain merely because latestPromptAt changes when the queue drains.
@MainActor
final class BoardCommentDelivery {
    private var hops: [AgentID: Int] = [:]
    private var seen: Set<UUID> = []
    private var pending: [AgentID: Task<Void, Never>] = [:]
    var onOutcome: ((AgentID, String) -> Void)?
    static let hopLimit = 6

    func waitForPendingDeliveriesForQA() async {
        for task in Array(pending.values) { await task.value }
    }

    func committed(_ transaction: BoardTransaction, actingAgent: AgentID?, projectID: UUID, supervisor: AgentSupervisor) {
        guard case let .addComment(cardID, comment, _) = transaction.command,
              !transaction.before.cards.flatMap(\.comments).contains(where: { $0.id == comment.id }),
              seen.insert(comment.id).inserted,
              let card = transaction.after.card(cardID) else { return }
        let candidates = supervisor.records.values.filter { $0.projectId == projectID && $0.archivedAt == nil && $0.capabilities.locallyManaged }
        var recipients = Set(card.assignees)
        for agent in candidates {
            let uuidMention = "@" + agent.id.rawValue.uuidString.lowercased()
            let text = comment.body.lowercased()
            let named = "@" + agent.humanDisplayName.lowercased()
            let mentions = [uuidMention, named].contains { mention in
                text.range(of: NSRegularExpression.escapedPattern(for: mention) + "(?=$|[\\s.,!?;:)])", options: .regularExpression) != nil
            }
            if mentions { recipients.insert(agent.id) }
        }
        let depth = actingAgent.map { (hops[$0] ?? 0) + 1 } ?? 0
        for id in recipients.sorted(by: { $0.rawValue.uuidString < $1.rawValue.uuidString }) {
            guard id != actingAgent, comment.authorID != id.rawValue.uuidString.lowercased() else { onOutcome?(id, "quiet_self"); continue }
            guard candidates.contains(where: { $0.id == id }) else { onOutcome?(id, "unavailable"); NSLog("BOARD-COMMENT-AGENT %@ unavailable", id.rawValue.uuidString); continue }
            guard depth <= Self.hopLimit else { onOutcome?(id, "quiet_chain_limit"); continue }
            hops[id] = depth
            // Bound each part independently and the whole prompt, including title.
            let recent = card.comments.filter { $0.id != comment.id }.suffix(3).map {
                "\($0.authorName.prefix(80)): \($0.body.prefix(400))" + ($0.body.count > 400 ? "… [continued in card thread]" : "")
            }.joined(separator: "\n\n")
            let title = String(card.title.prefix(240)) + (card.title.count > 240 ? "…" : "")
            let text = "Card: \(title)\nBoard: \(transaction.after.id) Card: \(cardID)\nNew comment from \(comment.authorName.prefix(80)):\n\(comment.body)\n\nRecent thread:\n\(recent)\n\nReply using array_board_apply op comment on this card."
            let prompt = AgentPrompt(actingAgent.map { supervisor.agentMessageText(text, from: $0) } ?? text)
            let previous = pending[id]
            pending[id] = Task { @MainActor [weak self, weak supervisor] in
                if let previous { await previous.value }
                guard let supervisor else { return }
                var queue = !supervisor.canStartSharedPromptNow(id)
                var result = await supervisor.accept(queue ? .queue(prompt) : .sendPrompt(prompt), for: id)
                if !queue, case .refused(.turnNotReady) = result, !supervisor.canStartSharedPromptNow(id) {
                    queue = true
                    result = await supervisor.accept(.queue(prompt), for: id)
                } else if queue, (result == .refused(.unsupported) || result == .refused(.turnNotReady)), supervisor.canStartSharedPromptNow(id) {
                    // A turn can finish while admission awaits the input gate.
                    queue = false
                    result = await supervisor.accept(.sendPrompt(prompt), for: id)
                }
                let outcome: String
                switch result {
                case .accepted: outcome = queue ? "queued" : "delivered"
                case .refused(let reason): outcome = "failed_\(reason.rawValue)"
                }
                self?.onOutcome?(id, outcome)
                if case .refused = result { NSLog("BOARD-COMMENT-AGENT %@ %@", id.rawValue.uuidString, outcome) }
            }
        }
    }
}

@MainActor
func boardCommentIdentity(_ record: AgentRecord, dark: Bool) -> [String: Any] {
    var value: [String: Any] = ["authorName": record.humanDisplayName, "colour": NSNull(), "character": NSNull()]
    if let name = record.identityColor,
       let rgb = ZoneChromeNSView.color(named: name).usingColorSpace(.deviceRGB) {
        value["colour"] = String(format: "#%02x%02x%02x", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255), Int(rgb.blueComponent * 255))
    }
    let controller = AgentCharacterController.shared
    if let atlas = controller.atlas(for: record.id.rawValue, appearance: dark ? .dark : .light, name: record.characterName),
       let frame = atlas.atlas.frames.first,
       let crop = atlas.image.cropping(to: CGRect(x: CGFloat(frame.x), y: CGFloat(frame.y), width: CGFloat(frame.width), height: CGFloat(frame.height))),
       let data = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]) {
        value["character"] = "data:image/png;base64," + data.base64EncodedString()
    }
    return value
}
