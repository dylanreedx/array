import Foundation

// CX-01 Phase 4 (`.plans/59`, §6.2 / §8 / §14.2 / §14.3): the geometry slice of
// the `array.workspace.v1` surface — a scoped, paginated, byte-bounded read
// (`canvas.query`) and ONE allowlisted geometry operation per call
// (`canvas.apply`: move or resize). Everything in this file is pure: DTOs, the
// pagination cursor, the constraint validator and the revision compare. The
// host pipeline lives in `WorkspaceAPIService+Canvas.swift`.
//
// Rectangles are WORLD canvas units (§6.2): independent of screen pixels, zoom
// and viewport; zero, negative and non-zero origins are preserved verbatim.

public extension WorkspaceAPIOp {
    /// What the session preset grants without a prompt. `canvas.apply` is
    /// deliberately absent: the first apply for a checkout goes through the
    /// trusted approval UI, and "allow for session" covers the later ones.
    static let sessionPresetOperations: Set<WorkspaceAPIOp> = [.workspaceContext, .artifactOpen, .canvasQuery]
}

// MARK: - canvas.query

public struct CanvasQueryRequest: Codable, Equatable, Sendable {
    /// Explicit checkout; the caller's own when omitted. Any other checkout
    /// needs a grant that covers it.
    public var checkoutHandle: CheckoutHandle?
    /// Restrict the page to one zone of the scoped checkout's project.
    public var zoneId: UUID?
    /// Items per page; clamped to `1...CanvasQueryPage.maxLimit`.
    public var limit: Int?
    /// Opaque continuation from a previous page's `nextCursor`.
    public var cursor: String?

    public init(checkoutHandle: CheckoutHandle? = nil, zoneId: UUID? = nil, limit: Int? = nil, cursor: String? = nil) {
        self.checkoutHandle = checkoutHandle
        self.zoneId = zoneId
        self.limit = limit
        self.cursor = cursor
    }
}

public struct CanvasQueryZone: Codable, Equatable, Sendable {
    public var zoneId: UUID
    public var projectId: UUID?
    public var worldRect: CanvasWorldRect
    /// An installed `ZoneLayer` owns this zone's tiles. False means the host
    /// holds only the zone descriptor: its tiles are NOT in this response and an
    /// empty tile list proves nothing (§6.2).
    public var hydrated: Bool
    /// `!hydrated` — spelled out so a reader never infers freshness from absence.
    public var stale: Bool
    public var collapsed: Bool

    public init(zoneId: UUID, projectId: UUID?, worldRect: CanvasWorldRect, hydrated: Bool, collapsed: Bool) {
        self.zoneId = zoneId
        self.projectId = projectId
        self.worldRect = worldRect
        self.hydrated = hydrated
        self.stale = !hydrated
        self.collapsed = collapsed
    }
}

public struct CanvasQueryTile: Codable, Equatable, Sendable {
    public var tileId: UUID
    public var kind: String
    public var zoneId: UUID
    public var worldRect: CanvasWorldRect
    public var title: String?

    public init(tileId: UUID, kind: String, zoneId: UUID, worldRect: CanvasWorldRect, title: String?) {
        self.tileId = tileId
        self.kind = kind
        self.zoneId = zoneId
        self.worldRect = worldRect
        self.title = title
    }
}

public struct CanvasQueryResponse: Codable, Equatable, Sendable {
    public var schema: String = WorkspaceAPISchema.v1
    public var checkoutHandle: CheckoutHandle
    public var projectId: UUID?
    public var revision: WorkspaceRevision
    public var coverage: WorkspaceCoverage
    public var zones: [CanvasQueryZone]
    public var tiles: [CanvasQueryTile]
    /// Present when more items follow. Bound to `revision.structure`; a
    /// structural change expires it (`cursor_expired`).
    public var nextCursor: String?
    /// Items shed from this page to honour the byte ceiling (they follow on the
    /// next page); never a silent loss.
    public var truncated: Bool

    public init(
        checkoutHandle: CheckoutHandle, projectId: UUID?, revision: WorkspaceRevision, coverage: WorkspaceCoverage,
        zones: [CanvasQueryZone], tiles: [CanvasQueryTile], nextCursor: String? = nil, truncated: Bool = false
    ) {
        self.checkoutHandle = checkoutHandle
        self.projectId = projectId
        self.revision = revision
        self.coverage = coverage
        self.zones = zones
        self.tiles = tiles
        self.nextCursor = nextCursor
        self.truncated = truncated
    }

    public var itemCount: Int { zones.count + tiles.count }
}

/// One item of the paginated stream: zones first (document z-order), then
/// tiles (by zone, then id) — a stable order so a cursor means the same thing
/// on every page of one structural revision.
public enum CanvasQueryItem: Equatable, Sendable {
    case zone(CanvasQueryZone)
    case tile(CanvasQueryTile)
}

/// Pagination mechanics (§7.2): a cursor is `v1:<structure>:<offset>`,
/// base64url-encoded so it is opaque on the wire and refuses tampering by
/// failing to parse. It is bound to the structural revision it was minted under.
public enum CanvasQueryCursor {
    public static let version = "v1"

    public static func encode(structure: UInt64, offset: Int) -> String {
        let raw = "\(version):\(structure):\(max(0, offset))"
        return Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ cursor: String) -> (structure: UInt64, offset: Int)? {
        var base64 = cursor.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64), let raw = String(data: data, encoding: .utf8) else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == Substring(version),
              let structure = UInt64(parts[1]), let offset = Int(parts[2]), offset >= 0 else { return nil }
        return (structure, offset)
    }
}

public enum CanvasQueryPage {
    public static let defaultLimit = 50
    public static let maxLimit = 50
    /// Upper bound on one encoded page. Enforced by shedding trailing items onto
    /// the next page, never by truncating an identity.
    public static let encodedByteCeiling = 12 * 1024

    public static func clampedLimit(_ requested: Int?) -> Int {
        min(max(requested ?? defaultLimit, 1), maxLimit)
    }

    public enum CursorOutcome: Equatable, Sendable {
        case start(offset: Int)
        case malformed
        case expired
    }

    /// Where a page starts. A cursor minted under another structural revision is
    /// expired, not silently re-based: the stream it indexed no longer exists.
    public static func resolveCursor(_ cursor: String?, currentStructure: UInt64) -> CursorOutcome {
        guard let cursor, !cursor.isEmpty else { return .start(offset: 0) }
        guard let decoded = CanvasQueryCursor.decode(cursor) else { return .malformed }
        guard decoded.structure == currentStructure else { return .expired }
        return .start(offset: decoded.offset)
    }

    /// Slice `items` into one page: at most `limit` items from `offset`, shed
    /// from the end until the encoded page fits `byteCeiling` (keeping at least
    /// one item so a single oversized item can still be delivered), and mint the
    /// continuation cursor when anything remains.
    public static func page(
        items: [CanvasQueryItem],
        offset: Int,
        limit: Int,
        structure: UInt64,
        byteCeiling: Int = encodedByteCeiling,
        encodedSize: ([CanvasQueryItem]) -> Int
    ) -> (items: [CanvasQueryItem], nextCursor: String?, truncated: Bool) {
        let start = min(max(offset, 0), items.count)
        var slice = Array(items[start..<min(start + limit, items.count)])
        var truncated = false
        while slice.count > 1, encodedSize(slice) > byteCeiling {
            slice.removeLast()
            truncated = true
        }
        let end = start + slice.count
        let next = end < items.count ? CanvasQueryCursor.encode(structure: structure, offset: end) : nil
        return (slice, next, truncated)
    }
}

// MARK: - canvas.apply

public struct CanvasApplyRequest: Codable, Equatable, Sendable {
    public enum Op: String, Codable, Sendable { case move, resize }

    public var op: Op
    public var tileId: UUID
    /// The complete target rectangle. For `move` only its origin is used; for
    /// `resize` its size, and its origin when supplied.
    public var worldFrame: CanvasWorldRect?
    /// Alternative spelling: `move` may pass just an origin; `resize` just a size.
    public var origin: CanvasWorldPoint?
    public var size: CanvasWorldSize?
    /// Must equal the host's current `{epoch, structure}` or nothing is applied.
    public var expectedRevision: WorkspaceRevision
    public var idempotencyKey: String?

    public init(
        op: Op, tileId: UUID, worldFrame: CanvasWorldRect? = nil, origin: CanvasWorldPoint? = nil,
        size: CanvasWorldSize? = nil, expectedRevision: WorkspaceRevision, idempotencyKey: String? = nil
    ) {
        self.op = op
        self.tileId = tileId
        self.worldFrame = worldFrame
        self.origin = origin
        self.size = size
        self.expectedRevision = expectedRevision
        self.idempotencyKey = idempotencyKey
    }
}

public struct CanvasWorldSize: Hashable, Codable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct CanvasApplyResult: Codable, Equatable, Sendable {
    public enum Durability: String, Codable, Sendable {
        /// The owner's persistence barrier ran and the frame is on disk.
        case committed
        /// The owner's layout engine resolved the request to the tile's current
        /// frame; nothing changed, nothing was written.
        case unchanged
    }

    public var schema: String = WorkspaceAPISchema.v1
    public var operationId: String
    public var op: CanvasApplyRequest.Op
    public var tileId: UUID
    public var requestedWorldRect: CanvasWorldRect
    /// Where the tile actually is after the owner's constraints and auto-layout.
    public var actualWorldRect: CanvasWorldRect
    public var actualZoneId: UUID?
    /// The requested size was raised to the kind's minimum, as a pointer resize is.
    public var clamped: Bool
    public var durability: Durability
    /// Whether the owner's geometry history recorded this edit (the user's Undo).
    public var undoRegistered: Bool
    public var revision: WorkspaceRevision
    public var presentationEffects: WorkspacePresentationEffects

    public init(
        operationId: String, op: CanvasApplyRequest.Op, tileId: UUID, requestedWorldRect: CanvasWorldRect,
        actualWorldRect: CanvasWorldRect, actualZoneId: UUID?, clamped: Bool, durability: Durability,
        undoRegistered: Bool, revision: WorkspaceRevision, presentationEffects: WorkspacePresentationEffects = .allPreserved
    ) {
        self.operationId = operationId
        self.op = op
        self.tileId = tileId
        self.requestedWorldRect = requestedWorldRect
        self.actualWorldRect = actualWorldRect
        self.actualZoneId = actualZoneId
        self.clamped = clamped
        self.durability = durability
        self.undoRegistered = undoRegistered
        self.revision = revision
        self.presentationEffects = presentationEffects
    }
}

/// Pure geometry validation (§14.2 step 4). Produces the frame the owner route
/// will be asked for, or the reason the request is invalid. Never touches a model.
public enum CanvasGeometryConstraints {
    /// Coordinates and dimensions beyond this are not a canvas the app can
    /// present; refusing them keeps the world finite for every other reader.
    public static let worldBound: Double = 1_000_000

    public struct Plan: Equatable, Sendable {
        public var requested: CanvasWorldRect
        public var target: CanvasWorldRect
        public var clamped: Bool
    }

    public enum Rejection: Error, Equatable, Sendable, CustomStringConvertible {
        case missingGeometry(String)
        case nonFinite
        case outOfBounds
        case nonPositiveSize

        public var description: String {
            switch self {
            case let .missingGeometry(what): return what
            case .nonFinite: return "Every coordinate and dimension must be a finite number."
            case .outOfBounds: return "The frame must lie within ±\(Int(worldBound)) world units."
            case .nonPositiveSize: return "Width and height must be positive."
            }
        }
    }

    public static func plan(
        _ request: CanvasApplyRequest,
        currentWorldFrame: CanvasWorldRect,
        minimumSize: CanvasWorldSize
    ) -> Result<Plan, Rejection> {
        let requested: CanvasWorldRect
        switch request.op {
        case .move:
            guard let origin = request.origin ?? request.worldFrame.map({ CanvasWorldPoint(x: $0.x, y: $0.y) }) else {
                return .failure(.missingGeometry("move needs `origin` or `worldFrame`."))
            }
            requested = CanvasWorldRect(x: origin.x, y: origin.y, width: currentWorldFrame.width, height: currentWorldFrame.height)
        case .resize:
            guard let size = request.size ?? request.worldFrame.map({ CanvasWorldSize(width: $0.width, height: $0.height) }) else {
                return .failure(.missingGeometry("resize needs `size` or `worldFrame`."))
            }
            let origin = request.worldFrame.map { CanvasWorldPoint(x: $0.x, y: $0.y) }
                ?? CanvasWorldPoint(x: currentWorldFrame.x, y: currentWorldFrame.y)
            requested = CanvasWorldRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
        }
        let values = [requested.x, requested.y, requested.width, requested.height]
        guard values.allSatisfy(\.isFinite) else { return .failure(.nonFinite) }
        guard requested.width > 0, requested.height > 0 else { return .failure(.nonPositiveSize) }
        guard values.allSatisfy({ abs($0) <= worldBound }) else { return .failure(.outOfBounds) }
        // The pointer path (`CanvasEngine.tile(_:resizedByScreenDelta:…)`) clamps
        // to the kind's minimum rather than refusing; the API does the same and
        // says so.
        var target = requested
        var clamped = false
        if request.op == .resize {
            if target.width < minimumSize.width { target.width = minimumSize.width; clamped = true }
            if target.height < minimumSize.height { target.height = minimumSize.height; clamped = true }
        }
        return .success(Plan(requested: requested, target: target, clamped: clamped))
    }
}

public extension WorkspaceRevision {
    /// Exact match on both halves: a handle minted under another host epoch is
    /// as stale as one minted before a structural change.
    func matches(_ current: WorkspaceRevision) -> Bool {
        epoch == current.epoch && structure == current.structure
    }
}
