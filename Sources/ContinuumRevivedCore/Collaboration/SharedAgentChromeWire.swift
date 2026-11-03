import Compression
import CryptoKit
import Foundation
import ContinuumRevivedAgentUI

/// The host tile's chrome for a shared agent: what its title bar, under-bar,
/// status row, composer footer and character show, as the host computed it.
/// It rides the transcript lane as its own op (`chrome`) and in checkpoints, so
/// the relay never reads it and a guest that predates it skips it.
///
/// Presentation facts only. No host path, no credential, no account or cost:
/// the location's tooltip and the account's quota stay on the host's Mac.
public extension SharedAgentTranscriptWire {
    struct Chrome: Codable, Equatable, Sendable {
        /// The host's agent id: a character's loop phase is keyed by it.
        public var agent: UUID
        /// The title bar's text, exactly as the host's tile shows it.
        public var title: String
        public var harness: String
        public var model: String
        public var thinking: String
        /// A zone-palette colour name, and the host's identity style
        /// (`AgentIdentityColorConfig.Style` raw value).
        public var identityColor: String?
        public var identityStyle: String?
        public var header: Header
        public var turn: Turn
        /// The context meter's reading, with cost removed.
        public var context: AgentContextWindowSnapshot?
        /// The status row's activity input; nil when the host knows no phase.
        public var activity: Activity?
        public var location: Location?
        /// `AgentStatusElement` raw values the host's row shows, account ones removed.
        public var enabledElements: [String]
        /// The words at the transcript's tail.
        public var tail: Tail
        /// The host's character, or nil when the host shows none.
        public var character: Character?
        /// The characters of the agent's direct helpers, by agent id.
        public var helpers: [UUID: AgentCharacterAssignment]

        public init(agent: UUID, title: String, harness: String, model: String, thinking: String, identityColor: String?,
                    identityStyle: String?, header: Header, turn: Turn, context: AgentContextWindowSnapshot?,
                    activity: Activity?, location: Location?, enabledElements: [String], tail: Tail,
                    character: Character?, helpers: [UUID: AgentCharacterAssignment]) {
            self.agent = agent; self.title = title; self.harness = harness; self.model = model; self.thinking = thinking
            self.identityColor = identityColor; self.identityStyle = identityStyle; self.header = header
            self.turn = turn; self.context = context; self.activity = activity; self.location = location
            self.enabledElements = enabledElements; self.tail = tail; self.character = character; self.helpers = helpers
        }

        /// `AgentTileStatePresenter.Presentation`, as the host derived it.
        public struct Header: Codable, Equatable, Sendable {
            public var name: String
            public var status: AgentStatus
            public var stateLabel: String
            public var stateAccessibilityLabel: String
            public var availableActionDescription: String
            /// The elapsed anchor; the guest counts from it on its own clock.
            public var startedAt: Date?
            public var branch: Branch?
            public var managed: Bool
            public init(name: String, status: AgentStatus, stateLabel: String, stateAccessibilityLabel: String,
                        availableActionDescription: String, startedAt: Date?, branch: Branch?, managed: Bool) {
                self.name = name; self.status = status; self.stateLabel = stateLabel
                self.stateAccessibilityLabel = stateAccessibilityLabel
                self.availableActionDescription = availableActionDescription
                self.startedAt = startedAt; self.branch = branch; self.managed = managed
            }
        }

        public struct Branch: Codable, Equatable, Sendable {
            public var text: String
            public var tooltip: String
            public var isWarning: Bool
            public init(text: String, tooltip: String, isWarning: Bool) {
                self.text = text; self.tooltip = tooltip; self.isWarning = isWarning
            }
        }

        /// What the primary action shows on the host. The guest draws it and
        /// never performs it: a Stop from here has no route to the host's runner.
        public struct Turn: Codable, Equatable, Sendable {
            public var working: Bool
            public var canSend: Bool
            public var canStop: Bool
            public var canSteer: Bool
            public var canQueue: Bool
            /// Array only mirrors this agent: the host shows no composer at all.
            public var isMirrored: Bool
            public init(working: Bool, canSend: Bool, canStop: Bool, canSteer: Bool, canQueue: Bool, isMirrored: Bool) {
                self.working = working; self.canSend = canSend; self.canStop = canStop
                self.canSteer = canSteer; self.canQueue = canQueue; self.isMirrored = isMirrored
            }
        }

        /// `AgentCompactActivityInput`: the guest presents it at its own `now`.
        public struct Activity: Codable, Equatable, Sendable {
            public var phase: String
            public var phaseStartedAt: Date?
            public var safeToolLabel: String?
            public var evidenceNote: String?
            public init(phase: String, phaseStartedAt: Date?, safeToolLabel: String?, evidenceNote: String?) {
                self.phase = phase; self.phaseStartedAt = phaseStartedAt
                self.safeToolLabel = safeToolLabel; self.evidenceNote = evidenceNote
            }
        }

        public struct Location: Codable, Equatable, Sendable {
            public var symbolName: String
            public var text: String
            public var accessibilityLabel: String
            public var isExternal: Bool
            public init(symbolName: String, text: String, accessibilityLabel: String, isExternal: Bool) {
                self.symbolName = symbolName; self.text = text
                self.accessibilityLabel = accessibilityLabel; self.isExternal = isExternal
            }
        }

        /// The tail's words. A live tail's clock runs from `since` on the guest.
        public struct Tail: Codable, Equatable, Sendable {
            public var working: Bool
            public var text: String?
            public var since: Date?
            public var settled: String?
            public init(working: Bool, text: String?, since: Date?, settled: String?) {
                self.working = working; self.text = text; self.since = since; self.settled = settled
            }
        }

        /// The host's character and the inputs of its pose.
        public struct Character: Codable, Equatable, Sendable {
            /// `InboxState` and `InboxAttention` raw values.
            public var state: String
            public var attention: String
            public var title: String
            public var action: String?
            public var lastOutputAt: Date?
            public var promptSentAt: Date?
            public var stepFailedAt: Date?
            public var endedAt: Date?
            public var outcome: String?
            /// The agent's manual pick, by name.
            public var characterName: String?
            /// Which character the host draws, in `theme`. nil: the guest resolves it.
            public var assignment: AgentCharacterAssignment?
            public var theme: ThemeReference

            public init(snapshot: AgentCharacterSnapshot, characterName: String?,
                        assignment: AgentCharacterAssignment?, theme: ThemeReference) {
                state = snapshot.state.rawValue; attention = snapshot.attention.rawValue; title = snapshot.title
                action = snapshot.activity.action?.rawValue; lastOutputAt = snapshot.activity.lastOutputAt
                promptSentAt = snapshot.activity.promptSentAt; stepFailedAt = snapshot.activity.stepFailedAt
                endedAt = snapshot.activity.endedAt; outcome = snapshot.activity.outcome?.rawValue
                self.characterName = characterName; self.assignment = assignment; self.theme = theme
            }

            /// The pose inputs; an unknown value (a newer host) reads as idle.
            public var snapshot: AgentCharacterSnapshot {
                AgentCharacterSnapshot(
                    state: InboxState(rawValue: state) ?? .ready,
                    attention: InboxAttention(rawValue: attention) ?? .none,
                    activity: AgentCharacterActivity(
                        action: action.flatMap(AgentCharacterLoop.init(rawValue:)), lastOutputAt: lastOutputAt,
                        promptSentAt: promptSentAt, stepFailedAt: stepFailedAt, endedAt: endedAt,
                        outcome: outcome.flatMap(AgentCharacterActivity.Outcome.init(rawValue:))),
                    title: title)
            }
        }

        /// Which set the host draws. A built-in set goes by id alone; a person's
        /// own set also carries its content hash, and its file travels once as a
        /// `CharacterTheme`.
        public struct ThemeReference: Codable, Equatable, Hashable, Sendable {
            public var id: String
            public var hash: String?
            public init(id: String, hash: String?) { self.id = id; self.hash = hash }
        }
    }

    /// A person's own character set, as its file: deflated, with the SHA-256 of
    /// the file's bytes. Sent once per set; the guest keeps it in memory only.
    struct CharacterTheme: Codable, Equatable, Sendable {
        /// What a deflated set may cost on the wire: a frame holds 48 KiB, and
        /// base64 inflates the bytes by a third.
        public static let maximumDeflatedBytes = 32 * 1024

        public let hash: String
        public let deflated: Data

        /// nil when the file deflates past `maximumDeflatedBytes`: the guest
        /// then draws its built-in set.
        public init?(file: Data) {
            guard file.count <= AgentCharacterThemeParser.maximumFileBytes,
                  let deflated = Self.deflate(file), deflated.count <= Self.maximumDeflatedBytes else { return nil }
            self.hash = Self.hash(file); self.deflated = deflated
        }
        public init(hash: String, deflated: Data) { self.hash = hash; self.deflated = deflated }

        public static func hash(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        /// The file again, or nil when it is oversized, corrupt or not the file
        /// its hash names. Never inflates past the validator's own size limit.
        public func file() -> Data? {
            guard deflated.count <= Self.maximumDeflatedBytes,
                  let data = Self.inflate(deflated, limit: AgentCharacterThemeParser.maximumFileBytes),
                  Self.hash(data) == hash else { return nil }
            return data
        }

        static func deflate(_ data: Data) -> Data? {
            guard !data.isEmpty else { return nil }
            let capacity = data.count + 1024
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { dst in
                data.withUnsafeBytes { src in
                    compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written > 0 else { return nil }
            return out.prefix(written)
        }

        /// One byte of headroom: output that fills it is over `limit`.
        static func inflate(_ data: Data, limit: Int) -> Data? {
            guard !data.isEmpty else { return nil }
            let capacity = limit + 1
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { dst in
                data.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written > 0, written <= limit else { return nil }
            return out.prefix(written)
        }
    }
}
