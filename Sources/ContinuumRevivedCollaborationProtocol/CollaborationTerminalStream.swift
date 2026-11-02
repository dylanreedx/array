import Foundation

extension Collaboration.LiveTile {
    /// A shared terminal as its own terminal drew it (`.plans/114-terminal-sharing`).
    /// The host's shell, prompt, aliases and environment make the output on the
    /// host's Mac; what travels is that output, the bytes the program wrote
    /// (VT), and the guest's Mac only draws it. Nothing the guest has
    /// configured runs, and nothing the guest types is carried.
    ///
    /// A stream is a run of frames numbered from one. An `output` frame is the
    /// bytes after the frame before it; a `keyframe` is the whole screen at its
    /// sequence, which every viewer redraws from (a new size, a flood the host
    /// skipped); a `checkpoint` is the whole screen for a viewer that is
    /// behind (a late joiner), which a viewer in step ignores.
    public struct TerminalPalette: Codable, Equatable, Sendable {
        /// `#rrggbb`. Nil: the drawing terminal's own.
        public let foreground: String?
        public let background: String?
        public let cursor: String?
        /// The 16 ANSI colours, 0 to 15.
        public let colors: [String]
        public init(foreground: String?, background: String?, cursor: String?, colors: [String]) {
            self.foreground = foreground; self.background = background; self.cursor = cursor; self.colors = colors
        }
    }

    public struct TerminalFrame: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case output, keyframe, checkpoint }
        /// One run of the host's tap. A new stream starts every viewer over.
        public let stream: UUID
        public let sequence: UInt64
        public let kind: Kind
        /// The host's grid, in cells.
        public let columns: Int
        public let rows: Int
        public let bytes: Data
        /// On a keyframe or checkpoint: the host's colours.
        public let palette: TerminalPalette?
        /// When the host read the newest of these bytes, seconds since 1970.
        public let sentAt: Double?
        public init(stream: UUID, sequence: UInt64, kind: Kind, columns: Int, rows: Int, bytes: Data,
                    palette: TerminalPalette? = nil, sentAt: Double? = nil) {
            self.stream = stream; self.sequence = sequence; self.kind = kind; self.columns = columns; self.rows = rows
            self.bytes = bytes; self.palette = palette; self.sentAt = sentAt
        }
        public var isScreen: Bool { kind != .output }
    }

    /// What the state lane carries for a terminal that streams: the newest
    /// keyframe or checkpoint, and the output after it, in order. A reader that
    /// has no stream (a relay without the stream lane) follows the terminal
    /// through this alone.
    public struct TerminalScreen: Codable, Equatable, Sendable {
        public let base: TerminalFrame
        public let output: [TerminalFrame]
        public init(base: TerminalFrame, output: [TerminalFrame]) { self.base = base; self.output = output }
    }

    /// One message on a terminal's stream lane,
    /// `GET /collaboration/v1/areas/{area}/tiles/{object}/stream` upgraded to a
    /// WebSocket. The host sends frames; the relay sends every other member
    /// the frames, the newest screen and the output after it first.
    public struct StreamMessage: Codable, Equatable, Sendable {
        public let frame: TerminalFrame?
        /// Relay to host: a frame was not carried (over the rate), so the
        /// chain is broken; send a keyframe.
        public let resync: Bool?
        public init(frame: TerminalFrame? = nil, resync: Bool? = nil) { self.frame = frame; self.resync = resync }
    }

    public enum TerminalStream {
        /// One frame's encoded size, inside the relay's 256 KiB WebSocket frame.
        public static let maxFrameBytes = 192 * 1024
        /// Frames a second a host may send, sustained, and in a burst.
        public static let rate: Double = 120
        public static let burst: Double = 120
        /// Output the relay keeps after the newest screen, for joiners.
        public static let maxReplayBytes = 512 * 1024
    }
}

/// How a viewer keeps in step with a stream, from either lane. Pure: it says
/// what to draw, and the view draws it.
public struct TerminalStreamFollower: Sendable, Equatable {
    public enum Step: Equatable, Sendable {
        /// Draw these bytes after what is drawn.
        case write(Data)
        /// Start over: forget the screen, then draw this one.
        case reset(Collaboration.LiveTile.TerminalFrame)
    }
    public private(set) var stream: UUID?
    public private(set) var sequence: UInt64 = 0
    /// Frames that arrived ahead of a gap, held until it is filled.
    private var held: [UInt64: Collaboration.LiveTile.TerminalFrame] = [:]
    public private(set) var gaps = 0
    public init() {}

    /// Behind, with nothing to catch up from: the state lane's screen is needed.
    public var isWaiting: Bool { stream == nil || !held.isEmpty }

    public mutating func take(_ frame: Collaboration.LiveTile.TerminalFrame) -> [Step] {
        if frame.stream != stream {
            // Another run of the tap: only a screen can start it. Output that
            // arrives first is held for the screen it follows.
            guard frame.isScreen else {
                if stream == nil, held.count < 512 { if held.isEmpty { gaps += 1 }; held[frame.sequence] = frame }
                return []
            }
            stream = frame.stream; sequence = frame.sequence
            held = held.filter { $0.value.stream == frame.stream }
            return [.reset(frame)] + drain()
        }
        // A screen at or before what is drawn shows nothing new.
        guard frame.sequence > sequence else { return [] }
        switch frame.kind {
        case .keyframe, .checkpoint:
            // A keyframe follows on; a checkpoint only reaches a viewer behind.
            sequence = frame.sequence
            return [.reset(frame)] + drain()
        case .output:
            guard frame.sequence == sequence + 1 else {
                if held.isEmpty { gaps += 1 }
                if held.count < 512 { held[frame.sequence] = frame }
                return []
            }
            sequence = frame.sequence
            return [.write(frame.bytes)] + drain()
        }
    }

    /// The state lane's screen: the base when it is newer than what is drawn,
    /// then its output.
    public mutating func take(_ screen: Collaboration.LiveTile.TerminalScreen) -> [Step] {
        var steps: [Step] = []
        if screen.base.stream != stream || screen.base.sequence > sequence {
            if screen.base.stream != stream { held = held.filter { $0.value.stream == screen.base.stream } }
            stream = screen.base.stream; sequence = screen.base.sequence
            steps.append(.reset(screen.base))
        }
        for frame in screen.output { steps += take(frame) }
        return steps + drain()
    }

    /// Held frames that now follow on.
    private mutating func drain() -> [Step] {
        var steps: [Step] = []
        held = held.filter { $0.key > sequence }
        while let next = held.removeValue(forKey: sequence + 1) {
            sequence = next.sequence
            steps.append(next.isScreen ? .reset(next) : .write(next.bytes))
        }
        return steps
    }
}
