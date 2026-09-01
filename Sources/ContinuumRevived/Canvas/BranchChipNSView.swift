import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// Ticket: docs/38-tickets/90-agent-ux/P2C.4-branch-on-rows.md
//
// WHICH CHECKOUT IS THIS AGENT ABOUT TO TOUCH? Since P2C.2 an agent can be
// spawned isolated, on `agent/<slug>` in `<repo>/.worktrees/<slug>`, and nothing
// on screen said so — five tiles looked identical whether they were editing your
// working copy or one of five private ones.
//
// Thin renderer, the same shape as `StatusChipNSView`: `display(for:)` is the one
// pure (context -> chip) mapping and this view only paints it, so the tile and the
// Component Lab card cannot draw two different chips for one agent.
final class BranchChipNSView: NSView, TokenThemed, AgentPageZoomScalable {
    /// A branch. `⎇` (U+2387) rather than a tree/fork emoji: it is monochrome, so
    /// it takes the label's token colour instead of shipping a colour no gate
    /// measures.
    static let branchGlyph = "⎇"
    /// The agent is not on the branch it was given.
    static let mismatchGlyph = "⚠"
    /// Suffix for an agent working directly in the project's own checkout — the
    /// case that matters when you are about to edit the same files.
    static let sharedSuffix = "· shared"

    /// Everything this chip paints. `nil` (from `display(for:)`) means there is
    /// nothing honest to say, and the chip is hidden rather than showing a
    /// placeholder branch.
    struct Display: Equatable {
        let text: String
        let tooltip: String
        /// Amber + a warning glyph, not just amber: hue alone is not a channel
        /// everyone can read.
        let isWarning: Bool
    }

    /// The one mapping. Three states, exactly the packet's:
    ///
    /// · **no worktree** — the agent works in the project's own checkout. Its
    ///   branch is whatever you have checked out, and that is what it shows, with
    ///   `· shared` so "this one is in YOUR tree" is legible at a glance.
    /// · **isolated, matching** — the normal isolated case: the agent's checkout is
    ///   on the branch it was given.
    /// · **isolated, mismatched** — the agent has moved off that branch (an agent
    ///   can run `git checkout` inside its own worktree), so its commits are not
    ///   landing where the record says. Shows the branch it is ACTUALLY on, since
    ///   that is where the work is going, and names the assigned one in the tooltip.
    ///
    /// `AgentRowContext.isBranchMismatch` compares against the agent's OWN checkout
    /// on purpose; the reasoning (and the git facts behind it) is at
    /// `WorktreeManager.currentBranch`.
    static func display(for context: AgentRowContext?) -> Display? {
        guard let context else { return nil }
        if let branch = context.worktreeBranch {
            guard context.isBranchMismatch, let actual = context.checkedOutBranch else {
                return Display(
                    text: "\(branchGlyph) \(branch)",
                    tooltip: "Isolated: this agent works in its own checkout, on \(branch).",
                    isWarning: false
                )
            }
            return Display(
                text: "\(mismatchGlyph) \(actual)",
                tooltip: "This agent was given \(branch) but its checkout is on \(actual) — "
                    + "its commits are not landing on the branch it was assigned.",
                isWarning: true
            )
        }
        guard let shared = context.checkedOutBranch else { return nil }
        return Display(
            text: "\(branchGlyph) \(shared) \(sharedSuffix)",
            tooltip: "This agent works directly in the project checkout, on \(shared).",
            isWarning: false
        )
    }

    /// Truncates in the MIDDLE: an `agent/<role>-<prompt>-<hash>` slug is
    /// identified by both ends (which agent, and which of two with the same role),
    /// so dropping the tail the way the header's title label does would leave two
    /// chips reading the same.
    private let label = NSTextField(labelWithString: "")
    private var isWarning = false

    /// This chip's rung of the tile's page zoom. `.default` until the tile's
    /// subtree walk delivers one, which is why every metric below is an exact
    /// identity at 100%.
    private(set) var pageZoom: AgentPageZoom = .default

    private var stack: NSStackView?
    private var minimumTextWidthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?

    /// Derived from the type it holds, like every other height in the tile: one
    /// `.label` line plus the chip's own vertical padding.
    static var preferredHeight: Double {
        preferredHeight(zoom: .default)
    }

    static func preferredHeight(zoom: AgentPageZoom) -> Double {
        zoom.lineHeight(for: .label) + zoom.scaled(insets).vertical
    }

    private static let insets = EdgeInsetsToken(top: Space.xs, left: Space.m, bottom: Space.xs, right: Space.m)

    /// Floor for the text inside the chip, so a squeezed header truncates the
    /// branch instead of compressing the chip to nothing — `UIProbeGeometry`
    /// .expectNoZeroSizeViews is an error, and an invisible chip is a lie besides.
    /// Four `.label` characters wide, measured from the font rather than guessed.
    private static var minimumTextWidth: Double {
        minimumTextWidth(zoom: .default)
    }

    private static func minimumTextWidth(zoom: AgentPageZoom) -> Double {
        ("0000" as NSString).size(withAttributes: [.font: NSFont.token(.label, zoom: zoom)]).width
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        // `Radius.card`, not `Radius.pill`: CALayer does not clamp a corner radius
        // to half the view's height, so 999 on an 18pt chip is not a capsule but
        // undefined-looking geometry that would also make the PNG baseline
        // machine-dependent.
        layer?.cornerRadius = pageZoom.scaled(Radius.card)
        layer?.masksToBounds = true
        applyTokens()

        label.font = .token(.label, zoom: pageZoom)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        // Lower than a label's default 750, so this is what gives way when the
        // header runs out of room — the agent's NAME must not truncate first.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(Self.insets, zoom: pageZoom)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        self.stack = stack
        // Both constants follow the page zoom, so they are held rather than baked
        // into an activated anchor a later rung could not reach.
        let minimumWidth = label.widthAnchor.constraint(
            greaterThanOrEqualToConstant: Self.minimumTextWidth(zoom: pageZoom))
        let height = heightAnchor.constraint(equalToConstant: Self.preferredHeight(zoom: pageZoom))
        minimumTextWidthConstraint = minimumWidth
        heightConstraint = height
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            minimumWidth,
            height
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Paint a display, or hide when there is none.
    func apply(_ display: Display?) {
        guard let display else {
            isHidden = true
            label.stringValue = ""
            toolTip = nil
            return
        }
        isHidden = false
        label.stringValue = display.text
        toolTip = display.tooltip
        isWarning = display.isWarning
        applyTokens()
    }

    /// `SurfaceToken.overlay` is the chip's fill — one documented step above the
    /// `tileChrome` the header paints, which `cardMessage` is not (they differ by
    /// one hex step in light). The warning is carried by the TEXT and the OUTLINE
    /// in `accentApproval`, which is a pair P1.6 already gates on every surface at
    /// the 4.5 text floor; a tinted fill at some alpha is not a documented pair, so
    /// it could not be gated at all (the same reasoning `ApprovalDockView` records).
    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = SurfaceToken.overlay.color.cgColor(for: theme)
        let accent = isWarning ? AccentToken.accentApproval.color : LineToken.border.color
        layer?.borderColor = accent.cgColor(for: theme)
        // `dynamicNSColor` for the text, resolved theme for the layers: an NSColor
        // resolves itself at draw time, a CGColor cannot (P1.9's whole finding).
        // Kept on ONE line on purpose — `check-color-hygiene.sh` bans a
        // `…Color(` at end of line (a multi-line raw construction), and
        // `dynamicNSColor(` ends in exactly that substring.
        let textToken = isWarning ? AccentToken.accentApproval.color : TextToken.textSecondary.color
        label.textColor = StatusChipNSView.dynamicNSColor(textToken)
    }

    /// Re-derives every metric this chip owns from `zoom`. Same contract as
    /// `applyTokens()`: idempotent, and safe on a chip already painting a display
    /// — it touches no text, no tooltip and no warning state.
    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        layer?.cornerRadius = pageZoom.scaled(Radius.card)
        label.font = .token(.label, zoom: pageZoom)
        stack?.edgeInsets = NSEdgeInsets(Self.insets, zoom: pageZoom)
        minimumTextWidthConstraint?.constant = Self.minimumTextWidth(zoom: pageZoom)
        heightConstraint?.constant = Self.preferredHeight(zoom: pageZoom)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    var qaText: String { label.stringValue }
    var qaIsWarning: Bool { isWarning }
}
