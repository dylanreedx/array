import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// T1 (`.plans/45`) — `AgentEntry.createdAt`, the supply behind the transcript's
/// hover-revealed "sent at" time.
///
/// This program's defining mistake is a renderer with no producer, so the
/// timestamp lands before the thing that draws it. Three properties carry the
/// design, and each of them is a way the obvious implementation goes wrong:
///
/// 1. **Every transcript already on disk predates the field.** A non-optional
///    `createdAt`, or a decoder that used `decode` rather than `decodeIfPresent`,
///    makes every persisted transcript in the field unreadable.
/// 2. **An unstamped reducer stays deterministic.** The reducer documents itself
///    as pure; a clock wired straight into it would make every witness that
///    compares whole documents flap. The provider defaults to `nil` and
///    production opts in.
/// 3. **A missing time renders as nothing, never as "now".** `replayCap` bounds a
///    rebuilt tile to the last 500 events, so old entries legitimately have no
///    time. Inventing one puts a false timestamp on real history.
func runAgentEntryTimestampChecks() {
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    let entryID = AgentNodeID(rawValue: "entry-1")!

    // 1. A document written before this field existed must still decode. The
    //    payload below is literally the old shape — no `createdAt` key anywhere.
    let legacyJSON = """
    {"version":1,"entries":[{"id":"entry-1","revision":0,"role":"user",
    "provenance":{"localPrompt":{"promptID":"p1"}},
    "lifecycle":{"finished":{}},"blocks":[]}]}
    """
    do {
        let decoded = try JSONDecoder().decode(AgentDocument.self, from: Data(legacyJSON.utf8))
        expect(decoded.entries.count == 1, "the legacy document must decode to one entry")
        expect(decoded.entries[0].createdAt == nil,
               "an entry persisted before createdAt existed must decode as nil, never as a "
               + "fabricated time — this is every transcript currently on disk")
    } catch {
        fputs("FAIL: a transcript persisted before createdAt existed must still decode; got \(error)\n", stderr)
        exit(1)
    }

    // 2. The default reducer stamps nothing, so a document is a pure function of
    //    its mutations and two runs compare equal.
    var unstamped = AgentDocumentReducer()
    _ = try? unstamped.apply(.beginEntry(
        id: entryID, role: .user, provenance: .localPrompt(promptID: "p1")))
    expect(unstamped.document.entries.first?.createdAt == nil,
           "the default reducer must not stamp a time — an injected-clock witness compares "
           + "whole documents and a real clock would make every one of them flap")

    // 3. An injected clock reaches the entry.
    let fixed = Date(timeIntervalSince1970: 1_700_000_000)
    var stamped = AgentDocumentReducer(createdAtProvider: { fixed })
    _ = try? stamped.apply(.beginEntry(
        id: entryID, role: .user, provenance: .localPrompt(promptID: "p1")))
    expect(stamped.document.entries.first?.createdAt == fixed,
           "an injected clock must reach AgentEntry.createdAt")

    // 4. Round-tripping preserves it, so a time survives being persisted and
    //    reloaded rather than existing only for the session that made it.
    do {
        let data = try JSONEncoder().encode(stamped.document)
        let round = try JSONDecoder().decode(AgentDocument.self, from: data)
        let back = round.entries.first?.createdAt
        expect(back.map { abs($0.timeIntervalSince(fixed)) < 0.001 } == true,
               "createdAt must survive an encode/decode round trip; got \(String(describing: back))")
    } catch {
        fputs("FAIL: a stamped document must round-trip; got \(error)\n", stderr)
        exit(1)
    }

    // 5. PRODUCTION stamps. This is the assertion with teeth: the property that
    //    actually breaks is not "the field exists" but "the shipping construction
    //    path fills it in". `AgentTranscriptProjection(threadId:)` is what
    //    `ManagedAgentTranscriptModel` builds, and its sibling init deliberately
    //    does not stamp — so asserting the model rather than the field is the
    //    only way to tell those two apart.
    var production = AgentTranscriptProjection(threadId: "thread-main")
    production.appendUserPrompt("hello")
    let producedAt = production.document.entries.first?.createdAt
    expect(producedAt != nil,
           "the PRODUCTION projection init must stamp createdAt — the field existing is not "
           + "the same as the shipping path filling it in, which is exactly the "
           + "renderer-without-a-producer failure this program exists to stop")
    expect(producedAt.map { abs($0.timeIntervalSinceNow) < 60 } == true,
           "the production stamp must be a real wall clock, not a placeholder")

    // 6. …and the injected-clock init still does not, so checks stay deterministic.
    var injected = AgentTranscriptProjection(threadId: "thread-main", monotonicNow: { 0 })
    injected.appendUserPrompt("hello")
    expect(injected.document.entries.first?.createdAt == nil,
           "the injected-clock projection init must NOT stamp, or every witness that compares "
           + "projected documents becomes time-dependent")

    // 7. `finishedAt` — the OTHER endpoint, and the one a turn's duration needs.
    //
    //    `createdAt` on an assistant entry is the moment of its first token, so a
    //    turn duration measured createdAt-to-createdAt reports time-to-first-token
    //    and drops the whole answer. `finishEntry` is the only moment that is
    //    genuinely an end, and it is the only place this is stamped: the
    //    per-token path must stay free of clock reads.
    let finishAt = Date(timeIntervalSince1970: 1_700_000_120)
    var lifecycle = AgentDocumentReducer(createdAtProvider: { finishAt })
    _ = try? lifecycle.apply(.beginEntry(
        id: entryID, role: .assistant, provenance: .providerItem(provider: "fixture", itemID: "a")))
    expect(lifecycle.document.entries.first?.finishedAt == nil,
           "an OPEN entry must have no finishedAt — a turn still streaming has not ended, and "
           + "reporting one would be a fabricated duration on live work")
    _ = try? lifecycle.apply(.finishEntry(id: entryID))
    expect(lifecycle.document.entries.first?.finishedAt == finishAt,
           "finishEntry must stamp finishedAt, or every turn header reports time-to-first-token")

    //    Same three properties createdAt owes, asserted for this field too.
    var unstampedEnd = AgentDocumentReducer()
    _ = try? unstampedEnd.apply(.beginEntry(
        id: entryID, role: .assistant, provenance: .providerItem(provider: "fixture", itemID: "a")))
    _ = try? unstampedEnd.apply(.finishEntry(id: entryID))
    expect(unstampedEnd.document.entries.first?.finishedAt == nil,
           "the default reducer must not stamp finishedAt either, or whole-document witnesses flap")
    do {
        let data = try JSONEncoder().encode(lifecycle.document)
        let round = try JSONDecoder().decode(AgentDocument.self, from: data)
        let back = round.entries.first?.finishedAt
        expect(back.map { abs($0.timeIntervalSince(finishAt)) < 0.001 } == true,
               "finishedAt must survive an encode/decode round trip; got \(String(describing: back))")
    } catch {
        fputs("FAIL: a finished document must round-trip; got \(error)\n", stderr)
        exit(1)
    }
    do {
        // The legacy payload again: it has a `finished` lifecycle and no
        // `finishedAt`, which is every transcript on disk today.
        let decoded = try JSONDecoder().decode(AgentDocument.self, from: Data(legacyJSON.utf8))
        expect(decoded.entries[0].finishedAt == nil,
               "an entry persisted before finishedAt existed must decode as nil")
    } catch {
        fputs("FAIL: the legacy document must still decode after finishedAt was added; got \(error)\n", stderr)
        exit(1)
    }

    print("AgentEntryTimestampChecks passed")
}
