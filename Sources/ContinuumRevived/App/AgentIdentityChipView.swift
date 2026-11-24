import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// An agent as the sidebar and tile headers show it: its icon in the user's chosen
/// plate (Orb, Squircle, Inline or Minimal, with the character when icons are on),
/// the provider's mark, then its NAME and how long ago. It reuses
/// `InboxLeadIconPlate` (the tile header's own renderer) and `BrandMark96`; nothing
/// here draws an icon.
@MainActor
final class AgentIdentityChipView: NSView {
    struct Identity {
        var agentID: UUID
        var name: String
        /// `provider/model`, for the provider mark.
        var model: String?
        var identityColor: String?
        var characterName: String?
    }

    static let plateSide: CGFloat = InboxLeadIconPlate.side
    private static let markSide: CGFloat = 13
    /// Every row's chip is this wide with the plate at its leading edge, so the plates
    /// share one x whatever the names' lengths.
    static let columnWidth: CGFloat = 96
    static let gap: CGFloat = 6
    private let plate = InboxLeadIconPlate(frame: NSRect(x: 0, y: 0, width: InboxLeadIconPlate.side, height: InboxLeadIconPlate.side))
    private let mark = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    /// True while the row it sits in is selected: the text takes the selection's
    /// own contrast colour, as every other palette row's does.
    var isEmphasized = false { didSet { if isEmphasized != oldValue { applyColours() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        plate.translatesAutoresizingMaskIntoConstraints = false
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Self.gap
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            plate.widthAnchor.constraint(equalToConstant: Self.plateSide),
            plate.heightAnchor.constraint(equalToConstant: Self.plateSide),
            mark.widthAnchor.constraint(equalToConstant: Self.markSide),
            mark.heightAnchor.constraint(equalToConstant: Self.markSide),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: Self.columnWidth),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ identity: Identity, age: String) {
        let controller = AgentCharacterController.shared
        var views: [NSView] = []
        if let atlas = controller.atlas(
            for: identity.agentID, appearance: AgentCharacterController.appearance(of: self), name: identity.characterName) {
            let now = Date()
            let plan = controller.plan(for: AgentCharacterSnapshot(state: .ready, title: identity.name, allowsMotion: false), now: now)
            let tint = identity.identityColor.map(AgentInboxView.identityDotColour(named:))
            plate.show(plan: plan, atlas: atlas, phase: controller.phase(for: identity.agentID), now: now, tint: tint,
                       working: false, workingPhase: 0, reduceMotion: { true })
            plate.setPaused(true)
            views.append(plate)
        } else {
            plate.hide()
        }
        // The plate already carries the provider; the bare mark stands in for it only
        // when agent icons are off and there is no plate.
        if views.isEmpty, let image = identity.model.flatMap({ BrandMark96.mark(forModel: $0) }) {
            image.isTemplate = true
            mark.image = image
            views.append(mark)
        }
        nameLabel.stringValue = identity.name
        views.append(nameLabel)
        stack.setViews(views, in: .leading)
        if views.contains(mark) { stack.setCustomSpacing(8, after: mark) }
        applyColours()
        setAccessibilityLabel("\(identity.name), \(age) ago")
        invalidateIntrinsicContentSize()
    }

    private func applyColours() {
        if isEmphasized {
            mark.contentTintColor = .alternateSelectedControlTextColor
            nameLabel.textColor = .alternateSelectedControlTextColor
        } else {
            mark.contentTintColor = BrandMark96.foreground(in: self)
            nameLabel.textColor = .labelColor
        }
        plate.applyPalette()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColours()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.columnWidth, height: Self.plateSide)
    }
}
