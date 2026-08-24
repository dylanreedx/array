import ContinuumRevivedAgentContent
import Foundation

/// Temporary one-way adapter for the AppKit card renderer.
///
/// `AgentDocument` remains the source of truth. This projection intentionally
/// flattens semantic inline marks and container structure to plain text because
/// `ManagedTranscriptCard` has no representation for either. Links retain their
/// label (not their destination), and soft/hard breaks become spaces/newlines.
public enum ManagedTranscriptCardProjection {
    public static func project(
        _ document: AgentDocument,
        itemKindsByItemID: [String: ItemKind],
        itemStatusesByItemID: [String: ItemStatus] = [:],
        rawMarkupSourcesByEntryID: [AgentNodeID: String] = [:]
    ) -> [ManagedTranscriptCard] {
        // Request entries are v2 semantic blocks (P5.4). The legacy card stack
        // presents the same runtime events through its own approval dock and
        // user-input card UI, so projecting them here would duplicate each
        // request as a legacy card and move blessed legacy baselines.
        document.entries.filter { entry in
            switch entry.blocks.first?.kind {
            case .approval?, .question?: return false
            default: return true
            }
        }.enumerated().map { index, entry in
            let primary = entry.blocks.first
            let kind = cardKind(entry: entry, block: primary)
            return ManagedTranscriptCard(
                id: cardID(entry: entry, block: primary, position: index + 1),
                kind: kind,
                title: title(entry: entry, block: primary, kind: kind),
                body: rawMarkupSourcesByEntryID[entry.id] ?? entry.blocks.map(plainText).joined(),
                itemKind: itemKind(
                    entry: entry,
                    block: primary,
                    itemKindsByItemID: itemKindsByItemID
                ),
                status: status(
                    entry: entry,
                    block: primary,
                    itemStatusesByItemID: itemStatusesByItemID
                )
            )
        }
    }

    private static func cardKind(entry: AgentEntry, block: AgentBlock?) -> ManagedTranscriptCardKind {
        guard let block else { return entry.role == .user ? .userMessage : .message }
        switch block.kind {
        case .toolCall, .commandOutput: return .toolCall
        case .plan: return .plan
        case .diff: return .diff
        case .error: return .error
        default: return entry.role == .user ? .userMessage : .message
        }
    }

    private static func cardID(entry: AgentEntry, block: AgentBlock?, position: Int) -> String {
        if let block, [.toolCall, .plan, .diff, .error].contains(block.kind),
           case .providerItem(_, let itemID?) = entry.provenance {
            return itemID
        }
        if case .localNotice(let reason) = entry.provenance {
            return decodedProviderID(from: reason, scope: "notice") ?? reason
        }
        if block?.kind == .commandOutput { return "output-\(position)" }
        switch entry.role {
        case .user: return "user-\(position)"
        case .assistant: return "assistant-\(position)"
        case .reasoning: return "reasoning-\(position)"
        case .system: return entry.id.rawValue
        }
    }

    private static func title(
        entry: AgentEntry,
        block: AgentBlock?,
        kind: ManagedTranscriptCardKind
    ) -> String {
        guard let block else { return roleTitle(entry.role) }
        switch block.payload {
        case .toolCall(let payload): return payload.name
        case .commandOutput: return "command output"
        case .plan(let payload): return payload.title ?? "plan"
        case .diff(let payload): return payload.text
        case .error(let payload): return payload.message
        case .notice:
            if let heading = block.children.first(where: { $0.kind == .heading }),
               case .heading(_, let content) = heading.payload {
                return plainText(content)
            }
            return "notice"
        default: return roleTitle(entry.role)
        }
    }

    private static func decodedProviderID(from semanticID: String, scope: String) -> String? {
        let prefix = scope + ":"
        guard semanticID.hasPrefix(prefix) else { return nil }
        var encoded = String(semanticID.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func roleTitle(_ role: AgentEntryRole) -> String {
        switch role {
        case .user: return "you"
        case .assistant: return "assistant"
        case .reasoning: return "reasoning"
        case .system: return "system"
        }
    }

    private static func itemKind(
        entry: AgentEntry,
        block: AgentBlock?,
        itemKindsByItemID: [String: ItemKind]
    ) -> ItemKind? {
        if case .providerItem(_, let itemID?) = entry.provenance,
           let legacyKind = itemKindsByItemID[itemID] {
            return legacyKind
        }
        guard let block else { return nil }
        switch block.kind {
        case .commandOutput: return .commandExecution
        case .plan: return .plan
        case .diff: return .fileChange
        case .error: return .error
        case .toolCall: return nil
        default: return nil
        }
    }

    private static func status(
        entry: AgentEntry,
        block: AgentBlock?,
        itemStatusesByItemID: [String: ItemStatus]
    ) -> ItemStatus? {
        guard let block else { return nil }
        // Runtime completion is the exact legacy fact. In particular, diff and
        // error payloads cannot encode failed/declined/completed distinctions,
        // so deriving those statuses from entry lifecycle loses information.
        if case .providerItem(_, let itemID?) = entry.provenance,
           let legacyStatus = itemStatusesByItemID[itemID] {
            return legacyStatus
        }
        let semantic: AgentItemStatus?
        switch block.payload {
        case .toolCall(let payload): semantic = payload.status
        case .commandOutput(let payload): semantic = payload.status
        case .plan(let payload): semantic = payload.status
        case .notice(let payload): semantic = payload.status
        case .approval(let payload), .question(let payload): semantic = payload.status
        case .diff:
            // Diff payloads do not carry a status; their open/finished
            // lifecycle retains the compatibility path's usual transition.
            semantic = entry.lifecycle == .finished ? .completed : .inProgress
        case .error:
            // A finished semantic error represents a failed item. The legacy
            // enum called the open state inProgress and the terminal state failed.
            semantic = entry.lifecycle == .finished ? .failed : .inProgress
        default: semantic = nil
        }
        return semantic.map(legacyStatus)
    }

    private static func legacyStatus(_ status: AgentItemStatus) -> ItemStatus {
        switch status {
        case .pending, .inProgress: return .inProgress
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled, .interrupted: return .declined
        }
    }

    private static func plainText(_ block: AgentBlock) -> String {
        let own: String
        switch block.payload {
        case .paragraph(let content), .heading(_, let content): own = plainText(content)
        case .fencedCode(let payload): own = payload.code
        case .commandOutput(let payload): own = payload.text
        case .notice(let payload): own = plainText(payload.message)
        case .approval(let payload), .question(let payload): own = plainText(payload.prompt)
        // Legacy structured cards displayed their title but no body.
        case .toolCall, .plan, .diff, .error, .image, .imageGallery, .fileReferences: own = ""
        case .agentReference(let payload): own = payload.displayNameAtSpawn
        case .thematicBreak: own = "\n"
        // The legacy card is plain text, so a table projects as the Markdown
        // source it came from rather than as a flattened cell soup.
        case .table(let payload): own = payload.source
        case .list, .listItem, .quote, .opaque: own = ""
        }
        // The notice heading is projected as the card title, never duplicated
        // into its body. Other semantic containers retain their child text.
        if case .notice = block.payload { return own }
        return own + block.children.map(plainText).joined()
    }

    private static func plainText(_ inlines: [AgentInline]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let text), .code(let text): return text
            case .emphasis(let children), .strong(let children): return plainText(children)
            case .link(_, _, let children): return plainText(children)
            case .softBreak: return " "
            case .hardBreak: return "\n"
            }
        }.joined()
    }
}
