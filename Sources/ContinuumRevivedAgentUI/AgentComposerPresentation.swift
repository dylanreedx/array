import Foundation

/// Presentation-only state. Runtime intent values live in Core; this module owns
/// only the truthful label/icon/state shown by the composer control.
public enum AgentComposerTurnPresentationState: CaseIterable, Equatable, Sendable {
    case ready
    case working
}

public struct AgentComposerPresentedCapabilities: Equatable, Sendable {
    public var canSend: Bool
    public var canStop: Bool
    public var canSteer: Bool
    public var canQueue: Bool

    public init(canSend: Bool, canStop: Bool, canSteer: Bool, canQueue: Bool) {
        self.canSend = canSend
        self.canStop = canStop
        self.canSteer = canSteer
        self.canQueue = canQueue
    }
}

public enum AgentComposerPrimaryAction: Equatable, Sendable {
    case send
    case stop
    /// A visible status, not an advertised executable intent.
    case unavailable
}

public enum AgentComposerSecondaryAction: Hashable, Sendable {
    case steer
    case queue
}

public struct AgentComposerPresentation: Equatable, Sendable {
    public var primaryAction: AgentComposerPrimaryAction
    public var title: String
    public var symbolName: String
    public var accessibilityLabel: String
    public var isEnabled: Bool
    public var isLoading: Bool
    public var secondaryActions: Set<AgentComposerSecondaryAction>

    public init(
        primaryAction: AgentComposerPrimaryAction,
        title: String,
        symbolName: String,
        accessibilityLabel: String,
        isEnabled: Bool,
        isLoading: Bool,
        secondaryActions: Set<AgentComposerSecondaryAction>
    ) {
        self.primaryAction = primaryAction
        self.title = title
        self.symbolName = symbolName
        self.accessibilityLabel = accessibilityLabel
        self.isEnabled = isEnabled
        self.isLoading = isLoading
        self.secondaryActions = secondaryActions
    }

    /// Resolves every state/capability combination to one primary presentation.
    /// Unsupported actions are not named: a runtime with a working turn but no
    /// stop RPC shows passive “Working”, never fake Steer or Queue.
    public static func resolve(
        state: AgentComposerTurnPresentationState,
        capabilities: AgentComposerPresentedCapabilities,
        hasDraft: Bool,
        isExecutingPrimaryAction: Bool = false
    ) -> Self {
        var secondary: Set<AgentComposerSecondaryAction> = []
        if state == .working {
            if capabilities.canSteer { secondary.insert(.steer) }
            if capabilities.canQueue { secondary.insert(.queue) }
        }

        switch state {
        case .ready where capabilities.canSend:
            return Self(
                primaryAction: .send,
                title: isExecutingPrimaryAction ? "Sending…" : "Send",
                symbolName: isExecutingPrimaryAction ? "hourglass" : "arrow.up",
                accessibilityLabel: isExecutingPrimaryAction ? "Sending prompt" : "Send prompt",
                isEnabled: hasDraft && !isExecutingPrimaryAction,
                isLoading: isExecutingPrimaryAction,
                secondaryActions: secondary
            )
        // One Stop for the whole flight (P5.5 consolidation): `.working`, and the
        // two `.ready` windows where the runner is spawning or draining — the
        // capability is the truth here, not the event-derived state. The CLI
        // contract: interrupt is available from submit until the turn is over.
        case _ where capabilities.canStop:
            return Self(
                primaryAction: .stop,
                title: isExecutingPrimaryAction ? "Stopping…" : "Stop",
                symbolName: isExecutingPrimaryAction ? "hourglass" : "stop.fill",
                accessibilityLabel: isExecutingPrimaryAction ? "Stopping current agent turn" : "Stop current agent turn",
                isEnabled: !isExecutingPrimaryAction,
                isLoading: isExecutingPrimaryAction,
                secondaryActions: secondary
            )
        case .working:
            return Self(
                primaryAction: .unavailable,
                title: "Working",
                symbolName: "ellipsis",
                accessibilityLabel: "Agent is working",
                isEnabled: false,
                isLoading: true,
                secondaryActions: secondary
            )
        case .ready:
            return Self(
                primaryAction: .unavailable,
                title: "Unavailable",
                symbolName: "minus",
                accessibilityLabel: "Sending is unavailable",
                isEnabled: false,
                isLoading: false,
                secondaryActions: secondary
            )
        }
    }
}
