import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// DESIGN-ROUND harness (v2): renders the ⌘K "Open file" step, offscreen, light and
/// dark. The surface, section heading, row metrics, agent identity and file ranking
/// are the production ones (`CommandCenterSurfaceView`, `CommandCenterSectionCell`,
/// `AgentIdentityChipView`, `AgentFileIndex`); only the rows' agent/recent data is
/// fixture. Run: `Array --file-open-design-stills <dir>`.
@MainActor
enum FileOpenDesignStills {
    struct AgentFixture {
        var name: String
        var model: String
        var color: String?
        var id = UUID()
    }

    struct Row {
        var path: String
        var agent: AgentFixture?
        var age: String?
        var matched: [Int] = []
        var name: String { (path as NSString).lastPathComponent }
        var dir: String { (path as NSString).deletingLastPathComponent }
    }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { true }
    }

    private static let falcon = AgentFixture(name: "Falcon", model: "anthropic/claude-opus-5-5", color: "orange")
    private static let wren = AgentFixture(name: "Wren", model: "openai-codex/gpt-5.5", color: "blue")
    private static let heron = AgentFixture(name: "Heron", model: "anthropic/claude-sonnet-5-5", color: "green")
    private static let otter = AgentFixture(name: "Otter", model: "openai-codex/gpt-5.5", color: "purple")

    static func run(outDir: String) throws {
        let out = URL(fileURLWithPath: outDir, isDirectory: true)
        let compare = out.appendingPathComponent("compare", isDirectory: true)
        try FileManager.default.createDirectory(at: compare, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let palmod = search(root: root, query: "palmod")
        let agcomp = search(root: root, query: "agcomp")
        func adopt(enabled: Bool, style: AgentCharacterConfig.BubbleStyle) {
            let defaults = UserDefaults(suiteName: "file-open-stills-\(UUID().uuidString)")!
            defaults.set(enabled, forKey: AgentCharacterConfig.enabledKey)
            defaults.set(style.rawValue, forKey: AgentCharacterConfig.bubbleStyleKey)
            AgentCharacterController.shared.adopt(defaults: defaults)
        }
        // (file, our query, sections, the query typed into the current agent menu for the same state)
        let states: [(String, String, [(String?, [Row])], String)] = [
            ("1-empty", "", [("Made by agents", madeByAgents(count: 3)), ("Recent", recents())], ""),
            ("2-agents", "", [("Made by agents", madeByAgents(count: 5)), ("Recent", Array(recents().prefix(2)))], ""),
            ("3-fuzzy-palmod", "palmod", [("Files", palmod)], "son"),
            ("4-fuzzy-agcomp", "agcomp", [("Files", agcomp)], "gpt"),
        ]
        for dark in [false, true] {
            let tag = dark ? "dark" : "light"
            adopt(enabled: true, style: .orb)
            for (name, query, sections, referenceQuery) in states {
                let ours = try snapshot(card(query: query, sections: sections), dark: dark)
                try write(ours, to: out.appendingPathComponent("\(name)-\(tag).png"))
                let reference = try snapshot(referenceCard(query: referenceQuery), dark: dark)
                try write(compose(reference, "Current ⌘K agent menu", ours, "Open file"),
                          to: compare.appendingPathComponent("\(name)-\(tag).png"))
                if !query.isEmpty {
                    let at = try snapshot(atMenuCard(rows: sections.first?.1 ?? []), dark: dark)
                    try write(compose(at, "Composer @ menu", ours, "Open file"),
                              to: compare.appendingPathComponent("\(name)-vs-at-menu-\(tag).png"))
                }
            }
            // The agent identity follows Settings > Agent Icons, because it reuses the tile's plate.
            for (label, enabled, style) in [("squircle", true, AgentCharacterConfig.BubbleStyle.squircle),
                                            ("inline", true, .inline), ("minimal", true, .minimalSquircle),
                                            ("icons-off", false, .orb)] {
                adopt(enabled: enabled, style: style)
                try write(try snapshot(card(query: "", sections: [("Made by agents", madeByAgents(count: 4))]), dark: dark),
                          to: out.appendingPathComponent("5-style-\(label)-\(tag).png"))
            }
        }
        print("FileOpenDesignStills wrote to \(out.path)")
    }

    // MARK: data

    private static func search(root: URL, query: String) -> [Row] {
        final class Box: @unchecked Sendable { var rows: [Row] = [] }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let context = AgentCompletionContext(
            agentID: AgentID(rawValue: UUID()), backend: .claudeCode, checkoutRoot: root,
            gitRoot: root, arrayProjectRoot: root, trustState: .trusted)
        Task.detached {
            let index = AgentFileIndex()
            let found = await index.suggestions(for: AgentCompletionQuery(
                trigger: "@", text: query, replacementRange: NSRange(location: 0, length: 0), context: context))
            box.rows = found.filter { !$0.title.hasSuffix("/") }.prefix(8).map {
                Row(path: $0.detail ?? $0.title, matched: $0.matchedPathIndices)
            }
            semaphore.signal()
        }
        semaphore.wait()
        var rows = box.rows
        // Stand-in: a file an agent made, matching the query, shows its agent.
        if rows.count > 3 { rows[3].agent = wren; rows[3].age = "4m" }
        return rows
    }

    private static func madeByAgents(count: Int) -> [Row] {
        let all: [Row] = [
            Row(path: "qa-runs/file-ux/redesign-sheet-3.png", agent: falcon, age: "2m"),
            Row(path: "outputs/q3-report.html", agent: wren, age: "9m"),
            Row(path: "outputs/q3-export.xlsx", agent: wren, age: "11m"),
            Row(path: "qa-runs/file-ux/options-loop.mp4", agent: falcon, age: "26m"),
            Row(path: "docs/handoff-notes.md", agent: heron, age: "41m"),
            Row(path: "outputs/invoice-march.pdf", agent: otter, age: "1h"),
            Row(path: "qa-runs/sidebar/after-dark.png", agent: heron, age: "2h"),
            Row(path: "outputs/release-assets.zip", agent: otter, age: "3h"),
        ]
        return Array(all.prefix(count))
    }

    private static func recents() -> [Row] {
        [
            Row(path: "Sources/ContinuumRevived/App/LaunchProfilePalette.swift", age: "1h"),
            Row(path: "CLAUDE.md", age: "3h"),
            Row(path: "docs/README.md", age: "yesterday"),
        ]
    }

    // MARK: card

    nonisolated(unsafe) private static var retained: [AnyObject] = []
    private static let rowHeight: CGFloat = CommandCenterItemCell.rowHeight
    private static let cardWidth: CGFloat = 660
    private static let footerText = "↑↓ Select · Return Open next to agent · ⌘Return Reveal in Finder · ⌥Return Copy file · Esc Back"

    private static func card(query: String, sections: [(String?, [Row])]) -> NSView {
        var entries: [Any] = []
        for (title, rows) in sections where !rows.isEmpty {
            if let title { entries.append(title) }
            entries.append(contentsOf: rows)
        }
        let body = entries.reduce(CGFloat.zero) { $0 + ($1 is String ? CommandCenterSectionCell.height : rowHeight) + 2 }
        let height = min(520, 92 + body)
        let card = CommandCenterSurfaceView(frame: NSRect(x: 0, y: 0, width: cardWidth, height: height))

        // The same search field the palette builds.
        let search = NSSearchField()
        search.placeholderString = "Open a file…"
        search.stringValue = query
        search.focusRingType = .none
        search.isBezeled = false
        search.drawsBackground = false
        search.font = .systemFont(ofSize: 16, weight: .medium)
        search.frame = NSRect(x: 18, y: height - 14 - 28, width: cardWidth - 36, height: 28)
        card.addSubview(search)

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        column.width = cardWidth - 16
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        let source = Source(entries: entries, query: query, rowHeight: rowHeight)
        table.dataSource = source
        table.delegate = source
        retained.append(source)
        objc_setAssociatedObject(card, "table", table, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(card, "select", entries.firstIndex(where: { !($0 is String) }) ?? 0, .OBJC_ASSOCIATION_RETAIN)
        // Palette layout: scroll top = search bottom + 10, scroll bottom = footer top + 8.
        let scroll = NSScrollView(frame: NSRect(x: 8, y: 34, width: cardWidth - 16, height: height - 14 - 28 - 10 - 34))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        table.frame = NSRect(x: 0, y: 0, width: cardWidth - 16, height: body)
        scroll.documentView = table
        card.addSubview(scroll)

        let footer = NSTextField(labelWithString: footerText)
        footer.font = .systemFont(ofSize: 10.5, weight: .medium)
        footer.textColor = .secondaryLabelColor
        footer.alignment = .center
        footer.frame = NSRect(x: 14, y: 10, width: cardWidth - 28, height: 16)
        card.addSubview(footer)
        return card
    }

    /// The current ⌘K agent → model step, built by the real palette.
    private static func referenceCard(query: String) -> NSView {
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let view = LaunchProfilePalette.designReferenceModelStep(host: host, query: query) ?? NSView()
        view.removeFromSuperview()
        objc_setAssociatedObject(view, "host", host, .OBJC_ASSOCIATION_RETAIN)
        view.frame.size.width = cardWidth
        return view
    }

    /// The composer "@" file menu: the shared choice list in its completions presentation.
    private static func atMenuCard(rows: [Row]) -> NSView {
        let items = rows.prefix(6).map { row -> ChoiceItem in
            let parent = (row.path as NSString).deletingLastPathComponent
            return ChoiceItem(id: row.path, title: row.name, detail: parent.isEmpty ? "./" : parent + "/",
                              icon: .system(FileKindIcon.symbol(forPath: row.path)))
        }
        let list = ChoiceListView(items: Array(items), selectedID: items.first?.id, presentation: .completions)
        let rowsHeight = CGFloat(items.count) * ChoiceListView.rowHeight
        list.frame = NSRect(x: 0, y: 0, width: 520, height: rowsHeight + ChoiceListView.verticalPadding * 2)
        return list
    }

    // MARK: snapshot

    private static func snapshot(_ card: NSView, dark: Bool) throws -> NSBitmapImageRep {
        let pad: CGFloat = 32
        let size = NSSize(width: card.frame.width + pad * 2, height: card.frame.height + pad * 2)
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = SurfaceToken.canvas.color.cgColor(for: dark ? .dark : .light)
        card.frame.origin = NSPoint(x: pad, y: pad)
        content.addSubview(card)
        let window = KeyWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = content
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        // The reference card is the real palette's table; ours is built here. Both settle the same way.
        let tables = [objc_getAssociatedObject(card, "table") as? NSTableView,
                      card.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTableView]
        for case let table? in tables {
            window.makeFirstResponder(table)
            table.reloadData()
            let select = (objc_getAssociatedObject(card, "select") as? Int)
                ?? (0..<table.numberOfRows).first(where: { table.delegate?.tableView?(table, shouldSelectRow: $0) ?? true }) ?? 0
            table.selectRowIndexes(IndexSet(integer: select), byExtendingSelection: false)
            table.enumerateAvailableRowViews { rowView, _ in rowView.isEmphasized = true }
        }
        content.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        content.displayIfNeeded()
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw NSError(domain: "stills", code: 1) }
        rep.size = size
        content.cacheDisplay(in: content.bounds, to: rep)
        return rep
    }

    private static func write(_ rep: NSBitmapImageRep, to url: URL) throws {
        guard let png = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "stills", code: 2) }
        try png.write(to: url)
    }

    /// Two stills side by side under small captions, for the fidelity check.
    private static func compose(_ left: NSBitmapImageRep, _ leftTitle: String, _ right: NSBitmapImageRep, _ rightTitle: String) -> NSBitmapImageRep {
        let gap: CGFloat = 16, caption: CGFloat = 26
        let size = NSSize(width: left.size.width + gap + right.size.width, height: max(left.size.height, right.size.height) + caption)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.black.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let top = size.height - caption
        left.draw(in: NSRect(x: 0, y: top - left.size.height, width: left.size.width, height: left.size.height))
        right.draw(in: NSRect(x: left.size.width + gap, y: top - right.size.height, width: right.size.width, height: right.size.height))
        (leftTitle as NSString).draw(at: NSPoint(x: 10, y: top + 5), withAttributes: attributes)
        (rightTitle as NSString).draw(at: NSPoint(x: left.size.width + gap + 10, y: top + 5), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    // MARK: table

    private final class Source: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let entries: [Any]; let query: String; let rowHeight: CGFloat
        init(entries: [Any], query: String, rowHeight: CGFloat) { self.entries = entries; self.query = query; self.rowHeight = rowHeight }
        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { false }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !(entries[row] is String) }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            entries[row] is String ? CommandCenterSectionCell.height : rowHeight
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            switch entries[row] {
            case let title as String: return CommandCenterSectionCell(title: title)
            case let file as Row:
                return CommandCenterItemCell(file: PaletteFileRow(
                    path: file.path, matched: file.matched,
                    agent: file.agent.map { .init(agentID: $0.id, name: $0.name, model: $0.model, identityColor: $0.color, characterName: nil) },
                    age: file.age))
            default: return nil
            }
        }
    }
}
