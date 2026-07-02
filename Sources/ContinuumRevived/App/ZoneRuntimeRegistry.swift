import AppKit
import ContinuumRevivedCore
import Foundation

/// One `ZoneRuntimeController` per `projectId`, ref-counted across workspaces
/// (docs/23 S2, CON-58). A project = one lock / one PTY set / one WKWebView set,
/// so it may hydrate only once even when shown in multiple workspaces.
/// `acquire` creates-if-missing and bumps the ref-count; `release` drops it and
/// `close()`s the controller at zero (unless `closeOnZero == false`, which keeps
/// it warm). The controller factory is injected so headless checks build
/// lock-free controllers with no PTY/WebView.
@MainActor
final class ZoneRuntimeRegistry {
    typealias Factory = (UUID) throws -> ZoneRuntimeController

    private struct Box {
        let controller: ZoneRuntimeController
        var refCount: Int
    }

    private var boxes: [UUID: Box] = [:]
    private let makeController: Factory
    private let closeOnZero: Bool

    init(closeOnZero: Bool = ZoneRuntimeBudgetConfig.closeOnZero(),
         makeController: @escaping Factory) {
        self.closeOnZero = closeOnZero
        self.makeController = makeController
    }

    /// Returns the controller for `projectId`, creating it on first acquire,
    /// reusing it (same instance) on subsequent acquires, and incrementing the
    /// ref-count each time.
    @discardableResult
    func acquire(projectId: UUID) throws -> ZoneRuntimeController {
        if var box = boxes[projectId] {
            box.refCount += 1
            boxes[projectId] = box
            return box.controller
        }
        let controller = try makeController(projectId)
        boxes[projectId] = Box(controller: controller, refCount: 1)
        return controller
    }

    /// Drops one reference. At zero, removes the box and (if `closeOnZero`)
    /// invokes `controller.close()`. No-op if `projectId` is not held.
    func release(projectId: UUID) {
        guard var box = boxes[projectId] else { return }
        box.refCount -= 1
        if box.refCount <= 0 {
            boxes.removeValue(forKey: projectId)
            if closeOnZero { box.controller.close() }
        } else {
            boxes[projectId] = box
        }
    }

    // MARK: Introspection (for the check / WorkspaceRuntime)
    var liveCount: Int { boxes.count }
    var liveProjectIds: Set<UUID> { Set(boxes.keys) }
    var liveControllers: [ZoneRuntimeController] { boxes.values.map(\.controller) }
    func refCount(for projectId: UUID) -> Int { boxes[projectId]?.refCount ?? 0 }
    func isLive(_ projectId: UUID) -> Bool { boxes[projectId] != nil }
    func controller(for projectId: UUID) -> ZoneRuntimeController? { boxes[projectId]?.controller }

    /// Register an already-built controller at refCount 1. Used by the boot
    /// convenience init so the boot controller is ref-counted consistently
    /// without going through the factory. No-op if projectId is already live.
    func register(_ controller: ZoneRuntimeController, for projectId: UUID) {
        guard boxes[projectId] == nil else { return }
        boxes[projectId] = Box(controller: controller, refCount: 1)
    }

    // MARK: Self-check
    static func runZoneRegistryRefcountSelfCheck() throws -> URL {
        enum CheckError: Error, CustomStringConvertible {
            case failed(String)
            var description: String {
                switch self { case let .failed(message): return message }
            }
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw CheckError.failed(message) }
        }

        let fileManager = FileManager.default
        let now = Date()

        // Fixed projectIds per spec
        let P = UUID(uuidString: "00000000-0000-0000-0000-000000000058")!
        let Q = UUID(uuidString: "00000000-0000-0000-0000-000000000059")!

        // Factory with makeCount tracking
        var makeCount: [UUID: Int] = [:]
        var tempDirs: [URL] = []

        func makeFactory() -> Factory {
            return { projectId in
                let tempRoot = fileManager.temporaryDirectory
                    .appendingPathComponent("continuum-zone-registry-\(projectId.uuidString)-\(UUID().uuidString)", isDirectory: true)
                try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
                tempDirs.append(tempRoot)
                let store = ProjectStore(projectRoot: tempRoot)
                let project = Project(
                    id: projectId,
                    name: "zone-registry-check-\(projectId.uuidString)",
                    rootPath: tempRoot.path,
                    createdAt: now,
                    updatedAt: now,
                    defaultLaunchProfileId: "shell",
                    editorPreference: .auto,
                    settings: ProjectSettings(
                        restorePolicy: .restoreDescriptors,
                        browserStoragePolicy: .perProject,
                        terminalClosePolicy: .askWhenRunning
                    )
                )
                makeCount[projectId, default: 0] += 1
                return ZoneRuntimeController(projectRoot: tempRoot, projectStore: store, project: project)
            }
        }

        defer {
            for dir in tempDirs {
                try? fileManager.removeItem(at: dir)
            }
        }

        let registry = ZoneRuntimeRegistry(closeOnZero: true, makeController: makeFactory())

        // 1. First acquire creates.
        let c1 = try registry.acquire(projectId: P)
        try expect(makeCount[P] == 1, "assertion 1: makeCount[P] == 1 after first acquire")
        try expect(registry.isLive(P), "assertion 1: isLive(P) == true after first acquire")
        try expect(registry.refCount(for: P) == 1, "assertion 1: refCount(P) == 1 after first acquire")
        try expect(registry.liveCount == 1, "assertion 1: liveCount == 1 after first acquire")

        // 2. Second acquire returns the SAME instance, does NOT create.
        let c2 = try registry.acquire(projectId: P)
        try expect(c2 === c1, "assertion 2: c2 === c1 (same instance — sharing guarantee)")
        try expect(makeCount[P] == 1, "assertion 2: makeCount[P] == 1 still (no second controller built)")
        try expect(registry.refCount(for: P) == 2, "assertion 2: refCount(P) == 2 after second acquire")
        try expect(registry.liveCount == 1, "assertion 2: liveCount == 1 (still one project)")

        // 3. Release once keeps it alive (ref-count 2 → 1).
        registry.release(projectId: P)
        try expect(registry.isLive(P), "assertion 3: isLive(P) == true after one release")
        try expect(registry.refCount(for: P) == 1, "assertion 3: refCount(P) == 1 after one release")
        try expect(registry.controller(for: P) === c1, "assertion 3: controller(P) === c1 (same instance)")
        // Controller is NOT closed — setTier throws .uiUnavailable (no UI attached), not .controllerClosed
        do {
            try c1.setTier(.snapshot)
            throw CheckError.failed("assertion 3: setTier should have thrown but did not")
        } catch ZoneRuntimeController.HydrationLifecycleError.uiUnavailable {
            // expected — controller is live, no UI attached
        } catch ZoneRuntimeController.HydrationLifecycleError.controllerClosed {
            throw CheckError.failed("assertion 3: controller should be live, not closed")
        }

        // 4. Release to zero closes and removes.
        registry.release(projectId: P)
        try expect(!registry.isLive(P), "assertion 4: isLive(P) == false after release to zero")
        try expect(registry.refCount(for: P) == 0, "assertion 4: refCount(P) == 0 after release to zero")
        try expect(registry.controller(for: P) == nil, "assertion 4: controller(P) == nil after release to zero")
        try expect(registry.liveCount == 0, "assertion 4: liveCount == 0 after release to zero")
        // close() was genuinely invoked: setTier now throws .controllerClosed
        do {
            try c1.setTier(.snapshot)
            throw CheckError.failed("assertion 4: setTier should have thrown .controllerClosed but did not")
        } catch ZoneRuntimeController.HydrationLifecycleError.controllerClosed {
            // expected — controller was genuinely closed
        }

        // 5. Acquire after zero builds a FRESH controller.
        let c3 = try registry.acquire(projectId: P)
        try expect(c3 !== c1, "assertion 5: c3 !== c1 (new instance after zero)")
        try expect(makeCount[P] == 2, "assertion 5: makeCount[P] == 2 (factory invoked second time)")
        try expect(registry.refCount(for: P) == 1, "assertion 5: refCount(P) == 1 after fresh acquire")
        try expect(registry.isLive(P), "assertion 5: isLive(P) == true after fresh acquire")

        // 6. Two projects are independent.
        let q1 = try registry.acquire(projectId: Q)
        try expect(q1 !== c3, "assertion 6: q1 !== c3 (different projects, different instances)")
        try expect(registry.liveCount == 2, "assertion 6: liveCount == 2 (P and Q both live)")
        try expect(registry.refCount(for: P) == 1, "assertion 6: refCount(P) == 1")
        try expect(registry.refCount(for: Q) == 1, "assertion 6: refCount(Q) == 1")
        try expect(makeCount[Q] == 1, "assertion 6: makeCount[Q] == 1")
        registry.release(projectId: Q)
        try expect(!registry.isLive(Q), "assertion 6: isLive(Q) == false after Q released")
        try expect(registry.isLive(P), "assertion 6: isLive(P) == true (releasing Q does not touch P)")
        try expect(registry.liveCount == 1, "assertion 6: liveCount == 1 after Q released")

        // 7. Over-release is a safe no-op.
        // P is at ref-count 1 — release to zero (closes), then release again (no-op).
        registry.release(projectId: P) // ref-count → 0, closes c3
        registry.release(projectId: P) // no-op — not in registry
        try expect(registry.refCount(for: P) == 0, "assertion 7: refCount(P) == 0 after over-release")
        try expect(!registry.isLive(P), "assertion 7: isLive(P) == false after over-release")
        try expect(registry.liveCount == 0, "assertion 7: liveCount == 0 after over-release")
        registry.release(projectId: Q) // Q not held — no crash
        try expect(registry.liveCount == 0, "assertion 7: liveCount == 0 after releasing unknown Q")

        // 8. closeOnZero == false keeps the controller warm (does NOT close it).
        var makeCount2: [UUID: Int] = [:]
        var tempDirs2: [URL] = []
        func makeFactory2() -> Factory {
            return { projectId in
                let tempRoot = fileManager.temporaryDirectory
                    .appendingPathComponent("continuum-zone-registry2-\(projectId.uuidString)-\(UUID().uuidString)", isDirectory: true)
                try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
                tempDirs2.append(tempRoot)
                let store = ProjectStore(projectRoot: tempRoot)
                let project = Project(
                    id: projectId,
                    name: "zone-registry2-check-\(projectId.uuidString)",
                    rootPath: tempRoot.path,
                    createdAt: now,
                    updatedAt: now,
                    defaultLaunchProfileId: "shell",
                    editorPreference: .auto,
                    settings: ProjectSettings(
                        restorePolicy: .restoreDescriptors,
                        browserStoragePolicy: .perProject,
                        terminalClosePolicy: .askWhenRunning
                    )
                )
                makeCount2[projectId, default: 0] += 1
                return ZoneRuntimeController(projectRoot: tempRoot, projectStore: store, project: project)
            }
        }
        defer {
            for dir in tempDirs2 {
                try? fileManager.removeItem(at: dir)
            }
        }

        let warm = ZoneRuntimeRegistry(closeOnZero: false, makeController: makeFactory2())
        let w1 = try warm.acquire(projectId: P)
        warm.release(projectId: P)
        // Box is dropped (re-acquire rebuilds), but controller was NOT closed
        try expect(!warm.isLive(P), "assertion 8: warm.isLive(P) == false (box dropped)")
        try expect(warm.refCount(for: P) == 0, "assertion 8: warm.refCount(P) == 0")
        // w1 was NOT closed — setTier throws .uiUnavailable, not .controllerClosed
        do {
            try w1.setTier(.snapshot)
            throw CheckError.failed("assertion 8: setTier should have thrown but did not")
        } catch ZoneRuntimeController.HydrationLifecycleError.uiUnavailable {
            // expected — controller is warm (not closed), just no UI
        } catch ZoneRuntimeController.HydrationLifecycleError.controllerClosed {
            throw CheckError.failed("assertion 8: controller should NOT be closed when closeOnZero == false")
        }

        // 9. Config default-resolution.
        let suiteName = "continuum-zone-runtime-closeonzero-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        // Key absent → default (true)
        try expect(
            ZoneRuntimeBudgetConfig.closeOnZero(defaults: suite) == ZoneRuntimeBudgetConfig.defaultCloseOnZero,
            "assertion 9: absent key returns defaultCloseOnZero"
        )
        try expect(
            ZoneRuntimeBudgetConfig.closeOnZero(defaults: suite) == true,
            "assertion 9: absent key returns true"
        )
        // Explicit false → false
        suite.set(false, forKey: ZoneRuntimeBudgetConfig.closeOnZeroKey)
        try expect(
            ZoneRuntimeBudgetConfig.closeOnZero(defaults: suite) == false,
            "assertion 9: explicit false returns false"
        )
        // Explicit true → true
        suite.set(true, forKey: ZoneRuntimeBudgetConfig.closeOnZeroKey)
        try expect(
            ZoneRuntimeBudgetConfig.closeOnZero(defaults: suite) == true,
            "assertion 9: explicit true returns true"
        )

        // 10. Release to zero is detach-only by construction.
        //
        // ZoneRuntimeController has no tmux dependency to call through: no TmuxControl,
        // no Process, no TmuxSession reference. This assertion proves release reaches
        // close() (the closed guard fires) and records the no-kill property as a
        // structural invariant rather than pretending there is a command log here.
        let releaseRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: makeFactory())
        let releaseController = try releaseRegistry.acquire(projectId: P)
        releaseRegistry.release(projectId: P)
        try expect(!releaseRegistry.isLive(P), "assertion 10: release to zero removed the box")
        do {
            try releaseController.setTier(.snapshot)
            throw CheckError.failed("assertion 10: setTier should have thrown .controllerClosed")
        } catch ZoneRuntimeController.HydrationLifecycleError.controllerClosed {
            // expected - close() ran through ZoneRuntimeController's detach-only body
        }
        let releaseReachedNoKill = true

        // 11. Multi-workspace release keeps the controller live until the final release.
        let multiRegistry = ZoneRuntimeRegistry(closeOnZero: true, makeController: makeFactory())
        let multiController = try multiRegistry.acquire(projectId: P)
        _ = try multiRegistry.acquire(projectId: P)
        multiRegistry.release(projectId: P)
        try expect(multiRegistry.isLive(P), "assertion 11a: first release keeps project live")
        try expect(multiRegistry.refCount(for: P) == 1, "assertion 11a: refCount(P) == 1 after first release")
        do {
            try multiController.setTier(.snapshot)
            throw CheckError.failed("assertion 11a: live controller should have thrown .uiUnavailable")
        } catch ZoneRuntimeController.HydrationLifecycleError.uiUnavailable {
            // expected - live, detached from UI, not closed
        } catch ZoneRuntimeController.HydrationLifecycleError.controllerClosed {
            throw CheckError.failed("assertion 11a: controller closed before final release")
        }
        multiRegistry.release(projectId: P)
        try expect(!multiRegistry.isLive(P), "assertion 11b: second release closed and removed")
        do {
            try multiController.setTier(.snapshot)
            throw CheckError.failed("assertion 11b: setTier should have thrown .controllerClosed")
        } catch ZoneRuntimeController.HydrationLifecycleError.controllerClosed {
            // expected - close() ran only after the final release
        }
        let multiReleaseReachedNoKill = true

        // Write manifest artifact
        let manifest: [String: Any] = [
            "check": "zone-registry-refcount",
            "assertions": 11,
            "closeOnZeroPolicy": "option-a-drop-box-skip-close",
            "releaseReachedNoKill": releaseReachedNoKill,
            "multiReleaseReachedNoKill": multiReleaseReachedNoKill,
            "controllerHasNoTmuxDependency": true
        ]
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("qa-runs", isDirectory: true)
            .appendingPathComponent(timestamp, isDirectory: true)
            .appendingPathComponent("zone-registry-refcount", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestURL, options: .atomic)
        return manifestURL
    }
}
