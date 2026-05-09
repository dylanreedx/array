import AppKit
import ContinuumRevivedCore
import Foundation

/// Placeholder tile view for terminal tiles whose runtime hasn't started
/// (or whose previous session exited). Renders the status text plus a
/// Restart button that hands back through the supplied closure. If
/// `onRestart` is nil the tile is in a terminal error state with no action.
@MainActor
final class TerminalRestartTileNSView: TileNSView {
    private let onRestart: (() -> Void)?

    init(tile: Tile, statusText: String, onRestart: (() -> Void)?) {
        self.onRestart = onRestart
        super.init(tile: tile)

        let body = NSView()
        body.wantsLayer = true
        body.layer?.backgroundColor = NSColor(white: 0.06, alpha: 1.0).cgColor

        let status = NSTextField(labelWithString: statusText)
        status.font = .systemFont(ofSize: 13, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        status.maximumNumberOfLines = 3
        status.lineBreakMode = .byWordWrapping
        status.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton(
            title: onRestart == nil ? "Open Cmd-K" : "Restart",
            target: self,
            action: #selector(handleAction(_:))
        )
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        if onRestart == nil {
            button.isEnabled = false
        }

        let stack = NSStackView(views: [status, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        body.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: body.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: body.trailingAnchor, constant: -16)
        ])

        setContentView(body)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func handleAction(_ sender: Any?) {
        onRestart?()
    }
}
