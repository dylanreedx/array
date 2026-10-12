import AppKit
import Foundation
import UserNotifications

/// The "an agent needs you" banner raised when the app is in the background.
///
/// Delivered through UserNotifications (NSUserNotification is deprecated since
/// macOS 11). Local notifications need no entitlement for a non-sandboxed app,
/// only the user's permission, asked for on the first banner. The framework
/// requires a real app bundle — `UNUserNotificationCenter.current()` traps in a
/// bare `swift build` binary — so anything else (checks, bare binaries) never
/// reaches the center.
@MainActor
enum NeedsAttentionNotification {
    /// QA: when set, receives (title, body) instead of a real delivery.
    static var qaSink: ((String, String) -> Void)?

    static func title(count: Int) -> String {
        count == 1 ? "Array agent needs attention" : "Array agents need attention"
    }

    static func body(count: Int) -> String {
        count == 1 ? "1 agent needs input." : "\(count) agents need input."
    }

    static func deliver(count: Int) {
        let title = title(count: count)
        let body = body(count: count)
        if let qaSink {
            qaSink(title, body)
            return
        }
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            guard granted else {
                if let error { fputs("Needs-attention notification not authorized: \(error)\n", stderr) }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: "array.agent-needs-attention", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error { fputs("Needs-attention notification failed: \(error)\n", stderr) }
            }
        }
    }

    /// `--attention-notification-check`: the banner the production delivery
    /// builds carries the app's user-visible name, never the internal one.
    static func runSelfCheck() throws -> URL {
        struct CheckError: Error, CustomStringConvertible { let description: String }
        var delivered: [(String, String)] = []
        qaSink = { delivered.append(($0, $1)) }
        defer { qaSink = nil }
        deliver(count: 1)
        deliver(count: 3)
        guard delivered.count == 2 else { throw CheckError(description: "expected 2 deliveries, got \(delivered.count)") }
        for (title, body) in delivered {
            if (title + body).localizedCaseInsensitiveContains("continuum") {
                throw CheckError(description: "needs-attention banner shows the internal name: \"\(title)\" / \"\(body)\"")
            }
            if !title.contains("Array") {
                throw CheckError(description: "needs-attention banner title must name Array, got \"\(title)\"")
            }
        }
        guard delivered[0].1 == "1 agent needs input.", delivered[1].1 == "3 agents need input." else {
            throw CheckError(description: "needs-attention body miscounted: \(delivered.map(\.1))")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("array-attention-notification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let artifact = directory.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: [
            "check": "attention-notification",
            "titles": delivered.map(\.0),
            "bodies": delivered.map(\.1),
        ], options: [.prettyPrinted, .sortedKeys]).write(to: artifact, options: .atomic)
        return artifact
    }
}
