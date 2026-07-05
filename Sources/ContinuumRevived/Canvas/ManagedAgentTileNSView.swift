import AppKit
import ContinuumRevivedCore
import Foundation

@MainActor
final class ManagedAgentTileNSView: TileNSView {
    private let header = NSStackView()
    private let glyphLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let phaseLabel = NSTextField(labelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "0s")
    private let cardStack = NSStackView()
    private let approvalDock = NSTextField(labelWithString: "Approval dock - ticket 72")
    private var cardViewsById: [String: TranscriptCardView] = [:]
    private var model: ManagedAgentTranscriptModel
    private var descriptor: AgentDescriptor
    private var startedAt: Date?

    init(tile: Tile, threadId: String = "thread-main", descriptor: AgentDescriptor? = nil) {
        self.model = ManagedAgentTranscriptModel(threadId: threadId)
        self.descriptor = descriptor ?? AgentDescriptor(
            agentKind: .managed,
            worktreePath: "",
            status: .configuring,
            statusUpdatedAt: Date()
        )
        super.init(tile: tile)
        setContentView(makeContentView())
        applyHeader(status: self.descriptor.status)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var transcriptCardCount: Int { model.cards.count }
    var activeToolCount: Int { model.activeToolCount }
    var currentAgentStatus: AgentStatus { descriptor.status }

    func ingest(_ event: AgentRuntimeEvent) {
        if startedAt == nil {
            if case .turnStarted = event { startedAt = Date() }
        }
        model.ingest(event)
        descriptor.status = model.currentStatus
        descriptor.statusUpdatedAt = Date()
        agentStatus = model.currentStatus
        applyHeader(status: model.currentStatus)
        reconcileCards()
    }

    private func makeContentView() -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(red: 0.08, green: 0.10, blue: 0.13, alpha: 1).cgColor

        configureHeader()

        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 8
        cardStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.documentView = cardStack

        approvalDock.font = .systemFont(ofSize: 11)
        approvalDock.textColor = .tertiaryLabelColor
        approvalDock.alignment = .center
        approvalDock.wantsLayer = true
        approvalDock.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        approvalDock.setContentCompressionResistancePriority(.required, for: .vertical)

        let layout = NSStackView(views: [header, scrollView, approvalDock])
        layout.orientation = .vertical
        layout.spacing = 0
        layout.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            layout.topAnchor.constraint(equalTo: root.topAnchor),
            layout.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            header.heightAnchor.constraint(equalToConstant: 52),
            approvalDock.heightAnchor.constraint(equalToConstant: 22),
            cardStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 420)
        ])
        return root
    }

    private func configureHeader() {
        glyphLabel.font = .systemFont(ofSize: 18, weight: .bold)
        glyphLabel.alignment = .center
        glyphLabel.widthAnchor.constraint(equalToConstant: 28).isActive = true
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        phaseLabel.font = .systemFont(ofSize: 12, weight: .medium)
        phaseLabel.textColor = .secondaryLabelColor
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        elapsedLabel.textColor = .tertiaryLabelColor

        let textStack = NSStackView(views: [nameLabel, phaseLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor(red: 0.11, green: 0.13, blue: 0.16, alpha: 1).cgColor
        header.addArrangedSubview(glyphLabel)
        header.addArrangedSubview(textStack)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(elapsedLabel)
    }

    private func applyHeader(status: AgentStatus) {
        nameLabel.stringValue = tile.title
        glyphLabel.stringValue = Self.glyph(for: status)
        glyphLabel.textColor = Self.color(for: status)
        phaseLabel.stringValue = Self.phase(for: status)
        if let startedAt, status == .working || status == .needsAttention {
            elapsedLabel.stringValue = "\(max(0, Int(Date().timeIntervalSince(startedAt))))s"
        }
    }

    private func reconcileCards() {
        for card in model.cards {
            if let view = cardViewsById[card.id] {
                view.apply(card)
            } else {
                let view = TranscriptCardView(card: card)
                cardViewsById[card.id] = view
                cardStack.addArrangedSubview(view)
                view.translatesAutoresizingMaskIntoConstraints = false
                view.widthAnchor.constraint(equalTo: cardStack.widthAnchor, constant: -24).isActive = true
            }
        }
    }

    private static func glyph(for status: AgentStatus) -> String {
        switch status {
        case .needsAttention: return "◆"
        case .working: return "●"
        case .done: return "✓"
        case .stale: return "!"
        case .idle: return "○"
        case .configuring: return "◌"
        }
    }

    private static func phase(for status: AgentStatus) -> String {
        switch status {
        case .needsAttention: return "needs you"
        case .working: return "working"
        case .done: return "done"
        case .stale: return "stale"
        case .idle: return "idle"
        case .configuring: return "configuring"
        }
    }

    private static func color(for status: AgentStatus) -> NSColor {
        switch status {
        case .needsAttention: return .systemOrange
        case .working: return .systemBlue
        case .done: return .systemGreen
        case .stale: return .systemGray
        case .idle: return .systemTeal
        case .configuring: return .systemPurple
        }
    }
}
