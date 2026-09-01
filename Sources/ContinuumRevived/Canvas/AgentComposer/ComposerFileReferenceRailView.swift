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
final class ComposerFileReferenceRailView: NSView, TokenThemed, AgentPageZoomScalable {
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
        NSSize(width: NSView.noIntrinsicMetric, height: references.isEmpty ? 0 : railHeight)
    }

    func setReferences(_ newReferences: [AgentPromptFileReference]) {
        references = newReferences
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let theme = effectiveTokenTheme
        for reference in newReferences {
            // A chip minted after a zoom apply is born scaled: the rail's own
            // rung is handed to the initializer.
            let chip = ComposerFileReferenceChipView(reference: reference, zoom: pageZoom) { [weak self] removed in
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

    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        applyStackMetrics()
        for case let chip as ComposerFileReferenceChipView in stack.arrangedSubviews {
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
        setAccessibilityLabel("File attachments")
        setAccessibilityHelp("Files referenced for the agent to read. Each is passed as a path, not embedded.")

        stack.orientation = .horizontal
        stack.alignment = .centerY
        applyStackMetrics()
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

    private(set) var pageZoom: AgentPageZoom

    // Metrics baked into an activated anchor cannot be re-derived, so every
    // zoom-dependent constant is held.
    private var heightConstraint: NSLayoutConstraint!
    private var glyphLeadingConstraint: NSLayoutConstraint!
    private var nameLeadingConstraint: NSLayoutConstraint!
    private var maxNameWidthConstraint: NSLayoutConstraint!
    private var removeLeadingConstraint: NSLayoutConstraint!
    private var removeTrailingConstraint: NSLayoutConstraint!
    private var removeWidthConstraint: NSLayoutConstraint!
    private var removeHeightConstraint: NSLayoutConstraint!

    init(
        reference: AgentPromptFileReference,
        zoom: AgentPageZoom = .default,
        onRemove: @escaping (AgentPromptFileReference) -> Void
    ) {
        self.reference = reference
        self.pageZoom = zoom
        self.onRemove = onRemove
        super.init(frame: .zero)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var qaDisplayName: String { nameLabel.stringValue }

    private func configureViews() {
        wantsLayer = true
        setAccessibilityRole(.group)

        glyphLabel.stringValue = "▤"
        glyphLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyphLabel)

        nameLabel.stringValue = ComposerImageDisplay.sanitizedFilename(reference.displayName)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        removeButton.isBordered = false
        removeButton.bezelStyle = .regularSquare
        removeButton.setButtonType(.momentaryPushIn)
        removeButton.target = self
        removeButton.action = #selector(removePressed(_:))
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.setAccessibilityLabel("Remove file attachment")
        addSubview(removeButton)

        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        glyphLeadingConstraint = glyphLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0)
        nameLeadingConstraint = nameLabel.leadingAnchor.constraint(
            equalTo: glyphLabel.trailingAnchor, constant: 0
        )
        maxNameWidthConstraint = nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 0)
        maxNameWidthConstraint.priority = .required
        removeLeadingConstraint = removeButton.leadingAnchor.constraint(
            equalTo: nameLabel.trailingAnchor, constant: 0
        )
        removeTrailingConstraint = removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0)
        removeWidthConstraint = removeButton.widthAnchor.constraint(equalToConstant: 0)
        removeHeightConstraint = removeButton.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightConstraint,
            glyphLeadingConstraint,
            glyphLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLeadingConstraint,
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            maxNameWidthConstraint,
            removeLeadingConstraint,
            removeTrailingConstraint,
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeWidthConstraint,
            removeHeightConstraint,
        ])

        applyPageZoom(pageZoom)

        toolTip = accessibilityChipLabel()
        setAccessibilityLabel(accessibilityChipLabel())
    }

    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        layer?.cornerRadius = CGFloat(zoom.scaled(AgentTileRadius.artifact))
        glyphLabel.font = .systemFont(ofSize: CGFloat(zoom.scaled(13)), weight: .semibold)
        nameLabel.font = .token(.caption, zoom: zoom)
        removeButton.font = .systemFont(ofSize: CGFloat(zoom.scaled(13)), weight: .semibold)
        heightConstraint.constant = CGFloat(zoom.scaled(26))
        glyphLeadingConstraint.constant = CGFloat(zoom.scaled(Space.s))
        nameLeadingConstraint.constant = CGFloat(zoom.scaled(Space.xs))
        maxNameWidthConstraint.constant = CGFloat(zoom.scaled(200))
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
