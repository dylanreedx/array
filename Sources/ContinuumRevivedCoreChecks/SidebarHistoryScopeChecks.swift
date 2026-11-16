import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// The default sidebar is a history of the user's agents, with helpers under
/// their lead. A missing/deleted/unrestorable parent is not a new user agent.
func runSidebarHistoryScopeChecks() throws {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let lead = UUID(), helper = UUID(), sublead = UUID(), grandchild = UUID()
    let absentParent = UUID(), orphan = UUID(), orphanChild = UUID()
    let workspace = UUID(), otherWorkspace = UUID()
    func row(_ id: UUID, parent: UUID? = nil, state: InboxState = .ready,
             lifecycle: InboxLifecycle = .active, outcome: AgentTerminalOutcome? = .succeeded,
             unread: Bool = false, liveRunner: Bool = false,
             blocked: Bool = false, pinned: Bool = false, whereAt: UUID? = nil) -> AgentInboxRow {
        AgentInboxRow(
            id: id, title: "agent", workspaceName: "workspace", workspaceId: whereAt ?? workspace,
            state: state, lifecycle: lifecycle, createdAt: now,
            parentId: parent, settlementBlocked: blocked,
            terminalEvent: outcome.map {
                AgentTerminalEvent(sequence: 1, turnID: "turn", outcome: $0, endedAt: now)
            }, terminalIsUnread: unread, hasLiveRunner: liveRunner, isPinned: pinned)
    }
    let normal = AgentInboxRowBuilder.placingChildrenWithParents([
        row(lead), row(helper, parent: lead, lifecycle: .archived(at: now)),
        row(sublead, parent: lead, lifecycle: .archived(at: now)),
        row(grandchild, parent: sublead, lifecycle: .settled(at: now)),
        row(UUID(), whereAt: otherWorkspace),
    ])
    let orphanFamily = [row(orphan, parent: absentParent, lifecycle: .archived(at: now)),
                        row(orphanChild, parent: orphan, lifecycle: .archived(at: now))]
    let input = normal + orphanFamily
    func filtered(_ rows: [AgentInboxRow], open: UUID? = nil) -> [AgentInboxRow] {
        InboxSort.excludingQuietOrphanedHelpers(rows: rows, openAgentId: open)
    }
    let actual = filtered(input)
    expect(actual.map(\.id) == normal.map(\.id),
           "sidebar history must omit a finished helper family whose parent is absent; got \(actual.count) rows, expected \(normal.count)")
    expect(filtered(normal) == normal, "a standing lead keeps its helpers and sub-leads")
    expect(InboxSort.excludingQuietOrphanedHelpers(rows: input, searching: true) == input,
           "search can still find every finished orphan helper")
    expect(filtered(input, open: orphanChild).map(\.id) == input.map(\.id),
           "opening an orphan keeps its family as context")
    for state in [InboxState.working, .approval, .input] {
        let family = [orphanFamily[0], row(orphanChild, parent: orphan, state: state)]
        expect(filtered(family) == family, "a \(state) descendant keeps the orphan family visible")
    }
    for survivor in [row(orphan, parent: absentParent, outcome: nil),
                     row(orphan, parent: absentParent, liveRunner: true),
                     row(orphan, parent: absentParent, blocked: true),
                     row(orphan, parent: absentParent, pinned: true),
                     row(orphan, parent: absentParent, lifecycle: .snoozed(until: now.addingTimeInterval(60))),
                     row(orphan, parent: absentParent, state: .failed, outcome: .failed, unread: true)] {
        expect(filtered([survivor]) == [survivor], "unknown or actionable orphan work must remain visible")
    }
    expect(filtered([row(orphan, parent: absentParent, state: .failed, outcome: .failed)]).isEmpty,
           "an acknowledged orphan failure is finished history")
    expect(filtered([row(orphan, parent: absentParent)]).isEmpty,
           "a successful orphan must not return as a live recent after restart")
    let cycle = [row(orphan, parent: orphanChild), row(orphanChild, parent: orphan)]
    expect(filtered(cycle) == cycle, "corrupt cycles terminate without discarding agents")
    let sorted = InboxSort.sortForInbox(rows: actual)
    expect(sorted.first(where: { $0.id == sublead })?.depth == 1
           && sorted.first(where: { $0.id == grandchild })?.depth == 2,
           "a sub-lead and its helper stay under the standing lead")
    let scoped = InboxScope.filter(rows: actual, scope: .workspaceID(workspace, "workspace"))
    expect(scoped.count == 4, "the workspace filter still excludes other workspaces")

    // Exercise durable record → context → snapshot → row as well, with the
    // absent-parent input produced when restore skips a lead's missing cwd.
    let record = AgentRecord(
        id: AgentID(rawValue: orphan), displayName: "Finished helper", model: "fixture/model",
        thinking: "medium", cwd: "/tmp/sidebar-history-fixture", parentAgentID: AgentID(rawValue: absentParent),
        createdAt: now, lastActivityAt: now,
        latestTerminalEvent: AgentTerminalEvent(sequence: 1, turnID: "turn", outcome: .succeeded, endedAt: now),
        archivedAt: now)
    let restored = try JSONDecoder().decode(AgentRecord.self, from: JSONEncoder().encode(record))
    let context = AgentContextIndex.build(
        registry: .empty(), documents: [:], projectCanvases: [:], terminalDescriptors: [], agents: [restored])
    let snapshot = AgentInventory.snapshot(
        terminalDescriptors: [], liveStatuses: [:], agents: [restored], activityByAgent: [:],
        replicaId: lead, now: now)
    let built = AgentInboxRowBuilder.rows(
        from: snapshot, context: context, records: [orphan: restored], now: now)
    expect(built.count == 1 && built[0].parentId == absentParent && filtered(built).isEmpty,
           "a persisted orphan helper is omitted through the production row builder")
    print("SidebarHistoryScope: quiet orphan families omitted; standing leads retain helpers/sub-leads; open, running, blocked, unread-failed and unknown work preserved; cycles safe; workspace scope preserved")
}

/// Optional audit of an explicit COPY. Avoid AgentStore: recovery can write.
/// This reconstructs a fresh, idle restore, not the live app's runtime state.
func runSidebarHistoryRecordsAudit(copy: URL) throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let registry = try decoder.decode(Registry.self, from: Data(contentsOf: copy.appendingPathComponent("registry.json")))
    let files = try FileManager.default.contentsOfDirectory(
        at: copy.appendingPathComponent("agents"), includingPropertiesForKeys: nil)
    let records = try files.filter {
        $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil
    }
        .map { try decoder.decode(AgentRecord.self, from: Data(contentsOf: $0)) }
    let adopted = records.filter { record in
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: record.cwd, isDirectory: &directory) && directory.boolValue
    }
    let now = records.map(\.lastActivityAt).max() ?? .distantPast
    let context = AgentContextIndex.build(
        registry: registry, documents: [:], projectCanvases: [:], terminalDescriptors: [], agents: adopted)
    let snapshot = AgentInventory.snapshot(
        terminalDescriptors: [], liveStatuses: [:], agents: adopted, activityByAgent: [:],
        replicaId: UUID(), now: now)
    let rows = AgentInboxRowBuilder.rows(
        from: snapshot, context: context,
        records: Dictionary(uniqueKeysWithValues: adopted.map { ($0.id.rawValue, $0) }), now: now)
    let present = Set(rows.map(\.id))
    let candidates = rows.filter { row in row.parentId.map { !present.contains($0) } ?? false }
    let filtered = InboxSort.excludingQuietOrphanedHelpers(rows: rows)
    let retained = Set(filtered.map(\.id))
    print("Copied-record idle restore: \(records.count) stored, \(adopted.count) adopted, \(candidates.count) orphan helpers; \(rows.count - filtered.count) omitted")
    for row in candidates.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
        print("\(retained.contains(row.id) ? "KEPT" : "OMITTED") \(row.id.uuidString) \(row.title)")
    }
}
