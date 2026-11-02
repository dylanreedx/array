import Foundation
import ContinuumRevivedCore

/// One tmux pane's output, byte for byte as its program wrote it, read through
/// a tmux control-mode client (`.plans/114-terminal-sharing`).
///
/// Array's terminal tiles run in tmux, so the pane is the terminal: what the
/// shell, its prompt and its programs wrote, at the pane's own grid. The tap
/// attaches a second client to the tile's tmux session, `ignore-size` (it
/// never resizes the window) and `read-only` (it never types). tmux sends the
/// client every byte a pane writes as `%output` lines, and the output of the
/// commands it is sent in blocks, both in one ordered stream. So a screen
/// captured with `capture-pane` lands at an exact point in the output: every
/// byte before its block is in it, and none after.
///
/// It reads the user's own tmux server, as the tile itself does. Its process
/// inherits this app's environment (and so its `TMUX_TMPDIR`), never `TMUX`.
final class TerminalTmuxTap: @unchecked Sendable {
    struct Screen: Sendable {
        var columns: Int, rows: Int
        var cursorX: Int, cursorY: Int, cursorVisible: Bool
        var alternate: Bool
        var scrollTop: Int, scrollBottom: Int
        var originMode: Bool, wrap: Bool, insert: Bool
        var cursorShape: String, cursorBlinking: Bool
        /// Lines above the screen, oldest first (none on the alternate screen).
        var history: [String]
        /// The screen, top to bottom, with its SGR escapes.
        var lines: [String]
        /// On the alternate screen: the normal screen under it.
        var saved: [String]
    }
    enum Event: Sendable {
        /// Bytes the pane wrote, and when the last of them was read.
        case output(Data, readAt: Double)
        /// A screen asked for with `requestScreen`, at its point in the output.
        case screen(Screen, purpose: Int)
        /// The pane's size or the window it is in changed.
        case layoutChanged
        /// The client ended: the tile closed, or tmux went away.
        case ended(String)
    }

    let pane: String
    private let process: Process
    private let input: FileHandle
    private let queue = DispatchQueue(label: "dev.arrayapp.terminal-tap")
    private let deliver: @Sendable ([Event]) -> Void
    // Reader state, on `queue` only.
    private var buffer = Data()
    private var block: (number: String, mine: Bool, lines: [Data])?
    private var pendingCommands: [(purpose: Int, history: Int)] = []
    private var events: [Event] = []
    /// Output read since the last event, appended in place: a flood is a
    /// hundred thousand `%output` lines, and joining them one by one was
    /// quadratic.
    private var output = Data()
    private var outputReadAt = 0.0
    private let outputPrefix: [UInt8]
    private static let beginPrefix = Array("%begin ".utf8), endPrefix = Array("%end ".utf8), errorPrefix = Array("%error ".utf8)
    private static let layoutPrefixes = ["%layout-change ", "%window-pane-changed ", "%session-window-changed "].map { Array($0.utf8) }
    private static let exitPrefix = Array("%exit".utf8)
    private var scheduled = false
    private var ended = false
    private let lock = NSLock()

    static let format = "#{pane_width} #{pane_height} #{cursor_x} #{cursor_y} #{cursor_flag} #{alternate_on} "
        + "#{scroll_region_upper} #{scroll_region_lower} #{origin_flag} #{wrap_flag} #{insert_flag} #{history_size} "
        + "#{cursor_shape} #{cursor_blinking}"

    /// The tile's tmux session and its active pane: the view session a
    /// project terminal shows, else the tile's own session. Nil when the tile
    /// does not run in local tmux (tmux off, or on another machine).
    static func locate(tileID: UUID, tmuxPath: String) -> (session: String, pane: String)? {
        for session in [TmuxSession.viewSessionName(tileId: tileID), TmuxSession.sessionName(tileId: tileID)] {
            guard let out = run(tmuxPath, ["display-message", "-p", "-t", "=" + session + ":", "#{pane_id}"]) else { continue }
            let pane = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if TmuxSession.isValidPaneId(pane) { return (session, pane) }
        }
        return nil
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TMUX"] = nil; env["TMUX_PANE"] = nil
        return env
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    init(tmuxPath: String, session: String, pane: String, deliver: @escaping @Sendable ([Event]) -> Void) throws {
        self.pane = pane; self.deliver = deliver
        outputPrefix = Array("%output \(pane) ".utf8)
        process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["-C", "attach-session", "-t", "=" + session, "-f", "ignore-size,read-only"]
        process.environment = Self.environment
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting
        // A tmux that exits under a write must not take the app with it.
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        let reader = stdout.fileHandleForReading
        reader.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.queue.async { data.isEmpty ? self.finish("tmux ended") : self.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in self?.queue.async { self?.finish("tmux ended") } }
        try process.run()
    }

    deinit { stop() }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        if process.isRunning { process.terminate() }
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    }

    /// Captures the pane: its state, `history` lines above the screen, the
    /// screen, and the normal screen under an alternate one. Arrives as
    /// `.screen(_, purpose:)` at its point in the output.
    func requestScreen(purpose: Int, history: Int) {
        queue.async { [self] in
            guard !ended else { return }
            pendingCommands.append((purpose, history))
            let start = history > 0 ? " -S -\(history)" : ""
            let line = "display-message -p -t \(pane) '\(Self.format)' ; capture-pane -p -e -N\(start) -t \(pane) ; "
                + "capture-pane -p -e -N -a -q -t \(pane)\n"
            input.write(Data(line.utf8))
        }
    }

    // MARK: Reading, on `queue`

    private var screenParts: [[Data]] = []

    /// Splits what tmux wrote into lines over raw bytes. A flood is a hundred
    /// thousand lines a second; generic `Data` slicing cost ~100 µs a line in
    /// a debug build and held the stream ten seconds behind.
    private func consume(_ data: Data) {
        buffer.append(data)
        let local = buffer
        var consumed = 0
        local.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let n = raw.count
            var start = 0
            while start < n, let found = memchr(base + start, 0x0A, n - start) {
                let end = UnsafeRawPointer(found).assumingMemoryBound(to: UInt8.self) - base
                handle(UnsafeBufferPointer(start: base + start, count: end - start))
                start = end + 1
            }
            consumed = start
        }
        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + consumed))
        flush()
    }

    private func handle(_ line: UnsafeBufferPointer<UInt8>) {
        guard let base = line.baseAddress else { handle(line: Data()); return }
        // A command's output block can hold any text; only outside one is a
        // line tmux's own notification.
        if block == nil, line.count >= outputPrefix.count, memcmp(base, outputPrefix, outputPrefix.count) == 0 {
            Self.unescape(UnsafeBufferPointer(rebasing: line[outputPrefix.count...]), into: &output)
            outputReadAt = Date().timeIntervalSince1970
            return
        }
        // Another pane's output: skipped without a copy.
        if block == nil, line.count > 8, memcmp(base, "%output ", 8) == 0 { return }
        handle(line: Data(buffer: line))
    }

    private func handle(line: Data) {
        if var open = block {
            let isEnd = line.starts(with: Self.endPrefix), isError = line.starts(with: Self.errorPrefix)
            if isEnd || isError, Self.blockNumber(line) == open.number {
                block = nil
                if open.mine { closeBlock(open.lines, failed: isError) }
                return
            }
            open.lines.append(Data(line)); block = open
            return
        }
        if line.starts(with: Self.beginPrefix) {
            // `%begin <time> <number> <flags>`; flags 1: a command this client sent.
            let parts = line.split(separator: 0x20)
            guard parts.count >= 4, let number = Self.blockNumber(line) else { return }
            block = (number, String(decoding: parts[3], as: UTF8.self) == "1", [])
            return
        }
        if Self.layoutPrefixes.contains(where: { line.starts(with: $0) }) {
            append(.layoutChanged)
            return
        }
        if line.starts(with: Self.exitPrefix) { finish("tmux client exited") }
    }

    private static func blockNumber(_ line: Data) -> String? {
        let parts = line.split(separator: 0x20)
        guard parts.count >= 3 else { return nil }
        return String(decoding: parts[1], as: UTF8.self) + " " + String(decoding: parts[2], as: UTF8.self)
    }

    /// Each screen request is three commands, so three blocks.
    private func closeBlock(_ lines: [Data], failed: Bool) {
        screenParts.append(failed ? [] : lines)
        guard screenParts.count == 3 else { return }
        let parts = screenParts; screenParts = []
        guard !pendingCommands.isEmpty else { return }
        let command = pendingCommands.removeFirst()
        guard let info = parts[0].first.map({ String(decoding: $0, as: UTF8.self).split(separator: " ").map(String.init) }), info.count >= 12,
              let columns = Int(info[0]), let rows = Int(info[1]), columns > 0, rows > 0 else { return }
        func int(_ i: Int) -> Int { Int(info[i]) ?? 0 }
        let captured = parts[1].map { String(decoding: $0, as: UTF8.self) }
        let alternate = int(5) == 1
        let history = alternate ? [] : Array(captured.dropLast(min(rows, captured.count)))
        append(.screen(Screen(columns: columns, rows: rows, cursorX: int(2), cursorY: int(3), cursorVisible: int(4) == 1,
                                     alternate: alternate, scrollTop: int(6), scrollBottom: int(7), originMode: int(8) == 1,
                                     wrap: int(9) != 0, insert: int(10) == 1,
                                     cursorShape: info.count > 12 ? info[12] : "default", cursorBlinking: info.count > 13 && info[13] == "1",
                                     history: history, lines: Array(captured.suffix(rows)),
                                     saved: alternate ? parts[2].map { String(decoding: $0, as: UTF8.self) } : []),
                              purpose: command.purpose))
    }

    private func finish(_ reason: String) {
        guard !ended else { return }
        ended = true
        append(.ended(reason))
        flush()
    }

    /// Hands what was read to the owner in one hop, in order. Output read in
    /// one go arrives as one event.
    /// An event after the output read before it, in order.
    private func append(_ event: Event) {
        takeOutput()
        events.append(event)
    }
    private func takeOutput() {
        guard !output.isEmpty else { return }
        events.append(.output(output, readAt: outputReadAt))
        output = Data()
    }

    private func flush() {
        takeOutput()
        guard !events.isEmpty else { return }
        let ready = events
        events = []
        deliver(ready)
    }

    /// `%output` escapes every byte below 32 and the backslash as `\ooo`.
    static func unescape(_ bytes: Data, into out: inout Data) {
        bytes.withUnsafeBytes { raw in unescape(raw.bindMemory(to: UInt8.self), into: &out) }
    }

    static func unescape(_ p: UnsafeBufferPointer<UInt8>, into out: inout Data) {
        guard let base = p.baseAddress else { return }
        let n = p.count
        var i = 0, run = 0
        func octal(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x37 }
        while i < n {
            if p[i] == 0x5C, i + 3 < n, octal(p[i + 1]), octal(p[i + 2]), octal(p[i + 3]) {
                if i > run { out.append(base + run, count: i - run) }
                out.append(UInt8(truncatingIfNeeded: Int(p[i + 1] - 0x30) * 64 + Int(p[i + 2] - 0x30) * 8 + Int(p[i + 3] - 0x30)))
                i += 4; run = i
                continue
            }
            i += 1
        }
        if n > run { out.append(base + run, count: n - run) }
    }

    static func unescape(_ bytes: Data) -> Data { var out = Data(); unescape(bytes, into: &out); return out }
}
