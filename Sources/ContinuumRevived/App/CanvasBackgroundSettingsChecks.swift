import AppKit
import ContinuumRevivedCore
import Foundation

/// WS7 — the EDITOR and the PRECEDENCE, driven through production objects.
///
/// The precedence half runs on a real `WorkspaceRuntime` with a real
/// `WorkspaceStore` on disk, adopting a real `CanvasNSView`, and switches
/// workspaces through `switchWorkspace` — so "a workspace override does not leak
/// to another workspace" is observed on the mounted canvas, not re-derived from
/// the resolver the production code also calls.
///
/// The editor half drives `CanvasBackgroundSettingsView`'s real controls and
/// real actions: no test-only mutation path exists, the `qa…` helpers select on
/// the control and then invoke the same `@objc` action the control does.
@MainActor
enum CanvasBackgroundSettingsChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(description: message()) }
    }

    /// WS7 F3: the reference-aware deferred sweep, driven through the PRODUCTION
    /// entry point (`AppDelegate.sweepCanvasBackgroundAssets`).
    ///
    /// `cleanup(referencedIDs:)` had no production caller at all: every imported
    /// background stayed on disk forever and "Remove Image" freed nothing. A
    /// witness that called `cleanup` directly would have stayed green through
    /// exactly that bug, so this drives the delegate's own method.
    ///
    /// It also pins the two ways this fix could be quietly wrong: sweeping
    /// against only the ACTIVE workspace would delete an image another workspace
    /// still names, and sweeping when a workspace document cannot be read would
    /// delete assets we cannot prove are unreferenced.
    private static func checkProductionAssetSweep() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws7-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = CanvasBackgroundAssetStore(applicationSupportDirectory: root)
        func importBytes(_ byte: UInt8, _ name: String) throws -> CanvasBackgroundAssetID {
            let url = root.appendingPathComponent(name)
            try Data(repeating: byte, count: 2048).write(to: url)
            return try store.importImage(at: url)
        }
        let globalID = try importBytes(1, "g.png")
        let workspaceID = try importBytes(2, "w.png")
        let orphanID = try importBytes(3, "orphan.png")

        let wsGlobal = UUID(), wsOverride = UUID()
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        var registry = Registry.empty()
        registry.workspaces = [
            WorkspaceEntry(id: wsGlobal, name: "inheriting", projectIds: [], createdAt: now, updatedAt: now),
            WorkspaceEntry(id: wsOverride, name: "overriding", projectIds: [], createdAt: now, updatedAt: now),
        ]
        let registryStore = RegistryStore(applicationSupportDirectory: root)
        try registryStore.save(registry)

        // The inheriting workspace names nothing; the other overrides with its own image.
        try WorkspaceStore(workspaceId: wsGlobal, applicationSupportDirectory: root)
            .save(WorkspaceDocument(viewport: .init(x: 0, y: 0, zoom: 1), zones: [], lastActiveZoneId: nil))
        var overrideConfig = CanvasBackgroundConfiguration.systemDefault
        overrideConfig.image = CanvasBackgroundImageSpec(assetID: workspaceID)
        var overrideDoc = WorkspaceDocument(viewport: .init(x: 0, y: 0, zoom: 1), zones: [], lastActiveZoneId: nil)
        overrideDoc.canvasBackground = .override(overrideConfig)
        try WorkspaceStore(workspaceId: wsOverride, applicationSupportDirectory: root).save(overrideDoc)

        var globalConfig = CanvasBackgroundConfiguration.systemDefault
        globalConfig.image = CanvasBackgroundImageSpec(assetID: globalID)
        let defaultsSuite = "continuum.test.ws7sweep.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        _ = CanvasBackgroundGlobalStore.save(globalConfig, defaults: defaults)

        let delegate = AppDelegate()
        delegate.registryStore = registryStore
        delegate.qaCanvasBackgroundSweepDefaults = defaults
        setenv("CONTINUUM_APP_SUPPORT", root.path, 1)
        defer { unsetenv("CONTINUUM_APP_SUPPORT") }

        func exists(_ id: CanvasBackgroundAssetID) -> Bool {
            FileManager.default.fileExists(atPath: store.directory.appendingPathComponent(id.fileName).path)
        }
        guard exists(globalID), exists(workspaceID), exists(orphanID) else {
            throw Failure(description: "sweep witness: the three seeded assets were not all imported")
        }

        guard let result = delegate.sweepCanvasBackgroundAssets(grace: 0) else {
            throw Failure(description: "sweep witness: the production sweep declined to run")
        }
        // Positive control: it must have actually scanned, or every assertion
        // below is satisfied vacuously by a sweep that did nothing.
        try expect(result.scanned >= 3,
                   "sweep witness: the sweep scanned \(result.scanned) files; it never ran over the store")
        try expect(!exists(orphanID),
                   "sweep witness: the ORPHANED asset survived — this is the leak the fix exists to close")
        try expect(exists(globalID),
                   "sweep witness: the asset named by the GLOBAL configuration was deleted")
        try expect(exists(workspaceID),
                   "sweep witness: the asset named by a NON-ACTIVE workspace's override was deleted — "
                   + "the sweep must span every workspace, not just the mounted one")

        // An unreadable workspace document must abort the sweep entirely rather
        // than delete assets it cannot prove are unreferenced.
        let orphan2 = try importBytes(4, "orphan2.png")
        try Data("not json".utf8).write(
            to: WorkspaceStore(workspaceId: wsOverride, applicationSupportDirectory: root).layout.canvasFile)
        try expect(delegate.sweepCanvasBackgroundAssets(grace: 0) == nil,
                   "sweep witness: an unreadable workspace document must abort the sweep")
        try expect(exists(orphan2),
                   "sweep witness: an aborted sweep still deleted an asset")
    }

    static func run() throws {
        try checkEditorAccessibilityAndKeyboardOrder()
        try checkEditorWritesTheSelectedScopeOnly()
        try checkImportAndRemoveSemantics()
        try checkPrecedenceOnRealWorkspaces()
        try checkProductionAssetSweep()
        print("canvas-background-settings: AX/keyboard order, scope writes, import/cancel/remove, live A→B→A precedence and relaunch, and the production reference-aware asset sweep")
    }

    // MARK: - Editor harness

    /// An in-memory stand-in for the two stores, so the editor half is fast and
    /// hermetic. The PRECEDENCE half below uses the real ones.
    @MainActor
    final class EditorHarness {
        var global = CanvasBackgroundConfiguration.systemDefault
        var workspace = WorkspaceCanvasBackground.inherit
        var globalWrites = 0
        var workspaceWrites = 0
        var chosenURL: URL?
        var importCalls = 0
        let assetRoot: URL
        let store: CanvasBackgroundAssetStore
        private(set) var view: CanvasBackgroundSettingsView!

        init(hasWorkspace: Bool = true) throws {
            assetRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("ws7-settings-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: assetRoot, withIntermediateDirectories: true)
            store = CanvasBackgroundAssetStore(applicationSupportDirectory: assetRoot)
            view = CanvasBackgroundSettingsView(environment: .init(
                loadGlobal: { [unowned self] in self.global },
                saveGlobal: { [unowned self] in self.global = $0; self.globalWrites += 1 },
                loadWorkspace: { [unowned self] in self.workspace },
                saveWorkspace: { [unowned self] in self.workspace = $0; self.workspaceWrites += 1 },
                importImage: { [unowned self] url in
                    self.importCalls += 1
                    return try self.store.importImage(at: url)
                },
                chooseImageURL: { [unowned self] in self.chosenURL },
                hasWorkspace: hasWorkspace))
            view.layoutSubtreeIfNeeded()
        }

        deinit { try? FileManager.default.removeItem(at: assetRoot) }
    }

    // MARK: - 1. Accessibility and keyboard order

    static func checkEditorAccessibilityAndKeyboardOrder() throws {
        let harness = try EditorHarness()
        let view = harness.view!

        let snapshots = view.qaControlSnapshots
        try expect(snapshots.count == CanvasBackgroundSettingsView.keyboardOrder.count,
                   "the section exposes \(snapshots.count) controls, the declared order names \(CanvasBackgroundSettingsView.keyboardOrder.count)")
        for snapshot in snapshots {
            try expect(!snapshot.identifier.isEmpty, "a control has no accessibility identifier: \(snapshot)")
            try expect(!snapshot.label.isEmpty, "\(snapshot.identifier) has no accessibility label")
            try expect(!snapshot.help.isEmpty, "\(snapshot.identifier) has no accessibility help")
        }
        try expect(Set(snapshots.map(\.identifier)).count == snapshots.count,
                   "two controls share an accessibility identifier: \(snapshots.map(\.identifier))")

        // The declared order is checked against APPKIT's real key-view loop, not
        // against the declaration it came from.
        let loop = view.qaKeyViewLoopIdentifiers
        try expect(loop == CanvasBackgroundSettingsView.keyboardOrder,
                   "the key-view loop is \(loop), the declared order is \(CanvasBackgroundSettingsView.keyboardOrder)")

        // The preview is decoration; the SUMMARY is what a screen reader gets.
        try expect(view.qaPreviewIsAccessibilityIgnored,
                   "the background preview is exposed to accessibility — it duplicates the summary as an unlabelled image")
        try expect(view.qaSummary.contains("all workspaces"),
                   "the summary does not state the effective scope: \(view.qaSummary)")

        // Enabled/hidden state is meaningful, not decorative.
        func enabled(_ identifier: String) -> Bool {
            view.qaControlSnapshots.first { $0.identifier == identifier }?.enabled ?? false
        }
        try expect(!enabled(CanvasBackgroundSettingsView.removeImageIdentifier),
                   "Remove Image is enabled with no image configured")
        try expect(!enabled(CanvasBackgroundSettingsView.opacityIdentifier),
                   "the opacity control is enabled with no image configured")
        view.qaSelectPattern(.solid)
        try expect(!enabled(CanvasBackgroundSettingsView.spacingIdentifier),
                   "the spacing control is enabled for a solid background, which has no grid")
        view.qaSelectPattern(.lines)
        try expect(enabled(CanvasBackgroundSettingsView.spacingIdentifier),
                   "the spacing control is disabled for a line grid")
        try expect(!enabled(CanvasBackgroundSettingsView.inheritIdentifier),
                   "Inherit Global is enabled while editing the global scope")

        // The summary tracks the state rather than restating the controls.
        view.qaSelectScope(.workspace)
        try expect(view.qaSummary.contains("inherits"),
                   "the workspace summary does not say the workspace is inheriting: \(view.qaSummary)")
        view.qaSetSpacing(120)
        try expect(view.qaSummary.contains("overrides"),
                   "after an edit the workspace summary does not say it overrides: \(view.qaSummary)")
        try expect(view.qaSummary.contains("120"),
                   "the summary does not carry the spacing value: \(view.qaSummary)")

        // With no workspace mounted, the workspace scope cannot be entered.
        let unmounted = try EditorHarness(hasWorkspace: false)
        unmounted.view.qaSelectScope(.workspace)
        try expect(unmounted.view.scope == .global,
                   "the editor entered the workspace scope with no workspace mounted")
        try expect(unmounted.workspaceWrites == 0, "the editor wrote to a workspace that is not mounted")
    }

    // MARK: - 2. Scope writes

    static func checkEditorWritesTheSelectedScopeOnly() throws {
        let harness = try EditorHarness()
        let view = harness.view!

        // Selecting a scope is NOT an edit.
        view.qaSelectScope(.workspace)
        try expect(harness.workspaceWrites == 0 && harness.globalWrites == 0,
                   "selecting a scope wrote something: global=\(harness.globalWrites) workspace=\(harness.workspaceWrites)")
        try expect(harness.workspace == .inherit, "selecting the workspace scope created an override")

        // The FIRST edit in the workspace scope establishes the override, forked
        // from what was being shown (the inherited global).
        harness.global = CanvasBackgroundConfiguration(pattern: .dots, spacing: 88)
        view.reload()
        view.qaSetSpacing(150)
        try expect(harness.globalWrites == 0, "a workspace edit wrote the global")
        try expect(harness.workspaceWrites == 1, "a workspace edit did not write the workspace")
        guard let override = harness.workspace.overrideConfiguration else {
            throw Failure(description: "the first workspace edit did not create an override")
        }
        try expect(override.spacing == 150, "the override did not take the edited spacing")
        try expect(override.pattern == .dots,
                   "the override did not fork from the inherited value: pattern is \(override.pattern), expected dots")

        // A later GLOBAL edit does not reach the overriding workspace.
        view.qaSelectScope(.global)
        view.qaSelectPattern(.solid)
        try expect(harness.global.pattern == .solid, "the global edit did not land")
        try expect(harness.workspace.overrideConfiguration?.pattern == .dots,
                   "a global edit changed an OVERRIDING workspace")

        // Inherit removes the override; the workspace then follows the global.
        view.qaSelectScope(.workspace)
        view.qaInherit()
        try expect(harness.workspace == .inherit, "Inherit Global did not clear the override")
        try expect(CanvasBackgroundResolver.effective(workspace: harness.workspace, global: harness.global)
                   == harness.global, "after inheriting, the workspace does not resolve to the global")

        // Reset differs by scope, deliberately: global resets to the default
        // CONFIGURATION, workspace resets to INHERIT.
        view.qaSelectScope(.global)
        view.qaReset()
        try expect(harness.global == .systemDefault, "Reset in the global scope did not restore the default")
        view.qaSelectScope(.workspace)
        view.qaSetSpacing(64)
        try expect(harness.workspace.isOverride, "the fixture needs an override before testing reset")
        view.qaReset()
        try expect(harness.workspace == .inherit,
                   "Reset in the workspace scope left an override instead of restoring inherit")

        // An EXACT colour survives the well round trip untouched.
        view.qaSelectScope(.global)
        let picked = NSColor(srgbRed: 0.137_254_9, green: 0.478_431_4, blue: 0.815_686_3, alpha: 1)
        view.qaSetBaseColor(picked)
        guard let stored = harness.global.base.customColor else {
            throw Failure(description: "picking a colour did not store a custom base colour")
        }
        let srgb = picked.usingColorSpace(.sRGB)!
        try expect(abs(stored.red - Double(srgb.redComponent)) < 1e-6
                   && abs(stored.green - Double(srgb.greenComponent)) < 1e-6
                   && abs(stored.blue - Double(srgb.blueComponent)) < 1e-6,
                   "the picked colour was rewritten: stored \(stored.rgba8), picked (\(srgb.redComponent), \(srgb.greenComponent), \(srgb.blueComponent))")
        // …and the live preview draws exactly it.
        try expect(view.qaPreview.currentConfiguration.base.customColor == stored,
                   "the live preview is not showing the edited configuration")
    }

    // MARK: - 3. Import, cancel and remove

    static func checkImportAndRemoveSemantics() throws {
        let harness = try EditorHarness()
        let view = harness.view!

        // CANCEL changes nothing at all.
        harness.chosenURL = nil
        let before = harness.global
        view.qaChooseImage()
        try expect(harness.importCalls == 0, "cancelling the picker still imported")
        try expect(harness.globalWrites == 0 && harness.workspaceWrites == 0,
                   "cancelling the picker wrote a configuration")
        try expect(harness.global == before, "cancelling the picker changed the configuration")

        // A real import stores an id, never a path.
        let source = harness.assetRoot.appendingPathComponent("picked-wallpaper.png")
        try Data((0..<2048).map { UInt8($0 % 253) }).write(to: source)
        harness.chosenURL = source
        view.qaChooseImage()
        try expect(harness.importCalls == 1, "the picker result was not imported")
        guard let spec = harness.global.image else {
            throw Failure(description: "the import did not reach the configuration")
        }
        try expect(harness.store.exists(spec.assetID), "the imported asset is not in the managed directory")
        let encoded = String(data: try JSONCodec.makeEncoder().encode(harness.global), encoding: .utf8)!
        try expect(!encoded.contains("picked-wallpaper") && !encoded.contains(harness.assetRoot.path)
                   && !encoded.contains("/"),
                   "the encoded configuration carries a path or the user's filename: \(encoded)")
        try expect(spec.opacity == .full && spec.mode == .fill,
                   "a fresh import did not take the documented defaults")

        // Opacity and mode edit the existing reference rather than replacing it.
        view.qaSetOpacity(.muted)
        view.qaSetMode(.fit)
        try expect(harness.global.image?.assetID == spec.assetID, "editing opacity replaced the asset reference")
        try expect(harness.global.image?.opacity == .muted && harness.global.image?.mode == .fit,
                   "opacity/mode edits did not land: \(String(describing: harness.global.image))")

        // An UNUSABLE pick is refused, surfaced, and changes nothing.
        let bad = harness.assetRoot.appendingPathComponent("not-an-image.exe")
        try Data([1, 2, 3]).write(to: bad)
        harness.chosenURL = bad
        let beforeBad = harness.global
        view.qaChooseImage()
        try expect(harness.global == beforeBad, "a refused import changed the configuration")
        try expect(view.qaSummary.contains("could not be used"),
                   "a refused import was not surfaced to the user: \(view.qaSummary)")

        // REMOVE clears the reference and leaves the managed file for the
        // deferred, reference-aware sweep.
        harness.chosenURL = source
        view.qaChooseImage()
        view.qaRemoveImage()
        try expect(harness.global.image == nil, "Remove Image did not clear the reference")
        try expect(harness.store.exists(spec.assetID),
                   "Remove Image deleted the managed file immediately — cleanup is deferred and reference-aware")
    }

    // MARK: - 4. Precedence on real workspaces

    static func checkPrecedenceOnRealWorkspaces() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws7-workspaces-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "dev.arrayapp.ws7.settings.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw Failure(description: "could not create an isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let workspaceA = UUID(), workspaceB = UUID()
        let storeA = WorkspaceStore(workspaceId: workspaceA, applicationSupportDirectory: root)
        let storeB = WorkspaceStore(workspaceId: workspaceB, applicationSupportDirectory: root)
        func document() -> WorkspaceDocument {
            WorkspaceDocument(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), zones: [], lastActiveZoneId: nil)
        }
        try storeA.save(document())
        try storeB.save(document())

        var registry = Registry.empty()
        registry.lastActiveWorkspaceId = workspaceA
        let registryStore = RegistryStore(applicationSupportDirectory: root)
        try registryStore.save(registry)

        let globalConfig = CanvasBackgroundConfiguration(pattern: .lines, spacing: 40)
        CanvasBackgroundGlobalStore.save(globalConfig, defaults: defaults)

        let browserEngine = BrowserEngineContext()
        defer { browserEngine.shutdown() }
        let canvas = CanvasNSView(
            canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil),
            activeZone: nil, zoneRenderModels: [], showsZoneChrome: false)
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let delegate = AppDelegate()
        let runtime = WorkspaceRuntime(
            workspaceId: workspaceA,
            document: try storeA.load(),
            registry: ZoneRuntimeRegistry(closeOnZero: true, makeController: { _ in
                throw Failure(description: "this fixture has no projects")
            }),
            focusBroker: delegate.qaFocusBroker,
            registryStore: registryStore,
            ghostty: nil,
            browserEngine: browserEngine)
        runtime.canvasBackgroundDefaults = defaults
        runtime.adoptCanvas(canvas)

        // Adopting the canvas applies the INHERITED global immediately.
        try expect(canvas.backgroundRenderer.currentConfiguration == globalConfig,
                   "adopting a canvas did not push the inherited global background: \(canvas.backgroundRenderer.currentConfiguration)")

        // A→override. It reaches the canvas AND the file.
        let overrideA = CanvasBackgroundConfiguration(
            base: .custom(CanvasBackgroundRGBA(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)!),
            pattern: .dots, spacing: 128)
        try runtime.setWorkspaceCanvasBackground(.override(overrideA))
        try expect(canvas.backgroundRenderer.currentConfiguration == overrideA,
                   "a workspace override did not reach the mounted canvas")
        try expect(try storeA.load().canvasBackground == .override(overrideA),
                   "the override was not persisted to workspace A's document")
        try expect(try storeB.load().canvasBackground == .inherit,
                   "setting workspace A's background wrote workspace B's document")

        // A global change must not disturb the overriding workspace.
        let newGlobal = CanvasBackgroundConfiguration(pattern: .solid, spacing: 200)
        runtime.setGlobalCanvasBackground(newGlobal)
        try expect(canvas.backgroundRenderer.currentConfiguration == overrideA,
                   "a global edit overwrote an overriding workspace's background on the canvas")
        try expect(runtime.effectiveCanvasBackground == overrideA,
                   "a global edit changed the resolved value for an overriding workspace")

        // SWITCH A → B. B inherits, so it must show the NEW global — not A's
        // override, and not the old global.
        try runtime.switchWorkspace(to: workspaceB)
        try expect(canvas.backgroundRenderer.currentConfiguration == newGlobal,
                   "after switching to the inheriting workspace the canvas shows \(canvas.backgroundRenderer.currentConfiguration), expected the global \(newGlobal)")
        try expect(runtime.document.canvasBackground == .inherit, "workspace B lost its inherit state")

        // B gets its own override, then A→B→A returns A's, unchanged.
        let overrideB = CanvasBackgroundConfiguration(pattern: .lines, spacing: 16)
        try runtime.setWorkspaceCanvasBackground(.override(overrideB))
        try runtime.switchWorkspace(to: workspaceA)
        try expect(canvas.backgroundRenderer.currentConfiguration == overrideA,
                   "returning to workspace A did not restore its own override: \(canvas.backgroundRenderer.currentConfiguration)")
        try expect(try storeB.load().canvasBackground == .override(overrideB),
                   "workspace B's override did not survive the switch away")
        try expect(try storeA.load().canvasBackground == .override(overrideA),
                   "workspace A's override was rewritten by the round trip")

        // RELAUNCH: a fresh runtime and a fresh canvas, reading the same files
        // and the same defaults suite, restores the same effective background.
        let canvas2 = CanvasNSView(
            canvasState: CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil),
            activeZone: nil, zoneRenderModels: [], showsZoneChrome: false)
        canvas2.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let runtime2 = WorkspaceRuntime(
            workspaceId: workspaceA,
            document: try storeA.load(),
            registry: ZoneRuntimeRegistry(closeOnZero: true, makeController: { _ in
                throw Failure(description: "this fixture has no projects")
            }),
            focusBroker: delegate.qaFocusBroker,
            registryStore: registryStore,
            ghostty: nil,
            browserEngine: browserEngine)
        runtime2.canvasBackgroundDefaults = defaults
        runtime2.adoptCanvas(canvas2)
        try expect(canvas2.backgroundRenderer.currentConfiguration == overrideA,
                   "a relaunch did not restore workspace A's override: \(canvas2.backgroundRenderer.currentConfiguration)")

        // The GLOBAL survives a relaunch too, read back from the same suite.
        try expect(CanvasBackgroundGlobalStore.load(defaults: defaults) == newGlobal,
                   "the global configuration did not survive a fresh read")

        // …and the CHANNEL split holds: a different suite (a different channel's
        // defaults domain) sees nothing of this one.
        let otherSuiteName = "dev.arrayapp.ws7.other.\(UUID().uuidString)"
        guard let otherDefaults = UserDefaults(suiteName: otherSuiteName) else {
            throw Failure(description: "could not create the second defaults suite")
        }
        defer { otherDefaults.removePersistentDomain(forName: otherSuiteName) }
        try expect(CanvasBackgroundGlobalStore.load(defaults: otherDefaults) == .systemDefault,
                   "a second defaults domain can read this one's global background")
    }
}
