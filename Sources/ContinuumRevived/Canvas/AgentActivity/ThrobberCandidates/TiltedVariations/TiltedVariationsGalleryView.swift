import AppKit
import ContinuumRevivedAgentUI

/// A coordinator-owned review surface for the selected Tilted Prism baseline and
/// five new variations. This is intentionally separate from both the original
/// four-candidate study and Orbit Variations; no candidate is production-wired.
@MainActor
final class TiltedVariationsGalleryView: NSView {
    enum Mode: Equatable {
        case live
        case snapshot
    }

    enum Candidate: String, CaseIterable {
        case tiltedPrism = "Tilted Prism"
        case chromaticDepthRelay = "Chromatic Depth Relay"
        case dualPlaneGyro = "Dual-Plane Gyro"
        case auroraRibbon = "Aurora Ribbon"
        case precessingPrism = "Precessing Prism"
        case prismaticComet = "Prismatic Comet"

        var identifier: String {
            switch self {
            case .tiltedPrism: return "tilted-prism"
            case .chromaticDepthRelay: return "chromatic-depth-relay"
            case .dualPlaneGyro: return "dual-plane-gyro"
            case .auroraRibbon: return "aurora-ribbon"
            case .precessingPrism: return "precessing-prism"
            case .prismaticComet: return "prismatic-comet"
            }
        }

        var direction: String {
            switch self {
            case .tiltedPrism: return "Tilted plane"
            case .chromaticDepthRelay: return "Depth relay"
            case .dualPlaneGyro: return "Dual-plane gyro"
            case .auroraRibbon: return "Aurora ribbon"
            case .precessingPrism: return "Prism precession"
            case .prismaticComet: return "Comet trail"
            }
        }

        @MainActor
        func makeIndicator(reducedMotion: Bool) -> NSView & AgentThinkingIndicatorAnimating {
            switch self {
            case .tiltedPrism:
                return TiltedPrismOrbitThinkingIndicatorView(reducedMotion: reducedMotion)
            case .chromaticDepthRelay:
                return ChromaticDepthRelayTiltedThinkingIndicatorView(reducedMotion: reducedMotion)
            case .dualPlaneGyro:
                return DualPlaneGyroTiltedThinkingIndicatorView(reducedMotion: reducedMotion)
            case .auroraRibbon:
                return AuroraRibbonTiltedThinkingIndicatorView(reducedMotion: reducedMotion)
            case .precessingPrism:
                return PrecessingPrismTiltedThinkingIndicatorView(reducedMotion: reducedMotion)
            case .prismaticComet:
                return PrismaticCometTiltedThinkingIndicatorView(reducedMotion: reducedMotion)
            }
        }
    }

    struct QAFixture {
        let candidate: Candidate
        let reducedMotion: Bool
        let indicator: NSView & AgentThinkingIndicatorAnimating
        let nameLabel: NSTextField
        let directionLabel: NSTextField
        let statusLabel: NSTextField
    }

    static let preferredSize = NSSize(width: 960, height: 640)
    private let titleLabel = NSTextField(labelWithString: "Tilted Prism Variations — Motion Study")
    private let subtitleLabel = NSTextField(labelWithString: "Selected Tilted Prism baseline plus five new variations at true 18×18 scale. Compare the same compact status context in live Normal and static Reduced Motion; review only, with no production winner.")
    private let grid = NSView()
    private let mode: Mode
    private var cards: [TiltedVariationCardView] = []

    init(frame frameRect: NSRect, mode: Mode) {
        self.mode = mode
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = CGFloat(Radius.container)
        identifier = NSUserInterfaceItemIdentifier("managedAgent.tiltedVariations.gallery")

        titleLabel.identifier = NSUserInterfaceItemIdentifier("tiltedVariations.title")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        subtitleLabel.identifier = NSUserInterfaceItemIdentifier("tiltedVariations.subtitle")
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 2

        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.identifier = NSUserInterfaceItemIdentifier("tiltedVariations.grid")
        let header = NSStackView(views: [titleLabel, subtitleLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = CGFloat(Space.xs)
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(grid)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(Space.l)),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(Space.l)),
            header.topAnchor.constraint(equalTo: topAnchor, constant: CGFloat(Space.l)),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(Space.l)),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(Space.l)),
            grid.topAnchor.constraint(equalTo: header.bottomAnchor, constant: CGFloat(Space.m)),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CGFloat(Space.l)),
        ])
        buildGrid()
        applyAppearance()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Tilted Prism Variations motion study")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { Self.preferredSize }

    override func layout() {
        super.layout()
        layoutCards()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        cards.forEach { $0.applyAppearance() }
        applyAppearance()
    }

    var qaCandidateCount: Int { Candidate.allCases.count }
    var qaFixtureCount: Int { cards.count }
    var qaIndicatorFixtures: [QAFixture] {
        cards.map {
            QAFixture(candidate: $0.candidate, reducedMotion: $0.reducedMotion,
                      indicator: $0.indicator, nameLabel: $0.nameLabel,
                      directionLabel: $0.directionLabel, statusLabel: $0.statusLabel)
        }
    }

    private func buildGrid() {
        for reducedMotion in [false, true] {
            for candidate in Candidate.allCases {
                let card = TiltedVariationCardView(candidate: candidate, reducedMotion: reducedMotion, mode: mode)
                card.autoresizingMask = []
                grid.addSubview(card)
                cards.append(card)
            }
        }
    }

    private func layoutCards() {
        let columns = Candidate.allCases.count
        let gap = CGFloat(Space.s)
        let width = floor((grid.bounds.width - gap * CGFloat(columns - 1)) / CGFloat(columns))
        let height = floor((grid.bounds.height - gap) / 2)
        for (index, card) in cards.enumerated() {
            let row = index / columns
            let column = index % columns
            card.frame = NSRect(x: CGFloat(column) * (width + gap),
                                y: grid.bounds.height - CGFloat(row + 1) * height - CGFloat(row) * gap,
                                width: width, height: height)
            card.layoutSubtreeIfNeeded()
        }
    }

    private func applyAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = SurfaceToken.panel.color.cgColor(in: self)
        layer?.borderColor = LineToken.border.color.cgColor(in: self)
        layer?.borderWidth = 1
        titleLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        subtitleLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        CATransaction.commit()
    }
}

@MainActor
private final class TiltedVariationCardView: NSView {
    let candidate: TiltedVariationsGalleryView.Candidate
    let reducedMotion: Bool
    let indicator: NSView & AgentThinkingIndicatorAnimating
    let nameLabel: NSTextField
    let directionLabel: NSTextField
    let statusLabel: NSTextField
    private let motionLabel: NSTextField
    private let statusRow = NSView()
    private let contextLabel: NSTextField
    private let whereLabel: NSTextField
    private let indicatorWell = NSView()

    init(candidate: TiltedVariationsGalleryView.Candidate, reducedMotion: Bool, mode: TiltedVariationsGalleryView.Mode) {
        self.candidate = candidate
        self.reducedMotion = reducedMotion
        self.indicator = candidate.makeIndicator(reducedMotion: reducedMotion)
        self.nameLabel = NSTextField(labelWithString: candidate.rawValue)
        self.directionLabel = NSTextField(labelWithString: candidate.direction)
        self.motionLabel = NSTextField(labelWithString: reducedMotion ? "Reduced Motion" : "Normal")
        self.contextLabel = NSTextField(labelWithString: "Claude")
        self.whereLabel = NSTextField(labelWithString: "feature/tilted-variations")
        self.statusLabel = NSTextField(labelWithString: "Thinking · files")
        super.init(frame: NSRect(x: 0, y: 0, width: 140, height: 250))
        wantsLayer = true
        layer?.cornerRadius = CGFloat(Radius.card)
        identifier = NSUserInterfaceItemIdentifier("tiltedVariations.card.\(candidate.identifier).\(reducedMotion ? "reduced" : "normal")")

        nameLabel.identifier = NSUserInterfaceItemIdentifier("tiltedVariations.name.\(candidate.identifier).\(reducedMotion)")
        nameLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        nameLabel.lineBreakMode = .byWordWrapping
        nameLabel.maximumNumberOfLines = 2
        nameLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        directionLabel.identifier = NSUserInterfaceItemIdentifier("tiltedVariations.direction.\(candidate.identifier).\(reducedMotion)")
        directionLabel.font = .systemFont(ofSize: 10, weight: .regular)
        directionLabel.lineBreakMode = .byWordWrapping
        directionLabel.maximumNumberOfLines = 2
        motionLabel.identifier = NSUserInterfaceItemIdentifier("tiltedVariations.motion.\(candidate.identifier).\(reducedMotion)")
        motionLabel.font = .systemFont(ofSize: 10, weight: .medium)
        motionLabel.alignment = .right
        contextLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        whereLabel.font = .systemFont(ofSize: 9, weight: .regular)
        whereLabel.lineBreakMode = .byTruncatingTail
        statusLabel.identifier = NSUserInterfaceItemIdentifier("tiltedVariations.status.\(candidate.identifier).\(reducedMotion)")
        statusLabel.font = .systemFont(ofSize: 10, weight: .regular)
        statusLabel.lineBreakMode = .byTruncatingTail
        [contextLabel, whereLabel, statusLabel].forEach { $0.setContentCompressionResistancePriority(.required, for: .vertical) }

        indicator.identifier = NSUserInterfaceItemIdentifier("tiltedVariations.indicator.\(candidate.identifier).\(reducedMotion)")
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.setReducedMotion(reducedMotion)
        indicator.setSnapshotPhase(0.38)
        if mode == .live && !reducedMotion { indicator.startAnimating() }

        indicatorWell.wantsLayer = true
        indicatorWell.layer?.cornerRadius = CGFloat(Radius.card)
        indicatorWell.translatesAutoresizingMaskIntoConstraints = false
        indicatorWell.addSubview(indicator)

        statusRow.wantsLayer = true
        statusRow.layer?.cornerRadius = CGFloat(Radius.card)
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        let contextStack = NSStackView(views: [contextLabel, whereLabel, statusLabel])
        contextStack.orientation = .vertical
        contextStack.alignment = .leading
        contextStack.spacing = 1
        contextStack.translatesAutoresizingMaskIntoConstraints = false
        statusRow.addSubview(indicatorWell)
        statusRow.addSubview(contextStack)

        addSubview(nameLabel)
        addSubview(directionLabel)
        addSubview(motionLabel)
        addSubview(statusRow)
        [nameLabel, directionLabel, motionLabel].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(Space.s)),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: CGFloat(Space.s)),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: motionLabel.leadingAnchor, constant: -CGFloat(Space.xs)),
            motionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(Space.s)),
            motionLabel.topAnchor.constraint(equalTo: topAnchor, constant: CGFloat(Space.s)),
            motionLabel.widthAnchor.constraint(equalToConstant: 76),
            directionLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            directionLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            directionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(Space.s)),
            statusRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(Space.s)),
            statusRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(Space.s)),
            statusRow.topAnchor.constraint(equalTo: directionLabel.bottomAnchor, constant: CGFloat(Space.s)),
            statusRow.heightAnchor.constraint(equalToConstant: 72),
            statusRow.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -CGFloat(Space.s)),
            indicatorWell.leadingAnchor.constraint(equalTo: statusRow.leadingAnchor, constant: CGFloat(Space.xs)),
            indicatorWell.centerYAnchor.constraint(equalTo: statusRow.centerYAnchor),
            indicatorWell.widthAnchor.constraint(equalToConstant: 30),
            indicatorWell.heightAnchor.constraint(equalToConstant: 30),
            indicator.centerXAnchor.constraint(equalTo: indicatorWell.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: indicatorWell.centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 18),
            indicator.heightAnchor.constraint(equalToConstant: 18),
            contextStack.leadingAnchor.constraint(equalTo: indicatorWell.trailingAnchor, constant: CGFloat(Space.xs)),
            contextStack.trailingAnchor.constraint(equalTo: statusRow.trailingAnchor, constant: -CGFloat(Space.xs)),
            contextStack.centerYAnchor.constraint(equalTo: statusRow.centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(candidate.rawValue), \(candidate.direction), \(reducedMotion ? "Reduced Motion" : "Normal"), Claude, feature/tilted-variations, Thinking")
        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    func applyAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = SurfaceToken.tileBody.color.cgColor(in: self)
        layer?.borderColor = LineToken.border.color.cgColor(in: self)
        layer?.borderWidth = 1
        statusRow.layer?.backgroundColor = SurfaceToken.tileChrome.color.cgColor(in: self)
        indicatorWell.layer?.backgroundColor = SurfaceToken.cardTool.color.cgColor(in: self)
        indicatorWell.layer?.borderColor = LineToken.border.color.cgColor(in: self)
        indicatorWell.layer?.borderWidth = 1
        nameLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        directionLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        motionLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        contextLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        whereLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        statusLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        CATransaction.commit()
    }
}
