import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// An interaction requested by rendered content. Renderers report semantic
/// intent through this seam; they never acquire the supervisor or another app
/// owner directly.
enum AgentRenderAction {
    case copy(blockID: AgentNodeID)
    case activateLink(blockID: AgentNodeID, url: URL)
    case submitResponse(blockID: AgentNodeID, value: String)
}

struct AgentRenderActions {
    let perform: (AgentRenderAction) -> Void

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

/// Mandatory safe renderer for unregistered extension/provider kinds. Its label
/// is intentionally generic: even a debug label can contain untrusted detail.
@MainActor
final class AgentUnknownBlockRenderer: AgentBlockRendering {
    let kind: AgentBlockKind = .unknown

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
        view.setAccessibilityLabel("Unsupported agent content")
    }
}
