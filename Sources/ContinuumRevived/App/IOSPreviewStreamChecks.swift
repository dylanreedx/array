import AppKit
import Foundation
import ImageIO

/// Exercises the real compressed-frame receiver on its production delegate
/// queue while main is intentionally unavailable. No network or simulator.
@MainActor
enum IOSPreviewStreamChecks {
    private final class WorkerResult: @unchecked Sendable { var allAllowed = true }
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw IOSPreviewChecks.Failure(description: message) }
    }
    private static func jpeg(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw IOSPreviewChecks.Failure(description: "could not create JPEG fixture")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw IOSPreviewChecks.Failure(description: "could not finalize JPEG fixture") }
        return data as Data
    }
    private nonisolated static func response(mime: String, length: Int) -> URLResponse {
        URLResponse(url: URL(string: "http://127.0.0.1/frame")!, mimeType: mime, expectedContentLength: length, textEncodingName: nil)
    }
    static func run() throws {
        let large = try jpeg(IOSPreviewChecks.image())
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.systemGreen.cgColor); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let latest = try jpeg(context.makeImage()!)
        let decoder = IOSPreviewFrameDecoder()
        var widths: [Int] = []
        var failures: [String] = []
        let receiver = IOSPreviewStreamReceiver(decoder: decoder,
            onFrame: { widths.append($0.width) }, onFailure: { failures.append($0) })
        let done = DispatchSemaphore(value: 0)
        let worker = WorkerResult()
        receiver.delegateQueue.addOperation {
            worker.allAllowed = receiver.receive(response: response(mime: "multipart/x-mixed-replace", length: -1)) == .allow
            for data in Array(repeating: large, count: 256) + [latest] {
                worker.allAllowed = worker.allAllowed && receiver.receive(response: response(mime: "image/jpeg", length: data.count)) == .allow
                let split = data.count / 2
                receiver.receive(data: data.prefix(split))
                receiver.receive(data: data.suffix(data.count - split))
            }
            decoder.waitForPendingDecode()
            done.signal()
        }
        // Main stays blocked here; assembly and decoding must finish anyway.
        try expect(done.wait(timeout: .now() + 10) == .success, "frame assembly/decode must not depend on the main queue")
        try expect(worker.allAllowed, "multipart and valid JPEG parts must be accepted")
        let stats = receiver.statistics
        try expect(stats.offeredFrames == 257 && stats.assemblyOnMainThread == 0,
                   "all 257 multipart frames must assemble off main while main is blocked")
        try expect(stats.largestPartBytes == max(large.count, latest.count), "assembly must retain at most the current bounded part")
        try expect(widths.isEmpty && decoder.metrics.presentationHighWater == 1 && decoder.metrics.compressedHighWater == 1,
                   "a blocked main queue must accumulate only one presentation and one compressed pending frame")
        let deadline = Date().addingTimeInterval(3)
        while widths.isEmpty, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        try expect(widths == [8] && failures.isEmpty, "unblocking main must present the newest frame exactly once")
        let offered = decoder.metrics.offered
        receiver.stop(); decoder.reset()
        let stoppedDone = DispatchSemaphore(value: 0)
        receiver.delegateQueue.addOperation {
            _ = receiver.receive(response: response(mime: "image/jpeg", length: large.count))
            receiver.receive(data: large)
            stoppedDone.signal()
        }
        try expect(stoppedDone.wait(timeout: .now() + 3) == .success, "stopped receiver worker must settle")
        try expect(decoder.metrics.offered == offered, "stopped delegate must never offer another frame after decoder reset")

        let malformed = IOSPreviewStreamReceiver(decoder: IOSPreviewFrameDecoder(), onFrame: { _ in })
        let malformedDone = DispatchSemaphore(value: 0)
        let badWorker = WorkerResult()
        malformed.delegateQueue.addOperation {
            badWorker.allAllowed = malformed.receive(response: response(mime: "image/jpeg", length: IOSPreviewStreamReceiver.maximumPartBytes + 1)) == .cancel
            malformedDone.signal()
        }
        try expect(malformedDone.wait(timeout: .now() + 3) == .success && badWorker.allAllowed && malformed.statistics.rejectedParts == 1,
                   "oversized JPEG parts must reject before retaining bytes")
        malformed.stop()
        let http = IOSPreviewStreamReceiver(decoder: IOSPreviewFrameDecoder(), onFrame: { _ in })
        let forbidden = HTTPURLResponse(url: URL(string: "http://127.0.0.1/frame")!, statusCode: 403, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "multipart/x-mixed-replace"])!
        try expect(http.receive(response: forbidden) == .cancel, "HTTP errors must never admit a multipart stream")
        http.stop()
        let overflow = IOSPreviewStreamReceiver(decoder: IOSPreviewFrameDecoder(), onFrame: { _ in })
        try expect(overflow.receive(response: response(mime: "image/jpeg", length: 1)) == .allow, "bounded part response must be allowed")
        overflow.receive(data: Data([1, 2]))
        try expect(overflow.statistics.rejectedParts == 1 && overflow.statistics.offeredFrames == 0,
                   "chunk overflow must reject instead of poisoning later frames")
        overflow.stop()
        let mime = IOSPreviewStreamReceiver(decoder: IOSPreviewFrameDecoder(), onFrame: { _ in })
        try expect(mime.receive(response: response(mime: "text/html", length: 20)) == .cancel, "non-JPEG parts must reject")
        mime.stop()
        print("IOSPreviewStreamChecks passed: 257 frames assembled while main blocked, newest-only presentation, bounded chunks, worker queue, malformed HTTP/MIME/length, overflow and synchronous stop fence")
    }
}
