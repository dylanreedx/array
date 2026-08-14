import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import UniformTypeIdentifiers

/// Path-free file chips for a submitted user turn. This mirrors the composer's
/// attachment rail, without remove controls or any ability to resolve the local
/// file after submission.
@MainActor
final class AgentFileReferenceRenderer: AgentBlockRendering {
    let kind: AgentBlockKind = .fileReferences

    func makeView() -> NSView { AgentFileReferenceRailView(frame: .zero) }

    func update(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentFileReferenceRailView,
              case let .fileReferences(payload) = block.payload else { return }
        view.apply(blockID: block.id, files: payload.files, context: context)
    }

    func measure(block: AgentBlock, width: CGFloat, context: AgentRenderContext) -> CGFloat {
        guard case let .fileReferences(payload) = block.payload, !payload.files.isEmpty else { return 0 }
        return AgentFileReferenceRailView.railHeight
    }

    func updateAccessibility(view: NSView, block: AgentBlock, context: AgentRenderContext) {
        guard let view = view as? AgentFileReferenceRailView,
              case let .fileReferences(payload) = block.payload else { return }
        view.applyAccessibility(files: payload.files)
    }
}

@MainActor
final class AgentFileReferenceRailView: NSView {
    static let railHeight: CGFloat = 40

    private let stack = NSStackView(frame: .zero)
    private var files: [AgentFileReferenceMetadata] = []
    private var context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: .dark)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = CGFloat(Space.s)
        addSubview(stack)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func apply(blockID: AgentNodeID, files: [AgentFileReferenceMetadata], context: AgentRenderContext) {
        self.files = files
        self.context = context
        identifier = NSUserInterfaceItemIdentifier("agent.fileReferences.\(blockID.rawValue)")
        for child in stack.arrangedSubviews {
            stack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
        for file in files {
            stack.addArrangedSubview(AgentFileReferenceChipView(file: file, context: context))
        }
        applyAccessibility(files: files)
        needsLayout = true
    }

    func applyAccessibility(files: [AgentFileReferenceMetadata]) {
        setAccessibilityLabel("File attachments")
        setAccessibilityValue(files.map { safeName($0.displayName) }.joined(separator: ", "))
    }

    override func layout() {
        super.layout()
        let size = stack.fittingSize
        stack.frame = NSRect(
            x: 0,
            y: max(0, (bounds.height - size.height) / 2),
            width: max(bounds.width, size.width),
            height: size.height
        )
        stack.layoutSubtreeIfNeeded()
    }
}

@MainActor
private final class AgentFileReferenceChipView: NSView {
    private let glyphLabel = NSTextField(labelWithString: "▤")
    private let nameLabel = NSTextField(labelWithString: "")

    init(file: AgentFileReferenceMetadata, context: AgentRenderContext) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CGFloat(AgentTileRadius.artifact)
        layer?.backgroundColor = context.tokens.artifactSurface.color.cgColor(for: context.appearance)
        layer?.borderColor = context.tokens.decorativeLine.color.cgColor(for: context.appearance)
        layer?.borderWidth = 1

        glyphLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        glyphLabel.textColor = context.tokens.secondaryText.color.nsColor(for: context.appearance)
        glyphLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyphLabel)

        let name = safeName(file.displayName)
        nameLabel.stringValue = name
        nameLabel.font = .token(.caption)
        nameLabel.textColor = context.tokens.primaryText.color.nsColor(for: context.appearance)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        let typeName = UTType(file.contentType)?.localizedDescription ?? "File"
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("File attachment, \(name), \(typeName)")
        toolTip = "\(name) — \(typeName)"

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            glyphLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(Space.s)),
            glyphLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: glyphLabel.trailingAnchor, constant: CGFloat(Space.xs)),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(Space.s)),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private func safeName(_ value: String) -> String {
    ComposerImageDisplay.sanitizedFilename(value, fallback: "File")
}
