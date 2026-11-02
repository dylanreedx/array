import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ImageIO
import UniformTypeIdentifiers

// Plan: .plans/110-agent-characters/README.md (transcript characters, 0.7.40 polish).
//
// `--transcript-character-check`: a real lead agent tile, attached to a real
// supervisor, with three delegated children whose turns run through the
// supervisor's own `deliver` path. The children's chips in the lead's drawn
// transcript must each show THAT child's character (the same shared atlas the
// child's own tile uses) in the pose its state names: working on an edit types,
// finished is done, failed is failed. A message from a child shows its sender's
// character; a provider's own subagent row (Claude's Task) gets a character
// posed by its tool status. A child finishing re-poses its chip through the
// live subscription. Slots scrolled out of the viewport own no sprite, a hidden
// window holds every sprite still, and with characters off every slot is
// today's icon again at the same chip height.
//
// `TRANSCRIPT_CHARACTERS_OUT=<dir>` also writes light and dark stills and a
// GIF of the chips going from working to done.
@MainActor
enum TranscriptCharacterChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static func pump(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    static func run() throws -> String {
        let key = AgentTranscriptCanvasView.rendererEnvironmentKey
        let previousRenderer = ProcessInfo.processInfo.environment[key]
        setenv(key, "canvas", 1)
        defer { if let previousRenderer { setenv(key, previousRenderer, 1) } else { unsetenv(key) } }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("array-transcript-character-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ArrayTranscriptCharacterChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AgentCharacterController.shared
        // A themes folder of its own: never the real store's.
        controller.importsDirectory = root.appendingPathComponent("characters", isDirectory: true)
        controller.reduceMotion = { false }
        controller.windowIsVisible = { _ in true }
        defaults.set(true, forKey: AgentCharacterConfig.enabledKey)
        controller.adopt(defaults: defaults)

        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.claude)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let supervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: support),
            makeRunner: AgentSupervisor.productionRunner,
            submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: support, debounceInterval: 0),
            transcriptStore: AgentTranscriptStore(root: root.appendingPathComponent("transcripts", isDirectory: true)))
        defer { supervisor.stopAll() }
        func spawn(_ name: String) -> AgentID {
            supervisor.spawn(role: nil, prompt: nil, cwd: work, harness: .claudeCode,
                             model: "anthropic/claude-haiku-4-5-20251001", thinking: "low", displayName: name)
        }
        let lead = spawn("Lead the polish round")
        let editor = spawn("Fix the login form")
        let reviewer = spawn("Review the parser")
        let tester = spawn("Run the failing leg")

        let tile = Tile(id: UUID(), kind: .managedAgent, title: "Lead the polish round",
                        frame: TileFrame(x: 0, y: 0, width: 620, height: 560),
                        zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata(launchProfileId: "managed"))
        let view = ManagedAgentTileNSView(tile: tile)
        view.frame = NSRect(x: 0, y: 0, width: 620, height: 560)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        view.attach(agentID: lead, supervisor: supervisor)
        view.layoutSubtreeIfNeeded()
        guard let surface = view.qaCanvasTranscript else {
            throw Failure(description: "the lead tile did not install the drawn transcript")
        }

        // The children's turns, through the supervisor.
        supervisor.qaDeliver(.turnStarted(threadId: "e", turnId: "e1"), to: editor)
        supervisor.qaDeliver(.itemStarted(threadId: "e", itemId: "e-edit", kind: .fileChange, title: "Sources/Login.swift"), to: editor)
        supervisor.qaDeliver(.turnStarted(threadId: "r", turnId: "r1"), to: reviewer)
        supervisor.qaDeliver(.turnCompleted(threadId: "r", turnId: "r1", outcome: .completed, errorMessage: nil), to: reviewer)
        supervisor.qaDeliver(.turnStarted(threadId: "t", turnId: "t1"), to: tester)
        supervisor.qaDeliver(.turnCompleted(threadId: "t", turnId: "t1", outcome: .failed, errorMessage: "exit 1"), to: tester)

        // The lead's transcript: a delegation of three, a message back from one
        // child, and a provider's own subagent (Claude's Task tool) still running.
        supervisor.qaDeliver(.turnStarted(threadId: "l", turnId: "l1"), to: lead)
        for (child, name) in [(editor, "Fix the login form"), (reviewer, "Review the parser"), (tester, "Run the failing leg")] {
            supervisor.qaDeliver(.childAgentSpawned(threadId: "l", childAgentID: child.rawValue, parentAgentID: lead.rawValue,
                                                    displayName: name, sourceItemID: nil, provider: "Claude Code",
                                                    spawnedAt: Date()), to: lead)
        }
        view.appendUserPrompt(AgentMessageEnvelope.wrap("The login form is fixed and its test passes.",
                                                        senderID: editor.rawValue, senderName: "Fix the login form"))
        supervisor.qaDeliver(.itemStarted(threadId: "l", itemId: "task-1", kind: .mcpToolCall, title: "Task"), to: lead)

        func settle() {
            _ = pump(until: { false }, timeout: 0.25)
            view.layoutSubtreeIfNeeded()
            surface.flushPendingVisualUpdate()
            view.layoutSubtreeIfNeeded()
            surface.displayIfNeeded()
        }
        func sprite(_ id: AgentID, inMessage: Bool = false) -> CharacterSpriteLayer? {
            let messageBlocks = Set(view.qaDocumentForChecks.entries.flatMap(\.blocks)
                .filter { $0.kind == .agentMessage }.map(\.id))
            return surface.qaCharacterSprites.first {
                $0.agentID == id.rawValue && messageBlocks.contains($0.blockID) == inMessage
            }?.layer
        }
        let appearance = AgentCharacterController.appearance(of: surface)
        settle()
        let chipRuns = surface.qaChipRuns
        try expect(chipRuns.flatMap(\.chips).count == 3, "the lead draws one chip per child: \(chipRuns.flatMap(\.chips).count)")

        // 1. Each chip shows that child's own character in the pose of its state.
        let expected: [(AgentID, AgentCharacterStill, String)] = [
            (editor, .loop(.type), "working on an edit"), (reviewer, .done, "finished"), (tester, .failed, "failed")]
        for (child, still, label) in expected {
            try expect(pump(until: { settle(); return sprite(child)?.plan?.still == still }),
                       "the \(label) child's chip poses \(still): \(String(describing: sprite(child)?.plan?.still)); sprites \(surface.qaCharacterSprites.map { ($0.agentID, $0.layer.plan?.still as Any) })")
            try expect(sprite(child)?.sprite === controller.atlas(for: child.rawValue, appearance: appearance),
                       "the \(label) child's chip draws its own character's shared atlas")
            let chip = chipRuns.flatMap(\.chips).first { $0.agentID == child.rawValue }
            let chipRect = chip.map { $0.rect.offsetBy(dx: chipRuns[0].origin.x, dy: chipRuns[0].origin.y) }
            try expect(chipRect.map { $0.contains(sprite(child)?.frame ?? .null) } == true,
                       "the \(label) child's character sits inside its chip: \(String(describing: sprite(child)?.frame)) in \(String(describing: chipRect))")
        }
        try expect(sprite(editor)?.isAnimating == true, "a working child's character moves")
        try expect(sprite(reviewer)?.plan?.isAnimated == true || sprite(reviewer)?.plan?.still == .done,
                   "a finished child cheers, then holds done")
        let distinct = Set([editor, reviewer, tester].compactMap { controller.characterIndex(for: $0.rawValue) })
        try expect(!distinct.isEmpty, "every child resolves a character")

        // 2. The message card shows its sender's character.
        try expect(sprite(editor, inMessage: true)?.sprite === controller.atlas(for: editor.rawValue, appearance: appearance),
                   "the message card from a child shows that child's character")

        // 3. The provider's own subagent row: a character posed by its tool status.
        let taskSprites = { surface.qaCharacterSprites.filter { ![lead, editor, reviewer, tester].map(\.rawValue).contains($0.agentID) } }
        try expect(taskSprites().count == 1 && taskSprites().first?.layer.isAnimating == true,
                   "a running Task row shows a working character: \(taskSprites().map { $0.layer.plan?.still as Any })")
        supervisor.qaDeliver(.itemCompleted(threadId: "l", itemId: "task-1", kind: .mcpToolCall, status: .completed), to: lead)
        try expect(pump(until: { settle(); return taskSprites().first?.layer.plan?.still == .done }),
                   "a finished Task row's character is done: \(taskSprites().map { $0.layer.plan?.still as Any })")

        // 4. A child finishing re-poses its chip through the live subscription.
        if let out = outputDirectory { try record(window: window, to: out.appendingPathComponent("chips-working-to-done.gif")) {
            supervisor.qaDeliver(.itemCompleted(threadId: "e", itemId: "e-edit", kind: .fileChange, status: .completed), to: editor)
            supervisor.qaDeliver(.turnCompleted(threadId: "e", turnId: "e1", outcome: .completed, errorMessage: nil), to: editor)
        } } else {
            supervisor.qaDeliver(.itemCompleted(threadId: "e", itemId: "e-edit", kind: .fileChange, status: .completed), to: editor)
            supervisor.qaDeliver(.turnCompleted(threadId: "e", turnId: "e1", outcome: .completed, errorMessage: nil), to: editor)
        }
        try expect(pump(until: { settle(); return sprite(editor)?.plan?.still == .done }),
                   "the editor's chip goes from typing to done when its turn completes: \(String(describing: sprite(editor)?.plan?.still))")

        // 5. A hidden window holds every sprite still; visible again, they move.
        supervisor.qaDeliver(.turnStarted(threadId: "e", turnId: "e2"), to: editor)
        try expect(pump(until: { settle(); return sprite(editor)?.isAnimating == true }), "a new turn moves the chip again")
        controller.windowIsVisible = { _ in false }
        NotificationCenter.default.post(name: AgentCharacterController.visibilityDidChangeNotification, object: nil)
        try expect(surface.qaCharacterSprites.allSatisfy { !$0.layer.isAnimating }, "a hidden window's characters hold still")
        controller.windowIsVisible = { _ in true }
        NotificationCenter.default.post(name: AgentCharacterController.visibilityDidChangeNotification, object: nil)
        try expect(sprite(editor)?.isAnimating == true, "visible again, the working chip moves")

        // 6. Off screen costs nothing: a slot outside the viewport has no sprite.
        for _ in 0..<12 { view.appendUserPrompt("A long follow-up note so the delegation scrolls out of view.\n\nAnd another paragraph.") }
        settle()
        surface.jumpToLatest()
        settle()
        let onScreen = surface.qaCharacterSprites
        try expect(onScreen.allSatisfy { $0.layer.frame.intersects(surface.bounds) },
                   "every sprite is in the viewport: \(onScreen.map(\.layer.frame)) in \(surface.bounds)")
        try expect(sprite(reviewer) == nil, "the scrolled-away chips own no sprite")
        surface.scrollTranscript(toY: 0)
        settle()
        try expect(sprite(reviewer) != nil, "scrolled back, the chip's character returns")

        if let out = outputDirectory { try captureStills(window: window, to: out, label: "on") }

        // 7. Characters off: today's icon in every slot, at the same chip size.
        let sizesOn = surface.qaChipRuns.map(\.size.height)
        defaults.set(false, forKey: AgentCharacterConfig.enabledKey)
        controller.reload()
        settle()
        try expect(surface.qaCharacterSprites.isEmpty && surface.qaCharacterSlotCount == 0,
                   "off: no sprite and no character slot (\(surface.qaCharacterSprites.count), \(surface.qaCharacterSlotCount))")
        let runsOff = surface.qaChipRuns
        try expect(runsOff.flatMap(\.chips).allSatisfy { chip in
            surface.qaSymbolRects.contains { chip.rect.offsetBy(dx: runsOff[0].origin.x, dy: runsOff[0].origin.y).contains($0) }
        }, "off: every chip draws today's icon")
        try expect(runsOff.map(\.size.height) == sizesOn, "chip rows keep their height: on \(sizesOn), off \(runsOff.map(\.size.height))")
        if let out = outputDirectory { try captureStills(window: window, to: out, label: "off") }
        defaults.set(true, forKey: AgentCharacterConfig.enabledKey)
        controller.reload()
        settle()
        try expect(sprite(reviewer) != nil, "on again, the characters come back with no relaunch")

        return "Transcript character checks passed: 3 delegated children's chips show their own characters posed typing / done / failed, the message card shows its sender's, a running Task row works then is done, a finished child re-poses live, hidden windows hold still, off-viewport slots own no sprite, off restores today's icons at equal chip heights"
    }

    static var outputDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["TRANSCRIPT_CHARACTERS_OUT"] else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func captureStills(window: NSWindow, to out: URL, label: String) throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            _ = pump(until: { false }, timeout: 0.3)
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            try SidebarCharacterChecks.capture(window, to: out.appendingPathComponent(
                "transcript-characters-\(label)-\(appearance == .aqua ? "light" : "dark").png"))
        }
        window.appearance = nil
    }

    /// The window server's frames for 2 s, then `change`, then 3 s more, as a GIF.
    static func record(window: NSWindow, to url: URL, change: () -> Void) throws {
        var frames: [CGImage] = []
        let fps = 12.0
        let start = Date()
        var changed = false
        while Date().timeIntervalSince(start) < 5 {
            if !changed, Date().timeIntervalSince(start) >= 2 { change(); changed = true }
            RunLoop.current.run(until: Date().addingTimeInterval(1 / fps))
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            CATransaction.flush()
            if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                   [.boundsIgnoreFraming, .bestResolution]) {
                frames.append(image)
            }
        }
        guard !frames.isEmpty, let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw Failure(description: "recording: no frames")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in frames {
            CGImageDestinationAddImage(destination, frame,
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw Failure(description: "recording: GIF did not finalize") }
    }
}
