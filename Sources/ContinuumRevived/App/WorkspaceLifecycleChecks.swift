import AppKit
import ContinuumRevivedCore
import Foundation

/// Delete, create and rename a workspace through the entry points a person
/// uses (`.plans/70` S5, reports B D2–D5, C1, C2), over the two-workspace
/// fixture mounted by `mountWorkspaceSceneAtBoot`:
///
///  - ⌘K "Rename X…" asks for the name (it renamed to "Renamed Workspace");
///  - deleting the current workspace lands in the most recently used one, not
///    the first in registry order, and keeps a recoverable copy of its layout;
///  - a replacement that cannot be mounted is skipped, never failing the delete;
///  - deleting a workspace kept warm releases its runtimes and locks;
///  - a created workspace becomes the launch workspace only once mounted, and a
///    create whose registry write fails leaves no orphan document.
@MainActor
enum WorkspaceLifecycleChecks {
    typealias Fixture = WorkspaceInvariantsFixture

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    final class Findings {
        var failures: [String] = []
        var facts: [String: Any] = [:]
        func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
            if !condition() { failures.append(message()) }
        }
    }

    static func run() throws -> URL {
        var manifest: [String: Any] = [:]
        var failures: [String] = []
        let scenarios: [(String, (Fixture, Findings) throws -> Void)] = [
            ("palette-rename-asks", paletteRenameAsks),
            ("delete-current-lands-on-most-recent", deleteCurrentLandsOnMostRecent),
            ("delete-current-skips-unmountable", deleteCurrentSkipsUnmountable),
            ("delete-releases-warm-runtimes", deleteReleasesWarmRuntimes),
            ("create-selects-only-once-mounted", createSelectsOnlyOnceMounted),
            ("create-failure-leaves-no-orphan", createFailureLeavesNoOrphan)
        ]
        for (label, body) in scenarios {
            fputs("workspace-lifecycle: \(label)\n", stderr)
            let findings = Findings()
            let fixture = try Fixture(label: "lifecycle-\(label)")
            do {
                try fixture.mount()
                let m = try fixture.requireMounted("mount")
                m.delegate.qaSetWorkspaceDeleteConfirmation { _ in true }
                try body(fixture, findings)
            } catch {
                findings.failures.append("aborted: \(error)")
            }
            var entry = findings.facts
            entry["failures"] = findings.failures
            entry["actions"] = fixture.actionLog
            manifest[label] = entry
            failures += findings.failures.map { "\(label): \($0)" }
            fixture.dispose()
        }
        let dir = URL(fileURLWithPath: "qa-runs/\(Int(Date().timeIntervalSince1970))/workspace-lifecycle", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let artifact = dir.appendingPathComponent("manifest.json", isDirectory: false)
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: artifact, options: .atomic)
        if !failures.isEmpty {
            throw Failure(message: "\(failures.count) expectation(s) failed (\(artifact.path)):\n  "
                          + failures.joined(separator: "\n  "))
        }
        return artifact
    }

    private static func registry(_ fixture: Fixture) throws -> Registry { try fixture.registryStore.loadOrEmpty() }

    private static func workspaceDirectories(_ fixture: Fixture) -> Set<String> {
        let dir = WorkspaceStoreLayout(applicationSupportDirectory: fixture.appSupport, workspaceId: Fixture.workspaceA).workspacesDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(names.filter { !$0.hasPrefix(".") })
    }

    private static func create(_ fixture: Fixture, named name: String) throws -> UUID {
        let m = try fixture.requireMounted("create")
        let before = Set(try registry(fixture).workspaces.map(\.id))
        m.delegate.workspaceCreatePromptProvider = { name }
        m.delegate.qaCreateWorkspaceFromChrome()
        m.delegate.workspaceCreatePromptProvider = nil
        guard let created = try registry(fixture).workspaces.first(where: { !before.contains($0.id) }) else {
            throw Failure(message: "create: no workspace was created")
        }
        return created.id
    }

    // MARK: - Scenarios

    private static func paletteRenameAsks(_ fixture: Fixture, _ findings: Findings) throws {
        let m = try fixture.requireMounted("rename")
        var asked: [String] = []
        m.delegate.qaSetWorkspaceRenamePrompt { current in asked.append(current); return "Kept" }
        _ = m.delegate.qaPerformPaletteAction(.renameWorkspace(Fixture.workspaceA))
        let name = try registry(fixture).workspaces.first { $0.id == Fixture.workspaceA }?.name
        findings.expect(asked == ["Grove"], "⌘K rename did not ask for a name (asked: \(asked))")
        findings.expect(name == "Kept", "⌘K rename stored \"\(name ?? "nothing")\", not the name given")
        m.delegate.qaSetWorkspaceRenamePrompt { _ in nil }
        _ = m.delegate.qaPerformPaletteAction(.renameWorkspace(Fixture.workspaceA))
        let afterCancel = try registry(fixture).workspaces.first { $0.id == Fixture.workspaceA }?.name
        findings.expect(afterCancel == "Kept", "a cancelled ⌘K rename changed the name to \"\(afterCancel ?? "nothing")\"")
    }

    /// A → B → create C (current). Deleting C goes back to B, the workspace used
    /// last — the old code went to A, the first in registry order — and keeps
    /// C's directory, byte for byte, in the workspace trash.
    private static func deleteCurrentLandsOnMostRecent(_ fixture: Fixture, _ findings: Findings) throws {
        try fixture.switchTo(Fixture.workspaceB)
        let created = try create(fixture, named: "Clearing")
        let m = try fixture.requireMounted("delete")
        findings.expect(m.runtime.workspaceId == created, "precondition: the created workspace was not mounted")
        let layout = WorkspaceStoreLayout(applicationSupportDirectory: fixture.appSupport, workspaceId: created)
        let bytes = try Data(contentsOf: layout.canvasFile)
        findings.expect(m.delegate.qaDeleteWorkspace(created), "deleting the current workspace failed: \(m.delegate.qaWorkspaceManagementMessage ?? "")")
        findings.expect(m.runtime.workspaceId == Fixture.workspaceB,
                        "deleting the current workspace landed on \(m.runtime.workspaceId), not the most recently used (Forest)")
        let after = try registry(fixture)
        findings.expect(!after.workspaces.contains { $0.id == created }, "the deleted workspace is still registered")
        findings.expect(after.lastActiveWorkspaceId == m.runtime.workspaceId, "the launch workspace is not the one mounted")
        findings.expect(!FileManager.default.fileExists(atPath: layout.workspaceDirectory.path), "the deleted workspace's directory is still live")
        let trash = WorkspaceStore(workspaceId: created, applicationSupportDirectory: fixture.appSupport).trashDirectory
        let trashed = ((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? [])
            .filter { $0.hasPrefix(created.uuidString) }
        findings.expect(trashed.count == 1, "the deleted workspace's layout is not in the trash (\(trashed))")
        if let first = trashed.first {
            let kept = try? Data(contentsOf: trash.appendingPathComponent(first).appendingPathComponent("canvas.json"))
            findings.expect(kept == bytes, "the trashed document is not the deleted one, byte for byte")
        }
    }

    /// A → B, then A's document disappears. Deleting B (current) cannot land on
    /// A; it lands on a fresh empty workspace instead of refusing the delete.
    private static func deleteCurrentSkipsUnmountable(_ fixture: Fixture, _ findings: Findings) throws {
        try fixture.switchTo(Fixture.workspaceB)
        let m = try fixture.requireMounted("delete")
        let layoutA = WorkspaceStoreLayout(applicationSupportDirectory: fixture.appSupport, workspaceId: Fixture.workspaceA)
        try FileManager.default.removeItem(at: layoutA.workspaceDirectory)
        m.runtime.discardWarmScene(workspaceId: Fixture.workspaceA)
        let deleted = m.delegate.qaDeleteWorkspace(Fixture.workspaceB)
        findings.expect(deleted, "an unmountable replacement failed the delete: \(m.delegate.qaWorkspaceManagementMessage ?? "")")
        let after = try registry(fixture)
        findings.expect(!after.workspaces.contains { $0.id == Fixture.workspaceB }, "Forest is still registered")
        findings.expect(m.runtime.workspaceId != Fixture.workspaceB && m.runtime.workspaceId != Fixture.workspaceA,
                        "the delete landed on \(m.runtime.workspaceId)")
        findings.expect(after.lastActiveWorkspaceId == m.runtime.workspaceId, "the launch workspace is not the one mounted")
    }

    /// A → B leaves A warm. Deleting A must release its controllers — their
    /// runtimes stopped, their locks given back — not leave them running with no
    /// tile anywhere.
    private static func deleteReleasesWarmRuntimes(_ fixture: Fixture, _ findings: Findings) throws {
        try fixture.switchTo(Fixture.workspaceB)
        let m = try fixture.requireMounted("delete")
        findings.facts["warmBefore"] = m.runtime.qaWarmWorkspaceIds.map(\.uuidString)
        findings.expect(m.delegate.qaDeleteWorkspace(Fixture.workspaceA), "deleting a warm workspace failed")
        findings.expect(!m.runtime.qaWarmWorkspaceIds.contains(Fixture.workspaceA), "the deleted workspace is still warm")
        for projectId in [Fixture.projectA1, Fixture.projectA2] {
            findings.expect(m.runtime.controller(for: projectId) == nil,
                            "\(Fixture.projectNames[projectId]!) still has a live controller after its workspace was deleted")
            let probe = ProjectLock(root: fixture.projectRoots[projectId]!)
            do { try probe.acquire(); probe.release() } catch {
                findings.failures.append("\(Fixture.projectNames[projectId]!)'s lock is still held after its workspace was deleted")
            }
        }
        findings.expect(m.runtime.workspaceId == Fixture.workspaceB, "deleting a workspace that is not current moved the user")
    }

    /// The switch into a new workspace fails. It still exists, and the
    /// workspace the next launch opens is the one actually mounted.
    private static func createSelectsOnlyOnceMounted(_ fixture: Fixture, _ findings: Findings) throws {
        let m = try fixture.requireMounted("create")
        let appSupport = fixture.appSupport
        m.runtime._workspaceDocumentLoader = { workspaceId in
            guard [Fixture.workspaceA, Fixture.workspaceB].contains(workspaceId) else { return nil }
            return try WorkspaceStore(workspaceId: workspaceId, applicationSupportDirectory: appSupport).tryLoad()
        }
        defer { m.runtime._workspaceDocumentLoader = nil }
        let created = try create(fixture, named: "Unreachable")
        let after = try registry(fixture)
        findings.expect(m.runtime.workspaceId == Fixture.workspaceA, "precondition: the switch into the new workspace did not fail")
        findings.expect(after.lastActiveWorkspaceId == Fixture.workspaceA,
                        "a workspace that never mounted became the launch workspace (\(String(describing: after.lastActiveWorkspaceId)))")
        let document = try WorkspaceStore(workspaceId: created, applicationSupportDirectory: appSupport).tryLoad()
        findings.expect(document != nil, "the created workspace has no document")
    }

    /// The registry write fails (its directory is read-only): the document
    /// written first must not stay behind as an orphan.
    private static func createFailureLeavesNoOrphan(_ fixture: Fixture, _ findings: Findings) throws {
        let m = try fixture.requireMounted("create")
        let before = workspaceDirectories(fixture)
        let fileManager = FileManager.default
        let original = (try? fileManager.attributesOfItem(atPath: fixture.appSupport.path)[.posixPermissions]) ?? 0o755
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.appSupport.path)
        m.delegate.workspaceCreatePromptProvider = { "Orphan" }
        m.delegate.qaCreateWorkspaceFromChrome()
        m.delegate.workspaceCreatePromptProvider = nil
        try fileManager.setAttributes([.posixPermissions: original], ofItemAtPath: fixture.appSupport.path)
        let afterRegistry = try registry(fixture)
        findings.expect(!afterRegistry.workspaces.contains { $0.name == "Orphan" }, "precondition: the registry write did not fail")
        let after = workspaceDirectories(fixture)
        findings.expect(after == before, "a failed create left \(after.subtracting(before)) behind")
        findings.expect(m.runtime.workspaceId == Fixture.workspaceA, "a failed create moved the user")
    }
}
