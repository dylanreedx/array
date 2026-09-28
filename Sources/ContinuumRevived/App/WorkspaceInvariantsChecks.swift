import AppKit
import ContinuumRevivedCore
import Foundation

/// `--workspace-invariants-check`: proves the workspace invariants fixture
/// (`WorkspaceInvariantsFixture`) before any later witness is allowed to trust it.
///
/// A harness that cannot fail proves nothing, so this leg is mostly negative
/// controls. It passes only when:
///
///  1. the `StoreFileWriter` seam fails, drops and passes writes exactly as
///     asked, measured in bytes on disk;
///  2. a clean control — mount, switch away and back, quit and remount, crash
///     and remount — reports ZERO violations, so the controls below cannot be
///     firing on noise; and
///  3. each injected defect is caught by the invariant it belongs to, naming
///     the injected subject: a 1pt WORLD shift (geometry), a foreign zone in a
///     workspace file (isolation), a ghost layer on the canvas (wholeness), and
///     a save acknowledged while the write never landed (durability).
@MainActor
enum WorkspaceInvariantsChecks {
    typealias Fixture = WorkspaceInvariantsFixture

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !condition() { throw Failure(message: message()) }
    }

    /// The pass line's caveat, printed as a `MATRIX-NOTE` so the matrix report
    /// shows it: projection is excluded from the clean control until the
    /// derived-headers slice lands.
    private(set) static var matrixNote = ""

    static func run() throws -> URL {
        var manifest: [String: Any] = [:]
        manifest["seam"] = try runSeamControls()
        let clean = try runCleanControl()
        manifest["clean"] = clean
        let openZones = Set((clean["steps"] as? [[String: Any]] ?? [])
            .flatMap { $0["openFindings"] as? [String] ?? [] }
            .compactMap { $0.components(separatedBy: ": ").first })
        matrixNote = openZones.isEmpty
            ? "projection excluded from the clean control but saw no open finding; re-enable it"
            : "PROJECTION EXCLUDED from the clean control, 1 open finding: after mount the zone header "
              + "draws no Home label (\(openZones.count) zone(s)); the derived-headers slice re-enables it here"
        manifest["shift"] = try runShiftControl()
        manifest["foreignZone"] = try runForeignZoneControl()
        manifest["ghostLayer"] = try runGhostLayerControl()
        manifest["staleReceipt"] = try runStaleReceiptControl()

        let timestamp = Int(Date().timeIntervalSince1970)
        let dir = URL(fileURLWithPath: "qa-runs/\(timestamp)/workspace-invariants", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let artifact = dir.appendingPathComponent("manifest.json", isDirectory: false)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: artifact, options: .atomic)
        return artifact
    }

    // MARK: - 1. The fault seam, in bytes

    private static func runSeamControls() throws -> [String: Any] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuum-store-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            StoreFileWriter.uninstall()
            try? FileManager.default.removeItem(at: root)
        }
        let store = ProjectStore(projectRoot: root)
        let file = store.layout.canvasFile
        func canvas(_ x: Double) -> CanvasState {
            CanvasState(viewport: CanvasViewport(x: x, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil)
        }
        func viewportX() -> Double? {
            guard let bytes = try? Data(contentsOf: file) else { return nil }
            return (try? JSONCodec.makeCanvasDecoder().decode(CanvasState.self, from: bytes))?.viewport.x
        }

        // failWrite(2): the second write alone throws and leaves the first on disk.
        StoreFileWriter.install(.init(fault: .failWrite(2), scope: root))
        try store.saveCanvas(canvas(1))
        var secondThrew = false
        do { try store.saveCanvas(canvas(2)) } catch is StoreFileWriter.InjectedFailure { secondThrew = true }
        try expect(secondThrew, "seam: failWrite(2) must throw on the second write")
        try expect(viewportX() == 1, "seam: a failed write must leave the previous bytes; disk has \(String(describing: viewportX()))")
        try store.saveCanvas(canvas(3))
        try expect(viewportX() == 3, "seam: writes after the failed one must land")
        let failTrace = StoreFileWriter.uninstall().map(\.outcome)
        try expect(failTrace == [.landed, .failed, .landed], "seam: failWrite trace \(failTrace)")

        // failFrom(1): nothing lands.
        try? FileManager.default.removeItem(at: file)
        StoreFileWriter.install(.init(fault: .failFrom(1), scope: root))
        var everyWriteThrew = true
        for x in [4.0, 5.0] {
            do { try store.saveCanvas(canvas(x)); everyWriteThrew = false } catch is StoreFileWriter.InjectedFailure {}
        }
        try expect(everyWriteThrew && viewportX() == nil, "seam: failFrom(1) must fail every write and write nothing")
        StoreFileWriter.uninstall()

        // abortAfter(1): the first lands, the second reports success and never lands.
        StoreFileWriter.install(.init(fault: .abortAfter(1), scope: root))
        try store.saveCanvas(canvas(6))
        try store.saveCanvas(canvas(7))
        try expect(viewportX() == 6, "seam: abortAfter(1) must drop the second write; disk has \(String(describing: viewportX()))")
        let abortTrace = StoreFileWriter.uninstall().map(\.outcome)
        try expect(abortTrace == [.landed, .dropped], "seam: abortAfter trace \(abortTrace)")

        // Out of scope: an unscoped path is never counted or faulted.
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuum-store-writer-elsewhere-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        StoreFileWriter.install(.init(fault: .failFrom(1), scope: root))
        try ProjectStore(projectRoot: elsewhere).saveCanvas(canvas(8))
        try expect(StoreFileWriter.uninstall().isEmpty, "seam: a write outside the scope must not be traced")

        return ["failWrite": failTrace.map(\.rawValue), "abortAfter": abortTrace.map(\.rawValue)]
    }

    // MARK: - 2. The clean control

    /// Projection is not asserted by the clean control: at `1451c030` every
    /// header loses its Home label once the runtime mounts the scene (both
    /// runtime render-model builders omit `scopeLabel`, and the rollup tick
    /// writes that copy back). That is a real defect — complaint 2 — owned by
    /// the derived-headers slice, whose witness asserts it. It is recorded here
    /// as an open finding so the manifest shows what the fixture sees.
    static let cleanInvariants = Set(Fixture.Invariant.allCases).subtracting([.projection])

    private static func checkClean(_ fixture: Fixture, _ step: String, into steps: inout [[String: Any]]) throws {
        let violations = try fixture.allViolations(invariants: cleanInvariants)
        let openFindings = try fixture.allViolations(invariants: [.projection])
        steps.append(["step": step, "violations": violations.map(\.description),
                      "openFindings": openFindings.map(\.description)])
        try expect(violations.isEmpty, "clean control, after \(step): \(violations.map(\.description))")
    }

    private static func runCleanControl() throws -> [String: Any] {
        let fixture = try Fixture(label: "clean")
        defer { fixture.dispose() }
        var steps: [[String: Any]] = []
        StoreFileWriter.install(.init(fault: .none, scope: fixture.root))

        try fixture.mount()
        try checkClean(fixture, "mount A", into: &steps)
        // The chrome view must be reading real drawing, not an empty default:
        // the titles are what the headers drew, and the named zone's differs
        // from the derived one.
        let chrome = try fixture.chromeView()
        try expect(chrome[Fixture.zoneA1]?.first == "Roots" && chrome[Fixture.zoneA2]?.first == "Birch",
                   "clean control: chrome drew \(chrome)")

        try fixture.switchTo(Fixture.workspaceB)
        try checkClean(fixture, "switch to B", into: &steps)
        try fixture.switchTo(Fixture.workspaceA)
        try checkClean(fixture, "switch back to A", into: &steps)
        let writesBeforeQuit = StoreFileWriter.trace.count
        try fixture.remount(crash: false)
        try checkClean(fixture, "quit and remount", into: &steps)
        try fixture.remount(crash: true)
        try checkClean(fixture, "crash and remount", into: &steps)
        try expect(fixture.receipts.contains { $0.truthful },
                   "clean control: the oracle saw no acknowledgement at all, so it proves nothing")
        return ["steps": steps, "writesBeforeQuit": writesBeforeQuit,
                "receipts": fixture.receipts.count, "actions": fixture.actionLog]
    }

    // MARK: - 3. Negative controls

    /// A defect is caught when the invariant it belongs to names its subject.
    private static func expectCaught(
        _ violations: [Fixture.Violation], _ invariant: Fixture.Invariant, subject: String, _ control: String
    ) throws -> [String: Any] {
        let hits = violations.filter { $0.invariant == invariant && $0.subject.contains(subject) }
        try expect(!hits.isEmpty,
                   "\(control): the injected defect was NOT caught by [\(invariant.rawValue)]; saw \(violations.map(\.description))")
        return ["caught": hits.map(\.description), "all": violations.map(\.description)]
    }

    /// A writer drifted one tile by one point in its project file.
    private static func runShiftControl() throws -> [String: Any] {
        let fixture = try Fixture(label: "shift")
        defer { fixture.dispose() }
        try fixture.mount()
        try fixture.quit()
        let store = ProjectStore(projectRoot: fixture.projectRoots[Fixture.projectA1]!)
        var canvas = try store.loadCanvas()
        let index = try canvas.tiles.firstIndex { $0.id == Fixture.noteA1b }
            .orThrow(Failure(message: "shift: seeded tile missing"))
        canvas.tiles[index].frame.x += 1
        try store.saveCanvas(canvas)
        try fixture.mount()
        let violations = try fixture.allViolations()
        let result = try expectCaught(violations, .geometry, subject: Fixture.noteA1b.uuidString, "shift")
        try expect(violations.filter { $0.invariant == .geometry }.count == 1,
                   "shift: only the shifted tile may be reported; saw \(violations)")
        return result
    }

    /// Workspace B's file gained a zone workspace A owns — the prod audit's shape.
    private static func runForeignZoneControl() throws -> [String: Any] {
        let fixture = try Fixture(label: "foreign")
        defer { fixture.dispose() }
        try fixture.mount()
        let storeB = WorkspaceStore(workspaceId: Fixture.workspaceB, applicationSupportDirectory: fixture.appSupport)
        var documentB = try storeB.load()
        documentB.zones.append(Fixture.seed.zones[Fixture.zoneA2]!)
        try storeB.save(documentB)
        return try expectCaught(try fixture.allViolations(), .isolation, subject: Fixture.zoneA2.uuidString, "foreign zone")
    }

    /// A layer is installed for a zone the mounted document does not contain.
    private static func runGhostLayerControl() throws -> [String: Any] {
        let fixture = try Fixture(label: "ghost")
        defer { fixture.dispose() }
        try fixture.mount()
        let m = try fixture.requireMounted("ghost")
        let ghostId = UUID()
        let placement = ZonePlacement(
            zoneId: ghostId, projectId: Fixture.projectA1,
            origin: ZonePoint(x: 5000, y: 5000), size: ZoneSize(width: 400, height: 300),
            color: "gray", collapsed: false, hydrationPolicy: .automatic)
        m.canvas.upsertZoneLayer(CanvasNSView.ZoneLayer(
            placement: placement,
            renderModel: CanvasNSView.ZoneRenderModel(placement: placement, displayName: "ghost")))
        return try expectCaught(try fixture.allViolations(), .wholeness, subject: ghostId.uuidString, "ghost layer")
    }

    /// The workspace write is silently dropped; the save still acknowledges.
    private static func runStaleReceiptControl() throws -> [String: Any] {
        let fixture = try Fixture(label: "receipt")
        defer { fixture.dispose() }
        try fixture.mount()
        fixture.resetReceipts()
        let workspaceDirectory = WorkspaceStoreLayout(
            applicationSupportDirectory: fixture.appSupport, workspaceId: Fixture.workspaceA).workspaceDirectory
        StoreFileWriter.install(.init(fault: .abortAfter(0), scope: workspaceDirectory))
        try fixture.rename(Fixture.zoneA1, to: "Renamed while the disk was gone")
        let trace = StoreFileWriter.uninstall()
        try expect(trace.contains { $0.outcome == .dropped },
                   "stale receipt: the rename made no workspace write to drop; trace \(trace)")
        var result = try expectCaught(fixture.durabilityViolations(), .durability,
                                      subject: Fixture.workspaceA.uuidString, "stale receipt")
        result["trace"] = trace.map(\.description)
        return result
    }
}

private extension Optional {
    func orThrow(_ error: Error) throws -> Wrapped {
        guard let value = self else { throw error }
        return value
    }
}
