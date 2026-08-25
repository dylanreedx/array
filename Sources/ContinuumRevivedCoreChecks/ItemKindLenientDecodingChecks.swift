import ContinuumRevivedCore
import Foundation

/// B6.2's prerequisite, landed before anything needs it.
///
/// `ItemKind` was a `String`-raw enum with a SYNTHESIZED decoder, so a value it
/// had never heard of threw and failed the whole decode. These values are
/// persisted in activity events and cross to the companion, so that is a
/// data-loss bug: one build meeting a kind a newer build wrote loses the event
/// rather than the field. Adding `.compaction` or `.subagent` to the old shape
/// would have reopened it on every older install.
///
/// Behaviour, not source text: every assertion below decodes real bytes.
func runItemKindLenientDecodingChecks() throws {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()

    struct Envelope: Codable, Equatable {
        var kind: ItemKind
        var title: String
    }

    // 1. A kind this build does not know decodes instead of throwing.
    // Deliberately a kind NO build here has. `"compaction"` was used originally
    // and then became a real case, which would have quietly turned this check
    // into an assertion about a known value — the exact way a leniency witness
    // stops witnessing leniency.
    let futureBytes = Data(#"{"kind":"holographicPreview","title":"a boundary"}"#.utf8)
    let future = try decoder.decode(Envelope.self, from: futureBytes)
    expect(future.kind == .unknown("holographicPreview"),
           "B6.2: an unknown ItemKind must decode as .unknown, not throw the event away")
    expect(future.title == "a boundary",
           "B6.2: the surrounding event must survive an unknown kind")

    // 2. It round-trips VERBATIM, so passing through an older build does not
    //    silently rewrite what a newer one wrote.
    let reencoded = try encoder.encode(future)
    let restored = try decoder.decode(Envelope.self, from: reencoded)
    expect(restored == future,
           "B6.2: an unknown ItemKind must round-trip verbatim, never collapse to a default")
    expect(String(data: reencoded, encoding: .utf8)?.contains("\"holographicPreview\"") == true,
           "B6.2: re-encoding an unknown kind must emit the original raw value")

    // 3. Every known case still encodes to exactly the string it always did —
    //    a hand-written decoder is where a rename hides.
    for (kind, raw) in [
        (ItemKind.commandExecution, "commandExecution"),
        (.fileChange, "fileChange"),
        (.mcpToolCall, "mcpToolCall"),
        (.webSearch, "webSearch"),
        (.assistantMessage, "assistantMessage"),
        (.reasoning, "reasoning"),
        (.plan, "plan"),
        (.error, "error"),
        (.subagent, "subagent"),
        (.compaction, "compaction"),
    ] {
        let bytes = try encoder.encode(Envelope(kind: kind, title: raw))
        expect(String(data: bytes, encoding: .utf8)?.contains("\"\(raw)\"") == true,
               "B6.2: \(raw) must keep its historical wire spelling")
        let back = try decoder.decode(Envelope.self, from: bytes)
        expect(back.kind == kind, "B6.2: \(raw) must survive a round trip")
    }

    print("ItemKind lenient decoding checks passed: an unknown kind decodes and round-trips verbatim, and all ten known kinds keep their wire spelling")
}
