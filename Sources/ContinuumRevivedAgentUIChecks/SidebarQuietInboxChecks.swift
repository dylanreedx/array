import ContinuumRevivedAgentUI
import Foundation

// Sidebar round, Quiet inbox (variants/A): the box and the family chips over
// the same 18-helper release family the core's checks use.

func runSidebarQuietInboxChecks() {
    typealias F = SidebarLedgerFixture
    let release = F.releaseFamily

    // 1. One chip per family: the release lead's 12 usage pauses (11 Claude +
    // 1 Codex) are ONE chip, paused never failed, with ONE action.
    let chips = SidebarQuietInbox.familyChips(rows: release)
    expect(chips.count == 1, "Quiet: one chip for one family — got \(chips.map(\.text))")
    let chip = chips[0]
    expect(chip.familyId == F.id(1) && chip.cause == .usageLimit && chip.text == "12 paused · usage",
           "Quiet: the family chip is '12 paused · usage' — got '\(chip.text)'")
    expect(chip.incident.actionTitle == "Open", "Quiet: usage's one action opens the agent — got \(chip.incident.actionTitle)")
    expect(chip.incident.agentIDs.count == 12 && chip.incident.familyIDs == [F.id(1)],
           "Quiet: the chip acts on the family's 12 paused agents only")
    expect(chip.incident.ownerIDs.count == 12,
           "Quiet: owners, not records — the mirrored helper resumes through its lead — got \(chip.incident.ownerIDs.count)")

    // 2. The box is the blocking incidents and nothing else; with nothing
    // blocking there is no box at all.
    let incidents = SidebarIncidents.build(rows: release)
    let box = SidebarQuietInbox.needsYou(incidents)
    expect(!box.isEmpty && box.allSatisfy(\.isBlocking), "Quiet: the box holds blocking incidents")
    expect(!box.contains { $0.kind == .cause(.usageLimit) }, "Quiet: a usage pause is never in the Needs-you box")
    let calm = InboxSort.sortForInbox(rows: [
        F.row(300, "Done lead", outcome: .succeeded),
        F.row(301, "Done helper", parent: 300, outcome: .succeeded),
    ])
    expect(SidebarQuietInbox.needsYou(SidebarIncidents.build(rows: calm)).isEmpty
           && SidebarQuietInbox.familyChips(rows: calm).isEmpty,
           "Quiet: nothing blocking means no box and no chip")

    // 3. Two families, two causes: each its own chip; a cleared helper is not counted.
    let two = InboxSort.sortForInbox(rows: release + [
        F.row(400, "Assess app progress", outcome: .succeeded),
        F.row(401, "Busy helper", parent: 400, outcome: .failed, detail: "serverOverloaded", harness: "codex"),
        F.row(402, "Busy helper 2", parent: 400, outcome: .failed, detail: "serverOverloaded", harness: "codex"),
        F.row(403, "Cleared busy", parent: 400, outcome: .failed, detail: "serverOverloaded", harness: "codex",
              cleared: true),
    ])
    let twoChips = SidebarQuietInbox.familyChips(rows: two)
    expect(twoChips.map(\.text).sorted() == ["12 paused · usage", "2 failed · Codex was busy"],
           "Quiet: one chip per family, cleared helpers excluded — got \(twoChips.map(\.text))")
    expect(twoChips.first { $0.familyId == F.id(400) }?.incident.actionTitle == "Retry",
           "Quiet: busy's one action is Retry")

    // 4. One count function: a failed lead with one failed helper. The chip
    // counts the lead's members as the tally does (the Ledger's count line),
    // so Quiet cannot say "2 failed" where the Ledger says "1 failed".
    let failing = InboxSort.sortForInbox(rows: [
        F.row(500, "improve our slash command UI", outcome: .failed, detail: "Tests failed: 3 of 40"),
        F.row(501, "Failed helper", parent: 500, outcome: .failed, detail: "Tests failed: 3 of 40"),
        F.row(502, "Done helper", parent: 500, outcome: .succeeded),
    ])
    let failingTally = SidebarLeadTally.tally(leadId: F.id(500), rows: failing, shownIDs: [])
    let failingChip = SidebarQuietInbox.familyChips(rows: failing).first { $0.familyId == F.id(500) }
    expect(failingTally.count(.failed) == 1 && failingChip?.count == failingTally.count(.failed)
           && failingChip?.text.hasPrefix("\(failingTally.count(.failed)) failed") == true,
           "Quiet and Ledger count one lead the same way: tally \(failingTally.countLine), chip '\(failingChip?.text ?? "none")'")

    // A cause only the lead carries keeps its line (A: "Interrupted when Array
    // restarted … Resume…") but no number, since the tally counts helpers only.
    let leadOnly = InboxSort.sortForInbox(rows: [
        F.row(600, "Polish sidebar card hover", outcome: .failed, detail: "Tests failed: 3 of 40"),
        F.row(601, "Done helper", parent: 600, outcome: .succeeded),
    ])
    let leadOnlyChip = SidebarQuietInbox.familyChips(rows: leadOnly).first { $0.familyId == F.id(600) }
    expect(leadOnlyChip?.count == 0 && leadOnlyChip?.text.hasPrefix("Failed · ") == true
           && SidebarLeadTally.tally(leadId: F.id(600), rows: leadOnly, shownIDs: []).count(.failed) == 0,
           "a lead's own cause keeps its words and says no helper count — got '\(leadOnlyChip?.text ?? "none")'")

    print("Sidebar quiet inbox passed: one chip per family (12 paused · usage, Open, 12 owners), the box is blocking-only (no usage) "
          + "and absent when nothing blocks, cleared helpers excluded")
}
