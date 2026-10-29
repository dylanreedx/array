import Foundation
import CoreGraphics
import ImageIO

/// Exercises actual upright pixels against coordinate targeting, never a source
/// string or a second copy of the rotation formula. No simulator/user state.
enum IOSPreviewObservationChecks {
    private struct CheckFailure: Error { let message: String }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw CheckFailure(message: message) }
    }
    private static func rejected(_ body: () throws -> Void) throws {
        do { try body() } catch is IOSPreviewObservation.Failure { return }
        throw CheckFailure(message: "invalid image was accepted")
    }
    static func run() throws {
        // Six different opaque pixels, row-major from top left.
        let pixels: [UInt8] = [255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,0,255, 255,0,255,255, 0,255,255,255]
        let image = CGImage(width: 2, height: 3, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let expected = [1: [0,1,2,3,4,5], 2: [5,4,3,2,1,0], 3: [1,3,5,0,2,4], 4: [4,2,0,5,3,1]]
        for orientation in 1...4 {
            let upright = try IOSPreviewImageGeometry.upright(image, orientation: orientation)
            let output = upright.dataProvider!.data! as Data
            for y in 0..<upright.height {
                for x in 0..<upright.width {
                    let original = expected[orientation]![y * upright.width + x]
                    let actual = Array(output[(y * upright.bytesPerRow + x * 4)..<(y * upright.bytesPerRow + x * 4 + 4)])
                    try expect(actual == Array(pixels[(original * 4)..<(original * 4 + 4)]), "wrong upright pixel at \(x),\(y), orientation \(orientation)")
                    let raw = IOSPreviewImageGeometry.rawPoint(x: (Double(x) + 0.5) / Double(upright.width),
                        y: (Double(y) + 0.5) / Double(upright.height), orientation: orientation)!
                    try expect(Int(raw.y * 3) * 2 + Int(raw.x * 2) == original, "image and HID transform disagree")
                }
            }
        }
        for value in [-0.1, 1.1, Double.nan, .infinity] {
            try expect(IOSPreviewImageGeometry.rawPoint(x: value, y: 0.5, orientation: 1) == nil, "bad x coordinate accepted")
            try expect(IOSPreviewImageGeometry.rawPoint(x: 0.5, y: value, orientation: 1) == nil, "bad y coordinate accepted")
        }
        try expect(IOSPreviewImageGeometry.rawPoint(x: 0, y: 1, orientation: 0) == nil, "invalid orientation accepted")
        let bytes = NSMutableData()
        let destination = CGImageDestinationCreateWithData(bytes, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        try expect(CGImageDestinationFinalize(destination), "fixture JPEG encoding failed")
        let data = bytes as Data
        let url = URL(string: "http://127.0.0.1/fresh.jpg")!
        let now = Date()
        var headers = ["Content-Type": "image/jpeg", "X-Array-Orientation": "3", "X-Array-Geometry-Generation": "2",
            "X-Array-Frame-Sequence": "12", "X-Array-Emission-Time-Ms": "1700000000000"]
        func response(_ status: Int = 200) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        let observation = try IOSPreviewObservation.decode(data, response: response(), receivedAt: now)
        try expect(observation.image.width == 3 && observation.image.height == 2 && observation.orientation == 3 &&
            observation.geometryGeneration == 2 && observation.sequence == 12, "decoded observation lost geometry")
        try expect(observation.helperEmittedAt.timeIntervalSince1970 == 1_700_000_000 && observation.hostReceivedAt == now,
            "emission and receive timestamps must remain distinct")
        try rejected { _ = try IOSPreviewObservation.decode(data, response: response(504), receivedAt: now) }
        try rejected { _ = try IOSPreviewObservation.decode(Data(), response: response(), receivedAt: now) }
        try rejected { _ = try IOSPreviewObservation.decode(Data(repeating: 0, count: IOSPreviewObservation.maximumBytes + 1), response: response(), receivedAt: now) }
        headers.removeValue(forKey: "X-Array-Frame-Sequence")
        try rejected { _ = try IOSPreviewObservation.decode(data, response: response(), receivedAt: now) }
        print("IOSPreviewObservationChecks passed: upright pixels and shared HID transform for all orientations; finite bounds, bounded JPEG, HTTP and metadata validation, distinct timestamps")
    }
}
