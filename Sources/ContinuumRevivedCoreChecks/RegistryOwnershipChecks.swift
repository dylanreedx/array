import ContinuumRevivedCore
import Foundation

/// Project ownership is recorded once (`.plans/67` §4, `.plans/70` S5).
///
/// `ProjectEntry.workspaceId` is the record; `WorkspaceEntry.projectIds` is its
/// derived index, rebuilt on every decode. Two registry shapes Dylan's own
/// machine really had are decoded here, through the same `RegistryStore` path
/// launch uses:
///
///  - 2026-10-05 (`reports/G-prod-state.md`): consistent, with five projects
///    owned by nothing — migration must change nothing;
///  - 2026-09-27 (`.plans/67` §1): the two fields disagree for four of seven
///    projects, which made `exclusiveWorkspaceOwner` throw and aborted every
///    switch into or delete of a workspace touching them.
///
/// Then the two delete defects that rode on the dual record: deleting W un-owned
/// a project another workspace declares, and the replacement was the first
/// workspace in registry order rather than the most recent.
func runRegistryOwnershipChecks() {
    var failures: [String] = []
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }

    let now = Date(timeIntervalSince1970: 1_900_000_000)
    func uuid(_ suffix: String) -> UUID { UUID(uuidString: "00000000-0000-4000-8000-\(suffix)")! }
    func project(_ id: UUID, _ name: String, owner: UUID?) -> ProjectEntry {
        ProjectEntry(id: id, name: name, rootPath: "/tmp/registry-ownership/\(name)", workspaceId: owner,
                     lastOpenedAt: now, pinned: false)
    }
    func workspace(_ id: UUID, _ name: String, _ projectIds: [UUID], lastActiveAt: Date? = nil) -> WorkspaceEntry {
        WorkspaceEntry(id: id, name: name, projectIds: projectIds, createdAt: now, updatedAt: now, lastActiveAt: lastActiveAt)
    }
    func registry(_ workspaces: [WorkspaceEntry], _ projects: [ProjectEntry], lastActive: UUID?) -> Registry {
        var registry = Registry.empty()
        registry.workspaces = workspaces
        registry.projects = projects
        registry.lastActiveWorkspaceId = lastActive
        return registry
    }
    /// Through the real store, as launch reads it.
    func roundTrip(_ registry: Registry, _ label: String) -> Registry? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-ownership-\(label)-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Raw bytes, so the stored shape is exactly the legacy one.
            let store = RegistryStore(applicationSupportDirectory: dir)
            try JSONCodec.makeEncoder().encode(registry).write(to: store.registryFile)
            return try store.loadOrEmpty()
        } catch {
            failures.append("\(label): the registry did not decode: \(error)")
            return nil
        }
    }
    func owners(_ registry: Registry) -> [UUID: UUID?] {
        var result: [UUID: UUID?] = [:]
        for project in registry.projects {
            do { result[project.id] = try registry.exclusiveWorkspaceOwner(of: project.id) } catch {
                failures.append("exclusiveWorkspaceOwner threw for \(project.name): \(error)")
            }
        }
        return result
    }
    func listed(_ registry: Registry, _ workspaceId: UUID) -> [UUID] {
        registry.workspaces.first { $0.id == workspaceId }?.projectIds ?? []
    }

    // Field identities (ids from the prod copy; paths are not).
    let work = UUID(uuidString: "7F1D1696-F2B9-4CC2-8838-217BF376F58A")!
    let personalWs = uuid("0000000E9270")
    let personal = UUID(uuidString: "AAEE0E7E-0000-4000-8000-000000000001")!
    let harmony = UUID(uuidString: "375C6B1C-A16B-4C59-B561-C034E408FFEA")!
    let selectus = UUID(uuidString: "4335C8CD-0000-4000-8000-000000000003")!
    let documents = UUID(uuidString: "D5F19B27-0000-4000-8000-000000000004")!
    let array = UUID(uuidString: "FBDAB89B-0000-4000-8000-000000000005")!
    let workProject = UUID(uuidString: "47D6CB3D-0000-4000-8000-000000000006")!
    let andable = UUID(uuidString: "870CE466-0000-4000-8000-000000000007")!

    // 1. 2026-10-05: consistent. Migration is the identity.
    do {
        let field = registry(
            [workspace(work, "work", [harmony, selectus])],
            [project(personal, "personal", owner: nil), project(harmony, "harmony", owner: work),
             project(selectus, "selectus", owner: work), project(documents, "Documents", owner: nil),
             project(array, "Array", owner: nil), project(workProject, "work", owner: nil),
             project(andable, "andable", owner: nil)],
            lastActive: work)
        if let decoded = roundTrip(field, "2026-10-05") {
            check(decoded == field, "2026-10-05: a consistent registry changed on decode")
            let found = owners(decoded)
            check(found[harmony] == .some(work) && found[selectus] == .some(work),
                  "2026-10-05: harmony/selectus lost their owner: \(found)")
            for unowned in [personal, documents, array, workProject, andable] {
                check(found[unowned] == .some(nil), "2026-10-05: an unowned project gained an owner: \(unowned)")
            }
        }
    }

    // 2. 2026-09-27: four of seven disagree. `personal`'s workspace lists
    //    harmony and selectus, which declare `work`; `work` lists Array, which
    //    declares personal; andable is listed by both and declares nothing;
    //    the work project is listed and undeclared.
    do {
        let field = registry(
            [workspace(personalWs, "personal", [personal, harmony, selectus, andable]),
             workspace(work, "work", [array, andable, workProject])],
            [project(personal, "personal", owner: personalWs), project(harmony, "harmony", owner: work),
             project(selectus, "selectus", owner: work), project(documents, "Documents", owner: nil),
             project(array, "Array", owner: personalWs), project(workProject, "work", owner: nil),
             project(andable, "andable", owner: nil)],
            lastActive: work)
        if let decoded = roundTrip(field, "2026-09-27") {
            let found = owners(decoded)
            // Every declaration survives; every undeclared membership is adopted.
            check(found[personal] == .some(personalWs), "2026-09-27: personal lost its declared owner: \(String(describing: found[personal]))")
            check(found[harmony] == .some(work), "2026-09-27: harmony lost its declared owner")
            check(found[selectus] == .some(work), "2026-09-27: selectus lost its declared owner")
            check(found[array] == .some(personalWs), "2026-09-27: Array lost its declared owner")
            check(found[workProject] == .some(work), "2026-09-27: an undeclared membership was not adopted")
            check(found[andable] == .some(work),
                  "2026-09-27: andable (listed twice, undeclared) should go to the last-active workspace, got \(String(describing: found[andable]))")
            check(found[documents] == .some(nil), "2026-09-27: Documents gained an owner")
            // One record: the index is derived from it, in its old order.
            check(listed(decoded, personalWs) == [personal, array],
                  "2026-09-27: personal's derived index is \(listed(decoded, personalWs))")
            check(listed(decoded, work) == [andable, workProject, harmony, selectus],
                  "2026-09-27: work's derived index is \(listed(decoded, work))")
            do { try decoded.validateExclusiveProjectOwnership() } catch {
                check(false, "2026-09-27: the migrated registry still fails the strict audit: \(error)")
            }
            // Idempotent, through the store again.
            if let again = roundTrip(decoded, "2026-09-27-again") {
                check(again == decoded, "2026-09-27: the migration is not idempotent")
            }
        }
    }

    // 4. The read itself never throws on a disagreement, even before migration.
    do {
        let unmigrated = registry(
            [workspace(personalWs, "personal", [harmony]), workspace(work, "work", [andable])],
            [project(harmony, "harmony", owner: work), project(andable, "andable", owner: nil)],
            lastActive: nil)
        let found = owners(unmigrated)
        check(found[harmony] == .some(work), "unmigrated: the declaration did not win over a stale membership")
        check(found[andable] == .some(work), "unmigrated: a single membership was not read as the owner")
    }

    // 5. Delete W where P declares V but carries a stale membership in W: P
    //    stays V's. (Before: W's membership list was cleared wholesale.)
    do {
        var field = registry(
            // `work` does not list harmony: the only membership is the stale one.
            [workspace(personalWs, "personal", [personal, harmony]), workspace(work, "work", [])],
            [project(personal, "personal", owner: personalWs), project(harmony, "harmony", owner: work)],
            lastActive: work)
        check(field.deleteWorkspace(id: personalWs, now: now), "delete: refused a non-last workspace")
        check((try? field.exclusiveWorkspaceOwner(of: harmony)) == .some(work),
              "delete: deleting personal un-owned harmony, which declares work")
        check((try? field.exclusiveWorkspaceOwner(of: personal)) == .some(nil),
              "delete: personal kept an owner that no longer exists")
    }

    // 6. Deleting the current workspace falls back to the most recent one.
    do {
        let older = uuid("0000000000B1")
        let newer = uuid("0000000000C1")
        var field = registry(
            [workspace(work, "work", []),
             workspace(older, "older", [], lastActiveAt: now.addingTimeInterval(-3600)),
             workspace(newer, "newer", [], lastActiveAt: now.addingTimeInterval(-60))],
            [], lastActive: work)
        check(field.deleteWorkspace(id: work, now: now), "recency: refused a non-last workspace")
        check(field.lastActiveWorkspaceId == newer,
              "recency: deleting the current workspace selected \(String(describing: field.lastActiveWorkspaceId)), not the most recent one")
        check(field.workspacesByRecency().map(\.id) == [newer, older], "recency: order is \(field.workspacesByRecency().map(\.name))")
        field.markWorkspaceMounted(older, now: now)
        check(field.workspacesByRecency().first?.id == older && field.lastActiveWorkspaceId == older,
              "recency: mounting did not move a workspace to the head")
    }

    // 7. Creating a workspace need not select it for launch.
    do {
        var field = registry([workspace(work, "work", [])], [], lastActive: work)
        let created = field.createWorkspace(name: "Fresh", now: now, selectForLaunch: false)
        check(field.lastActiveWorkspaceId == work && field.workspaces.contains { $0.id == created.id },
              "create: an unmounted new workspace became the launch target")
    }

    if failures.isEmpty {
        print("RegistryOwnershipChecks passed")
    } else {
        for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
        Foundation.exit(1)
    }
}
