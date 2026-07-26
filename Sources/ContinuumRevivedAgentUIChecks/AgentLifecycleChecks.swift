import ContinuumRevivedAgentUI
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P4.1-lifecycle-state.md
//
// The pure half of P4.1's verification: `SettledOverride` itself, which lives in
// AgentUI and can therefore be checked by a target that imports AgentUI ALONE.
//
// COVERAGE SPLIT, stated rather than implied. The packet names this one file,
// but its "Verify" line asks for an `AgentRecord` Codable round-trip — and
// `AgentRecord` is in Core, which this target may not import (P1.1: the
// AgentUIChecks target depends on AgentUI alone precisely so a token reaching
// back into Core fails to compile). Splitting is the only way to honour both.
// The record half is `runAgentRecordLifecycleCheck()` in
// `ContinuumRevivedCoreChecks/AgentRecordChecks.swift`, next to the round-trip
// and decode-forward checks it extends.
//
// Three properties, each with a negative test observed red before the final
// code (quoted at each check):
//   1. THE DEFAULT IS `.neutral` — the value every agent that has never been
//      touched carries.
//   2. THE TRI-STATE IS REALLY THREE — `.active` is a distinct keep-active pin,
//      not a spelling of `.neutral`. A boolean could not carry it.
//   3. AN UNKNOWN PERSISTED WORD READS AS `.neutral` rather than throwing, and
//      a known one is never coerced.

func runAgentLifecycleChecks() {
    runSettledOverrideDefaultCheck()
    runSettledOverrideTriStateCheck()
    runSettledOverrideDecodeForwardCheck()
    print("AgentLifecycle checks: .neutral default, a distinct keep-active pin, stable raw words and decode-forward on an unknown one passed")
}

// 1 · The default.
// NEGATIVE TEST (observed red): `SettledOverride.default = .settled`
// → "FAIL: an agent nobody has ruled on is .neutral, not .settled — got settled".
private func runSettledOverrideDefaultCheck() {
    expect(SettledOverride.default == .neutral,
           "an agent nobody has ruled on is .neutral, not .settled — got \(SettledOverride.default.rawValue)")
    expect(SettledOverride(persistedRawValue: nil) == .neutral,
           "a record with no stored override at all — every record written before P4.1 — decodes as .neutral")
}

// 2 · Three states, not two. The pin is the case a boolean cannot express: with
// `.active` gone, "keep this up" and "I have not said anything" would be the
// same value and the first auto-settle sweep (P4.3) would bury a row the human
// deliberately kept.
// NEGATIVE TESTS (both observed red): deleting `case active` → the build fails
// at this file, "type 'SettledOverride' has no member 'active'", which is the
// strongest form this assertion can take (Swift also rejects the subtler edit
// of aliasing `active` onto `neutral`'s raw word outright — duplicate raw values
// do not compile, so the distinctness assertion below is a belt-and-braces
// guard against a hand-written `RawRepresentable` rather than the enum);
// and renaming a stored word, `case settled = "done"`
// → "FAIL: the persisted words are stable — got ["done", "active", "neutral"]".
private func runSettledOverrideTriStateCheck() {
    expect(SettledOverride.allCases.count == 3,
           "settle / keep-active pin / neutral is three states — got \(SettledOverride.allCases.count)")
    expect(SettledOverride.active != SettledOverride.neutral,
           "the keep-active pin is not a spelling of neutral")
    expect(Set(SettledOverride.allCases.map(\.rawValue)).count == SettledOverride.allCases.count,
           "every override persists as its own distinct word — got \(SettledOverride.allCases.count) cases and \(Set(SettledOverride.allCases.map(\.rawValue)).count) words")

    // The words themselves are pinned: they are on disk in every user's agent
    // records, so renaming one silently repoints a stored human decision.
    expect(SettledOverride.settled.rawValue == "settled"
            && SettledOverride.active.rawValue == "active"
            && SettledOverride.neutral.rawValue == "neutral",
           "the persisted words are stable — got \(SettledOverride.allCases.map(\.rawValue))")
}

// 3 · Decode-forward on the VALUE, not just the key. A downgrade meets records
// written by a newer build; losing one human decision is recoverable, throwing
// and losing the agent record is not.
// NEGATIVE TEST (observed red): `init(persistedRawValue:)` reduced to
// `self = SettledOverride(rawValue: persistedRawValue!)!`
// → the check traps at "Unexpectedly found nil"; with the force-unwraps replaced
// by a `throws` spelling the record-level witness in CoreChecks is red instead
// ("AgentRecord rejected a payload carrying an unknown future key").
private func runSettledOverrideDecodeForwardCheck() {
    for unknown in ["snoozed", "SETTLED", "", "archived", "true"] {
        expect(SettledOverride(persistedRawValue: unknown) == .neutral,
               "an override word this build has never heard of (\"\(unknown)\") reads as .neutral rather than failing the record")
    }
    // …and a word it HAS heard of is never coerced to the default, or the check
    // above would pass against an initialiser that always returns `.neutral`.
    for known in SettledOverride.allCases {
        expect(SettledOverride(persistedRawValue: known.rawValue) == known,
               "a known override word survives — \(known.rawValue) read back as \(SettledOverride(persistedRawValue: known.rawValue).rawValue)")
    }

    // Codable itself: the wire form is the bare word, so a persisted record is
    // readable and a hand-written fixture is a string, not an ordinal.
    guard let data = try? JSONEncoder().encode(SettledOverride.settled),
          let text = String(data: data, encoding: .utf8),
          let decoded = try? JSONDecoder().decode(SettledOverride.self, from: data)
    else {
        fputs("FAIL: SettledOverride failed to round-trip\n", stderr)
        Foundation.exit(1)
    }
    expect(text == "\"settled\"", "SettledOverride encodes as its word — got \(text)")
    expect(decoded == .settled, "SettledOverride round-trips")

    // …and Codable is tolerant on the SAME terms as the storage path, so a
    // second consumer cannot inherit a stricter rule by accident (codex).
    // NEGATIVE TEST (observed red): deleting the custom `init(from:)` so the
    // synthesised raw-value one takes over → "FAIL: decoding an unknown
    // override word directly is tolerant on the same terms as the record path:
    // dataCorrupted(… Cannot initialize SettledOverride from invalid String
    // value snoozed)".
    do {
        let fromTheFuture = try JSONDecoder().decode(SettledOverride.self, from: Data("\"snoozed\"".utf8))
        expect(fromTheFuture == .neutral,
               "an override word from a newer build decodes as .neutral, not as a thrown error — got \(fromTheFuture.rawValue)")
    } catch {
        fputs("FAIL: decoding an unknown override word directly is tolerant on the same terms as the record path: \(error)\n", stderr)
        Foundation.exit(1)
    }
}
