import AppKit
import ContinuumRevivedAgentUI

/// Films the sidebar's motion — hover in/out on a folded stack, unfold, fold —
/// from the window server, so what is recorded is what a screen would show,
/// animations included. `--sidebar-motion-film-check` writes one strip per scene
/// and appearance into `qa-runs/sidebar-motion-film/`. A review tool: it asserts
/// only that every scene produced frames.
@MainActor
enum SidebarMotionFilm {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static let now = Date(timeIntervalSince1970: 1_900_600_000)

    static func run(outputDirectory: URL) async throws -> String {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var lines: [String] = []
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            lines += try await film(appearance: appearance, into: outputDirectory)
        }
        return lines.joined(separator: "\n")
    }

    private static func film(appearance: NSAppearance.Name, into directory: URL) async throws -> [String] {
        let tag = appearance == .darkAqua ? "dark" : "light"
        let inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 320, height: 900))
        inbox.clock = { now }
        inbox.foldsUntouchedGroups = true
        inbox.prefersReducedMotion = { false }
        inbox.onRevealRow = { _ in }
        inbox.hoverCardEnabled = false
        let window = NSWindow(contentRect: inbox.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = inbox
        // On a real screen, so the fold's display link ticks, but at the level
        // just above the desktop: behind every app window, never taking focus
        // or the pointer. An off-screen window gets no display ticks at all.
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        if let screen = NSScreen.main { window.setFrameOrigin(screen.visibleFrame.origin) }
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        inbox.reload(rows: SidebarPolishFixtures.rows(now: now))
        inbox.layoutForQA()
        try await settle(0.4)

        let team = UUID(uuidString: "00000000-0000-0000-0000-000000000502")!
        var lines: [String] = []

        var subject = team
        func focus() -> CGRect {
            for case let cell as AgentInbox96CellView in inbox.qaMaterializedRowCells where cell.qaAgentID == subject {
                // Window coordinates are y-up; the image is y-down.
                let rect = cell.convert(cell.bounds, to: nil).insetBy(dx: 0, dy: -14)
                return CGRect(x: 0, y: inbox.bounds.height - rect.maxY, width: inbox.bounds.width, height: rect.height)
            }
            return CGRect(x: 0, y: 0, width: inbox.bounds.width, height: 200)
        }
        func scene(_ name: String, duration: TimeInterval, _ action: () throws -> Void) async throws {
            let region = focus()
            let frames = try await record(window: window, duration: duration, action: action)
            let url = directory.appendingPathComponent("\(tag)-\(name).png")
            try writeGrid(frames, region: region, to: url)
            // The rows the fold moves, and the glyph alone, enlarged.
            let list = CGRect(x: 0, y: region.minY, width: region.width, height: min(360, inbox.bounds.height - region.minY))
            try writeGrid(frames, region: list, columns: 6,
                          to: directory.appendingPathComponent("\(tag)-\(name)-list.png"))
            let glyph = CGRect(x: 0, y: region.minY + 10, width: 70, height: region.height - 20)
            try writeGrid(frames, region: glyph, columns: 12, upscale: 3,
                          to: directory.appendingPathComponent("\(tag)-\(name)-glyph.png"))
            lines.append("\(tag) \(name): \(frames.count) frames → \(url.path)")
        }

        try await scene("hover-in", duration: 0.45) { _ = inbox.hoverRowForQA(id: team) }
        try await scene("hover-out", duration: 0.45) { _ = inbox.hoverRowForQA(id: nil) }
        let single = UUID(uuidString: "00000000-0000-0000-0000-000000000506")!
        subject = single
        try await scene("single-hover-in", duration: 0.35) { _ = inbox.hoverRowForQA(id: single) }
        try await scene("single-hover-out", duration: 0.35) { _ = inbox.hoverRowForQA(id: nil) }
        subject = team
        try await scene("unfold", duration: 0.5) { try pressFold(inbox, team, window) }
        try await settle(0.3)
        try await scene("fold", duration: 0.5) { try pressFold(inbox, team, window) }
        return lines
    }

    private static func pressFold(_ inbox: AgentInboxView, _ id: UUID, _ window: NSWindow) throws {
        for case let cell as AgentInbox96CellView in inbox.qaMaterializedRowCells where cell.qaAgentID == id {
            guard let control = cell.qaFoldControlForQA else { break }
            let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType) throws -> NSEvent {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                else { throw Failure(description: "could not synthesise \(type)") }
                return event
            }
            window.sendEvent(try event(.leftMouseDown))
            // The release through the application, the way a real one arrives.
            NSApp.postEvent(try event(.leftMouseUp), atStart: true)
            if let release = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(release)
            }
            return
        }
        throw Failure(description: "no fold control for \(id)")
    }

    private struct Frame { let at: TimeInterval; let image: CGImage }

    /// Frames every ~16ms for `duration`, the first one before `action`.
    private static func record(window: NSWindow, duration: TimeInterval, action: () throws -> Void) async throws -> [Frame] {
        var frames: [Frame] = []
        let windowID = CGWindowID(window.windowNumber)
        func grab(_ start: TimeInterval) {
            if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, [.boundsIgnoreFraming, .bestResolution]) {
                frames.append(Frame(at: ProcessInfo.processInfo.systemUptime - start, image: image))
            }
        }
        grab(0); grab(0); frames.removeAll()   // the first grabs are slow; warm up
        let start = ProcessInfo.processInfo.systemUptime
        grab(start)
        try action()
        while ProcessInfo.processInfo.systemUptime - start < duration {
            try await Task.sleep(nanoseconds: 16_000_000)
            grab(start)
        }
        guard frames.count > 3 else { throw Failure(description: "captured only \(frames.count) frames") }
        return frames
    }

    private static func settle(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Each frame cropped to `region` (points, y-down), six to a row, labelled with its time.
    private static func writeGrid(_ frames: [Frame], region: CGRect, columns wanted: Int = 4,
                                  upscale: CGFloat = 1, to url: URL) throws {
        guard let first = frames.first?.image else { return }
        let scale = CGFloat(first.width) / 320
        let crop = CGRect(x: region.minX * scale, y: region.minY * scale,
                          width: region.width * scale, height: region.height * scale).integral
        let label = Int(16 * scale), gap = Int(4 * scale)
        let columns = min(wanted, frames.count), rows = (frames.count + columns - 1) / columns
        let drawnW = Int(crop.width * upscale), drawnH = Int(crop.height * upscale)
        let cellW = drawnW + gap, cellH = drawnH + label + gap
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: cellW * columns, height: cellH * rows, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure(description: "no context") }
        context.interpolationQuality = upscale > 1 ? .none : .default
        context.setFillColor(CGColor(gray: 0.45, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: cellW * columns, height: cellH * rows))
        for (index, frame) in frames.enumerated() {
            let column = index % columns, row = index / columns
            let originX = column * cellW, top = cellH * rows - row * cellH
            if let piece = frame.image.cropping(to: crop) {
                context.draw(piece, in: CGRect(x: originX, y: top - label - drawnH, width: drawnW, height: drawnH))
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            (String(format: "%.0f ms", frame.at * 1000) as NSString).draw(
                at: NSPoint(x: CGFloat(originX) + 4 * scale, y: CGFloat(top - label) + 2 * scale),
                withAttributes: [.font: NSFont.systemFont(ofSize: (upscale > 1 ? 8 : 11) * scale), .foregroundColor: NSColor.white])
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw Failure(description: "could not encode \(url.lastPathComponent)") }
        try data.write(to: url)
    }
}
