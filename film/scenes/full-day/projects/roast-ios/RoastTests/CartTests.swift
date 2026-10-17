import XCTest
@testable import Roast

final class CartTests: XCTestCase {
    func testTotalRoundsOnce() {
        let cart = Cart(lines: [.init(name: "Autumn blend", price: 18), .init(name: "Autumn blend", price: 18)], discount: 0.10)
        XCTAssertEqual(cart.total, 32.40)
    }
}
