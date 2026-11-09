import Foundation

extension UUID {
    /// `lhs.uuidString < rhs.uuidString`, without building either string.
    ///
    /// `uuidString` is the sixteen bytes in order as uppercase hex with dashes
    /// at fixed positions. Hex digits sort by nibble value ('0'-'9' < 'A'-'F'),
    /// and the dashes sit at the same place in both strings, so the string
    /// order is exactly the byte order. The string form allocated twice per
    /// comparison, and the layout engine sorts by it on every pointer event of
    /// a drag and twice per geometry snapshot of the whole workspace.
    /// CoreChecks `--uuid-string-order-check` holds the two orders equal.
    @inlinable
    public static func isOrderedBeforeByString(_ lhs: UUID, _ rhs: UUID) -> Bool {
        let a = lhs.uuid, b = rhs.uuid
        if a.0 != b.0 { return a.0 < b.0 }
        if a.1 != b.1 { return a.1 < b.1 }
        if a.2 != b.2 { return a.2 < b.2 }
        if a.3 != b.3 { return a.3 < b.3 }
        if a.4 != b.4 { return a.4 < b.4 }
        if a.5 != b.5 { return a.5 < b.5 }
        if a.6 != b.6 { return a.6 < b.6 }
        if a.7 != b.7 { return a.7 < b.7 }
        if a.8 != b.8 { return a.8 < b.8 }
        if a.9 != b.9 { return a.9 < b.9 }
        if a.10 != b.10 { return a.10 < b.10 }
        if a.11 != b.11 { return a.11 < b.11 }
        if a.12 != b.12 { return a.12 < b.12 }
        if a.13 != b.13 { return a.13 < b.13 }
        if a.14 != b.14 { return a.14 < b.14 }
        return a.15 < b.15
    }
}
