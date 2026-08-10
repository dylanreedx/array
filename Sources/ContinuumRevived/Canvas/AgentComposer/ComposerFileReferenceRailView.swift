import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation
import UniformTypeIdentifiers

/// A compact single-row rail of file-reference chips (icon + filename + remove).
/// Unlike the image rail there is no thumbnail pipeline — a reference carries no
/// bytes, only a `@/path` the agent Reads. Chips paint token surfaces; the rail
/// itself leaves its resting background unpainted (nil, never `.clear`) so the
/// appearance census owns no literal here.
@MainActor
final class ComposerFileReferenceRailView: NSView, TokenThemed {
    static let railHeight: CGFloat = 40

    private let scrollView = NSScrollView(frame: .zero)
    private let stack = NSStackView(frame: .zero)
    private var references: [AgentPromptFileReference] = []

    var onRemove: ((AgentPromptFileReference) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureViews()
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: references.isEmpty ? 0 : Self.railHeight)
    }

    func setReferences(_ newReferences: [AgentPromptFileReference]) {
        references = newReferences
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let theme = effectiveTokenTheme
        for reference in newReferences {
            let chip = ComposerFileReferenceChipView(reference: reference) { [weak self] removed in
                self?.onRemove?(removed)
            }
            chip.applyTokens(theme: theme)
            stack.addArrangedSubview(chip)
        }
        isHidden = newReferences.isEmpty
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func applyTokens() {
        // Resting background is deliberately unpainted — a painted transparent
        // would register as an unadopted literal in the appearance census.
        layer?.backgroundColor = nil
        let theme = effectiveTokenTheme
        for case let chip as ComposerFileReferenceChipView in stack.arrangedSubviews {
            chip.applyTokens(theme: theme)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    private func configureViews() {
        wantsLayer = true
        isHidden = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("File attachments")
        setAccessibilityHelp("Files referenced for the agent to read. Each is passed as a path, not embedded.")

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = CGFloat(Space.s)
        stack.edgeInsets = NSEdgeInsets(
            top: CGFloat(Space.xs), left: 0, bottom: CGFloat(Space.xs), right: 0
        )
        stack.translatesAutoresizingMaskIntoConstraints = false

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

    // MARK: - QA seams

    var qaReferenceCount: Int { references.count }
    var qaDisplayNames: [String] {
        stack.arrangedSubviews.compactMap { ($0 as? ComposerFileReferenceChipView)?.qaDisplayName }
    }
    var qaAccessibilityLabels: [String] {
        stack.arrangedSubviews.compactMap { ($0 as? ComposerFileReferenceChipView)?.accessibilityLabel() }
    }

    func qaRemove(at index: Int) {
        guard references.indices.contains(index) else { return }
        onRemove?(references[index])
    }
}

@MainActor
private final class ComposerFileReferenceChipView: NSView {
    private let glyphLabel = NSTextField(labelWithString: "")
    private let nameLabel = NSTextField(labelWithString: "")
    private let removeButton = NSButton(title: "×", target: nil, action: nil)
    private let reference: AgentPromptFileReference
    private let onRemove: (AgentPromptFileReference) -> Void

    init(reference: AgentPromptFileReference, onRemove: @escaping (AgentPromptFileReference) -> Void) {
        self.reference = reference
        self.onRemove = onRemove
        super.init(frame: .zero)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var qaDisplayName: String { nameLabel.stringValue }

    private func configureViews() {
        wantsLayer = true
        layer?.cornerRadius = CGFloat(AgentTileRadius.artifact)
        setAccessibilityRole(.group)

        glyphLabel.stringValue = "▤"
        glyphLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        glyphLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyphLabel)

        nameLabel.stringValue = ComposerImageDisplay.sanitizedFilename(reference.displayName)
        nameLabel.font = .token(.caption)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        removeButton.isBordered = false
        removeButton.bezelStyle = .regularSquare
        removeButton.setButtonType(.momentaryPushIn)
        removeButton.font = .systemFont(ofSize: 13, weight: .semibold)
        removeButton.target = self
        removeButton.action = #selector(removePressed(_:))
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.setAccessibilityLabel("Remove file attachment")
        addSubview(removeButton)

        let maxNameWidth = nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 200)
        maxNameWidth.priority = .required
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            glyphLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(Space.s)),
            glyphLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: glyphLabel.trailingAnchor, constant: CGFloat(Space.xs)),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            maxNameWidth,
            removeButton.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: CGFloat(Space.xs)),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(Space.xs)),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 18),
            removeButton.heightAnchor.constraint(equalToConstant: 18),
        ])

        toolTip = accessibilityChipLabel()
        setAccessibilityLabel(accessibilityChipLabel())
    }

    func applyTokens(theme: TokenTheme) {
        wantsLayer = true
        layer?.backgroundColor = AgentSurfaceRole.artifact.color.cgColor(for: theme)
        layer?.borderColor = AgentLineRole.decorativeHairline.color.cgColor(for: theme)
        layer?.borderWidth = 1
        glyphLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        nameLabel.textColor = TextToken.textPrimary.color.nsColor(for: theme)
        removeButton.contentTintColor = TextToken.textSecondary.color.nsColor(for: theme)
    }

    private func accessibilityChipLabel() -> String {
        "File attachment, \(ComposerImageDisplay.sanitizedFilename(reference.displayName)), \(typeLabel())"
    }

    private func typeLabel() -> String {
        guard let type = UTType(reference.contentType) else { return "File" }
        return type.localizedDescription ?? type.preferredFilenameExtension?.uppercased() ?? "File"
    }

    @objc private func removePressed(_ sender: NSButton) {
        onRemove(reference)
    }
}
