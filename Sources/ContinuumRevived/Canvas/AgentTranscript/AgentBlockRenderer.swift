import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// An interaction requested by rendered content. Renderers report semantic
/// intent through this seam; they never acquire the supervisor or another app
/// owner directly.
enum AgentRenderAction {
    case copy(blockID: AgentNodeID)
    case activateLink(blockID: AgentNodeID, url: URL)
    case openDiff(blockID: AgentNodeID)
    case retry(blockID: AgentNodeID)
    case submitResponse(requestID: String, value: String)
}

struct AgentRenderActions {
    let perform: (AgentRenderAction) -> Void
    private let disclosureState: (AgentNodeID, Bool) -> Bool
    private let setDisclosureState: (AgentNodeID, Bool) -> Void
    private let presentationRevisionValue: (AgentNodeID) -> UInt64
    private let invalidatePresentationValue: (AgentNodeID) -> Void

    init(_ perform: @escaping (AgentRenderAction) -> Void) {
        self.init(
            perform: perform,
            disclosureState: { _, defaultValue in defaultValue },
            setDisclosureState: { _, _ in },
            presentationRevision: { _ in 0 },
            invalidatePresentation: { _ in }
        )
    }

    init(
        perform: @escaping (AgentRenderAction) -> Void,
        disclosureState: @escaping (AgentNodeID, Bool) -> Bool,
        setDisclosureState: @escaping (AgentNodeID, Bool) -> Void,
        presentationRevision: @escaping (AgentNodeID) -> UInt64,
        invalidatePresentation: @escaping (AgentNodeID) -> Void
    ) {
        self.perform = perform
        self.disclosureState = disclosureState
        self.setDisclosureState = setDisclosureState
        presentationRevisionValue = presentationRevision
        invalidatePresentationValue = invalidatePresentation
    }

    func isExpanded(blockID: AgentNodeID, default defaultValue: Bool) -> Bool {
        disclosureState(blockID, defaultValue)
    }

    func setExpanded(_ expanded: Bool, blockID: AgentNodeID) {
        setDisclosureState(blockID, expanded)
        invalidatePresentationValue(blockID)
    }

    func presentationRevision(blockID: AgentNodeID) -> UInt64 {
        presentationRevisionValue(blockID)
    }

    func addingPresentationInvalidation(
        _ additional: @escaping (AgentNodeID) -> Void
    ) -> AgentRenderActions {
        AgentRenderActions(
            perform: perform,
            disclosureState: disclosureState,
            setDisclosureState: setDisclosureState,
            presentationRevision: presentationRevisionValue,
            invalidatePresentation: { blockID in
                invalidatePresentationValue(blockID)
                additional(blockID)
            }
        )
    }

    func gated(
        while isActive: @escaping () -> Bool,
        perform replacement: @escaping (AgentRenderAction) -> Void
    ) -> AgentRenderActions {
        AgentRenderActions(
            perform: { action in
                guard isActive() else { return }
                replacement(action)
            },
            disclosureState: { blockID, defaultValue in
                guard isActive() else { return defaultValue }
                return disclosureState(blockID, defaultValue)
            },
            setDisclosureState: { blockID, expanded in
                guard isActive() else { return }
                setDisclosureState(blockID, expanded)
            },
            presentationRevision: { blockID in
                guard isActive() else { return 0 }
                return presentationRevisionValue(blockID)
            },
            invalidatePresentation: { blockID in
                guard isActive() else { return }
                invalidatePresentationValue(blockID)
            }
        )
    }

    @MainActor static let disabled = AgentRenderActions { _ in }
}

/// The finite semantic token vocabulary available to a renderer. Keeping the
/// context in token roles (rather than resolved NSColors) lets a reused view
/// repaint correctly when its appearance changes.
struct AgentRenderTokens: Equatable {
    var bodySurface: SurfaceToken
    var artifactSurface: AgentSurfaceRole
    var codeSurface: AgentSurfaceRole
    var primaryText: TextToken
    var secondaryText: TextToken
    var decorativeLine: AgentLineRole
    var focusLine: AgentLineRole

    static let transcript = AgentRenderTokens(
        bodySurface: .tileBody,
        artifactSurface: .artifact,
        codeSurface: .codeSubdued,
        primaryText: .textPrimary,
        secondaryText: .textSecondary,
        decorativeLine: .decorativeHairline,
        focusLine: .focusRing
    )
}

/// Everything a block renderer may learn about its host. In particular, this
/// type deliberately has no AgentSupervisor, provider, parser, or document owner.
struct AgentRenderContext {
    var actions: AgentRenderActions
    var tokens: AgentRenderTokens
    var appearance: TokenTheme
}

/// One AppKit renderer for one semantic block family. `update` and
/// `updateAccessibility` must tolerate a reused view previously displaying a
/// different block of the same registered kind.
@MainActor
protocol AgentBlockRendering: AnyObject {
    /// The one semantic family this renderer owns. The registry validates this
    /// declaration instead of trusting a caller-supplied dictionary key.
    var kind: AgentBlockKind { get }

    func makeView() -> NSView
    func update(view: NSView, block: AgentBlock, context: AgentRenderContext)
    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat
    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext)
}

/// Temporary bootstrap renderer. Follow-up Phase 3 tickets replace each
/// registration with a specialized renderer without changing registry clients.
/// It never exposes payloads, tool arguments, paths, or provider text.
@MainActor
final class AgentDeferredBlockRenderer: AgentBlockRendering {
    let kind: AgentBlockKind
    private let safeLabel: String

    init(kind: AgentBlockKind, safeLabel: String) {
        self.kind = kind
        self.safeLabel = safeLabel
    }

    func makeView() -> NSView {
        let view = NSView(frame: .zero)
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        return view
    }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        updateAccessibility(view: view, block: block, context: context)
    }

    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        24
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        view.setAccessibilityLabel(safeLabel)
    }
}
