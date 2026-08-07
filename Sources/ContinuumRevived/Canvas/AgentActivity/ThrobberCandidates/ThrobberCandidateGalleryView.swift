import AppKit
import ContinuumRevivedAgentUI

/// Coordinator-owned motion-study surface for the four managed-agent thinking
/// indicator candidates. It deliberately stays out of `ManagedAgentTileNSView`:
/// Component Lab can compare the candidates in recognizable tile chrome without
/// choosing or shipping one.
@MainActor
final class ThrobberCandidateGalleryView: NSView {
    enum Mode: Equatable {
        case live
        case snapshot
    }

    struct QALabelPair {
        let identifier: String
        let candidateFrameInGallery: NSRect
        let fixtureFrameInGallery: NSRect
        let candidateIntrinsicWidth: CGFloat
        let fixtureIntrinsicWidth: CGFloat
        let candidateTranslatesAutoresizingMask: Bool
        let fixtureTranslatesAutoresizingMask: Bool
        let candidateHasAmbiguousLayout: Bool
        let fixtureHasAmbiguousLayout: Bool
    }

    struct QAIndicatorFixture {
        let identifier: String
        let reducedMotion: Bool
        let indicator: NSView & AgentThinkingIndicatorAnimating
    }

    enum Candidate: String, CaseIterable {
        case orbitingTriad = "A · Orbit"
        case thinkingWave = "B · Wave"
        case breathingSpark = "C · Spark"
        case drawingLoop = "D · Loop"

        var identifier: String {
            switch self {
            case .orbitingTriad: return "orbitingTriad"
            case .thinkingWave: return "thinkingWave"
            case .breathingSpark: return "breathingSpark"
            case .drawingLoop: return "drawingLoop"
            }
        }

        @MainActor
        func makeIndicator() -> (NSView & AgentThinkingIndicatorAnimating) {
            switch self {
            case .orbitingTriad:
                return OrbitingTriadThinkingIndicatorView(reducedMotion: false)
            case .thinkingWave:
                return ThinkingWaveIndicatorView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
            case .breathingSpark:
                return BreathingSparkIndicatorView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
            case .drawingLoop:
                return DrawingLoopIndicatorView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
            }
        }
    }

    enum Stage: String, CaseIterable {
        case starting = "Starting"
        case thinking = "Thinking"
        case responding = "Responding"

        var snapshotPhase: CGFloat {
            switch self {
            case .starting: return 0.08
            case .thinking: return 0.38
            case .responding: return 0.72
            }
        }

        var statusSummary: String {
            switch self {
            case .starting: return "session starting · preparing context"
            case .thinking: return "agent thinking · reading files"
            case .responding: return "responding · streaming answer"
            }
        }
    }

    struct Fixture: Equatable {
        let stage: Stage
        let reducedMotion: Bool

        var label: String { reducedMotion ? "Reduced" : "Normal" }
        var identifier: String { "\(reducedMotion ? "reduced" : "normal").\(stage.rawValue.lowercased())" }
    }

    static let fixtures: [Fixture] = [false, true].flatMap { reduced in
        Stage.allCases.map { Fixture(stage: $0, reducedMotion: reduced) }
    }

    static let preferredSize = NSSize(width: 940, height: 560)
    private let titleLabel = NSTextField(labelWithString: "Managed-agent throbber candidates")
    private let subtitleLabel = NSTextField(labelWithString: "Deterministic snapshot phases: Normal vs Reduced Motion across Starting, Thinking, and Responding. Motion quality remains a supervised review item.")
    private let mode: Mode
    private let grid = NSView()
    private var indicatorViews: [NSView & AgentThinkingIndicatorAnimating] = []
    private var tileViews: [ThrobberCandidateTileView] = []

    init(frame frameRect: NSRect, mode: Mode) {
        self.mode = mode
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = CGFloat(Radius.container)
        layer?.masksToBounds = false
        identifier = NSUserInterfaceItemIdentifier("throbberCandidates.gallery")

        titleLabel.identifier = NSUserInterfaceItemIdentifier("throbberCandidates.title")
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        subtitleLabel.identifier = NSUserInterfaceItemIdentifier("throbberCandidates.subtitle")
        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 2

        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.identifier = NSUserInterfaceItemIdentifier("throbberCandidates.grid")

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

        buildRows()
        applyAppearance()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Managed-agent throbber candidate gallery")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { Self.preferredSize }

    override func layout() {
        super.layout()
        layoutTiles()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceRecursively(from: self)
    }

    var qaIndicatorViews: [NSView & AgentThinkingIndicatorAnimating] { indicatorViews }
    var qaIndicatorFixtures: [QAIndicatorFixture] {
        tileViews.map { $0.qaIndicatorFixture }
    }
    var qaHeaderLabelPairs: [QALabelPair] {
        tileViews.map { $0.qaLabelPair(in: self) }
    }
    var qaFixtureCount: Int { Self.fixtures.count }
    var qaCandidateCount: Int { Candidate.allCases.count }

    private func buildRows() {
        for fixture in Self.fixtures {
            for candidate in Candidate.allCases {
                let tile = ThrobberCandidateTileView(candidate: candidate, fixture: fixture, mode: mode)
                tile.autoresizingMask = []
                tile.identifier = NSUserInterfaceItemIdentifier("throbberCandidates.tile.\(candidate.identifier).\(fixture.identifier)")
                indicatorViews.append(tile.indicator)
                tileViews.append(tile)
                grid.addSubview(tile)
            }
        }
    }

    private func layoutTiles() {
        let columns = ThrobberCandidateGalleryView.Candidate.allCases.count
        let rows = ThrobberCandidateGalleryView.fixtures.count
        guard columns > 0, rows > 0 else { return }
        let gap = CGFloat(Space.s)
        let tileWidth = floor((grid.bounds.width - gap * CGFloat(columns - 1)) / CGFloat(columns))
        let tileHeight = floor((grid.bounds.height - gap * CGFloat(rows - 1)) / CGFloat(rows))
        for (index, tile) in tileViews.enumerated() {
            let row = index / columns
            let column = index % columns
            let x = CGFloat(column) * (tileWidth + gap)
            let y = grid.bounds.height - CGFloat(row + 1) * tileHeight - CGFloat(row) * gap
            tile.frame = NSRect(x: x, y: y, width: tileWidth, height: tileHeight)
            tile.layoutSubtreeIfNeeded()
        }
    }

    private func applyAppearanceRecursively(from view: NSView) {
        if let themed = view as? ThrobberCandidateAppearanceApplying { themed.applyAppearance() }
        view.subviews.forEach(applyAppearanceRecursively)
        applyAppearance()
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
private protocol ThrobberCandidateAppearanceApplying: AnyObject {
    func applyAppearance()
}

@MainActor
private final class ThrobberCandidateTileView: NSView, ThrobberCandidateAppearanceApplying {
    let indicator: NSView & AgentThinkingIndicatorAnimating

    private let fixture: ThrobberCandidateGalleryView.Fixture
    private let candidateIdentifier: String
    private let fixtureIdentifier: String
    private let header = NSView()
    private let candidateLabel: NSTextField
    private let fixtureLabel: NSTextField
    private let statusLabel: NSTextField
    private let pathLabel: NSTextField
    private let indicatorWell = NSView()

    init(
        candidate: ThrobberCandidateGalleryView.Candidate,
        fixture: ThrobberCandidateGalleryView.Fixture,
        mode: ThrobberCandidateGalleryView.Mode
    ) {
        self.indicator = candidate.makeIndicator()
        self.fixture = fixture
        self.candidateIdentifier = candidate.identifier
        self.fixtureIdentifier = fixture.identifier
        self.candidateLabel = NSTextField(labelWithString: candidate.rawValue)
        self.fixtureLabel = NSTextField(labelWithString: fixture.label)
        self.statusLabel = NSTextField(labelWithString: fixture.stage.statusSummary)
        self.pathLabel = NSTextField(labelWithString: "Claude · feature/throbber-study")
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 72))

        wantsLayer = true
        layer?.cornerRadius = CGFloat(Radius.container)
        layer?.masksToBounds = false
        identifier = NSUserInterfaceItemIdentifier("throbberCandidates.tile.\(candidate.identifier).\(fixture.identifier)")

        header.wantsLayer = true
        header.translatesAutoresizingMaskIntoConstraints = false
        header.identifier = NSUserInterfaceItemIdentifier("throbberCandidates.header.\(candidate.identifier).\(fixture.identifier)")

        candidateLabel.identifier = NSUserInterfaceItemIdentifier("throbberCandidates.candidate.\(candidate.identifier).\(fixture.identifier)")
        candidateLabel.translatesAutoresizingMaskIntoConstraints = false
        candidateLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        candidateLabel.lineBreakMode = .byTruncatingTail
        candidateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        candidateLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        fixtureLabel.identifier = NSUserInterfaceItemIdentifier("throbberCandidates.fixture.\(candidate.identifier).\(fixture.identifier)")
        fixtureLabel.translatesAutoresizingMaskIntoConstraints = false
        fixtureLabel.font = .systemFont(ofSize: 10, weight: .medium)
        fixtureLabel.lineBreakMode = .byTruncatingTail
        fixtureLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        fixtureLabel.setContentHuggingPriority(.required, for: .horizontal)

        pathLabel.identifier = NSUserInterfaceItemIdentifier("throbberCandidates.path.\(candidate.identifier).\(fixture.identifier)")
        pathLabel.font = .systemFont(ofSize: 10, weight: .regular)
        pathLabel.lineBreakMode = .byTruncatingTail

        statusLabel.identifier = NSUserInterfaceItemIdentifier("throbberCandidates.status.\(candidate.identifier).\(fixture.identifier)")
        statusLabel.font = .systemFont(ofSize: 10, weight: .regular)
        statusLabel.lineBreakMode = .byTruncatingTail

        indicator.identifier = NSUserInterfaceItemIdentifier("throbberCandidates.indicator.\(candidate.identifier).\(fixture.identifier)")
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.setReducedMotion(fixture.reducedMotion)
        indicator.setSnapshotPhase(fixture.stage.snapshotPhase)
        if mode == .live && !fixture.reducedMotion {
            indicator.startAnimating()
        }

        indicatorWell.wantsLayer = true
        indicatorWell.layer?.cornerRadius = CGFloat(Radius.card)
        indicatorWell.translatesAutoresizingMaskIntoConstraints = false
        indicatorWell.identifier = NSUserInterfaceItemIdentifier("throbberCandidates.indicatorWell.\(candidate.identifier).\(fixture.identifier)")
        indicatorWell.addSubview(indicator)

        let textStack = NSStackView(views: [pathLabel, statusLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = CGFloat(Space.xs)
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView(views: [indicatorWell, textStack])
        body.orientation = .horizontal
        body.alignment = .centerY
        body.spacing = CGFloat(Space.s)
        body.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        header.addSubview(candidateLabel)
        header.addSubview(fixtureLabel)
        addSubview(body)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: 24),

            candidateLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: CGFloat(Space.s)),
            candidateLabel.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -CGFloat(Space.s)),
            candidateLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            candidateLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: ceil(candidateLabel.intrinsicContentSize.width)),
            fixtureLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -CGFloat(Space.s)),
            fixtureLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            fixtureLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: ceil(fixtureLabel.intrinsicContentSize.width) + 2),
            fixtureLabel.leadingAnchor.constraint(greaterThanOrEqualTo: candidateLabel.trailingAnchor, constant: CGFloat(Space.s)),

            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(Space.s)),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(Space.s)),
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: CGFloat(Space.xs)),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CGFloat(Space.s)),

            indicatorWell.widthAnchor.constraint(equalToConstant: 34),
            indicatorWell.heightAnchor.constraint(equalToConstant: 34),
            indicator.centerXAnchor.constraint(equalTo: indicatorWell.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: indicatorWell.centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 18),
            indicator.heightAnchor.constraint(equalToConstant: 18),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(candidate.rawValue), \(fixture.label), \(fixture.stage.statusSummary)")
        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    var qaIndicatorFixture: ThrobberCandidateGalleryView.QAIndicatorFixture {
        ThrobberCandidateGalleryView.QAIndicatorFixture(
            identifier: "\(candidateIdentifier).\(fixtureIdentifier)",
            reducedMotion: fixture.reducedMotion,
            indicator: indicator
        )
    }

    func qaLabelPair(in ancestor: NSView) -> ThrobberCandidateGalleryView.QALabelPair {
        ThrobberCandidateGalleryView.QALabelPair(
            identifier: "\(candidateIdentifier).\(fixtureIdentifier)",
            candidateFrameInGallery: candidateLabel.convert(candidateLabel.bounds, to: ancestor),
            fixtureFrameInGallery: fixtureLabel.convert(fixtureLabel.bounds, to: ancestor),
            candidateIntrinsicWidth: candidateLabel.intrinsicContentSize.width,
            fixtureIntrinsicWidth: fixtureLabel.intrinsicContentSize.width,
            candidateTranslatesAutoresizingMask: candidateLabel.translatesAutoresizingMaskIntoConstraints,
            fixtureTranslatesAutoresizingMask: fixtureLabel.translatesAutoresizingMaskIntoConstraints,
            candidateHasAmbiguousLayout: candidateLabel.hasAmbiguousLayout,
            fixtureHasAmbiguousLayout: fixtureLabel.hasAmbiguousLayout
        )
    }

    func applyAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = SurfaceToken.tileBody.color.cgColor(in: self)
        layer?.borderColor = LineToken.border.color.cgColor(in: self)
        layer?.borderWidth = 1
        header.layer?.backgroundColor = SurfaceToken.tileChrome.color.cgColor(in: self)
        indicatorWell.layer?.backgroundColor = SurfaceToken.cardTool.color.cgColor(in: self)
        indicatorWell.layer?.borderColor = LineToken.border.color.cgColor(in: self)
        indicatorWell.layer?.borderWidth = 1
        candidateLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        fixtureLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        pathLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        statusLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        CATransaction.commit()
    }
}
