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
    expect(chip.incident.actionTitle == "Switch & resume…", "Quiet: usage's one action — got \(chip.incident.actionTitle)")
    expect(chip.incident.agentIDs.count == 12 && chip.incident.familyIDs == [F.id(1)],
           "Quiet: the chip acts on the family's 12 paused agents only")
    expect(chip.incident.ownerIDs.count == 12,
           "Quiet: owners, not records — the mirrored helper resumes through its lead — got \(chip.incident.ownerIDs.count)")

    // 2. The box is the blocking incidents and nothing else; with nothing
    // blocking there is no box at all.
    let incidents = SidebarIncidents.build(rows: release)
    let box = SidebarQuietInbox.needsYou(incidents)
    expect(!box.isEmpty && box.allSatisfy(\.isBlocking), "Quiet: the box holds blocking incidents")
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

    print("Sidebar quiet inbox passed: one chip per family (12 paused · usage, 12 owners), the box is blocking-only "
          + "and absent when nothing blocks, cleared helpers excluded")
}
