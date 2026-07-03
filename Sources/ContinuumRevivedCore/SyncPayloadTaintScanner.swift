import Foundation

// Ticket: docs/38-tickets/09-taint-scan-i5.md
//
// A pure, type-agnostic scanner over the JSON tree produced by
// `JSONSerialization.jsonObject(with:)` applied to the encoded wire form of a
// synced spatial payload (`LoggedOp`) or a projected activity payload
// (`AgentActivityEvent`). It looks for forbidden content — pid-shaped
// integers, tmux pane-target strings, host-local paths, and transcript-length
// strings — that would indicate the sync/observation type split (ticket 08)
// or the op-log envelope (ticket 02) has sprung a leak. No AppKit, no
// network: pure Foundation, so it can be called from future transport-layer
// defensive checks too.

/// One taint hit found while walking a decoded JSON tree.
public struct TaintViolation: Equatable, Sendable {
    /// Dot/bracket path to the offending value, e.g. "op.createTile.frame.x".
    public let keyPath: String
    public let pattern: TaintPattern
    /// Truncated to 200 chars for readability in failure messages.
    public let offendingValue: String

    public init(keyPath: String, pattern: TaintPattern, offendingValue: String) {
        self.keyPath = keyPath
        self.pattern = pattern
        self.offendingValue = offendingValue
    }
}

public enum TaintPattern: String, Equatable, Sendable, CaseIterable {
    case pidShapedInteger    // Int in 2...4_194_304
    case paneTargetString    // matches ^%\d+$
    case hostLocalPath       // begins with /Users/, /home/, ~/, or /var/folders/
    case transcriptBody      // String.count > 512
}

/// The exact, complete key sets the locked geometry types (`TileFrame`,
/// `ZonePoint`, `ZoneSize`) produce on the wire when encoded as a nested
/// object under a field literally named `frame`, `origin`, or `size` (see
/// `Op.encode(to:)` in SpatialOp.swift). Exempted from the pid-shaped-integer
/// check per ruling C-20260701-008 (overwatch, 2026-07-02): "legitimate
/// small-integer geometry (frame coords, counts, indices) is NOT taint; only
/// pid/handle/pane-id-shaped values or host paths crossing the sync/activity
/// boundary are taint — scan for the latter pattern, allow the former."
///
/// This exemption is required because `JSONEncoder` serializes a whole-number
/// `Double` (e.g. `TileFrame(x: 100, ...)`) without a decimal point, and
/// `JSONSerialization` then decodes that JSON number as the same kind of
/// `NSNumber` an `Int` would produce — the wire representation of a
/// legitimate frame coordinate and a hypothetical pid are indistinguishable
/// once round-tripped through JSON.
///
/// The exemption requires BOTH the parent field name AND an EXACT match of
/// the parent object's complete key set — not just the presence of one
/// recognized leaf name. Matching on a (parent, leaf) name pair alone is
/// exploitable: an arbitrary, unrelated payload shaped `{"frame": {"x":
/// 12345}}` would satisfy a name-only check even though it is missing
/// `y`/`width`/`height` and is not actually a `TileFrame`. Requiring the
/// sibling key set to match exactly closes that hole: a `frame` object
/// carrying only `x` is scanned normally and any pid-shaped value inside it
/// is still caught. A bare `x`/`width` at the top level, or nested under any
/// key other than `frame`/`origin`/`size`, is likewise never exempted.
///
/// RETRY RULING C-20260701-008 (scalar-leaf-only): the exemption is granted
/// ONLY to the scalar `NSNumber` value found DIRECTLY under a verified
/// geometry dict's key — never through an intervening array or nested
/// container. Two prior attempts leaked this:
///
/// 1. A first attempt propagated the "verified" flag through array
///    recursion unchanged, so a poisoned payload shaped like
///    `{"frame": {"x": [12345], "y": 0, "width": 0, "height": 0}}` still
///    passed the exact-key-set check while `x`'s value was an array hiding
///    a pid-shaped integer instead of the scalar `Double` a real `TileFrame`
///    always produces. Fixed by forcing `inVerifiedGeometryDict: false` for
///    every array element (see the `[Any]` case below).
/// 2. A second attempt still matched the *field name* by stripping the
///    `"[idx]"` array-index suffix back off the path component before
///    comparing it against `geometryKeySets` — so a dict reached by
///    indexing INTO an array, e.g. `{"frame": [{"x": 12345, "y": 0,
///    "width": 0, "height": 0}]}`, had its reaching path component
///    `"frame[0]"` stripped back down to `"frame"`, matched the exact key
///    set (the dict itself still has exactly x/y/width/height), and
///    re-verified as geometry even though it only exists because `frame`'s
///    *value* is an array, not the plain object a real `TileFrame` encodes
///    to. The fix: match the field name against the RAW, unstripped path
///    component. A dict reached via an array index always carries a
///    `"[idx]"` suffix on that component, which can never equal the bare
///    string `"frame"`/`"origin"`/`"size"`, so such a dict is never
///    verified — closing the loophole without needing to distinguish "was
///    this reached via an array" as a separate flag.
private let geometryKeySets: [String: Set<String>] = [
    "frame": ["x", "y", "width", "height"],
    "origin": ["x", "y"],
    "size": ["width", "height"],
]

/// True whole-number check for a decoded JSON number. `JSONSerialization`
/// hands back the same `NSNumber` shape for `2` and `2.5` — both are
/// non-integral-safe to inspect via `doubleValue`, which is exact for the
/// tiny magnitudes the pid range covers. Only a value that is actually a
/// whole number can be pid-shaped; the ticket bans pid-shaped *integers*,
/// not arbitrary JSON numbers like `2.5`.
private func isIntegralValue(_ num: NSNumber) -> Bool {
    num.doubleValue.truncatingRemainder(dividingBy: 1) == 0
}

/// Integers that are legitimately in the pid-shaped range (`2...4_194_304`)
/// for a documented non-pid reason. Starts empty — every addition MUST carry
/// an inline comment explaining why that specific integer is not a pid.
/// Widening this to hide a real false positive (rather than fixing the
/// scanner's pattern or the payload shape) defeats the whole check.
private func isKnownSafeInteger(_ i: Int) -> Bool {
    false
}

/// Walk any JSON-deserialized tree (`[String: Any]`, `[Any]`, `String`,
/// `NSNumber`, `NSNull`) and return every taint violation found.
///
/// `keyPath` is the entry point's starting path, taken as a single opaque
/// path segment (never re-split on "."), so a caller-supplied prefix that
/// happens to contain a literal dot is not misread as nesting. All
/// structural path tracking during recursion uses a real `[String]` array of
/// path components — never a flattened, re-splittable string — so a decoded
/// JSON key that literally contains a dot (e.g. a field named `"frame.x"`)
/// can never be confused with two nested keys `frame` and `x`.
public func taintCheck(_ value: Any, keyPath: String = "") -> [TaintViolation] {
    scan(value, path: keyPath.isEmpty ? [] : [keyPath], inVerifiedGeometryDict: false)
}

private func scan(_ value: Any, path: [String], inVerifiedGeometryDict: Bool) -> [TaintViolation] {
    switch value {
    case let dict as [String: Any]:
        // A dict is a "verified geometry dict" only if BOTH its own field
        // name (the key it was reached through) is EXACTLY one of
        // frame/origin/size AND its complete set of sibling keys matches
        // that type's exact shape. A partial or extra key set (e.g.
        // `{"frame": {"x": 1}}`) fails the exact-match and is scanned
        // normally. The field name is compared RAW (unstripped): a dict
        // reached via an array index carries a `"[idx]"` suffix on its
        // reaching path component (e.g. `"frame[0]"`), which never equals
        // the bare `"frame"`, so a geometry-shaped object nested inside an
        // array is never verified (RETRY RULING C-20260701-008, see the
        // doc comment on `geometryKeySets` above).
        let fieldName = path.last ?? ""
        let verified = geometryKeySets[fieldName].map { Set(dict.keys) == $0 } ?? false
        return dict.flatMap { key, child in
            scan(child, path: path + [key], inVerifiedGeometryDict: verified)
        }
    case let array as [Any]:
        // SCALAR-LEAF-ONLY (C-20260701-008 retry ruling): the geometry
        // exemption never survives a trip through an array. Every element
        // of an array is scanned as if it were NOT under a verified
        // geometry dict, regardless of what this call received — closing
        // the `{"frame": {"x": [12345], ...}}` bypass.
        return array.enumerated().flatMap { idx, child in
            scan(child, path: appendingArrayIndex(path, idx), inVerifiedGeometryDict: false)
        }
    case let str as String:
        let keyPath = path.joined(separator: ".")
        var violations: [TaintViolation] = []
        if str.count > 512 {
            violations.append(TaintViolation(
                keyPath: keyPath, pattern: .transcriptBody,
                offendingValue: String(str.prefix(200))
            ))
        }
        if str.range(of: #"^%\d+$"#, options: .regularExpression) != nil {
            violations.append(TaintViolation(
                keyPath: keyPath, pattern: .paneTargetString, offendingValue: str
            ))
        }
        let hostPrefixes = ["/Users/", "/home/", "~/", "/var/folders/"]
        if hostPrefixes.contains(where: { str.hasPrefix($0) }) {
            violations.append(TaintViolation(
                keyPath: keyPath, pattern: .hostLocalPath,
                offendingValue: String(str.prefix(200))
            ))
        }
        return violations
    case let num as NSNumber:
        let keyPath = path.joined(separator: ".")
        // GUARD FIRST: a UInt64 sequence/lamport value can exceed Int.max. Calling
        // intValue on it truncates and is meaningless. If it is bigger than
        // Int.max it cannot be a pid, so return clean early.
        if num.uint64Value > UInt64(Int.max) {
            return []
        }
        // A pid is, by definition, a whole number. A non-integral JSON
        // number (e.g. 2.5) cannot be a pid no matter its magnitude.
        guard isIntegralValue(num) else {
            return []
        }
        if inVerifiedGeometryDict {
            return []
        }
        let i = num.intValue
        if i >= 2 && i <= 4_194_304 && !isKnownSafeInteger(i) {
            return [TaintViolation(
                keyPath: keyPath, pattern: .pidShapedInteger, offendingValue: "\(i)"
            )]
        }
        return []
    default:
        return []
    }
}

/// Appends an array index to the path as a suffix on the last component
/// (e.g. `["frame"]` + idx 0 -> `["frame[0]"]`), matching the existing
/// display convention, rather than as a separate component.
private func appendingArrayIndex(_ path: [String], _ idx: Int) -> [String] {
    guard let last = path.last else { return ["[\(idx)]"] }
    var newPath = path
    newPath[newPath.count - 1] = "\(last)[\(idx)]"
    return newPath
}
