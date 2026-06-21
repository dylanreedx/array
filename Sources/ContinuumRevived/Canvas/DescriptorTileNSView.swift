import AppKit
import ContinuumRevivedCore
import Foundation

/// Tile view used when no live runtime is attached: a colored placeholder
/// labeled with the tile kind. Useful for descriptor-only tiles in Phase 3.
@MainActor
final class DescriptorTileNSView: TileNSView {

    override init(tile: Tile) {
        super.init(tile: tile)
        let body = NSView(frame: .zero)
        body.wantsLayer = true
        body.layer?.backgroundColor = Self.background(for: tile.kind).cgColor

        let label = NSTextField(labelWithString: tile.title)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = NSColor.lightGray
        label.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: body.centerYAnchor)
        ])

        setContentView(body)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static func background(for kind: TileKind) -> NSColor {
        switch kind {
        case .terminal: return NSColor(red: 0.10, green: 0.13, blue: 0.18, alpha: 1)
        case .browser:  return NSColor(red: 0.13, green: 0.17, blue: 0.20, alpha: 1)
        case .browserInspector: return NSColor(red: 0.10, green: 0.16, blue: 0.19, alpha: 1)
        case .note:     return NSColor(red: 0.18, green: 0.16, blue: 0.10, alpha: 1)
        case .file:     return NSColor(red: 0.12, green: 0.18, blue: 0.13, alpha: 1)
        case .fileTree: return NSColor(red: 0.15, green: 0.13, blue: 0.20, alpha: 1)
        case .ticketQueue: return NSColor(red: 0.11, green: 0.15, blue: 0.22, alpha: 1)
        case .conductorQueue: return NSColor(red: 0.10, green: 0.14, blue: 0.18, alpha: 1)
        case .diffReview: return NSColor(red: 0.16, green: 0.12, blue: 0.18, alpha: 1)
        case .runArtifacts: return NSColor(red: 0.12, green: 0.15, blue: 0.18, alpha: 1)
        }
    }
}
