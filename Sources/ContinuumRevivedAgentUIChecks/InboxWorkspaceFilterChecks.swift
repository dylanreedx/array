import ContinuumRevivedAgentUI
import Foundation

// Plan: .plans/86-workspace-filter/README.md
//
// THE CHECKLIST'S RULES, without a window:
//
//   1. A click from `This workspace` builds an INCLUDE set; a click from `All
//      agents` builds an EXCLUDE set, and only the exclude set shows a workspace
//      created afterwards.
//   2. `This workspace` follows a switch; a workspace there only by following
//      reads `.following`, and unchecking it drops the follow.
//   3. The last box cannot be unchecked; re-picking a pick changes nothing.
//   4. `Only` isolates; `Only` on the workspace on screen is `This workspace`.
//   5. Labels: "This workspace", "Array + Film", "3 workspaces", "All but Film".
//   6. Storage round-trips every set, and the two old scopes keep their values.
func runInboxWorkspaceFilterChecks() {
    let array = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!
    let film = UUID(uuidString: "A0000000-0000-4000-8000-000000000002")!
    let site = UUID(uuidString: "A0000000-0000-4000-8000-000000000003")!
    let later = UUID(uuidString: "A0000000-0000-4000-8000-000000000004")!
    let names = [array: "Array", film: "Film", site: "Website", later: "Later"]
    let epoch = Date(timeIntervalSince1970: 1_900_000_000)
    func row(_ n: Int, _ workspace: UUID?, state: InboxState = .ready) -> AgentInboxRow {
        AgentInboxRow(
            id: UUID(uuidString: String(format: "A1000000-0000-4000-8000-%012X", n))!,
            title: "agent \(n)", workspaceName: workspace.flatMap { names[$0] }, workspaceId: workspace,
            state: state, createdAt: epoch.addingTimeInterval(Double(n)))
    }
    let rows = [row(1, array), row(2, film, state: .approval), row(3, site), row(4, nil), row(5, later)]
    func shown(_ scope: InboxScope, current: UUID? = array) -> [String] {
        InboxScope.filter(rows: rows, scope: scope, currentWorkspaceId: current).map(\.title)
    }
    func pick(_ kind: InboxScopeMenuEntry.Kind, _ scope: InboxScope, only: Bool = false) -> InboxScope? {
        InboxScopeMenu.choose(kind, from: scope, current: array, only: only)
    }

    // 1. Include from This workspace, exclude from All.
    guard let arrayFilm = pick(.workspace(film), .currentWorkspace) else {
        return expect(false, "checking Film from This workspace must change the scope")
    }
    expect(shown(arrayFilm) == ["agent 1", "agent 2"], "Array + Film shows exactly their agents — got \(shown(arrayFilm))")
    expect(arrayFilm.workspaceFilter?.mode == .include, "a set built from This workspace is an include set")
    guard let allButFilm = pick(.workspace(film), .all) else {
        return expect(false, "unchecking Film from All must change the scope")
    }
    expect(shown(allButFilm) == ["agent 1", "agent 3", "agent 4", "agent 5"],
           "All but Film shows everything else, headless included — got \(shown(allButFilm))")
    expect(allButFilm.workspaceFilter?.shows(workspace: UUID(), current: array) == true,
           "an exclude set shows a workspace created after it")
    expect(arrayFilm.workspaceFilter?.shows(workspace: UUID(), current: array) == false,
           "an include set does not")
    expect(pick(.workspace(film), allButFilm) == .all, "re-checking the only hidden workspace is All again")

    // 2. Following.
    expect(shown(arrayFilm, current: site) == ["agent 2", "agent 3"],
           "This workspace follows a switch: on Website, Array + Film becomes Website + Film — got \(shown(arrayFilm, current: site))")
    let menu = InboxScopeMenu.entries(
        scope: arrayFilm, workspaces: [.init(id: film, name: "Film"), .init(id: array, name: "Array")],
        rows: rows, current: array)
    let byKind = Dictionary(uniqueKeysWithValues: menu.map { ($0.kind, $0) })
    expect(byKind[.workspace(array)]?.check == .following, "Array is in the set by following, and says so")
    expect(byKind[.workspace(film)]?.check == .on && byKind[.current]?.check == .on && byKind[.all]?.check == .off,
           "Film and This workspace are checked, All is not")
    expect(menu.first?.kind == .current && menu.dropFirst().first?.kind == .all,
           "pinned rows lead: This workspace, then All agents")
    expect(menu.compactMap { if case .workspace(let id) = $0.kind { return id } else { return nil } }.first == array,
           "the workspace on screen leads the workspace block")
    expect(byKind[.workspace(film)]?.detail == "1 agent · 1 needs you" && byKind[.workspace(film)]?.needsYou == true,
           "a workspace row counts its agents and who needs you — got \(byKind[.workspace(film)]?.detail ?? "nil")")
    expect(byKind[.unplaced]?.trailing == "1 headless", "Unplaced is offered when an agent has no workspace")
    let dropped = pick(.workspace(array), arrayFilm)
    expect(dropped.map { shown($0, current: site) } == ["agent 2"],
           "unchecking the followed workspace drops the follow, so a switch adds nothing")

    // 3. Refusals.
    expect(pick(.current, .currentWorkspace) == nil, "the last box cannot be unchecked")
    expect(pick(.all, .all) == nil && pick(.project("x"), .project("x")) == nil,
           "re-picking the pick already showing changes nothing")
    expect(pick(.workspace(film), .project("x")) == arrayFilm,
           "a checkbox clicked from a project scope starts from This workspace")

    // 4. Only.
    expect(pick(.workspace(film), arrayFilm, only: true).map { shown($0) } == ["agent 2"], "Only isolates Film")
    expect(pick(.workspace(array), allButFilm, only: true) == .currentWorkspace,
           "Only on the workspace on screen is This workspace")

    // 5. Labels.
    func title(_ scope: InboxScope?) -> String {
        scope.map { InboxScopeMenu.title(for: $0, names: names, current: array) } ?? "nil"
    }
    expect(title(.currentWorkspace) == "This workspace", "the default reads This workspace")
    expect(title(arrayFilm) == "Array + Film", "two workspaces read A + B, current first — got \(title(arrayFilm))")
    let three = arrayFilm.workspaceFilter.flatMap { $0.toggling(workspace: site, current: array) }.map(InboxScope.normalized)
    expect(title(three) == "3 workspaces", "three or more count — got \(title(three))")
    expect(title(allButFilm) == "All but Film", "an exclude set names what it hides — got \(title(allButFilm))")
    expect(title(.all) == "All agents", "All reads All agents")

    // 6. Storage.
    for scope in [arrayFilm, allButFilm, three, dropped, pick(.unplaced, .currentWorkspace, only: true)].compactMap({ $0 }) {
        let stored = scope.storageValue
        expect(InboxScope(storageValue: stored) == scope, "\(stored) must round-trip")
    }
    expect(InboxScope.currentWorkspace.storageValue == "current" && InboxScope.all.storageValue == "all",
           "the two old scopes keep their stored values")
    expect(InboxScope(storageValue: "workspaces:include:") == nil
           && InboxScope(storageValue: "workspaces:exclude:current") == nil
           && InboxScope(storageValue: "workspaces:sideways:") == nil,
           "an empty, contradictory or unknown set decodes to nothing, so the config fails open")
    print("InboxWorkspaceFilter checks: include/exclude inference, following, refusals, Only, labels and storage passed")
}
