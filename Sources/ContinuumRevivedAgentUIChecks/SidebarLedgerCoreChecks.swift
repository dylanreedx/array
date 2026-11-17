import ContinuumRevivedAgentUI
import Foundation

// Sidebar round (array/sidebar-next): the shared core both sidebar layouts read.
// Pure: the count partition, the failure classes, the incident list and Clear's
// eligibility, on the 18-helper release-lead fixture the round's mockups use.

enum SidebarLedgerFixture {
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    static func row(
        _ n: Int, _ title: String, parent: Int? = nil, state: InboxState = .ready,
        outcome: AgentTerminalOutcome? = nil, detail: String? = nil, harness: String = "claude",
        mirrored: Bool = false, cleared: Bool = false, endedHoursAgo: Double = 30
    ) -> AgentInboxRow {
        var row = AgentInboxRow(
            id: id(n), title: title, projectName: "Array", state: state,
            createdAt: now.addingTimeInterval(Double(-100_000 + n)),
            parentId: parent.map(id), harness: harness,
            terminalEvent: outcome.map {
                AgentTerminalEvent(sequence: UInt64(n), turnID: nil, outcome: $0,
                                   endedAt: now.addingTimeInterval(-endedHoursAgo * 3600))
            })
        row.failureDetail = detail
        row.resumesThroughLead = mirrored
        row.isCleared = cleared
        return row
    }

    static let usage = "You've hit your 5-hour limit · resets 1:20 AM"

    /// Lead 1 with 18 unique descendants over two sub-leads:
    /// 12 paused (11 Claude, 1 Codex; one Claude helper mirrored), 1 failed
    /// (Codex could not start), 3 stopped, 2 done.
    static var releaseFamily: [AgentInboxRow] {
        var rows = [row(1, "Array release lead", outcome: .succeeded)]
        // Sub-lead A (done) with 4 paused helpers, one of them a mirrored child.
        rows.append(row(2, "Monitor overnight runs", parent: 1, outcome: .succeeded))
        for n in 3...6 {
            rows.append(row(n, "Overnight helper \(n)", parent: 2, outcome: .failed, detail: usage,
                            mirrored: n == 6))
        }
        // Sub-lead B (paused) with 4 paused helpers and 2 stopped.
        rows.append(row(7, "Further sidebar improvements", parent: 1, outcome: .failed, detail: usage))
        for n in 8...11 {
            rows.append(row(n, "Sidebar helper \(n)", parent: 7, outcome: .failed, detail: usage))
        }
        rows.append(row(12, "Sidebar helper 12", parent: 7, outcome: .interrupted))
        rows.append(row(13, "Sidebar helper 13", parent: 7, outcome: .cancelled))
        // Direct helpers: 2 paused Claude, 1 paused Codex, 1 couldn't start, 1 stopped, 1 done.
        rows.append(row(14, "Recover review fixes", parent: 1, outcome: .failed, detail: usage))
        rows.append(row(15, "Build combined preview", parent: 1, outcome: .failed, detail: usage))
        rows.append(row(16, "Codex usage helper", parent: 1, outcome: .failed,
                        detail: "You've hit your usage limit. Try again at 3:00 AM.", harness: "codex"))
        rows.append(row(17, "Implement permission approval", parent: 1, outcome: .failed,
                        detail: "Codex could not start: could not launch codex: No such file or directory (2)",
                        harness: "codex"))
        rows.append(row(18, "Interrupted helper", parent: 1, outcome: .interrupted, endedHoursAgo: 0.2))
        rows.append(row(19, "Finished helper", parent: 1, outcome: .succeeded, endedHoursAgo: 0.1))
        // Usage is out LIVE for both CLIs here, and each has a second account.
        return InboxSort.sortForInbox(rows: SidebarUsageLive.stamp(rows, states: [
            "Claude": .init(exhausted: true, canSwitch: true), "Codex": .init(exhausted: true, canSwitch: true)]))
    }
}

func runSidebarLedgerCoreChecks() {
    typealias F = SidebarLedgerFixture

    // 1. Failure classes, from the words Array records today (census copy).
    let classes: [(String?, SidebarFailureCause?)] = [
        ("You've hit your 5-hour limit", .usageLimit),
        ("You've hit your weekly limit · resets Tue", .usageLimit),
        ("rate_limit", .usageLimit),
        ("serverOverloaded", .providerBusy),
        ("Failed to authenticate: OAuth session expired and could not be refreshed", .signInExpired),
        ("Codex could not start: could not launch [path] No such file or directory (2)", .couldNotStart),
        ("Array restarted while this helper was working, so its turn did not finish.", .interruptedByRestart),
        ("This child was still running when the previous session ended.", .interruptedByRestart),
        ("Claude Code reported an error without details.", nil),
        ("You've hit your usage limit. Try again at 3:00 AM.", .usageLimit),
        ("Invalid API key · Please run /login", .signInExpired),
        ("Not logged in, please run /login", .signInExpired),
        ("API Error: 401 {\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"OAuth token has expired.\"}}", .signInExpired),
        ("Claude Code could not start: could not launch claude: No such file or directory (2)", .couldNotStart),
        // Task errors that only mention a topic stay plain failures.
        ("Tests failed: no such file or directory: fixtures/run.json", nil),
        ("Build failed: executable target 'Array' has errors", nil),
        ("Fix the authentication middleware: 2 tests failed", nil),
        ("Add per-team quota display; snapshot mismatch", nil),
        ("The Codex session ended before this child finished.", nil),
        ("The Claude parent ended before this mirrored child reported a result.", nil),
        (nil, nil),
    ]
    for (text, expected) in classes {
        expect(SidebarRecovery.classify(text) == expected,
               "classify(\(text ?? "nil")) = \(String(describing: SidebarRecovery.classify(text))), expected \(String(describing: expected))")
    }
    expect(SidebarFailureCause.usageLimit.label(harness: "claude") == "Paused · usage",
           "a usage stop reads as a pause, never Failed")
    expect(SidebarFailureCause.providerBusy.label(harness: "codex") == "Codex was busy", "busy label names the CLI")
    let actions = SidebarFailureCause.allCases.map(\.actionTitle)
    expect(actions == ["Switch & resume…", "Retry", "Sign in…", "Repair setup…", "Resume", "Open"],
           "one action per class, got \(actions)")
    // An unexplained failure is a real task error; an interruption with no words is Stopped.
    let generic = F.row(90, "x", outcome: .failed, detail: "Claude Code reported an error without details.")
    expect(SidebarRecovery.cause(for: generic) == .taskError && SidebarRecovery.state(for: generic) == .failed,
           "unexplained failure is Failed with Open")
    let fileError = F.row(92, "z", outcome: .failed, detail: "Tests failed: no such file or directory: fixtures/run.json")
    expect(SidebarRecovery.cause(for: fileError) == .taskError && SidebarRecovery.state(for: fileError) == .failed
           && SidebarRecovery.cause(for: fileError)?.isBlocking == false,
           "a task error mentioning 'no such file' is a plain, clearable Failed")
    let stopped = F.row(91, "y", outcome: .interrupted)
    expect(SidebarRecovery.cause(for: stopped) == nil && SidebarRecovery.state(for: stopped) == .stopped,
           "a bare interruption is Stopped, not a failure")
    let restart = F.row(92, "z", outcome: .interrupted,
                        detail: "Array restarted while this helper was working, so its turn did not finish.")
    expect(SidebarRecovery.cause(for: restart) == .interruptedByRestart && SidebarRecovery.state(for: restart) == .stopped,
           "restart interruption is its own cause, counted as stopped")
    // A succeeded helper whose report has checks that did not pass did NOT fail:
    // it counts as done, and no count line or fold count says "failed" for it.
    let researchLead = F.row(950, "Research lead")
    let research = AgentInboxRow(
        id: F.id(951), title: "Weekend news roundup", projectName: "Array", state: .ready,
        createdAt: F.now.addingTimeInterval(-600), parentId: F.id(950),
        terminalEvent: AgentTerminalEvent(sequence: 1, turnID: nil, outcome: .succeeded,
                                          endedAt: F.now.addingTimeInterval(-60)),
        selfReport: InboxSelfReport(checksPassed: 0, checksFailed: 3))
    if case let .checks(failed, total)? = research.selfReportLine {
        expect(failed == 3 && total == 3, "setup: the report carries 3 of 3 checks that did not pass")
    } else { expect(false, "setup: a finished helper's report must surface its checks") }
    expect(SidebarRecovery.state(for: research) == .done, "report checks that did not pass do not make a succeeded helper failed")
    for shownIDs in [Set<UUID>(), Set([research.id])] {
        let researchTally = SidebarLeadTally.tally(leadId: researchLead.id, rows: [researchLead, research], shownIDs: shownIDs)
        expect(researchTally.count(.failed) == 0 && (researchTally.foldedCounts[.failed] ?? 0) == 0
               && !researchTally.countLine.contains("failed"),
               "report checks must never count as failed agents: \(researchTally.countLine)")
    }

    // 2. One reconciled count, through the real bounded fold.
    let rows = F.releaseFamily
    let bounded = InboxSort.boundedForInbox(rows: rows, now: F.now)
    let shownIDs = Set(bounded.rows.map(\.id))
    let tally = SidebarLeadTally.tally(leadId: F.id(1), rows: rows, shownIDs: shownIDs)
    expect(tally.total == 18, "lead counts 18 unique descendants, got \(tally.total)")
    expect(tally.count(.paused) == 12 && tally.count(.failed) == 1 && tally.count(.stopped) == 3
           && tally.count(.done) == 2 && tally.count(.working) == 0 && tally.count(.needsYou) == 0,
           "partition 12 paused + 1 failed + 3 stopped + 2 done, got \(tally.counts)")
    expect(tally.shown == 2 && tally.folded == 16, "2 recent helpers shown, 16 folded: \(tally.shown)/\(tally.folded)")
    expect(tally.reconciles, "states sum to total and shown + folded = total: \(tally)")
    expect(tally.countLine == "18 helpers · 12 paused · 1 failed · 3 interrupted", "count chip: \(tally.countLine)")
    expect(tally.foldLine == "\(tally.folded) folded", "the fold says only what it folds: \(tally.foldLine)")
    expect(!tally.foldLine.contains("failed"), "the fold never repeats failed: \(tally.foldLine)")
    expect(tally.shown + Set(bounded.remainders.flatMap(\.hiddenDescendantIDs)).count == 18,
           "shown + every remainder's hidden = 18 (tally shown \(tally.shown))")

    // A cleared helper folds, and the total does not move.
    let clearedRows = rows.map { $0.id == F.id(19) ? { var r = $0; r.isCleared = true; return r }($0) : $0 }
    let clearedBounded = InboxSort.boundedForInbox(rows: clearedRows, now: F.now)
    let clearedTally = SidebarLeadTally.tally(
        leadId: F.id(1), rows: clearedRows, shownIDs: Set(clearedBounded.rows.map(\.id)))
    expect(!Set(clearedBounded.rows.map(\.id)).contains(F.id(19)), "a cleared helper leaves the shown rows")
    expect(clearedTally.shown == 1 && clearedTally.folded == 17, "Clear moves one helper from shown to folded")
    expect(clearedTally.total == 18 && clearedTally.reconciles, "clearing never changes the total")

    // 3. Incidents: owners, not records.
    let incidents = SidebarIncidents.build(rows: rows)
    let claudeUsage = incidents.first { $0.kind == .cause(.usageLimit) && $0.harness == "claude" }
    expect(claudeUsage?.agentIDs.count == 11, "11 Claude agents paused, got \(claudeUsage?.agentIDs.count ?? -1)")
    // The mirrored helper 6 resumes through sub-lead 2, which is not itself paused.
    expect(claudeUsage?.ownerIDs.count == 11 && claudeUsage?.ownerIDs.contains(F.id(2)) == true
           && claudeUsage?.ownerIDs.contains(F.id(6)) == false,
           "resumable owners counted once, mirrored helper through its lead: \(claudeUsage?.ownerIDs.count ?? -1)")
    expect(claudeUsage?.detail == "11 agents paused in 1 family · 11 can resume", "usage detail: \(claudeUsage?.detail ?? "nil")")
    expect(claudeUsage?.actionTitle == "Switch & resume…", "usage action")
    let codexUsage = incidents.first { $0.kind == .cause(.usageLimit) && $0.harness == "codex" }
    expect(codexUsage?.agentIDs == [F.id(16)], "the Codex pause has its own reachable incident")
    let setup = incidents.first { $0.kind == .cause(.couldNotStart) }
    expect(setup?.title == "Codex couldn't start" && setup?.actionTitle == "Repair setup…" && setup?.isBlocking == true,
           "setup incident: \(String(describing: setup))")
    expect(incidents.prefix { $0.isBlocking }.count == incidents.filter(\.isBlocking).count,
           "blocking incidents come first")

    // 4. Clear: settled or acknowledged-failed rows only; blockers stay.
    let eligible = Set(SidebarClear.eligibleIDs(rows: rows, standing: []))
    for paused in [3, 4, 5, 8, 14, 16] {
        expect(!eligible.contains(F.id(paused)), "Clear refuses a usage-paused helper \(paused)")
    }
    expect(!eligible.contains(F.id(17)), "Clear refuses an unresolved setup failure")
    expect(!eligible.contains(F.id(1)), "a lead whose family holds blockers is not cleared itself")
    expect(eligible == Set([12, 13, 18, 19].map(F.id)),
           "Clear takes the 3 stopped and 1 done helpers, got \(eligible.count)")
    expect(SidebarClear.refusal(for: rows.first { $0.id == F.id(1) }!, standing: [F.id(1)]) == .standing,
           "a standing lead never clears")
    let asking = AgentInboxRow(id: F.id(95), title: "asks", state: .approval, createdAt: F.now)
    expect(SidebarClear.refusal(for: asking, standing: []) == .needsYou, "Clear refuses needs-you")
    // A whole finished family clears as ONE row: its helpers are not counted again.
    let finished = InboxSort.sortForInbox(rows: [
        F.row(200, "Done lead", outcome: .succeeded),
        F.row(201, "Done helper", parent: 200, outcome: .succeeded),
        F.row(202, "Stopped helper", parent: 200, outcome: .interrupted),
    ])
    expect(SidebarClear.eligibleIDs(rows: finished, standing: []) == [F.id(200)],
           "a finished family clears as its lead")

    // 4b. Clear marks: sidebar-only, released by new activity.
    let marks: [UUID: SidebarClearMark] = [
        F.id(200): SidebarClearMarks.mark(for: finished[0], now: F.now),
        F.id(19): SidebarClearMarks.mark(for: rows.first { $0.id == F.id(19) }!, now: F.now),
    ]
    let marked = SidebarClearMarks.apply(marks, to: finished + rows)
    let markedRoot = marked.rows.first { $0.id == F.id(200) }!
    let markedChild = marked.rows.first { $0.id == F.id(201) }!
    let markedHelper = marked.rows.first { $0.id == F.id(19) }!
    expect(markedRoot.lifecycle != .active && markedChild.lifecycle != .active && markedRoot.isCleared,
           "a cleared lead goes to History with its family")
    expect(markedHelper.lifecycle == .active && markedHelper.isCleared, "a cleared helper stays in its active family, folded")
    let woken = F.row(19, "Finished helper", parent: 1, outcome: .succeeded, endedHoursAgo: 0)
    var newer = woken
    newer = AgentInboxRow(id: woken.id, title: woken.title, state: .working, createdAt: woken.createdAt, parentId: woken.parentId)
    let released = SidebarClearMarks.apply(marks, to: [newer])
    expect(released.released == [F.id(19)] && !released.rows[0].isCleared, "new activity releases a clear mark")

    // New activity inside a cleared family must release its root's mark too.
    // Clear may have stored only the root, because it subsumed these helpers.
    for activeChild in [
        F.row(201, "Done helper", parent: 200, state: .working, outcome: nil),
        F.row(201, "Done helper", parent: 200, outcome: .failed, detail: F.usage, endedHoursAgo: 0),
    ] {
        let changedFamily = finished.map { $0.id == activeChild.id ? activeChild : $0 }
        let reappeared = SidebarClearMarks.apply(marks, to: changedFamily)
        expect(reappeared.released.contains(F.id(200)), "new helper activity releases the cleared family's root")
        expect(reappeared.rows.allSatisfy { $0.lifecycle == .active && !$0.isCleared },
               "new helper activity brings the cleared family back from History")
    }

    // A lazy transcript detail can reveal a blocker on the SAME terminal
    // event after Clear. It must reappear without waiting for another turn.
    let unknown = F.row(300, "Initially unknown", outcome: .failed, detail: "No details")
    let unknownMarks = [unknown.id: SidebarClearMarks.mark(for: unknown, now: F.now)]
    for detail in ["OAuth session expired", "Codex could not start: could not launch codex: No such file or directory (2)"] {
        var revealed = unknown
        revealed.failureDetail = detail
        let applied = SidebarClearMarks.apply(unknownMarks, to: [revealed])
        expect(applied.released.contains(unknown.id) && !applied.rows[0].isCleared,
               "a late blocking cause releases an existing Clear mark")
    }
    // Dogfood: a usage stop blocks only while usage is out live, so it never
    // releases a mark on its own — with or without live usage.
    for live in [false, true] {
        var revealed = unknown
        revealed.failureDetail = F.usage
        revealed.usageExhaustedNow = live
        let applied = SidebarClearMarks.apply(unknownMarks, to: [revealed])
        expect(!applied.released.contains(unknown.id) && applied.rows[0].isCleared,
               "a usage stop alone (live \(live)) does not bring a cleared row back")
    }
    // Dogfood: titles read clean on every surface (one resolver).
    for (raw, want) in [
        ("Safest merge **Add RED cases** to `--x-check`", "Safest merge Add RED cases to --x-check"),
        ("You are working in the Array repository at: Implement and verify a fix", "Implement and verify a fix"),
        ("## Plan the release", "Plan the release"),
        ("Investigate   the\nflaky test", "Investigate the flaky test"),
    ] {
        expect(AgentName.displayTitle(raw) == want, "displayTitle(\(raw)) = \(AgentName.displayTitle(raw)), wanted \(want)")
    }
    expect(AgentName.fromPrompt("You are working in the Array repository at: /Users/x/Array\n\n**Fix** the `login` test") == "Fix the login test",
           "fromPrompt skips the boilerplate line and markup — got \(AgentName.fromPrompt("You are working in the Array repository at: /Users/x/Array\n\n**Fix** the `login` test") ?? "nil")")
    // Dogfood: the live usage rule, pure. Old words alone are a plain failure.
    do {
        let stopped = F.row(400, "Old usage stop", outcome: .failed, detail: F.usage)
        expect(SidebarRecovery.cause(for: stopped) == .taskError && SidebarRecovery.state(for: stopped) == .failed,
               "an old usage stop with no live exhaustion is a plain failure — got \(String(describing: SidebarRecovery.cause(for: stopped)))")
        expect(SidebarClear.refusal(for: stopped, standing: []) != .pausedOnUsage,
               "Clear never refuses an old usage stop as paused")
        var live = stopped
        live.usageExhaustedNow = true
        expect(SidebarRecovery.cause(for: live) == .usageLimit && SidebarRecovery.state(for: live) == .paused,
               "a usage stop while usage is out live is a pause")
        let one = SidebarIncidents.build(rows: [live]).first { $0.kind == .cause(.usageLimit) }
        expect(one?.actionTitle == SidebarFailureCause.usageResumeTitle,
               "one account: the usage action is Resume — got \(one?.actionTitle ?? "nil")")
        live.usageCanSwitchAccount = true
        let two = SidebarIncidents.build(rows: [live]).first { $0.kind == .cause(.usageLimit) }
        expect(two?.actionTitle == "Switch & resume…", "a second signed-in account: Switch & resume…")
        let dismissed = [two!.id: SidebarIncidentDismissals.fingerprint(two!, rows: [live])]
        expect(SidebarIncidentDismissals.visible([two!], dismissed: dismissed, rows: [live]).isEmpty,
               "a dismissed incident is hidden")
        let newer = F.row(401, "New usage stop", outcome: .failed, detail: F.usage)
        var newerLive = newer
        newerLive.usageExhaustedNow = true
        let grown = SidebarIncidents.build(rows: [live, newerLive]).first { $0.kind == .cause(.usageLimit) }!
        expect(SidebarIncidentDismissals.visible([grown], dismissed: dismissed, rows: [live, newerLive]).count == 1,
               "a new agent in the incident brings a dismissed item back")
    }
    let queued = AgentInboxRow(id: unknown.id, title: unknown.title, state: .ready,
        createdAt: unknown.createdAt, settlementBlocked: true, terminalEvent: unknown.terminalEvent)
    expect(SidebarClearMarks.apply(unknownMarks, to: [queued]).released.contains(unknown.id),
           "new blocked work releases an existing Clear mark")

    // A subsuming root mark must release when old descendant facts become known.
    let oldChild = F.row(201, "Unknown child", parent: 200, outcome: .failed)
    let rootMark = [F.id(200): marks[F.id(200)]!]
    // (Dogfood: a usage stop is not a same-event blocker; it is live state.)
    for detail in ["OAuth session expired", "Codex could not start: could not launch codex: No such file or directory (2)"] {
        var child = oldChild
        child.failureDetail = detail
        let restored = SidebarClearMarks.apply(rootMark, to: [finished[0], child])
        expect(restored.released.contains(F.id(200)) && restored.rows.allSatisfy { $0.lifecycle == .active },
               "same-event descendant blocker releases a subsuming root Clear mark")
    }
    expect(markedRoot.lifecycle.endedAt == finished[0].terminalEvent?.endedAt,
           "Clear preserves the work's actual History date")
    expect(markedChild.lifecycle.endedAt == finished.first { $0.id == F.id(201) }?.terminalEvent?.endedAt,
           "Clear preserves each descendant's actual History date")

    let settledFamily = finished.map { row in
        row.followingParent(lifecycle: .settled(at: F.now.addingTimeInterval(-3600)),
            closingSince: row.closingSince, workspaceName: row.workspaceName, workspaceId: row.workspaceId)
    }
    let standing = SidebarStandingLeads.apply([F.id(200)], to: settledFamily)
    expect(standing.allSatisfy { $0.lifecycle == .active } && standing[0].isStanding,
           "Standing retains a settled lead and its family")
    let archived = settledFamily.map { row in
        row.followingParent(lifecycle: .archived(at: F.now), closingSince: row.closingSince,
            workspaceName: row.workspaceName, workspaceId: row.workspaceId)
    }
    expect(SidebarStandingLeads.apply([F.id(200)], to: archived).allSatisfy { $0.lifecycle == .archived(at: F.now) },
           "Standing honors explicit archive")
    let snoozed = settledFamily.map { row in
        row.followingParent(lifecycle: .snoozed(until: F.now.addingTimeInterval(3600)), closingSince: row.closingSince,
            workspaceName: row.workspaceName, workspaceId: row.workspaceId)
    }
    expect(SidebarStandingLeads.apply([F.id(200)], to: snoozed) == snoozed, "Standing honors explicit snooze")

    // 5. Layout setting.
    let suite = "array.sidebar-ledger-core-check.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    expect(SidebarLayout.resolve(in: defaults) == .quietInbox, "Quiet inbox is the default")
    defaults.set("ledger", forKey: SidebarLayout.defaultsKey)
    expect(SidebarLayout.resolve(in: defaults) == .ledger, "the Ledger stays a Settings choice")
    defaults.set("quietInbox", forKey: SidebarLayout.defaultsKey)
    expect(SidebarLayout.resolve(in: defaults) == .quietInbox, "the layout persists")
    SidebarStandingLeads.save([F.id(1)], to: defaults)
    expect(SidebarStandingLeads.load(from: defaults) == [F.id(1)], "standing leads persist per agent")
    defaults.removePersistentDomain(forName: suite)

    print("Sidebar ledger core passed: 18 = 12 paused + 1 failed + 3 stopped + 2 done, shown \(tally.shown) + folded \(tally.folded); "
          + "11 Claude owners for 11 paused (mirrored helper through its lead); Clear takes 4, refuses paused/setup/standing/needs-you")
}
