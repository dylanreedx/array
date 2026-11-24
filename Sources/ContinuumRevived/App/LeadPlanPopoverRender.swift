import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// `--lead-plan-popover-render <dir>`: the lead's plan line and its popover in
/// a real lead tile on a real canvas (Orb icons on), fed by the production
/// supervisor. His plan on his tile size and a small plan on a small tile,
/// resting and needing him, closed and open, light and dark; plus one contact
/// sheet per appearance. Offscreen; never takes the screen. The open stills
/// composite the popover's own child panel over the tile's window.
@MainActor
enum LeadPlanPopoverRender {
    /// A stable id per name, so a helper keeps its character in every still.
    static func id(_ name: String) -> AgentID {
        var h: UInt64 = 0xcbf29ce484222325
        for b in name.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        var g = h &* 0x9E3779B97F4A7C15
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { bytes[i] = UInt8(truncatingIfNeeded: h >> (8 * UInt64(i))) }
        for i in 0..<8 { bytes[8 + i] = UInt8(truncatingIfNeeded: g >> (8 * UInt64(i))); g = g &* 31 }
        bytes[6] = (bytes[6] & 0x0f) | 0x40; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return AgentID(rawValue: UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                             bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])))
    }

    struct Case {
        let name: String
        let label: String
        let tile: NSSize
        let title: String
        let attention: Bool
        var small: Bool { name.hasPrefix("small") }
    }
    static let cases = [
        Case(name: "his-resting", label: "His plan · resting", tile: NSSize(width: 960, height: 800), title: "Rethink the plan drawer", attention: false),
        Case(name: "his-needs-you", label: "His plan · needs him", tile: NSSize(width: 960, height: 800), title: "Rethink the plan drawer", attention: true),
        Case(name: "small-resting", label: "Small · resting", tile: NSSize(width: 640, height: 520), title: "Fix the login redirect", attention: false),
        Case(name: "small-needs-you", label: "Small · needs him", tile: NSSize(width: 640, height: 520), title: "Fix the login redirect", attention: true),
    ]

    struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor final class Scene {
        let window: NSWindow
        let canvas: CanvasNSView
        let supervisor: AgentSupervisor
        let root: URL
        var lead: ManagedAgentTileNSView!
        init(window: NSWindow, canvas: CanvasNSView, supervisor: AgentSupervisor, root: URL) {
            self.window = window; self.canvas = canvas; self.supervisor = supervisor; self.root = root
        }
        var leadRect: NSRect { canvas.convert(lead.bounds, from: lead) }
        func close() {
            lead.qaLeadPlanView.close()
            supervisor.stopAll()
            window.orderOut(nil)
            try? FileManager.default.removeItem(at: root)
        }
    }

    static func leadEvents(_ c: Case, lead: AgentID) -> [(AgentRuntimeEvent, TimeInterval)] {
        let t = AgentSupervisor.threadId(for: lead), u = "turn-1"
        var e: [(AgentRuntimeEvent, TimeInterval)] = [
            (.sessionStateChanged(.running), 260),
            (.turnStarted(threadId: t, turnId: u), 250),
            (.contentDelta(threadId: t, turnId: u, streamKind: .assistant, delta: c.small
                ? "I'll hand the redirect fix to a helper and ship the hotfix once it is green."
                : "I split this into five steps. One helper fixes the drawer's data model, another designs the directions; I review them with you before joining the view to the model."), 240),
            (.itemStarted(threadId: t, itemId: "cmd-1", kind: .commandExecution, title: "git log --oneline -5"), 230),
            (.itemCompleted(threadId: t, itemId: "cmd-1", kind: .commandExecution, status: .completed), 228),
            (.contextWindowUpdated(threadId: t, snapshot: AgentContextWindowSnapshot(
                usedTokens: c.small ? 31_000 : 84_000, maxTokens: 200_000, observedAt: Date(), source: .providerSessionStats, freshness: .live)), 200),
        ]
        if c.attention {
            e.append((.contentDelta(threadId: t, turnId: u, streamKind: .assistant, delta: "\n\n" + (c.small
                ? "The fix is green. Ship the hotfix tonight, or wait for QA?"
                : "The data model fix is green; the redesign helper failed and I'll restart it. Ship the drawer fix in 0.7.61, or hold it?")), 40))
            e.append((.turnCompleted(threadId: t, turnId: u, outcome: .completed, errorMessage: nil), 30))
        } else {
            e.append((.itemStarted(threadId: t, itemId: "wait-1", kind: .commandExecution, title: "array_wait_agents"), 8))
        }
        return e
    }

    static func scene(_ c: Case, appearance: NSAppearance) async throws -> Scene {
        let size = NSSize(width: c.tile.width + 140, height: max(c.tile.height + 140, 720))
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
        canvas.focusBroker = FocusBroker()
        canvas.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-plan-popover-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("Array", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let supervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: support),
            makeRunner: AgentSupervisor.productionRunner,
            submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: support, debounceInterval: 0),
            transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true)))
        let s = Scene(window: window, canvas: canvas, supervisor: supervisor, root: root)
        let leadID = id("lead-" + c.title)
        _ = try supervisor.spawn(role: nil, prompt: nil, cwd: work, harness: .claudeCode, mode: .managed, model: "anthropic/claude-opus-5-5",
                                 thinking: "medium", parentAgentID: nil, isolated: false, displayName: c.title, id: leadID)
        let tile = Tile(id: UUID(), kind: .managedAgent, title: c.title,
                        frame: TileFrame(x: 70, y: 70, width: c.tile.width, height: c.tile.height),
                        zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed"))
        let view = ManagedAgentTileNSView(tile: tile)
        canvas.install(tileView: view, for: tile)
        view.attach(agentID: leadID, supervisor: supervisor)
        s.lead = view
        canvas.layoutSubtreeIfNeeded()
        view.appendUserPrompt(c.small ? "Fix the login redirect and ship a hotfix." : "Rethink the plan drawer: something completely different. Use the orbs.")
        let now = Date()
        for (e, ago) in leadEvents(c, lead: leadID) { supervisor.qaDeliver(e, to: leadID, now: now.addingTimeInterval(-ago)) }
        let spawn: (String) throws -> AgentID = { name in
            try supervisor.spawn(role: nil, prompt: nil, cwd: work, harness: .claudeCode, mode: .free, model: "anthropic/claude-sonnet-5-5",
                                 thinking: "medium", parentAgentID: leadID, isolated: false, displayName: name, id: id(name))
        }
        if c.small { try LeadPlanFixture.small(supervisor, lead: leadID, attention: c.attention, spawn: spawn) }
        else { _ = try LeadPlanFixture.his(supervisor, lead: leadID, attention: c.attention, spawn: spawn) }
        try? await Task.sleep(for: .seconds(0.8))
        view.agentStatus = c.attention ? .needsAttention : .working
        guard !view.qaLeadPlanView.isHidden else { throw Failure(description: "\(c.name): the plan line did not appear") }
        return s
    }

    static func settle(_ s: Scene) async {
        for _ in 0..<3 {
            s.canvas.layoutSubtreeIfNeeded()
            s.lead.layoutSubtreeIfNeeded(); s.lead.placeAgentBubble()
            try? await Task.sleep(for: .seconds(0.1))
        }
        s.window.displayIfNeeded()
        s.lead.qaLeadPlanView.popover.panel?.displayIfNeeded()
        CATransaction.flush()
        try? await Task.sleep(for: .seconds(0.35))
    }

    static func image(of window: NSWindow) throws -> CGImage {
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]) else {
            throw Failure(description: "the window server returned no image")
        }
        return image
    }

    /// The tile's window, with the popover's panel drawn over it where it sits.
    static func capture(_ s: Scene, rect: NSRect) async throws -> CGImage {
        await settle(s)
        let line = s.lead.qaLeadPlanView
        if !line.isOpen, let why = line.popover.qaLastSelfDismissal { print("note: the plan closed itself: \(why)") }
        if line.isOpen, let panel = line.popover.panel {
            // The offscreen window has no screen, so the panel was placed on the main
            // screen; seat it where it opens in the tile, its bottom just above the line.
            let m = ChoicePanelShadowView.margin
            let size = NSSize(width: panel.frame.width - 2 * m, height: panel.frame.height - 2 * m)
            let lineScreen = s.window.convertToScreen(line.convert(line.bounds, to: nil))
            // The line sits in the tile's resting host, so its own coordinates say nothing
            // about where it draws; it draws 111 pt above the tile's bottom edge (measured
            // on both tile sizes). Seat the surface a step above that.
            let lineTopFromBottom = s.canvas.bounds.height - s.leadRect.maxY + 111 + 10
            let origin = NSPoint(x: lineScreen.maxX + CGFloat(Space.l) - size.width,
                                 y: s.window.frame.minY + lineTopFromBottom + CGFloat(Space.m))
            panel.setFrame(NSRect(origin: origin, size: size).insetBy(dx: -m, dy: -m), display: true)
            panel.displayIfNeeded()
            CATransaction.flush()
            try? await Task.sleep(for: .seconds(0.3))
        }
        let base = try image(of: s.window)
        let scale = CGFloat(base.width) / s.window.frame.width
        let w = base.width, h = base.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(description: "no context")
        }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        if let panel = line.popover.panel, panel.isVisible {
            let p = try image(of: panel)
            let f = panel.frame, wf = s.window.frame
            ctx.draw(p, in: CGRect(x: (f.minX - wf.minX) * scale, y: (f.minY - wf.minY) * scale,
                                   width: f.width * scale, height: f.height * scale))
        }
        guard let full = ctx.makeImage() else { throw Failure(description: "composite failed") }
        let host = s.canvas
        let y = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
        guard let cropped = full.cropping(to: CGRect(x: rect.minX * scale, y: y * scale, width: rect.width * scale, height: rect.height * scale).integral) else {
            throw Failure(description: "could not crop \(rect)")
        }
        return cropped
    }

    static func render(to dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "ArrayPlanPopover-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AgentCharacterController.shared
        controller.reduceMotion = { true }
        controller.windowIsVisible = { _ in true }
        defaults.set(true, forKey: AgentCharacterConfig.enabledKey)
        defaults.set(AgentCharacterConfig.BubbleStyle.orb.rawValue, forKey: AgentCharacterConfig.bubbleStyleKey)
        controller.adopt(defaults: defaults)
        controller.reload(force: true)
        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.claude)
        var log: [String] = []
        for (appearanceName, tag) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let appearance = NSAppearance(named: appearanceName)!
            NSApp.appearance = appearance
            var shots: [(String, CGImage)] = []
            for c in cases {
                for open in [false, true] {
                    let s = try await scene(c, appearance: appearance)
                    defer { s.close() }
                    if open {
                        s.lead.qaLeadPlanView.open()
                        guard s.lead.qaLeadPlanView.isOpen else { throw Failure(description: "\(c.name): the plan did not open") }
                    }
                    let image = try await capture(s, rect: s.leadRect.insetBy(dx: -44, dy: -44))
                    let name = "b-\(c.name)\(open ? "-open" : "")-\(tag).png"
                    try write(image, to: dir.appendingPathComponent(name))
                    shots.append((c.label + (open ? " · open" : ""), image))
                    log.append(name + "  " + s.lead.qaLeadPlanView.sentence)
                }
            }
            try sheet(shots, appearance: appearance).write(to: dir.appendingPathComponent("sheet-\(tag).png"))
        }
        NSApp.appearance = nil
        print(log.joined(separator: "\n"))
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw Failure(description: "png encode failed")
        }
        try data.write(to: url)
    }

    /// One sheet per appearance: closed and open side by side, one row per case.
    static func sheet(_ shots: [(String, CGImage)], appearance: NSAppearance) throws -> Data {
        let k: CGFloat = 0.25
        let pad: CGFloat = 24, caption: CGFloat = 20
        func size(_ i: CGImage) -> NSSize { NSSize(width: CGFloat(i.width) * k, height: CGFloat(i.height) * k) }
        let rows = stride(from: 0, to: shots.count, by: 2).map { Array(shots[$0..<min($0 + 2, shots.count)]) }
        let rowWidths = rows.map { $0.reduce(pad) { $0 + size($1.1).width + pad } }
        let rowHeights = rows.map { caption + ($0.map { size($0.1).height }.max() ?? 0) + pad }
        let total = NSSize(width: (rowWidths.max() ?? 0) + pad, height: pad + rowHeights.reduce(0, +))
        let image = NSImage(size: total, flipped: true) { _ in
            appearance.performAsCurrentDrawingAppearance {
                let theme = appearance.tokenTheme
                SurfaceToken.canvas.color.nsColor(for: theme).setFill()
                NSRect(origin: .zero, size: total).fill()
                let muted = TextToken.textSecondary.color.nsColor(for: theme)
                var y = pad
                for (r, row) in rows.enumerated() {
                    var x = pad
                    for (label, img) in row {
                        (label as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: muted])
                        let s = size(img)
                        NSImage(cgImage: img, size: s).draw(in: NSRect(x: x, y: y + caption, width: s.width, height: s.height),
                                                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                        x += s.width + pad
                    }
                    y += rowHeights[r]
                }
            }
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation(using: .none, factor: 2)!)!
        return rep.representation(using: .png, properties: [:])!
    }
}
