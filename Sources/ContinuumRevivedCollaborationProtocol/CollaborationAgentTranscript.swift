import Foundation

extension Collaboration {
    /// A published agent's whole transcript, the same semantic document its
    /// owner's tile draws (`~/array-scratch/mp-polish/transcript-lead/CONTRACT.md`).
    ///
    /// The relay sees envelopes only: a checkpoint and sequenced frames whose
    /// `body` it never decodes. The body's vocabulary (`AgentDocument` entries and
    /// blocks) lives with the app, so a new block kind never needs a relay
    /// deploy. Memory only, like `LiveTile`: a relay restart drops the lane and
    /// the host's next publish is answered `checkpointRequired`.
    public enum AgentTranscript {
        public static let schema = 1
        /// Sent in `LiveTile.capabilityHeader` by a client that reads this lane.
        public static let capability = "agent-transcript"
        public static let mainStream = "main"
        public static func childStream(_ agent: UUID) -> String { "child:" + agent.uuidString.lowercased() }

        // Raw bytes. Bodies travel base64 (4/3) inside the 256 KiB request cap.
        public static let maxCheckpointBytes = 176 * 1024
        public static let maxFrameBytes = 48 * 1024
        public static let maxPublishBytes = 176 * 1024
        /// A host checkpoints again once this many frame bytes follow its last.
        public static let checkpointAfterBytes = 256 * 1024
        public static let maxRetainedBytes = 1024 * 1024
        public static let maxRetainedFrames = 1024
        public static let maxStreamBytes = 64
        public static let maxFramesPerRead = 64
        public static let maxWaitMilliseconds = 25_000

        public static func validStream(_ stream: String) -> Bool {
            !stream.isEmpty && stream.utf8.count <= maxStreamBytes
                && stream.unicodeScalars.allSatisfy { $0.value > 0x20 && $0.value < 0x7F }
        }

        /// The whole picture at `through`, as the host's body encoding states it.
        public struct Checkpoint: Codable, Equatable, Sendable {
            public let generation: UInt64
            public let through: UInt64
            public let body: Data
            public init(generation: UInt64, through: UInt64, body: Data) {
                self.generation = generation; self.through = through; self.body = body
            }
        }
        public struct Frame: Codable, Equatable, Sendable {
            public let generation: UInt64
            public let sequence: UInt64
            public let body: Data
            public init(generation: UInt64, sequence: UInt64, body: Data) {
                self.generation = generation; self.sequence = sequence; self.body = body
            }
        }
        public struct Cursor: Codable, Equatable, Sendable {
            public let generation: UInt64
            public let through: UInt64
            public init(generation: UInt64, through: UInt64) { self.generation = generation; self.through = through }
        }

        public struct Publish: Codable, Sendable {
            public let epoch: Int64
            public let host: SharedArea.ID<SharedArea.Host>
            public let stream: String
            public let checkpoint: Checkpoint?
            public let frames: [Frame]
            public init(epoch: Int64, host: SharedArea.ID<SharedArea.Host>, stream: String, checkpoint: Checkpoint?, frames: [Frame]) {
                self.epoch = epoch; self.host = host; self.stream = stream; self.checkpoint = checkpoint; self.frames = frames
            }
            public var bodyBytes: Int { (checkpoint?.body.count ?? 0) + frames.reduce(0) { $0 + $1.body.count } }
        }
        public struct ReadRequest: Codable, Sendable {
            public let stream: String
            public let cursor: Cursor?
            public let waitMilliseconds: Int
            public init(stream: String, cursor: Cursor?, waitMilliseconds: Int) {
                self.stream = stream; self.cursor = cursor; self.waitMilliseconds = waitMilliseconds
            }
        }
        public enum Read: Codable, Equatable, Sendable {
            /// The cursor is current: the frames after it (possibly none).
            case frames(generation: UInt64, frames: [Frame], more: Bool)
            /// Start over: the newest checkpoint and the frames after it.
            case resnapshot(Checkpoint, frames: [Frame], more: Bool)
        }

        public enum Failure: Error, Equatable, Sendable {
            /// A frame the log cannot place (gap, empty log): send a checkpoint.
            case checkpointRequired
            /// An older generation than the log holds: this host session is dead.
            case stale
            case invalid
        }

        /// Head checkpoint plus every frame after it. Pure; the relay's lane and
        /// the witnesses run the same code.
        public struct Log: Equatable, Sendable {
            public private(set) var checkpoint: Checkpoint
            public private(set) var frames: [Frame] = []
            public init(checkpoint: Checkpoint) { self.checkpoint = checkpoint }
            public var through: UInt64 { frames.last?.sequence ?? checkpoint.through }
            public var generation: UInt64 { checkpoint.generation }
            public var retainedBytes: Int { frames.reduce(0) { $0 + $1.body.count } }

            /// Applies a publish to `log` (nil = nothing held). Throws without change.
            public static func publish(_ publish: Publish, onto log: Log?) throws(Failure) -> Log {
                guard AgentTranscript.validStream(publish.stream), publish.bodyBytes <= maxPublishBytes,
                      publish.checkpoint.map({ $0.body.count <= maxCheckpointBytes && $0.generation > 0 }) ?? true,
                      publish.frames.allSatisfy({ $0.body.count <= maxFrameBytes }),
                      publish.checkpoint != nil || !publish.frames.isEmpty else { throw .invalid }
                var next: Log
                if let checkpoint = publish.checkpoint {
                    if let log, checkpoint.generation < log.generation
                        || (checkpoint.generation == log.generation && checkpoint.through < log.checkpoint.through) { throw .stale }
                    if let log, checkpoint.generation == log.generation, checkpoint.through <= log.through {
                        // Same session, rebased: keep the frames the checkpoint has not folded.
                        next = Log(checkpoint: checkpoint)
                        next.frames = log.frames.filter { $0.sequence > checkpoint.through }
                    } else {
                        next = Log(checkpoint: checkpoint)
                    }
                } else {
                    guard let log else { throw .checkpointRequired }
                    next = log
                }
                for frame in publish.frames {
                    guard frame.generation >= next.generation else { throw .stale }
                    guard frame.generation == next.generation else { throw .checkpointRequired }
                    if frame.sequence <= next.through { continue }
                    guard frame.sequence == next.through + 1 else { throw .checkpointRequired }
                    next.frames.append(frame)
                }
                guard next.frames.count <= maxRetainedFrames, next.retainedBytes <= maxRetainedBytes else { throw .checkpointRequired }
                return next
            }

            public func read(after cursor: Cursor?, limit: Int = maxFramesPerRead) -> Read {
                let limit = max(1, limit)
                guard let cursor, cursor.generation == generation,
                      cursor.through >= checkpoint.through, cursor.through <= through else {
                    let page = Array(frames.prefix(limit))
                    return .resnapshot(checkpoint, frames: page, more: page.count < frames.count)
                }
                let after = frames.filter { $0.sequence > cursor.through }
                let page = Array(after.prefix(limit))
                return .frames(generation: generation, frames: page, more: page.count < after.count)
            }
        }
    }
}
