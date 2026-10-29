import Foundation
import ImageIO

/// URLSession delivers multipart frame chunks on this serial worker queue. Only
/// decoded, coalesced images cross onto the main actor; canvas gestures cannot
/// postpone assembly of every compressed chunk in the network stream.
final class IOSPreviewStreamReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let maximumPartBytes = 4 * 1024 * 1024
    struct Statistics: Sendable {
        var receivedBytes = 0
        var offeredFrames = 0
        var largestPartBytes = 0
        var assemblyOnMainThread = 0
        var rejectedParts = 0
    }
    let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "array.ios-preview.stream"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private let lock = NSLock()
    private let decoder: IOSPreviewFrameDecoder
    private let onFrame: @MainActor (CGImage) -> Void
    private let onFailure: @MainActor (String) -> Void
    private var stopped = false
    private var failureReported = false
    private var partLength = 0
    private var part = Data()
    private var counts = Statistics()
    var statistics: Statistics { lock.withLock { counts } }

    init(decoder: IOSPreviewFrameDecoder,
         onFrame: @escaping @MainActor (CGImage) -> Void,
         onFailure: @escaping @MainActor (String) -> Void = { _ in }) {
        self.decoder = decoder
        self.onFrame = onFrame
        self.onFailure = onFailure
        super.init()
    }

    /// Synchronous: after return no delegate can offer a new compressed frame.
    /// The session owner resets the decoder after this fence.
    func stop() {
        lock.withLock { stopped = true; partLength = 0; part = Data() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        completionHandler(receive(response: response))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receive(data: data)
    }

    // These seams exercise the actual production assembly in offline checks;
    // they obey the same lock/fence as the URLSession delegate entry points.
    func receive(response: URLResponse) -> URLSession.ResponseDisposition {
        var failed = false
        let disposition = lock.withLock { () -> URLSession.ResponseDisposition in
            guard !stopped, !failureReported else { return .cancel }
            if Thread.isMainThread { counts.assemblyOnMainThread += 1 }
            partLength = 0; part = Data()
            let statusOK = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? true
            let length = response.expectedContentLength
            let multipart = response.mimeType?.hasPrefix("multipart/") == true
            guard statusOK, multipart || (response.mimeType == "image/jpeg" && length > 0 && length <= Int64(Self.maximumPartBytes)) else {
                counts.rejectedParts += 1; failureReported = true; failed = true
                return .cancel
            }
            if !multipart { partLength = Int(length) }
            return .allow
        }
        if failed { reportFailure("Preview received an invalid frame response. Connect to try again.") }
        return disposition
    }
    func receive(data: Data) {
        guard !data.isEmpty else { return }
        var failed = false
        lock.withLock {
            guard !stopped, !failureReported else { return }
            if Thread.isMainThread { counts.assemblyOnMainThread += 1 }
            counts.receivedBytes += data.count
            guard partLength > 0, data.count <= partLength - part.count else {
                partLength = 0; part = Data()
                counts.rejectedParts += 1; failureReported = true; failed = true
                return
            }
            part.append(data)
            counts.largestPartBytes = max(counts.largestPartBytes, part.count)
            guard part.count == partLength else { return }
            counts.offeredFrames += 1
            // Holding the fence across offer ensures stop()+decoder.reset()
            // cannot be overtaken by an already-running delegate callback.
            decoder.offer(part) { [weak self] image in
                guard let self, self.lock.withLock({ !self.stopped && !self.failureReported }) else { return }
                self.onFrame(image)
            }
            partLength = 0; part = Data()
        }
        if failed { reportFailure("Preview received an invalid frame. Connect to try again.") }
    }
    private func reportFailure(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lock.withLock({ !self.stopped }) else { return }
            self.onFailure(message)
        }
    }
}
