import Foundation

public enum OnboardingMilestone: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case commandCenterOpened
    case quickJumpUsed
    case navigationModeEntered
    case navigationModeActivated
    case zoneRenamed
    case zoneColorSelected
    case zoneScopeInspected
}

public enum GettingStartedTask: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case openCommandCenter
    case navigate
    case personalizeZone
}

public enum StarterPhase: String, Codable, Equatable, Sendable {
    case notStarted
    case waitingForEnvironment
    case creating
    case complete
    case skipped
    case ineligible
}

public struct StarterLayoutProgress: Codable, Equatable, Sendable {
    public var phase: StarterPhase
    public var projectId: UUID?
    public var zoneId: UUID?
    public var agentTileId: UUID?
    public var shellTileId: UUID?
    public var browserTileId: UUID?

    public init(
        phase: StarterPhase = .notStarted,
        projectId: UUID? = nil,
        zoneId: UUID? = nil,
        agentTileId: UUID? = nil,
        shellTileId: UUID? = nil,
        browserTileId: UUID? = nil
    ) {
        self.phase = phase
        self.projectId = projectId
        self.zoneId = zoneId
        self.agentTileId = agentTileId
        self.shellTileId = shellTileId
        self.browserTileId = browserTileId
    }
}

public struct OnboardingProgress: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public static let currentIntroVersion = 1

    public var schemaVersion: Int
    public var introVersion: Int?
    public var explicitlyDismissedIntro: Bool
    public var explicitlySkippedStarter: Bool
    public var firstProjectId: UUID?
    public var starter: StarterLayoutProgress
    public var milestones: Set<OnboardingMilestone>
    public var skippedTasks: Set<GettingStartedTask>
    public var educationReplayRequested: Bool

    public init(
        schemaVersion: Int = currentSchemaVersion,
        introVersion: Int? = nil,
        explicitlyDismissedIntro: Bool = false,
        explicitlySkippedStarter: Bool = false,
        firstProjectId: UUID? = nil,
        starter: StarterLayoutProgress = StarterLayoutProgress(),
        milestones: Set<OnboardingMilestone> = [],
        skippedTasks: Set<GettingStartedTask> = [],
        educationReplayRequested: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.introVersion = introVersion
        self.explicitlyDismissedIntro = explicitlyDismissedIntro
        self.explicitlySkippedStarter = explicitlySkippedStarter
        self.firstProjectId = firstProjectId
        self.starter = starter
        self.milestones = milestones
        self.skippedTasks = skippedTasks
        self.educationReplayRequested = educationReplayRequested
    }

    public var needsIntro: Bool {
        introVersion != Self.currentIntroVersion && !explicitlyDismissedIntro
    }

    public mutating func demonstrate(_ milestone: OnboardingMilestone) {
        milestones.insert(milestone)
    }

    public func isTaskComplete(_ task: GettingStartedTask) -> Bool {
        switch task {
        case .openCommandCenter:
            return milestones.contains(.commandCenterOpened)
        case .navigate:
            return milestones.isSuperset(of: [
                .quickJumpUsed,
                .navigationModeEntered,
                .navigationModeActivated,
            ])
        case .personalizeZone:
            return milestones.isSuperset(of: [
                .zoneRenamed,
                .zoneColorSelected,
                .zoneScopeInspected,
            ])
        }
    }

    public func isTaskResolved(_ task: GettingStartedTask) -> Bool {
        isTaskComplete(task) || skippedTasks.contains(task)
    }

    public var hasPendingGettingStartedTasks: Bool {
        GettingStartedTask.allCases.contains { !isTaskResolved($0) }
    }

    public mutating func skipTask(_ task: GettingStartedTask) {
        skippedTasks.insert(task)
    }

    /// Educational replay never creates/deletes/repositions workspace content.
    public mutating func replayEducation() {
        milestones.removeAll()
        skippedTasks.removeAll()
        educationReplayRequested = true
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case introVersion
        case explicitlyDismissedIntro
        case explicitlySkippedStarter
        case firstProjectId
        case starter
        case milestones
        case skippedTasks
        case educationReplayRequested
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        schemaVersion = Self.currentSchemaVersion
        introVersion = try container.decodeIfPresent(Int.self, forKey: .introVersion)
        explicitlyDismissedIntro = try container.decodeIfPresent(Bool.self, forKey: .explicitlyDismissedIntro) ?? false
        explicitlySkippedStarter = try container.decodeIfPresent(Bool.self, forKey: .explicitlySkippedStarter) ?? false
        firstProjectId = try container.decodeIfPresent(UUID.self, forKey: .firstProjectId)
        starter = try container.decodeIfPresent(StarterLayoutProgress.self, forKey: .starter) ?? StarterLayoutProgress()
        milestones = try container.decodeIfPresent(Set<OnboardingMilestone>.self, forKey: .milestones) ?? []
        skippedTasks = try container.decodeIfPresent(Set<GettingStartedTask>.self, forKey: .skippedTasks) ?? []
        educationReplayRequested = try container.decodeIfPresent(Bool.self, forKey: .educationReplayRequested) ?? false
    }
}

/// Versioned, channel-local progress. Environment readiness is deliberately not
/// persisted here because tools and authentication may regress independently.
public final class OnboardingProgressStore: @unchecked Sendable {
    public static let key = "array.onboarding.progress.v1"
    public static let legacyShownKey = "continuum.onboarding.shown"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> OnboardingProgress {
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(OnboardingProgress.self, from: data) {
            return decoded
        }
        // Preserve an explicit legacy dismissal, but do not claim any behavior
        // was demonstrated and never mark environment readiness complete.
        if defaults.bool(forKey: Self.legacyShownKey) {
            return OnboardingProgress(
                introVersion: OnboardingProgress.currentIntroVersion,
                explicitlyDismissedIntro: true
            )
        }
        return OnboardingProgress()
    }

    public func save(_ progress: OnboardingProgress) {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        defaults.set(data, forKey: Self.key)
    }

    @discardableResult
    public func update(_ mutation: (inout OnboardingProgress) -> Void) -> OnboardingProgress {
        var progress = load()
        mutation(&progress)
        save(progress)
        return progress
    }
}
