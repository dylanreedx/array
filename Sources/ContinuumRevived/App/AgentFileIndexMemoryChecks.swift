import AppKit
import ContinuumRevivedCore
import Darwin
import Foundation

/// `--agent-file-index-memory-check`: forty managed agent tiles on one large
/// checkout must not hold forty copies of its `@`-completion file index.
///
/// Dylan's 0.7.47 grew to 7.6 GB in 2.5 days. Its heap census showed 40 arrays
/// of `AgentFileIndex.Indexed`, 1.3M `_FileCache` and 1.6M `NSURL`: every tile
/// built its own index of the same checkout, and every entry kept a file URL
/// carrying the resource-value cache its content-type lookup had attached.
///
/// Driven through production: a real `AppDelegate` and supervisor, real
/// `ManagedAgentTileNSView`s wired by `wireManagedAgentTile`, and the composer
/// taking the keyboard through `NSWindow.makeFirstResponder`, which is what
/// warms the index in the app. Memory is malloc bytes in use, read before and
/// after; suggestions are compared against a digest recorded from the build
/// before the fix, so the change is proven not to alter a single row.
@MainActor
enum AgentFileIndexMemoryChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure(description: message()) }
    }

    static let tileCount = 40
    static let topDirectories = 30
    static let subdirectories = 15
    static let filesPerDirectory = 100

    /// Recorded from the suggestions of the build before the fix
    /// (2e280397) over this fixture; every later build must match it.
    static let goldenSuggestionDigest = "60dfeb4fe7aadd05"

    static func mallocBytesInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    static func physFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : -1
    }

    private static func mb(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }

    private static func makeFixture(root: URL) throws -> Int {
        let fm = FileManager.default
        let extensions = ["swift", "md", "json", "txt"]
        var files = 0
        for top in 0..<topDirectories {
            for sub in 0..<subdirectories {
                let directory = root
                    .appendingPathComponent(String(format: "module-%02d", top), isDirectory: true)
                    .appendingPathComponent(String(format: "group-%02d", sub), isDirectory: true)
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                for index in 0..<filesPerDirectory {
                    let name = String(format: "file-%03d.%@", index, extensions[index % extensions.count])
                    guard fm.createFile(atPath: directory.appendingPathComponent(name).path, contents: nil) else {
                        throw Failure(description: "could not create fixture file \(name)")
                    }
                    files += 1
                }
            }
        }
        try "# Fixture\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        // A git checkout, like the real one: the index lists it with
        // `git ls-files --others`, so nothing needs to be staged.
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        git.arguments = ["git", "-C", root.path, "init", "-q"]
        git.standardOutput = Pipe()
        git.standardError = Pipe()
        try git.run()
        git.waitUntilExit()
        try expect(git.terminationStatus == 0, "git init failed for the fixture")
        return files + 1
    }

    /// Every completion, with the fixture's random root removed, hashed.
    private static func digest(_ batches: [[AgentCompletion]], root: URL) -> String {
        var text = ""
        for batch in batches {
            text += "--\n"
            for completion in batch {
                text += "\(completion.id)|\(completion.title)|\(completion.detail ?? "")|\(completion.insertionText)|\(completion.score)|\(completion.payload)|\(completion.provenance)|\(completion.isEnabled)\n"
            }
        }
        for path in [root.resolvingSymlinksInPath().path, root.standardizedFileURL.path] {
            text = text.replacingOccurrences(of: path, with: "<root>")
        }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    private static func queries(context: AgentCompletionContext) -> [AgentCompletionQuery] {
        let range = NSRange(location: 0, length: 0)
        return [
            AgentCompletionQuery(trigger: "@", text: "", replacementRange: range, context: context),
            AgentCompletionQuery(trigger: "@", text: "rea", replacementRange: range, context: context),
            AgentCompletionQuery(trigger: "@", text: "file-042", replacementRange: range, context: context),
            AgentCompletionQuery(trigger: "@", text: "grp07swift", replacementRange: range, context: context),
            AgentCompletionQuery(trigger: "@", text: "", replacementRange: range, context: context,
                                 navigationPath: "module-03"),
            AgentCompletionQuery(trigger: "@", text: "", replacementRange: range, context: context,
                                 navigationPath: "module-03/group-11"),
            AgentCompletionQuery(trigger: "@", text: "9.md", replacementRange: range, context: context,
                                 navigationPath: "module-12"),
        ]
    }

    static func run() async throws -> String {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory
            .appendingPathComponent("array-file-index-memory-\(UUID().uuidString)", isDirectory: true)
        let appSupport = temporary.appendingPathComponent("support", isDirectory: true)
        let agentsSupport = temporary.appendingPathComponent("agents", isDirectory: true)
        let projectRoot = temporary.appendingPathComponent("checkout", isDirectory: true)
        for dir in [appSupport, agentsSupport, projectRoot] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        defer { try? fm.removeItem(at: temporary) }
        let fileCount = try makeFixture(root: projectRoot)

        var tiles: [Tile] = []
        for index in 0..<tileCount {
            let x = Double(40 + (index % 8) * 560)
            let y = Double(40 + (index / 8) * 460)
            let tile = Tile(
                id: UUID(), kind: .managedAgent, title: "agent \(index)",
                frame: TileFrame(x: x, y: y, width: 520, height: 420),
                zPosition: .fromLegacyRank(index + 1), runtimeRef: nil,
                metadata: TileMetadata(launchProfileId: "managed-agent", projectRelativeCwd: "."))
            tiles.append(tile)
        }
        let canvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 0.2), tiles: tiles, groups: [],
            lastActiveTileId: nil))
        canvas.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }

        let delegate = AppDelegate()
        canvas.focusBroker = delegate.focusBroker
        delegate.canvasView = canvas
        delegate.registryStore = RegistryStore(applicationSupportDirectory: appSupport)
        delegate.agentSupervisor = AgentSupervisor(
            store: AgentStore(applicationSupportDirectory: agentsSupport),
            makeRunner: { _ in ScriptedAgentRunner(script: [], holdUntilStopped: true) })
        let supervisor = delegate.agentSupervisor

        var views: [ManagedAgentTileNSView] = []
        for (index, tile) in tiles.enumerated() {
            let view = ManagedAgentTileNSView(tile: tile)
            canvas.install(tileView: view, for: tile)
            let agentId = supervisor.spawn(
                role: nil, prompt: nil, cwd: projectRoot, harness: .claudeCode,
                model: "fixture/file-index-memory", thinking: "medium", tileId: tile.id,
                displayName: "Index witness \(index)")
            delegate.wireManagedAgentTile(tile.id, agentID: agentId)
            views.append(view)
        }
        canvas.layoutSubtreeIfNeeded()
        window.makeKey()

        /// Gives one tile's editor the keyboard, as a press does, and waits for
        /// the index its focus warmed: the query queues behind the warm-up on
        /// the same source, so its answer means the index exists.
        func focusAndAwaitIndex(_ view: ManagedAgentTileNSView) async throws -> [[AgentCompletion]] {
            guard let composer = view.qaComposerForChecks else {
                throw Failure(description: "a tile has no composer")
            }
            // Taken the way a person takes it: a press where the editor is
            // drawn. An idle tile's chrome rests, and the press wakes it.
            guard let drawn = view.qaPresentedRect(of: composer.textView) else {
                throw Failure(description: "the tile does not present its composer's editor")
            }
            let point = view.convert(NSPoint(x: drawn.midX, y: drawn.midY), to: nil)
            func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseUp ? 0 : 1
                ) else { throw Failure(description: "could not make a mouse event") }
                return event
            }
            // The editor tracks its own release with `nextEvent`: queue it first.
            NSApp.postEvent(try mouse(.leftMouseUp), atStart: false)
            window.sendEvent(try mouse(.leftMouseDown))
            _ = await waitUntil(timeout: 0.2, pollInterval: 0.02) { false }
            try expect(window.firstResponder === composer.textView,
                       "a press on the composer gives its editor the keyboard, got \(String(describing: window.firstResponder))")
            try expect(composer.qaPreparedCompletionContext != nil
                           && composer.qaPreparedCompletionContext == view.qaCompletionContext,
                       "taking the keyboard warms the agent's file index, got \(String(describing: composer.qaPreparedCompletionContext))")
            guard let context = view.qaCompletionContext else {
                throw Failure(description: "the tile has no completion context")
            }
            try expect(context.trustState == .trusted, "the fixture checkout is trusted, got \(context.trustState)")
            var batches: [[AgentCompletion]] = []
            for query in queries(context: context) {
                batches.append(await composer.qaCompletionSource.suggestions(for: query)
                    .filter { $0.providerIDs.contains("checkout.files") })
            }
            return batches
        }

        // Settle anything the wiring scheduled before the baseline.
        _ = await waitUntil(timeout: 0.5, pollInterval: 0.1) { false }
        let baselineMalloc = mallocBytesInUse()
        let baselineFootprint = physFootprint()

        let firstBatches = try await focusAndAwaitIndex(views[0])
        _ = await waitUntil(timeout: 0.3, pollInterval: 0.1) { false }
        let oneMalloc = mallocBytesInUse() - baselineMalloc
        let firstDigest = digest(firstBatches, root: projectRoot)
        try expect(firstBatches.allSatisfy { !$0.isEmpty }, "every fixture query returns rows: \(firstBatches.map(\.count))")

        var lastBatches = firstBatches
        for view in views.dropFirst() {
            lastBatches = try await focusAndAwaitIndex(view)
        }
        _ = await waitUntil(timeout: 0.3, pollInterval: 0.1) { false }
        let allMalloc = mallocBytesInUse() - baselineMalloc
        let allFootprint = physFootprint() - baselineFootprint
        let lastDigest = digest(lastBatches, root: projectRoot)

        let report = "\(fileCount) files, \(tileCount) tiles: first index +\(mb(oneMalloc)) malloc, all tiles +\(mb(allMalloc)) malloc (\(mb(allMalloc / tileCount))/tile), footprint +\(mb(allFootprint)); digest \(firstDigest)"
        print("file-index memory: \(report)")

        try expect(firstDigest == lastDigest,
                   "every tile offers the same suggestions: first \(firstDigest), last \(lastDigest)")
        try expect(firstDigest == goldenSuggestionDigest,
                   "suggestions match the pre-fix build exactly: got \(firstDigest), want \(goldenSuggestionDigest)")
        // Before the fix: first index +78 MB, forty tiles +3,041 MB. One
        // checkout must cost about one index, however many tiles use it.
        try expect(allMalloc < oneMalloc * 2,
                   "\(tileCount) tiles on one checkout hold one index, not \(tileCount): \(report)")
        return report
    }
}
