import Foundation
import ContinuumRevivedCollaborationProtocol

// Mode B of the share redesign (`.plans/105-collaboration/SHARE-REDESIGN.md`):
// a portal tile on a guest's canvas that shows part of the host's canvas.
// The contract every shared tile kind implements is
// `.plans/105-collaboration/PORTAL-CONTRACT.md`; these are its wire types.
//
// Nothing here needs a relay change. A portal is an ordinary shared area:
// - agents are `agentObservation` items, exactly as in mode A;
// - every other shared tile is an `artifact` item whose revisions carry the
//   tile's content (a snapshot first, then one revision per change);
// - one more `artifact` item, the portal manifest, whose object ID is the
//   area's own ID, names every item's kind and title.
// Positions are the document's `.place` geometry, in area coordinates: the
// host's world frame minus the portal's origin, which never moves.

public enum SharedPortal {
    /// Every portal payload entry lives under this repository-relative prefix
    /// in a `.files` artifact revision. File and diff tiles may publish real
    /// git captures instead; their entries carry no prefix.
    public static let entryPrefix = "array-portal/"
    /// The manifest revision's one entry.
    public static let manifestPath = entryPrefix + "portal.json"

    /// What a shared item is on the guest. Unknown raw values decode as
    /// `.unknown`, so a newer host never breaks an older guest's portal.
    public enum ItemKind: String, Codable, Sendable, CaseIterable {
        case agent, note, file, diff, browser, terminal, unknown

        public init(from decoder: Decoder) throws {
            self = ItemKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }

        /// The local tile kinds that share as this item kind. Every other
        /// kind stays out of a portal.
        public static func forTile(_ kind: TileKind) -> ItemKind? {
            switch kind {
            case .managedAgent: return .agent
            case .note: return .note
            case .file: return .file
            case .diffReview: return .diff
            case .browser: return .browser
            case .terminal: return .terminal
            default: return nil
            }
        }
    }

    /// One shared tile, as the guest learns of it.
    public struct Entry: Codable, Equatable, Sendable {
        public let object: SharedArea.ID<SharedArea.Object>
        public let kind: ItemKind
        /// What the guest shows as its title. Kinds that must not leak a
        /// title (terminals) publish a generic one.
        public let title: String
        public init(object: SharedArea.ID<SharedArea.Object>, kind: ItemKind, title: String) {
            self.object = object; self.kind = kind; self.title = String(title.prefix(200))
        }
    }

    /// The portal manifest: its name and the shared tiles, in the order they
    /// were added. One revision per change (a tile added, a title changed).
    public struct Manifest: Codable, Equatable, Sendable {
        public var schema = 1
        public var name: String
        public var entries: [Entry]
        public init(name: String, entries: [Entry]) { self.name = String(name.prefix(120)); self.entries = entries }

        public func entry(for object: SharedArea.ID<SharedArea.Object>) -> Entry? { entries.first { $0.object == object } }
    }

    /// The manifest item's object ID: the area's own ID, so a guest can tell a
    /// portal from the document alone, before reading any artifact.
    public static func manifestObject(in area: SharedArea.ID<SharedArea.Area>) -> SharedArea.ID<SharedArea.Object> {
        .init(area.rawValue)
    }
    /// Whether an area is a portal: it holds the manifest item.
    public static func isPortal(_ document: SharedArea.Document) -> Bool {
        let manifest = manifestObject(in: document.id)
        return document.items.contains { $0.id == manifest && $0.kind == .artifact }
    }
    /// The manifest item sits at the area origin, one point square. Guests
    /// never draw it.
    public static let manifestRect = SharedArea.Rect(x: 0, y: 0, width: 1, height: 1)

    // MARK: Payloads

    // Making a revision is the sharer's work, on a Mac, like the artifact
    // producer whose `Draft` it returns. Reading one (below) is every
    // platform's, iOS included.
    #if os(macOS)
    /// A portal payload revision: named entries under `entryPrefix`. Binary
    /// content (a still picture) travels base64-encoded in an entry whose name
    /// ends `.b64`, because artifact entries are `text/plain` or `text/x-diff`.
    /// One entry is at most 1 MiB; a revision at most 8 MiB.
    public static func payloadDraft(_ entries: [String: Data], at date: Date = Date()) throws -> SharedArtifactProducer.Draft {
        let files = try entries.keys.sorted().map { name -> Collaboration.Artifact.Entry in
            let data = entries[name]!
            guard data.count <= Collaboration.Artifact.Limits.blobBytes else { throw Collaboration.Artifact.ValidationFailure.tooLarge }
            return .init(path: entryPrefix + name, change: .unchanged, coverage: .included,
                         blob: Collaboration.Artifact.digest(data), length: data.count, mediaType: "text/plain", sourceDigest: "")
        }
        var blobs: [String: Data] = [:]
        for data in entries.values { blobs[Collaboration.Artifact.digest(data)] = data }
        return .init(kind: .files, base: .init(head: nil),
                     declaration: .init(range: .files, includesCommitted: false, includesStaged: false, includesUnstaged: false,
                                        includesUntracked: false, omittedChangedPaths: 0, omittedUntrackedPaths: 0),
                     entries: files, blobs: blobs, capturedAt: Int64((date.timeIntervalSince1970 * 1000).rounded()))
    }
    /// A JSON payload as one entry, `<name>.json`.
    public static func jsonDraft<T: Encodable>(_ value: T, name: String, extra: [String: Data] = [:], at date: Date = Date()) throws -> SharedArtifactProducer.Draft {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var entries = extra
        entries[name + ".json"] = try encoder.encode(value)
        return try payloadDraft(entries, at: date)
    }
    public static func manifestDraft(_ manifest: Manifest, at date: Date = Date()) throws -> SharedArtifactProducer.Draft {
        try jsonDraft(manifest, name: "portal", at: date)
    }
    #endif
    /// The payload entries of a fetched revision, by name without the prefix.
    /// Empty for a real git capture (a file or diff published as itself).
    public static func payload(_ bytes: [String: Data]) -> [String: Data] {
        var out: [String: Data] = [:]
        for (path, data) in bytes where path.hasPrefix(entryPrefix) { out[String(path.dropFirst(entryPrefix.count))] = data }
        return out
    }
    public static func decode<T: Decodable>(_ type: T.Type, name: String, from bytes: [String: Data]) -> T? {
        guard let data = payload(bytes)[name + ".json"] else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    public static func decodeManifest(_ bytes: [String: Data]) -> Manifest? {
        guard let manifest = decode(Manifest.self, name: "portal", from: bytes), manifest.schema == 1 else { return nil }
        return manifest
    }

    // MARK: Standard payloads
    //
    // The shapes the note and browser kinds publish, so a guest of any
    // version reads them the same way. A kind may add entries beside these;
    // it must not change what these fields mean.

    /// `note.json`: the note's whole text, sent again on each save.
    public struct NotePayload: Codable, Equatable, Sendable {
        public var text: String
        /// "markdown" or "plain".
        public var format: String
        public init(text: String, format: String = "markdown") { self.text = text; self.format = format }
        public static let name = "note"
    }
    /// `browser.json`: where the page is, and whether the guest loads it
    /// ("live", a public URL) or shows the still in `still.png.b64` ("still",
    /// localhost or anything private). Cookies and sessions never travel.
    public struct BrowserPayload: Codable, Equatable, Sendable {
        public enum Mode: String, Codable, Sendable { case live, still }
        public var url: String
        public var title: String
        public var mode: Mode
        public init(url: String, title: String, mode: Mode) { self.url = url; self.title = title; self.mode = mode }
        public static let name = "browser"
        public static let stillEntry = "still.png.b64"
    }

    // MARK: Geometry

    /// Area coordinates of a host tile: its world frame minus the portal origin.
    public static func areaRect(world frame: TileFrame, origin: Origin) -> SharedArea.Rect {
        .init(x: frame.x - origin.x, y: frame.y - origin.y, width: frame.width, height: frame.height)
    }
    public struct Origin: Codable, Equatable, Sendable {
        public let x: Double
        public let y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
        /// The top-left of the frames shared when the portal was made. It never
        /// moves afterwards, so a tile's area rect changes only when it moves.
        public static func enclosing(_ frames: [TileFrame]) -> Origin {
            .init(x: frames.map(\.x).min() ?? 0, y: frames.map(\.y).min() ?? 0)
        }
    }

    /// The camera inside a portal: the area rect at the body's top-left, and
    /// how many screen points one area point takes.
    public struct Camera: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var zoom: Double
        public init(x: Double, y: Double, zoom: Double) { self.x = x; self.y = y; self.zoom = zoom }
        public static let zoomRange: ClosedRange<Double> = 0.05...4

        /// Fits `rect` into a body of `size`, centred, with `margin` points spare.
        public static func fitting(_ rect: SharedArea.Rect, in size: CGSize, margin: Double = 24) -> Camera {
            guard rect.valid, size.width > 1, size.height > 1 else { return .init(x: 0, y: 0, zoom: 1) }
            let w = max(1, Double(size.width) - 2 * margin), h = max(1, Double(size.height) - 2 * margin)
            let zoom = min(zoomRange.upperBound, max(zoomRange.lowerBound, min(w / rect.width, h / rect.height, 1)))
            return .init(x: rect.x + rect.width / 2 - Double(size.width) / zoom / 2,
                         y: rect.y + rect.height / 2 - Double(size.height) / zoom / 2, zoom: zoom)
        }
        public func screen(_ rect: SharedArea.Rect) -> CGRect {
            CGRect(x: (rect.x - x) * zoom, y: (rect.y - y) * zoom, width: rect.width * zoom, height: rect.height * zoom)
        }
        public func screen(_ point: CGPoint) -> CGPoint { CGPoint(x: (Double(point.x) - x) * zoom, y: (Double(point.y) - y) * zoom) }
        public func area(_ point: CGPoint) -> CGPoint { CGPoint(x: Double(point.x) / zoom + x, y: Double(point.y) / zoom + y) }
    }

    /// The union of the items' rects, the manifest excluded.
    public static func contentRect(_ document: SharedArea.Document) -> SharedArea.Rect? {
        let manifest = manifestObject(in: document.id)
        let rects = document.positions.filter { $0.object != manifest }.map(\.rect)
        guard let first = rects.first else { return nil }
        var minX = first.x, minY = first.y, maxX = first.x + first.width, maxY = first.y + first.height
        for r in rects.dropFirst() { minX = min(minX, r.x); minY = min(minY, r.y); maxX = max(maxX, r.x + r.width); maxY = max(maxY, r.y + r.height) }
        return .init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// What a `.sharedPortal` tile persists: the area, whose it is, and the
/// guest's own camera inside it. A reference only, never a path, record or
/// credential. Another account (or none) shows a placeholder.
public struct SharedPortalTileReference: Codable, Equatable, Sendable {
    public var areaId: UUID
    public var hostName: String
    public var hostPerson: UUID?
    /// `CollaborationLocalAccount.id` of the account that joined.
    public var accountId: String?
    /// The portal's name ("Checkout"), as it was when the link was opened.
    public var name: String
    /// The guest's pan and zoom inside the portal. Nil fits the content.
    public var camera: SharedPortal.Camera?

    public init(areaId: UUID, hostName: String, hostPerson: UUID? = nil, accountId: String? = nil, name: String,
                camera: SharedPortal.Camera? = nil) {
        self.areaId = areaId; self.hostName = hostName; self.hostPerson = hostPerson
        self.accountId = accountId; self.name = name; self.camera = camera
    }
}
