import Foundation
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// Host side of a shared agent's chrome: what the agent's own tile shows in its
/// title bar, under-bar, status row, footer and character, computed from the
/// supervisor with the presenters that tile uses, so the guest's tile can show
/// the same thing. Read-only over the supervisor. It does not need the host's
/// tile to be on screen.
@MainActor
final class SharedAgentChromeBuilder {
    typealias Chrome = SharedAgentTranscriptWire.Chrome
    typealias CharacterTheme = SharedAgentTranscriptWire.CharacterTheme

    private weak var supervisor: AgentSupervisor?
    let agent: AgentID
    private let defaults: UserDefaults
    private let characters: AgentCharacterController
    /// The status row's phase anchor holds across ticks, as it does in the tile.
    private var phaseAdapter = AgentCompactStatusPhaseAdapter()
    /// The selected set's file, read and deflated once per set.
    private var shipped: (theme: AgentCharacterTheme, file: CharacterTheme?)?
    /// The meter keeps its last reading until a new one lands, as the host
    /// tile's does (it seeds "no requests yet" and holds it into the first turn).
    private var lastContext: AgentContextWindowSnapshot?

    init(supervisor: AgentSupervisor, agent: AgentID, defaults: UserDefaults = .standard,
         characters: AgentCharacterController = .shared) {
        self.supervisor = supervisor; self.agent = agent; self.defaults = defaults; self.characters = characters
        lastContext = supervisor.contextWindowSnapshot(for: agent) ?? supervisor.freshSessionContextWindow(for: agent)
    }

    /// The chrome now, and the person's own set it names (nil for a built-in set).
    func build(now: Date = AgentElapsedClock.now()) -> (chrome: Chrome, theme: CharacterTheme?)? {
        guard let supervisor, let record = supervisor.records[agent] else { return nil }
        let selection = supervisor.launchSelection(for: agent)
        let model = selection?.model ?? record.model
        let snapshot = supervisor.turnSnapshot(for: agent)
        let presence = snapshot?.presence ?? supervisor.turnPresence(for: agent) ?? AgentTurnPresence()
        let name = record.humanDisplayName
        let branch = supervisor.branchContextCachedOnly(for: agent)

        // Header and title-bar status, as `applyAgentHeader` derives them.
        let presented = snapshot.map {
            AgentTileStatePresenter.present(name: name, snapshot: $0, branchContext: branch, startedAt: nil, now: now)
        } ?? AgentTileStatePresenter.present(name: name, status: .idle, branchContext: branch, startedAt: nil, now: now)
        let header = Chrome.Header(
            name: presented.name, status: presented.status, stateLabel: presented.stateLabel,
            stateAccessibilityLabel: presented.stateAccessibilityLabel,
            availableActionDescription: presented.availableActionDescription, startedAt: presented.startedAt,
            branch: presented.branch.map { .init(text: $0.text, tooltip: $0.tooltip, isWarning: $0.isWarning) },
            managed: supervisor.showsManagedIndicator(for: agent))

        let capabilities = snapshot?.capabilities ?? .init()
        let turn = Chrome.Turn(
            working: snapshot.map { $0.executionState == .working } ?? false,
            canSend: capabilities.canSend, canStop: capabilities.canStop, canSteer: capabilities.canSteer,
            canQueue: capabilities.canQueue, isMirrored: snapshot?.isMirrored ?? false)

        // The context meter's reading. Cost belongs to the host's account.
        if let reading = supervisor.contextWindowSnapshot(for: agent) ?? supervisor.freshSessionContextWindow(for: agent) {
            lastContext = reading
        }
        var context = lastContext
        context?.totalCostUsd = nil
        context?.costBasis = nil

        // The status row, as `refreshCompactStatus` derives it.
        var compaction: AgentCompactStatusPhaseFacts.Session?
        var interaction: AgentCompactStatusPhaseFacts.Interaction?
        switch snapshot?.state {
        case .compacting?: compaction = .init(state: .running)
        case .needsAction?: interaction = .pending(startedAt: nil)
        default: break
        }
        var activity: Chrome.Activity?
        var location: Chrome.Location?
        var resolvedPhase: AgentCompactActivityPhase?
        let elements = AgentStatusElementConfig.visibleElements(defaults: defaults)
        if let where_ = supervisor.locationSnapshot(for: agent, at: now) {
            let facts = ManagedAgentTileNSView.compactPhaseFacts(presence: presence, hasPresenceFacts: true, compaction: compaction)
            let resolution = phaseAdapter.update(AgentCompactStatusPhaseFacts(
                session: facts.session, turn: facts.turn, location: where_, interaction: interaction), now: now)
            resolvedPhase = resolution.phase
            let projectName = branch?.projectName
            let detail = AgentLocationStatusPresenter.present(where_, projectName: projectName)
            let shown: AgentCompactStatusPresentation.Location
            if let input = resolution.activityInput {
                activity = .init(phase: input.phase.rawValue, phaseStartedAt: input.phaseStartedAt,
                                 safeToolLabel: input.safeToolLabel, evidenceNote: input.evidenceNote)
                shown = AgentCompactStatusPresentation.present(
                    location: where_, projectName: projectName, activity: input, now: now,
                    contextWindow: nil, enabledElements: []).location
            } else {
                shown = ManagedAgentTileNSView.compactLocationPresentation(where_, detail: detail)
            }
            // The tooltip can name a path; the guest shows the line itself.
            location = .init(symbolName: shown.symbolName, text: shown.text,
                             accessibilityLabel: shown.accessibilityLabel, isExternal: shown.isExternal)
        }

        // The transcript tail, as `refreshTranscriptThinkingIndicator` and
        // `setLiveTailStatusText` derive it. The guest runs the clock.
        let awaitingUser: Bool = { if case .needsAction? = snapshot?.state { return true }; return false }()
        let live = presence.isLive && !awaitingUser && !presence.phase.isTerminal
        var tailText: String?
        var tailSince: Date?
        if live {
            if case let .tool(tool) = presence.phase,
               !(resolvedPhase.map { [.reading, .searching, .editing, .running].contains($0) } ?? false) {
                tailText = "Running \(ManagedAgentTileNSView.shortToolTitle(tool))"
                tailSince = presence.currentToolStartedAt
            } else if let input = activity.flatMap(Self.activityInput) {
                let shown = AgentCompactStatusPresentation.presentActivity(input, now: now)
                tailText = ManagedAgentTileNSView.tailStatusText(
                    for: Self.withoutElapsed(shown), startupDetail: presence.startupDetail, compacting: compaction != nil)
            }
        }
        let settled = live ? nil : ManagedAgentTileNSView.settledTailText(for: presence)
        let tail = Chrome.Tail(working: live, text: tailText, since: tailSince, settled: settled)

        // The character, as `refreshAgentCharacter` derives it.
        var character: Chrome.Character?
        var file: CharacterTheme?
        var helpers: [UUID: AgentCharacterAssignment] = [:]
        if characters.isEnabled, let theme = characters.theme {
            let state = snapshot.map(InboxState.state(forSnapshot:))
                ?? (record.latestTerminalEvent.map { $0.outcome == .failed || $0.outcome == .runtimeError } == true ? .failed : .ready)
            let pose = AgentCharacterSnapshot(
                state: state,
                activity: AgentCharacterActivityProjection.activity(
                    presence: snapshot?.presence ?? supervisor.turnPresence(for: agent),
                    terminalEvent: record.latestTerminalEvent, latestPromptAt: record.latestPromptAt),
                title: name)
            let reference: Chrome.ThemeReference
            if theme.id == AgentCharacterBundled.themeID {
                reference = .init(id: theme.id, hash: nil)
            } else {
                file = themeFile(for: theme)
                reference = .init(id: theme.id, hash: file?.hash)
            }
            character = .init(snapshot: pose, characterName: record.characterName,
                              assignment: characters.assignment(for: agent.rawValue, name: record.characterName),
                              theme: reference)
            for child in supervisor.records.values where child.parentAgentID == agent {
                helpers[child.id.rawValue] = characters.assignment(for: child.id.rawValue, name: child.characterName)
            }
        }

        let chrome = Chrome(
            agent: agent.rawValue,
            title: ManagedAgentTileNSView.titleBarName(recordName: name, fallback: nil, model: model, id: agent.rawValue),
            harness: (selection?.harness ?? record.harness)?.rawValue ?? "", model: model,
            thinking: selection?.thinking ?? record.thinking ?? "",
            identityColor: record.identityColor,
            identityStyle: record.identityColor == nil ? nil : AgentIdentityColorConfig.style(defaults: defaults).rawValue,
            header: header, turn: turn, context: context, activity: activity, location: location,
            enabledElements: elements.filter { !$0.isAccountScoped && $0 != .cost }.map(\.rawValue),
            tail: tail, character: character, helpers: helpers)
        return (chrome, file)
    }

    /// The selected set's own file, deflated, or nil when it cannot be shipped
    /// (unreadable, edited since it was read, or too large): the guest then
    /// draws its built-in set.
    private func themeFile(for theme: AgentCharacterTheme) -> CharacterTheme? {
        if let shipped, shipped.theme == theme { return shipped.file }
        var file: CharacterTheme?
        for candidate in characters.userThemeFiles {
            guard case let .success(parsed) = candidate.result, parsed == theme,
                  let data = try? Data(contentsOf: candidate.url),
                  case let .success(again) = AgentCharacterThemeParser.parse(data: data), again == theme else { continue }
            file = CharacterTheme(file: data)
            break
        }
        shipped = (theme, file)
        return file
    }

    static func activityInput(_ wire: Chrome.Activity) -> AgentCompactActivityInput? {
        guard let phase = AgentCompactActivityPhase(rawValue: wire.phase) else { return nil }
        return AgentCompactActivityInput(phase: phase, phaseStartedAt: wire.phaseStartedAt,
                                         safeToolLabel: wire.safeToolLabel, evidenceNote: wire.evidenceNote)
    }

    static func withoutElapsed(_ activity: AgentCompactStatusPresentation.Activity) -> AgentCompactStatusPresentation.Activity {
        .init(phase: activity.phase, symbolName: activity.symbolName, text: activity.text, elapsedText: nil,
              accessibilityLabel: activity.accessibilityLabel, detailText: activity.detailText,
              showsThinkingIndicator: activity.showsThinkingIndicator, isSilent: activity.isSilent)
    }
}
