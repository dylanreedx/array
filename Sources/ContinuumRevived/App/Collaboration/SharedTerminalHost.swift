import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

/// A shared terminal on its owner's Mac (`.plans/114-terminal-sharing`).
///
/// The guest never runs anything, so the guest's configuration never matters:
/// the host's shell, prompt, aliases and environment make the output here, and
/// what travels is that output. The tap (`TerminalTmuxTap`) reads the bytes
/// the tile's tmux pane wrote; this source cuts them into frames: output at
/// most sixty times a second, the whole screen when a viewer must start over
/// (a new size, a flood it skipped), and the whole screen with some history
/// for a viewer that joins late. Frames go out on the tile's stream lane the
/// moment they are cut; the state lane carries the newest screen and the
/// output after it, for a relay without the stream lane.
///
/// Nothing is sent before the share's opt-in (this source exists only once the
/// tile is shared), and the environment never is: only what the pane drew.
/// A terminal not in local tmux falls back to its visible text, as before.
@MainActor
final class TerminalLiveSource: LiveTileSource {
    let kind: Collaboration.LiveTile.Kind = .terminal
    /// The state lane: every 100 ms while it is the only lane; once a second
    /// beside the stream lane, which carries the output.
    var interval: Duration { laneOpen ? .milliseconds(1000) : .milliseconds(100) }
    var onChange: (() -> Void)?
    var outbox: [Collaboration.LiveTile.EventBody] = []
    private let text: @MainActor () -> String?
    private let title: @MainActor () -> String
    private let palette: Collaboration.LiveTile.TerminalPalette?
    private let tapTarget: @MainActor () -> (tmux: String, tile: UUID)?

    static let maxTextBytes = 64 * 1024
    /// Output frames a second, at most.
    static let frameInterval: TimeInterval = 1.0 / 60
    /// Over this many bytes a second, output is skipped and the viewers are
    /// sent the screen instead, at most five times a second.
    static let floodBytesPerSecond = 256 * 1024
    static let floodFrameBytes = 64 * 1024
    static let floodScreenInterval: TimeInterval = 0.2
    /// Output after the newest screen that the state lane carries before the
    /// host sends a fresh one (and the relay's replay restarts from it).
    static let checkpointBytes = 64 * 1024
    static let historyLines = 400
    static let historyBytes = 32 * 1024

    private enum Purpose: Int { case keyframe = 1, checkpoint = 2 }

    // Stream
    private var tap: TerminalTmuxTap?
    private var tapRetry: Task<Void, Never>?
    /// Looking for the tile's pane, off the main thread.
    private var locating: Task<Void, Never>?
    /// After tmux left a lookup unanswered, the next try waits this long.
    static let unresponsiveRetry: Duration = .seconds(10)
    private var stream = UUID()
    private var sequence: UInt64 = 0
    private var columns = 0, rows = 0
    private var base: Collaboration.LiveTile.TerminalFrame?
    private var sinceBase: [Collaboration.LiveTile.TerminalFrame] = []
    private var sinceBaseBytes = 0
    private var pending = Data()
    private var pendingReadAt: Double?
    private var lastFrameAt = Date.distantPast
    private var flushTask: Task<Void, Never>?
    private var screenRequested: Purpose?
    private var flooding = false
    /// Output is skipped from a flood's start until the screen that settles it.
    private var skipping = false
    private var lastFloodScreen = Date.distantPast
    private var recent: [(at: Date, bytes: Int)] = []

    // Lane
    private weak var controller: SharedAreaController?
    private var object: SharedArea.ID<SharedArea.Object>?
    private var lane: (any SharedAreaTileStream)?
    private var laneTask: Task<Void, Never>?
    private var laneOpen = false
    private var laneRefused = false
    private var sends: AsyncStream<Collaboration.LiveTile.TerminalFrame>.Continuation?

    // Facts, for the journey.
    private(set) var bytesRead = 0
    private(set) var bytesSent = 0
    private(set) var framesSent = 0
    private(set) var screensSent = 0
    private(set) var skippedBytes = 0
    private(set) var tapState = "off"
    /// The newest stream events, for the journey: what happened and when.
    private(set) var log: [String] = []
    private func note(_ event: String) {
        log.append(String(format: "%.3f ", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)) + event)
        if log.count > 80 { log.removeFirst(log.count - 80) }
    }

    init(text: @escaping @MainActor () -> String?, title: @escaping @MainActor () -> String,
         palette: Collaboration.LiveTile.TerminalPalette?, tapTarget: @escaping @MainActor () -> (tmux: String, tile: UUID)?) {
        self.text = text; self.title = title; self.palette = palette; self.tapTarget = tapTarget
    }

    var facts: [String: Any] {
        ["streamTap": tapState, "streamLane": laneOpen ? "open" : (laneRefused ? "refused" : "closed"), "streamBytesRead": bytesRead,
         "streamBytesSent": bytesSent, "streamFrames": framesSent, "streamScreens": screensSent, "streamSkippedBytes": skippedBytes,
         "streamSequence": Int(sequence), "streamGrid": "\(columns)x\(rows)", "streamLog": log]
    }

    // MARK: LiveTileSource

    func connect(controller: SharedAreaController, object: SharedArea.ID<SharedArea.Object>) {
        self.controller = controller; self.object = object
        startTap()
        openLane()
    }

    func payload(eventsThrough: UInt64) async -> Collaboration.LiveTile.Payload? {
        guard var value = text() else { return nil }
        let screen = base.map { Collaboration.LiveTile.TerminalScreen(base: $0, output: sinceBase) }
        // Beside a stream, the text is only for a viewer that cannot draw one.
        let cap = screen == nil ? Self.maxTextBytes : 16 * 1024
        if value.utf8.count > cap { value = String(value.suffix(cap / 2)) }
        if let screen {
            return .terminal(.init(title: title(), text: value, columns: screen.base.columns, rows: screen.base.rows, screen: screen))
        }
        let lines = value.split(separator: "\n", omittingEmptySubsequences: false)
        return .terminal(.init(title: title(), text: value, columns: lines.map(\.count).max() ?? 0, rows: lines.count))
    }

    func receive(_ events: [Collaboration.LiveTile.Event], me: SharedArea.ID<SharedArea.Person>) {}

    func stop() {
        tapRetry?.cancel(); tapRetry = nil
        locating?.cancel(); locating = nil
        tap?.stop(); tap = nil
        flushTask?.cancel(); flushTask = nil
        sends?.finish(); sends = nil
        laneTask?.cancel(); laneTask = nil
        if let lane { Task { await lane.close() } }
        lane = nil; laneOpen = false
    }

    // MARK: Tap

    /// Finds the tile's pane off the main thread, then attaches the tap. A
    /// tmux that doesn't answer never holds the app: the share carries the
    /// visible text meanwhile, and tries again shortly.
    private func startTap() {
        guard tap == nil, locating == nil else { return }
        guard let target = tapTarget() else { tapState = "no tmux"; return }
        tapState = "locating"
        locating = Task { [weak self] in
            let location = await TerminalTmuxTap.locate(tileID: target.tile, tmuxPath: target.tmux)
            guard !Task.isCancelled, let self else { return }
            self.locating = nil
            self.attachTap(location, tmux: target.tmux)
        }
    }

    private func attachTap(_ location: TerminalTmuxTap.Location, tmux: String) {
        guard tap == nil else { return }
        let located: (session: String, pane: String)
        switch location {
        case .found(let session, let pane): located = (session, pane)
        case .notInTmux: tapState = "no pane"; return
        case .unresponsive:
            tapState = "tmux not answering"
            note("tmux did not answer; streaming the visible text until it does")
            fputs("terminal share: tmux did not answer within \(Int(TerminalTmuxTap.locateDeadline)) s; showing the visible text until it does\n", stderr)
            tapRetry = Task { [weak self] in
                try? await Task.sleep(for: Self.unresponsiveRetry)
                guard !Task.isCancelled else { return }
                self?.startTap()
            }
            return
        }
        do {
            tap = try TerminalTmuxTap(tmuxPath: tmux, session: located.session, pane: located.pane) { events in
                DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.handle(events) } }
            }
        } catch {
            tapState = "failed: \(error)"; return
        }
        tapState = "on"
        // A new run: viewers start over from its first screen.
        stream = UUID(); sequence = 0; base = nil; sinceBase = []; sinceBaseBytes = 0; pending = Data(); screenRequested = nil
        requestScreen(.keyframe)
    }

    private func handle(_ events: [TerminalTmuxTap.Event]) {
        for event in events {
            switch event {
            case .output(let data, let readAt):
                bytesRead += data.count
                // Before the first screen there is nothing to follow on from.
                guard base != nil || screenRequested != nil else { continue }
                record(data.count)
                if skipping || base == nil { skippedBytes += data.count; continue }
                pending.append(data); pendingReadAt = readAt
                if pending.count > Self.floodFrameBytes || recentBytes() > Self.floodBytesPerSecond { startFlood() } else { scheduleFlush() }
            case .screen(let screen, let purpose):
                takeScreen(screen, purpose: Purpose(rawValue: purpose) ?? .keyframe)
            case .layoutChanged:
                requestScreen(.keyframe)
            case .ended(let reason):
                tap = nil; tapState = "ended: \(reason)"
                base = nil; sinceBase = []; onChange?()
                // The session may come back (a restart); look again shortly.
                tapRetry = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    self?.startTap()
                }
            }
        }
    }

    private func record(_ bytes: Int) {
        let now = Date()
        recent.append((now, bytes))
        recent.removeAll { now.timeIntervalSince($0.at) > 1 }
    }
    private func recentBytes() -> Int { recent.reduce(0) { $0 + $1.bytes } }

    /// A flood: what the program writes now is skipped, and the viewers get
    /// the screen as it stands, five times a second, until it calms.
    private func startFlood() {
        skippedBytes += pending.count
        pending = Data(); pendingReadAt = nil
        flushTask?.cancel(); flushTask = nil
        skipping = true
        if !flooding { flooding = true; note("flood starts"); floodWatch() }
        if Date().timeIntervalSince(lastFloodScreen) >= Self.floodScreenInterval { requestScreen(.keyframe) }
    }

    private func floodWatch() {
        Task { [weak self] in
            while let self, self.flooding {
                try? await Task.sleep(for: .milliseconds(Int(Self.floodScreenInterval * 1000)))
                let calm = self.recent.filter { Date().timeIntervalSince($0.at) <= 0.25 }.reduce(0) { $0 + $1.bytes } < Self.floodBytesPerSecond / 8
                if calm { self.flooding = false; self.note("flood calm") }
                // The screen as it stands; when calm, the one that settles it.
                self.requestScreen(.keyframe)
            }
        }
    }

    private func requestScreen(_ purpose: Purpose) {
        guard let tap else { return }
        if let requested = screenRequested, requested == .keyframe || purpose == .checkpoint { return }
        screenRequested = purpose
        note("screen requested \(purpose)")
        if purpose == .keyframe, flooding { lastFloodScreen = Date() }
        tap.requestScreen(purpose: purpose.rawValue, history: purpose == .checkpoint || base == nil ? Self.historyLines : 0)
    }

    private func takeScreen(_ screen: TerminalTmuxTap.Screen, purpose: Purpose) {
        screenRequested = nil
        note("screen received \(purpose) skipping=\(skipping) flooding=\(flooding) read=\(bytesRead)")
        // Everything read before the capture is in it.
        if skipping || base == nil { pending = Data() } else { flushNow() }
        // Asked for once the flood calmed: output follows on from here again.
        if !flooding { skipping = false }
        columns = screen.columns; rows = screen.rows
        // The first screen of a run and a checkpoint carry history, so a viewer
        // who starts from one can scroll back over it.
        let withHistory = purpose == .checkpoint || base == nil
        let bytes = Self.vt(screen, history: withHistory)
        let kind: Collaboration.LiveTile.TerminalFrame.Kind = purpose == .checkpoint && base != nil ? .checkpoint : .keyframe
        if kind == .keyframe { sequence += 1 }
        let frame = Collaboration.LiveTile.TerminalFrame(stream: stream, sequence: sequence, kind: kind, columns: columns, rows: rows,
                                                        bytes: bytes, palette: palette, sentAt: Date().timeIntervalSince1970)
        base = frame; sinceBase = []; sinceBaseBytes = 0
        screensSent += 1
        send(frame)
        onChange?()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        let wait = max(0, Self.frameInterval - Date().timeIntervalSince(lastFrameAt))
        if wait == 0 { flushNow(); return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(ceil(wait * 1000))))
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            self.flushNow()
        }
    }

    private func flushNow() {
        flushTask?.cancel(); flushTask = nil
        guard !pending.isEmpty, base != nil else { return }
        sequence += 1
        let frame = Collaboration.LiveTile.TerminalFrame(stream: stream, sequence: sequence, kind: .output, columns: columns, rows: rows,
                                                        bytes: pending, sentAt: pendingReadAt)
        pending = Data(); pendingReadAt = nil
        lastFrameAt = Date()
        sinceBase.append(frame); sinceBaseBytes += frame.bytes.count
        send(frame)
        if sinceBaseBytes > Self.checkpointBytes { requestScreen(.checkpoint) }
    }

    // MARK: Lane

    /// Out on the stream lane when it is open; on the state lane either way.
    private func send(_ frame: Collaboration.LiveTile.TerminalFrame) {
        framesSent += 1; bytesSent += frame.bytes.count
        if laneOpen { sends?.yield(frame) }
    }

    private func openLane() {
        guard laneTask == nil else { return }
        laneTask = Task { [weak self] in
            var backoff = 1.0
            while !Task.isCancelled {
                guard let self, let controller = self.controller, let object = self.object else { return }
                if controller.status != .connected { try? await Task.sleep(for: .milliseconds(500)); continue }
                do {
                    let lane = try await controller.openTileStream(object: object)
                    backoff = 1
                    await self.run(lane)
                } catch CollaborationClientError.server(let status, _) where status == 404 || status == 501 {
                    // A relay without the lane: the state lane carries it all.
                    self.laneRefused = true
                    return
                } catch {}
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 15)
            }
        }
    }

    private func run(_ lane: any SharedAreaTileStream) async {
        self.lane = lane; laneOpen = true
        let (frames, continuation) = AsyncStream<Collaboration.LiveTile.TerminalFrame>.makeStream(bufferingPolicy: .unbounded)
        sends = continuation
        // The relay's replay starts from a screen.
        if base != nil { requestScreen(.checkpoint) }
        // One sender keeps the frames in order; the lane's end (either way)
        // ends both.
        let sender = Task {
            for await frame in frames { do { try await lane.send(frame) } catch { return } }
        }
        for await message in lane.messages where message.resync == true { requestScreen(.keyframe) }
        sender.cancel()
        continuation.finish()
        sends = nil; laneOpen = false; self.lane = nil
        await lane.close()
    }

    // MARK: The screen as VT

    /// Bytes that draw `screen` from a soft reset: the history (which scrolls
    /// into the viewer's scrollback), the screen, the alternate screen over
    /// the normal one, then the cursor and the modes that change where the
    /// next byte lands. A viewer starting over resets first and applies the
    /// palette; one in step just redraws.
    static func vt(_ screen: TerminalTmuxTap.Screen, history: Bool) -> Data {
        let esc = "\u{1b}["
        var out = "\u{1b}[?1049l\(esc)0m\(esc)r\(esc)?6l\(esc)?7h\(esc)4l\(esc)H\(esc)2J"
        func lines(_ list: [String]) -> String { list.map { $0 + "\(esc)0m" }.joined(separator: "\r\n") }
        if screen.alternate {
            out += lines(Array(screen.saved.prefix(screen.rows)))
            // Where the program was started from: the shell's prompt returns
            // under the last line it wrote when the program exits.
            let lastWritten = screen.saved.lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? -1
            out += "\(esc)\(min(lastWritten + 2, screen.rows));1H\u{1b}[?1049h\(esc)H"
            out += lines(screen.lines)
        } else {
            var kept: [String] = []
            if history {
                var budget = historyBytes
                for line in screen.history.reversed() {
                    budget -= line.utf8.count + 6
                    if budget < 0 { break }
                    kept.insert(line, at: 0)
                }
            }
            out += lines(kept + screen.lines)
        }
        let full = screen.scrollTop == 0 && screen.scrollBottom == screen.rows - 1
        if !full { out += "\(esc)\(screen.scrollTop + 1);\(screen.scrollBottom + 1)r" }
        if screen.originMode { out += "\(esc)?6h\(esc)\(screen.cursorY - screen.scrollTop + 1);\(screen.cursorX + 1)H" }
        else { out += "\(esc)\(screen.cursorY + 1);\(screen.cursorX + 1)H" }
        if !screen.wrap { out += "\(esc)?7l" }
        if screen.insert { out += "\(esc)4h" }
        out += screen.cursorVisible ? "\(esc)?25h" : "\(esc)?25l"
        let shape: Int
        switch screen.cursorShape {
        case "block": shape = screen.cursorBlinking ? 1 : 2
        case "underline": shape = screen.cursorBlinking ? 3 : 4
        case "bar": shape = screen.cursorBlinking ? 5 : 6
        default: shape = 0
        }
        out += "\(esc)\(shape) q"
        return Data(out.utf8)
    }
}

extension TerminalLiveSource {
    /// The host's colours, from the same Ghostty config its terminals draw with.
    static func palette(_ theme: GhosttyThemeSnapshot) -> Collaboration.LiveTile.TerminalPalette? {
        guard theme.backgroundHex != nil || !theme.paletteHex.isEmpty else { return nil }
        return .init(foreground: theme.foregroundHex, background: theme.backgroundHex, cursor: nil, colors: Array(theme.paletteHex.prefix(16)))
    }
}
