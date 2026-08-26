import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI

/// An interaction requested by rendered content. Renderers report semantic
/// intent through this seam; they never acquire the supervisor or another app
/// owner directly.
enum AgentRenderAction {
    case copy(blockID: AgentNodeID)
    case activateLink(blockID: AgentNodeID, url: URL, target: AgentLinkOpenTarget)
    /// A destination shaped like a file in the responding agent's checkout. The
    /// raw authored string is carried through unchanged — relative paths and
    /// `path:line:column` forms keep their information — because only the host,
    /// holding that agent's live cwd, can resolve and authorize it.
    case openLocalFile(blockID: AgentNodeID, destination: String)
    case openDiff(blockID: AgentNodeID)
    case retry(blockID: AgentNodeID)
    case submitResponse(requestID: String, value: String)
    case previewImage(blockID: AgentNodeID, attachmentID: AgentImageAttachmentID)
    case copyImage(blockID: AgentNodeID, attachmentID: AgentImageAttachmentID)
    case saveImageAs(blockID: AgentNodeID, attachmentID: AgentImageAttachmentID)
    case revealImage(blockID: AgentNodeID, attachmentID: AgentImageAttachmentID)
    case revealAgent(blockID: AgentNodeID, agentID: UUID, parentAgentID: UUID)
}

enum AgentLinkOpenTarget: Equatable, Sendable {
    /// Open inside Array. For web URLs the app creates a browser tile beside the
    /// agent that authored the link; app-owned schemes stay app-owned.
    case array
    /// Explicit user intent to leave Array (Command-click or context menu).
    case systemBrowser
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

    func invalidatePresentation(blockID: AgentNodeID) {
        invalidatePresentationValue(blockID)
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

enum AgentImageResourceState: Equatable {
    case available
    case processing
    case failed
    case missing
}

/// Cheap, sync-safe presentation state for one opaque image attachment. It is
/// deliberately not a file/image capability: renderers learn only bounded labels,
/// dimensions, revision, and action availability. The host-local action owner
/// must re-resolve local files when an action is invoked.
struct AgentImageResourceSnapshot: Equatable {
    var attachmentID: AgentImageAttachmentID
    var state: AgentImageResourceState
    var revision: UInt64
    var pixelSize: NSSize?
    var displayName: String?
    var contentType: String?
    var byteCount: UInt64?
    var canPreview: Bool
    var canCopy: Bool
    var canSave: Bool
    var canReveal: Bool

    init(
        attachmentID: AgentImageAttachmentID,
        state: AgentImageResourceState,
        revision: UInt64 = 0,
        pixelSize: NSSize? = nil,
        displayName: String? = nil,
        contentType: String? = nil,
        byteCount: UInt64? = nil,
        canPreview: Bool? = nil,
        canCopy: Bool? = nil,
        canSave: Bool? = nil,
        canReveal: Bool? = nil
    ) {
        self.attachmentID = attachmentID
        self.state = state
        self.revision = revision
        self.pixelSize = pixelSize
        self.displayName = displayName
        self.contentType = contentType
        self.byteCount = byteCount
        let available = state == .available
        self.canPreview = canPreview ?? available
        self.canCopy = canCopy ?? available
        self.canSave = canSave ?? available
        self.canReveal = canReveal ?? available
    }
}

struct AgentImageThumbnail {
    var attachmentID: AgentImageAttachmentID
    var revision: UInt64
    var image: NSImage
    var pixelSize: NSSize
}

final class AgentImageThumbnailRequest: @unchecked Sendable {
    private let cancelValue: () -> Void
    private(set) var isCancelled = false

    init(cancel: @escaping () -> Void = {}) {
        cancelValue = cancel
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        cancelValue()
    }
}

final class AgentImageResourceObservation: @unchecked Sendable {
    private let cancelValue: () -> Void
    private(set) var isCancelled = false

    init(cancel: @escaping () -> Void = {}) {
        cancelValue = cancel
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        cancelValue()
    }
}

enum AgentImageThumbnailResult {
    case success(AgentImageThumbnail)
    case failed
}

/// Host-local resolver for opaque semantic image IDs. It exposes cheap state,
/// cancellable bounded thumbnail requests, and revision invalidation only; full
/// originals and local file URLs stay behind the action owner boundary.
struct AgentImageResourceProvider: @unchecked Sendable {
    private let snapshotValue: (AgentImageAttachmentID) -> AgentImageResourceSnapshot
    private let requestThumbnailValue: (
        AgentImageAttachmentID,
        NSSize,
        UInt64,
        @escaping @MainActor (AgentImageThumbnailResult) -> Void
    ) -> AgentImageThumbnailRequest
    private let observeValue: (AgentImageAttachmentID, @escaping @MainActor (UInt64) -> Void) -> AgentImageResourceObservation

    init(
        snapshot: @escaping (AgentImageAttachmentID) -> AgentImageResourceSnapshot,
        requestThumbnail: @escaping (
            AgentImageAttachmentID,
            NSSize,
            UInt64,
            @escaping @MainActor (AgentImageThumbnailResult) -> Void
        ) -> AgentImageThumbnailRequest = { _, _, _, _ in
            AgentImageThumbnailRequest()
        },
        observe: @escaping (AgentImageAttachmentID, @escaping @MainActor (UInt64) -> Void) -> AgentImageResourceObservation = { _, _ in
            AgentImageResourceObservation()
        }
    ) {
        snapshotValue = snapshot
        requestThumbnailValue = requestThumbnail
        observeValue = observe
    }

    func snapshot(_ id: AgentImageAttachmentID) -> AgentImageResourceSnapshot {
        snapshotValue(id)
    }

    func requestThumbnail(
        id: AgentImageAttachmentID,
        targetPixelSize: NSSize,
        revision: UInt64,
        completion: @escaping @MainActor (AgentImageThumbnailResult) -> Void
    ) -> AgentImageThumbnailRequest {
        requestThumbnailValue(id, targetPixelSize, revision, completion)
    }

    func observe(
        id: AgentImageAttachmentID,
        invalidated: @escaping @MainActor (UInt64) -> Void
    ) -> AgentImageResourceObservation {
        observeValue(id, invalidated)
    }

    static let unavailable = AgentImageResourceProvider { id in
        AgentImageResourceSnapshot(attachmentID: id, state: .missing)
    }
}

/// Everything a block renderer may learn about its host. In particular, this
/// type deliberately has no AgentSupervisor, parser, document owner, or concrete
/// storage path resolver. Host-local media capability is injected explicitly via
/// `imageResources` and remains keyed by opaque semantic attachment IDs.
struct AgentRenderContext {
    var actions: AgentRenderActions
    var tokens: AgentRenderTokens
    var appearance: TokenTheme
    var imageResources: AgentImageResourceProvider = .unavailable
    /// C10: `AgentReferenceRenderer`'s seam for a live status, deliberately
    /// outside the semantic document (see `AgentReferenceStatusSource`).
    var agentStatus: AgentReferenceStatusSource = .unavailable
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
