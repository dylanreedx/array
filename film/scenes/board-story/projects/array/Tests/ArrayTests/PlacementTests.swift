import XCTest
@testable import Array

final class PlacementTests: XCTestCase {
    func testSpawnIntoUnarmedZoneLandsInsideIt() {
        let canvas = CanvasFixture.twoZones()
        canvas.arm(canvas.zoneA)
        let tile = canvas.spawn(.terminal, scope: .zone(canvas.zoneB))
        XCTAssertTrue(canvas.zoneB.worldRect.contains(tile.worldFrame))
    }
}
