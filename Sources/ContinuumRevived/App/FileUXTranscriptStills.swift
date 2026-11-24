#if ARRAY_CHECKS
import AppKit
import PDFKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// Review stills for the Changes card's file previews: the real transcript list
/// and the real card, with a store of real files, light and dark, at rest and
/// with one thumbnail hovered. Writes PNGs to the directory it is given.
@MainActor
enum FileUXTranscriptStills {
    struct Turn { let prompt: String; let reply: String; let files: [(URL, AgentDiffFileAction)] }

    static func render(to dir: URL) async throws {
        let fixtures = dir.appendingPathComponent("fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let png = URL(fileURLWithPath: "\(home)/array-scratch/plan-drawer-redesign/final/checklist-attention-open-dark.png")
        let report = fixtures.appendingPathComponent("opening-files-report.md")
        try Data("""
        # How files get opened today, and what to design for next

        Research date: 2026-11-23. Read-only.

        ## Scope and caveats

        Sixty-one requests were read in sequence.
        """.utf8).write(to: report)
        let pdf = fixtures.appendingPathComponent("findings.pdf")
        try makePDF(at: pdf)
        let html = fixtures.appendingPathComponent("launch-page.html")
        try Data(htmlSource.utf8).write(to: html)
        let code = fixtures.appendingPathComponent("AtomicWriter.swift")
        try Data("""
        import Foundation

        public enum AtomicWriterError: Error {
            case unwritable
        }

        public struct AtomicWriter {
            public func write(_ data: Data, to url: URL) throws {}
        }
        """.utf8).write(to: code)
        let svg = fixtures.appendingPathComponent("badge.svg")
        try Data("<svg xmlns='http://www.w3.org/2000/svg' width='160' height='100'><rect width='160' height='100' fill='#3b5bdb'/><circle cx='80' cy='50' r='30' fill='white'/></svg>".utf8).write(to: svg)
        let turns = [
            Turn(prompt: "Write up what you found about how I open files.", reply: "I wrote the findings up.", files: [(report, .add)]),
            Turn(prompt: "Render the drawer, write the report and draw the badge.", reply: "Here are the drawer, the report and the badge.",
                 files: [(png, .write), (report, .write), (svg, .write)]),
            Turn(prompt: "Add the atomic writer.", reply: "The atomic writer is in.", files: [(code, .add)]),
        ]
        for dark in [true, false] {
            for hover in [false, true] {
                let theme: TokenTheme = dark ? .dark : .light
                let size = NSSize(width: 640, height: 760)
                let host = NSView(frame: NSRect(origin: .zero, size: size))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.wantsLayer = true
                host.layer?.backgroundColor = (dark ? NSColor(white: 0.09, alpha: 1) : NSColor(white: 0.97, alpha: 1)).cgColor
                let ctx = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: theme)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                window.orderFrontOffscreenForChecks()
                // The default renderer: the drawn transcript.
                let canvas = try await makeCanvas(ctx, turns: turns, size: NSSize(width: size.width - 32, height: size.height - 32))
                canvas.frame = NSRect(x: 16, y: 16, width: size.width - 32, height: size.height - 32)
                host.addSubview(canvas)
                for _ in 0..<12 {
                    canvas.flushPendingVisualUpdate(); host.layoutSubtreeIfNeeded()
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
                if hover, canvas.qaFileThumbs.count >= 3 {
                    let center = canvas.qaFileThumbs[2].center
                    let event = NSEvent.mouseEvent(with: .mouseMoved, location: canvas.convert(center, to: nil), modifierFlags: [],
                                                   timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                   eventNumber: 0, clickCount: 0, pressure: 0)!
                    canvas.mouseMoved(with: event)
                    try await Task.sleep(nanoseconds: 400_000_000)
                }
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?
                    .write(to: dir.appendingPathComponent("strip-\(dark ? "dark" : "light")\(hover ? "-hover" : "").png"))
            }
        }
    }

    static func makeCanvas(_ ctx: AgentRenderContext, turns: [Turn], size: NSSize) async throws -> AgentTranscriptCanvasView {
        let store = AgentToolDetailStore()
        let canvas = AgentTranscriptCanvasView(toolDetailStore: store)
        canvas.frame = NSRect(origin: .zero, size: size)
        try canvas.updateRenderContext(ctx)
        var entries: [AgentEntry] = []
        for (index, turn) in turns.enumerated() {
            let thread = "stills-thread-\(index)"
            var projection = AgentTranscriptProjection(threadId: thread)
            try projection.appendUserPrompt(id: AgentNodeID(rawValue: "stills-user-\(index)")!, text: turn.prompt)
            var translator = ClaudeEventTranslator(runToken: "stills\(index)")
            let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(turn.reply)"}},"parent_tool_use_id":null}"#
            for event in translator.translate(stream: [line]) { projection.ingest(event.withThreadId(thread)) }
            entries += projection.document.entries
            let scope = AgentToolDetailScope(agentID: "stills-agent", threadID: thread, turnID: "turn-\(index)", provider: "runtime")!
            // As the live app records it: one Write operation, and one entry, per file.
            for (fileIndex, file) in turn.files.enumerated() {
                let itemID = AgentToolDetailID(stringLiteral: "write-\(index)-\(fileIndex)")
                let key = AgentToolDetailKey(scope: scope, providerItemID: itemID)
                _ = await store.recordStart(AgentToolDetailStart(
                    identity: key, toolName: "write", affectedFiles: [file.0],
                    fileChanges: [.init(action: file.1 == .add ? .add : .write, path: file.0.lastPathComponent, addedLines: 24, removedLines: nil)]))
                _ = await store.recordEnd(AgentToolDetailEnd(identity: key, status: .completed))
                let block = AgentBlock(id: AgentNodeID(rawValue: "stills-diff-\(index)-\(fileIndex)")!, revision: 1, kind: .diff,
                                       payload: .diff(AgentDiffPayload(text: "", summary: "Write")))
                let entry = AgentEntry(id: AgentNodeID(rawValue: "stills-diff-entry-\(index)-\(fileIndex)")!, revision: 1, role: .assistant,
                                       provenance: .providerItem(provider: "runtime", itemID: itemID.rawValue), blocks: [block])
                _ = canvas.bindToolDetailIdentity(key, to: entry.id)
                entries.append(entry)
            }
        }
        let document = AgentDocument(version: 1, entries: entries)
        try canvas.enqueue(document: document, patch: AgentDocumentPatch(
            fromVersion: 0, toVersion: 1, inserted: document.entries.flatMap(\.blocks).map(\.id)), final: true)
        await canvas.qaAdoptStoreRecords()
        await canvas.qaWaitForToolDetailRefresh()
        return canvas
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView, where match: (T) -> Bool) -> T? {
        if let v = view as? T, match(v) { return v }
        for sub in view.subviews { if let hit = find(type, in: sub, where: match) { return hit } }
        return nil
    }

    static func makePDF(at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw NSError(domain: "pdf", code: 1) }
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAttributedString(string: "How files get opened", attributes: [.font: NSFont.systemFont(ofSize: 28, weight: .bold)])
            .draw(at: NSPoint(x: 54, y: 700))
        ("Sixty-one requests were read in sequence. Finder is only irreplaceable when a file is handed to a person.\n\nThe rest are about looking: comparison sheets, stills and films." as NSString)
            .draw(in: NSRect(x: 54, y: 560, width: 504, height: 120), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage(); ctx.closePDF()
    }

    static let htmlSource = """
    <!doctype html><html><head><meta charset="utf-8"><title>Array</title><style>
    body{margin:0;font-family:-apple-system,Helvetica;background:#0f1115;color:#f2f2f2}
    .hero{padding:48px 40px;background:linear-gradient(135deg,#3b2cff,#13b5c9)}
    h1{margin:0 0 8px;font-size:44px}p{margin:0;font-size:18px;opacity:.9}
    .row{display:flex;gap:16px;padding:32px 40px}.card{flex:1;height:90px;border-radius:12px;background:#1d2027}
    </style></head><body><div class="hero"><h1>Array</h1><p>A spatial workspace for coding agents.</p></div>
    <div class="row"><div class="card"></div><div class="card"></div><div class="card"></div></div></body></html>
    """

    static func makeList(_ ctx: AgentRenderContext, turns: [Turn], size: NSSize) async throws -> AgentTranscriptListView {
        let store = AgentToolDetailStore()
        let list = AgentTranscriptListView(renderContext: ctx, toolDetailStore: store)
        list.frame = NSRect(origin: .zero, size: size)
        var entries: [AgentEntry] = []
        for (index, turn) in turns.enumerated() {
            let thread = "stills-thread-\(index)"
            var projection = AgentTranscriptProjection(threadId: thread)
            try projection.appendUserPrompt(id: AgentNodeID(rawValue: "stills-user-\(index)")!, text: turn.prompt)
            var translator = ClaudeEventTranslator(runToken: "stills\(index)")
            let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(turn.reply)"}},"parent_tool_use_id":null}"#
            for event in translator.translate(stream: [line]) { projection.ingest(event.withThreadId(thread)) }
            entries += projection.document.entries

            let scope = AgentToolDetailScope(agentID: "stills-agent", threadID: thread, turnID: "turn-\(index)", provider: "runtime")!
            let itemID = AgentToolDetailID(stringLiteral: "write-\(index)")
            let key = AgentToolDetailKey(scope: scope, providerItemID: itemID)
            _ = await store.recordStart(AgentToolDetailStart(
                identity: key, toolName: "write", affectedFiles: turn.files.map(\.0),
                fileChanges: turn.files.map { .init(action: $0.1 == .add ? .add : .write, path: $0.0.lastPathComponent, addedLines: 24, removedLines: 0) }))
            _ = await store.recordEnd(AgentToolDetailEnd(identity: key, status: .completed))
            let block = AgentBlock(id: AgentNodeID(rawValue: "stills-diff-\(index)")!, revision: 1, kind: .diff,
                                   payload: .diff(AgentDiffPayload(text: "", summary: "")))
            let entry = AgentEntry(id: AgentNodeID(rawValue: "stills-diff-entry-\(index)")!, revision: 1, role: .assistant,
                                   provenance: .providerItem(provider: "runtime", itemID: itemID.rawValue), blocks: [block])
            list.bindToolDetailIdentity(key, to: entry.id)
            entries.append(entry)
        }
        let document = AgentDocument(version: 1, entries: entries)
        try list.apply(document: document, patch: AgentDocumentPatch(
            fromVersion: 0, toVersion: 1, inserted: document.entries.flatMap(\.blocks).map(\.id)))
        await list.qaWaitForToolDetailRefresh()
        return list
    }
}
#endif
