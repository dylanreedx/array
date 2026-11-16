import AppKit
import ContinuumRevivedCore
import ImageIO
import UniformTypeIdentifiers

/// Actual file bodies reached through the production boot mount and workspace
/// API. No test-only scene install, parser substitution, application launch or
/// access to a user's project. All fixtures are generated under the API bench.
@MainActor
enum FileFormatsChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }
    private static func eventually(_ message: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !predicate() {
            guard Date() < deadline else { throw Failure(description: message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func run() async throws {
        _ = NSApplication.shared
        let utf8 = Data("id,value\r\n00123,9007199254740993\r\n".utf8)
        guard let utf16Text = "id\tvalue\r\n00123\t雪\r\n".data(using: .utf16LittleEndian) else {
            throw Failure(description: "UTF-16 fixture encoding failed")
        }
        var utf16 = Data([0xFF, 0xFE]); utf16.append(utf16Text)
        let formats: [(String, Data)] = [
            ("pixels.png", try png()), ("records.csv", utf8),
            ("unicode.tsv", utf16), ("workbook.xlsx", workbook())
        ]
        // A single active document per fixture makes release of its admission
        // leases observable, independently of other previews' shared cache hits.
        for (name, bytes) in formats { try await runDocument(name: name, bytes: bytes) }
    }

    private static func runDocument(name: String, bytes: Data) async throws {
        let budgetBefore = FileContentBudget.shared.retainedBytes
        let observationsBefore = FileContentObservation.shared.qaObserverCount
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
        let url = f.pbRoot.appendingPathComponent(name)
        try bytes.write(to: url)
        try expect(f.runtime.qaHasCanvas, "format fixture bypassed the production mount")
        try expect(f.delegate.qaAgentSupervisor.setWorkspaceToolsEnabled(agentID: f.agentId, true), "workspace tools policy did not enable")
        let armed = f.canvas.armedZoneId
        let viewportApplications = f.canvas.qaViewportApplyCount
        let reply = f.api.dispatch(agentId: f.agentId, requestId: "format-" + name, op: "artifact.open", payload: [
            "relativePath": name, "presentation": ["camera": "preserve"]
        ])
        guard case let .result(result) = reply,
              let rawID = result["tileId"]?.string, let tileID = UUID(uuidString: rawID) else {
            throw Failure(description: "\(name): production artifact.open failed: \(reply)")
        }
        try expect(result["projectId"]?.string == f.projectPb.uuidString, "\(name): opened the armed project instead of the agent checkout")
        try expect(f.canvas.zoneId(containing: tileID) == f.zoneB, "\(name): wrong zone")
        try expect(f.canvas.armedZoneId == armed && f.canvas.qaViewportApplyCount == viewportApplications,
                   "\(name): opening a preview changed the armed zone or camera")
        guard let initial = f.canvas.tileView(for: tileID) as? FileTileNSView else {
            throw Failure(description: "\(name): production open did not mount a file host")
        }
        try await ready(initial, name: name)
        if let world = result["actualWorldRect"]?.object,
           let x = (world["x"]?.value as? NSNumber)?.doubleValue,
           let y = (world["y"]?.value as? NSNumber)?.doubleValue {
            f.canvas.setViewport(CanvasViewport(x: x - 24, y: y - 24, zoom: 1))
            f.canvas.layoutSubtreeIfNeeded()
        }
        try await checkBody(initial, name: name)
        try capture(initial, name: name)
        let afterOpen = try Data(contentsOf: url)
        try expect(afterOpen == bytes, "\(name): opening a read-only preview wrote source bytes")
        let persisted = try f.storePb.loadCanvas()
        guard let record = persisted.tiles.first(where: { $0.id == tileID }) else {
            throw Failure(description: "\(name): production open did not persist the file tile")
        }
        try expect(record.kind == .file && record.zoneId == f.zoneB, "\(name): preview changed durable tile identity")
        let world = result["actualWorldRect"]?.object
        try expect((world?["x"]?.value as? NSNumber)?.doubleValue == record.frame.x && (world?["y"]?.value as? NSNumber)?.doubleValue == record.frame.y,
                   "\(name): API world coordinates differ from persisted frame")

        // Workspace switch must dispose its mounted body, then hydrate from the
        // same persisted .file record and reconstruct the proper native body.
        try f.runtime.switchWorkspace(to: f.workspaceWB)
        try expect(initial.qaRenderer == nil && !initial.qaRichLoading,
                   "\(name): workspace departure retained a renderer or request")
        try f.runtime.switchWorkspace(to: f.workspaceWA)
        guard let restored = f.canvas.tileView(for: tileID) as? FileTileNSView else {
            throw Failure(description: "\(name): workspace round trip lost the file tile")
        }
        try await ready(restored, name: name)
        try await checkBody(restored, name: name)
        try expect(restored.tile.metadata.documentLocation == record.metadata.documentLocation,
                   "\(name): hydration changed document ownership")
        let afterHydration = try Data(contentsOf: url)
        try expect(afterHydration == bytes, "\(name): hydration wrote source bytes")

        if name.hasSuffix(".csv") {
            // Shared observation clock sees external edits; no per-renderer
            // timer or direct call to a private load function is involved.
            let replacement = Data("id,value\r\n00999,changed externally\r\n".utf8)
            try replacement.write(to: url, options: .atomic)
            FileContentObservation.shared.poll()
            try await ready(restored, name: name)
            try await selectedValue(restored, expected: "00999")
            // Drive the same filesystem coordinator and notification the real
            // file-tree rename sends. Never present a modal or touch Trash.
            let moved = try ProjectFileOperationCoordinator(rootURL: f.pbRoot).rename(entry: url, newName: "renamed.csv")
            NotificationCenter.default.post(name: .arrayProjectFileMoved, object: nil,
                userInfo: ["source": moved.source.path, "destination": moved.destination.path, "directory": false])
            try await ready(restored, name: "renamed.csv")
            if initial !== restored {
                try expect(initial.qaRenderer == nil && !initial.qaRichLoading, "rename resurrected a retired preview host")
            }
            try expect(restored.tile.metadata.documentLocation?.path == moved.destination.path,
                       "rename did not update rich document identity")
            try await selectedValue(restored, expected: "00999")
            try FileManager.default.removeItem(at: moved.destination)
            FileContentObservation.shared.poll()
            try await eventually("deleted source did not finish its failed load", { !restored.qaRichLoading })
            try expect(restored.qaRenderer == nil && !restored.qaHasDocumentSession,
                       "deleted source left a stale renderer or created a text session")
        }
        f.canvas.removeTile(id: tileID)
        try expect(restored.qaRenderer == nil && !restored.qaRichLoading, "\(name): tile removal retained a renderer")
        do {
            try await eventually("\(name): file resources or observers were not released", {
                FileContentBudget.shared.retainedBytes == budgetBefore && FileContentObservation.shared.qaObserverCount == observationsBefore
            })
        } catch {
            let work = await FileGridWorkScheduler.shared.qaCounts
            throw Failure(description: "\(name): resources: budget \(FileContentBudget.shared.retainedBytes)/\(budgetBefore), observers \(FileContentObservation.shared.qaObserverCount)/\(observationsBefore), retiredRendererAlive=\(restored.qaRetiredRendererAlive), workers=\(work)")
        }
    }

    private static func ready(_ host: FileTileNSView, name: String) async throws {
        try await eventually("\(name): rich preview did not finish", { !host.qaRichLoading })
        try expect(host.qaRenderer != nil, "\(name): completed without a supported native body")
        try expect(!host.qaHasDocumentSession && host.loadedText == nil && !host.isDirty,
                   "\(name): read-only preview allocated an editing session or draft")
        guard let body = host.qaRenderer?.view else { return }
        try expect(body.superview != nil && body.window != nil, "\(name): renderer was constructed but never mounted")
        host.layoutSubtreeIfNeeded()
    }
    private static func checkBody(_ host: FileTileNSView, name: String) async throws {
        if name.hasSuffix(".png") {
            guard let image = host.qaRenderer as? FileImageRenderer else { throw Failure(description: "PNG did not mount ImageIO renderer") }
            try expect(image.qaViewport.document != nil, "mounted image has no decoded pixels")
        } else if name.hasSuffix(".xlsx") {
            guard let workbook = host.qaRenderer as? WorkbookGridRenderer else { throw Failure(description: "XLSX did not mount workbook renderer") }
            try expect(workbook.workbook?.visibleSheets.count == 1 && workbook.qaSelectedSheet == "0", "workbook sheet selection lost")
            try await selectedValue(host, expected: "00123")
        } else {
            try expect(host.qaRenderer is DelimitedGridRenderer, "\(name): no delimited grid")
            try await selectedValue(host, expected: "00123")
            if name.hasSuffix(".tsv"), let grid = host.qaRenderer as? DelimitedGridRenderer {
                grid.qaSelect(row: 1, column: 1)
                try await eventually("UTF-16 cell projection did not load", { !grid.qaIsLoading })
                grid.qaSelect(row: 1, column: 1)
                try expect(grid.qaSelectedValue == "雪", "UTF-16 TSV projection lost Unicode")
            }
        }
    }
    private static func selectedValue(_ host: FileTileNSView, expected: String) async throws {
        let grid = (host.qaRenderer as? DelimitedGridRenderer) ?? (host.qaRenderer as? WorkbookGridRenderer)?.qaGrid
        guard let grid else { throw Failure(description: "no grid to inspect selection") }
        grid.setVisible(true)
        grid.qaLayout(size: NSSize(width: 700, height: 420))
        try await eventually("grid projected pages did not complete", { !grid.qaIsLoading })
        grid.qaSelect(row: 1, column: 0)
        try await eventually("selected cell page did not complete", { !grid.qaIsLoading })
        grid.qaSelect(row: 1, column: 0)
        try expect(grid.qaSelectedValue == expected, "mounted grid changed exact cell text: \(String(describing: grid.qaSelectedValue))")
        try expect(grid.qaCachedPageCount <= 8 && grid.qaCachedBytes <= 4 * 1_024 * 1_024, "mounted grid exceeded page bounds")
    }

    private static func capture(_ host: FileTileNSView, name: String) throws {
        guard let body = host.qaRenderer?.view else { return }
        // Capture the complete body in a fixed QA window. The production canvas
        // clips offscreen content; caching a larger rect there can hide controls.
        guard let parent = body.superview else { throw Failure(description: "unmounted capture body") }
        let constraints = parent.constraints.filter { ($0.firstItem as? NSView) === body || ($0.secondItem as? NSView) === body }
        let originalFrame = body.frame
        let translates = body.translatesAutoresizingMaskIntoConstraints
        let originalMask = body.autoresizingMask
        NSLayoutConstraint.deactivate(constraints)
        body.removeFromSuperview()
        let preview = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        preview.isReleasedWhenClosed = false
        body.translatesAutoresizingMaskIntoConstraints = true
        let backingHost = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 460))
        backingHost.wantsLayer = true
        preview.contentView = backingHost
        body.frame = backingHost.bounds
        body.autoresizingMask = [.width, .height]
        backingHost.addSubview(body)
        defer {
            preview.contentView = nil
            preview.close()
            body.removeFromSuperview()
            body.autoresizingMask = originalMask
            body.translatesAutoresizingMaskIntoConstraints = translates
            parent.addSubview(body)
            body.frame = originalFrame
            NSLayoutConstraint.activate(constraints)
            host.layoutSubtreeIfNeeded()
        }
        let root = ProcessInfo.processInfo.environment["ARRAY_FILE_APPEARANCE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let root { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            body.appearance = NSAppearance(named: appearance)
            host.qaRenderer?.applyTheme()
            body.setFrameSize(NSSize(width: 760, height: 460))
            body.needsLayout = true
            body.layoutSubtreeIfNeeded()
            for child in body.subviews where !child.isHidden {
                try expect(body.bounds.intersects(child.frame), "visible renderer control is outside its body: \(type(of: child)) \(child.frame) in \(body.bounds)")
            }
            preview.appearance = body.appearance
            var rendered: Result<NSBitmapImageRep, Error> = .failure(Failure(description: "appearance did not render"))
            body.effectiveAppearance.performAsCurrentDrawingAppearance {
                rendered = Result { try UIProbe.bitmap(of: body, id: "file-format-" + name + "-" + suffix) }
            }
            let bitmap = try rendered.get()
            if let root, let encoded = bitmap.representation(using: .png, properties: [:]) {
                try encoded.write(to: root.appendingPathComponent(name + "-" + suffix + ".png"))
            }
            // Toolbar glyphs, and the image footer, must survive sibling drawing
            // in both themes. Data inspectors may have legitimate blank bottoms.
            guard let pixels = bitmap.bitmapData else { throw Failure(description: "missing bitmap pixels") }
            let bytesPerPixel = bitmap.bitsPerPixel / 8
            let edgeRows = name.hasSuffix(".png") ? [0, max(0, bitmap.pixelsHigh - 64)] : [0]
            for firstRow in edgeRows {
                var colours = Set<UInt32>()
                for y in firstRow..<min(firstRow + 64, bitmap.pixelsHigh) {
                    for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                        let offset = y * bitmap.bytesPerRow + x * bytesPerPixel
                        colours.insert(UInt32(pixels[offset]) << 16 | UInt32(pixels[offset + 1]) << 8 | UInt32(pixels[offset + 2]))
                    }
                }
                try expect(colours.count > 8, "\(name) \(suffix): content drawing covered toolbar or inspector (\(colours.count) edge colours at row \(firstRow))")
            }

        }
        body.appearance = nil
        host.qaRenderer?.applyTheme()
    }
    private static func png() throws -> Data {
        let pixels = Data([255, 0, 0, 255, 0, 0, 255, 255])
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw Failure(description: "cannot create PNG fixture pixels")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure(description: "cannot create PNG fixture encoder")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure(description: "PNG fixture encoding failed") }
        return data as Data
    }
    private static func workbook() -> Data {
        storedZIP([
            ("xl/workbook.xml", "<workbook xmlns:r=\"urn:relationships\"><sheets><sheet name=\"Values\" r:id=\"r1\"/></sheets></workbook>"),
            ("xl/_rels/workbook.xml.rels", "<Relationships><Relationship Id=\"r1\" Target=\"worksheets/sheet1.xml\"/></Relationships>"),
            ("xl/worksheets/sheet1.xml", "<worksheet><sheetData><row><c r=\"A1\" t=\"inlineStr\"><is><t>id</t></is></c></row><row><c r=\"A2\" t=\"inlineStr\"><is><t>00123</t></is></c></row></sheetData></worksheet>")
        ])
    }
    /// Stored ZIP records include the complete 46-byte central-directory header;
    /// lengths and offsets are computed from the bytes actually appended.
    private static func storedZIP(_ files: [(String, String)]) -> Data {
        var output = Data(), central = Data()
        func u16(_ value: Int) -> Data { var v = UInt16(value).littleEndian; return withUnsafeBytes(of: &v) { Data($0) } }
        func u32(_ value: UInt32) -> Data { var v = value.littleEndian; return withUnsafeBytes(of: &v) { Data($0) } }
        func crc(_ bytes: Data) -> UInt32 {
            var value: UInt32 = 0xFFFFFFFF
            for byte in bytes { value ^= UInt32(byte); for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0xEDB88320 : 0) } }
            return value ^ 0xFFFFFFFF
        }
        for (path, text) in files {
            let name = Data(path.utf8), bytes = Data(text.utf8), offset = output.count, checksum = crc(bytes)
            let local: [Data] = [u32(0x04034B50), u16(20), u16(0), u16(0), u16(0), u16(0), u32(checksum), u32(UInt32(bytes.count)), u32(UInt32(bytes.count)), u16(name.count), u16(0), name, bytes]
            for part in local { output.append(part) }
            let record: [Data] = [u32(0x02014B50), u16(20), u16(20), u16(0), u16(0), u16(0), u16(0), u32(checksum), u32(UInt32(bytes.count)), u32(UInt32(bytes.count)), u16(name.count), u16(0), u16(0), u16(0), u16(0), u32(0), u32(UInt32(offset)), name]
            for part in record { central.append(part) }
        }
        let offset = output.count
        output.append(central)
        let end: [Data] = [u32(0x06054B50), u16(0), u16(0), u16(files.count), u16(files.count), u32(UInt32(central.count)), u32(UInt32(offset)), u16(0)]
        for part in end { output.append(part) }
        return output
    }
}
