import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// `--lead-plan-concepts-render <dir>`: the four plan concepts in a real lead
/// agent tile on a real canvas (Orb icons on), his drawer on his tile size and
/// a small plan on a small tile, resting and with something needing him, light
/// and dark. Writes `{a,b,c,d}-<case>-<appearance>.png` and one contact sheet
/// per appearance. Offscreen; never takes the screen.
@MainActor
enum LeadPlanConceptsRender {
    static let day: TimeInterval = 86400

    /// A stable id per name, so a helper keeps its character in every still.
    static func id(_ name: String) -> AgentID {
        var h: UInt64 = 0xcbf29ce484222325
        for b in name.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        var g = h &* 0x9E3779B97F4A7C15
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { bytes[i] = UInt8(truncatingIfNeeded: h >> (8 * UInt64(i))) }
        for i in 0..<8 { bytes[8 + i] = UInt8(truncatingIfNeeded: g >> (8 * UInt64(i))); g = g &* 31 }
        bytes[6] = (bytes[6] & 0x0f) | 0x40; bytes[8] = (bytes[8] & 0x3f) | 0x80
        let u = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return AgentID(rawValue: u)
    }
    static func helper(_ name: String, _ model: String, _ phase: LeadPlanDrawerModel.Phase, ago: TimeInterval? = nil, stale: Bool = false) -> LeadPlanDrawerModel.Helper {
        .init(id: id(name), name: name, model: model, phase: phase, endedAgo: ago, stale: stale)
    }

    /// His drawer (the same fixture as the drawer round): three failures 5–6
    /// days old, two idle helpers, one done an hour ago, a five-step plan.
    /// Attention adds a failure 12 minutes old and a lead decision.
    static func his(attention: Bool) -> LeadPlanDrawerModel {
        let strays = [
            helper("Sidebar fold band", "Sonnet 5.5", .failed, ago: 6 * day, stale: true),
            helper("Relay deletion routes", "Opus 5.5", .failed, ago: 6 * day, stale: true),
            helper("Bubble orb sizing", "Sonnet 5.5", .failed, ago: 5 * day, stale: true),
            helper("Settings theme picker", "Opus 5.5", .idle),
            helper("Companion task alerts", "Sonnet 5.5", .idle),
            helper("iOS preview tiles", "Sonnet 5.5", .done, ago: 3600),
        ]
        let steps: [LeadPlanDrawerModel.Step] = [
            .init(title: "Fix the drawer's data model", owner: .helpers([helper("Drawer data model", "Sonnet 5.5", .working)])),
            .init(title: "Design three drawer directions",
                  owner: .helpers([attention ? helper("Drawer redesign view", "Sonnet 5.5", .failed, ago: 12 * 60)
                                             : helper("Drawer redesign view", "Sonnet 5.5", .idle)])),
            .init(title: "Review the directions with Dylan", owner: .you),
            .init(title: "Join the view to the model", owner: .lead),
            .init(title: "Gate and ship 0.7.61", owner: .lead),
        ]
        return .init(steps: steps, strays: strays,
                     decision: attention ? "Ship the drawer fix in 0.7.61, or hold it?" : nil,
                     options: attention ? ["Ship it", "Hold for 0.7.62"] : [], collapsed: false)
    }

    static func small(attention: Bool) -> LeadPlanDrawerModel {
        .init(steps: [
            .init(title: "Fix the login redirect", owner: .helpers([helper("Login redirect fix", "Sonnet 5.5", attention ? .needsYou : .working)])),
            .init(title: "Ship the hotfix", owner: .lead),
        ], decision: attention ? "Ship the hotfix tonight, or wait for QA?" : nil,
           options: attention ? ["Ship tonight", "Wait for QA"] : [], collapsed: false)
    }

    struct Case {
        let name: String
        let label: String
        let tile: NSSize
        let title: String
        let attention: Bool
        let model: LeadPlanDrawerModel
    }
    static var cases: [Case] {
        // His lead tiles sit around 960–1020 x 800–880 on his canvas; a new
        // helper tile is 640 x 520.
        [Case(name: "his-resting", label: "His plan · resting", tile: NSSize(width: 960, height: 800), title: "Rethink the plan drawer", attention: false, model: his(attention: false)),
         Case(name: "his-needs-you", label: "His plan · needs him", tile: NSSize(width: 960, height: 800), title: "Rethink the plan drawer", attention: true, model: his(attention: true)),
         Case(name: "small-resting", label: "Small · resting", tile: NSSize(width: 640, height: 520), title: "Fix the login redirect", attention: false, model: small(attention: false)),
         Case(name: "small-needs-you", label: "Small · needs him", tile: NSSize(width: 640, height: 520), title: "Fix the login redirect", attention: true, model: small(attention: true))]
    }

    /// Yields to the main actor, so the tiles' event tasks run.
    static func pump(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    // MARK: Scene

    @MainActor final class Scene {
        let window: NSWindow
        let canvas: CanvasNSView
        let supervisor: AgentSupervisor
        let work: URL
        let root: URL
        var lead: ManagedAgentTileNSView!
        var helpers: [ManagedAgentTileNSView] = []
        init(window: NSWindow, canvas: CanvasNSView, supervisor: AgentSupervisor, work: URL, root: URL) {
            self.window = window; self.canvas = canvas; self.supervisor = supervisor; self.work = work; self.root = root
        }
        /// The lead tile in canvas coordinates.
        var leadRect: NSRect { canvas.convert(lead.bounds, from: lead) }
        func close() {
            supervisor.stopAll()
            window.orderOut(nil)
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// A tile attached to a real supervisor record, so the title, model,
    /// location, context meter and "Worked for" are production's own.
    static func makeTile(_ title: String, frame: NSRect, agent: AgentID, mode: AgentMode, parent: AgentID?, status: AgentStatus,
                         state: InboxState, in s: Scene, events: [(AgentRuntimeEvent, TimeInterval)], prompt: String?,
                         model: String = "anthropic/claude-opus-5-5") async throws -> ManagedAgentTileNSView {
        let id = try s.supervisor.spawn(role: nil, prompt: nil, cwd: s.work, harness: .claudeCode, mode: mode, model: model, thinking: "medium",
                                        parentAgentID: parent, isolated: false, displayName: title, id: agent)
        let tile = Tile(id: UUID(), kind: .managedAgent, title: title,
                        frame: TileFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
                        zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed"))
        let view = ManagedAgentTileNSView(tile: tile)
        s.canvas.install(tileView: view, for: tile)
        view.attach(agentID: id, supervisor: s.supervisor)
        s.canvas.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        if let prompt { view.appendUserPrompt(prompt) }
        let now = Date()
        for (e, ago) in events { s.supervisor.qaDeliver(e, to: id, now: now.addingTimeInterval(-ago)) }
        await pump(0.6)
        view.agentStatus = status
        return view
    }

    static func leadEvents(_ c: Case, listsOptions: Bool) -> [(AgentRuntimeEvent, TimeInterval)] {
        let t = AgentSupervisor.threadId(for: id("lead-" + c.title)), u = "turn-1"
        let small = c.name.hasPrefix("small")
        var e: [(AgentRuntimeEvent, TimeInterval)] = [
            (.sessionStateChanged(.running), 260),
            (.turnStarted(threadId: t, turnId: u), 250),
            (.contentDelta(threadId: t, turnId: u, streamKind: .assistant, delta: small
                ? "I'll hand the redirect fix to a helper and ship the hotfix once it is green."
                : "I split this into five steps. One helper fixes the drawer's data model, another designs the directions; I review them with you before joining the view to the model."), 240),
            (.itemStarted(threadId: t, itemId: "cmd-1", kind: .commandExecution, title: "git log --oneline -5"), 230),
            (.itemCompleted(threadId: t, itemId: "cmd-1", kind: .commandExecution, status: .completed), 228),
            (.contextWindowUpdated(threadId: t, snapshot: AgentContextWindowSnapshot(
                usedTokens: small ? 31_000 : 84_000, maxTokens: 200_000, observedAt: Date(), source: .providerSessionStats, freshness: .live)), 200),
        ]
        if c.attention {
            e.append((.contentDelta(threadId: t, turnId: u, streamKind: .assistant, delta: "\n\n" + (small
                ? "The fix is green. " : "The data model fix is green; the redesign helper failed and I'll restart it. ") + (listsOptions ? (small ? "Which do you prefer for the hotfix?" : "Which do you prefer for the drawer fix?")
                    + "\n\n" + c.model.options.map { "- " + $0 }.joined(separator: "\n") : (c.model.decision ?? ""))), 40))
            e.append((.turnCompleted(threadId: t, turnId: u, outcome: .completed, errorMessage: nil), 30))
        } else {
            e.append((.itemStarted(threadId: t, itemId: "wait-1", kind: .commandExecution, title: "array_wait_agents"), 8))
        }
        return e
    }

    static func scene(_ c: Case, appearance: NSAppearance, extraWidth: CGFloat, listsOptions: Bool = false) async throws -> Scene {
        let size = NSSize(width: c.tile.width + extraWidth + 140, height: max(c.tile.height + 140, 720))
        let canvas = CanvasNSView(canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
        canvas.focusBroker = FocusBroker()
        canvas.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-plan-concepts-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("Array", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let supervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: support),
            makeRunner: AgentSupervisor.productionRunner,
            submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: support, debounceInterval: 0),
            transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true)))
        let s = Scene(window: window, canvas: canvas, supervisor: supervisor, work: work, root: root)
        s.lead = try await makeTile(c.title, frame: NSRect(x: 70, y: 70, width: c.tile.width, height: c.tile.height), agent: id("lead-" + c.title),
                              mode: .managed, parent: nil, status: c.attention ? .needsAttention : .working, state: c.attention ? .input : .working,
                              in: s, events: leadEvents(c, listsOptions: listsOptions),
                              prompt: c.name.hasPrefix("small") ? "Fix the login redirect and ship a hotfix." : "Rethink the plan drawer: something completely different. Use the orbs.")
        return s
    }

    static func settle(_ s: Scene) async {
        for _ in 0..<3 {
            s.canvas.layoutSubtreeIfNeeded()
            for v in [s.lead!] + s.helpers { v.layoutSubtreeIfNeeded(); v.placeAgentBubble() }
            await pump(0.1)
        }
        s.window.displayIfNeeded()
        CATransaction.flush()
        await pump(0.25)
    }

    static func capture(_ s: Scene, rect: NSRect) async throws -> CGImage {
        await settle(s)
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(s.window.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]) else {
            throw Failure(description: "the window server returned no image")
        }
        let host = s.canvas
        let scale = CGFloat(image.width) / host.bounds.width
        let y = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
        guard let cropped = image.cropping(to: CGRect(x: rect.minX * scale, y: y * scale, width: rect.width * scale, height: rect.height * scale).integral) else {
            throw Failure(description: "could not crop \(rect)")
        }
        return cropped
    }

    // MARK: Concepts

    static func glance(_ c: Case) -> PlanGlance {
        PlanGlance(c.model, leadID: id("lead-" + c.title), leadName: c.title)
    }

    static func add(_ view: NSView, frame: NSRect, to s: Scene) {
        view.frame = frame
        s.canvas.addSubview(view, positioned: .above, relativeTo: nil)
    }

    /// A: orbs in the title bar; a decision answers through the composer's own chips.
    static func conceptA(_ c: Case, _ s: Scene, now: Date) async throws {
        let g = glance(c)
        s.canvas.layoutSubtreeIfNeeded()
        guard let bar = s.lead.qaTitleBarView else { throw Failure(description: "A: no title bar") }
        let barRect = s.canvas.convert(bar.bounds, from: bar)
        let pill = s.lead.qaStatusPillRectInBar().map { s.canvas.convert($0, from: bar) }
        let strip = PlanHeaderStripView(g)
        let right = (pill?.minX ?? barRect.maxX - 40) - 12
        let w = strip.preferredWidth
        add(strip, frame: NSRect(x: right - w, y: barRect.minY, width: w, height: barRect.height), to: s)
        strip.show(now: now)
        if c.attention {
            // The lead asks in its own reply and lists the answers; the
            // composer's reply detector turns them into chips (production path).
            // The orb that needs him, opened: its card under the bar.
            if let i = g.helpers.firstIndex(where: { $0.phase == .failed || $0.phase == .needsYou }), i < strip.orbs.count {
                let orb = s.canvas.convert(strip.orbs[i].bounds, from: strip.orbs[i])
                let h = g.helpers[i]
                let card = PlanOrbCardView(helper: h, step: h.step.map { g.steps[$0] }, stepNumber: h.step.map { $0 + 1 })
                let size = PlanOrbCardView.size(for: h, step: h.step.map { g.steps[$0] })
                let shadow = ChoicePanelShadowView(surface: card)
                let m = ChoicePanelShadowView.margin
                add(shadow, frame: NSRect(x: min(orb.midX - 40, s.leadRect.maxX - size.width - 8) - m, y: orb.maxY + 6 - m,
                                          width: size.width + 2 * m, height: size.height + 2 * m), to: s)
            }
        }
    }

    /// B: one line on the composer's status row; a click opens the plan popover.
    static func conceptB(_ c: Case, _ s: Scene, now: Date, open: Bool) async throws {
        let g = glance(c)
        s.canvas.layoutSubtreeIfNeeded()
        // The drawn chrome rests the compose area detached from the window, so
        // place by the tile: the status row is the top 28 pt of the compose area.
        let backdrop = s.lead.qaPageZoomComposeBackdrop.bounds.height
        let lead = s.leadRect
        let rowRect = NSRect(x: lead.minX + 12, y: lead.maxY - backdrop + 3, width: lead.width - 12 - 60, height: 28)
        let line = PlanStatusLineView(g)
        line.open = open
        let w = line.preferredWidth
        let lineRect = NSRect(x: rowRect.maxX - w - 4, y: rowRect.minY, width: w, height: rowRect.height)
        add(line, frame: lineRect, to: s)
        line.show(now: now)
        guard open else { return }
        let surface = PlanPopoverSurfaceView(g)
        let width = min(520, s.leadRect.width - 40)
        let height = surface.list.preferredHeight
        let m = ChoicePanelShadowView.margin
        let shadow = ChoicePanelShadowView(surface: surface)
        add(shadow, frame: NSRect(x: lineRect.maxX - width + 6 - m, y: lineRect.minY - 6 - height - m,
                                  width: width + 2 * m, height: height + 2 * m), to: s)
        surface.applyTokens()
        surface.list.show(now: now)
    }

    /// C: the plan as a card pinned at the top of the transcript.
    static func conceptC(_ c: Case, _ s: Scene, now: Date) async throws {
        let g = glance(c)
        s.canvas.layoutSubtreeIfNeeded()
        guard let transcript = (s.lead.qaTranscriptForChecks as NSView?) ?? (s.lead.qaTranscriptSurface as? NSView) else { throw Failure(description: "C: no transcript") }
        let tr = s.canvas.convert(transcript.bounds, from: transcript)
        let card = PlanTranscriptCardView(g)
        let lead = s.leadRect
        let inset: CGFloat = 24
        // At the transcript's newest end, rewritten in place: it stays the
        // last thing in the transcript while the lead works.
        let h = card.preferredHeight
        add(card, frame: NSRect(x: lead.minX + inset, y: tr.maxY - h - 12, width: lead.width - 2 * inset, height: h), to: s)
        card.applyTokens()
        card.list.show(now: now)
    }

    /// D: satellites beside the tile, each linked to its helper's own tile.
    static func conceptD(_ c: Case, _ s: Scene, now: Date) async throws {
        let g = glance(c)
        let lead = s.leadRect
        let helperX = lead.maxX + 16 + PlanSatelliteView.spineX + PlanSatelliteView.labelWidth + 120
        var anchors: [Int: NSPoint] = [:]
        var y = lead.minY
        for (i, h) in g.helpers.enumerated() where h.step != nil && h.phase != .done {
            let size = NSSize(width: 640, height: 260)
            let status: AgentStatus = switch h.phase { case .working: .working; case .failed, .needsYou: .needsAttention; default: .idle }
            let state: InboxState = switch h.phase { case .working: .working; case .failed: .failed; case .needsYou: .input; default: .ready }
            let t = AgentSupervisor.threadId(for: h.id), u = "turn-\(i)"
            let text: String = switch h.phase {
            case .working: "Linking each plan step to its helpers by id, so a rename can't move a step."
            case .failed: "Drafted three directions; the render failed on a missing font."
            case .needsYou: "The redirect fix passes. Should I also clear the stale session cookie?"
            default: "Ready for the next step."
            }
            let ended: TimeInterval = h.phase == .failed ? 12 * 60 : 45
            var ev: [(AgentRuntimeEvent, TimeInterval)] = [(.sessionStateChanged(.running), ended + 200), (.turnStarted(threadId: t, turnId: u), ended + 190),
                (.contentDelta(threadId: t, turnId: u, streamKind: .assistant, delta: text), ended + 20),
                (.contextWindowUpdated(threadId: t, snapshot: AgentContextWindowSnapshot(
                    usedTokens: 46_000, maxTokens: 200_000, observedAt: Date(), source: .providerSessionStats, freshness: .live)), ended + 10)]
            if h.phase != .working { ev.append((.turnCompleted(threadId: t, turnId: u, outcome: h.phase == .failed ? .failed : .completed, errorMessage: nil), ended)) }
            else { ev.append((.itemStarted(threadId: t, itemId: "edit-\(i)", kind: .fileChange, title: "Sources/ContinuumRevived/App/AgentSupervisor+LeadPlan.swift"), 4)) }
            let tile = try await makeTile(h.name, frame: NSRect(x: helperX, y: y, width: size.width, height: size.height), agent: h.id,
                                    mode: .managed, parent: nil, status: status, state: state, in: s, events: ev, prompt: nil,
                                    model: "anthropic/claude-sonnet-5-5")
            s.helpers.append(tile)
            s.canvas.layoutSubtreeIfNeeded()
            let r = s.canvas.convert(tile.bounds, from: tile)
            anchors[i] = NSPoint(x: r.minX, y: r.minY + 40)
            y += size.height + 40
        }
        let sat = PlanSatelliteView(g)
        let frame = NSRect(x: lead.maxX + 16, y: lead.minY, width: helperX - lead.maxX - 16, height: lead.height)
        sat.leadAnchor = NSPoint(x: 0, y: sat.nodeCenter(0).y)
        sat.helperTileAnchors = anchors.mapValues { NSPoint(x: $0.x - frame.minX, y: $0.y - frame.minY) }
        add(sat, frame: frame, to: s)
        sat.show(now: now)
    }

    // MARK: Render

    static func render(to dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = "ArrayPlanConcepts-\(UUID().uuidString)"
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
        let now = Date()
        var log: [String] = []
        for (appearanceName, tag) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let appearance = NSAppearance(named: appearanceName)!
            NSApp.appearance = appearance
            var shots: [String: [(String, CGImage)]] = [:]
            for concept in ["a", "b", "c", "d"] {
                for c in cases {
                    let extra: CGFloat = concept == "d" ? PlanSatelliteView.spineX + PlanSatelliteView.labelWidth + 136 + 700 : 0
                    let s = try await scene(c, appearance: appearance, extraWidth: extra, listsOptions: concept == "a")
                    defer { s.close() }
                    switch concept {
                    case "a": try await conceptA(c, s, now: now)
                    case "b": try await conceptB(c, s, now: now, open: c.attention)
                    case "c": try await conceptC(c, s, now: now)
                    default: try await conceptD(c, s, now: now)
                    }
                    var rect = s.leadRect.insetBy(dx: -44, dy: -44)
                    if concept == "d" {
                        let right = s.helpers.map { s.canvas.convert($0.bounds, from: $0).maxX }.max() ?? (s.leadRect.maxX + 400)
                        rect.size.width = right + 30 - rect.minX
                    }
                    let image = try await capture(s, rect: rect)
                    let url = dir.appendingPathComponent("\(concept)-\(c.name)-\(tag).png")
                    try write(image, to: url)
                    shots[concept, default: []].append((c.label, image))
                    log.append(url.lastPathComponent)
                }
            }
            // B's popover open at rest too: the plan is one click away.
            do {
                let c = cases[0]
                let s = try await scene(c, appearance: appearance, extraWidth: 0)
                defer { s.close() }
                try await conceptB(c, s, now: now, open: true)
                let image = try await capture(s, rect: s.leadRect.insetBy(dx: -44, dy: -44))
                try write(image, to: dir.appendingPathComponent("b-his-resting-open-\(tag).png"))
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

    static let titles = [
        "a": "A · Header orbs — the plan lives in the title bar",
        "b": "B · Status line — one sentence on the composer's line, the plan in a popover",
        "c": "C · Transcript card — pinned at the newest end of the transcript, rewritten in place",
        "d": "D · Satellites — the plan beside the tile on the canvas, linked to each helper's tile",
    ]

    /// One sheet per appearance: a row per concept, the four cases across, at a
    /// common scale so tile sizes compare honestly.
    static func sheet(_ shots: [String: [(String, CGImage)]], appearance: NSAppearance) throws -> Data {
        let k: CGFloat = 0.25 // pixels (2x) → sheet points
        let pad: CGFloat = 24, caption: CGFloat = 20, title: CGFloat = 28
        var rows: [(String, [(String, CGImage)])] = ["a", "b", "c", "d"].map { ($0, shots[$0] ?? []) }
        rows = rows.filter { !$0.1.isEmpty }
        func size(_ i: CGImage) -> NSSize { NSSize(width: CGFloat(i.width) * k, height: CGFloat(i.height) * k) }
        let rowWidths = rows.map { $0.1.reduce(pad) { $0 + size($1.1).width + pad } }
        let rowHeights = rows.map { title + caption + ($0.1.map { size($0.1).height }.max() ?? 0) + pad }
        let total = NSSize(width: (rowWidths.max() ?? 0) + pad, height: pad + rowHeights.reduce(0, +))
        let image = NSImage(size: total, flipped: true) { _ in
            appearance.performAsCurrentDrawingAppearance {
                let theme = appearance.tokenTheme
                SurfaceToken.canvas.color.nsColor(for: theme).setFill()
                NSRect(origin: .zero, size: total).fill()
                let ink = TextToken.textPrimary.color.nsColor(for: theme)
                let muted = TextToken.textSecondary.color.nsColor(for: theme)
                var y = pad
                for (r, row) in rows.enumerated() {
                    (titles[row.0]! as NSString).draw(at: NSPoint(x: pad, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: ink])
                    var x = pad
                    for (label, img) in row.1 {
                        (label as NSString).draw(at: NSPoint(x: x, y: y + title), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: muted])
                        let s = size(img)
                        NSImage(cgImage: img, size: s).draw(in: NSRect(x: x, y: y + title + caption, width: s.width, height: s.height),
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
