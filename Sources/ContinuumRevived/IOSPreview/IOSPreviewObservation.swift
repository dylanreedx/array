import Foundation
import CoreGraphics
import ImageIO

/// Upright screenshot coordinates are independent of the canvas and backing scale.
/// Used by the human surface too, so automation cannot drift from its orientation.
enum IOSPreviewImageGeometry {
    static func rawPoint(x: Double, y: Double, orientation: Int) -> CGPoint? {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
        switch orientation {
        case 1: return CGPoint(x: x, y: y)
        case 2: return CGPoint(x: 1 - x, y: 1 - y)
        case 3: return CGPoint(x: 1 - y, y: x)
        case 4: return CGPoint(x: y, y: 1 - x)
        default: return nil
        }
    }
    static func upright(_ raw: CGImage, orientation: Int) throws -> CGImage {
        guard (1...4).contains(orientation) else { throw IOSPreviewObservation.Failure.invalidFrame }
        if orientation == 1 { return raw }
        let rotated = orientation == 3 || orientation == 4
        let width = rotated ? raw.height : raw.width, height = rotated ? raw.width : raw.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw IOSPreviewObservation.Failure.invalidFrame
        }
        switch orientation {
        case 2: context.translateBy(x: CGFloat(width), y: CGFloat(height)); context.rotate(by: .pi)
        case 3: context.translateBy(x: CGFloat(width), y: 0); context.rotate(by: .pi / 2)
        case 4: context.translateBy(x: 0, y: CGFloat(height)); context.rotate(by: -.pi / 2)
        default: break
        }
        context.interpolationQuality = .none
        context.draw(raw, in: CGRect(x: 0, y: 0, width: raw.width, height: raw.height))
        guard let image = context.makeImage() else { throw IOSPreviewObservation.Failure.invalidFrame }
        return image
    }
}

/// One bounded fresh result. A later host-issued handle must additionally bind
/// principal, checkout, device, connection and human-control generations.
struct IOSPreviewObservation: @unchecked Sendable {
    enum Failure: Error { case unavailable, busy, invalidFrame }
    let image: CGImage
    let orientation: Int
    let geometryGeneration: Int
    let sequence: Int
    let helperEmittedAt: Date
    let hostReceivedAt: Date

    static let maximumBytes = 4 * 1024 * 1024
    static func decode(_ data: Data, response: URLResponse, receivedAt: Date) throws -> Self {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType == "image/jpeg", !data.isEmpty, data.count <= maximumBytes,
              let orientation = http.value(forHTTPHeaderField: "X-Array-Orientation").flatMap(Int.init),
              (1...4).contains(orientation),
              let geometry = http.value(forHTTPHeaderField: "X-Array-Geometry-Generation").flatMap(Int.init), geometry > 0,
              let sequence = http.value(forHTTPHeaderField: "X-Array-Frame-Sequence").flatMap(Int.init), sequence > 0,
              let milliseconds = http.value(forHTTPHeaderField: "X-Array-Emission-Time-Ms").flatMap(Double.init),
              milliseconds.isFinite, milliseconds > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096, width <= 4_000_000 / height,
              let raw = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw Failure.invalidFrame }
        return Self(image: try IOSPreviewImageGeometry.upright(raw, orientation: orientation), orientation: orientation,
            geometryGeneration: geometry, sequence: sequence,
            helperEmittedAt: Date(timeIntervalSince1970: milliseconds / 1000), hostReceivedAt: receivedAt)
    }
}
