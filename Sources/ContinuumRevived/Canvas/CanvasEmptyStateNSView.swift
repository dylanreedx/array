import AppKit

@MainActor
struct CanvasEmptyStateActions {
    let spawnClaude: () -> Void
    let spawnShell: () -> Void
    let spawnBrowser: () -> Void
    let openInEditor: () -> Void
}

@MainActor
final class CanvasEmptyStateNSView: NSView {
    var actions: CanvasEmptyStateActions?

    private let stack = NSStackView()

    init(actions: CanvasEmptyStateActions?) {
        self.actions = actions
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = true
        wantsLayer = false
        setupStack()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let fittingSize = stack.fittingSize
        stack.frame = NSRect(
            x: floor((bounds.width - fittingSize.width) / 2),
            y: floor((bounds.height - fittingSize.height) / 2),
            width: fittingSize.width,
            height: fittingSize.height
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        for subview in subviews.reversed() {
            let converted = convert(point, to: subview)
            if let hit = subview.hitTest(converted), hit is NSButton {
                return hit
            }
        }
        return nil
    }

    private func setupStack() {
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = true
        addSubview(stack)

        stack.addArrangedSubview(makeButton(title: "Spawn Claude", action: #selector(spawnClaude)))
        stack.addArrangedSubview(makeButton(title: "Spawn Shell", action: #selector(spawnShell)))
        stack.addArrangedSubview(makeButton(title: "Spawn Browser", action: #selector(spawnBrowser)))
        stack.addArrangedSubview(makeButton(title: "Open in Editor", action: #selector(openInEditor)))
    }

    private func makeButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.setButtonType(.momentaryPushIn)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 160),
            button.heightAnchor.constraint(equalToConstant: 28)
        ])
        return button
    }

    @objc private func spawnClaude() {
        actions?.spawnClaude()
    }

    @objc private func spawnShell() {
        actions?.spawnShell()
    }

    @objc private func spawnBrowser() {
        actions?.spawnBrowser()
    }

    @objc private func openInEditor() {
        actions?.openInEditor()
    }
}
