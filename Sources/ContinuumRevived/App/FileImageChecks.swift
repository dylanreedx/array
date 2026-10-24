import AppKit
import ImageIO
import UniformTypeIdentifiers
import ContinuumRevivedCore

@MainActor
enum FileImageChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func run() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("array-image-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
            if !value() { throw Failure(description: message) }
        }
        // Independent source pixels: top/bottom and alpha are intentional; no
        // fixture depends on a screenshot or whatever ImageIO returns at runtime.
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 0,
                               0, 0, 255, 255, 255, 255, 255, 128,
                               255, 255, 0, 255, 0, 255, 255, 255]
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let source = CGImage(width: 2, height: 3, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw Failure(description: "could not create independent image fixture")
        }
        func write(_ name: String, type: UTType, orientation: Int) throws -> URL {
            let url = root.appendingPathComponent(name)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
                throw Failure(description: "fixture encoder missing")
            }
            CGImageDestinationAddImage(destination, source,
                [kCGImagePropertyOrientation: orientation] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw Failure(description: "fixture encode failed") }
            return url
        }
        let png = try write("alpha.png", type: .png, orientation: 1)
        let snapshot = try SecureFileSnapshot.capture(path: png.path, maxBytes: FileImageBackend.compressedByteLimit)
        let document = try FileImageBackend.load(snapshot: snapshot)
        try expect(document.pixelWidth == 2 && document.pixelHeight == 3, "PNG dimensions must match source")
        try expect(document.image.alphaInfo != .none && document.image.alphaInfo != .noneSkipLast && document.image.alphaInfo != .noneSkipFirst,
                   "PNG preview must retain alpha")
        try expect(document.decodedBytes <= FileImageBackend.decodedByteLimit, "decoded pixels exceed bound")
        let rotated = try write("rotated.tiff", type: .tiff, orientation: 6)
        let rotatedDocument = try FileImageBackend.load(snapshot: .capture(path: rotated.path, maxBytes: FileImageBackend.compressedByteLimit))
        try expect(rotatedDocument.pixelWidth == 3 && rotatedDocument.pixelHeight == 2,
                   "EXIF rotation must swap source dimensions")
        try expect(rotatedDocument.image.width == 3 && rotatedDocument.image.height == 2,
                   "decoded thumbnail must apply orientation")
        let gif = root.appendingPathComponent("animated.gif")
        guard let frames = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 2, nil) else {
            throw Failure(description: "GIF fixture encoder missing")
        }
        CGImageDestinationAddImage(frames, source, nil)
        CGImageDestinationAddImage(frames, source, nil)
        guard CGImageDestinationFinalize(frames) else { throw Failure(description: "GIF fixture encode failed") }
        let animated = try FileImageBackend.load(snapshot: .capture(path: gif.path, maxBytes: FileImageBackend.compressedByteLimit))
        try expect(animated.pageCount == 2 && animated.isAnimated && animated.statusText.contains("animation paused"),
                   "animated images must disclose the static first-frame preview")
        let renderer = FileImageRenderer(document: document)
        renderer.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        renderer.layoutSubtreeIfNeeded()
        let viewport = renderer.qaViewport
        try expect(viewport.imageRect.width > 0 && viewport.imageRect.height > 0, "fit must produce visible geometry")
        let backing = NSScreen.main?.backingScaleFactor ?? 1
        viewport.setActualPixels()
        try expect(abs(viewport.displayScale - 1 / max(1, backing)) < 0.0001,
                   "actual size must be one decoded pixel per physical pixel")
        viewport.zoom(by: 2)
        try expect(abs(viewport.displayScale - 2 / max(1, backing)) < 0.0001, "zoom must update geometry")
        let retainedImage = document.image
        for index in 0..<100 {
            renderer.frame.size.width = CGFloat(640 + index)
            renderer.layoutSubtreeIfNeeded()
        }
        try expect(viewport.document?.image === retainedImage, "resize must reuse decoded pixels")
        try expect(viewport.subviews.isEmpty, "image viewport must use one surface")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            renderer.appearance = NSAppearance(named: appearance)
            renderer.applyTheme()
            guard let bitmap = renderer.bitmapImageRepForCachingDisplay(in: renderer.bounds) else {
                throw Failure(description: "renderer bitmap unavailable")
            }
            renderer.cacheDisplay(in: renderer.bounds, to: bitmap)
            try expect(bitmap.pixelsWide > 0, "appearance render must produce pixels")
        }
        renderer.dispose()
        try expect(viewport.document == nil, "disposal must release decoded document")
        let bad = root.appendingPathComponent("bad.png")
        try Data([0, 1, 2]).write(to: bad)
        do {
            _ = try FileImageBackend.load(snapshot: .capture(path: bad.path, maxBytes: 100))
            throw Failure(description: "corrupt image must fail")
        } catch is FileImageBackend.LoadError { }
        print("file-image-check: PASS (orientation, alpha, bounds, Retina geometry, reuse, appearances, disposal)")
    }
}
