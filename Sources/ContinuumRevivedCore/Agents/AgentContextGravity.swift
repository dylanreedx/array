import Foundation

/// Queue 91 / spatial-awareness P4: provider-neutral scope-gravity inputs.
///
/// These types are intentionally host-local and non-Codable because they carry
/// absolute check-out paths. They do not touch AppKit, providers, persistence,
/// stores, transport, or process cwd. Callers must supply every fallback
/// explicitly.
public enum AgentScopeSignalProvenance: Equatable, Sendable {
    case projectZone(zoneId: String)
    case managedAgent(agentId: String)
    case terminal(entityId: String)
    case fileTree(entityId: String)
    case workspaceDefault(workspaceId: String)
}

public enum AgentScopeBindingState: String, Equatable, Sendable {
    case provisional
    case pinned
}

public enum AgentScopeFreezeEvent: String, Equatable, Sendable {
    case composerEdited
    case referenceAdded
    case manualLocationChosen
    case turnSubmitted
}

public enum AgentScopeLifecycle: String, Equatable, Sendable {
    case zeroTurnUntouched
    case active
    case restored
}

public enum AgentScopeResolutionWarning: Equatable, Sendable {
    case inheritedRelativeDirectoryMissing(String)
    case noSpatialSignalOrWorkspaceDefault
}

public struct AgentWorldPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct AgentWorldRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var center: AgentWorldPoint {
        AgentWorldPoint(x: x + width / 2, y: y + height / 2)
    }

    public func contains(_ point: AgentWorldPoint) -> Bool {
        point.x >= x && point.x <= x + width && point.y >= y && point.y <= y + height
    }

    public func distance(to other: AgentWorldRect) -> Double {
        let a = center
        let b = other.center
        return ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
}

public struct AgentScopeSignal: Equatable, Sendable {
    public let provenance: AgentScopeSignalProvenance
    public let frame: AgentWorldRect
    public let home: AgentHome
    /// Checkout-relative directory from Where. Nil means checkout root. This is
    /// mapped into the new agent's own checkout before becoming Where.
    public let relativeDirectory: String?

    public init(
        provenance: AgentScopeSignalProvenance,
        frame: AgentWorldRect,
        home: AgentHome,
        relativeDirectory: String? = nil
    ) {
        self.provenance = provenance
        self.frame = frame
        self.home = home
        self.relativeDirectory = AgentContextGravityEngine.normalizedRelativeDirectory(relativeDirectory)
    }
}

public struct AgentScopeBinding: Equatable, Sendable {
    public let home: AgentHome
    public let whereDirectory: URL
    public let provenance: AgentScopeSignalProvenance
    public let state: AgentScopeBindingState
    public let warning: AgentScopeResolutionWarning?

    public init(
        home: AgentHome,
        whereDirectory: URL,
        provenance: AgentScopeSignalProvenance,
        state: AgentScopeBindingState,
        warning: AgentScopeResolutionWarning? = nil
    ) {
        self.home = home
        self.whereDirectory = AgentContextGravityEngine.normalizedDirectoryURL(whereDirectory)
        self.provenance = provenance
        self.state = state
        self.warning = warning
    }

    public func pinned() -> AgentScopeBinding {
        AgentScopeBinding(
            home: home,
            whereDirectory: whereDirectory,
            provenance: provenance,
            state: .pinned,
            warning: warning)
    }

    public func applyingFreezeEvent(_ event: AgentScopeFreezeEvent) -> AgentScopeBinding {
        pinned()
    }
}

public struct AgentContextGravityInput: Equatable, Sendable {
    public let newAgentFrame: AgentWorldRect
    public let newAgentCheckoutRoot: URL
    public let projectZones: [AgentScopeSignal]
    public let managedAgents: [AgentScopeSignal]
    public let workspaceDefault: AgentHome?
    public let workspaceId: String

    public init(
        newAgentFrame: AgentWorldRect,
        newAgentCheckoutRoot: URL,
        projectZones: [AgentScopeSignal] = [],
        managedAgents: [AgentScopeSignal] = [],
        workspaceDefault: AgentHome? = nil,
        workspaceId: String
    ) {
        self.newAgentFrame = newAgentFrame
        self.newAgentCheckoutRoot = AgentContextGravityEngine.normalizedDirectoryURL(newAgentCheckoutRoot)
        self.projectZones = projectZones
        self.managedAgents = managedAgents
        self.workspaceDefault = workspaceDefault
        self.workspaceId = workspaceId
    }
}

public enum AgentContextGravityEngine: Sendable {
    public static func proposeScope(
        _ input: AgentContextGravityInput,
        directoryExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> AgentScopeBinding? {
        if let containing = input.projectZones
            .filter({ $0.frame.contains(input.newAgentFrame.center) })
            .sorted(by: { $0.frame.distance(to: input.newAgentFrame) < $1.frame.distance(to: input.newAgentFrame) })
            .first {
            return binding(
                from: containing,
                checkoutRoot: input.newAgentCheckoutRoot,
                state: .provisional,
                directoryExists: directoryExists,
                allowSingleRelativeDirectory: true)
        }

        if let agreed = agreedManagedAgentSignal(input.managedAgents, relativeTo: input.newAgentFrame) {
            return binding(
                from: agreed.signal,
                checkoutRoot: input.newAgentCheckoutRoot,
                state: .provisional,
                directoryExists: directoryExists,
                forcedRelativeDirectory: agreed.relativeDirectory)
        }

        if let nearest = input.managedAgents.min(by: {
            $0.frame.distance(to: input.newAgentFrame) < $1.frame.distance(to: input.newAgentFrame)
        }) {
            return binding(
                from: nearest,
                checkoutRoot: input.newAgentCheckoutRoot,
                state: .provisional,
                directoryExists: directoryExists,
                allowSingleRelativeDirectory: false)
        }

        if let workspaceDefault = input.workspaceDefault {
            let home = AgentHome(
                projectId: workspaceDefault.projectId,
                projectRoot: workspaceDefault.projectRoot,
                checkoutRoot: workspaceDefault.checkoutRoot)
            return AgentScopeBinding(
                home: home,
                whereDirectory: home.checkoutRoot,
                provenance: .workspaceDefault(workspaceId: input.workspaceId),
                state: .provisional)
        }

        return nil
    }

    public static func updateScopeAfterSettledMove(
        current: AgentScopeBinding,
        lifecycle: AgentScopeLifecycle,
        input: AgentContextGravityInput,
        directoryExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> AgentScopeBinding {
        guard current.state == .provisional, lifecycle == .zeroTurnUntouched else { return current }
        return proposeScope(input, directoryExists: directoryExists) ?? current
    }

    public static func normalizedRelativeDirectory(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "." else { return nil }
        let standardized = (trimmed as NSString).standardizingPath
        guard !standardized.isEmpty, standardized != ".", !standardized.hasPrefix("/") else { return nil }
        let components = standardized.split(separator: "/").map(String.init)
        guard !components.contains("..") else { return nil }
        return components.joined(separator: "/")
    }

    static func normalizedDirectoryURL(_ url: URL) -> URL {
        guard url.isFileURL else { return url.standardized }
        let expanded = (url.path as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        return URL(fileURLWithPath: standardized, isDirectory: true).standardizedFileURL
    }

    private static func binding(
        from signal: AgentScopeSignal,
        checkoutRoot: URL,
        state: AgentScopeBindingState,
        directoryExists: (URL) -> Bool,
        allowSingleRelativeDirectory: Bool = false,
        forcedRelativeDirectory: String? = nil
    ) -> AgentScopeBinding {
        let normalizedCheckout = normalizedDirectoryURL(checkoutRoot)
        let home = AgentHome(
            projectId: signal.home.projectId,
            projectRoot: signal.home.projectRoot,
            checkoutRoot: normalizedCheckout)
        let relative = forcedRelativeDirectory ?? (allowSingleRelativeDirectory ? signal.relativeDirectory : nil)
        if let relative {
            let candidate = normalizedCheckout.appendingPathComponent(relative, isDirectory: true)
            if directoryExists(candidate) {
                return AgentScopeBinding(
                    home: home,
                    whereDirectory: candidate,
                    provenance: signal.provenance,
                    state: state)
            }
            return AgentScopeBinding(
                home: home,
                whereDirectory: normalizedCheckout,
                provenance: signal.provenance,
                state: state,
                warning: .inheritedRelativeDirectoryMissing(relative))
        }
        return AgentScopeBinding(
            home: home,
            whereDirectory: normalizedCheckout,
            provenance: signal.provenance,
            state: state)
    }

    private static func agreedManagedAgentSignal(
        _ signals: [AgentScopeSignal],
        relativeTo newAgentFrame: AgentWorldRect
    ) -> (signal: AgentScopeSignal, relativeDirectory: String?)? {
        let grouped = Dictionary(grouping: signals, by: projectKey)
        let candidates = grouped.values.filter { $0.count >= 2 }
        guard let group = candidates.max(by: { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count < rhs.count }
            return nearestDistance(lhs, relativeTo: newAgentFrame) > nearestDistance(rhs, relativeTo: newAgentFrame)
        }) else { return nil }

        let relativeCounts = Dictionary(grouping: group.compactMap(\.relativeDirectory), by: { $0 })
        let agreedRelative = relativeCounts
            .filter { $0.value.count >= 2 }
            .sorted { lhs, rhs in
                if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
                return lhs.key < rhs.key
            }
            .first?.key
        let representative = group.min(by: { lhs, rhs in
            lhs.frame.distance(to: newAgentFrame) < rhs.frame.distance(to: newAgentFrame)
        }) ?? group[0]
        return (representative, agreedRelative)
    }

    private static func projectKey(_ signal: AgentScopeSignal) -> String {
        if let projectId = signal.home.projectId { return "id:\(projectId.uuidString)" }
        if let projectRoot = signal.home.projectRoot { return "root:\(projectRoot.path)" }
        return "checkout:\(signal.home.checkoutRoot.path)"
    }

    private static func nearestDistance(_ signals: [AgentScopeSignal], relativeTo newAgentFrame: AgentWorldRect) -> Double {
        signals.map { $0.frame.distance(to: newAgentFrame) }.min() ?? .infinity
    }
}
