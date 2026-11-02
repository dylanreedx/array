import Foundation

/// A plain-text sequence CRDT for live shared notes.
///
/// RGA (replicated growable array) with tombstones. Every element is one
/// grapheme cluster with a Lamport id; an insert names the element it follows,
/// and concurrent inserts after the same element are ordered by id (higher
/// counter first, ties by replica string), so every replica that has seen the
/// same ops shows the same text and no concurrent edit is lost.
///
/// Element boundaries travel on the wire (`Run.scalarCounts`), never re-derived
/// from the receiver's grapheme rules, so two OS versions with different Unicode
/// segmentation still agree on how many ids a run carries.
///
/// Offsets in this API count visible ELEMENTS. They equal `text`'s Characters
/// except in the rare case where concurrent inserts juxtapose pieces that
/// render as one grapheme (for example two separately inserted regional
/// indicators); the UTF-16 helpers are element-based too, so the AppKit side
/// stays consistent by always converting through them.
extension Collaboration {
    public enum NoteText {
        /// Lamport id of one element.
        public struct ID: Codable, Hashable, Comparable, Sendable {
            public let counter: UInt64
            public let replica: String
            public init(counter: UInt64, replica: String) { self.counter = counter; self.replica = replica }
            public static func < (a: ID, b: ID) -> Bool {
                a.counter != b.counter ? a.counter < b.counter : a.replica < b.replica
            }
            enum CodingKeys: String, CodingKey { case counter = "c", replica = "r" }
        }

        /// A contiguous typed string: element i has id `start.counter + i` and
        /// follows element i-1; element 0 follows `after` (nil = document start).
        public struct Run: Codable, Equatable, Sendable {
            public let start: ID
            public let after: ID?
            /// The elements concatenated.
            public let text: String
            /// Unicode scalars per element; nil when every element is one scalar.
            public let scalarCounts: [Int]?

            public var count: Int { scalarCounts?.count ?? text.unicodeScalars.count }

            init(start: ID, after: ID?, elements: [String]) {
                self.start = start
                self.after = after
                self.text = elements.joined()
                let counts = elements.map { $0.unicodeScalars.count }
                self.scalarCounts = counts.allSatisfy { $0 == 1 } ? nil : counts
            }

            var elements: [String] { NoteText.split(text, scalarCounts: scalarCounts) }
            var last: ID { ID(counter: start.counter + UInt64(max(count, 1) - 1), replica: start.replica) }

            enum CodingKeys: String, CodingKey { case replica = "r", counter = "c", after = "a", text = "t", scalarCounts = "l" }
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                start = ID(counter: try c.decode(UInt64.self, forKey: .counter), replica: try c.decode(String.self, forKey: .replica))
                after = try c.decodeIfPresent(ID.self, forKey: .after)
                text = try c.decode(String.self, forKey: .text)
                scalarCounts = try c.decodeIfPresent([Int].self, forKey: .scalarCounts)
                try NoteText.validate(text: text, scalarCounts: scalarCounts, codingPath: c.codingPath)
            }
            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(start.replica, forKey: .replica)
                try c.encode(start.counter, forKey: .counter)
                try c.encodeIfPresent(after, forKey: .after)
                try c.encode(text, forKey: .text)
                try c.encodeIfPresent(scalarCounts, forKey: .scalarCounts)
            }
        }

        /// Ids `start ..< start + count` of one replica.
        public struct IDRange: Codable, Equatable, Sendable {
            public let replica: String
            public let start: UInt64
            public let count: Int
            public init(replica: String, start: UInt64, count: Int) { self.replica = replica; self.start = start; self.count = count }
            enum CodingKeys: String, CodingKey { case replica = "r", start = "c", count = "n" }
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                replica = try c.decode(String.self, forKey: .replica)
                start = try c.decode(UInt64.self, forKey: .start)
                count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 1
            }
            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(replica, forKey: .replica)
                try c.encode(start, forKey: .start)
                if count != 1 { try c.encode(count, forKey: .count) }
            }
        }

        /// JSON: `{"i":{"r":"A","c":7,"a":{"r":"A","c":6},"t":"x"}}` or
        /// `{"d":[{"r":"A","c":3,"n":2}]}`.
        public enum Op: Codable, Equatable, Sendable {
            case insert(Run)
            case delete([IDRange])

            enum CodingKeys: String, CodingKey { case insert = "i", delete = "d" }
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                if let run = try c.decodeIfPresent(Run.self, forKey: .insert) { self = .insert(run) }
                else if let ranges = try c.decodeIfPresent([IDRange].self, forKey: .delete) { self = .delete(ranges) }
                else { throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "note text op has neither i nor d")) }
            }
            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .insert(let run): try c.encode(run, forKey: .insert)
                case .delete(let ranges): try c.encode(ranges, forKey: .delete)
                }
            }
        }

        /// Full state including tombstones, in document order, for a late joiner.
        public struct Snapshot: Codable, Equatable, Sendable {
            /// Consecutive ids of one replica, all visible (`text`) or all tombstones (`tombstones`).
            public struct Segment: Codable, Equatable, Sendable {
                public let replica: String
                public let start: UInt64
                public let text: String?
                public let scalarCounts: [Int]?
                public let tombstones: Int?
                var count: Int { text.map { _ in scalarCounts?.count ?? text!.unicodeScalars.count } ?? (tombstones ?? 0) }
                init(replica: String, start: UInt64, text: String?, scalarCounts: [Int]?, tombstones: Int?) {
                    self.replica = replica; self.start = start; self.text = text; self.scalarCounts = scalarCounts; self.tombstones = tombstones
                }
                enum CodingKeys: String, CodingKey { case replica = "r", start = "c", text = "t", scalarCounts = "l", tombstones = "n" }
                public init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    replica = try c.decode(String.self, forKey: .replica)
                    start = try c.decode(UInt64.self, forKey: .start)
                    text = try c.decodeIfPresent(String.self, forKey: .text)
                    scalarCounts = try c.decodeIfPresent([Int].self, forKey: .scalarCounts)
                    tombstones = try c.decodeIfPresent(Int.self, forKey: .tombstones)
                    if let text { try NoteText.validate(text: text, scalarCounts: scalarCounts, codingPath: c.codingPath) }
                    else if (tombstones ?? 0) < 1 {
                        throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "segment has neither text nor tombstones"))
                    }
                }
            }
            public let clock: UInt64
            public let segments: [Segment]
            public let pendingInserts: [Run]
            public let pendingDeletes: [IDRange]

            enum CodingKeys: String, CodingKey { case clock = "k", segments = "e", pendingInserts = "p", pendingDeletes = "x" }
            init(clock: UInt64, segments: [Segment], pendingInserts: [Run], pendingDeletes: [IDRange]) {
                self.clock = clock; self.segments = segments; self.pendingInserts = pendingInserts; self.pendingDeletes = pendingDeletes
            }
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                clock = try c.decode(UInt64.self, forKey: .clock)
                segments = try c.decode([Segment].self, forKey: .segments)
                pendingInserts = try c.decodeIfPresent([Run].self, forKey: .pendingInserts) ?? []
                pendingDeletes = try c.decodeIfPresent([IDRange].self, forKey: .pendingDeletes) ?? []
            }
            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(clock, forKey: .clock)
                try c.encode(segments, forKey: .segments)
                if !pendingInserts.isEmpty { try c.encode(pendingInserts, forKey: .pendingInserts) }
                if !pendingDeletes.isEmpty { try c.encode(pendingDeletes, forKey: .pendingDeletes) }
            }
        }

        /// A caret position pinned to the element on its left (nil = document start).
        public struct Anchor: Hashable, Sendable {
            public let element: ID?
        }

        /// Largest delete range or run accepted from the wire; larger ones are malformed.
        static let maxSpan = 1 << 24

        static func split(_ text: String, scalarCounts: [Int]?) -> [String] {
            var out: [String] = []
            guard let counts = scalarCounts else {
                out.reserveCapacity(text.utf8.count)
                for s in text.unicodeScalars { out.append(String(s)) }
                return out
            }
            out.reserveCapacity(counts.count)
            var it = text.unicodeScalars.makeIterator()
            for n in counts {
                var e = String.UnicodeScalarView()
                for _ in 0..<n { if let s = it.next() { e.append(s) } }
                out.append(String(e))
            }
            return out
        }

        static func validate(text: String, scalarCounts: [Int]?, codingPath: [CodingKey]) throws {
            let scalars = text.unicodeScalars.count
            let ok: Bool
            if let counts = scalarCounts { ok = !counts.isEmpty && counts.allSatisfy { $0 >= 1 } && counts.reduce(0, +) == scalars }
            else { ok = scalars >= 1 }
            if !ok { throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "note text run boundaries do not match its text")) }
        }

        /// Merges adjacent typing runs and adjacent deletes so a burst of
        /// keystrokes travels as one op. Applying the result is identical to
        /// applying the input.
        public static func coalesced(_ ops: [Op]) -> [Op] {
            var out: [Op] = []
            var pending: (start: ID, after: ID?, elements: [String])?
            func flush() {
                if let p = pending { out.append(.insert(Run(start: p.start, after: p.after, elements: p.elements))) }
                pending = nil
            }
            for op in ops {
                switch op {
                case .insert(let run):
                    if let p = pending, run.start.replica == p.start.replica,
                       run.start.counter == p.start.counter + UInt64(p.elements.count),
                       run.after == ID(counter: run.start.counter - 1, replica: run.start.replica) {
                        pending!.elements += run.elements
                    } else {
                        flush()
                        pending = (run.start, run.after, run.elements)
                    }
                case .delete(let ranges):
                    flush()
                    if case .delete(let previous)? = out.last {
                        out[out.count - 1] = .delete(mergeRanges(previous + ranges))
                    } else {
                        out.append(.delete(mergeRanges(ranges)))
                    }
                }
            }
            flush()
            return out
        }

        static func mergeRanges(_ ranges: [IDRange]) -> [IDRange] {
            var out: [IDRange] = []
            for r in ranges {
                if let l = out.last, l.replica == r.replica, l.start + UInt64(l.count) == r.start {
                    out[out.count - 1] = IDRange(replica: l.replica, start: l.start, count: l.count + r.count)
                } else { out.append(r) }
            }
            return out
        }

        /// Splits `ops` into batches whose JSON (`[Op]` through a default
        /// `JSONEncoder`) stays within `maxBytes`, splitting long runs and
        /// delete lists as needed. Order is preserved. A single element whose
        /// own encoding exceeds the budget is left whole in its own batch.
        public static func batches(_ ops: [Op], maxBytes: Int) -> [[Op]] {
            let encoder = JSONEncoder()
            func size(_ op: Op) -> Int { (try? encoder.encode(op).count) ?? Int.max }
            var pieces: [(Op, Int)] = []
            func fit(_ op: Op) {
                let s = size(op)
                if s + 2 <= maxBytes { pieces.append((op, s)); return }
                switch op {
                case .insert(let run) where run.count > 1:
                    let e = run.elements
                    let k = e.count / 2
                    fit(.insert(Run(start: run.start, after: run.after, elements: Array(e[..<k]))))
                    let second = ID(counter: run.start.counter + UInt64(k), replica: run.start.replica)
                    let secondAfter = ID(counter: second.counter - 1, replica: run.start.replica)
                    fit(.insert(Run(start: second, after: secondAfter, elements: Array(e[k...]))))
                case .delete(let ranges) where ranges.count > 1:
                    fit(.delete(Array(ranges[..<(ranges.count / 2)])))
                    fit(.delete(Array(ranges[(ranges.count / 2)...])))
                case .delete(let ranges) where ranges.count == 1 && ranges[0].count > 1:
                    let r = ranges[0], k = r.count / 2
                    fit(.delete([IDRange(replica: r.replica, start: r.start, count: k)]))
                    fit(.delete([IDRange(replica: r.replica, start: r.start + UInt64(k), count: r.count - k)]))
                default:
                    pieces.append((op, s))
                }
            }
            for op in ops { fit(op) }
            var out: [[Op]] = []
            var batch: [Op] = []
            var bytes = 2
            for (op, s) in pieces {
                let added = s + (batch.isEmpty ? 0 : 1)
                if !batch.isEmpty && bytes + added > maxBytes {
                    out.append(batch); batch = []; bytes = 2
                    batch.append(op); bytes += s
                } else {
                    batch.append(op); bytes += added
                }
            }
            if !batch.isEmpty { out.append(batch) }
            return out
        }

        /// One editor's copy of the note.
        public struct Replica: Sendable {
            struct Key: Hashable, Sendable { let counter: UInt64; let replica: Int32 }

            public let replica: String
            public private(set) var text: String = ""
            public var count: Int { visibleCount }

            private var clock: UInt64 = 0
            private var names: [String] = []
            private var nameIndex: [String: Int32] = [:]
            // Nodes, struct-of-arrays, in arrival order; `next`/`prev` link document order.
            private var keys: [Key] = []
            private var elems: [String] = []
            private var utf8Len: [Int32] = []
            private var utf16Len: [Int32] = []
            private var deleted: [Bool] = []
            private var next: [Int32] = []
            private var prev: [Int32] = []
            private var head: Int32 = -1
            private var tail: Int32 = -1
            private var index: [Key: Int32] = [:]
            private var visibleCount = 0
            /// Inserts whose `after` has not arrived, keyed by that missing id.
            private var waiting: [Key: [Run]] = [:]
            /// Deletes that arrived before the element they delete.
            private var pendingDeletes: Set<Key> = []

            public init(replica: String) {
                self.replica = replica
                _ = intern(replica)
            }

            public init(snapshot: Snapshot, replica: String) {
                self.init(replica: replica)
                merge(snapshot)
            }

            public var snapshot: Snapshot {
                var segments: [Snapshot.Segment] = []
                var cur = head
                while cur != -1 {
                    let first = cur
                    let k0 = keys[Int(first)], gone = deleted[Int(first)]
                    var parts: [String] = []
                    var n = 0
                    while cur != -1 {
                        let k = keys[Int(cur)]
                        guard k.replica == k0.replica, k.counter == k0.counter + UInt64(n), deleted[Int(cur)] == gone else { break }
                        if !gone { parts.append(elems[Int(cur)]) }
                        n += 1
                        cur = next[Int(cur)]
                    }
                    let name = names[Int(k0.replica)]
                    if gone {
                        segments.append(.init(replica: name, start: k0.counter, text: nil, scalarCounts: nil, tombstones: n))
                    } else {
                        let run = Run(start: ID(counter: k0.counter, replica: name), after: nil, elements: parts)
                        segments.append(.init(replica: name, start: k0.counter, text: run.text, scalarCounts: run.scalarCounts, tombstones: nil))
                    }
                }
                let pendingRuns = waiting.values.flatMap { $0 }.sorted { $0.start < $1.start }
                let pendingIDs = pendingDeletes.map { id($0) }.sorted()
                let ranges = NoteText.mergeRanges(pendingIDs.map { IDRange(replica: $0.replica, start: $0.counter, count: 1) })
                return Snapshot(clock: clock, segments: segments, pendingInserts: pendingRuns, pendingDeletes: ranges)
            }

            // MARK: Remote ops

            /// Merges ops from any replica. Idempotent and order-independent;
            /// an op whose dependency has not arrived is held until it does.
            public mutating func apply(_ ops: [Op]) {
                var changed = false
                var queue: [Run] = []
                for op in ops {
                    switch op {
                    case .insert(let run): if integrate(run, queue: &queue) { changed = true }
                    case .delete(let ranges): if applyDelete(ranges) { changed = true }
                    }
                    while let run = queue.popLast() { if integrate(run, queue: &queue) { changed = true } }
                }
                if changed { text = render() }
            }

            /// Applies remote ops and returns `offsets` (element offsets taken
            /// before the apply, e.g. a selection) mapped to the new text.
            public mutating func apply(_ ops: [Op], mapping offsets: [Int]) -> [Int] {
                let anchors = offsets.map { anchor(at: $0) }
                apply(ops)
                return self.offsets(of: anchors)
            }

            /// Folds another replica's snapshot into this one, keeping any of
            /// this replica's edits the snapshot has not seen. Idempotent, and
            /// equivalent to applying every op the snapshot reflects: each
            /// element is placed after its predecessor in the snapshot's order,
            /// which RGA's sibling rule resolves exactly as the original parent.
            public mutating func merge(_ snapshot: Snapshot) {
                var changed = false
                var queue: [Run] = []
                var left: Int32 = -1
                for seg in snapshot.segments {
                    let n = seg.count
                    guard n >= 1, n <= NoteText.maxSpan, seg.start <= UInt64.max - UInt64(n) else { continue }
                    let r = intern(seg.replica)
                    let parts = seg.text.map { NoteText.split($0, scalarCounts: seg.scalarCounts) }
                    clock = max(clock, seg.start + UInt64(n) - 1)
                    for i in 0..<n {
                        let k = Key(counter: seg.start + UInt64(i), replica: r)
                        if let existing = index[k] {
                            if parts == nil && !deleted[Int(existing)] {
                                deleted[Int(existing)] = true; visibleCount -= 1; changed = true
                            }
                            left = existing
                            continue
                        }
                        let node = insertNode(k, parts?[i] ?? "", after: left)
                        if parts == nil {
                            if !deleted[Int(node)] { deleted[Int(node)] = true; visibleCount -= 1 }
                        } else if !deleted[Int(node)] { changed = true }
                        if !waiting.isEmpty, let held = waiting.removeValue(forKey: k) { queue.append(contentsOf: held) }
                        left = node
                    }
                }
                clock = max(clock, snapshot.clock)
                if applyDelete(snapshot.pendingDeletes) { changed = true }
                for run in snapshot.pendingInserts { if integrate(run, queue: &queue) { changed = true } }
                while let run = queue.popLast() { if integrate(run, queue: &queue) { changed = true } }
                if changed { text = render() }
            }

            // MARK: Local edits

            /// Diffs the visible text against `newText` (common prefix/suffix by
            /// grapheme), applies the edit locally and returns the ops to send.
            public mutating func edit(to newText: String) -> [Op] {
                var old = text, new = newText
                old.makeContiguousUTF8(); new.makeContiguousUTF8()
                let oldLen = old.utf8.count, newLen = new.utf8.count
                let (p, s): (Int, Int) = old.withUTF8 { o in new.withUTF8 { n in
                    let p = NoteText.commonPrefix(o, n)
                    return (p, NoteText.commonSuffix(o, n, limit: min(oldLen, newLen) - p))
                } }
                if p == oldLen && p == newLen { return [] }

                // Prefix: last element boundary at or before p that is also a grapheme boundary in `new`.
                var (pBytes, _, left) = boundary(atOrBefore: p, total: oldLen)
                while !NoteText.isBoundary(new, pBytes) {
                    pBytes -= Int(utf8Len[Int(left)])
                    left = previousVisible(left)
                }
                // Suffix: first element boundary at or after oldLen - s, likewise aligned in `new`.
                var (qBytes, _, right) = boundary(atOrAfter: max(oldLen - s, pBytes), total: oldLen)
                while !NoteText.isBoundary(new, newLen - (oldLen - qBytes)) {
                    qBytes += Int(utf8Len[Int(right)])
                    right = nextVisible(right)
                }

                var removed: [Key] = []
                var cur = left == -1 ? head : next[Int(left)]
                while cur != -1 && cur != right {
                    if !deleted[Int(cur)] { removed.append(keys[Int(cur)]) }
                    cur = next[Int(cur)]
                }
                let lo = new.utf8.index(new.utf8.startIndex, offsetBy: pBytes)
                let hi = new.utf8.index(new.utf8.startIndex, offsetBy: newLen - (oldLen - qBytes))
                let inserted = new[lo..<hi].map { String($0) }

                var ops: [Op] = []
                if !removed.isEmpty {
                    let ranges = NoteText.mergeRanges(removed.map { IDRange(replica: names[Int($0.replica)], start: $0.counter, count: 1) })
                    ops.append(.delete(ranges))
                    _ = applyDelete(ranges)
                }
                if !inserted.isEmpty {
                    let run = Run(start: ID(counter: clock + 1, replica: replica),
                                  after: left == -1 ? nil : id(keys[Int(left)]), elements: inserted)
                    ops.append(.insert(run))
                    var queue: [Run] = []
                    _ = integrate(run, queue: &queue)
                    while let r = queue.popLast() { _ = integrate(r, queue: &queue) }
                }
                text = new
                return ops
            }

            // MARK: Carets and UTF-16

            public func anchor(at offset: Int) -> Anchor {
                guard offset > 0, visibleCount > 0 else { return Anchor(element: nil) }
                let k = min(offset, visibleCount)
                var cur: Int32, seen: Int
                if k * 2 <= visibleCount {
                    cur = head; seen = 0
                    while cur != -1 {
                        if !deleted[Int(cur)] { seen += 1; if seen == k { break } }
                        cur = next[Int(cur)]
                    }
                } else {
                    cur = tail; seen = visibleCount
                    while cur != -1 {
                        if !deleted[Int(cur)] { if seen == k { break }; seen -= 1 }
                        cur = prev[Int(cur)]
                    }
                }
                return Anchor(element: cur == -1 ? nil : id(keys[Int(cur)]))
            }

            /// Element offset just right of the anchor's element; a deleted
            /// element collapses to where it stood.
            public func offset(of anchor: Anchor) -> Int { offsets(of: [anchor])[0] }

            public func offsets(of anchors: [Anchor]) -> [Int] {
                var wanted: [Int32: [Int]] = [:]
                var result = [Int](repeating: 0, count: anchors.count)
                for (i, a) in anchors.enumerated() {
                    guard let e = a.element, let r = nameIndex[e.replica],
                          let node = index[Key(counter: e.counter, replica: r)] else { continue }
                    wanted[node, default: []].append(i)
                }
                guard !wanted.isEmpty else { return result }
                var cur = head, seen = 0, found = 0
                while cur != -1 && found < wanted.count {
                    if !deleted[Int(cur)] { seen += 1 }
                    if let slots = wanted[cur] { for i in slots { result[i] = seen }; found += 1 }
                    cur = next[Int(cur)]
                }
                return result
            }

            /// Element offset containing UTF-16 offset `utf16` (rounded down to an element start).
            public func characterOffset(utf16: Int) -> Int {
                var cur = head, units = 0, elements = 0
                while cur != -1 {
                    if !deleted[Int(cur)] {
                        units += Int(utf16Len[Int(cur)])
                        if units > utf16 { break }
                        elements += 1
                    }
                    cur = next[Int(cur)]
                }
                return elements
            }

            /// UTF-16 offset of element offset `character` (clamped to the text).
            public func utf16Offset(character: Int) -> Int {
                var cur = head, units = 0, elements = 0
                while cur != -1 && elements < character {
                    if !deleted[Int(cur)] { units += Int(utf16Len[Int(cur)]); elements += 1 }
                    cur = next[Int(cur)]
                }
                return units
            }

            // MARK: Internals

            private mutating func intern(_ name: String) -> Int32 {
                if let i = nameIndex[name] { return i }
                let i = Int32(names.count)
                names.append(name); nameIndex[name] = i
                return i
            }

            private func id(_ k: Key) -> ID { ID(counter: k.counter, replica: names[Int(k.replica)]) }

            private func isGreater(_ a: Key, _ b: Key) -> Bool {
                a.counter != b.counter ? a.counter > b.counter : names[Int(a.replica)] > names[Int(b.replica)]
            }

            /// RGA placement: after `after`, skip every following element with a
            /// greater id (greater concurrent siblings and their descendants).
            private mutating func insertNode(_ k: Key, _ e: String, after: Int32) -> Int32 {
                var l = after
                var r = l == -1 ? head : next[Int(l)]
                while r != -1 && isGreater(keys[Int(r)], k) { l = r; r = next[Int(r)] }
                let n = Int32(keys.count)
                let gone = !pendingDeletes.isEmpty && pendingDeletes.remove(k) != nil
                keys.append(k); elems.append(e)
                utf8Len.append(Int32(e.utf8.count)); utf16Len.append(Int32(e.utf16.count))
                deleted.append(gone); prev.append(l); next.append(r)
                if l == -1 { head = n } else { next[Int(l)] = n }
                if r == -1 { tail = n } else { prev[Int(r)] = n }
                index[k] = n
                if !gone { visibleCount += 1 }
                return n
            }

            /// Returns whether visible text changed.
            private mutating func integrate(_ run: Run, queue: inout [Run]) -> Bool {
                let n = run.count
                guard n >= 1, n <= NoteText.maxSpan, run.start.counter <= UInt64.max - UInt64(n) else { return false }
                let r = intern(run.start.replica)
                let first = Key(counter: run.start.counter, replica: r)
                let last = Key(counter: run.start.counter + UInt64(n) - 1, replica: r)
                clock = max(clock, last.counter)
                // Element j of a run exists only if j-1 did, so a present last element means the run is known.
                if index[last] != nil { return false }
                var left: Int32 = -1
                if let a = run.after {
                    let ak = Key(counter: a.counter, replica: intern(a.replica))
                    guard let node = index[ak] else {
                        if index[first] == nil { waiting[ak, default: []].append(run) }
                        return false
                    }
                    left = node
                }
                let parts = run.elements
                var changed = false
                for i in 0..<n {
                    let k = Key(counter: run.start.counter + UInt64(i), replica: r)
                    if let existing = index[k] { left = existing; continue }
                    left = insertNode(k, parts[i], after: left)
                    if !deleted[Int(left)] { changed = true }
                    if !waiting.isEmpty, let held = waiting.removeValue(forKey: k) { queue.append(contentsOf: held) }
                }
                return changed
            }

            private mutating func applyDelete(_ ranges: [IDRange]) -> Bool {
                var changed = false
                for range in ranges {
                    guard range.count >= 1, range.count <= NoteText.maxSpan,
                          range.start <= UInt64.max - UInt64(range.count) else { continue }
                    let r = intern(range.replica)
                    clock = max(clock, range.start + UInt64(range.count) - 1)
                    for i in 0..<range.count {
                        let k = Key(counter: range.start + UInt64(i), replica: r)
                        if let node = index[k] {
                            if !deleted[Int(node)] { deleted[Int(node)] = true; visibleCount -= 1; changed = true }
                        } else {
                            pendingDeletes.insert(k)
                        }
                    }
                }
                return changed
            }

            private func render() -> String {
                var s = ""
                s.reserveCapacity(Int(visibleCount))
                var cur = head
                while cur != -1 {
                    if !deleted[Int(cur)] { s += elems[Int(cur)] }
                    cur = next[Int(cur)]
                }
                return s
            }

            private func previousVisible(_ node: Int32) -> Int32 {
                var cur = node == -1 ? -1 : prev[Int(node)]
                while cur != -1 && deleted[Int(cur)] { cur = prev[Int(cur)] }
                return cur
            }

            private func nextVisible(_ node: Int32) -> Int32 {
                var cur = node == -1 ? -1 : next[Int(node)]
                while cur != -1 && deleted[Int(cur)] { cur = next[Int(cur)] }
                return cur
            }

            /// Largest element boundary with UTF-8 offset <= target, and the
            /// visible element left of it (-1 at document start).
            private func boundary(atOrBefore target: Int, total: Int) -> (bytes: Int, elements: Int, left: Int32) {
                if target * 2 <= total {
                    var bytes = 0, elements = 0, left: Int32 = -1, cur = head
                    while cur != -1 {
                        if !deleted[Int(cur)] {
                            let w = Int(utf8Len[Int(cur)])
                            if bytes + w > target { break }
                            bytes += w; elements += 1; left = cur
                        }
                        cur = next[Int(cur)]
                    }
                    return (bytes, elements, left)
                }
                var bytes = total, elements = visibleCount, cur = tail
                while true {
                    while cur != -1 && deleted[Int(cur)] { cur = prev[Int(cur)] }
                    if cur == -1 || bytes <= target { return (bytes, elements, cur) }
                    bytes -= Int(utf8Len[Int(cur)]); elements -= 1
                    cur = prev[Int(cur)]
                }
            }

            /// Smallest element boundary with UTF-8 offset >= target, and the
            /// visible element right of it (-1 at document end).
            private func boundary(atOrAfter target: Int, total: Int) -> (bytes: Int, elements: Int, right: Int32) {
                if target * 2 >= total {
                    var bytes = total, elements = visibleCount, right: Int32 = -1, cur = tail
                    while cur != -1 {
                        if !deleted[Int(cur)] {
                            let w = Int(utf8Len[Int(cur)])
                            if bytes - w < target { break }
                            bytes -= w; elements -= 1; right = cur
                        }
                        cur = prev[Int(cur)]
                    }
                    return (bytes, elements, right)
                }
                var bytes = 0, elements = 0, cur = head
                while true {
                    while cur != -1 && deleted[Int(cur)] { cur = next[Int(cur)] }
                    if cur == -1 || bytes >= target { return (bytes, elements, cur) }
                    bytes += Int(utf8Len[Int(cur)]); elements += 1
                    cur = next[Int(cur)]
                }
            }
        }

        // MARK: Byte diff helpers

        static func isBoundary(_ s: String, _ utf8Offset: Int) -> Bool {
            if utf8Offset <= 0 || utf8Offset >= s.utf8.count { return true }
            let i = s.utf8.index(s.utf8.startIndex, offsetBy: utf8Offset)
            return String.Index(i, within: s) != nil
        }

        static func commonPrefix(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Int {
            let limit = min(a.count, b.count)
            guard limit > 0, let pa = a.baseAddress, let pb = b.baseAddress else { return 0 }
            if memcmp(pa, pb, limit) == 0 { return limit }
            var lo = 0, hi = limit   // prefix `lo` equal, prefix `hi` not
            while hi - lo > 64 {
                let mid = (lo + hi) / 2
                if memcmp(pa, pb, mid) == 0 { lo = mid } else { hi = mid }
            }
            while lo < hi && pa[lo] == pb[lo] { lo += 1 }
            return lo
        }

        static func commonSuffix(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>, limit: Int) -> Int {
            guard limit > 0, let pa = a.baseAddress, let pb = b.baseAddress else { return 0 }
            let ea = pa + a.count, eb = pb + b.count
            if memcmp(ea - limit, eb - limit, limit) == 0 { return limit }
            var lo = 0, hi = limit
            while hi - lo > 64 {
                let mid = (lo + hi) / 2
                if memcmp(ea - mid, eb - mid, mid) == 0 { lo = mid } else { hi = mid }
            }
            while lo < hi && ea[-(lo + 1)] == eb[-(lo + 1)] { lo += 1 }
            return lo
        }
    }
}
