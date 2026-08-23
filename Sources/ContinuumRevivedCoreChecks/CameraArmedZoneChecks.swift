import CoreGraphics
import ContinuumRevivedCore
import Foundation

/// T2 (`.plans/47`) — `CanvasEngine.cameraArmedZone`.
///
/// The camera is one of four things that decide which zone new tiles land in, and
/// it is the only one that fires without the user touching anything. Two
/// properties carry the whole design: a `nil` answer means "leave the arming
/// alone", never "disarm"; and a zone with no project must never win, because
/// arming one makes `activeController` nil and disarms creation entirely.
func runCameraArmedZoneChecks() {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    let projectOne = UUID()
    let projectTwo = UUID()
    let zoneOne = UUID()
    let zoneTwo = UUID()
    let zoneGroup = UUID()

    func zone(
        _ id: UUID,
        project: UUID?,
        x: Double,
        y: Double,
        w: Double = 1000,
        h: Double = 800
    ) -> ZonePlacement {
        ZonePlacement(
            zoneId: id, projectId: project,
            origin: ZonePoint(x: x, y: y), size: ZoneSize(width: w, height: h),
            color: "blue", collapsed: false, hydrationPolicy: .automatic
        )
    }

    // A 800x600 viewport at zoom 1 has its centre 400,300 past its origin.
    let visible = CGSize(width: 800, height: 600)
    func viewportCentred(on point: CGPoint, zoom: Double = 1) -> CanvasViewport {
        CanvasViewport(
            x: point.x - (Double(visible.width) / zoom) / 2,
            y: point.y - (Double(visible.height) / zoom) / 2,
            zoom: zoom
        )
    }

    let one = zone(zoneOne, project: projectOne, x: 0, y: 0)
    let two = zone(zoneTwo, project: projectTwo, x: 4000, y: 0)
    let group = zone(zoneGroup, project: nil, x: 8000, y: 0)

    // 1. The centre inside a zone arms it.
    expect(CanvasEngine.cameraArmedZone(
        zones: [one, two, group],
        viewport: viewportCentred(on: CGPoint(x: 500, y: 400)),
        visibleSize: visible) == zoneOne,
        "a viewport centred inside zone one must arm zone one")
    expect(CanvasEngine.cameraArmedZone(
        zones: [one, two, group],
        viewport: viewportCentred(on: CGPoint(x: 4500, y: 400)),
        visibleSize: visible) == zoneTwo,
        "a viewport centred inside zone two must arm zone two")

    // 2. The centre outside every zone answers nil — which the caller reads as
    //    "no change". Panning across the gap between two zones must not strand
    //    creation with no target at all.
    expect(CanvasEngine.cameraArmedZone(
        zones: [one, two, group],
        viewport: viewportCentred(on: CGPoint(x: 2500, y: 400)),
        visibleSize: visible) == nil,
        "empty canvas between zones must answer nil, not the nearest zone — 'nearest' "
        + "would arm a zone thousands of points off screen the moment the camera "
        + "crossed open canvas")

    // 3. A group zone never wins, even dead centre. `activeController` is nil for
    //    a project-less zone, so arming one turns every spawn into a refusal.
    expect(CanvasEngine.cameraArmedZone(
        zones: [one, two, group],
        viewport: viewportCentred(on: CGPoint(x: 8500, y: 400)),
        visibleSize: visible) == nil,
        "a group zone under the camera must not arm")

    // 4. Overlapping zones resolve by z-order: the input is expected in
    //    `zonesInZOrder`, last element frontmost, exactly as hit-testing reads it.
    let lower = zone(UUID(), project: projectOne, x: 0, y: 0, w: 2000, h: 2000)
    let upper = zone(UUID(), project: projectTwo, x: 100, y: 100, w: 500, h: 500)
    expect(CanvasEngine.cameraArmedZone(
        zones: [lower, upper],
        viewport: viewportCentred(on: CGPoint(x: 300, y: 300)),
        visibleSize: visible) == upper.zoneId,
        "the frontmost containing zone must win, matching zoneId(at:)")
    expect(CanvasEngine.cameraArmedZone(
        zones: [upper, lower],
        viewport: viewportCentred(on: CGPoint(x: 300, y: 300)),
        visibleSize: visible) == lower.zoneId,
        "reversing the z-order must reverse the answer — this function reads order, "
        + "it does not re-derive it")

    // 5. Zoom changes where the centre is, so it changes the answer.
    expect(CanvasEngine.cameraArmedZone(
        zones: [one, two],
        viewport: viewportCentred(on: CGPoint(x: 4500, y: 400), zoom: 0.25),
        visibleSize: visible) == zoneTwo,
        "the centre must be computed in WORLD units — dividing the visible size by "
        + "zoom is what makes a zoomed-out camera still point somewhere real")

    // 6. Degenerate inputs answer nil rather than trapping.
    expect(CanvasEngine.cameraArmedZone(
        zones: [], viewport: viewportCentred(on: .zero), visibleSize: visible) == nil,
        "no zones must answer nil")
    expect(CanvasEngine.cameraArmedZone(
        zones: [one],
        viewport: CanvasViewport(x: 0, y: 0, zoom: 0),
        visibleSize: visible) != nil,
        "a zero zoom must be clamped rather than producing a NaN centre")

    // 7. The boundary is inclusive on both edges, so a zone's own corner counts as
    //    inside it and two abutting zones cannot both refuse the point between them.
    expect(CanvasEngine.cameraArmedZone(
        zones: [one],
        viewport: viewportCentred(on: CGPoint(x: 1000, y: 800)),
        visibleSize: visible) == zoneOne,
        "the far corner of a zone must still be inside it")

    print("CameraArmedZoneChecks passed")
}
