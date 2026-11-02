import Foundation
import ContinuumRevivedCollaborationProtocol

private typealias NT = Collaboration.NoteText

/// SplitMix64: deterministic, seedable.
private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Byte equality; Swift's String == is canonical equivalence and would call NFC and NFD equal.
private func same(_ a: String, _ b: String) -> Bool { Array(a.utf8) == Array(b.utf8) }

private func roundTrip<T: Codable>(_ value: T) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

/// Two replicas that both start from `base` (A typed it, B received it).
private func pair(_ base: String, _ a: String = "A", _ b: String = "B") -> (NT.Replica, NT.Replica) {
    var ra = NT.Replica(replica: a), rb = NT.Replica(replica: b)
    rb.apply(ra.edit(to: base))
    return (ra, rb)
}

private func randomEdit(_ text: String, _ rng: inout SeededRNG) -> String {
    let pieces = ["a", "b", "c", "xyz", " ", "\n", "e\u{301}", "é", "👍🏽", "🇺🇸", "👨‍👩‍👧", "日本", "hello "]
    var chars = Array(text)
    let roll = Int.random(in: 0..<10, using: &rng)
    if chars.isEmpty || roll < 5 {
        let at = Int.random(in: 0...chars.count, using: &rng)
        let piece = (0..<Int.random(in: 1...3, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
        chars.insert(contentsOf: Array(piece), at: at)
    } else if roll < 8 {
        let lo = Int.random(in: 0..<chars.count, using: &rng)
        let hi = min(chars.count, lo + Int.random(in: 1...4, using: &rng))
        chars.removeSubrange(lo..<hi)
    } else {
        let lo = Int.random(in: 0..<chars.count, using: &rng)
        let hi = min(chars.count, lo + Int.random(in: 1...3, using: &rng))
        chars.replaceSubrange(lo..<hi, with: Array(pieces.randomElement(using: &rng)!))
    }
    return String(chars)
}

func runNoteTextCRDTChecks() throws {
    // Concurrent typing at one spot: both survive, same order everywhere.
    do {
        var (a, b) = pair("Hello ")
        let opsA = a.edit(to: "Hello Alice")
        let opsB = b.edit(to: "Hello Bob")
        a.apply(opsB); b.apply(opsA)
        try require(same(a.text, b.text), "concurrent same-spot inserts converge: \(a.text)")
        try require(a.text.contains("Alice") && a.text.contains("Bob"), "concurrent same-spot inserts both survive")
        // Negative control: whole-text last-writer-wins keeps one edit and drops the other.
        let lww = "Hello Bob"   // B wrote last
        try require(!(lww.contains("Alice") && lww.contains("Bob")), "negative control: last-writer-wins loses a concurrent edit")
        let d = NT.Replica(snapshot: a.snapshot, replica: "D")
        try require(same(d.text, a.text), "a third replica from snapshot shows the same order")
    }

    // Insert in the middle while the other deletes around it.
    do {
        var (a, b) = pair("abcXYZdef")
        let ins = a.edit(to: "abc123XYZdef")
        let del = b.edit(to: "abZdef")
        a.apply(del); b.apply(ins)
        try require(same(a.text, "ab123Zdef") && same(b.text, "ab123Zdef"), "insert inside a concurrently deleted span survives: \(a.text)")
    }

    // Idempotent re-apply.
    do {
        var (a, b) = pair("one two three")
        let ops = a.edit(to: "one 2 three!") + a.edit(to: "zero one 2 three!")
        b.apply(ops)
        let before = b.snapshot
        b.apply(ops); b.apply(ops.reversed())
        try require(same(b.text, a.text) && b.snapshot == before, "re-applying ops is a no-op")
    }

    // Out-of-order delivery: insert after an unseen id, delete of an unseen id.
    do {
        var a = NT.Replica(replica: "A"), b = NT.Replica(replica: "B")
        let first = a.edit(to: "abc")
        let second = a.edit(to: "abcdef")
        b.apply(second)
        try require(b.text.isEmpty, "insert after an unseen id is held")
        b.apply(first)
        try require(same(b.text, "abcdef"), "held insert lands once its dependency arrives")

        var c = NT.Replica(replica: "C"), d = NT.Replica(replica: "D")
        let make = c.edit(to: "xyz")
        let remove = c.edit(to: "xz")
        d.apply(remove)
        try require(d.text.isEmpty, "delete of an unseen id changes nothing yet")
        // A snapshot taken while ops are held carries them to a late joiner.
        let late = NT.Replica(snapshot: try roundTrip(d.snapshot), replica: "E")
        d.apply(make)
        try require(same(d.text, "xz"), "held delete applies when the element arrives")
        var e = late
        e.apply(make)
        try require(same(e.text, "xz"), "held delete survives a snapshot round trip")

        var f = NT.Replica(replica: "F")
        f.apply(second)
        var g = NT.Replica(snapshot: try roundTrip(f.snapshot), replica: "G")
        g.apply(first)
        try require(same(g.text, "abcdef"), "held insert survives a snapshot round trip")
    }

    // Snapshot round trip, resuming the same replica id without id collisions.
    do {
        var (a, b) = pair("The quick brown fox")
        b.apply(a.edit(to: "The quick fox"))           // tombstones
        b.apply(a.edit(to: "The very quick fox"))
        let data = try JSONEncoder().encode(a.snapshot)
        let decoded = try JSONDecoder().decode(NT.Snapshot.self, from: data)
        try require(decoded == a.snapshot, "snapshot JSON round trip is lossless")
        var resumed = NT.Replica(snapshot: decoded, replica: "A")
        try require(same(resumed.text, a.text), "snapshot restores the text")
        let more = resumed.edit(to: "The very quick red fox")
        guard case .insert(let run)? = more.last else { throw CheckFailure(label: "resumed edit produced no insert") }
        try require(run.start.counter > decoded.clock, "resumed replica's clock is past everything in the snapshot")
        b.apply(more)
        try require(same(b.text, "The very quick red fox"), "edits after a snapshot apply cleanly elsewhere (no id collision)")
        var late = NT.Replica(snapshot: decoded, replica: "L")
        let mine = late.edit(to: "The very quick fox jumps")
        late.apply(more); b.apply(mine)
        try require(same(late.text, b.text), "late joiner from snapshot converges: \(late.text)")
    }

    // Snapshot merge: a guest that fell behind catches up without losing unsent edits.
    do {
        var (host, guest) = pair("shared note body")
        let sent = guest.edit(to: "shared note body, guest line")
        host.apply(sent)
        let unsent = guest.edit(to: "the shared note body, guest line")
        let hostOps = host.edit(to: "shared NOTE body, guest line; host line")
        var viaOps = guest
        viaOps.apply(hostOps)
        guest.merge(try roundTrip(host.snapshot))
        try require(same(guest.text, viaOps.text), "merging a snapshot that holds some of my ops equals the op path: \(guest.text)")
        try require(guest.text.hasPrefix("the ") && guest.text.contains("host line"), "merge keeps my unsent edit and the host's edit")
        host.apply(unsent)
        try require(same(host.text, guest.text), "host converges once the unsent edit arrives")
        let before = guest.snapshot
        guest.merge(host.snapshot); guest.merge(guest.snapshot)
        try require(guest.snapshot == before, "merge is idempotent")

        var (h2, g2) = pair("offline")
        let offline = g2.edit(to: "offline edits here")
        let hostOnly = h2.edit(to: "online offline")
        var opPath = g2
        opPath.apply(hostOnly)
        g2.merge(h2.snapshot)
        try require(same(g2.text, opPath.text), "merging a snapshot with none of my ops equals the op path: \(g2.text)")
        h2.apply(offline)
        try require(same(h2.text, g2.text), "both sides converge after the merge")
    }

    // Three replicas, random edits, random delivery order with duplicates and delay,
    // with some catch-ups done by snapshot merge instead of ops. Several seeds.
    var totalMerges = 0, totalElements = 0
    for seed in UInt64(1)...6 {
        var rng = SeededRNG(state: 0x5EED_0000 + seed)
        var replicas = ["r1", "r2", "r3"].map { NT.Replica(replica: $0) }
        var inbox: [[NT.Op]] = [[], [], []]
        var seen: [[NT.Op]] = [[], [], []]   // every op each replica made or applied
        var log: [NT.Op] = []
        for _ in 0..<300 {
            let who = Int.random(in: 0..<3, using: &rng)
            let target = randomEdit(replicas[who].text, &rng)
            let ops = replicas[who].edit(to: target)
            guard same(replicas[who].text, target) else { throw CheckFailure(label: "seed \(seed): local edit text mismatch") }
            log += ops; seen[who] += ops
            for other in 0..<3 where other != who {
                for op in ops {
                    inbox[other].append(op)
                    if Int.random(in: 0..<5, using: &rng) == 0 { inbox[other].append(op) }
                }
            }
            for r in 0..<3 where !inbox[r].isEmpty && Bool.random(using: &rng) {
                inbox[r].shuffle(using: &rng)
                let k = Int.random(in: 1...inbox[r].count, using: &rng)
                let batch = Array(inbox[r].prefix(k))
                replicas[r].apply(batch); seen[r] += batch
                inbox[r].removeFirst(k)
            }
            if Int.random(in: 0..<8, using: &rng) == 0 {
                let from = Int.random(in: 0..<3, using: &rng), to = (from + Int.random(in: 1...2, using: &rng)) % 3
                var opPath = replicas[to]
                opPath.apply(seen[from])
                replicas[to].merge(try roundTrip(replicas[from].snapshot))
                seen[to] += seen[from]
                totalMerges += 1
                guard same(opPath.text, replicas[to].text), opPath.snapshot.segments == replicas[to].snapshot.segments else {
                    throw CheckFailure(label: "seed \(seed): snapshot merge diverged from applying the same ops")
                }
            }
            let probe = Int.random(in: 0..<3, using: &rng)
            guard same(NT.Replica(snapshot: replicas[probe].snapshot, replica: "probe").text, replicas[probe].text) else {
                throw CheckFailure(label: "seed \(seed): text and element model disagree")
            }
        }
        for r in 0..<3 {
            inbox[r] += log
            inbox[r].shuffle(using: &rng)
            replicas[r].apply(inbox[r])
        }
        var fresh = NT.Replica(replica: "fresh")
        fresh.apply(log.reversed())
        guard same(replicas[0].text, replicas[1].text), same(replicas[1].text, replicas[2].text), same(fresh.text, replicas[0].text),
              replicas[0].snapshot.segments == replicas[1].snapshot.segments,
              replicas[1].snapshot.segments == fresh.snapshot.segments else {
            throw CheckFailure(label: "seed \(seed): replicas diverged")
        }
        totalElements += replicas[0].count
    }
    try require(totalMerges > 50, "every snapshot merge (\(totalMerges) of them) matched applying the same ops")
    try require(totalElements > 0, "6 seeds x 300 rounds x 3 replicas converge after shuffled, duplicated, delayed delivery (incl. a reverse-order replica)")

    // edit(to:) never splits a grapheme and handles NFC vs NFD as distinct bytes.
    do {
        let cases: [(String, String)] = [
            ("cafe", "cafe\u{301}"), ("hi 👍", "hi 👍🏽"), ("🇺🇸", "🇺🇸🇫🇷"), ("👨‍👩", "👨‍👩‍👧"),
            ("caf\u{E9}", "cafe\u{301}"), ("a👍🏽b", "ab"), ("日本語", "日本"),
        ]
        for (from, to) in cases {
            var (a, b) = pair(from)
            let ops = a.edit(to: to)
            b.apply(try roundTrip(ops))
            let label = "\(from.unicodeScalars.map { String($0.value, radix: 16) }) -> \(to.unicodeScalars.map { String($0.value, radix: 16) })"
            try require(same(a.text, to) && same(b.text, to) && a.count == to.count, "grapheme-safe edit \(label)")
        }
        var (a, _) = pair("cafe")
        let ops = a.edit(to: "cafe\u{301}")
        try require(ops.count == 2, "adding a combining accent replaces the whole grapheme (delete + insert)")
    }

    // Caret and selection mapping across remote applies.
    do {
        var (local, remote) = pair("Hello world")
        try require(local.apply(remote.edit(to: "Oh, Hello world"), mapping: [6]) == [10], "remote insert before the caret shifts it")
        try require(local.apply(remote.edit(to: "Oh, Hello world!"), mapping: [10]) == [10], "remote insert after the caret leaves it")
        try require(local.apply(remote.edit(to: "Oh, Helworld!"), mapping: [10]) == [7], "deleted anchor collapses to the surviving position")
        try require(local.apply(remote.edit(to: "Oh, HeXlworld!"), mapping: [4, 8]) == [4, 9], "selection grows with an insert inside it")
        try require(local.apply(remote.edit(to: "ZOh, HeXlworld!"), mapping: [0]) == [0], "caret at start stays at start")
        let (u, _) = pair("a👍🏽b")
        try require(u.utf16Offset(character: 2) == 5 && u.characterOffset(utf16: 5) == 2, "UTF-16 and element offsets agree")
        try require(u.characterOffset(utf16: 3) == 1 && u.utf16Offset(character: 99) == 6, "UTF-16 inside a grapheme rounds down; offsets clamp")
    }

    // Chunking keeps each batch under budget and reproduces the text, in any order.
    do {
        let encoder = JSONEncoder()
        var rng = SeededRNG(state: 42)
        let alphabet = Array("abcdefghij \"\\/\n") + ["👍🏽", "é", "日"].map { Character($0) }
        let big = String((0..<40_000).map { _ in alphabet.randomElement(using: &rng)! })
        var a = NT.Replica(replica: "A")
        let ops = a.edit(to: big)
        let batches = NT.batches(ops, maxBytes: 8_000)
        let sizes = try batches.map { try encoder.encode($0).count }
        try require(batches.count > 1 && sizes.allSatisfy { $0 <= 8_000 }, "\(batches.count) batches, largest \(sizes.max() ?? 0) bytes <= 8000")
        var inOrder = NT.Replica(replica: "B"), reversed = NT.Replica(replica: "C")
        for batch in batches { inOrder.apply(try roundTrip(batch)) }
        for batch in batches.reversed() { reversed.apply(batch) }
        try require(same(inOrder.text, big) && same(reversed.text, big), "applying the batches (in order and reversed) reproduces the text")

        // A fragmented delete list: every other element.
        guard case .insert(let run)? = ops.first else { throw CheckFailure(label: "no run") }
        let ranges = stride(from: 0, to: run.count, by: 2).map {
            NT.IDRange(replica: run.start.replica, start: run.start.counter + UInt64($0), count: 1)
        }
        let deleteBatches = NT.batches([.delete(ranges)], maxBytes: 160_000)
        let deleteSizes = try deleteBatches.map { try encoder.encode($0).count }
        try require(deleteBatches.count > 1 && deleteSizes.allSatisfy { $0 <= 160_000 }, "fragmented delete splits into \(deleteBatches.count) batches <= 160000")
        var full = a, chunked = a
        full.apply([.delete(ranges)])
        for batch in deleteBatches { chunked.apply(batch) }
        try require(same(full.text, chunked.text) && chunked.count == 20_000, "chunked deletes equal the whole delete")
    }

    // Performance: typing 20k characters, and loading a 20k-character snapshot.
    do {
        let clock = ContinuousClock()
        var typist = NT.Replica(replica: "T")
        var wire: [NT.Op] = []
        var text = ""
        let typing = clock.measure {
            for i in 0..<20_000 {
                text.append(i % 50 == 49 ? "\n" : Character(UnicodeScalar(UInt8(97 + i % 26))))
                wire += typist.edit(to: text)
            }
        }
        try require(same(typist.text, text) && typist.count == 20_000, "typed 20k characters one at a time in \(typing)")
        try require(typing < .seconds(2), "typing 20k characters stays under 2 s")
        let compact = NT.coalesced(wire)
        try require(compact.count == 1, "20k keystroke ops coalesce to \(compact.count) op")
        var receiver = NT.Replica(replica: "R")
        receiver.apply(compact)
        try require(same(receiver.text, text), "the coalesced op reproduces the text")

        let data = try JSONEncoder().encode(typist.snapshot)
        var loaded: NT.Replica? = nil
        let loading = clock.measure {
            if let snap = try? JSONDecoder().decode(NT.Snapshot.self, from: data) { loaded = NT.Replica(snapshot: snap, replica: "S") }
        }
        try require(loaded.map { same($0.text, text) } == true, "loaded a 20k snapshot (\(data.count) bytes) in \(loading)")
        try require(loading < .seconds(2), "loading a 20k snapshot stays under 2 s")
        var midTyped = typist
        var midText = text
        let middle = clock.measure {
            for k in 0..<500 {
                midText.insert("M", at: midText.index(midText.startIndex, offsetBy: 10_000 + k))
                _ = midTyped.edit(to: midText)
            }
        }
        try require(same(midTyped.text, midText) && middle < .seconds(2), "500 keystrokes mid-document in a 20k note took \(middle)")
    }
}
