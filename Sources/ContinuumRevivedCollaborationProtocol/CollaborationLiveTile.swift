import Foundation

extension Collaboration {
    /// One shared tile that is not an agent: a note, a file, a diff, a browser
    /// or a terminal (`.plans/105-collaboration/SHARE-KINDS.md`). The area holds
    /// it as one `SharedArea.Kind.liveTile` item, sourced like an agent
    /// observation; this lane carries what it shows.
    ///
    /// Two primitives per (area, object), both held in the relay's memory:
    /// - **state**: the latest whole picture, written only by the item's owning
    ///   host. A newer revision replaces the older one; nothing is kept.
    /// - **events**: an append-only, bounded log any member may extend where the
    ///   kind takes input (note edits, browser clicks and scrolls). The relay
    ///   stamps each event with its author and a sequence number.
    ///
    /// Readers long-poll both at once. A relay restart loses the lane; the host
    /// republishes its state on its next beat, and note edits are CRDT ops, so
    /// replaying or losing a duplicate never corrupts the text.
    public enum LiveTile {
        public static let schema = 1
        /// A state's encoded payload, inside the relay's 256 KiB request cap with
        /// room for the envelope.
        public static let maxStateBytes = 240 * 1024
        public static let maxEventBytes = 128 * 1024
        public static let retainedEvents = 2048
        public static let maxEventsPerRead = 256
        public static let maxWaitMilliseconds = 25_000

        /// What a client sends with every request to say which areas it can
        /// read. 0.7.38 and earlier send nothing and cannot decode an area
        /// holding a live tile, so the relay refuses them that area at the link
        /// (HTTP 426) before admitting anyone or spending a "Works once" link.
        public static let capabilityHeader = "x-array-collaboration-capabilities"
        public static let capability = "live-tile"
        public static func clientReadsLiveTiles(_ header: String?) -> Bool {
            header?.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == capability } ?? false
        }

        public enum Kind: String, Codable, Sendable, CaseIterable { case note, file, diff, browser, terminal }

        public struct Note: Codable, Equatable, Sendable {
            public let title: String
            /// The host's replica, every op it has merged. A late joiner starts
            /// here and then reads events after `eventsThrough`.
            public let snapshot: NoteText.Snapshot
            public let eventsThrough: UInt64
            public init(title: String, snapshot: NoteText.Snapshot, eventsThrough: UInt64) {
                self.title = title; self.snapshot = snapshot; self.eventsThrough = eventsThrough
            }
        }
        public struct File: Codable, Equatable, Sendable {
            public let name: String
            public let language: String?
            /// Nil when the file is binary or too large to carry; `notice` says which.
            public let text: String?
            public let digest: String
            public let byteCount: Int
            public let notice: String?
            public init(name: String, language: String?, text: String?, digest: String, byteCount: Int, notice: String?) {
                self.name = name; self.language = language; self.text = text; self.digest = digest
                self.byteCount = byteCount; self.notice = notice
            }
        }
        public struct Diff: Codable, Equatable, Sendable {
            public let title: String
            /// Unified diff text, cut at the byte cap; `truncated` says so.
            public let diff: String
            public let digest: String
            public let files: Int
            public let truncated: Bool
            public init(title: String, diff: String, digest: String, files: Int, truncated: Bool) {
                self.title = title; self.diff = diff; self.digest = digest; self.files = files; self.truncated = truncated
            }
        }
        public enum Reach: String, Codable, Sendable {
            /// Anyone can load the URL: the guest's own browser follows it.
            case `public`
            /// localhost, the LAN, a file, or a page only the host is signed in
            /// to: the guest sees the host's rendered frames.
            case `private`
        }
        public struct Frame: Codable, Equatable, Sendable {
            /// JPEG bytes of the host's visible page.
            public let jpeg: Data
            /// The page's size in points, so a click maps to the same spot.
            public let width: Double
            public let height: Double
            public let sequence: UInt64
            public init(jpeg: Data, width: Double, height: Double, sequence: UInt64) {
                self.jpeg = jpeg; self.width = width; self.height = height; self.sequence = sequence
            }
        }
        public struct Browser: Codable, Equatable, Sendable {
            public let url: String?
            public let title: String
            public let reach: Reach
            /// The latest picture of the host's page. Carried for every reach, so
            /// a guest who cannot load a public page still sees it.
            public let frame: Frame?
            public init(url: String?, title: String, reach: Reach, frame: Frame?) {
                self.url = url; self.title = title; self.reach = reach; self.frame = frame
            }
        }
        public struct Terminal: Codable, Equatable, Sendable {
            public let title: String
            /// The last screenful and some scrollback, plain text: what a viewer
            /// that cannot draw `screen` shows.
            public let text: String
            public let columns: Int
            public let rows: Int
            /// The terminal as it drew itself: the newest screen and the output
            /// after it (`TerminalScreen`, `.plans/114-terminal-sharing`). Absent
            /// from an older host, and from a terminal that is not in tmux.
            public let screen: TerminalScreen?
            public init(title: String, text: String, columns: Int, rows: Int, screen: TerminalScreen? = nil) {
                self.title = title; self.text = text; self.columns = columns; self.rows = rows; self.screen = screen
            }
        }

        public enum Payload: Codable, Equatable, Sendable {
            case note(Note), file(File), diff(Diff), browser(Browser), terminal(Terminal)
            public var kind: Kind {
                switch self {
                case .note: .note
                case .file: .file
                case .diff: .diff
                case .browser: .browser
                case .terminal: .terminal
                }
            }
        }

        public struct State: Codable, Equatable, Sendable {
            public let schema: Int
            /// A new run of the host starts a new generation; revisions count within it.
            public let generation: UUID
            public let revision: UInt64
            public let at: Date
            public let payload: Payload
            public var kind: Kind { payload.kind }
            public init(generation: UUID, revision: UInt64, at: Date = Date(), payload: Payload) {
                schema = LiveTile.schema; self.generation = generation; self.revision = revision; self.at = at; self.payload = payload
            }
        }

        /// What a member may append. The relay refuses input a kind does not take.
        public enum EventBody: Codable, Equatable, Sendable {
            case noteOps([NoteText.Op])
            /// A click at a point of the host's page, in page points.
            case browserClick(x: Double, y: Double)
            case browserScroll(dx: Double, dy: Double)

            public var acceptedBy: Kind {
                switch self {
                case .noteOps: .note
                case .browserClick, .browserScroll: .browser
                }
            }
        }
        public struct Event: Codable, Equatable, Sendable {
            public let sequence: UInt64
            public let author: SharedArea.ID<SharedArea.Person>
            public let at: Date
            public let body: EventBody
            public init(sequence: UInt64, author: SharedArea.ID<SharedArea.Person>, at: Date, body: EventBody) {
                self.sequence = sequence; self.author = author; self.at = at; self.body = body
            }
        }

        /// Which kinds a guest may give input to. A terminal is a read-only
        /// mirror: typing stays on its owner's Mac.
        public static func acceptsGuestInput(_ kind: Kind) -> Bool {
            switch kind {
            case .note, .browser: true
            case .file, .diff, .terminal: false
            }
        }

        public struct PublishState: Codable, Sendable {
            public let epoch: Int64
            public let host: SharedArea.ID<SharedArea.Host>
            public let state: State
            public init(epoch: Int64, host: SharedArea.ID<SharedArea.Host>, state: State) {
                self.epoch = epoch; self.host = host; self.state = state
            }
        }
        public struct AppendEvent: Codable, Sendable {
            public let body: EventBody
            public init(body: EventBody) { self.body = body }
        }
        public struct Appended: Codable, Equatable, Sendable {
            public let sequence: UInt64
            public init(sequence: UInt64) { self.sequence = sequence }
        }
        public struct ReadRequest: Codable, Sendable {
            /// The state the reader holds; the reply omits an unchanged state.
            public let generation: UUID?
            public let revision: UInt64?
            public let eventsAfter: UInt64?
            public let waitMilliseconds: Int
            public init(generation: UUID?, revision: UInt64?, eventsAfter: UInt64?, waitMilliseconds: Int) {
                self.generation = generation; self.revision = revision; self.eventsAfter = eventsAfter
                self.waitMilliseconds = waitMilliseconds
            }
        }
        public struct Read: Codable, Equatable, Sendable {
            /// Nil when the reader's state is current, or the host has not published.
            public let state: State?
            public let events: [Event]
            /// The newest sequence the log has assigned.
            public let eventHead: UInt64
            /// Events at or below this were dropped; a reader behind it takes the state.
            public let eventFloor: UInt64
            public init(state: State?, events: [Event], eventHead: UInt64, eventFloor: UInt64) {
                self.state = state; self.events = events; self.eventHead = eventHead; self.eventFloor = eventFloor
            }
        }

        /// Strip credentials and never publish query strings, fragments, or
        /// opaque path tokens. Private addresses are shown only as stills.
        public static func shareable(_ address: String) -> (url: String?, reach: Reach) {
            guard !address.isEmpty, var parts = URLComponents(string: address) else { return (nil, .private) }
            let signedIn = parts.user != nil || parts.password != nil
            parts.user = nil; parts.password = nil
            var opaquePath = false
            let segments = parts.path.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
                let value = String(segment)
                guard isOpaquePathSegment(value) else { return value }
                opaquePath = true
                return "*"
            }
            let reach: Reach = signedIn || parts.query != nil || parts.fragment != nil || opaquePath || isPrivateAddress(parts.url) ? .private : .public
            if opaquePath { parts.path = segments.joined(separator: "/") }
            if reach == .private { parts.query = nil; parts.fragment = nil }
            return (parts.string, reach)
        }

        private static func isOpaquePathSegment(_ value: String) -> Bool {
            guard value.count >= 24 else { return false }
            // Readable hyphenated slugs are common; mixed alphanumeric strings
            // and identifiers can carry credentials even without a known name.
            if value.contains("-"), value.allSatisfy({ $0 == "-" || $0.isLowercase }) { return false }
            let counts = Dictionary(value.map { ($0, 1) }, uniquingKeysWith: +)
            let length = Double(value.count)
            let entropy = counts.values.reduce(0.0) { result, count in
                let frequency = Double(count) / length
                return result - frequency * log2(frequency)
            }
            return entropy >= 3.5
        }

        /// A URL the guest cannot reach from their own Mac: loopback, link-local,
        /// private-network and `.local` hosts, and anything that is not http(s).
        /// Signed-in pages are judged by the host (`Browser.reach`) because only
        /// it knows; this is the address part of that judgement.
        public static func isPrivateAddress(_ url: URL?) -> Bool {
            guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !host.isEmpty else { return true }
            if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal")
                || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") || !host.contains(".") && !host.contains(":") { return true }
            if host.contains(":"), host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") { return true }
            let octets = host.split(separator: ".").compactMap { UInt8($0) }
            if octets.count == 4, host.split(separator: ".").count == 4 {
                switch (octets[0], octets[1]) {
                case (127, _), (10, _), (0, _), (192, 168), (169, 254): return true
                case (172, 16...31): return true
                case (100, 64...127): return true
                default: return false
                }
            }
            return false
        }
    }
}
