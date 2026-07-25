import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

@MainActor
struct ApprovalDockRequest: Equatable {
    var requestId: String
    var kind: ApprovalKind
    var detail: String?

    init(requestId: String, kind: ApprovalKind, detail: String?) {
        self.requestId = requestId
        self.kind = kind
        self.detail = Self.sanitizedDetail(detail)
    }

    static func sanitizedDetail(_ detail: String?) -> String? {
        guard let detail else { return nil }
        let collapsed = detail
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(160))
    }
}

extension ApprovalKind {
    var displayName: String {
        switch self {
        case .commandExecutionApproval: return "Run command"
        case .applyPatchApproval: return "Apply patch"
        case .toolUserInput: return "Answer needed"
        }
    }
}

@MainActor
final class ApprovalDockView: NSView, TokenThemed {
    var pendingRequest: ApprovalDockRequest? {
        didSet { configure(with: pendingRequest) }
    }

    var onDecision: ((ApprovalDecision) -> Void)?

    private let headerLabel = NSTextField(labelWithString: "⚠ Approval needed")
    private let detailLabel = NSTextField(labelWithString: "")
    private let buttonStack = NSStackView()

    /// The attention hue, never re-picked here: whenever this dock is up the tile
    /// is in `.needsAttention`, so taking the accent from `StatusChipPresenter`
    /// (P1.8, the one status→appearance mapping) makes the dock's outline and
    /// header match the glyph in the tile header by construction instead of by
    /// coincidence. The shipped `.systemOrange` was that coincidence, and P0.4
    /// measured it at 2.31:1 on white.
    private static var attentionAccent: TokenColor {
        StatusChipPresenter.display(for: .needsAttention).accent
    }

    /// The dock's height, DERIVED — replacing the hardcoded 92pt, which says
    /// nothing about what it holds and silently clips the moment a role's size
    /// moves. Three content rows (header `.label`, detail `.captionMono`, the
    /// button row) plus `Inset.card`'s vertical padding and the two `Space.m` gaps
    /// between them.
    ///
    /// The button row is the one term the type scale cannot supply: an `NSButton`'s
    /// bezel chrome is AppKit's, not the scale's, so it is MEASURED from a real
    /// button configured exactly like the dock's — which is what `Metrics`' own
    /// note asks for ("if a control's own chrome needs more, P1.10 adds it from the
    /// control's real metrics — never by re-hardcoding").
    ///
    /// `UIProbeGeometry` asserts this value is at or above the dock's real
    /// `fittingSize.height` at every probed tile width, so the derivation cannot
    /// under-report the content it is sizing.
    static var preferredHeight: Double {
        Inset.card.vertical
            + Metrics.lineHeight(for: .label)
            + Metrics.lineHeight(for: .captionMono)
            + buttonRowHeight
            + 2 * Space.m
    }

    private static var buttonRowHeight: Double {
        let probe = NSButton(title: "Approve", target: nil, action: nil)
        probe.bezelStyle = .rounded
        probe.controlSize = .small
        probe.font = .token(.label)
        return probe.fittingSize.height
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 1
        // Full-bleed: the dock spans the tile edge to edge between the transcript
        // and the compose row, so it has no corners of its own. Deliberately not
        // `Radius.card` — that would round against a square tile edge.
        layer?.cornerRadius = 0
        applyTokens()
        isHidden = true
        alphaValue = 0

        headerLabel.font = .token(.label)
        headerLabel.textColor = StatusChipNSView.dynamicNSColor(Self.attentionAccent)

        detailLabel.font = .token(.captionMono)
        detailLabel.textColor = StatusChipNSView.dynamicNSColor(TextToken.textSecondary.color)
        detailLabel.lineBreakMode = .byTruncatingTail

        let approve = makeButton(title: "Approve", decision: .accept, accented: true)
        let approveSession = makeButton(title: "Approve for session", decision: .acceptForSession, accented: true)
        let decline = makeButton(title: "Decline", decision: .decline, accented: false)
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = Space.m
        [approve, approveSession, decline].forEach(buttonStack.addArrangedSubview)

        let layout = NSStackView(views: [headerLabel, detailLabel, buttonStack])
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = Space.m
        layout.edgeInsets = NSEdgeInsets(Inset.card)
        layout.translatesAutoresizingMaskIntoConstraints = false
        addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: trailingAnchor),
            layout.topAnchor.constraint(equalTo: topAnchor),
            layout.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `SurfaceToken.overlay` is named for this view — "popovers, menus, the
    /// approval dock — floats above everything". The accent carries the attention
    /// as the OUTLINE plus the header and the two approve buttons, rather than as a
    /// tinted fill: a fill at some alpha over a surface is not a documented pair,
    /// so P1.6 could not gate it, while `accentApproval` on `overlay` is one of the
    /// 104 pairs the palette already asserts (at the 4.5 text floor, stricter than
    /// the 3.0 a line needs).
    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = SurfaceToken.overlay.color.cgColor(for: theme)
        layer?.borderColor = Self.attentionAccent.cgColor(for: theme)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    var qaDetailText: String { detailLabel.stringValue }
    /// The height the dock's real content needs at its current width — what
    /// `preferredHeight` is asserted against.
    var qaContentFittingHeight: Double {
        layoutSubtreeIfNeeded()
        return Double(subviews.first?.fittingSize.height ?? 0)
    }
    var qaButtonTitles: [String] { buttonStack.arrangedSubviews.compactMap { ($0 as? NSButton)?.title } }

    func qaClick(_ decision: ApprovalDecision) {
        onDecision?(decision)
        pendingRequest = nil
        alphaValue = 0
        isHidden = true
    }

    private func configure(with request: ApprovalDockRequest?) {
        guard let request else {
            animateVisible(false)
            return
        }
        if let detail = request.detail {
            detailLabel.stringValue = "\(request.kind.displayName): \(detail)"
            detailLabel.isHidden = false
        } else {
            detailLabel.stringValue = ""
            detailLabel.isHidden = true
        }
        animateVisible(true)
    }

    private func makeButton(title: String, decision: ApprovalDecision, accented: Bool) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(decisionClicked(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .token(.label)
        // Kept on one line: `check-color-hygiene.sh`'s multi-line-constructor rule
        // matches any line ENDING in `Color(`, and `dynamicNSColor(` is one — a
        // false positive the reformat avoids without weakening the pattern.
        let tint = accented ? Self.attentionAccent : TextToken.textSecondary.color
        button.contentTintColor = StatusChipNSView.dynamicNSColor(tint)
        button.identifier = NSUserInterfaceItemIdentifier("approvalDock.\(decision.rawValue)")
        return button
    }

    @objc private func decisionClicked(_ sender: NSButton) {
        switch sender.identifier?.rawValue {
        case ApprovalDecision.accept.rawValue:
            qaClick(.accept)
        case ApprovalDecision.acceptForSession.rawValue:
            qaClick(.acceptForSession)
        case ApprovalDecision.decline.rawValue:
            qaClick(.decline)
        default:
            break
        }
    }

    private func animateVisible(_ show: Bool) {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if show { isHidden = false }
        guard !reduced else {
            alphaValue = show ? 1 : 0
            isHidden = !show
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = show ? 1 : 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                if !show { self?.isHidden = true }
            }
        }
    }
}
