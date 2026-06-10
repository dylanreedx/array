import AppKit
import ContinuumRevivedCore
import Foundation

/// Tile view that hosts a read-only plain-text preview of a single file.
@MainActor
final class FileTileNSView: TileNSView {
    private(set) var textView: NSTextView
    private let scrollView: NSScrollView
    private let filePath: String?

    override init(tile: Tile) {
        self.filePath = tile.metadata.filePath

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.backgroundColor = NSColor(white: 0.10, alpha: 1.0)
        tv.textColor = NSColor(white: 0.90, alpha: 1.0)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.translatesAutoresizingMaskIntoConstraints = false

        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.hasHorizontalScroller = true
        sv.drawsBackground = false
        sv.documentView = tv

        self.textView = tv
        self.scrollView = sv

        super.init(tile: tile)

        setContentView(sv)
        tv.widthAnchor.constraint(greaterThanOrEqualTo: sv.contentView.widthAnchor).isActive = true
        loadFile()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func loadFile() {
        guard let filePath, !filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showMessage("File not found")
            return
        }

        if Self.shouldLoadAsynchronously(path: filePath) {
            textView.string = "Loading file..."
            Task.detached { [filePath] in
                let result = FilePreview.load(path: filePath)
                await MainActor.run { [weak self] in self?.apply(result) }
            }
        } else {
            apply(FilePreview.load(path: filePath))
        }
    }

    private func apply(_ result: FilePreview) {
        switch result {
        case let .text(content):
            setContentView(scrollView)
            textView.string = content
        case let .unavailable(message):
            showMessage(message)
        }
    }

    private func showMessage(_ message: String) {
        let label = NSTextField(labelWithString: message)
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(white: 0.82, alpha: 1.0)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.10, alpha: 1.0).cgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        setContentView(container)
    }

    nonisolated private static func shouldLoadAsynchronously(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey]),
           values.volumeIsLocal == false {
            return true
        }
        return false
    }
}
