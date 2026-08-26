import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// B4 — Array's own follow-up queue, rendered as chips. Deleting a chip is
/// direct manipulation of Array's queue and never touches the turn in flight:
/// the primary composer control keeps ONE meaning, "interrupt the current
/// turn". Modeled on `ComposerFileReferenceRailView`'s chip-rail shape.
@MainActor
final class ComposerQueuedMessageRailView: NSView, TokenThemed {
    static let railHeight: CGFloat = 40

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
        NSSize(width: NSView.noIntrinsicMetric, height: messages.isEmpty ? 0 : Self.railHeight)
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
            let chip = ComposerQueuedMessageChipView(message: message, paused: isPaused) { [weak self] removed in
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    private func configureViews() {
        wantsLayer = true
        isHidden = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("Queued messages")
        setAccessibilityHelp("Messages Array will send once the current turn finishes.")

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = CGFloat(Space.s)
        stack.edgeInsets = NSEdgeInsets(top: CGFloat(Space.xs), left: 0, bottom: CGFloat(Space.xs), right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false

        clearButton.isBordered = false
        clearButton.bezelStyle = .regularSquare
        clearButton.setButtonType(.momentaryPushIn)
        clearButton.font = .token(.caption)
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

    init(message: AgentComposerQueuedMessage, paused: Bool, onRemove: @escaping (UUID) -> Void) {
        self.messageID = message.id
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
        layer?.cornerRadius = CGFloat(AgentTileRadius.artifact)
        setAccessibilityRole(.group)

        glyphLabel.stringValue = paused ? "⏸" : "⏳"
        glyphLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        glyphLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyphLabel)

        previewLabel.stringValue = previewText
        previewLabel.font = .token(.caption)
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(previewLabel)

        removeButton.isBordered = false
        removeButton.bezelStyle = .regularSquare
        removeButton.setButtonType(.momentaryPushIn)
        removeButton.font = .systemFont(ofSize: 13, weight: .semibold)
        removeButton.target = self
        removeButton.action = #selector(removePressed(_:))
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.setAccessibilityLabel("Remove queued message")
        addSubview(removeButton)

        let maxWidth = previewLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 200)
        maxWidth.priority = .required
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            glyphLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(Space.s)),
            glyphLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            previewLabel.leadingAnchor.constraint(equalTo: glyphLabel.trailingAnchor, constant: CGFloat(Space.xs)),
            previewLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            maxWidth,
            removeButton.leadingAnchor.constraint(equalTo: previewLabel.trailingAnchor, constant: CGFloat(Space.xs)),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(Space.xs)),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 18),
            removeButton.heightAnchor.constraint(equalToConstant: 18),
        ])

        let label = paused
            ? "Queued message, held after interrupt: \(previewText)"
            : "Queued message: \(previewText)"
        toolTip = label
        setAccessibilityLabel(label)
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
