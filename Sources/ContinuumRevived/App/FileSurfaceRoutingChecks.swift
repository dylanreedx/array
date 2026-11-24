import AppKit
import AVKit
import PDFKit
import WebKit

/// Which surface each kind of file opens in, driven through the production
/// workspace API (`artifact.open`) on the production boot mount: html and svg in
/// a browser tile with read access to their folder, pdf with PDFKit, video with
/// AVKit, and ordinary text still in a file tile.
@MainActor
enum FileSurfaceRoutingChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }
    private static func eventually(_ message: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !predicate() {
            guard Date() < deadline else { throw Failure(description: message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func run() async throws {
        _ = NSApplication.shared
        let f = try WorkspaceAPIChecks.makeFixture()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 2000, height: 1200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = f.canvas
        defer {
            for tile in f.canvas.allWorkspaceTiles() { f.canvas.tileView(for: tile.id)?.prepareForRemovalFromScene() }
            window.contentView = nil
            window.close()
            f.tearDown()
        }
        try expect(f.delegate.qaAgentSupervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true), "workspace tools did not enable")

        // Fixtures: a page whose own script must load for the title to change.
        try Data("<html><head><script src=\"app.js\"></script></head><body>page</body></html>".utf8)
            .write(to: f.pbRoot.appendingPathComponent("page.html"))
        try Data("document.title = 'sibling-loaded';".utf8).write(to: f.pbRoot.appendingPathComponent("app.js"))
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\"><rect width=\"20\" height=\"20\"/></svg>".utf8)
            .write(to: f.pbRoot.appendingPathComponent("logo.svg"))
        try Data("plain\n".utf8).write(to: f.pbRoot.appendingPathComponent("plain.txt"))
        try pdfData().write(to: f.pbRoot.appendingPathComponent("doc.pdf"))
        try Data(count: 2_048).write(to: f.pbRoot.appendingPathComponent("clip.mp4"))

        func open(_ name: String) throws -> UUID {
            let reply = f.api.dispatch(agentId: f.agentId, requestId: "route-" + name, op: "artifact.open", payload: [
                "relativePath": name, "presentation": ["camera": "preserve"]
            ])
            guard case let .result(result) = reply, let raw = result["tileId"]?.string, let id = UUID(uuidString: raw) else {
                throw Failure(description: "\(name): artifact.open failed: \(reply)")
            }
            try expect(f.canvas.zoneId(containing: id) == f.zoneB, "\(name): not in the agent's zone")
            return id
        }

        // html: a browser tile on the file URL, and the page's sibling script loads.
        let page = try open("page.html")
        guard let pageTile = f.canvas.tileView(for: page) as? BrowserTileNSView,
              let runtime = pageTile.runtime as? WKWebViewBrowserRuntime else {
            throw Failure(description: "page.html did not open in a browser tile")
        }
        let pageURL = URL(fileURLWithPath: f.pbRoot.appendingPathComponent("page.html").path).resolvingSymlinksInPath()
        try expect(runtime.webView.url == nil || runtime.webView.url?.isFileURL == true, "browser tile is not on a file URL")
        try await eventually("page.html did not load its sibling script (no read access to its folder): title=\(runtime.webView.title ?? "nil")") {
            runtime.webView.title == "sibling-loaded"
        }
        try expect(runtime.webView.url?.resolvingSymlinksInPath() == pageURL, "browser tile is on \(String(describing: runtime.webView.url))")
        // Reopening the same page reuses the tile.
        let reopened = try open("page.html")
        try expect(reopened == page, "reopening page.html made a second tile")

        // svg: browser tile too.
        let logo = try open("logo.svg")
        try expect(f.canvas.tileView(for: logo) is BrowserTileNSView, "logo.svg did not open in a browser tile")

        // pdf: PDFKit inside a file tile.
        let pdf = try open("doc.pdf")
        guard let pdfTile = f.canvas.tileView(for: pdf) as? FileTileNSView else { throw Failure(description: "doc.pdf is not a file tile") }
        try await eventually("doc.pdf never showed a PDF renderer") { pdfTile.qaRenderer is FilePDFRenderer }
        try expect((pdfTile.qaRenderer as? FilePDFRenderer)?.qaPageCount == 2, "the pdf renderer lost its pages")

        // mp4: AVKit player on the file itself (routing witnessed; the bytes are a stub).
        let clip = try open("clip.mp4")
        guard let clipTile = f.canvas.tileView(for: clip) as? FileTileNSView else { throw Failure(description: "clip.mp4 is not a file tile") }
        try await eventually("clip.mp4 never showed a video renderer") { clipTile.qaRenderer is FileVideoRenderer }
        try expect((clipTile.qaRenderer as? FileVideoRenderer)?.qaPlayerURL?.lastPathComponent == "clip.mp4", "the video player is not on the file")

        // Control: ordinary text stays a file tile.
        let plain = try open("plain.txt")
        try expect(f.canvas.tileView(for: plain) is FileTileNSView && (f.canvas.tileView(for: plain) as? FileTileNSView)?.qaRenderer == nil,
                   "plain.txt left the text file tile")
        print("file surface routing: html and svg open in a browser tile on the file URL with its folder readable, pdf in PDFKit, mp4 in AVKit, text unchanged")
    }

    private static func pdfData() -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(x: 20, y: 20, width: 100, height: 100))
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
