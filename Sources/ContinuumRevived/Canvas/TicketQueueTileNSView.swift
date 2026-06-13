import AppKit
import ContinuumRevivedCore

@MainActor
final class TicketQueueTileNSView: TileNSView {
    private(set) var renderedRowIdentifiers: [String]
    private(set) var emptyStateMessage: String?

    init(tile: Tile, rows: [LinearTicketQueueRow] = [], emptyStateMessage: String? = "No Linear API key configured") {
        self.renderedRowIdentifiers = rows.map(\.identifier)
        self.emptyStateMessage = rows.isEmpty ? emptyStateMessage : nil
        super.init(tile: tile)

        let body = NSStackView()
        body.orientation = .vertical
        body.spacing = 8
        body.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        body.wantsLayer = true
        body.layer?.backgroundColor = NSColor(red: 0.11, green: 0.15, blue: 0.22, alpha: 1).cgColor

        let header = NSTextField(labelWithString: tile.title)
        header.font = NSFont.boldSystemFont(ofSize: 14)
        header.textColor = .white
        body.addArrangedSubview(header)

        if rows.isEmpty {
            let empty = NSTextField(labelWithString: emptyStateMessage ?? "No tickets")
            empty.font = NSFont.systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            body.addArrangedSubview(empty)
        } else {
            for row in rows {
                let label = NSTextField(labelWithString: "\(row.identifier) · \(row.priority.displayName) · \(row.state) · \(row.title)")
                label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                label.textColor = .lightGray
                label.lineBreakMode = .byTruncatingTail
                body.addArrangedSubview(label)
            }
        }

        setContentView(body)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
