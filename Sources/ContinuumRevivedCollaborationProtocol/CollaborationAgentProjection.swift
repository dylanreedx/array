import Foundation

extension Collaboration {
    /// A teammate's read-only view of one published agent. The execution host
    /// projects its supervisor's semantic transcript through an allowlist; the
    /// recipient never constructs a runner from it. Every field here is a
    /// deliberate publication: provider item ids, titles, prompts, reasoning,
    /// command output, error text, usage and paths have no field to travel in.
    public enum AgentProjection {
        public static let schema = 1
        /// Sized so a whole snapshot, JSON-escaped, stays inside the service's
        /// 256 KiB request limit: a teammate's view is the gist, not an archive.
        public static let maxRows = 32
        public static let maxRowTextBytes = 3 * 1024
        public static let maxDeltaBytes = 1024
        public static let maxBatchFrames = 64
        public static let retainedFrames = 512

        /// What the owner chose to include from before publication. Excluded is
        /// the default: the projection starts at the publishing attach boundary.
        public enum History: String, Codable, Sendable { case excluded, assistantOutput }
        public enum Phase: String, Codable, Sendable { case ready, starting, working, needsAction, failed, stopped }
        public enum ToolKind: String, Codable, Sendable { case command, fileChange, mcpTool, webSearch, plan, subagent, other }
        public enum ToolStatus: String, Codable, Sendable { case running, completed, failed, declined }
        public enum Outcome: String, Codable, Sendable { case completed, failed, interrupted, cancelled }

        /// Host facts about the BOUND runner at the moment they were read. They
        /// are presentation, not a grant: the host revalidates every command.
        /// Teardown (kill) is deliberately absent; interrupt keeps the session.
        public struct Capabilities: Codable, Equatable, Sendable {
            public let locallyManaged: Bool
            public let canSend: Bool
            public let canQueue: Bool
            public let canSteer: Bool
            public let canInterrupt: Bool
            public init(locallyManaged: Bool, canSend: Bool, canQueue: Bool, canSteer: Bool, canInterrupt: Bool) {
                self.locallyManaged = locallyManaged
                self.canSend = locallyManaged && canSend
                self.canQueue = locallyManaged && canQueue
                self.canSteer = locallyManaged && canSteer
                self.canInterrupt = locallyManaged && canInterrupt
            }
            public static let none = Capabilities(locallyManaged: false, canSend: false, canQueue: false, canSteer: false, canInterrupt: false)
        }

        /// What a recipient may actually offer. Only send and queue have a
        /// cross-host route (the handoff dispatcher), and only for the person who
        /// holds control. Steer, interrupt and provider approvals have no remote
        /// route at all, so they stay unavailable whatever the host runner can do.
        public struct RemoteControls: Equatable, Sendable {
            public let send: Bool
            public let queue: Bool
            public let steer = false
            public let interrupt = false
            public let approveProviderRequest = false
            public init(host: Capabilities, holdsControl: Bool) {
                // Re-derived from decoded values: a wire Capabilities never passed
                // through the gating initializer.
                send = holdsControl && host.locallyManaged && host.canSend
                queue = holdsControl && host.locallyManaged
            }
        }

        public enum RowKind: Codable, Equatable, Sendable {
            case assistant
            case tool(ToolKind)
        }
        public struct Row: Codable, Equatable, Sendable {
            /// Opaque: a digest of the host generation and provider identity.
            public let id: String
            public let turn: String?
            public let kind: RowKind
            public var text: String
            public var status: ToolStatus?
            public var truncated: Bool
            /// The sequence of the frame that last changed this row; 0 for a row
            /// that came from included history. With the generation, this is the
            /// row's `Position` for a result excerpt.
            public var sequence: UInt64
            public init(id: String, turn: String?, kind: RowKind, text: String = "", status: ToolStatus? = nil,
                        truncated: Bool = false, sequence: UInt64 = 0) {
                self.id = id; self.turn = turn; self.kind = kind; self.text = text; self.status = status
                self.truncated = truncated; self.sequence = sequence
            }
        }

        /// Where an event stands in a projection: the source of truth for the
        /// `turn`/position a result excerpt cites (`Collaboration.ResultExcerpt`).
        public struct Position: Codable, Hashable, Sendable {
            public let generation: UInt64
            public let sequence: UInt64
            public init(generation: UInt64, sequence: UInt64) { self.generation = generation; self.sequence = sequence }
        }

        public enum Payload: Codable, Equatable, Sendable {
            case phase(Phase)
            case capabilities(Capabilities)
            case turnStarted(turn: String)
            case turnCompleted(turn: String, outcome: Outcome)
            case assistantText(row: String, turn: String, delta: String)
            case tool(row: String, turn: String?, kind: ToolKind, status: ToolStatus)
        }

        /// One sequenced tail event. `(host, object, generation, sequence)` is its
        /// stable identity; a replacement host session always mints a higher
        /// generation, so an old session's late frames cannot touch the new view.
        public struct Frame: Codable, Equatable, Sendable {
            public let host: SharedArea.ID<SharedArea.Host>
            public let object: SharedArea.ID<SharedArea.Object>
            public let generation: UInt64
            public let sequence: UInt64
            public let payload: Payload
            public init(host: SharedArea.ID<SharedArea.Host>, object: SharedArea.ID<SharedArea.Object>,
                        generation: UInt64, sequence: UInt64, payload: Payload) {
                self.host = host; self.object = object; self.generation = generation; self.sequence = sequence; self.payload = payload
            }
        }

        public enum ApplyError: Error, Equatable, Sendable {
            case wrongObject, staleGeneration, newerGeneration, gap(expected: UInt64, received: UInt64), invalid
        }

        /// The complete projected state through `through`. The reducer is the
        /// same on the host, in the service log and on the recipient, so a
        /// snapshot at N plus frames N+1… equals the host's own state.
        public struct Snapshot: Codable, Equatable, Sendable {
            public let schema: Int
            public let host: SharedArea.ID<SharedArea.Host>
            public let object: SharedArea.ID<SharedArea.Object>
            public let generation: UInt64
            public let history: History
            public private(set) var through: UInt64
            public private(set) var phase: Phase
            public private(set) var capabilities: Capabilities
            public private(set) var rows: [Row]
            /// Rows dropped from the front to respect `maxRows`.
            public private(set) var omittedRows: Int
            public init(host: SharedArea.ID<SharedArea.Host>, object: SharedArea.ID<SharedArea.Object>, generation: UInt64,
                        history: History, phase: Phase, capabilities: Capabilities, rows: [Row] = []) {
                schema = AgentProjection.schema
                self.host = host; self.object = object; self.generation = generation; self.history = history
                through = 0; self.phase = phase; self.capabilities = capabilities; self.rows = []; omittedRows = 0
                for row in rows { insert(row) }
            }

            /// The position an excerpt of `row` cites, if the row came from the live tail.
            public func position(of row: String) -> Position? {
                guard let found = rows.first(where: { $0.id == row }), found.sequence > 0 else { return nil }
                return Position(generation: generation, sequence: found.sequence)
            }

            public var valid: Bool {
                schema == AgentProjection.schema && generation > 0 && rows.count <= AgentProjection.maxRows && omittedRows >= 0
                    && Set(rows.map(\.id)).count == rows.count
                    && rows.allSatisfy { $0.sequence <= through && $0.id.utf8.count <= 64 && ($0.turn?.utf8.count ?? 0) <= 64
                        && $0.text.utf8.count <= AgentProjection.maxRowTextBytes && AgentProjection.sanitize($0.text) == $0.text }
            }

            /// Applies one frame. Returns false for a duplicate already folded in.
            @discardableResult
            public mutating func apply(_ frame: Frame) throws(ApplyError) -> Bool {
                guard frame.host == host, frame.object == object else { throw .wrongObject }
                guard frame.generation >= generation else { throw .staleGeneration }
                guard frame.generation == generation else { throw .newerGeneration }
                guard frame.sequence > through else { return false }
                guard frame.sequence == through + 1 else { throw .gap(expected: through + 1, received: frame.sequence) }
                guard AgentProjection.valid(frame.payload) else { throw .invalid }
                switch frame.payload {
                case .phase(let value): phase = value
                case .capabilities(let value): capabilities = value
                case .turnStarted: phase = .working
                case .turnCompleted(_, let outcome): phase = outcome == .failed ? .failed : .ready
                case let .assistantText(id, turn, delta):
                    if let index = rows.firstIndex(where: { $0.id == id }) {
                        guard rows[index].kind == .assistant else { throw .invalid }
                        Self.append(delta, to: &rows[index])
                        rows[index].sequence = frame.sequence
                    } else {
                        var row = Row(id: id, turn: turn, kind: .assistant, sequence: frame.sequence)
                        Self.append(delta, to: &row)
                        insert(row)
                    }
                case let .tool(id, turn, kind, status):
                    if let index = rows.firstIndex(where: { $0.id == id }) {
                        guard rows[index].kind == .tool(kind) else { throw .invalid }
                        rows[index].status = status
                        rows[index].sequence = frame.sequence
                    } else {
                        insert(Row(id: id, turn: turn, kind: .tool(kind), status: status, sequence: frame.sequence))
                    }
                }
                through = frame.sequence
                return true
            }

            private mutating func insert(_ row: Row) {
                rows.append(row)
                if rows.count > AgentProjection.maxRows {
                    rows.removeFirst(rows.count - AgentProjection.maxRows)
                    omittedRows += 1
                }
            }

            /// Deterministic truncation at a character boundary, identical on every
            /// replica, so a bounded row can never diverge between host and viewer.
            private static func append(_ delta: String, to row: inout Row) {
                guard !row.truncated else { return }
                var budget = AgentProjection.maxRowTextBytes - row.text.utf8.count
                for character in delta {
                    let size = String(character).utf8.count
                    guard size <= budget else { row.truncated = true; return }
                    row.text.append(character); budget -= size
                }
            }
        }

        /// Text keeps newlines and tabs; every other control character, terminal
        /// escapes included, is removed on the host. That also bounds JSON
        /// escaping at 2x, which is what keeps a full snapshot under 256 KiB.
        public static func sanitize(_ text: String) -> String {
            String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
                scalar == "\n" || scalar == "\t" || !(scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value))
            }))
        }

        static func valid(_ payload: Payload) -> Bool {
            switch payload {
            case let .assistantText(row, turn, delta):
                return row.utf8.count <= 64 && turn.utf8.count <= 64 && !delta.isEmpty && delta.utf8.count <= maxDeltaBytes
                    && sanitize(delta) == delta
            case let .tool(row, turn, _, _):
                return row.utf8.count <= 64 && (turn?.utf8.count ?? 0) <= 64
            case let .turnStarted(turn), let .turnCompleted(turn, _):
                return turn.utf8.count <= 64
            case .phase, .capabilities:
                return true
            }
        }

        /// What a host sends. A snapshot replaces the log (new generation, or a
        /// host that lost frames it could not deliver); frames extend it.
        public struct Batch: Codable, Equatable, Sendable {
            public let snapshot: Snapshot?
            public let frames: [Frame]
            public init(snapshot: Snapshot?, frames: [Frame]) { self.snapshot = snapshot; self.frames = frames }
        }
        public struct PublishReport: Codable, Sendable {
            public let epoch: Int64
            public let batch: Batch
            public init(epoch: Int64, batch: Batch) { self.epoch = epoch; self.batch = batch }
        }

        public enum Read: Codable, Equatable, Sendable {
            /// The cursor's generation is current and its frames are retained.
            case frames(generation: UInt64, frames: [Frame], more: Bool)
            /// Late join, stale/newer generation, or a cursor older than retention:
            /// start over from this state. Never a silent skip over a gap.
            case resnapshot(Snapshot)
        }
        public struct ReadRequest: Codable, Sendable {
            public let cursor: Cursor?
            public init(cursor: Cursor?) { self.cursor = cursor }
        }
        public struct Cursor: Codable, Equatable, Sendable {
            public let generation: UInt64
            public let through: UInt64
            public init(generation: UInt64, through: UInt64) { self.generation = generation; self.through = through }
        }

        /// Head state plus a bounded contiguous window of the frames that led to
        /// it. Used by the service (durable) and by the host outbox.
        public struct Log: Codable, Equatable, Sendable {
            public private(set) var head: Snapshot
            public private(set) var frames: [Frame]
            public init(snapshot: Snapshot) { head = snapshot; frames = [] }

            public enum Failure: Error, Equatable, Sendable { case wrongObject, staleGeneration, invalid, apply(ApplyError) }

            public mutating func publish(_ batch: Batch) throws(Failure) {
                guard batch.frames.count <= AgentProjection.maxBatchFrames else { throw .invalid }
                var next = self
                if let snapshot = batch.snapshot {
                    guard snapshot.valid else { throw .invalid }
                    guard snapshot.host == head.host, snapshot.object == head.object else { throw .wrongObject }
                    guard snapshot.generation > head.generation
                            || (snapshot.generation == head.generation && snapshot.through >= head.through) else { throw .staleGeneration }
                    next = Log(snapshot: snapshot)
                }
                for frame in batch.frames {
                    do {
                        if try next.head.apply(frame) { next.frames.append(frame) }
                    } catch .staleGeneration {
                        throw .staleGeneration
                    } catch {
                        throw .apply(error)
                    }
                }
                if next.frames.count > AgentProjection.retainedFrames {
                    next.frames.removeFirst(next.frames.count - AgentProjection.retainedFrames)
                }
                self = next
            }

            public func read(after cursor: Cursor?, limit: Int = AgentProjection.maxBatchFrames) -> Read {
                let floor = head.through - UInt64(frames.count)
                guard let cursor, cursor.generation == head.generation,
                      cursor.through >= floor, cursor.through <= head.through else { return .resnapshot(head) }
                let start = Int(cursor.through - floor)
                let end = min(frames.count, start + max(1, limit))
                return .frames(generation: head.generation, frames: Array(frames[start..<end]), more: end < frames.count)
            }
        }

        /// The recipient's state for one published agent. It only ever applies
        /// what it was sent; it owns no executor and asks for a resnapshot rather
        /// than guessing across a gap.
        public struct Replica: Equatable, Sendable {
            public private(set) var state: Snapshot?
            public init() {}
            public var cursor: Cursor? { state.map { Cursor(generation: $0.generation, through: $0.through) } }

            public enum Outcome: Equatable, Sendable { case applied(Int), needsResnapshot(ApplyError) }

            public mutating func receive(_ read: Read) -> Outcome {
                switch read {
                case .resnapshot(let snapshot):
                    guard snapshot.valid else { return .needsResnapshot(.invalid) }
                    if let state, snapshot.host != state.host || snapshot.object != state.object { return .needsResnapshot(.wrongObject) }
                    // An older session's snapshot arriving late never replaces a newer one.
                    if let state, snapshot.generation < state.generation
                        || (snapshot.generation == state.generation && snapshot.through < state.through) { return .applied(0) }
                    state = snapshot
                    return .applied(1)
                case .frames(_, let frames, _):
                    guard var next = state else { return .needsResnapshot(.gap(expected: 1, received: frames.first?.sequence ?? 0)) }
                    var applied = 0
                    for frame in frames {
                        do { if try next.apply(frame) { applied += 1 } }
                        catch .staleGeneration { continue }
                        catch { state = next; return .needsResnapshot(error) }
                    }
                    state = next
                    return .applied(applied)
                }
            }
        }
    }
}
