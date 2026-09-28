import AppKit
import ContinuumRevivedCore
import Foundation

/// Directed witnesses for the data-protection patches (`.plans/67`, slice 1),
/// each on `WorkspaceInvariantsFixture`: two real workspaces mounted through
/// `mountWorkspaceSceneAtBoot`, driven through the entry points a user reaches,
/// asserted on the bytes on disk. Each flag runs every scenario and reports all
/// that failed, so a RED run names every broken route at once.
@MainActor
enum WorkspaceDataProtectionChecks {
    typealias Fixture = WorkspaceInvariantsFixture

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure(message: message()) }
    }

    /// Run each scenario on its own fixture; fail with every failure message.
    private static func runScenarios(
        _ name: String, _ scenarios: [(String, (Fixture) throws -> [String: Any])]
    ) throws -> URL {
        var manifest: [String: Any] = [:]
        var failures: [String] = []
        for (label, body) in scenarios {
            let fixture = try Fixture(label: label)
            do {
                var result = try body(fixture)
                result["actions"] = fixture.actionLog
                manifest[label] = result
            } catch {
                failures.append("\(label): \(error)")
                manifest[label] = ["failure": "\(error)", "actions": fixture.actionLog]
            }
            fixture.dispose()
        }
        let timestamp = Int(Date().timeIntervalSince1970)
        let dir = URL(fileURLWithPath: "qa-runs/\(timestamp)/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let artifact = dir.appendingPathComponent("manifest.json", isDirectory: false)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        if !failures.isEmpty {
            throw Failure(message: "\(failures.count) of \(scenarios.count) scenario(s) failed (\(artifact.path)):\n  "
                          + failures.joined(separator: "\n  "))
        }
        return artifact
    }

    // MARK: - --workspace-saver-identity-check

    /// One saver per mounted workspace, superseded by every later save; no
    /// writer reads the mounted document back from disk.
    static func runSaverIdentity() throws -> URL {
        try runScenarios("workspace-saver-identity", [
            ("cross-workspace", crossWorkspaceArming),
            ("arm-then-rename", armThenRename),
            ("arm-then-layout-commit", armThenLayoutCommit)
        ])
    }

    /// Mount A, arm A, switch to B, arm B, drain: A's file is not touched by
    /// anything B does, and B's arming lands in B's file.
    private static func crossWorkspaceArming(_ fixture: Fixture) throws -> [String: Any] {
        try fixture.mount()
        try fixture.armByClick(Fixture.zoneA2)
        try fixture.switchTo(Fixture.workspaceB)
        let aBytes = try fixture.readWorkspaceFile(Fixture.workspaceA).bytes
        try expect(aBytes != nil, "A has no file after switching away")
        try fixture.armByClick(Fixture.zoneB2)
        fixture.drain()
        let aAfter = try fixture.readWorkspaceFile(Fixture.workspaceA)
        let bAfter = try fixture.readWorkspaceFile(Fixture.workspaceB)
        try expect(aAfter.bytes == aBytes,
                   "A's file changed while B was mounted; it now holds zones "
                   + "\(aAfter.document?.zones.map(\.zoneId) ?? []) armed at \(String(describing: aAfter.document?.lastActiveZoneId))")
        try expect(bAfter.document?.lastActiveZoneId == Fixture.zoneB2,
                   "arming zone B2 in B never reached B's file; B's file is armed at "
                   + "\(String(describing: bAfter.document?.lastActiveZoneId))")
        return ["aUnchanged": true]
    }

    /// Arm (debounced), then rename (synchronous) inside the debounce window,
    /// drain, then die: the durable document is the latest one, both changes.
    private static func armThenRename(_ fixture: Fixture) throws -> [String: Any] {
        let name = "Renamed inside the debounce window"
        try fixture.mount()
        try fixture.armByClick(Fixture.zoneA2)
        try fixture.rename(Fixture.zoneA1, to: name)
        fixture.drain()
        try fixture.remount(crash: true)
        let document = try fixture.modelView().document
        let zone = document.zones.first { $0.zoneId == Fixture.zoneA1 }
        try expect(zone?.name == name,
                   "the rename did not survive: zone A1 is named \(String(describing: zone?.name)) after remount")
        try expect(document.lastActiveZoneId == Fixture.zoneA2,
                   "the arming did not survive: armed at \(String(describing: document.lastActiveZoneId)) after remount")
        return ["name": name]
    }

    /// Arm (debounced), then move a tile through the canvas's programmatic
    /// geometry route — the drag's own owner, which commits through the
    /// `onLayoutCommitted` callback production wires in the mount — inside the
    /// debounce window. Neither the commit nor the arming may undo the other,
    /// in memory or on disk.
    private static func armThenLayoutCommit(_ fixture: Fixture) throws -> [String: Any] {
        try fixture.mount()
        let m = try fixture.requireMounted("layout commit")
        try fixture.armByClick(Fixture.zoneA2)
        var requested = Fixture.seed.tiles[Fixture.noteA1a]!
        requested.x += 30
        let outcome = m.canvas.applyProgrammaticTileGeometry(
            tileId: Fixture.noteA1a, in: Fixture.zoneA1, worldFrame: requested, action: .moveTile)
        guard case .committed = outcome else { throw Failure(message: "the tile move was not committed: \(outcome)") }
        let committed = try fixture.modelView().tileWorldFrames[Fixture.noteA1a]
        try expect(committed != Fixture.seed.tiles[Fixture.noteA1a], "the committed move left the tile where it was")
        try expect(m.runtime.qaArmedZoneId == Fixture.zoneA2,
                   "the layout commit reverted the in-memory arming to "
                   + "\(String(describing: m.runtime.qaArmedZoneId))")
        fixture.drain()
        let onDisk = try fixture.readWorkspaceFile(Fixture.workspaceA).document
        try expect(onDisk?.lastActiveZoneId == Fixture.zoneA2,
                   "disk lost the arming: armed at \(String(describing: onDisk?.lastActiveZoneId))")
        let tile = fixture.readProjectFile(Fixture.projectA1).canvas?.tiles.first { $0.id == Fixture.noteA1a }
        try expect(tile?.frame == committed,
                   "disk lost the committed tile frame: \(String(describing: tile?.frame)), committed \(String(describing: committed))")
        return ["armed": Fixture.zoneA2.uuidString, "committed": "\(String(describing: committed))"]
    }
}

extension WorkspaceDataProtectionChecks {
    // MARK: - --note-conversion-writer-check

    /// Converting a note to a document that is already open keeps every other
    /// record of the project exactly where it was.
    static func runNoteConversionWriter() throws -> URL {
        try runScenarios("note-conversion-writer", [("reuse-open-document", noteReusesOpenDocument)])
    }

    /// A note in zone A1 (origin 600,200) is saved as the Markdown file a file
    /// tile in the same zone already has open. Project A1 also owns zone A3.
    /// The process dies right after, before any later canvas save could rewrite
    /// the file. After the remount: the note is gone, and every other tile of
    /// the project — its zone-mate and the sibling zone's tile — is still there
    /// with its WORLD frame.
    private static func noteReusesOpenDocument(_ fixture: Fixture) throws -> [String: Any] {
        try fixture.mount()
        let m = try fixture.requireMounted("note reuse")
        guard let noteView = m.canvas.tileView(for: Fixture.noteA1a) as? NoteTileNSView else {
            throw Failure(message: "note A1a is not hydrated as a note view")
        }
        let destination = fixture.projectRoots[Fixture.projectA1]!.appendingPathComponent(Fixture.fileA1Name)
        // The note's own Save-as-Markdown callback, as its menu item fires it.
        noteView.onSaveAsMarkdownRequested?(destination)
        try expect(m.canvas.tileView(for: Fixture.noteA1a) == nil, "the note was not converted")
        try fixture.remount(crash: true)

        var expected = Fixture.seed
        expected.tiles[Fixture.noteA1a] = nil
        expected.tileProject[Fixture.noteA1a] = nil
        expected.tileZone[Fixture.noteA1a] = nil
        let violations = try fixture.allViolations(expected: expected, invariants: [.geometry, .conservation])
        let onDisk = fixture.readProjectFile(Fixture.projectA1).canvas?.tiles
            .map { "\($0.id.uuidString.suffix(4)) \($0.frame)" } ?? []
        try expect(violations.isEmpty,
                   "after the conversion and a remount: \(violations.map(\.description)); project A1's file holds \(onDisk)")
        return ["projectA1": onDisk]
    }
}

extension WorkspaceDataProtectionChecks {
    // MARK: - --retired-flat-write-check

    /// Once the mount retires the boot-only flat scene, its model is a stale
    /// boot snapshot, and no production path may write it to a project file.
    static func runRetiredFlatWrite() throws -> URL {
        try runScenarios("retired-flat-write", [
            ("inspector-reveal", inspectorRevealAfterRetirement),
            ("flat-writer-refuses", flatWriterRefusesAfterRetirement)
        ])
    }

    /// Spawn a browser and its inspector into zone A1, commit a tile move, then
    /// ask for the inspector again, which takes the reveal-the-existing-one
    /// branch. Project A1's file must still hold the moved frame and both
    /// spawned tiles: writing the flat scene put the boot snapshot back.
    private static func inspectorRevealAfterRetirement(_ fixture: Fixture) throws -> [String: Any] {
        try fixture.mount()
        let m = try fixture.requireMounted("inspector reveal")
        guard let spawner = m.runtime.controller(for: Fixture.projectA1)?.tileSpawner else {
            throw Failure(message: "project A1 has no live spawner")
        }
        guard case let .spawned(browser) = spawner.spawnBrowser(url: "about:blank", targetZoneId: Fixture.zoneA1) else {
            throw Failure(message: "browser spawn into zone A1 failed")
        }
        guard case let .spawned(inspector) = spawner.spawnBrowserInspector(for: browser.tileId) else {
            throw Failure(message: "first inspector spawn failed")
        }
        var requested = Fixture.seed.tiles[Fixture.noteA1b]!
        requested.y += 40
        guard case .committed = m.canvas.applyProgrammaticTileGeometry(
            tileId: Fixture.noteA1b, in: Fixture.zoneA1, worldFrame: requested, action: .moveTile) else {
            throw Failure(message: "the tile move was not committed")
        }
        let moved = try fixture.modelView().tileWorldFrames[Fixture.noteA1b]
        guard case let .spawned(revealed) = spawner.spawnBrowserInspector(for: browser.tileId), revealed == inspector else {
            throw Failure(message: "the second inspector request did not reveal the existing inspector")
        }
        // Read the file the reveal left, before any later canvas save rewrites it:
        // the process can die here.
        let tiles = fixture.readProjectFile(Fixture.projectA1).canvas?.tiles ?? []
        let byId = Dictionary(tiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        try expect(byId[browser.tileId] != nil && byId[inspector] != nil,
                   "project A1's file lost the spawned browser and inspector; it holds \(tiles.map { $0.id.uuidString.suffix(4) })")
        try expect(byId[Fixture.noteA1b]?.frame == moved,
                   "project A1's file lost the committed move: \(String(describing: byId[Fixture.noteA1b]?.frame)), committed \(String(describing: moved))")
        return ["tiles": tiles.map { "\($0.id.uuidString.suffix(4)) \($0.kind)" }]
    }

    /// The flat scene's writer refuses once the scene is retired, and every
    /// project file is untouched by the refusal.
    private static func flatWriterRefusesAfterRetirement(_ fixture: Fixture) throws -> [String: Any] {
        try fixture.mount()
        let m = try fixture.requireMounted("flat writer")
        let before = fixture.readProjectFile(Fixture.projectA1).bytes
        var refused = false
        do { _ = try m.canvas.flatCanvasStateForPersistence() } catch { refused = true }
        try expect(refused, "the retired flat scene's state was still handed out for persistence")
        try expect(fixture.readProjectFile(Fixture.projectA1).bytes == before, "a refused flat write changed project A1's file")
        return ["refused": refused]
    }
}

extension WorkspaceDataProtectionChecks {
    // MARK: - --flat-spawn-migration-check

    /// The two spawns that were left on the flat path land in the armed zone's
    /// layer and its own project's file, in WORLD frames.
    static func runFlatSpawnMigration() throws -> URL {
        try runScenarios("flat-spawn-migration", [
            ("diff-review-from-palette", diffReviewFromPalette),
            ("run-artifacts", runArtifactsSpawn)
        ])
    }

    private static func diffReviewFromPalette(_ fixture: Fixture) throws -> [String: Any] {
        try fixture.mount()
        let m = try fixture.requireMounted("diff review")
        try fixture.armByClick(Fixture.zoneA2)
        let before = Set(try fixture.modelView().tileWorldFrames.keys)
        _ = m.delegate.qaPerformPaletteAction(.newDiffReview)
        return try expectSpawnedInArmedZone(fixture, before: before, kind: .diffReview)
    }

    private static func runArtifactsSpawn(_ fixture: Fixture) throws -> [String: Any] {
        try fixture.mount()
        let m = try fixture.requireMounted("run artifacts")
        try fixture.armByClick(Fixture.zoneA2)
        guard let spawner = m.runtime.controller(for: Fixture.projectA2)?.tileSpawner else {
            throw Failure(message: "project A2 has no live spawner")
        }
        let runDirectory = fixture.root.appendingPathComponent("run-0001", isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let before = Set(try fixture.modelView().tileWorldFrames.keys)
        switch spawner.spawnRunArtifacts(runDirectoryPath: runDirectory.path) {
        case .spawned, .alreadyOpen: break
        case .invalidPath: throw Failure(message: "spawnRunArtifacts rejected a valid path")
        case let .failure(error): throw Failure(message: "spawnRunArtifacts failed: \(error)")
        }
        return try expectSpawnedInArmedZone(fixture, before: before, kind: .runArtifacts)
    }

    /// Exactly one new tile of `kind`: in zone A2's layer, its WORLD frame inside
    /// zone A2's WORLD rect, persisted with that frame in project A2's file, which
    /// holds only project A2's tiles; project A1's file untouched.
    private static func expectSpawnedInArmedZone(
        _ fixture: Fixture, before: Set<UUID>, kind: TileKind
    ) throws -> [String: Any] {
        let m = try fixture.requireMounted("spawn")
        let a1Bytes = fixture.readProjectFile(Fixture.projectA1).bytes
        let frames = try fixture.modelView().tileWorldFrames
        let new = Set(frames.keys).subtracting(before)
        try expect(new.count == 1, "expected one new tile in the mounted scene, found \(new.count)")
        let tileId = new.first!
        let world = frames[tileId]!
        try expect(m.canvas.tiles(inZone: Fixture.zoneA2)?.contains { $0.id == tileId } == true,
                   "the new tile is not in the armed zone's layer (zone A2)")
        guard let zone = m.canvas.zonePlacement(for: Fixture.zoneA2) else { throw Failure(message: "zone A2 vanished") }
        let rect = CanvasEngine.zoneWorldFrame(zone)
        try expect(world.x >= rect.x && world.y >= rect.y
                   && world.x + world.width <= rect.x + rect.width && world.y + world.height <= rect.y + rect.height,
                   "the new tile's WORLD frame \(world) is outside zone A2's WORLD rect \(rect)")
        let fileA2 = fixture.readProjectFile(Fixture.projectA2).canvas?.tiles ?? []
        let persisted = fileA2.first { $0.id == tileId }
        try expect(persisted?.kind == kind && persisted?.frame == world,
                   "project A2's file holds \(String(describing: persisted.map { "\($0.kind) \($0.frame)" })) for the new tile; the scene has \(kind) \(world)")
        let a2Seed = Set(Fixture.seed.tileProject.filter { $0.value == Fixture.projectA2 }.keys)
        let foreign = Set(fileA2.map(\.id)).subtracting(a2Seed).subtracting([tileId])
        try expect(foreign.isEmpty, "project A2's file holds tiles that are not project A2's: \(foreign)")
        try expect(fixture.readProjectFile(Fixture.projectA1).bytes == a1Bytes, "the spawn rewrote project A1's file")
        return ["tile": tileId.uuidString, "world": "\(world)", "zone": "\(rect)"]
    }
}

extension WorkspaceDataProtectionChecks {
    // MARK: - --canvas-save-receipt-check

    /// A canvas save acknowledges only what landed, failure reaches switch and
    /// quit, and no write outlives the project lock that authorized it.
    static func runCanvasSaveReceipt() throws -> URL {
        try runScenarios("canvas-save-receipt", [
            ("failing-store", failingCanvasStore),
            ("lock-outlives-write", lockOutlivesQueuedWrite),
            ("lock-outlives-write-on-switch", lockOutlivesQueuedWriteOnSwitch)
        ])
    }

    /// A camera change, as a pan reports it, scheduling project A1's debounced
    /// canvas save.
    private static func panAndReport(_ m: Fixture.Mounted, dy: Double) {
        var viewport = m.canvas.viewport
        viewport.y += dy
        m.canvas.setViewport(viewport)
        m.delegate.canvasDidChange(m.canvas)
    }

    private static func canvasFilePlan(
        _ fixture: Fixture, _ fault: StoreFileWriter.Fault, project: UUID = Fixture.projectA1
    ) -> StoreFileWriter.Plan {
        let file = ProjectStoreLayout(projectRoot: fixture.projectRoots[project]!).canvasFile
        return StoreFileWriter.Plan(fault: fault, scope: file.deletingLastPathComponent(),
                                    matching: { $0.lastPathComponent == file.lastPathComponent })
    }

    /// Every write of project A1's canvas fails. The debounced save must not
    /// acknowledge, switch and quit must refuse, and once the store recovers the
    /// change the user made is still there to save.
    private static func failingCanvasStore(_ fixture: Fixture) throws -> [String: Any] {
        try fixture.mount()
        let m = try fixture.requireMounted("failing store")
        guard let controller = m.runtime.controller(for: Fixture.projectA1) else { throw Failure(message: "no A1 controller") }
        var acknowledgements = 0
        let production = controller.onCanvasStatePersisted
        controller.onCanvasStatePersisted = { acknowledgements += 1; production?() }

        StoreFileWriter.install(canvasFilePlan(fixture, .failFrom(1)))
        defer { StoreFileWriter.uninstall() }
        panAndReport(m, dy: 40)
        let panned = m.canvas.viewport
        fixture.drain()
        let failedWrites = StoreFileWriter.trace.filter { $0.outcome == .failed }.count
        try expect(failedWrites > 0, "the pan scheduled no canvas write to fail")
        try expect(acknowledgements == 0, "a failed canvas save was acknowledged \(acknowledgements) time(s)")

        let switched = m.delegate.qaSwitchWorkspaceFromSidebar(Fixture.workspaceB)
        try expect(!switched && m.runtime.workspaceId == Fixture.workspaceA,
                   "the switch went ahead over an unsaved canvas; runtime is on \(m.runtime.workspaceId)")
        let reply = m.delegate.qaQuitForRemount()
        try expect(reply == .terminateCancel, "quit went ahead over an unsaved canvas")

        StoreFileWriter.uninstall()
        try fixture.quit()
        let onDisk = fixture.readProjectFile(Fixture.projectA1).canvas?.viewport
        try expect(onDisk == panned,
                   "after the store recovered, quit did not save the change: disk viewport \(String(describing: onDisk)), panned \(panned)")
        return ["failedWrites": failedWrites, "acknowledgements": acknowledgements]
    }

    /// As below, but the lock is released by a workspace switch releasing the
    /// departing project rather than by quit — a project that is no longer the
    /// active one. The switch re-dirties only the ACTIVE controller's canvas, so
    /// nothing sends this project's final flush through the save queue by
    /// accident: pan in zone A2, click zone A1, switch, all inside one slow write.
    private static func lockOutlivesQueuedWriteOnSwitch(_ fixture: Fixture) throws -> [String: Any] {
        try fixture.mount()
        let m = try fixture.requireMounted("lock on switch")
        try fixture.armByClick(Fixture.zoneA2)
        fixture.drain(0.3)
        StoreFileWriter.install(canvasFilePlan(fixture, .delayWrite(1, seconds: 1.5), project: Fixture.projectA2))
        defer { StoreFileWriter.uninstall() }
        panAndReport(m, dy: 60)
        fixture.drain(0.4)
        try fixture.armByClick(Fixture.zoneA1)
        try fixture.switchTo(Fixture.workspaceB)
        let lock = ProjectLock(root: fixture.projectRoots[Fixture.projectA2]!)
        var lockFree = false
        do { try lock.acquire(); lockFree = true } catch {}
        let heldLanded = { StoreFileWriter.trace.contains { $0.index == 1 && $0.outcome == .landed } }
        let landedAtRelease = heldLanded()
        let traceAtRelease = StoreFileWriter.trace.map(\.description)
        if lockFree { lock.release() }
        fixture.drain(1.6)
        try expect(heldLanded(), "the held canvas write never landed")
        try expect(!lockFree || landedAtRelease,
                   "switching away freed project A2's lock while its canvas write was still queued; trace at release \(traceAtRelease)")
        return ["lockFreeAfterSwitch": lockFree, "heldWriteLandedByThen": landedAtRelease]
    }

    /// Project A2's debounced canvas write is held on the save queue, and the
    /// user quits while it is in flight. The project lock must not come free
    /// before that write has resolved. Project A2 on purpose: it holds only a
    /// note, so nothing at quit re-dirties its canvas and sends a synchronous
    /// write through the queue that would wait behind the held one by accident.
    private static func lockOutlivesQueuedWrite(_ fixture: Fixture) throws -> [String: Any] {
        try fixture.mount()
        let m = try fixture.requireMounted("lock")
        try fixture.armByClick(Fixture.zoneA2)
        fixture.drain(0.3)
        StoreFileWriter.install(canvasFilePlan(fixture, .delayWrite(1, seconds: 1.5), project: Fixture.projectA2))
        defer { StoreFileWriter.uninstall() }
        panAndReport(m, dy: 60)
        // Let the debounce fire and the write start waiting on the save queue.
        fixture.drain(0.4)
        try fixture.quit()
        let lock = ProjectLock(root: fixture.projectRoots[Fixture.projectA2]!)
        var lockFree = false
        do { try lock.acquire(); lockFree = true } catch {}
        // The held write is the plan's first counted mutation.
        let heldLanded = { StoreFileWriter.trace.contains { $0.index == 1 && $0.outcome == .landed } }
        let landedAtRelease = heldLanded()
        let traceAtRelease = StoreFileWriter.trace.map(\.description)
        if lockFree { lock.release() }
        fixture.drain(1.6)
        let trace = StoreFileWriter.trace.map(\.description)
        try expect(heldLanded(), "the held canvas write never landed; trace \(trace)")
        try expect(!lockFree || landedAtRelease,
                   "the project lock was free while its canvas write was still queued; trace at release \(traceAtRelease)")
        return ["lockFreeAfterQuit": lockFree, "heldWriteLandedByThen": landedAtRelease, "trace": trace]
    }
}

extension WorkspaceDataProtectionChecks {
    // MARK: - --picker-epoch-fence-check

    /// A choice made in a picker opened under one mounted scene never lands in
    /// another: the confirm is fenced by the mount it was opened in.
    static func runPickerEpochFence() throws -> URL {
        try runScenarios("picker-epoch-fence", [
            ("switch-while-open", pickerConfirmAfterSwitch),
            ("same-mount-lands", pickerConfirmSameMount)
        ])
    }

    /// Positive control: a pick confirmed under the mount it was opened in lands,
    /// so the fence cannot pass by refusing everything.
    private static func pickerConfirmSameMount(_ fixture: Fixture) throws -> [String: Any] {
        try fixture.mount()
        let m = try fixture.requireMounted("picker")
        m.canvas.requestZoneScopeChange(zoneId: Fixture.zoneA2)
        let pressed = m.delegate.qaConfirmProjectHomePicker(projectId: Fixture.projectA2, homeRelativePath: nil)
        fixture.drain()
        let scope = try fixture.readWorkspaceFile(Fixture.workspaceA).document?.lastExplicitCreationScope
        try expect(pressed && scope?.projectId == Fixture.projectA2,
                   "a pick confirmed in the mount it was opened in did not land: pressed \(pressed), A's scope \(String(describing: scope))")
        return ["scope": "\(String(describing: scope))"]
    }

    /// Open zone A1's Home picker (the header's Home action), switch to B from
    /// the sidebar with the picker still open, then press B1's row. Nothing may
    /// change: not B's file, not A's, not the registry.
    private static func pickerConfirmAfterSwitch(_ fixture: Fixture) throws -> [String: Any] {
        try fixture.mount()
        let m = try fixture.requireMounted("picker")
        m.canvas.requestZoneScopeChange(zoneId: Fixture.zoneA1)
        try fixture.switchTo(Fixture.workspaceB)
        let aBytes = try fixture.readWorkspaceFile(Fixture.workspaceA).bytes
        let bBytes = try fixture.readWorkspaceFile(Fixture.workspaceB).bytes
        let registryBytes = try Data(contentsOf: fixture.registryStore.registryFile)
        let pressed = m.delegate.qaConfirmProjectHomePicker(projectId: Fixture.projectB1, homeRelativePath: nil)
        fixture.drain()
        let bAfter = try fixture.readWorkspaceFile(Fixture.workspaceB)
        try expect(bAfter.bytes == bBytes,
                   "a pick made for workspace A's zone landed in B's file (pressed: \(pressed)); B's explicit scope is now "
                   + "\(String(describing: bAfter.document?.lastExplicitCreationScope))")
        let aAfter = try fixture.readWorkspaceFile(Fixture.workspaceA).bytes
        let registryAfter = try Data(contentsOf: fixture.registryStore.registryFile)
        try expect(aAfter == aBytes, "the stale pick changed A's file")
        try expect(registryAfter == registryBytes, "the stale pick changed the registry")
        try expect(m.runtime.document.lastExplicitCreationScope == bAfter.document?.lastExplicitCreationScope,
                   "the stale pick changed B's mounted document")
        return ["pressed": pressed]
    }
}

private extension Optional {
    func orThrow(_ error: Error) throws -> Wrapped {
        guard let value = self else { throw error }
        return value
    }
}
