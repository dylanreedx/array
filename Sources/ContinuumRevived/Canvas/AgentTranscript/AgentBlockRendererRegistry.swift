import ContinuumRevivedAgentContent

enum AgentBlockRendererRegistryError: Error, Equatable, CustomStringConvertible {
    case duplicateKind(AgentBlockKind)
    case duplicateRenderer(AgentBlockKind)
    case mismatchedKind(expected: AgentBlockKind, declared: AgentBlockKind)
    case missingFallback
    case registryFrozen

    var description: String {
        switch self {
        case let .duplicateKind(kind):
            return "duplicate renderer registration for kind '\(kind.rawValue)'"
        case let .duplicateRenderer(kind):
            return "renderer for kind '\(kind.rawValue)' is already registered for another semantic family"
        case let .mismatchedKind(expected, declared):
            return "renderer registered for kind '\(expected.rawValue)' declares kind '\(declared.rawValue)'"
        case .missingFallback:
            return "renderer registry has no unknown-content fallback"
        case .registryFrozen:
            return "renderer registry is frozen"
        }
    }
}

/// The single block-kind → renderer selection point. Registration is mutable only
/// during bootstrap; every production consumer receives the frozen singleton.
@MainActor
final class AgentBlockRendererRegistry {
    static let builtInKinds: [AgentBlockKind] = [
        .paragraph, .heading, .list, .listItem, .quote, .thematicBreak,
        .fencedCode, .toolCall, .commandOutput, .plan, .diff, .approval,
        .question, .image, .imageGallery, .error, .notice, .unknown
    ]

    static let production: AgentBlockRendererRegistry = {
        do {
            let registry = AgentBlockRendererRegistry()

            // This is deliberately the only production registration point. Phase
            // 3 renderer tickets replace these deferred renderers one kind at a
            // time; transcript hosts and tiles remain kind-agnostic.
            for kind in builtInKinds where kind != .unknown {
                if AssistantProseRenderer.supportedKinds.contains(kind) {
                    try registry.register(AssistantProseRenderer(kind: kind), for: kind)
                } else if kind == .fencedCode {
                    try registry.register(CodeBlockRenderer(), for: kind)
                } else if kind == .toolCall {
                    try registry.register(ToolCallRenderer(), for: kind)
                } else if kind == .commandOutput {
                    try registry.register(CommandOutputRenderer(), for: kind)
                } else if kind == .plan {
                    try registry.register(PlanRenderer(), for: kind)
                } else if kind == .diff {
                    try registry.register(DiffSummaryRenderer(), for: kind)
                } else if kind == .approval {
                    try registry.register(ApprovalRenderer(), for: kind)
                } else if kind == .question {
                    try registry.register(QuestionRenderer(), for: kind)
                } else if kind == .image {
                    try registry.register(AgentImageRenderer(), for: kind)
                } else if kind == .imageGallery {
                    try registry.register(AgentImageGalleryRenderer(), for: kind)
                } else if kind == .error || kind == .notice {
                    try registry.register(ErrorNoticeRenderer(kind: kind), for: kind)
                } else {
                    try registry.register(
                        AgentDeferredBlockRenderer(
                            kind: kind,
                            safeLabel: "Agent \(kind.rawValue) content"
                        ),
                        for: kind
                    )
                }
            }
            try registry.setFallback(AgentUnknownBlockRenderer())
            try registry.freeze()
            return registry
        } catch {
            preconditionFailure("invalid production agent renderer registry: \(error)")
        }
    }()

    private var renderers: [AgentBlockKind: any AgentBlockRendering] = [:]
    private var fallback: (any AgentBlockRendering)?
    private(set) var isFrozen = false

    func register(_ renderer: any AgentBlockRendering, for kind: AgentBlockKind) throws {
        guard !isFrozen else { throw AgentBlockRendererRegistryError.registryFrozen }
        guard renderer.kind == kind else {
            throw AgentBlockRendererRegistryError.mismatchedKind(expected: kind, declared: renderer.kind)
        }
        guard renderers[kind] == nil, !(kind == .unknown && fallback != nil) else {
            throw AgentBlockRendererRegistryError.duplicateKind(kind)
        }
        let identity = ObjectIdentifier(renderer)
        guard !renderers.values.contains(where: { ObjectIdentifier($0) == identity }) else {
            throw AgentBlockRendererRegistryError.duplicateRenderer(kind)
        }
        renderers[kind] = renderer
    }

    func setFallback(_ renderer: any AgentBlockRendering) throws {
        guard !isFrozen else { throw AgentBlockRendererRegistryError.registryFrozen }
        guard renderer.kind == .unknown else {
            throw AgentBlockRendererRegistryError.mismatchedKind(expected: .unknown, declared: renderer.kind)
        }
        guard fallback == nil, renderers[.unknown] == nil else {
            throw AgentBlockRendererRegistryError.duplicateKind(.unknown)
        }
        let identity = ObjectIdentifier(renderer)
        guard !renderers.values.contains(where: { ObjectIdentifier($0) == identity }) else {
            throw AgentBlockRendererRegistryError.duplicateRenderer(.unknown)
        }
        fallback = renderer
    }

    func freeze() throws {
        guard !isFrozen else { return }
        guard fallback != nil else { throw AgentBlockRendererRegistryError.missingFallback }
        isFrozen = true
    }

    /// Unknown extension kinds and the semantic `.unknown` kind both take the
    /// exact same safe fallback path. Resolution refuses an incompletely
    /// bootstrapped registry rather than making unknown content disappear.
    func renderer(for kind: AgentBlockKind) throws -> any AgentBlockRendering {
        guard let fallback else { throw AgentBlockRendererRegistryError.missingFallback }
        if kind == .unknown { return fallback }
        return renderers[kind] ?? fallback
    }

    func registrationCount(for kind: AgentBlockKind) -> Int {
        if kind == .unknown { return fallback == nil ? 0 : 1 }
        return renderers[kind] == nil ? 0 : 1
    }
}
