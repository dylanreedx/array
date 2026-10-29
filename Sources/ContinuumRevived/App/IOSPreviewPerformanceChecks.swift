import AppKit
import Foundation

/// Opt-in measurement against the live gate's exclusively owned simulator. The
/// marker is rendered by UIKit and observed in a decoded production frame, so
/// latency includes HID, UIKit, capture, JPEG, transport and decode/presentation
/// delivery. It does not claim physical display scan-out or human event routing.
@MainActor
enum IOSPreviewPerformanceChecks {
    private static func fail(_ message: String) -> IOSPreviewChecks.Failure { .init(description: message) }
    private static func wait(_ message: String, seconds: Double = 10, until condition: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.002))
        }
        guard condition() else { throw fail(message) }
    }
    private static func quantile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * p)) - 1))]
    }
    private static func summary(_ values: [Double]) -> [String: Any] {
        guard !values.isEmpty else { return ["count": 0] }
        return ["count": values.count, "p50": quantile(values, 0.5), "p95": quantile(values, 0.95),
                "max": values.max()!, "min": values.min()!, "mean": values.reduce(0, +) / Double(values.count)]
    }
    private static func marker(in image: CGImage, point: CGPoint) -> Bool? {
        let x = min(image.width - 1, max(0, Int(Double(point.x) * Double(image.width))))
        let y = min(image.height - 1, max(0, Int(Double(point.y) * Double(image.height))))
        guard let pixel = image.cropping(to: CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)) else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn, abs(Int(rgba[0]) - Int(rgba[2])) > 100 else { return nil }
        return rgba[2] > rgba[0] // blue == odd tap count
    }
    private struct Resource {
        let cpuSeconds: Double
        let rssKB: Double
        let sampledAt: Double
    }
    private static func resources(pid: Int32) -> Resource? {
        // Only this check's host PID and its explicitly owned helper PID enter
        // this function. ps is observational and never signals a process.
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "time=,rss="]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: output, encoding: .utf8) else { return nil }
        let parts = text.split(whereSeparator: { $0.isWhitespace })
        guard parts.count == 2, let rss = Double(parts[1]) else { return nil }
        let clock = parts[0].split(separator: ":").compactMap { Double($0) }
        guard clock.count >= 2 else { return nil }
        return Resource(cpuSeconds: clock.reduce(0) { $0 * 60 + $1 }, rssKB: rss, sampledAt: ProcessInfo.processInfo.systemUptime)
    }
    private static func resourceDelta(_ before: Resource?, _ after: Resource?) -> [String: Any] {
        guard let before, let after, after.sampledAt > before.sampledAt else { return ["available": false] }
        return ["available": true, "cpuPercent": 100 * (after.cpuSeconds - before.cpuSeconds) / (after.sampledAt - before.sampledAt),
                "rssKB": after.rssKB, "rssDeltaKB": after.rssKB - before.rssKB]
    }

    static func run(tile: IOSPreviewTileNSView, deviceID: String, state: () -> [String: Any], tap: () throws -> Void, out: URL) throws {
        let originalFPS = IOSPreviewProcessSession.captureFramesPerSecond
        let originalFrame = tile.runtime.onFrame
        var restored = false
        defer {
            tile.runtime.onFrame = originalFrame
            IOSPreviewProcessSession.captureFramesPerSecond = originalFPS
            if !restored { tile.runtime.disconnect(); tile.runtime.connect(allowBoot: false) }
        }
        guard let coordinates = state()["latencyMarker"] as? [String: Double],
              let x = coordinates["x"], let y = coordinates["y"],
              state()["performanceAnimation"] as? Bool == true else {
            throw fail("performance witness requires its UIKit marker and --performance-animation launch argument")
        }
        let point = CGPoint(x: x, y: y)
        var rows: [[String: Any]] = []
        for rate in [15, 30, 60] {
            tile.runtime.disconnect()
            // Detach returns synchronously but the owned helper drains inputs
            // before exiting. Reconnect waits for its real child lifetime below.
            IOSPreviewProcessSession.captureFramesPerSecond = rate
            tile.runtime.connect(allowBoot: false)
            try wait("performance preview failed to reconnect at \(rate) fps", seconds: 60) {
                tile.runtime.state == .connected
            }
            guard tile.runtime.deviceID == deviceID else { throw fail("performance sweep changed device identity") }
            var frameTimes: [Double] = []
            var latestMarker: Bool?
            var awaitedMarker: Bool?
            var sentAt: Double?
            var latency: Double?
            tile.runtime.onFrame = { image in
                originalFrame?(image)
                let arrived = ProcessInfo.processInfo.systemUptime
                frameTimes.append(arrived)
                latestMarker = marker(in: image, point: point)
                if latency == nil, let sent = sentAt, latestMarker == awaitedMarker {
                    latency = (arrived - sent) * 1000
                }
            }
            let tapsBefore = state()["taps"] as? Int ?? 0
            try wait("UIKit latency marker was not visible in real decoded frames") { latestMarker == (tapsBefore % 2 != 0) }
            // Warm up JPEG decoding/capture independently of the recorded window.
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let hostBefore = resources(pid: ProcessInfo.processInfo.processIdentifier)
            let helperPID = tile.runtime.helperPID
            let helperBefore = helperPID.flatMap { resources(pid: $0) }
            frameTimes.removeAll(keepingCapacity: true)
            let windowStart = ProcessInfo.processInfo.systemUptime
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            let windowEnd = ProcessInfo.processInfo.systemUptime
            let measuredFrameTimes = frameTimes
            let hostAfter = resources(pid: ProcessInfo.processInfo.processIdentifier)
            let helperAfter = helperPID.flatMap { resources(pid: $0) }
            var latencies: [Double] = []
            for _ in 0..<12 {
                let before = state()["taps"] as? Int ?? 0
                let expected = (before + 1) % 2 != 0
                awaitedMarker = expected; latency = nil
                sentAt = ProcessInfo.processInfo.systemUptime
                try tap()
                try wait("tap did not cause a new UIKit marker in production frames at \(rate) fps", seconds: 5) { latency != nil }
                guard let measured = latency else { throw fail("missing visual latency sample") }
                sentAt = nil; awaitedMarker = nil
                latencies.append(measured)
                try wait("UIKit app-owned counter did not confirm the measured tap") { state()["taps"] as? Int == before + 1 }
                // Spread samples across capture phases rather than repeatedly
                // hitting the same timer phase after the previous frame.
                RunLoop.current.run(until: Date().addingTimeInterval(0.035 + Double(before % 5) * 0.009))
            }
            let intervals = zip(measuredFrameTimes.dropFirst(), measuredFrameTimes).map { ($0.0 - $0.1) * 1000 }
            let result: [String: Any] = ["requestedFPS": rate,
                "deliveredFrames": measuredFrameTimes.count, "windowSeconds": windowEnd - windowStart,
                "deliveredFPS": Double(measuredFrameTimes.count) / (windowEnd - windowStart),
                "frameIntervalMs": summary(intervals), "inputToDecodedVisualMs": summary(latencies),
                "host": resourceDelta(hostBefore, hostAfter), "helper": resourceDelta(helperBefore, helperAfter)]
            rows.append(result)
            print("PERF: \(rate)fps → \(result["deliveredFPS"]!) delivered fps, visual input p50 \(quantile(latencies, 0.5))ms / p95 \(quantile(latencies, 0.95))ms")
            // Always reset callback before disconnect; retired frames must never
            // mutate the next rate's capture window or pending sample.
            tile.runtime.onFrame = originalFrame
        }
        IOSPreviewProcessSession.captureFramesPerSecond = originalFPS
        tile.runtime.disconnect(); tile.runtime.connect(allowBoot: false)
        try wait("performance sweep could not restore default capture session", seconds: 60) { tile.runtime.state == .connected }
        restored = true
        let report: [String: Any] = ["device": deviceID, "result": "PASS", "rates": rows,
            "method": "12 native AppKit taps/rate; first decoded UIKit red/blue marker change; 3-second animated capture window",
            "limitations": ["Physical display scan-out is not measured", "Injected AppKit event handlers, not human global focus routing", "ps CPU deltas are coarse process totals and include all host QA work", "No hard timing threshold: shared-machine load is recorded, behavioral marker/counter outcomes are required"]]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appendingPathComponent("performance-report.json"), options: .atomic)
        print("PASS: real iOS preview performance sweep completed at 15/30/60 fps")
    }
}
