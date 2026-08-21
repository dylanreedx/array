import Foundation

public enum AgentCompletionScope: String, Codable, Equatable, Sendable {
    case system
    case personal
    case project
    case plugin
    case package
    case temporary
    case runtime
    case fixture
}

/// Provider-native identity retained independently from the row's display text.
/// Paths and handles are host-local capabilities and intentionally not Codable.
public struct AgentCompletionProvenance: Equatable, Sendable {
    public let backend: AgentBackend?
    public let scope: AgentCompletionScope
    public let sourceIdentifier: String
    public let invocationName: String?

    public init(
        backend: AgentBackend? = nil,
        scope: AgentCompletionScope,
        sourceIdentifier: String,
        invocationName: String? = nil
    ) {
        self.backend = backend
        self.scope = scope
        self.sourceIdentifier = sourceIdentifier
        self.invocationName = invocationName
    }

    public static let fixture = AgentCompletionProvenance(
        scope: .fixture,
        sourceIdentifier: "array.fixture"
    )
}

public struct ResolvedSkillInvocation: Equatable, Sendable {
    public let name: String
    public let providerHandle: String

    public init(name: String, providerHandle: String) {
        self.name = name
        self.providerHandle = providerHandle
    }
}

public struct ResolvedPromptTemplate: Equatable, Sendable {
    public let name: String
    public let prompt: String

    public init(name: String, prompt: String) {
        self.name = name
        self.prompt = prompt
    }
}

public struct ResolvedRuntimeCommand: Equatable, Sendable {
    public let name: String
    public let providerHandle: String

    public init(name: String, providerHandle: String) {
        self.name = name
        self.providerHandle = providerHandle
    }
}

public struct DirectoryNavigationTarget: Equatable, Sendable {
    public let directoryURL: URL

    public init(directoryURL: URL) {
        precondition(directoryURL.isFileURL, "DirectoryNavigationTarget requires a local file URL")
        self.directoryURL = directoryURL
    }
}

public enum AgentCompletionPayload: Equatable, Sendable {
    case insertText(String)
    case file(AgentPromptFileReference)
    case skill(ResolvedSkillInvocation)
    case promptTemplate(ResolvedPromptTemplate)
    case runtimeCommand(ResolvedRuntimeCommand)
    case command(AgentCommandInvocation)
    case directory(DirectoryNavigationTarget)
}

public struct AgentCompletion: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let detail: String?
    /// Search/display text retained for provider-neutral filtering. Acceptance
    /// is governed exclusively by `payload`.
    public let insertionText: String
    public let score: Int
    public let payload: AgentCompletionPayload
    public let provenance: AgentCompletionProvenance
    public let isEnabled: Bool
    public let disabledReason: String?
    /// Every provider that returned this deduplicated result, in stable order.
    public let providerIDs: [String]

    public init(
        id: String,
        title: String,
        detail: String? = nil,
        insertionText: String,
        score: Int = 0,
        providerIDs: [String] = [],
        payload: AgentCompletionPayload? = nil,
        provenance: AgentCompletionProvenance = .fixture,
        isEnabled: Bool = true,
        disabledReason: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.insertionText = insertionText
        self.score = score
        self.providerIDs = providerIDs
        self.payload = payload ?? .insertText(insertionText)
        self.provenance = provenance
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
    }
}

public protocol AgentCompletionProvider: Sendable {
    var providerID: String { get }
    var trigger: Character { get }
    func suggestions(for query: AgentCompletionQuery) async -> [AgentCompletion]
}

/// The presentation depends on this narrow source rather than a concrete actor so
/// stale-generation behavior can be verified with an intentionally uncooperative
/// source. Production uses `AgentCompletionProviderRegistry`.
public protocol AgentCompletionSuggestionSource: Sendable {
    func suggestions(for query: AgentCompletionQuery) async -> [AgentCompletion]
}

/// Bounded host-local fixtures for the isolated composer. Runtime command,
/// indexed-file, and skill adapters replace these registrations at the same seam.
/// None of these values are persisted or projected into sync metadata.
public enum AgentCompletionFixtures {
    public static func providers() -> [any AgentCompletionProvider] {
        [
            StaticAgentCompletionProvider(
                providerID: "fixture.commands",
                trigger: "/",
                completions: [
                    AgentCompletion(id: "command.help", title: "help", detail: "Show available commands", insertionText: "/help", score: 30),
                    AgentCompletion(id: "command.clear", title: "clear", detail: "Start a clean turn", insertionText: "/clear", score: 20),
                ]
            ),
            StaticAgentCompletionProvider(
                providerID: "fixture.files",
                trigger: "@",
                completions: [
                    AgentCompletion(id: "file.readme", title: "README.md", detail: "Workspace file", insertionText: "@README.md", score: 20),
                ]
            ),
            StaticAgentCompletionProvider(
                providerID: "fixture.skills",
                trigger: "$",
                completions: [
                    AgentCompletion(id: "skill.review", title: "review", detail: "Review this change", insertionText: "$review", score: 20),
                    AgentCompletion(id: "skill.research", title: "research", detail: "Gather supporting evidence", insertionText: "$research", score: 10),
                ]
            ),
        ]
    }
}

/// Replaceable fixture-backed provider used until runtime command/file/skill
/// adapters register at this provider-neutral seam. Fixtures are host-local;
/// file paths are never persisted or projected into sync metadata.
public struct StaticAgentCompletionProvider: AgentCompletionProvider {
    public let providerID: String
    public let trigger: Character
    public let completions: [AgentCompletion]

    public init(providerID: String, trigger: Character, completions: [AgentCompletion]) {
        self.providerID = providerID
        self.trigger = trigger
        self.completions = completions
    }

    public func suggestions(for query: AgentCompletionQuery) async -> [AgentCompletion] {
        guard !Task.isCancelled else { return [] }
        let needle = AgentCompletionText.canonical(query.text)
        guard !needle.isEmpty else { return completions }
        return completions.filter {
            AgentCompletionText.canonical($0.title).contains(needle)
                || AgentCompletionText.canonical($0.insertionText).contains(needle)
        }
    }
}

/// Actor-isolated provider registry. Registration with the same provider ID is
/// an intentional replacement, enabling runtime adapters without hard-coding
/// slash/file/skill branches in a text view.
public actor AgentCompletionProviderRegistry: AgentCompletionSuggestionSource {
    private var providersByID: [String: any AgentCompletionProvider] = [:]

    public init(providers: [any AgentCompletionProvider] = []) {
        for provider in providers { providersByID[provider.providerID] = provider }
    }

    public func register(_ provider: any AgentCompletionProvider) {
        providersByID[provider.providerID] = provider
    }

    public func unregister(providerID: String) {
        providersByID.removeValue(forKey: providerID)
    }

    public func suggestions(for query: AgentCompletionQuery) async -> [AgentCompletion] {
        let providers = providersByID.values
            .filter { $0.trigger == query.trigger }
            .sorted { $0.providerID < $1.providerID }
        guard !providers.isEmpty, !Task.isCancelled else { return [] }

        let batches = await withTaskGroup(
            of: (String, [AgentCompletion]).self,
            returning: [(String, [AgentCompletion])].self
        ) { group in
            for provider in providers {
                group.addTask {
                    guard !Task.isCancelled else { return (provider.providerID, []) }
                    let values = await provider.suggestions(for: query)
                    guard !Task.isCancelled else { return (provider.providerID, []) }
                    return (provider.providerID, values)
                }
            }
            var result: [(String, [AgentCompletion])] = []
            for await batch in group { result.append(batch) }
            return result
        }
        guard !Task.isCancelled else { return [] }
        return Self.merge(batches: batches, query: query)
    }

    private static func merge(
        batches: [(String, [AgentCompletion])],
        query: AgentCompletionQuery
    ) -> [AgentCompletion] {
        struct Accumulator {
            var completion: AgentCompletion
            var providerIDs: Set<String>
            var matchRank: Int
        }

        var merged: [String: Accumulator] = [:]
        for (providerID, completions) in batches.sorted(by: { $0.0 < $1.0 }) {
            for completion in completions {
                let key = AgentCompletionText.canonical(completion.insertionText)
                let rank = matchRank(completion, query: query)
                if var existing = merged[key] {
                    existing.providerIDs.insert(providerID)
                    existing.providerIDs.formUnion(completion.providerIDs)
                    if isPreferred(completion, rank: rank, over: existing.completion, rank: existing.matchRank) {
                        existing.completion = completion
                        existing.matchRank = rank
                    }
                    merged[key] = existing
                } else {
                    merged[key] = Accumulator(
                        completion: completion,
                        providerIDs: Set(completion.providerIDs).union([providerID]),
                        matchRank: rank
                    )
                }
            }
        }

        return merged.values.map { value in
            AgentCompletion(
                id: value.completion.id,
                title: value.completion.title,
                detail: value.completion.detail,
                insertionText: value.completion.insertionText,
                score: value.completion.score,
                providerIDs: value.providerIDs.sorted(),
                payload: value.completion.payload,
                provenance: value.completion.provenance,
                isEnabled: value.completion.isEnabled,
                disabledReason: value.completion.disabledReason
            )
        }.sorted { lhs, rhs in
            let leftRank = matchRank(lhs, query: query)
            let rightRank = matchRank(rhs, query: query)
            if leftRank != rightRank { return leftRank > rightRank }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let leftTitle = AgentCompletionText.canonical(lhs.title)
            let rightTitle = AgentCompletionText.canonical(rhs.title)
            if leftTitle != rightTitle { return leftTitle < rightTitle }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            if lhs.insertionText != rhs.insertionText { return lhs.insertionText < rhs.insertionText }
            return lhs.id < rhs.id
        }
    }

    private static func isPreferred(
        _ candidate: AgentCompletion,
        rank candidateRank: Int,
        over current: AgentCompletion,
        rank currentRank: Int
    ) -> Bool {
        if candidateRank != currentRank { return candidateRank > currentRank }
        if candidate.score != current.score { return candidate.score > current.score }
        if candidate.title != current.title { return candidate.title < current.title }
        return candidate.id < current.id
    }

    private static func matchRank(_ completion: AgentCompletion, query: AgentCompletionQuery) -> Int {
        let needle = AgentCompletionText.canonical(query.text)
        guard !needle.isEmpty else { return 0 }
        let title = AgentCompletionText.canonical(completion.title)
        let insertion = AgentCompletionText.canonical(completion.insertionText)
        let triggeredNeedle = AgentCompletionText.canonical(String(query.trigger)) + needle
        if title == needle || insertion == triggeredNeedle { return 3 }
        if title.hasPrefix(needle) || insertion.hasPrefix(triggeredNeedle) { return 2 }
        if title.contains(needle) || insertion.contains(needle) { return 1 }
        return 0
    }
}

private enum AgentCompletionText {
    /// Completion identity and ordering must not change with the host's current
    /// language or region. POSIX case/diacritic folding gives filtering, dedupe,
    /// and ranking one fixed normalization policy; final ordering uses Swift's
    /// locale-independent String comparison.
    private static let locale = Locale(identifier: "en_US_POSIX")

    static func canonical(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
    }
}
