import ContinuumRevivedAgentUI
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P3.8-scope-dropdown.md
//
// THE FILTER, AS A PURE FUNCTION. What is asserted here and what is deliberately
// left to `--agent-inbox-check` (which owns the rendered popup and the selection):
//
//   1. SCOPING PICKS OUT A SUBSET, and the right one — project, workspace, and
//      `.all` as identity.
//   2. IT DOES NOT REORDER. Filtering is not ranking (P3.4 owns the order), so the
//      survivors come back in their arrival positions, and filter∘sort == sort∘filter.
//   3. THE OPEN AGENT SURVIVES ANY SCOPE — the packet's "watch out", stated as its
//      own property because it is the one row a filter is forbidden to drop.
//   4. THE MENU: `All agents` first, projects then workspaces, each sorted
//      case-insensitively, deduplicated, the CATALOG (what is open) unioned with what
//      the rows mention so an agentless open project is still pickable, and the
//      SELECTED scope present even when neither mentions it any more.
//   5. THE STORAGE ROUND TRIP is total and tagged — a project named "all", a
//      project and a workspace sharing a name, and a name containing a colon are
//      three different scopes that all survive it; garbage decodes to nothing so
//      the config can fail OPEN.
func runInboxScopeChecks() {
    runInboxScopeFilterCheck()
    runInboxScopeOrderCheck()
    runInboxScopeOpenAgentCheck()
    runInboxScopeEntriesCheck()
    runInboxScopeStorageCheck()
    print("InboxScope checks: project/workspace/all filtering, order preserved (filter∘sort == sort∘filter), the open agent surviving every scope, menu entries (all-first, projects before workspaces, case-insensitive, deduped, open-but-agentless projects offered from the catalog, stale selection kept across a rename) and a total tagged storage round trip passed")
}

private let scopeEpoch = Date(timeIntervalSince1970: 1_900_000_000)

/// One row per (project, workspace) pair the checks below need. `createdAt` steps
/// backwards with the index so the fixture is NOT already in `InboxSort`'s order —
/// otherwise "filtering does not reorder" would be satisfied by a no-op.
private func scopeRow(
    _ index: Int,
    project: String?,
    workspace: String?
) -> AgentInboxRow {
    AgentInboxRow(
        id: UUID(uuidString: String(format: "3B800000-0000-4000-8000-%012X", index))!,
        title: "agent \(index)",
        projectName: project,
        workspaceName: workspace,
        state: .ready,
        createdAt: scopeEpoch.addingTimeInterval(Double(index) * 60)
    )
}

/// continuum/Work, continuum/Work, bannockburn/Work, zed/Side, and a headless agent
/// in a project but no workspace (P2A.6 — it has no tile, so no workspace).
private let scopeFixture: [AgentInboxRow] = [
    scopeRow(1, project: "continuum", workspace: "Work"),
    scopeRow(2, project: "continuum", workspace: "Work"),
    scopeRow(3, project: "bannockburn", workspace: "Work"),
    scopeRow(4, project: "zed", workspace: "Side"),
    scopeRow(5, project: "continuum", workspace: nil),
]

private func runInboxScopeFilterCheck() {
    let all = InboxScope.filter(rows: scopeFixture, scope: .all)
    expect(all.map(\.id) == scopeFixture.map(\.id),
           "`.all` is the identity — got \(all.count) of \(scopeFixture.count) rows")

    let project = InboxScope.filter(rows: scopeFixture, scope: .project("continuum"))
    expect(project.map(\.title) == ["agent 1", "agent 2", "agent 5"],
           "a project scope keeps exactly that project's agents, including the one with no workspace — got \(project.map(\.title))")

    let workspace = InboxScope.filter(rows: scopeFixture, scope: .workspace("Work"))
    expect(workspace.map(\.title) == ["agent 1", "agent 2", "agent 3"],
           "a workspace scope crosses projects — got \(workspace.map(\.title))")
    // The honest edge, asserted rather than left to be discovered: an agent with no
    // workspace is reachable in `.all` and in its project, and nowhere else.
    expect(!workspace.contains { $0.title == "agent 5" },
           "an agent with no workspace must not be smuggled into a workspace scope")

    let unknown = InboxScope.filter(rows: scopeFixture, scope: .project("does-not-exist"))
    expect(unknown.isEmpty,
           "a scope nothing matches shows nothing rather than everything — got \(unknown.count) rows")
    // A project and a workspace that share a name are different scopes.
    expect(InboxScope.filter(rows: scopeFixture, scope: .workspace("continuum")).isEmpty,
           "a project name is not a workspace name")
}

private func runInboxScopeOrderCheck() {
    // Vacuity first: if the fixture were already sorted, the two claims below would
    // be about a list nothing moved.
    expect(InboxSort.sortForInbox(rows: scopeFixture).map(\.id) != scopeFixture.map(\.id),
           "the fixture must not already be in InboxSort's order, or the order checks are vacuous")

    let filtered = InboxScope.filter(rows: scopeFixture, scope: .workspace("Work"))
    expect(filtered.map(\.id) == scopeFixture.filter { $0.workspaceName == "Work" }.map(\.id),
           "the survivors come back in their arrival order — filtering is not ranking (P3.4 owns the order)")

    // …and the two operations commute, which is what lets the view filter first and
    // sort second without the scope becoming a second sort key.
    let filterThenSort = InboxSort.sortForInbox(
        rows: InboxScope.filter(rows: scopeFixture, scope: .workspace("Work"))).map(\.id)
    let sortThenFilter = InboxScope.filter(
        rows: InboxSort.sortForInbox(rows: scopeFixture), scope: .workspace("Work")).map(\.id)
    expect(filterThenSort == sortThenFilter,
           "filter∘sort must equal sort∘filter — got \(filterThenSort) vs \(sortThenFilter)")
}

private func runInboxScopeOpenAgentCheck() {
    // THE PACKET'S "WATCH OUT": the agent open in the focused tile is force-included,
    // or navigating to an agent hides its own row.
    let open = scopeFixture[3]
    expect(open.projectName == "zed",
           "this witness needs an open agent OUTSIDE the scope, or it proves nothing")
    let scoped = InboxScope.filter(
        rows: scopeFixture, scope: .project("continuum"), openAgentId: open.id)
    expect(scoped.contains { $0.id == open.id },
           "the open agent survives a scope that excludes it — got \(scoped.map(\.title))")
    expect(scoped.map(\.title) == ["agent 1", "agent 2", "agent 4", "agent 5"],
           "…in its own position, and without dragging its project's other rows in — got \(scoped.map(\.title))")
    // Without it, the same call drops that row — the regression, executable.
    expect(!InboxScope.filter(rows: scopeFixture, scope: .project("continuum"))
            .contains { $0.id == open.id },
           "the force-include must be what keeps the row, not the scope")
    // And it is not a second way to show everything.
    expect(InboxScope.filter(rows: scopeFixture, scope: .project("continuum"), openAgentId: open.id).count
            == InboxScope.filter(rows: scopeFixture, scope: .project("continuum")).count + 1,
           "the open agent adds exactly one row")
}

private func runInboxScopeEntriesCheck() {
    let entries = InboxScope.entries(for: scopeFixture)
    expect(entries == [
        .all,
        .project("bannockburn"), .project("continuum"), .project("zed"),
        .workspace("Side"), .workspace("Work"),
    ], "the menu is All agents, then projects, then workspaces, each sorted — got \(entries.map(\.title))")
    expect(entries.first == .all, "`All agents` is always first — it is the default and the way back")
    expect(Set(entries).count == entries.count,
           "no scope appears twice, however many agents share a project — got \(entries.map(\.title))")

    // Case-insensitive, or `Zed` sorts before `apps` and the menu is a list you have
    // to search rather than read.
    let mixed = InboxScope.entries(for: [
        scopeRow(6, project: "Zed", workspace: nil),
        scopeRow(7, project: "apps", workspace: nil),
    ])
    expect(mixed == [.all, .project("apps"), .project("Zed")],
           "names sort case-insensitively — got \(mixed.map(\.title))")

    // A project and a workspace that share a name are two entries, not one. (The
    // view must therefore not build its menu with `addItem(withTitle:)`, which
    // removes an existing item with the same title.)
    let shared = InboxScope.entries(for: [scopeRow(8, project: "Continuum", workspace: "Continuum")])
    expect(shared == [.all, .project("Continuum"), .workspace("Continuum")],
           "a project and a workspace with one name are two scopes — got \(shared.count) entries")

    // THE SELECTED SCOPE IS ALWAYS IN THE MENU, even once no row mentions it: a
    // popup whose selection is missing renders as its first entry, so the list would
    // show one scope while the control claimed another.
    let stale = InboxScope.entries(for: scopeFixture, including: .project("archived"))
    expect(stale.contains(.project("archived")),
           "a selected scope no row matches any more stays in the menu — got \(stale.map(\.title))")
    expect(stale.count == InboxScope.entries(for: scopeFixture).count + 1,
           "…and is appended once, not duplicated — got \(stale.map(\.title))")
    expect(InboxScope.entries(for: scopeFixture, including: .project("continuum"))
            == InboxScope.entries(for: scopeFixture),
           "a selected scope the rows DO mention is not appended a second time")
    expect(InboxScope.entries(for: []) == [.all],
           "an empty list still offers `All agents`, so the control is never blank")

    // THE CATALOG — what is OPEN, which is not the same as what has an agent in it.
    // From cross-review: a menu derived from the rows alone cannot offer the project
    // you are about to start your first agent in.
    let catalog: [InboxScope] = [.project("quiet-project"), .workspace("Quiet")]
    let withCatalog = InboxScope.entries(for: scopeFixture, catalog: catalog)
    expect(withCatalog == [
        .all,
        .project("bannockburn"), .project("continuum"), .project("quiet-project"), .project("zed"),
        .workspace("Quiet"), .workspace("Side"), .workspace("Work"),
    ], "an open project with no agents is still a scope — got \(withCatalog.map(\.title))")
    expect(InboxScope.filter(rows: scopeFixture, scope: .project("quiet-project")).isEmpty,
           "…and picking it shows nothing, which is the honest answer and not a crash")
    // The union is a union, not a replacement: an agent whose project has LEFT the
    // registry (a checkout that went missing under a running agent) stays reachable.
    expect(InboxScope.entries(for: scopeFixture, catalog: [.project("quiet-project")])
            .contains(.project("continuum")),
           "the rows are still read — an agent whose project left the registry must stay reachable")
    expect(InboxScope.entries(for: scopeFixture, catalog: [.project("continuum")])
            == InboxScope.entries(for: scopeFixture),
           "a catalog entry the rows already mention is not a second entry")
    expect(InboxScope.entries(for: [], catalog: catalog) == [.all, .project("quiet-project"), .workspace("Quiet")],
           "with no agents at all the menu is still what is open — got \(InboxScope.entries(for: [], catalog: catalog).map(\.title))")
    // `.all` in a catalog is not a second `All agents`.
    expect(InboxScope.entries(for: [], catalog: [.all]) == [.all],
           "`.all` cannot be duplicated by a catalog that names it")

    // THE DOCUMENTED LIMIT, pinned so it cannot change unnoticed: a scope is a NAME,
    // so two open projects sharing a display name are ONE entry that matches both.
    // Declined deliberately rather than missed — ids are not on the row (P3.1 flattened
    // them out to share the type with iOS), and the failure mode here is a scope that
    // shows a SUPERSET, which hides no agent. Widening this to ids means widening the
    // row, and it would be a change to P3.1's model, not to this file.
    let twinNames = InboxScope.entries(
        for: [], catalog: [.project("Continuum"), .project("Continuum")])
    expect(twinNames == [.all, .project("Continuum")],
           "two open projects with one name are one entry — got \(twinNames.map(\.title))")

    // A RENAME, end to end: the old scope is still decodable, still in the menu as the
    // selection, and matches nothing. This is the behaviour `WorkspaceSidebarConfig`
    // documents, asserted so the doc cannot drift from the code again.
    let afterRename = InboxScope.entries(
        for: scopeFixture, catalog: [.project("continuum-renamed")],
        including: .project("continuum-old"))
    expect(afterRename.contains(.project("continuum-old")) && afterRename.contains(.project("continuum-renamed")),
           "after a rename the new name is offered and the stale selection is still visible — got \(afterRename.map(\.title))")
    expect(InboxScope.filter(rows: scopeFixture, scope: .project("continuum-old")).isEmpty,
           "…and the stale scope matches nothing, so the list is empty rather than wrong")
}

private func runInboxScopeStorageCheck() {
    let cases: [InboxScope] = [
        .all,
        .project("continuum"),
        .workspace("continuum"),
        // The three names that break an untagged or last-colon codec.
        .project("all"),
        .project("a:b"),
        .workspace("11:30 standup"),
    ]
    for scope in cases {
        expect(InboxScope(storageValue: scope.storageValue) == scope,
               "\(scope) must survive the storage round trip — wrote '\(scope.storageValue)', read \(String(describing: InboxScope(storageValue: scope.storageValue)))")
    }
    expect(Set(cases.map(\.storageValue)).count == cases.count,
           "distinct scopes must have distinct storage values — got \(cases.map(\.storageValue))")

    // FAIL OPEN: anything unreadable decodes to nothing, and
    // `WorkspaceSidebarConfig.resolveScope` turns that into `.all`. A filter that
    // failed closed on a value it did not understand would hide every row.
    for garbage in ["", "project", "project:", "workspace:", ":name", "zone:main", "ALL", "all:"] {
        expect(InboxScope(storageValue: garbage) == nil,
               "'\(garbage)' is not a scope this version wrote and must not decode to one — got \(String(describing: InboxScope(storageValue: garbage)))")
    }

    expect(InboxScope.all.title == InboxScope.allTitle && InboxScope.project("x").title == "x",
           "a project or workspace entry shows its own name, with no prefix to spend width on")
}
