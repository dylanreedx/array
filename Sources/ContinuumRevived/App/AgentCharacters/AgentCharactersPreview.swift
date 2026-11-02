import AppKit
import AVFoundation
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// Plan: .plans/110-agent-characters/PREVIEW.md
//
// Dylan's preview: the production sidebar and real agent tiles on a real canvas,
// attached to a real supervisor that runs no CLI. Scripted runtime events, the
// same ones a runner emits, walk eight agents through every state on a loop, so
// every character, pose and reaction can be seen in a few seconds. Characters are
// on. One window in Aqua and one in Dark Aqua.
//
// Opt-in only: the `dev.arrayapp.macos.characters` bundle or
// ARRAY_AGENT_CHARACTERS_PREVIEW=1, never the production bundle, never a check
// run. `scripts/agent-characters-preview.sh` builds the bundle.
// `--agent-characters-recording-check <out.mp4>` records the same scene offscreen.
@MainActor
final class AgentCharactersPreview: NSObject, NSApplicationDelegate {
    static let bundleIdentifier = "dev.arrayapp.macos.characters"

    static var isRequested: Bool {
        (ProcessInfo.processInfo.environment["ARRAY_AGENT_CHARACTERS_PREVIEW"] == "1"
            || Bundle.main.bundleIdentifier == bundleIdentifier)
            && Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier
            && !CommandLine.arguments.contains(where: { $0.hasSuffix("-check") })
    }

    private static var retained: AgentCharactersPreview?
    private var scenes: [Scene] = []
    private var gridWindow: NSWindow?

    static func run() {
        let app = NSApplication.shared
        let preview = AgentCharactersPreview()
        retained = preview
        app.delegate = preview
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.enableCharacters(in: .standard)
        let root = Self.workRoot()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1600, height: 1000)
        for (index, appearance) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            let scene = Scene(appearance: appearance, root: root, label: index == 0 ? "light" : "dark")
            let window = scene.window
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.title = "Agent characters — \(index == 0 ? "Light" : "Dark")"
            window.setFrameOrigin(NSPoint(x: screen.minX + 20 + CGFloat(index) * 40,
                                          y: screen.maxY - window.frame.height - 20 - CGFloat(index) * (window.frame.height + 30)))
            window.makeKeyAndOrderFront(nil)
            scene.start()
            scenes.append(scene)
        }
        if let theme = AgentCharacterController.shared.theme {
            let grid = AgentCharacterPreviewGridView(theme: theme)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: grid.frame.size).insetBy(dx: -16, dy: -16),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Agent characters — every character in every state"
            let host = NSView(frame: NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size))
            grid.setFrameOrigin(NSPoint(x: 16, y: 16))
            host.addSubview(grid)
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: screen.maxX - window.frame.width - 20, y: screen.minY + 20))
            window.orderFront(nil)
            gridWindow = window
        }
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    static func enableCharacters(in defaults: UserDefaults) {
        defaults.set(true, forKey: AgentCharacterConfig.enabledKey)
        AgentCharacterController.shared.adopt(defaults: defaults)
    }

    /// The preview's own scratch: CONTINUUM_APP_SUPPORT when the launch sets it.
    static func workRoot() -> URL {
        let base = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("array-agent-characters-preview", isDirectory: true)
        let root = base.appendingPathComponent("characters-preview-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("work"), withIntermediateDirectories: true)
        return root
    }

    // MARK: - The scene

    @MainActor
    final class Scene {
        let window: NSWindow
        let canvas: CanvasNSView
        let inbox: AgentInboxView
        let supervisor: AgentSupervisor
        private var agents: [AgentID] = []
        private var timer: Timer?
        private var tick = 0
        private var turn: [Int: Int] = [:]
        private let created = Date()

        static let titles = [
            "Rework the sign-in screen", "Find every caller of saveCanvas", "Run the release matrix",
            "Delete the stale benches", "Fix the zoom stutter", "Write the release notes",
            "Audit the notification paths", AgentName.defaultName,
        ]
        static let models = [
            "anthropic/claude-opus-4-6", "openai/gpt-5.5", "pi/kimi-k2", "anthropic/claude-sonnet-4-5",
            "openai/gpt-5.5", "anthropic/claude-opus-4-6", "anthropic/claude-haiku-4-5", "openai/gpt-5.5",
        ]

        init(appearance: NSAppearance.Name, root: URL, label: String) {
            let support = root.appendingPathComponent("support-\(label)", isDirectory: true)
            let work = root.appendingPathComponent("work", isDirectory: true)
            supervisor = AgentSupervisor(
                store: AgentStore(applicationSupportDirectory: support),
                makeRunner: AgentSupervisor.productionRunner,
                submissionRecoveryStore: AgentComposerDraftStore(applicationSupportDirectory: support, debounceInterval: 0),
                transcriptStore: AgentTranscriptStore(root: support.appendingPathComponent("transcripts", isDirectory: true)))
            let size = NSSize(width: 1560, height: 760)
            window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.isReleasedWhenClosed = false
            let host = NSView(frame: NSRect(origin: .zero, size: size))
            inbox = AgentInboxView(frame: NSRect(x: 0, y: 0, width: 320, height: size.height))
            inbox.autoresizingMask = [.height]
            canvas = CanvasNSView(canvasState: CanvasState(
                viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
            canvas.focusBroker = FocusBroker()
            canvas.frame = NSRect(x: 321, y: 0, width: size.width - 321, height: size.height)
            canvas.autoresizingMask = [.width, .height]
            host.addSubview(inbox)
            host.addSubview(canvas)
            window.contentView = host
            for (n, title) in Self.titles.enumerated() {
                let id = supervisor.spawn(role: nil, prompt: nil, cwd: work, harness: .claudeCode,
                                          model: Self.models[n], thinking: "low", displayName: title)
                agents.append(id)
                let tile = Tile(id: UUID(), kind: .managedAgent, title: title,
                                frame: TileFrame(x: Double(n % 4) * 300 + 16, y: Double(n / 4) * 370 + 16, width: 288, height: 356),
                                zPosition: .fromLegacyRank(n + 1), runtimeRef: nil,
                                metadata: TileMetadata(launchProfileId: "managed"))
                let view = ManagedAgentTileNSView(tile: tile)
                canvas.install(tileView: view, for: tile)
                view.attach(agentID: id, supervisor: supervisor)
            }
            // The quiet one: its last word was 200 s ago, so it is already asleep.
            let quiet = agents[6]
            let long = Date().addingTimeInterval(-200)
            supervisor.qaDeliver(.turnStarted(threadId: "t6", turnId: "u6"), to: quiet, now: long)
            supervisor.qaDeliver(.itemStarted(threadId: "t6", itemId: "q", kind: .mcpToolCall, title: "Read"), to: quiet, now: long)
            supervisor.qaDeliver(.itemCompleted(threadId: "t6", itemId: "q", kind: .mcpToolCall, status: .completed), to: quiet, now: long)
            pushRows()
        }

        func start() {
            step()
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.step() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        func stop() { timer?.invalidate() }

        private func deliver(_ n: Int, _ event: AgentRuntimeEvent) {
            supervisor.qaDeliver(event, to: agents[n])
        }

        private func beginTurn(_ n: Int) {
            turn[n, default: 0] += 1
            deliver(n, .turnStarted(threadId: "t\(n)", turnId: "u\(n).\(turn[n]!)"))
        }

        private func step(_ n: Int, _ id: String, _ kind: ItemKind, _ title: String?) {
            deliver(n, .itemStarted(threadId: "t\(n)", itemId: id, kind: kind, title: title))
        }

        /// One 0.5 s beat of the script; a full cycle is 16 s.
        func step() {
            let t = tick % 32
            if tick == 0 {
                for n in [0, 1, 2] { beginTurn(n) }
                beginTurn(3)
                deliver(3, .requestOpened(threadId: "t3", requestId: "approve", kind: .commandExecutionApproval))
            }
            // 0: editing, then reading, then building.
            switch t {
            case 0: step(0, "e\(tick)", .fileChange, "Sources/SignIn.swift")
            case 12: step(0, "r\(tick)", .mcpToolCall, "Read")
            case 22: step(0, "b\(tick)", .commandExecution, "swift build")
            default: break
            }
            // 1: searching the code, then the web.
            if t == 0 { step(1, "g\(tick)", .mcpToolCall, "Grep") }
            if t == 16 { step(1, "w\(tick)", .webSearch, "saveCanvas callers") }
            // 2: running; a step fails now and then (a flinch).
            if t == 0 { step(2, "m\(tick)", .commandExecution, "Bash") }
            if t == 10 { deliver(2, .itemCompleted(threadId: "t2", itemId: "m\(tick - 10)", kind: .commandExecution, status: .failed))
                step(2, "m2\(tick)", .commandExecution, "Bash") }
            // 4: works, then fails (a droop, then the failed pose).
            if t == 0 { beginTurn(4); step(4, "z\(tick)", .commandExecution, "swift test") }
            if t == 14 { deliver(4, .turnCompleted(threadId: "t4", turnId: "u4.\(turn[4] ?? 0)", outcome: .failed, errorMessage: "tests failed")) }
            // 5: thinks, writes, then finishes (a cheer, then done).
            if t == 4 { beginTurn(5); step(5, "p\(tick)", .reasoning, nil) }
            if t == 12 { step(5, "f\(tick)", .fileChange, "RELEASE-NOTES.md") }
            if t == 20 { deliver(5, .turnCompleted(threadId: "t5", turnId: "u5.\(turn[5] ?? 0)", outcome: .completed, errorMessage: nil)) }
            tick += 1
            pushRows()
        }

        /// The sidebar rows, built by the production builder from the same
        /// supervisor the tiles watch.
        func pushRows() {
            let now = Date()
            inbox.clock = { now }
            inbox.reload(rows: agents.enumerated().map { n, id in
                // The context production joins in: name, model (the provider mark),
                // project and when it was made (the list's order).
                let context = AgentRowContext(
                    projectName: "Array", directoryName: "Array", displayName: Self.titles[n],
                    agentKind: .managed, harness: "Claude Code", model: Self.models[n],
                    createdAt: created.addingTimeInterval(Double(-n)))
                return AgentInboxRowBuilder.row(
                    from: AgentsBoardRow(agentId: id.rawValue, status: .idle, lastSummary: "", recent: [],
                                         updatedAt: now, context: context),
                    turnSnapshot: supervisor.turnSnapshot(for: id), record: supervisor.records[id], now: now)
            })
        }
    }

    // MARK: - Offscreen recording

    /// `--agent-characters-recording-check <out.mp4>`: the scene in Aqua, then in
    /// Dark Aqua, captured from the window server offscreen, 8 s each.
    static func record(to url: URL, secondsPerAppearance: TimeInterval = 8, fps: Double = 20) throws -> String {
        let defaults = UserDefaults(suiteName: "ArrayCharactersRecording-\(UUID().uuidString)")!
        AgentCharacterController.shared.windowIsVisible = { _ in true }
        AgentCharacterController.shared.reduceMotion = { false }
        enableCharacters(in: defaults)
        let root = workRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.removeItem(at: url)
        var writer: AVAssetWriter?
        var input: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        var frames = 0
        var clock: TimeInterval = 0
        for (index, appearance) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            let scene = Scene(appearance: appearance, root: root, label: index == 0 ? "light" : "dark")
            scene.window.orderFrontOffscreenForChecks()
            scene.start()
            defer { scene.stop(); scene.window.orderOut(nil) }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            let start = Date()
            var last = Date.distantPast
            while Date().timeIntervalSince(start) < secondsPerAppearance {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
                guard Date().timeIntervalSince(last) >= 1 / fps else { continue }
                last = Date()
                CATransaction.flush()
                guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(scene.window.windowNumber),
                                                          [.boundsIgnoreFraming, .bestResolution]) else { continue }
                if writer == nil {
                    let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
                    let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: image.width,
                                                   AVVideoHeightKey: image.height]
                    let i = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                    i.expectsMediaDataInRealTime = true
                    let a = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: i, sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                        kCVPixelBufferWidthKey as String: image.width, kCVPixelBufferHeightKey as String: image.height])
                    w.add(i)
                    guard w.startWriting() else { throw NSError(domain: "recording", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(String(describing: w.error))"]) }
                    w.startSession(atSourceTime: .zero)
                    (writer, input, adaptor) = (w, i, a)
                }
                guard let adaptor, let input, let pool = adaptor.pixelBufferPool else { continue }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { continue }
                CVPixelBufferLockBaseAddress(buffer, [])
                let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer),
                                        height: CVPixelBufferGetHeight(buffer), bitsPerComponent: 8,
                                        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
                context?.draw(image, in: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
                CVPixelBufferUnlockBaseAddress(buffer, [])
                while !input.isReadyForMoreMediaData { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
                let time = CMTime(seconds: clock + Date().timeIntervalSince(start), preferredTimescale: 600)
                if adaptor.append(buffer, withPresentationTime: time) { frames += 1 }
            }
            clock += secondsPerAppearance
        }
        guard let writer, let input else { throw NSError(domain: "recording", code: 2, userInfo: [NSLocalizedDescriptionKey: "no frames captured"]) }
        input.markAsFinished()
        var done = false
        writer.finishWriting { done = true }
        while !done { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "recording", code: 3) }
        return "Recorded \(frames) frames (\(Int(clock)) s, light then dark) to \(url.path)"
    }
}
