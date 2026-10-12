import ContinuumRevivedCore
import Foundation

/// An unreadable canvas is not an absent one. Absent loads as nil (empty); a
/// `canvas.json` that exists and decodes nowhere (an unknown tile kind, say)
/// throws, and `saveCanvas` refuses to write over it. Its own arm because the
/// bare CoreChecks run is KNOWN-RED and a witness inside it would go unreported.
func runUnreadableCanvasStoreChecks() {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("array-unreadable-canvas-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let canvas = CanvasState(viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil)
    do {
        let unreadableRoot = scratch.appendingPathComponent("unreadable-canvas", isDirectory: true)
        let unreadableStore = ProjectStore(projectRoot: unreadableRoot)
        try FileManager.default.createDirectory(at: unreadableStore.layout.stateRoot, withIntermediateDirectories: true)
        do {
            let absent = try unreadableStore.tryLoadCanvas()
            expect(absent == nil, "tryLoadCanvas: a missing canvas.json loads as nil")
        } catch {
            expect(false, "tryLoadCanvas: a missing canvas.json must not throw, got \(error)")
        }
        let unreadable = Data(#"{"schemaVersion":1,"viewport":{"x":0,"y":0,"zoom":1},"tiles":[{"id":"6A000000-0000-0000-0000-000000000001","kind":"futureKind","title":"t","frame":{"x":0,"y":0,"width":10,"height":10},"zIndex":1,"runtimeRef":null,"metadata":{}}],"groups":[],"lastActiveTileId":null}"#.utf8)
        try unreadable.write(to: unreadableStore.layout.canvasFile)
        do {
            _ = try unreadableStore.tryLoadCanvas()
            expect(false, "tryLoadCanvas: an undecodable canvas.json must throw, not read as empty")
        } catch ProjectStoreError.canvasUnreadable {
        } catch {
            expect(false, "tryLoadCanvas: an undecodable canvas.json must throw canvasUnreadable, got \(error)")
        }
        do {
            try unreadableStore.saveCanvas(canvas)
            expect(false, "saveCanvas: must refuse to write over an undecodable canvas.json")
        } catch ProjectStoreError.canvasUnreadable {
        } catch {
            expect(false, "saveCanvas over an undecodable canvas.json must throw canvasUnreadable, got \(error)")
        }
        expect((try? Data(contentsOf: unreadableStore.layout.canvasFile)) == unreadable,
               "saveCanvas: the undecodable canvas.json must stay byte-identical")
    } catch {
        expect(false, "unreadable canvas store checks could not set up: \(error)")
    }
}
