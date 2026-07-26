import AppKit
import ContinuumRevivedCore

// Ticket: docs/38-tickets/90-agent-ux/P2D.6-fan-out.md — the fan-out half.
//
// This tile already dispatched ONE row to ONE terminal. Fan-out is the same
// gesture at N: the rows gain a selection, and the handler is handed every
// selected row at once so the supervisor can decide the batch (cap, deferral,
// one worktree each) rather than the view doing it a row at a time.
//
// Both halves are OPT-IN by handler, exactly as `dispatchHandler` already was: a
// tile built without `fanOutHandler` renders precisely what it rendered before,
// which is what the existing render checks assert.

@MainActor
final class TicketQueueTileNSView: TileNSView {
    private(set) var renderedRowIdentifiers: [String]
    private(set) var emptyStateMessage: String?
    private let dispatchHandler: ((LinearTicketQueueRow) -> Void)?
    private let fanOutHandler: (([LinearTicketQueueRow]) -> Void)?
    private var rowsByIdentifier: [String: LinearTicketQueueRow] = [:]
    private var selectionBoxes: [String: NSButton] = [:]
    /// Items an agent has finished, in the order they were checked off.
    private(set) var doneRowIdentifiers: [String] = []
    /// What the last fan-out reported — the cap and what it deferred. Rendered, so
    /// a truncated batch is never silent.
    private(set) var fanOutStatusMessage: String?
    private var statusLabel: NSTextField?
    private var doneMarkers: [String: NSTextField] = [:]

    /// The selected rows, in the order they are rendered.
    var selectedRowIdentifiers: [String] {
        renderedRowIdentifiers.filter { selectionBoxes[$0]?.state == .on }
    }

    init(tile: Tile, rows: [LinearTicketQueueRow] = [], emptyStateMessage: String? = "No Linear API key configured", dispatchHandler: ((LinearTicketQueueRow) -> Void)? = nil, fanOutHandler: (([LinearTicketQueueRow]) -> Void)? = nil) {
        self.renderedRowIdentifiers = rows.map(\.identifier)
        self.emptyStateMessage = rows.isEmpty ? emptyStateMessage : nil
        self.dispatchHandler = dispatchHandler
        self.fanOutHandler = fanOutHandler
        self.rowsByIdentifier = Dictionary(uniqueKeysWithValues: rows.map { ($0.identifier, $0) })
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
                let title = "\(row.identifier) · \(row.priority.displayName) · \(row.state) · \(row.title)"
                let line = NSStackView()
                line.orientation = .horizontal
                line.spacing = 6
                line.alignment = .firstBaseline
                if fanOutHandler != nil {
                    let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
                    box.identifier = NSUserInterfaceItemIdentifier("fanout.select.\(row.identifier)")
                    box.setAccessibilityLabel("Select \(row.identifier)")
                    selectionBoxes[row.identifier] = box
                    line.addArrangedSubview(box)

                    // The check-off mark. Present from the start and hidden, rather
                    // than inserted on completion: a row that grows a view mid-batch
                    // re-lays out the whole stack under the user's pointer.
                    let marker = NSTextField(labelWithString: "✓")
                    marker.font = NSFont.boldSystemFont(ofSize: 12)
                    marker.textColor = .systemGreen
                    marker.isHidden = true
                    marker.identifier = NSUserInterfaceItemIdentifier("fanout.done.\(row.identifier)")
                    doneMarkers[row.identifier] = marker
                    line.addArrangedSubview(marker)
                }
                let control: NSView
                if dispatchHandler != nil {
                    let button = NSButton(title: title, target: self, action: #selector(dispatchTicket(_:)))
                    button.identifier = NSUserInterfaceItemIdentifier(row.identifier)
                    button.bezelStyle = .inline
                    button.isBordered = false
                    button.alignment = .left
                    button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                    button.contentTintColor = .lightGray
                    button.lineBreakMode = .byTruncatingTail
                    control = button
                } else {
                    let label = NSTextField(labelWithString: title)
                    label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                    label.textColor = .lightGray
                    label.lineBreakMode = .byTruncatingTail
                    control = label
                }
                if fanOutHandler == nil {
                    body.addArrangedSubview(control)
                } else {
                    line.addArrangedSubview(control)
                    body.addArrangedSubview(line)
                }
            }
            if fanOutHandler != nil {
                let fanOut = NSButton(title: "Fan Out Selected", target: self, action: #selector(fanOutSelectedRows(_:)))
                fanOut.identifier = NSUserInterfaceItemIdentifier("fanout.run")
                fanOut.bezelStyle = .rounded
                body.addArrangedSubview(fanOut)

                let status = NSTextField(labelWithString: "")
                status.font = NSFont.systemFont(ofSize: 11)
                // `.lightGray` like the rows above it, NOT `.secondaryLabelColor`
                // and not `TextToken.textSecondary`: this tile paints its own dark
                // fill in both appearances, so an appearance-resolved text colour
                // is dark-on-dark in Aqua — the exact pairing P1.7's gate exists to
                // stop. Retiring the literal fill is this tile's own token-adoption
                // ticket, not this one's.
                status.textColor = .lightGray
                status.lineBreakMode = .byTruncatingTail
                status.identifier = NSUserInterfaceItemIdentifier("fanout.status")
                status.isHidden = true
                statusLabel = status
                body.addArrangedSubview(status)
            }
        }

        setContentView(body)
    }

    @objc private func dispatchTicket(_ sender: NSButton) {
        guard let rawIdentifier = sender.identifier?.rawValue,
              let row = rowsByIdentifier[rawIdentifier] else { return }
        dispatchHandler?(row)
    }

    @objc private func fanOutSelectedRows(_ sender: NSButton) {
        fanOutSelection()
    }

    /// Hands every selected row to the fan-out handler, in rendered order. Also the
    /// entry point for the `agent.fanOut` command, which is why it is a method and
    /// not the button's body.
    func fanOutSelection() {
        guard let fanOutHandler else { return }
        let selected = selectedRowIdentifiers.compactMap { rowsByIdentifier[$0] }
        guard !selected.isEmpty else {
            report("Select at least one ticket to fan out")
            return
        }
        fanOutHandler(selected)
    }

    /// Sets a row's selection. Used by the checks and by anything driving the tile
    /// programmatically; a click reaches the same `NSButton` state.
    func setSelected(_ selected: Bool, forRow identifier: String) {
        selectionBoxes[identifier]?.state = selected ? .on : .off
    }

    /// THE CHECK-OFF. Called when the agent fanned out for this row finishes: the
    /// row shows its mark and drops out of the selection, so a second fan-out over
    /// the same tile cannot re-launch work that is already done. Unknown or
    /// already-marked identifiers are no-ops — the completion may arrive after the
    /// tile has re-rendered on newer rows, and that must not crash or double-count.
    func markItemDone(_ identifier: String) {
        guard rowsByIdentifier[identifier] != nil, !doneRowIdentifiers.contains(identifier) else { return }
        doneRowIdentifiers.append(identifier)
        doneMarkers[identifier]?.isHidden = false
        let box = selectionBoxes[identifier]
        box?.state = .off
        box?.isEnabled = false
    }

    /// Shows what a fan-out did — including what it DEFERRED, which is the packet's
    /// no-silent-truncation rule: the count the supervisor reported is rendered, not
    /// logged.
    func report(_ message: String) {
        fanOutStatusMessage = message
        statusLabel?.stringValue = message
        statusLabel?.isHidden = message.isEmpty
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
