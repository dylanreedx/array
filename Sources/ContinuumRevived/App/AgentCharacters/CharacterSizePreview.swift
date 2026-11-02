import AppKit
import AVFoundation
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// Plan: .plans/110-agent-characters › character size (0.7.40 polish).
//
// `--agent-characters-size-recording-check <out-dir>`: the characters preview
// scene (the real sidebar beside eight real agent tiles, agents acting) in an
// offscreen window, captured from the window server. Writes
// - compare-light.png / compare-dark.png: Small, Medium and Large side by side,
//   at 100% canvas zoom and at 50%;
// - size-switch.mp4: Large → Medium → Small → Large → Small, switched live
//   through the setting's own change notification, as the Settings pane does.
// Never takes the screen: `orderFrontOffscreenForChecks`, no activation.
@MainActor
enum CharacterSizePreview {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func run(outDirectory: URL) throws -> String {
        try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "ArrayCharacterSizePreview-\(UUID().uuidString)")!
        let controller = AgentCharacterController.shared
        controller.windowIsVisible = { _ in true }
        controller.reduceMotion = { false }
        AgentCharactersPreview.enableCharacters(in: defaults)
        let root = AgentCharactersPreview.workRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        func choose(_ size: AgentCharacterConfig.Size) {
            defaults.set(size.rawValue, forKey: AgentCharacterConfig.sizeKey)
            SettingChangeEvent.post(SettingID(rawValue: AgentCharacterConfig.sizeKey))
        }
        func wait(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        func capture(_ window: NSWindow) throws -> CGImage {
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            CATransaction.flush()
            wait(0.15)
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                      [.boundsIgnoreFraming, .bestResolution]) else {
                throw Failure(description: "capture failed")
            }
            return image
        }

        // 1. The comparison sheets.
        var sheets: [String] = []
        for (appearance, tone) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let scene = AgentCharactersPreview.Scene(appearance: appearance, root: root, label: tone)
            scene.window.orderFrontOffscreenForChecks()
            scene.start()
            defer { scene.stop(); scene.window.orderOut(nil) }
            wait(2)
            var cells: [[CGImage]] = []
            for size in AgentCharacterConfig.Size.allCases {
                choose(size)
                scene.canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 1))
                wait(0.6)
                let full = try capture(scene.window)
                scene.canvas.setViewport(CanvasViewport(x: 0, y: 0, zoom: 0.5))
                wait(0.6)
                let half = try capture(scene.window)
                cells.append([full, half])
            }
            choose(.small)
            let url = outDirectory.appendingPathComponent("compare-\(tone).png")
            try writeSheet(cells, scale: scene.window.backingScaleFactor, dark: tone == "dark", to: url)
            sheets.append(url.lastPathComponent)
        }

        // 2. The live switch, in Dark Aqua.
        let scene = AgentCharactersPreview.Scene(appearance: .darkAqua, root: root, label: "recording")
        scene.window.orderFrontOffscreenForChecks()
        scene.start()
        defer { scene.stop(); scene.window.orderOut(nil) }
        wait(2)
        let movie = outDirectory.appendingPathComponent("size-switch.mp4")
        try? FileManager.default.removeItem(at: movie)
        let writer = try FrameWriter(url: movie)
        let plan: [(AgentCharacterConfig.Size, TimeInterval)] = [(.small, 2.5), (.medium, 2.5), (.large, 3), (.small, 2), (.large, 2.5), (.small, 2)]
        let start = Date()
        for (size, seconds) in plan {
            choose(size)
            let until = Date().addingTimeInterval(seconds)
            var last = Date.distantPast
            while Date() < until {
                RunLoop.current.run(until: Date().addingTimeInterval(0.005))
                guard Date().timeIntervalSince(last) >= 1.0 / 20 else { continue }
                last = Date()
                CATransaction.flush()
                guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(scene.window.windowNumber),
                                                          [.boundsIgnoreFraming, .bestResolution]) else { continue }
                try writer.append(image, at: Date().timeIntervalSince(start))
            }
        }
        let frames = try writer.finish()
        return "Character size preview: \(sheets.joined(separator: ", ")) and size-switch.mp4 (\(frames) frames) in \(outDirectory.path)"
    }

    /// Three columns (Small, Medium, Large), two rows (100%, 50%), each cell the
    /// sidebar and the first two tiles, at the capture's own pixels.
    static func writeSheet(_ cells: [[CGImage]], scale: CGFloat, dark: Bool, to url: URL) throws {
        let crop = CGRect(x: 0, y: 0, width: 960 * scale, height: 400 * scale)
        let label = 34 * scale, gap = 12 * scale
        let width = Int(crop.width * 3 + gap * 4), height = Int(label + (crop.height + label) * 2 + gap * 2)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(description: "no sheet context")
        }
        context.setFillColor(dark ? CGColor(gray: 0.08, alpha: 1) : CGColor(gray: 0.93, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        let ink: NSColor = dark ? .white : .black
        func text(_ string: String, at point: CGPoint, size: CGFloat) {
            (string as NSString).draw(at: point, withAttributes: [
                .font: NSFont.systemFont(ofSize: size * scale, weight: .semibold), .foregroundColor: ink])
        }
        let names = ["Small (1×)", "Medium (1.5×)", "Large (2.25×)"]
        for (column, pair) in cells.enumerated() {
            let x = gap + CGFloat(column) * (crop.width + gap)
            text(names[column], at: CGPoint(x: x, y: CGFloat(height) - label + 6 * scale), size: 18)
            for (row, image) in pair.enumerated() {
                guard let cropped = image.cropping(to: crop) else { continue }
                let top = CGFloat(height) - label - CGFloat(row) * (crop.height + label + gap)
                if row == 1 { text("Canvas at 50%", at: CGPoint(x: x, y: top - label + 8 * scale), size: 14) }
                let y = top - (row == 1 ? label : 0) - crop.height
                context.draw(cropped, in: CGRect(x: x, y: y, width: crop.width, height: crop.height))
            }
        }
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw Failure(description: "sheet encode failed")
        }
        try data.write(to: url)
    }

    /// H.264 from window-server captures, sized from the first frame.
    final class FrameWriter {
        let url: URL
        private var writer: AVAssetWriter?
        private var input: AVAssetWriterInput?
        private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        private(set) var frames = 0

        init(url: URL) throws { self.url = url }

        func append(_ image: CGImage, at seconds: TimeInterval) throws {
            if writer == nil {
                let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
                let i = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: image.width, AVVideoHeightKey: image.height])
                i.expectsMediaDataInRealTime = true
                let a = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: i, sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                    kCVPixelBufferWidthKey as String: image.width, kCVPixelBufferHeightKey as String: image.height])
                w.add(i)
                guard w.startWriting() else { throw Failure(description: "writer: \(String(describing: w.error))") }
                w.startSession(atSourceTime: .zero)
                (writer, input, adaptor) = (w, i, a)
            }
            guard let adaptor, let input, let pool = adaptor.pixelBufferPool else { return }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { return }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: CVPixelBufferGetWidth(buffer),
                                    height: CVPixelBufferGetHeight(buffer), bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
            if adaptor.append(buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600)) { frames += 1 }
        }

        func finish() throws -> Int {
            guard let writer, let input else { throw Failure(description: "no frames captured") }
            input.markAsFinished()
            var done = false
            writer.finishWriting { done = true }
            while !done { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            guard writer.status == .completed else { throw writer.error ?? Failure(description: "writer failed") }
            return frames
        }
    }
}
