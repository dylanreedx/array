import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// B4 — Array's own follow-up queue, rendered as chips. Deleting a chip is
/// direct manipulation of Array's queue and never touches the turn in flight:
/// the primary composer control keeps ONE meaning, "interrupt the current
/// turn". Modeled on `ComposerFileReferenceRailView`'s chip-rail shape.
@MainActor
final class ComposerQueuedMessageRailView: NSView, TokenThemed, AgentPageZoomScalable {
    static let railHeight: CGFloat = 40

    /// The rail's reserved height at `zoom`. The un-parameterised `railHeight`
    /// stays for callers that reserve space at 100%.
    static func railHeight(zoom: AgentPageZoom) -> CGFloat {
        CGFloat(zoom.scaled(40))
    }

    private(set) var pageZoom: AgentPageZoom = .default

    /// This rail's reserved height at its own zoom.
    var railHeight: CGFloat { Self.railHeight(zoom: pageZoom) }

    private let scrollView = NSScrollView(frame: .zero)
    private let stack = NSStackView(frame: .zero)
    private let clearButton = NSButton(title: "Clear queued", target: nil, action: nil)
    private var messages: [AgentComposerQueuedMessage] = []
    private var paused = false

    /// Deletes one queued message. Never touches the turn in flight.
    var onRemove: ((UUID) -> Void)?
    /// "Clear queued" — every chip at once, still without touching the turn
    /// in flight.
    var onClearAll: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureViews()
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: messages.isEmpty ? 0 : railHeight)
    }

    /// `paused` reflects `AgentSupervisor.isQueuePaused(for:)` — held after an
    /// interrupted turn so a user who stopped to look does not see the queue
    /// implying it is about to run.
    func setMessages(_ newMessages: [AgentComposerQueuedMessage], paused isPaused: Bool) {
        messages = newMessages
        paused = isPaused
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let theme = effectiveTokenTheme
        for message in newMessages {
            // A chip minted after a zoom apply is born scaled: the rail's own
            // rung is handed to the initializer.
            let chip = ComposerQueuedMessageChipView(
                message: message, paused: isPaused, zoom: pageZoom
            ) { [weak self] removed in
                self?.onRemove?(removed)
            }
            chip.applyTokens(theme: theme)
            stack.addArrangedSubview(chip)
        }
        // The loop above already removed every previous arranged subview,
        // `clearButton` included when it was present — so there is nothing to
        // tear down here, only a conditional re-add. Calling
        // `removeArrangedSubview` on a view NSStackView no longer holds is a
        // hard assertion failure, not a no-op (crashed exactly this way on
        // the very next detach after a 2+-message queue).
        if newMessages.count > 1 {
            stack.addArrangedSubview(clearButton)
        }
        isHidden = newMessages.isEmpty
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func applyTokens() {
        layer?.backgroundColor = nil
        let theme = effectiveTokenTheme
        for case let chip as ComposerQueuedMessageChipView in stack.arrangedSubviews {
            chip.applyTokens(theme: theme)
        }
        clearButton.contentTintColor = TextToken.textSecondary.color.nsColor(for: theme)
    }

    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        applyStackMetrics()
        clearButton.font = .token(.caption, zoom: zoom)
        for case let chip as ComposerQueuedMessageChipView in stack.arrangedSubviews {
            chip.applyPageZoom(zoom)
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    private func applyStackMetrics() {
        stack.spacing = CGFloat(pageZoom.scaled(Space.s))
        stack.edgeInsets = NSEdgeInsets(
            top: CGFloat(pageZoom.scaled(Space.xs)), left: 0,
            bottom: CGFloat(pageZoom.scaled(Space.xs)), right: 0
        )
    }

    private func configureViews() {
        wantsLayer = true
        isHidden = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("Queued messages")
        setAccessibilityHelp("Messages Array will send once the current turn finishes.")

        stack.orientation = .horizontal
        stack.alignment = .centerY
        applyStackMetrics()
        stack.translatesAutoresizingMaskIntoConstraints = false

        clearButton.isBordered = false
        clearButton.bezelStyle = .regularSquare
        clearButton.setButtonType(.momentaryPushIn)
        clearButton.font = .token(.caption, zoom: pageZoom)
        clearButton.target = self
        clearButton.action = #selector(clearPressed(_:))
        clearButton.setAccessibilityLabel("Clear queued messages")

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = stack
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
        ])
    }

    @objc private func clearPressed(_ sender: NSButton) {
        onClearAll?()
    }

    // MARK: - QA seams

    var qaMessageCount: Int { messages.count }
    var qaIsPaused: Bool { paused }
    var qaPreviewTexts: [String] {
        stack.arrangedSubviews.compactMap { ($0 as? ComposerQueuedMessageChipView)?.qaPreviewText }
    }

    func qaRemove(at index: Int) {
        guard messages.indices.contains(index) else { return }
        onRemove?(messages[index].id)
    }
}

@MainActor
private final class ComposerQueuedMessageChipView: NSView {
    private let glyphLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private let removeButton = NSButton(title: "×", target: nil, action: nil)
    private let messageID: UUID
    private let onRemove: (UUID) -> Void

    private(set) var pageZoom: AgentPageZoom

    // Metrics baked into an activated anchor cannot be re-derived, so every
    // zoom-dependent constant is held.
    private var heightConstraint: NSLayoutConstraint!
    private var glyphLeadingConstraint: NSLayoutConstraint!
    private var previewLeadingConstraint: NSLayoutConstraint!
    private var maxWidthConstraint: NSLayoutConstraint!
    private var removeLeadingConstraint: NSLayoutConstraint!
    private var removeTrailingConstraint: NSLayoutConstraint!
    private var removeWidthConstraint: NSLayoutConstraint!
    private var removeHeightConstraint: NSLayoutConstraint!

    init(
        message: AgentComposerQueuedMessage,
        paused: Bool,
        zoom: AgentPageZoom = .default,
        onRemove: @escaping (UUID) -> Void
    ) {
        self.messageID = message.id
        self.pageZoom = zoom
        self.onRemove = onRemove
        super.init(frame: .zero)
        configureViews(previewText: Self.preview(for: message), paused: paused)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var qaPreviewText: String { previewLabel.stringValue }

    private static func preview(for message: AgentComposerQueuedMessage) -> String {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        if !message.imageAttachments.isEmpty { return "Image" }
        if !message.fileReferences.isEmpty { return "File" }
        return "Queued message"
    }

    private func configureViews(previewText: String, paused: Bool) {
        wantsLayer = true
        setAccessibilityRole(.group)

        glyphLabel.stringValue = paused ? "⏸" : "⏳"
        glyphLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyphLabel)

        previewLabel.stringValue = previewText
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(previewLabel)

        removeButton.isBordered = false
        removeButton.bezelStyle = .regularSquare
        removeButton.setButtonType(.momentaryPushIn)
        removeButton.target = self
        removeButton.action = #selector(removePressed(_:))
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.setAccessibilityLabel("Remove queued message")
        addSubview(removeButton)

        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        glyphLeadingConstraint = glyphLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0)
        previewLeadingConstraint = previewLabel.leadingAnchor.constraint(
            equalTo: glyphLabel.trailingAnchor, constant: 0
        )
        maxWidthConstraint = previewLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 0)
        maxWidthConstraint.priority = .required
        removeLeadingConstraint = removeButton.leadingAnchor.constraint(
            equalTo: previewLabel.trailingAnchor, constant: 0
        )
        removeTrailingConstraint = removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0)
        removeWidthConstraint = removeButton.widthAnchor.constraint(equalToConstant: 0)
        removeHeightConstraint = removeButton.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightConstraint,
            glyphLeadingConstraint,
            glyphLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            previewLeadingConstraint,
            previewLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            maxWidthConstraint,
            removeLeadingConstraint,
            removeTrailingConstraint,
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeWidthConstraint,
            removeHeightConstraint,
        ])

        applyPageZoom(pageZoom)

        let label = paused
            ? "Queued message, held after interrupt: \(previewText)"
            : "Queued message: \(previewText)"
        toolTip = label
        setAccessibilityLabel(label)
    }

    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        layer?.cornerRadius = CGFloat(zoom.scaled(AgentTileRadius.artifact))
        glyphLabel.font = .systemFont(ofSize: CGFloat(zoom.scaled(13)), weight: .semibold)
        previewLabel.font = .token(.caption, zoom: zoom)
        removeButton.font = .systemFont(ofSize: CGFloat(zoom.scaled(13)), weight: .semibold)
        heightConstraint.constant = CGFloat(zoom.scaled(26))
        glyphLeadingConstraint.constant = CGFloat(zoom.scaled(Space.s))
        previewLeadingConstraint.constant = CGFloat(zoom.scaled(Space.xs))
        maxWidthConstraint.constant = CGFloat(zoom.scaled(200))
        removeLeadingConstraint.constant = CGFloat(zoom.scaled(Space.xs))
        removeTrailingConstraint.constant = -CGFloat(zoom.scaled(Space.xs))
        removeWidthConstraint.constant = CGFloat(zoom.scaled(18))
        removeHeightConstraint.constant = CGFloat(zoom.scaled(18))
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func applyTokens(theme: TokenTheme) {
        wantsLayer = true
        layer?.backgroundColor = AgentSurfaceRole.artifact.color.cgColor(for: theme)
        layer?.borderColor = AgentLineRole.decorativeHairline.color.cgColor(for: theme)
        layer?.borderWidth = 1
        glyphLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        previewLabel.textColor = TextToken.textPrimary.color.nsColor(for: theme)
        removeButton.contentTintColor = TextToken.textSecondary.color.nsColor(for: theme)
    }

    @objc private func removePressed(_ sender: NSButton) {
        onRemove(messageID)
    }
}
