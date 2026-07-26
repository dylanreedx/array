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

// Ticket: docs/38-tickets/90-agent-ux/P4.2-effective-settled.md
//
// The precedence matrix. Two halves, deliberately:
//
//   A · A TABLE of 31 named cases with HAND-WRITTEN expectations, covering every
//       rung of the precedence order and both of the packet's named witnesses
//       (`.settled` + a pending approval, and `.settled` + a running session, each
//       of which MUST resolve `.active`). Hand-written because an oracle that
//       re-implements the precedence would pass against an inverted
//       implementation as happily as a correct one.
//   B · AN EXHAUSTIVE 1,728-case SWEEP
//       ({override × blockers × snooze × inactivity × archived × decision time}),
//       every case carrying both an expected lifecycle and the rungs' invariants.
//       This is where "total" is proven, and where a fifth blocker or a fourth
//       override case is covered the moment it is declared.
//
// P4.13 extends this file; nothing here is meant to be the last word on the
// matrix, only on the rules P4.2 rules.

/// One fixed instant, so nothing in this file reads a clock — the purity the
/// packet's "Watch out" demands is also what makes these expectations stable.
private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let anHourAgo = now.addingTimeInterval(-3_600)
private let aWeekAgo = now.addingTimeInterval(-7 * 86_400)
private let inHalfAnHour = now.addingTimeInterval(1_800)
private let halfAnHourAgo = now.addingTimeInterval(-1_800)
/// Three days, the shape of window P4.3 will convert its `autoSettleAfterDays`
/// setting into. In seconds — `resolve` takes no calendar.
private let threeDays: TimeInterval = 3 * 86_400

private struct LifecycleCase {
    let what: String
    let override: SettledOverride
    var blockers: LifecycleBlockers = .unblocked
    var settledAt: Date?
    var snoozedUntil: Date?
    var archivedAt: Date?
    var lastActivityAt: Date?
    var autoSettleAfter: TimeInterval?
    let expected: InboxLifecycle

    var resolved: InboxLifecycle {
        InboxLifecycle.resolve(
            override: override,
            blockers: blockers,
            settledAt: settledAt,
            snoozedUntil: snoozedUntil,
            archivedAt: archivedAt,
            lastActivityAt: lastActivityAt,
            autoSettleAfter: autoSettleAfter,
            now: now
        )
    }
}

// A · The table.
//
// NEGATIVE TESTS, each observed red at exit 1 against the final code and quoted
// where it lands:
//   · the blocker step made to defer to `.settled` (`if blockers.isBlocking,
//     override != .settled`) → "FAIL: precedence: a settled agent that is waiting
//     on an approval MUST resolve .active … resolved settled(…)" — the packet's
//     first named witness. Deleting the blocker step outright is red at the same
//     assertion;
//   · `resolve` narrowed to `blockers.contains(.pendingApproval)` → the second
//     named witness, "a settled agent whose session is still running MUST resolve
//     .active". REPORTED WHERE IT LANDS rather than where it was aimed: the edit
//     first tried — `.sessionRunning` subtracted inside `isBlocking` — is red one
//     check earlier, at the vocabulary check's "FAIL: 4 blocks", so it does not
//     witness this table at all;
//   · the snooze step moved ABOVE the blocker step → "a blocker pulls a snoozed
//     row back out of the shelf";
//   · the keep-active pin moved BELOW the inactivity rung → "the keep-active pin
//     suppresses auto-settle";
//   · `>` for `>=` on the inactivity comparison → "inactivity exactly at the
//     window settles (>=, not >)";
//   · `>=` for `>` on the snooze comparison → "a snooze whose moment has arrived
//     is over";
//   · the archived step moved below the blocker step → "an archived agent is out
//     of the list even with a blocker";
//   · the `settledAt ?? lastActivityAt` fallback reduced to `now` → "a settled
//     agent with no recorded decision time ends when its work went quiet".
private func runEffectiveLifecycleTableCheck() {
    let cases: [LifecycleCase] = [
        // Rung 6 — nothing said, nothing stale, nothing blocking.
        LifecycleCase(what: "an untouched agent is active",
                      override: .neutral, expected: .active),

        // Rung 3 — "I said done."
        LifecycleCase(what: "a settled agent settles, at the moment it was settled",
                      override: .settled, settledAt: anHourAgo,
                      expected: .settled(at: anHourAgo)),
        LifecycleCase(what: "a settled agent with no recorded decision time ends when its work went quiet",
                      override: .settled, lastActivityAt: aWeekAgo,
                      expected: .settled(at: aWeekAgo)),
        LifecycleCase(what: "a settled agent with no dates at all still carries one",
                      override: .settled, expected: .settled(at: now)),

        // Rung 4 — the pin.
        LifecycleCase(what: "the keep-active pin is active",
                      override: .active, expected: .active),

        // Rung 1 — THE RULE. Blockers outrank user intent, all four of them.
        LifecycleCase(what: "precedence: a settled agent that is waiting on an approval MUST resolve .active",
                      override: .settled, blockers: .pendingApproval, settledAt: anHourAgo,
                      expected: .active),
        LifecycleCase(what: "precedence: a settled agent whose session is still running MUST resolve .active",
                      override: .settled, blockers: .sessionRunning, settledAt: anHourAgo,
                      expected: .active),
        LifecycleCase(what: "a settled agent that asked a question resolves .active",
                      override: .settled, blockers: .pendingInput, settledAt: anHourAgo,
                      expected: .active),
        LifecycleCase(what: "a settled agent with a turn queued behind it resolves .active",
                      override: .settled, blockers: .queuedTurn, settledAt: anHourAgo,
                      expected: .active),
        LifecycleCase(what: "every blocker at once still resolves .active",
                      override: .settled,
                      blockers: [.pendingApproval, .pendingInput, .sessionRunning, .queuedTurn],
                      settledAt: anHourAgo, expected: .active),
        LifecycleCase(what: "a pinned agent with a blocker is active",
                      override: .active, blockers: .pendingApproval, expected: .active),
        LifecycleCase(what: "an untouched agent with a blocker is active",
                      override: .neutral, blockers: .pendingApproval, expected: .active),

        // Rung 2 — the snooze shelf.
        LifecycleCase(what: "an unexpired snooze shelves the row",
                      override: .neutral, snoozedUntil: inHalfAnHour,
                      expected: .snoozed(until: inHalfAnHour)),
        LifecycleCase(what: "a snoozed row keeps its wake-up rather than being buried as settled",
                      override: .settled, settledAt: anHourAgo, snoozedUntil: inHalfAnHour,
                      expected: .snoozed(until: inHalfAnHour)),
        LifecycleCase(what: "a snoozed row that is also pinned is still shelved",
                      override: .active, snoozedUntil: inHalfAnHour,
                      expected: .snoozed(until: inHalfAnHour)),
        LifecycleCase(what: "an expired snooze is over: the row is back",
                      override: .neutral, snoozedUntil: halfAnHourAgo,
                      expected: .active),
        LifecycleCase(what: "an expired snooze on a settled agent re-resolves the override it deferred",
                      override: .settled, settledAt: anHourAgo, snoozedUntil: halfAnHourAgo,
                      expected: .settled(at: anHourAgo)),
        LifecycleCase(what: "a snooze whose moment has arrived is over",
                      override: .neutral, snoozedUntil: now, expected: .active),
        LifecycleCase(what: "a blocker pulls a snoozed row back out of the shelf",
                      override: .neutral, blockers: .pendingApproval, snoozedUntil: inHalfAnHour,
                      expected: .active),
        LifecycleCase(what: "a queued turn pulls a snoozed row back too",
                      override: .settled, blockers: .queuedTurn, settledAt: anHourAgo,
                      snoozedUntil: inHalfAnHour, expected: .active),

        // Rung 5 — auto-settle on inactivity (P4.3 supplies the window).
        LifecycleCase(what: "a week of silence past a three-day window settles, dated when it went quiet",
                      override: .neutral, lastActivityAt: aWeekAgo, autoSettleAfter: threeDays,
                      expected: .settled(at: aWeekAgo)),
        LifecycleCase(what: "an hour of silence inside the window stays active",
                      override: .neutral, lastActivityAt: anHourAgo, autoSettleAfter: threeDays,
                      expected: .active),
        LifecycleCase(what: "inactivity exactly at the window settles (>=, not >)",
                      override: .neutral, lastActivityAt: now.addingTimeInterval(-threeDays),
                      autoSettleAfter: threeDays,
                      expected: .settled(at: now.addingTimeInterval(-threeDays))),
        LifecycleCase(what: "no configured window means no auto-settle, however old the silence",
                      override: .neutral, lastActivityAt: aWeekAgo, expected: .active),
        LifecycleCase(what: "a window with no activity date to measure against cannot settle",
                      override: .neutral, autoSettleAfter: threeDays, expected: .active),
        LifecycleCase(what: "the keep-active pin suppresses auto-settle",
                      override: .active, lastActivityAt: aWeekAgo, autoSettleAfter: threeDays,
                      expected: .active),
        LifecycleCase(what: "a blocker outranks auto-settle as well as the override",
                      override: .neutral, blockers: .pendingApproval,
                      lastActivityAt: aWeekAgo, autoSettleAfter: threeDays, expected: .active),
        LifecycleCase(what: "a snooze outranks auto-settle",
                      override: .neutral, snoozedUntil: inHalfAnHour,
                      lastActivityAt: aWeekAgo, autoSettleAfter: threeDays,
                      expected: .snoozed(until: inHalfAnHour)),
        LifecycleCase(what: "a stale settled agent settles at its own decision time, not the silence",
                      override: .settled, settledAt: anHourAgo,
                      lastActivityAt: aWeekAgo, autoSettleAfter: threeDays,
                      expected: .settled(at: anHourAgo)),

        // Rung 0 — archived leaves the list; it is not a stronger settle.
        LifecycleCase(what: "an archived agent is archived, never settled",
                      override: .neutral, archivedAt: anHourAgo, expected: .archived),
        LifecycleCase(what: "an archived agent is out of the list even with a blocker",
                      override: .settled, blockers: .pendingApproval, settledAt: anHourAgo,
                      archivedAt: anHourAgo, expected: .archived),
        LifecycleCase(what: "an archived agent is not shelved by a live snooze",
                      override: .neutral, snoozedUntil: inHalfAnHour, archivedAt: anHourAgo,
                      expected: .archived),
    ]

    for testCase in cases {
        expect(testCase.resolved == testCase.expected,
               "\(testCase.what) — expected \(testCase.expected), resolved \(testCase.resolved)")
    }

    // The table is not allowed to shrink quietly below the packet's "~30 cases",
    // and it must really exercise all four lifecycles.
    expect(cases.count >= 31,
           "the precedence table covers every rung — got \(cases.count) cases")
    for lifecycle in [InboxLifecycle.active, .archived] {
        expect(cases.contains { $0.expected == lifecycle },
               "the table expects \(lifecycle) somewhere")
    }
    expect(cases.contains { if case .settled = $0.expected { return true } else { return false } },
           "the table expects a settled row somewhere")
    expect(cases.contains { if case .snoozed = $0.expected { return true } else { return false } },
           "the table expects a snoozed row somewhere")
}

// B · Every combination, each with an expected lifecycle. 3 overrides × ALL 16 blocker
// sets × 3 snooze values × 3 activity values × 2 archive values × 2 recorded
// decision times = 1,728 resolutions. This is where TOTALITY is proven.
//
// It carries an oracle (`expected`, below) as well as invariants, on codex's
// finding: invariants alone left combinations the table does not name unpinned —
// `.neutral` + an EXPIRED snooze + stale inactivity must settle, and an
// implementation that returned `.active` for any snooze it had seen would have
// satisfied every invariant here. The oracle is the precedence order written a
// second time, which on its own would be circular; what makes it non-circular is
// that the 31-case table above states the same rules as literal input→output
// pairs, so an edit has to fool a hand-written expectation AND a re-spelling of
// the rule to get through.
//
// All 16 blocker sets and not the four singles: `LifecycleBlockers` is an
// OptionSet precisely because the facts compose, and 10 of the 16 compositions
// went unswept before this.
//
// WHERE ITS WITNESSES LAND, honestly: every mutation of `resolve` that this pass
// catches is caught by the table FIRST, because the table runs first and its 31
// cases already name each rung. So the sweep's teeth were witnessed
// independently — the blocker step made to defer to `.settled` WITH the table's
// call removed is red here at "FAIL: the precedence order holds — override
// settled, blockers 1, snooze none, activity none, settledAt false, archived
// false wanted active, resolved settled(…)". Its standing value is the three
// things the table cannot state: an expectation for every combination rather than
// 31 chosen ones, purity (the same facts twice), and that nothing resolves to a
// case the rungs do not permit.
private func runEffectiveLifecyclePropertyCheck() {
    /// The precedence order, re-spelled: what this combination MUST resolve to.
    func expected(
        override: SettledOverride,
        blockers: LifecycleBlockers,
        settledAt: Date?,
        snoozedUntil: Date?,
        archivedAt: Date?,
        lastActivityAt: Date?
    ) -> InboxLifecycle {
        if archivedAt != nil { return .archived }
        if !blockers.isEmpty { return .active }
        if let snoozedUntil, snoozedUntil > now { return .snoozed(until: snoozedUntil) }
        if override == .settled { return .settled(at: settledAt ?? lastActivityAt ?? now) }
        if override == .active { return .active }
        if let lastActivityAt, now.timeIntervalSince(lastActivityAt) >= threeDays {
            return .settled(at: lastActivityAt)
        }
        return .active
    }

    // ALL 16 blocker sets — every composition of the four facts, not just the
    // singles (codex).
    let blockerSets: [LifecycleBlockers] = (0..<16).map { LifecycleBlockers(rawValue: $0) }
    let snoozes: [Date?] = [nil, inHalfAnHour, halfAnHourAgo]
    let activities: [Date?] = [nil, anHourAgo, aWeekAgo]
    let archives: [Date?] = [nil, anHourAgo]
    // Both halves of the `settledAt ?? lastActivityAt ?? now` fallback, swept
    // rather than only named in the table.
    let decisions: [Date?] = [nil, anHourAgo]
    var resolutions = 0
    var byLifecycle: [String: Int] = [:]

    for override in SettledOverride.allCases {
        for blockers in blockerSets {
            for snoozedUntil in snoozes {
                for lastActivityAt in activities {
                    for archivedAt in archives {
                        for settledAt in decisions {
                            let facts = (
                                override: override, blockers: blockers, settledAt: settledAt,
                                snoozedUntil: snoozedUntil, archivedAt: archivedAt,
                                lastActivityAt: lastActivityAt
                            )
                            let lifecycle = InboxLifecycle.resolve(
                                override: facts.override,
                                blockers: facts.blockers,
                                settledAt: facts.settledAt,
                                snoozedUntil: facts.snoozedUntil,
                                archivedAt: facts.archivedAt,
                                lastActivityAt: facts.lastActivityAt,
                                autoSettleAfter: threeDays,
                                now: now
                            )
                            resolutions += 1
                            let inputs = """
                                override \(override.rawValue), blockers \(blockers.rawValue), \
                                snooze \(snoozedUntil.map { $0 > now ? "future" : "past" } ?? "none"), \
                                activity \(lastActivityAt.map { $0 == aWeekAgo ? "stale" : "recent" } ?? "none"), \
                                settledAt \(settledAt != nil), archived \(archivedAt != nil)
                                """

                            // The oracle: every combination has an expected answer.
                            let wanted = expected(
                                override: facts.override, blockers: facts.blockers,
                                settledAt: facts.settledAt, snoozedUntil: facts.snoozedUntil,
                                archivedAt: facts.archivedAt, lastActivityAt: facts.lastActivityAt
                            )
                            expect(lifecycle == wanted,
                                   "the precedence order holds — \(inputs) wanted \(wanted), resolved \(lifecycle)")

                            // …plus the invariants, which the oracle could not
                            // state about itself.
                            expect((lifecycle == .archived) == (archivedAt != nil),
                                   "archivedAt is the only thing that produces .archived — \(inputs) resolved \(lifecycle)")
                            if archivedAt == nil, blockers.isBlocking {
                                // THE RULE, over every combination rather than the
                                // table's named few.
                                expect(lifecycle == .active,
                                       "a blocker forces .active — \(inputs) resolved \(lifecycle)")
                            }
                            if archivedAt == nil, override == .active, !blockers.isBlocking,
                               !(snoozedUntil.map { $0 > now } ?? false) {
                                // The pin, whatever the silence.
                                expect(lifecycle == .active,
                                       "the keep-active pin is never auto-settled — \(inputs) resolved \(lifecycle)")
                            }
                            // A shelved row is shelved until the stored moment,
                            // and that moment is always in the future.
                            if case .snoozed(let until) = lifecycle {
                                expect(until == snoozedUntil && until > now,
                                       "a shelved row is shelved until exactly the stored moment — \(inputs) resolved \(lifecycle)")
                            }
                            // History never ends in the future: a settled row's
                            // date is what P3.4 sorts history on.
                            if case .settled(let at) = lifecycle {
                                expect(at <= now,
                                       "a settled row's end time is never in the future — \(inputs) resolved \(lifecycle)")
                            }

                            // Pure: the same facts resolve the same way twice.
                            let again = InboxLifecycle.resolve(
                                override: facts.override,
                                blockers: facts.blockers,
                                settledAt: facts.settledAt,
                                snoozedUntil: facts.snoozedUntil,
                                archivedAt: facts.archivedAt,
                                lastActivityAt: facts.lastActivityAt,
                                autoSettleAfter: threeDays,
                                now: now
                            )
                            expect(again == lifecycle,
                                   "resolve is pure — \(inputs) resolved \(lifecycle) then \(again)")

                            switch lifecycle {
                            case .active: byLifecycle["active", default: 0] += 1
                            case .snoozed: byLifecycle["snoozed", default: 0] += 1
                            case .settled: byLifecycle["settled", default: 0] += 1
                            case .archived: byLifecycle["archived", default: 0] += 1
                            }
                        }
                    }
                }
            }
        }
    }

    expect(resolutions == 1_728,
           "the sweep covers every combination of the six stored facts — got \(resolutions)")
    // Not vacuous: all four lifecycles are actually produced, so the sweep is not
    // 1,728 assertions about `.active`.
    for lifecycle in ["active", "snoozed", "settled", "archived"] {
        expect((byLifecycle[lifecycle] ?? 0) > 0,
               "the sweep produces \(lifecycle) somewhere — got \(byLifecycle)")
    }
    print("Effective-lifecycle sweep measured \(resolutions) combinations: \(byLifecycle.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
}

// The blocker vocabulary itself: four independent facts that compose, and the
// mapping from the pending request P3.1 already derives from the event ring.
// NEGATIVE TEST (observed red): `forPending(.input)` returning `.pendingApproval`
// → "a pending input is the input blocker, not the approval one".
private func runLifecycleBlockerVocabularyCheck() {
    expect(LifecycleBlockers.all.count == 4,
           "pending approval / pending input / running session / queued turn is four blockers — got \(LifecycleBlockers.all.count)")
    expect(Set(LifecycleBlockers.all.map(\.rawValue)).count == 4,
           "every blocker is its own bit — got \(Set(LifecycleBlockers.all.map(\.rawValue)))")
    expect(!LifecycleBlockers.unblocked.isBlocking,
           "an agent with no blockers is not blocked")
    for blocker in LifecycleBlockers.all {
        expect(blocker.isBlocking, "\(blocker.rawValue) blocks")
    }
    expect(LifecycleBlockers.forPending(.approval) == .pendingApproval,
           "a pending approval is the approval blocker")
    expect(LifecycleBlockers.forPending(.input) == .pendingInput,
           "a pending input is the input blocker, not the approval one")
    expect(LifecycleBlockers.forPending(nil) == .unblocked,
           "no pending request is no blocker")
}

func runEffectiveLifecycleChecks() {
    runLifecycleBlockerVocabularyCheck()
    runEffectiveLifecycleTableCheck()
    runEffectiveLifecyclePropertyCheck()
    print("Effective-lifecycle checks: 31 named precedence cases and 1,728 swept combinations passed — a blocker outranks \"I said done\" in every one")
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
