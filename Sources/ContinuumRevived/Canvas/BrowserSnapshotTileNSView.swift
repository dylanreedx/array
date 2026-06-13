import AppKit
import ContinuumRevivedCore
import Foundation

/// Snapshot-tier placeholder for a browser tile whose WKWebView has been
/// torn down. The bitmap is transient; BrowserState remains the persisted
/// URL/title descriptor used to rehydrate.
@MainActor
final class BrowserSnapshotTileNSView: TileNSView {
    init(tile: Tile, snapshotImage: NSImage, urlString: String) {
        super.init(tile: tile)

        let body = NSView()
        body.wantsLayer = true
        body.layer?.backgroundColor = NSColor(white: 0.90, alpha: 1.0).cgColor

        let imageView = NSImageView(image: snapshotImage)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let caption = NSTextField(labelWithString: "Snapshot · \(urlString)")
        caption.font = .systemFont(ofSize: 12, weight: .regular)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingMiddle
        caption.translatesAutoresizingMaskIntoConstraints = false

        body.addSubview(imageView)
        body.addSubview(caption)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 12),
            imageView.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -12),
            imageView.topAnchor.constraint(equalTo: body.topAnchor, constant: 12),
            imageView.bottomAnchor.constraint(equalTo: caption.topAnchor, constant: -8),
            caption.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 12),
            caption.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -12),
            caption.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -10)
        ])

        setContentView(body)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
