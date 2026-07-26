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

// Ticket: docs/38-tickets/90-agent-ux/P2D.5-child-rollup.md
//
// A PARENT IS NOT SETTLEABLE WHILE ANYTHING UNDER IT IS BLOCKED OR RUNNING — the
// packet's second half, and deliberately the SAME rule as "a blocker outranks an
// explicit settle" rather than a new one: a descendant's blockers are folded into
// the parent's before `resolve` ever runs, so they land on step 1 and everything
// already proved about that step applies unchanged.
//
// THE CONSEQUENCE THAT MAKES THE COLLAPSED ROW SAFE, asserted at the bottom: a
// parent holding a blocked descendant resolves `.active`, and
// `RowVariant.forLifecycle(.active)` is a full CARD. So the row that has to show a
// rollup always has the card's room to show it in, and the one-line parked variant
// never has to carry one.
//
// SIX NEGATIVE TESTS OBSERVED RED at exit 1 against the final code, quoted VERBATIM
// and reported WHERE THEY LANDED rather than where they were aimed — the set-algebra
// block runs first, so three of the four mutations below are caught by it before the
// named witness ever evaluates:
//   1. `includingDescendants` returning `self` (children ignored) → "any descendant
//      blocks, not just the first — got 0"
//   2. …returning `descendants.reduce(.unblocked)` (the agent's own lost) → "an
//      agent's own blocker survives the rollup — got 0"
//   3. …folding with `intersection` instead of `union` → "any descendant blocks, not
//      just the first — got 0"
//   4. …unioning only `descendants.first` → "any descendant blocks, not just the
//      first — got 0"
//   5. mutation 1 AGAIN with the set-algebra block deleted, so the named witness is
//      the only thing left that can catch it → "a blocked child outranks the parent's
//      own \"I said done\" — got settled(at: 2026-07-26 20:20:00 +0000)". This is the
//      one that proves the witness has teeth of its own.
//   6. `resolve`'s blocker rung made to defer to `.settled` — the P4.2 rung this
//      whole ticket rides on. It is red one check EARLIER, at P4.2's own table:
//      "precedence: a settled agent that is waiting on an approval MUST resolve
//      .active — expected active, resolved settled(…)". The dependency is therefore
//      guarded by its owner, which is where it belongs.
private func runParentBlockedByDescendantCheck() {
    let now = Date(timeIntervalSinceReferenceDate: 806_800_000)
    let quiet = now.addingTimeInterval(-10_000)

    // The rollup itself, as a set operation: total, associative, idempotent.
    expect(LifecycleBlockers.unblocked.includingDescendants([]) == .unblocked,
           "a childless agent's blockers are its own")
    expect(LifecycleBlockers.pendingApproval.includingDescendants([]) == .pendingApproval,
           "an agent's own blocker survives the rollup — got \(LifecycleBlockers.pendingApproval.includingDescendants([]).rawValue)")
    expect(LifecycleBlockers.unblocked.includingDescendants([.unblocked, .unblocked]) == .unblocked,
           "quiet children add nothing")
    expect(LifecycleBlockers.unblocked.includingDescendants([.unblocked, .queuedTurn]) == .queuedTurn,
           "any descendant blocks, not just the first — got \(LifecycleBlockers.unblocked.includingDescendants([.unblocked, .queuedTurn]).rawValue)")
    expect(LifecycleBlockers.pendingInput.includingDescendants([.sessionRunning])
           == [.pendingInput, .sessionRunning],
           "the parent's blockers and its children's are both kept")
    // Associativity: rolling a chain up one level at a time is the same answer as
    // one flat call, which is what lets a caller reuse a child's rolled-up set.
    let grandchild = LifecycleBlockers.pendingApproval
    let child = LifecycleBlockers.sessionRunning.includingDescendants([grandchild])
    expect(LifecycleBlockers.unblocked.includingDescendants([child])
           == LifecycleBlockers.unblocked.includingDescendants([.sessionRunning, grandchild]),
           "rolling a chain up level by level is the same as one flat roll")
    expect(child.includingDescendants([child]) == child, "the roll is idempotent")

    // THE NAMED WITNESS: a parent that said "done", with a child that has not.
    // Every blocker in turn, so a fifth one is covered the moment it is declared.
    for blocker in LifecycleBlockers.all {
        let resolved = InboxLifecycle.resolve(
            override: .settled,
            blockers: LifecycleBlockers.unblocked.includingDescendants([blocker]),
            settledAt: quiet, lastActivityAt: quiet, now: now)
        expect(resolved == .active,
               "a blocked child outranks the parent's own \"I said done\" — got \(resolved)")
        // …and the row it produces is a full card, which is the room the rollup line
        // needs. This is what makes the one-line parked variant's silence honest.
        expect(RowVariant.forLifecycle(resolved) == .card,
               "a parent held open by a child is a card, so it has room for its rollup — got \(RowVariant.forLifecycle(resolved).rawValue)")
    }
    // A snooze does not hide it either: blockers are above the snooze rung too, so
    // parking a parent cannot park a child's raised hand with it.
    let snoozedParent = InboxLifecycle.resolve(
        override: .settled,
        blockers: LifecycleBlockers.unblocked.includingDescendants([.pendingApproval]),
        snoozedUntil: now.addingTimeInterval(3_600), lastActivityAt: quiet, now: now)
    expect(snoozedParent == .active,
           "a blocked child pulls a snoozed parent back too — got \(snoozedParent)")

    // WHEN EVERY CHILD SETTLES, THE PARENT BECOMES SETTLEABLE. The packet's third
    // named case, and the one that proves the rule is not simply "parents never
    // settle".
    let allQuiet = InboxLifecycle.resolve(
        override: .settled,
        blockers: LifecycleBlockers.unblocked.includingDescendants([.unblocked, .unblocked]),
        settledAt: quiet, lastActivityAt: quiet, now: now)
    expect(allQuiet == .settled(at: quiet),
           "when everything under it is quiet the parent settles as it was told to — got \(allQuiet)")
    expect(RowVariant.forLifecycle(allQuiet) == .slim,
           "…and then it collapses like any settled row")

    // The parent's OWN blocker still works with no children at all — the rollup is
    // an addition to step 1, not a replacement for it.
    let ownBlocker = InboxLifecycle.resolve(
        override: .settled, blockers: LifecycleBlockers.pendingApproval.includingDescendants([]),
        settledAt: quiet, lastActivityAt: quiet, now: now)
    expect(ownBlocker == .active, "a childless agent's own blocker is unchanged by this ticket")
}

// Ticket: docs/38-tickets/90-agent-ux/P4.6-snooze-raised-hand.md
//
// THE EARLY WAKE, and the line it must not cross. A snooze may never hide
// something that needs you; it also may not un-snooze for what you had already
// seen when you set it. Those two pull in opposite directions, and every case
// here is about where the line between them sits.
//
// Three parts:
//   A · the predicate, as a table of named cases — including the packet's five
//       verify cases, with the pre-existing failure (`snoozedAt - 1s`) as THE
//       witness;
//   B · the boundary swept second-by-second across `snoozedAt`, so the strict
//       `>` is pinned rather than implied by two hand-picked instants;
//   C · what a raised hand DOES: it withholds the shelf date from `resolve` (so
//       the row is back) without clearing the stored snooze, and the row carries
//       `.woke` (P3.3), which outranks `unread`.
//
// SIX NEGATIVE TESTS OBSERVED RED at exit 1 against the final code, quoted
// verbatim and reported where they LAND:
//   1. `>=` for `>` on the failure newness — the one edit the packet's witness
//      exists for → "FAIL: a failure at snoozedAt +0s does not wake a snoozed row
//      — got true". Caught by the boundary sweep rather than by the table, which
//      is why the sweep is here: the table's two hand-picked instants are ±1s and
//      both stay green under it.
//   2. a missing `snoozedAt` read as `Date.distantPast` (the plausible spelling of
//      "no reference point") → "FAIL: a pre-P4.6 snooze with no recorded moment
//      does not wake on a failure it cannot date — expected still snoozed, got
//      woken".
//   3. the pending signal made to require newness too → "FAIL: a pending approval
//      while snoozed raises the hand — expected woken, got still snoozed".
//   4. `snoozeHonoured` reduced to `record.snoozedUntil` (the predicate computed
//      and then ignored) → "FAIL: a new failure pulls the row off the shelf — got
//      snoozed(until: …)".
//   5. the not-snoozed guard deleted → "FAIL: an agent that is not snoozed has no
//      hand to raise — expected still snoozed, got woken". Without it every failed
//      agent in the list would read as permanently woke.
//   6. the completed-run signal dropped → "FAIL: a run completing after the snooze
//      was set raises the hand — expected woken, got still snoozed".
//
// The record half — `snoozedAt` persisted at all — is witnessed in CoreChecks,
// where the field lives: `snoozedAt` encoded onto `snoozedUntil`'s key is red at
// the lifecycle sweep ("round-trips every lifecycle date exactly — 200 of 200
// differed"), and dropping it from `encode(to:)` with that sweep blinded is red at
// the named assertion ("when a snooze was set and when it ends are two facts —
// snoozedAt nil").
private let snoozeSet = anHourAgo
private let snoozeEnds = inHalfAnHour

private struct RaisedHandCase {
    let what: String
    let record: SnoozedAgentFacts
    let expected: Bool

    var raised: Bool { InboxLifecycle.raisedHandWhileSnoozed(record: record, now: now) }
}

private func runRaisedHandTableCheck() {
    /// A live snooze, set an hour ago and ending in half an hour, with whichever
    /// signal the case is about laid over it.
    func snoozed(
        pending: PendingRequest? = nil,
        failedAt: Date? = nil,
        runCompletedAt: Date? = nil,
        snoozedAt: Date? = snoozeSet,
        snoozedUntil: Date? = snoozeEnds
    ) -> SnoozedAgentFacts {
        SnoozedAgentFacts(snoozedUntil: snoozedUntil, snoozedAt: snoozedAt,
                          pending: pending, failedAt: failedAt, runCompletedAt: runCompletedAt)
    }

    let cases: [RaisedHandCase] = [
        // The packet's five, in its own words.
        RaisedHandCase(what: "a pending approval while snoozed raises the hand",
                       record: snoozed(pending: .approval), expected: true),
        RaisedHandCase(what: "a failure one second BEFORE the snooze was set stays snoozed — the human saw it and said not now",
                       record: snoozed(failedAt: snoozeSet.addingTimeInterval(-1)), expected: false),
        RaisedHandCase(what: "a failure one second after the snooze was set raises the hand",
                       record: snoozed(failedAt: snoozeSet.addingTimeInterval(1)), expected: true),
        RaisedHandCase(what: "a run completing after the snooze was set raises the hand",
                       record: snoozed(runCompletedAt: snoozeSet.addingTimeInterval(60)), expected: true),
        RaisedHandCase(what: "nothing happening leaves the row snoozed until its wake-up",
                       record: snoozed(), expected: false),

        // The other pending kind — a question with nothing to approve is just as
        // much someone waiting on you (P3.1's two-case `PendingRequest`).
        RaisedHandCase(what: "a pending question while snoozed raises the hand too",
                       record: snoozed(pending: .input), expected: true),
        // A pending request has no newness test, deliberately: it is unanswered
        // now, whenever it was asked, and `resolve`'s step 1 already un-shelves a
        // blocked row however old the block is.
        RaisedHandCase(what: "an approval that was already open when the snooze was set still raises the hand",
                       record: snoozed(pending: .approval, failedAt: snoozeSet.addingTimeInterval(-3_600)),
                       expected: true),

        // The mirror of the witness, for the run signal.
        RaisedHandCase(what: "a run that completed BEFORE the snooze was set stays snoozed",
                       record: snoozed(runCompletedAt: snoozeSet.addingTimeInterval(-60)), expected: false),
        RaisedHandCase(what: "an old failure and an old run together still stay snoozed",
                       record: snoozed(failedAt: snoozeSet.addingTimeInterval(-1),
                                       runCompletedAt: snoozeSet.addingTimeInterval(-1)),
                       expected: false),
        RaisedHandCase(what: "one new signal beside an old one is enough",
                       record: snoozed(failedAt: snoozeSet.addingTimeInterval(-1),
                                       runCompletedAt: snoozeSet.addingTimeInterval(1)),
                       expected: true),

        // NOT SNOOZED — there is nothing to wake early from, and answering true
        // would make every failed agent in the list permanently "woke".
        RaisedHandCase(what: "an agent that is not snoozed has no hand to raise",
                       record: SnoozedAgentFacts(pending: .approval,
                                                 failedAt: now.addingTimeInterval(-1)),
                       expected: false),
        RaisedHandCase(what: "an EXPIRED snooze is over, so the wake is the shelf's business and not a raised hand",
                       record: snoozed(failedAt: now.addingTimeInterval(-1), snoozedUntil: halfAnHourAgo),
                       expected: false),
        RaisedHandCase(what: "a snooze whose moment has exactly arrived is over here too — the same boundary resolve uses",
                       record: snoozed(failedAt: now.addingTimeInterval(-1), snoozedUntil: now),
                       expected: false),

        // A RECORD FROM BEFORE THIS TICKET: a live snooze with no `snoozedAt`.
        // No reference point, so the date signals are suppressed — waking on any
        // recorded failure would wake permanently and the snooze would not exist
        // for that record.
        RaisedHandCase(what: "a pre-P4.6 snooze with no recorded moment does not wake on a failure it cannot date",
                       record: snoozed(failedAt: now.addingTimeInterval(-1), snoozedAt: nil),
                       expected: false),
        RaisedHandCase(what: "…but a pending approval still wakes it, because that signal needs no date",
                       record: snoozed(pending: .approval, snoozedAt: nil), expected: true),
    ]

    for testCase in cases {
        expect(testCase.raised == testCase.expected,
               "\(testCase.what) — expected \(testCase.expected ? "woken" : "still snoozed"), got \(testCase.raised ? "woken" : "still snoozed")")
    }
    // Not vacuous: the table really says both things.
    expect(cases.contains { $0.expected } && cases.contains { !$0.expected },
           "the raised-hand table expects both a wake and a stay — got \(cases.map(\.expected))")
    expect(cases.count >= 15, "the raised-hand table covers every signal — got \(cases.count) cases")
}

// B · The boundary, swept. The packet's witness is a single second on either side
// of `snoozedAt`; this pins the whole line, for BOTH date signals, so a `>=`
// spelling is red at exactly one offset rather than depending on which two
// instants someone happened to pick.
private func runRaisedHandBoundaryCheck() {
    var woke = 0
    var stayed = 0
    for offset in -5...5 {
        let moment = snoozeSet.addingTimeInterval(TimeInterval(offset))
        for (signal, record) in [
            ("failure", SnoozedAgentFacts(snoozedUntil: snoozeEnds, snoozedAt: snoozeSet, failedAt: moment)),
            ("completed run", SnoozedAgentFacts(snoozedUntil: snoozeEnds, snoozedAt: snoozeSet, runCompletedAt: moment)),
        ] {
            let raised = InboxLifecycle.raisedHandWhileSnoozed(record: record, now: now)
            // STRICTLY newer. Offset 0 — the same instant the snooze was set —
            // counts as something the human had in front of them, because the
            // alternative is a row that wakes itself the moment it is parked.
            expect(raised == (offset > 0),
                   "a \(signal) at snoozedAt \(offset >= 0 ? "+" : "")\(offset)s \(offset > 0 ? "wakes" : "does not wake") a snoozed row — got \(raised)")
            if raised { woke += 1 } else { stayed += 1 }
        }
    }
    expect(woke == 10 && stayed == 12,
           "the boundary sweep crosses the line once per signal — woke \(woke), stayed \(stayed)")
}

// C · What a raised hand DOES. Three consequences, each asserted rather than
// described:
//   1. `snoozeHonoured` withholds the shelf date, so `resolve` — untouched by this
//      ticket — puts the row back in the list;
//   2. the STORED snooze is not cleared, so the row can be re-snoozed without
//      having lost that it was deferred (the packet's watch-out);
//   3. the row carries `.woke`, which is the one attention value with a word.
private func runRaisedHandSurfacingCheck() {
    let newFailure = SnoozedAgentFacts(snoozedUntil: snoozeEnds, snoozedAt: snoozeSet,
                                       failedAt: snoozeSet.addingTimeInterval(1))
    let oldFailure = SnoozedAgentFacts(snoozedUntil: snoozeEnds, snoozedAt: snoozeSet,
                                       failedAt: snoozeSet.addingTimeInterval(-1))

    // 1 · The row is back. Withholding the date makes `resolve` fall through the
    // shelf to the rung below exactly as an expired snooze does — no new rung, and
    // nothing about the order changes.
    let woken = InboxLifecycle.resolve(
        override: .neutral,
        snoozedUntil: InboxLifecycle.snoozeHonoured(record: newFailure, now: now),
        lastActivityAt: anHourAgo, now: now)
    expect(woken == .active,
           "a new failure pulls the row off the shelf — got \(woken)")
    expect(RowVariant.forLifecycle(woken) == .card,
           "…as a full card, not the one-line parked row it was — got \(RowVariant.forLifecycle(woken).rawValue)")

    let stillShelved = InboxLifecycle.resolve(
        override: .neutral,
        snoozedUntil: InboxLifecycle.snoozeHonoured(record: oldFailure, now: now),
        lastActivityAt: anHourAgo, now: now)
    expect(stillShelved == .snoozed(until: snoozeEnds),
           "a failure the human had already seen leaves the row on the shelf until its wake-up — got \(stillShelved)")

    // …and `snoozeHonoured` is exactly the stored date whenever no hand is up, so
    // it cannot be a shelf-suppressor that fires on something else.
    expect(InboxLifecycle.snoozeHonoured(record: oldFailure, now: now) == snoozeEnds,
           "an unraised hand honours the stored wake-up unchanged")
    expect(InboxLifecycle.snoozeHonoured(record: newFailure, now: now) == nil,
           "a raised hand withholds the shelf date")

    // 2 · The snooze is NOT cleared. `snoozeHonoured` answers what to honour now;
    // the stored fact it read is still there to be re-snoozed from.
    expect(newFailure.snoozedUntil == snoozeEnds && newFailure.snoozedAt == snoozeSet,
           "waking reads the stored snooze, it does not clear it — got \(String(describing: newFailure.snoozedUntil))")

    // 3 · The attention axis. `.woke` outranks `unread` and is the one value that
    // gets a word, because it is what put the row back in front of you.
    let raised = InboxLifecycle.raisedHandWhileSnoozed(record: newFailure, now: now)
    expect(InboxAttention.resolve(unread: false, raisedHand: raised) == .woke,
           "a woken row carries .woke")
    expect(InboxAttention.resolve(unread: true, raisedHand: raised) == .woke,
           "…and .woke outranks unread when both hold")
    expect(InboxAttention.resolve(
        unread: true,
        raisedHand: InboxLifecycle.raisedHandWhileSnoozed(record: oldFailure, now: now)) == .unread,
           "a row that stayed snoozed is not woke")
}

func runSnoozeRaisedHandChecks() {
    runRaisedHandTableCheck()
    runRaisedHandBoundaryCheck()
    runRaisedHandSurfacingCheck()
    print("Snooze raised-hand checks: blockers and new failures wake a snoozed agent, a failure the human had already seen does not, and waking withholds the shelf date without clearing the snooze")
}

func runEffectiveLifecycleChecks() {
    runLifecycleBlockerVocabularyCheck()
    runEffectiveLifecycleTableCheck()
    runEffectiveLifecyclePropertyCheck()
    runParentBlockedByDescendantCheck()
    print("Effective-lifecycle checks: 31 named precedence cases, 1,728 swept combinations and the parent/descendant rollup passed — a blocker outranks \"I said done\" in every one, whether it is the agent's own or a child's")
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
