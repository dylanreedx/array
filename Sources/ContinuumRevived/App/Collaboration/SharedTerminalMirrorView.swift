import AppKit
import GhosttyKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

/// A teammate's terminal, drawn here by a real Ghostty surface fed the bytes
/// their terminal wrote (`.plans/114-terminal-sharing`). Nothing runs here but
/// a pipe: the surface's process copies the host's output to its terminal and
/// discards whatever the terminal answers, so this Mac's shell, prompt,
/// aliases and environment never touch it. It draws in the host's colours, at
/// the host's grid (columns by rows), scaled to fit the tile; it scrolls back
/// over what streamed since it joined; it takes no typing.
///
/// Frames come from both lanes into one `TerminalStreamFollower`: the stream
/// lane as they are cut, and the state lane's screen when this view starts,
/// falls behind or the stream lane is not there.
@MainActor
final class SharedTerminalMirrorView: NSView {
    private var follower = TerminalStreamFollower()
    private let box = TerminalMirrorBox()
    private let shield = TerminalMirrorShield()
    private var terminal: GhosttyTerminalView?
    private var feed: TerminalMirrorFeed?
    private(set) var columns = 0, rows = 0
    private(set) var palette: Collaboration.LiveTile.TerminalPalette?
    private var natural = NSSize.zero
    private weak var controller: SharedAreaController?
    private var object: SharedArea.ID<SharedArea.Object>?
    private var laneTask: Task<Void, Never>?
    private var lastStateRead = Date.distantPast
    private var teardown: Task<Void, Never>?
    private var surfaceEnded = false

    // Facts, for the journey and the render check.
    private(set) var framesApplied = 0
    private(set) var resets = 0
    private(set) var bytesApplied = 0
    private(set) var laneFrames = 0
    private(set) var laneState = "off"
    private(set) var updates: UInt64 = 0
    /// Host read to here applied, per output frame, in ms (same Mac's clock in
    /// the journey; across Macs it includes their clock difference).
    private(set) var recentDelays: [Double] = []
    /// The newest frames and screens, for the journey: what arrived, how, when.
    private(set) var log: [String] = []
    func note(_ event: String) {
        log.append(String(format: "%.3f ", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)) + event)
        if log.count > 80 { log.removeFirst(log.count - 80) }
    }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        addSubview(box)
        addSubview(shield)
        shield.onScroll = { [weak self] event in self?.terminal?.scrollWheel(with: event) }
        setAccessibilityElement(true); setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Lanes

    /// The state lane's screen.
    func take(_ screen: Collaboration.LiveTile.TerminalScreen) {
        note("state screen base \(screen.base.sequence) \(screen.base.kind) +\(screen.output.count) (at \(follower.sequence))")
        apply(follower.take(screen))
    }

    /// Opens the stream lane as a watcher. A relay without it leaves the
    /// state lane to carry everything.
    func attach(controller: SharedAreaController, object: SharedArea.ID<SharedArea.Object>) {
        if self.controller === controller, self.object == object, laneTask != nil { return }
        laneTask?.cancel()
        self.controller = controller; self.object = object
        laneTask = Task { [weak self] in
            var backoff = 1.0
            while !Task.isCancelled {
                guard let self, let controller = self.controller, let object = self.object else { return }
                if controller.status != .connected { try? await Task.sleep(for: .milliseconds(500)); continue }
                do {
                    self.laneState = "connecting"
                    let lane = try await controller.openTileStream(object: object)
                    self.laneState = "open"; backoff = 1
                    for await message in lane.messages {
                        guard let frame = message.frame else { continue }
                        self.laneFrames += 1
                        self.take(frame)
                    }
                    await lane.close()
                    self.laneState = "closed"; self.note("lane closed")
                } catch CollaborationClientError.server(let status, _) where status == 404 || status == 501 {
                    self.laneState = "refused"
                    return
                } catch {
                    self.laneState = "failed"; self.note("lane failed: \(error)")
                }
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 15)
            }
        }
    }

    func take(_ frame: Collaboration.LiveTile.TerminalFrame) {
        if frame.kind != .output { note("lane \(frame.kind) \(frame.sequence) (at \(follower.sequence))") }
        apply(follower.take(frame))
        if follower.isWaiting { readState() }
        if frame.kind == .output, let sent = frame.sentAt {
            recentDelays.append((Date().timeIntervalSince1970 - sent) * 1000)
            if recentDelays.count > 512 { recentDelays.removeFirst(recentDelays.count - 512) }
        }
    }

    func stop() {
        laneTask?.cancel(); laneTask = nil
    }

    /// Behind, with a gap the stream will not fill: the state lane's screen
    /// brings this view up to date. At most twice a second.
    private func readState() {
        guard Date().timeIntervalSince(lastStateRead) > 0.5, let controller, let object else { return }
        lastStateRead = Date()
        Task { [weak self] in
            let read = try? await controller.readLiveTile(object: object, request: .init(generation: nil, revision: nil, eventsAfter: nil, waitMilliseconds: 0))
            guard case .terminal(let terminal)? = read?.state?.payload, let screen = terminal.screen else { return }
            self?.take(screen)
        }
    }

    /// Ends the surface and its pipe; the next screen starts a new one.
    func tearDown() {
        stop()
        feed?.close(); feed = nil
        terminal?.requestClose(force: true)
        terminal?.removeFromSuperview(); terminal = nil
        follower = TerminalStreamFollower()
    }

    /// Out of the window for good (the tile closed): the surface is freed. A
    /// short absence (a workspace switch, parking) keeps it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        teardown?.cancel(); teardown = nil
        if window == nil, terminal != nil {
            teardown = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled, self.window == nil else { return }
                self.tearDown()
            }
        } else if window != nil, follower.isWaiting {
            readState()
        }
    }

    // MARK: Drawing

    private func apply(_ steps: [TerminalStreamFollower.Step]) {
        guard !steps.isEmpty else { return }
        if surfaceEnded {
            // The surface's pipe ended under it: start over on a new one.
            surfaceEnded = false
            feed?.close(); feed = nil; terminal?.removeFromSuperview(); terminal = nil
            follower = TerminalStreamFollower()
            readState()
            return
        }
        for step in steps {
            switch step {
            case .write(let bytes):
                ensureSurface()
                feed?.write(bytes)
                framesApplied += 1; bytesApplied += bytes.count
            case .reset(let frame):
                if frame.columns != columns || frame.rows != rows { columns = frame.columns; rows = frame.rows; resize() }
                if let colours = frame.palette, colours != palette { palette = colours; needsDisplay = true }
                ensureSurface()
                // Start over: a full reset, the host's colours, then the screen.
                feed?.write(Data("\u{1b}c".utf8) + Self.paletteBytes(palette) + frame.bytes)
                resets += 1; framesApplied += 1; bytesApplied += frame.bytes.count
            }
        }
        updates &+= 1
    }

    static func paletteBytes(_ palette: Collaboration.LiveTile.TerminalPalette?) -> Data {
        guard let palette else { return Data() }
        func spec(_ hex: String) -> String? {
            let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            guard value.count == 6, value.allSatisfy(\.isHexDigit) else { return nil }
            let chars = Array(value.lowercased())
            return "rgb:\(String(chars[0...1]))/\(String(chars[2...3]))/\(String(chars[4...5]))"
        }
        var out = ""
        for (index, hex) in palette.colors.prefix(16).enumerated() { if let value = spec(hex) { out += "\u{1b}]4;\(index);\(value)\u{1b}\\" } }
        if let value = palette.foreground.flatMap(spec) { out += "\u{1b}]10;\(value)\u{1b}\\" }
        if let value = palette.background.flatMap(spec) { out += "\u{1b}]11;\(value)\u{1b}\\" }
        if let value = palette.cursor.flatMap(spec) { out += "\u{1b}]12;\(value)\u{1b}\\" }
        return Data(out.utf8)
    }

    private func ensureSurface() {
        guard terminal == nil, window != nil, let context = GhosttyRuntimeContext.current, let app = try? context.app else { return }
        let feed = TerminalMirrorFeed()
        guard let path = feed.path else { return }
        self.feed = feed
        // `env -i`: nothing of this Mac's environment; bash with no profile or
        // rc: nothing of its configuration. The background `cat` drains what
        // the terminal answers (it would otherwise fill the pty and stall it).
        let script = "stty raw -echo 2>/dev/null; exec 3<&0; /bin/cat <&3 >/dev/null & exec /bin/cat \"$0\""
        let profile = LaunchProfile(command: "/usr/bin/env",
                                    arguments: ["-i", "PATH=/usr/bin:/bin", "/bin/bash", "--noprofile", "--norc", "-c", script, path],
                                    cwd: NSTemporaryDirectory(), title: "Shared terminal")
        let view = GhosttyTerminalView(ghosttyApp: app, launchProfile: profile) { [weak self] status in
            if case .exited = status { self?.surfaceEnded = true }
        }
        terminal = view
        box.addSubview(view)
        view.frame = NSRect(origin: .zero, size: natural == .zero ? NSSize(width: 640, height: 400) : natural)
        view.setGhosttyFocus(true)
        view.setSnapshotOccluded(false)
        resize()
    }

    /// The surface at the host's grid, in this Mac's font: Ghostty is asked
    /// for its cell size, and the surface is sized to exactly `columns` by
    /// `rows` cells plus its padding.
    private func resize() {
        guard let terminal, let surface = terminal.surface, columns > 0, rows > 0 else { needsLayout = true; return }
        let scale = window?.backingScaleFactor ?? 2
        var size = ghostty_surface_size(surface)
        if size.cell_width_px == 0 || size.cell_height_px == 0 {
            // Not measured yet: give it a size and ask again.
            terminal.setSurfacePixelSize(CGSize(width: 1280, height: 800))
            size = ghostty_surface_size(surface)
            guard size.cell_width_px > 0, size.cell_height_px > 0 else { return }
        }
        // Padding and remainder, as the surface has them now.
        let extraX = Int(size.width_px) - Int(size.columns) * Int(size.cell_width_px)
        let extraY = Int(size.height_px) - Int(size.rows) * Int(size.cell_height_px)
        let width = CGFloat(columns * Int(size.cell_width_px) + max(0, extraX))
        let height = CGFloat(rows * Int(size.cell_height_px) + max(0, extraY))
        natural = NSSize(width: width / scale, height: height / scale)
        terminal.frame = NSRect(origin: .zero, size: natural)
        terminal.setSurfacePixelSize(CGSize(width: width, height: height))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        shield.frame = bounds
        guard natural.width > 0, natural.height > 0, bounds.width > 0, bounds.height > 0 else { box.frame = bounds; return }
        // Fitted, never cropped; letterboxed in the host's background.
        let fit = min(bounds.width / natural.width, bounds.height / natural.height)
        let size = NSSize(width: natural.width * fit, height: natural.height * fit)
        box.frame = NSRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: size.height)
        box.bounds = NSRect(origin: .zero, size: natural)
    }

    override func draw(_ dirtyRect: NSRect) {
        hostBackground.setFill()
        bounds.fill()
    }

    /// The host's background, else Array's tile body.
    var hostBackground: NSColor {
        // The host's Ghostty palette, read the way Array reads its own.
        palette?.background.flatMap(GhosttyThemeSnapshot.color(hex:)) ?? SurfaceToken.tileBody.color.nsColor(in: self)
    }

    // MARK: QA

    var qaTerminalView: GhosttyTerminalView? { terminal }
    var qaScreenText: String { terminal?.visibleText() ?? "" }
    /// The screen row by row (a rectangle, so a soft-wrapped line stays on
    /// its rows), as tmux's own capture of the host's pane has it.
    var qaScreenRows: String {
        guard let surface = terminal?.surface else { return "" }
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: true)
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }
    /// Everything the surface holds: the scrollback, then the screen.
    var qaScrollbackText: String {
        guard let surface = terminal?.surface else { return "" }
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_SCREEN, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, selection, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }
    var qaGrid: (columns: Int, rows: Int)? {
        guard let surface = terminal?.surface else { return nil }
        let size = ghostty_surface_size(surface)
        return (Int(size.columns), Int(size.rows))
    }
    var qaFollowerSequence: UInt64 { follower.sequence }
    var qaGaps: Int { follower.gaps }
    var qaBoxFrame: NSRect { box.frame }
}

/// Holds the surface at its natural size; its bounds scale it to fit.
@MainActor
final class TerminalMirrorBox: NSView {
    override var isFlipped: Bool { true }
}

/// Over the surface: a click, a drag or a key goes nowhere, so nothing is
/// typed or selected into the stream. A scroll scrolls back.
@MainActor
final class TerminalMirrorShield: NSView {
    var onScroll: ((NSEvent) -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) { onScroll?(event) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

/// The pipe into the surface's process: a FIFO in a private folder, written
/// in order on a queue of its own, so a slow surface never stalls the app.
final class TerminalMirrorFeed: @unchecked Sendable {
    let path: String?
    private let folder: URL?
    private let queue = DispatchQueue(label: "dev.arrayapp.terminal-mirror-feed")
    private var descriptor: Int32 = -1
    private var closed = false

    init() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("array-mirror-\(UUID().uuidString.prefix(8))")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let fifo = folder.appendingPathComponent("feed").path
            guard mkfifo(fifo, 0o600) == 0 else { throw CocoaError(.fileWriteUnknown) }
            self.folder = folder; path = fifo
        } catch {
            self.folder = nil; path = nil
        }
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            guard !closed, openIfNeeded() else { return }
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 { if errno == EINTR { continue }; closeNow(); return }
                    offset += written
                }
            }
        }
    }

    /// The reader opens the FIFO when the surface's process starts; until
    /// then a writer cannot. Waits up to five seconds for it.
    private func openIfNeeded() -> Bool {
        if descriptor >= 0 { return true }
        guard let path else { return false }
        for _ in 0..<500 {
            let fd = open(path, O_WRONLY | O_NONBLOCK)
            if fd >= 0 {
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
                _ = fcntl(fd, F_SETNOSIGPIPE, 1)
                descriptor = fd
                return true
            }
            if closed { return false }
            usleep(10_000)
        }
        return false
    }

    func close() { queue.async { [self] in closed = true; closeNow() } }

    private func closeNow() {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
}

/// "Dylan's Terminal · zsh": a shared terminal is named for whose it is, then
/// the host tile's own title.
enum SharedTerminalTitle {
    static func title(hostName: String, hostTitle: String) -> String {
        let own = hostTitle.trimmingCharacters(in: .whitespaces)
        return "\(hostName)'s Terminal" + (own.isEmpty || own == "Terminal" ? "" : " · \(own)")
    }
}
