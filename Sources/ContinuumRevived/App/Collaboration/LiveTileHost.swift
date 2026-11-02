import AppKit
import CryptoKit
import WebKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

// The owner's side of a shared note, file, diff, browser or terminal
// (`.plans/105-collaboration/SHARE-KINDS.md`). `SharedAreaHostSession` keeps one
// `LiveTileHost` per `.liveTile` item it hosts; each reads its tile through a
// `LiveTileSource` and publishes what it shows on the item's lane. Input from
// teammates (note edits, browser clicks and scrolls) comes back as events.

/// What one shared tile kind does on its owner's Mac. Everything runs on main.
@MainActor
protocol LiveTileSource: AnyObject {
    var kind: Collaboration.LiveTile.Kind { get }
    /// How often the pump asks for a fresh payload while nothing pushed.
    var interval: Duration { get }
    /// The source calls this when what it shows changed, to publish sooner.
    var onChange: (() -> Void)? { get set }
    /// What the tile shows now. Nil: nothing to publish (yet).
    func payload(eventsThrough: UInt64) async -> Collaboration.LiveTile.Payload?
    /// Events from the lane, every author's, in order. `mine` tells the host's own.
    func receive(_ events: [Collaboration.LiveTile.Event], me: SharedArea.ID<SharedArea.Person>)
    /// Events this source wants appended (the host's own note edits).
    var outbox: [Collaboration.LiveTile.EventBody] { get set }
    func stop()
}

@MainActor
final class LiveTileHost {
    let binding: SharedAreaLocalSourceBinding
    let source: LiveTileSource
    private weak var controller: SharedAreaController?
    private let generation = UUID()
    private var revision: UInt64 = 0
    private var lastPayload: Collaboration.LiveTile.Payload?
    private var lastPublishedAt = Date.distantPast
    private var eventCursor: UInt64?
    private var dirty = true
    private var pump: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var wake: CheckedContinuation<Void, Never>?
    private(set) var publishedCount = 0
    private(set) var receivedEvents = 0
    private(set) var lastError: String?

    init(binding: SharedAreaLocalSourceBinding, source: LiveTileSource, controller: SharedAreaController) {
        self.binding = binding; self.source = source; self.controller = controller
    }

    func start() {
        guard pump == nil else { return }
        source.onChange = { [weak self] in self?.markDirty() }
        pump = Task { [weak self] in
            while let self, !Task.isCancelled {
                // Not connected yet: wait, never spin. `beat` returns without
                // suspending, so a loop that only awaited it would hold main.
                guard await self.beat() else { try? await Task.sleep(for: .milliseconds(500)); continue }
                let interval = self.source.interval
                await self.sleep(interval)
            }
        }
        reader = Task { [weak self] in
            while let self, !Task.isCancelled {
                let wait = await self.readOnce()
                if wait { try? await Task.sleep(for: .seconds(1)) }
            }
        }
    }

    func stop() {
        pump?.cancel(); pump = nil; reader?.cancel(); reader = nil
        wake?.resume(); wake = nil
        source.stop()
    }

    private func markDirty() {
        dirty = true
        wake?.resume(); wake = nil
    }
    private func sleep(_ interval: Duration) async {
        guard !dirty else { return }
        await withCheckedContinuation { continuation in
            wake = continuation
            Task { [weak self] in
                try? await Task.sleep(for: interval)
                self?.wake?.resume(); self?.wake = nil
            }
        }
    }

    /// Flush the host's own events, then publish the state if it changed (or
    /// every 10 s, so a relay that restarted has it again).
    @discardableResult
    private func beat() async -> Bool {
        guard let controller, controller.status == .connected else { return false }
        dirty = false
        while !source.outbox.isEmpty {
            let body = source.outbox[0]
            do { _ = try await controller.appendLiveTileEvent(object: binding.object, body: body); source.outbox.removeFirst() }
            catch { lastError = "\(error)"; break }
        }
        guard let payload = await source.payload(eventsThrough: eventCursor ?? 0) else { return true }
        guard payload != lastPayload || Date().timeIntervalSince(lastPublishedAt) > 10 else { return true }
        revision += 1
        do {
            try await controller.publishLiveTileState(object: binding.object, host: binding.host,
                                                      state: .init(generation: generation, revision: revision, payload: payload))
            lastPayload = payload; lastPublishedAt = Date(); publishedCount += 1; lastError = nil
        } catch {
            lastError = "\(error)"
        }
        return true
    }

    /// Returns true when the read failed and the loop should back off.
    private func readOnce() async -> Bool {
        guard let controller, controller.status == .connected else { return true }
        do {
            let read = try await controller.readLiveTile(object: binding.object, request: .init(
                generation: generation, revision: revision, eventsAfter: eventCursor ?? 0, waitMilliseconds: 20_000))
            if !read.events.isEmpty, let me = Optional(controller.identity.person) {
                receivedEvents += read.events.count
                source.receive(read.events, me: me)
                markDirty()
            }
            // A relay that restarted counts from zero again.
            if let cursor = eventCursor, read.eventHead < cursor { eventCursor = read.eventHead; return false }
            eventCursor = max(eventCursor ?? 0, read.events.last?.sequence ?? read.eventHead)
            return false
        } catch {
            lastError = "\(error)"
            return true
        }
    }
}

// MARK: - Sources

/// A note, edited by everyone with the link. Text merges as a sequence CRDT:
/// both people's keystrokes survive, in the same order on every Mac.
@MainActor
final class NoteLiveSource: LiveTileSource {
    let kind: Collaboration.LiveTile.Kind = .note
    let interval: Duration = .seconds(1)
    var onChange: (() -> Void)?
    var outbox: [Collaboration.LiveTile.EventBody] = []
    private let read: @MainActor () -> String?
    private let write: @MainActor (String) -> Void
    private let title: @MainActor () -> String
    private let stateURL: URL
    private var replica: Collaboration.NoteText.Replica
    private var observer: NSObjectProtocol?
    private var lastText: String

    init(read: @escaping @MainActor () -> String?, write: @escaping @MainActor (String) -> Void,
         title: @escaping @MainActor () -> String, textView: @escaping @MainActor () -> NSTextView?, stateURL: URL, replicaID: String) {
        self.read = read; self.write = write; self.title = title; self.stateURL = stateURL
        let current = read() ?? ""
        // The replica outlives a relaunch: teammates hold its element IDs, so a
        // fresh one made from the text would duplicate every character.
        if let data = try? Data(contentsOf: stateURL),
           let saved = try? JSONDecoder().decode(Collaboration.NoteText.Snapshot.self, from: data) {
            replica = Collaboration.NoteText.Replica(snapshot: saved, replica: replicaID)
        } else {
            replica = Collaboration.NoteText.Replica(replica: replicaID)
        }
        lastText = replica.text
        if current != replica.text { publishLocal(current) }
        observer = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: nil, queue: .main) { [weak self] note in
            let sender = ObjectIdentifier(note.object as AnyObject)
            MainActor.assumeIsolated {
                guard let self, let view = textView(), ObjectIdentifier(view) == sender else { return }
                self.publishLocal(view.string)
            }
        }
    }

    private func publishLocal(_ text: String) {
        guard text != replica.text else { return }
        let ops = replica.edit(to: text)
        lastText = replica.text
        for batch in Collaboration.NoteText.batches(ops, maxBytes: 96 * 1024) { outbox.append(.noteOps(batch)) }
        save()
        onChange?()
    }

    func receive(_ events: [Collaboration.LiveTile.Event], me: SharedArea.ID<SharedArea.Person>) {
        // The host's own events are already in the replica; applying them
        // again is a no-op, so nothing is filtered here.
        var ops: [Collaboration.NoteText.Op] = []
        for event in events { if case .noteOps(let batch) = event.body { ops += batch } }
        guard !ops.isEmpty else { return }
        // Fold in any keystroke not yet seen as a change first.
        if let current = read(), current != replica.text, current != lastText { publishLocal(current) }
        replica.apply(ops)
        guard replica.text != lastText else { return }
        lastText = replica.text
        write(replica.text)
        save()
    }

    func payload(eventsThrough: UInt64) async -> Collaboration.LiveTile.Payload? {
        if let current = read(), current != replica.text, current != lastText { publishLocal(current) }
        return .note(.init(title: title(), snapshot: replica.snapshot, eventsThrough: eventsThrough))
    }

    private func save() {
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(replica.snapshot).write(to: stateURL, options: .atomic)
    }
    func stop() { if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil }
}

/// A file: its text as saved on disk, re-read whenever it changes.
@MainActor
final class FileLiveSource: LiveTileSource {
    let kind: Collaboration.LiveTile.Kind = .file
    let interval: Duration = .milliseconds(700)
    var onChange: (() -> Void)?
    var outbox: [Collaboration.LiveTile.EventBody] = []
    private let url: URL
    private var cached: (modified: Date?, size: Int, payload: Collaboration.LiveTile.Payload)?
    nonisolated static let maxTextBytes = 200 * 1024

    init(url: URL) { self.url = url }

    func payload(eventsThrough: UInt64) async -> Collaboration.LiveTile.Payload? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attributes?[.modificationDate] as? Date
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        if let cached, cached.modified == modified, cached.size == size { return cached.payload }
        let url = self.url
        let payload: Collaboration.LiveTile.Payload = await Task.detached {
            let name = url.lastPathComponent
            guard let data = try? Data(contentsOf: url) else {
                return .file(.init(name: name, language: url.pathExtension, text: nil, digest: "", byteCount: 0,
                                   notice: "The file can't be read on its owner's Mac."))
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard data.count <= Self.maxTextBytes else {
                return .file(.init(name: name, language: url.pathExtension, text: nil, digest: digest, byteCount: data.count,
                                   notice: "Too large to share live (\(data.count / 1024) KB; the limit is \(Self.maxTextBytes / 1024) KB)."))
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return .file(.init(name: name, language: url.pathExtension, text: nil, digest: digest, byteCount: data.count,
                                   notice: "A binary file: only text files are shared live."))
            }
            return .file(.init(name: name, language: url.pathExtension, text: text, digest: digest, byteCount: data.count, notice: nil))
        }.value
        cached = (modified, size, payload)
        return payload
    }
    func receive(_ events: [Collaboration.LiveTile.Event], me: SharedArea.ID<SharedArea.Person>) {}
    func stop() {}
}

/// A diff: the same git diff the tile shows, re-read every two seconds and
/// re-published only when it changed.
@MainActor
final class DiffLiveSource: LiveTileSource {
    let kind: Collaboration.LiveTile.Kind = .diff
    let interval: Duration = .seconds(2)
    var onChange: (() -> Void)?
    var outbox: [Collaboration.LiveTile.EventBody] = []
    private let root: URL
    private let source: DiffReviewSource
    private let title: String
    nonisolated static let maxDiffBytes = 200 * 1024

    init(root: URL, source: DiffReviewSource, title: String) { self.root = root; self.source = source; self.title = title }

    func payload(eventsThrough: UInt64) async -> Collaboration.LiveTile.Payload? {
        let root = root, source = source, title = title
        return await Task.detached { () -> Collaboration.LiveTile.Payload in
            let arguments: [String]
            switch source.kind {
            case .workingTreeVsHEAD: arguments = ["diff", "--no-color", "--no-ext-diff", "HEAD"]
            case .branchVsBase, .worktreeVsBase: arguments = ["diff", "--no-color", "--no-ext-diff", (source.baseBranch ?? "main") + "...HEAD"]
            }
            let output = Self.git(arguments, root: root) ?? ""
            var text = output
            var truncated = false
            if text.utf8.count > Self.maxDiffBytes {
                text = String(decoding: Array(text.utf8.prefix(Self.maxDiffBytes)), as: UTF8.self)
                truncated = true
            }
            let files = output.split(separator: "\n").filter { $0.hasPrefix("diff --git ") }.count
            let digest = SHA256.hash(data: Data(output.utf8)).map { String(format: "%02x", $0) }.joined()
            return .diff(.init(title: title, diff: text, digest: digest, files: files, truncated: truncated))
        }.value
    }
    nonisolated static func git(_ arguments: [String], root: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
    func receive(_ events: [Collaboration.LiveTile.Event], me: SharedArea.ID<SharedArea.Person>) {}
    func stop() {}
}

/// A terminal: a read-only mirror of what it shows. Nothing typed elsewhere
/// ever reaches it; the relay refuses input to a terminal outright.
@MainActor
final class TerminalLiveSource: LiveTileSource {
    let kind: Collaboration.LiveTile.Kind = .terminal
    let interval: Duration = .milliseconds(500)
    var onChange: (() -> Void)?
    var outbox: [Collaboration.LiveTile.EventBody] = []
    private let text: @MainActor () -> String?
    private let title: @MainActor () -> String
    static let maxTextBytes = 64 * 1024

    init(text: @escaping @MainActor () -> String?, title: @escaping @MainActor () -> String) { self.text = text; self.title = title }

    func payload(eventsThrough: UInt64) async -> Collaboration.LiveTile.Payload? {
        guard var value = text() else { return nil }
        if value.utf8.count > Self.maxTextBytes { value = String(value.suffix(Self.maxTextBytes / 2)) }
        let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
        return .terminal(.init(title: title(), text: value, columns: lines.map(\.count).max() ?? 0, rows: lines.count))
    }
    func receive(_ events: [Collaboration.LiveTile.Event], me: SharedArea.ID<SharedArea.Person>) {}
    func stop() {}
}

/// A browser: its URL and title always, and a picture of the page at most
/// eight times a second while it is on screen and changing. A teammate's click
/// or scroll lands on this page.
@MainActor
final class BrowserLiveSource: LiveTileSource {
    let kind: Collaboration.LiveTile.Kind = .browser
    let interval: Duration = .milliseconds(125)
    var onChange: (() -> Void)?
    var outbox: [Collaboration.LiveTile.EventBody] = []
    private let webView: @MainActor () -> WKWebView?
    private let address: @MainActor () -> String
    private let title: @MainActor () -> String
    private var frame: Collaboration.LiveTile.Frame?
    private var lastDigest = ""
    private var sequence: UInt64 = 0
    private var capturing = false
    private var lastCapture = Date.distantPast
    /// Clicks and scrolls that reached the page, for the witness.
    private(set) var appliedInput: [Collaboration.LiveTile.EventBody] = []
    static let maxFrameBytes = 180 * 1024
    static let minimumFrameInterval: TimeInterval = 0.12

    init(webView: @escaping @MainActor () -> WKWebView?, address: @escaping @MainActor () -> String, title: @escaping @MainActor () -> String) {
        self.webView = webView; self.address = address; self.title = title
    }

    func payload(eventsThrough: UInt64) async -> Collaboration.LiveTile.Payload? {
        let urlString = address()
        let url = URL(string: urlString)
        let reach: Collaboration.LiveTile.Reach = Collaboration.LiveTile.isPrivateAddress(url) ? .private : .public
        await captureIfDue()
        return .browser(.init(url: urlString.isEmpty ? nil : urlString, title: title(), reach: reach, frame: frame))
    }

    /// A WebKit snapshot, only while the page is in a window and visible, and
    /// only when it changed. JPEG, scaled and re-compressed under the cap.
    private func captureIfDue() async {
        guard !capturing, Date().timeIntervalSince(lastCapture) >= Self.minimumFrameInterval,
              let webView = webView(), webView.window != nil, !webView.isHiddenOrHasHiddenAncestor,
              webView.bounds.width > 1, webView.bounds.height > 1 else { return }
        capturing = true; defer { capturing = false }
        lastCapture = Date()
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        configuration.snapshotWidth = NSNumber(value: Double(min(webView.bounds.width, 1280)))
        guard let image = try? await webView.takeSnapshot(configuration: configuration),
              let jpeg = Self.jpeg(image, maxBytes: Self.maxFrameBytes) else { return }
        let digest = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
        guard digest != lastDigest else { return }
        lastDigest = digest; sequence += 1
        frame = .init(jpeg: jpeg, width: Double(webView.bounds.width), height: Double(webView.bounds.height), sequence: sequence)
    }

    static func jpeg(_ image: NSImage, maxBytes: Int) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        for quality in [0.7, 0.5, 0.35, 0.2] {
            if let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]), data.count <= maxBytes { return data }
        }
        return nil
    }

    func receive(_ events: [Collaboration.LiveTile.Event], me: SharedArea.ID<SharedArea.Person>) {
        guard let webView = webView() else { return }
        for event in events where event.author != me {
            switch event.body {
            case .browserClick(let x, let y):
                appliedInput.append(event.body)
                webView.evaluateJavaScript(Self.clickScript(x: x, y: y), completionHandler: nil)
            case .browserScroll(let dx, let dy):
                appliedInput.append(event.body)
                webView.evaluateJavaScript("window.scrollBy(\(dx), \(dy));", completionHandler: nil)
            case .noteOps: break
            }
        }
        lastCapture = .distantPast
        onChange?()
    }

    /// The same events a real click makes, at that point of the page.
    static func clickScript(x: Double, y: Double) -> String {
        """
        (function(x, y) {
          var target = document.elementFromPoint(x, y);
          if (!target) { return 'none'; }
          var options = { bubbles: true, cancelable: true, view: window, clientX: x, clientY: y, button: 0 };
          target.dispatchEvent(new PointerEvent('pointerdown', options));
          target.dispatchEvent(new MouseEvent('mousedown', options));
          if (target.focus) { target.focus(); }
          target.dispatchEvent(new PointerEvent('pointerup', options));
          target.dispatchEvent(new MouseEvent('mouseup', options));
          target.dispatchEvent(new MouseEvent('click', options));
          return target.tagName;
        })(\(x), \(y));
        """
    }
    func stop() {}
}
