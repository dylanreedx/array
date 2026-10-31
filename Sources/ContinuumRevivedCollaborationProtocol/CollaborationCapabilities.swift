import Foundation

extension Collaboration {
    /// Area collaboration and host execution are separate authorities. These
    /// values describe operations, not grants accepted from a client's JSON.
    public enum Capability: String, Codable, CaseIterable, Hashable, Sendable {
        case view, discuss, layout, publish, manageSharing
        case promptAgent, stopAgent, approveProviderRequest, writeTerminal
    }

    public static func requiredCapabilities(for edit: SharedArea.Edit) -> Set<Capability> {
        switch edit {
        case let .admit(item, _):
            return [.layout, item.kind == .discussion || item.kind == .agreement ? .discuss : .publish]
        case .place: return [.layout]
        case .remove: return [.layout, .publish]
        case .context, .post, .endorse: return [.discuss]
        }
    }
}

extension Collaboration.Role {
    /// Current role policy. Sharing is full access: an editor (what a share
    /// link grants) may prompt and stop a shared agent, which still runs on its
    /// owner's Mac under the owner's CLI login. The owning host revalidates
    /// membership at its own admission point for every prompt. Provider
    /// approvals stay with the owner and terminals are never shared.
    public func allows(_ capability: Collaboration.Capability) -> Bool {
        switch capability {
        case .view: return true
        case .discuss, .layout, .publish, .promptAgent, .stopAgent: return self != .viewer
        case .manageSharing: return self == .owner
        case .approveProviderRequest, .writeTerminal: return false
        }
    }
}

extension Collaboration.Scope {
    /// A snapshot is useful for presentation, not reusable authorization. The
    /// service independently reloads membership before each real operation.
    public func allows(_ capability: Collaboration.Capability) -> Bool {
        epoch > 0 && role.allows(capability)
    }

    /// Presentation preflight only. Authorship, source ownership, current
    /// membership and document validity are still checked by the service.
    public func canSubmit(_ command: SharedArea.Command) -> Bool {
        command.area == area && !command.edits.isEmpty && command.edits.allSatisfy { edit in
            Collaboration.requiredCapabilities(for: edit).allSatisfy { allows($0) }
        }
    }
}
