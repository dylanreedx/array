import Foundation

@MainActor
enum IOSPreviewActionChecks {
    private struct CheckFailure: Error { let message: String }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw CheckFailure(message: message) }
    }
    private static func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw CheckFailure(message: "action did not settle")
    }
    private static func reply(_ channel: IOSPreviewActionChannel, _ tag: UInt8, _ id: Int, _ outcome: String) -> Bool {
        channel.receive(tag: tag, body: try! JSONSerialization.data(withJSONObject: ["requestID": id, "outcome": outcome]))
    }
    private static func expectFailure(_ task: Task<Void, Error>, _ expected: IOSPreviewActionChannel.Failure) async throws {
        switch await task.result {
        case .success: throw CheckFailure(message: "unexpected successful action")
        case .failure(let error): try expect(error as? IOSPreviewActionChannel.Failure == expected, "wrong action failure: \(error)")
        }
    }
    static func run() async throws {
        let channel = IOSPreviewActionChannel()
        var ids: [Int] = [], completed = false
        let first = Task { try await channel.perform { ids.append($0); return true }; completed = true }
        try await settle { ids.count == 1 }
        try expect(!completed, "socket enqueue cannot complete an action")
        try expect(reply(channel, 0x84, ids[0] + 1, "native_sequence_completed"), "foreign ack must be consumed")
        try expect(!completed, "wrong ID cannot complete an action")
        let busy = Task { try await channel.perform { ids.append($0); return true } }
        try await expectFailure(busy, .rejected)
        try expect(ids.count == 1, "busy channel cannot dispatch another native action")
        _ = reply(channel, 0x84, ids[0], "native_sequence_completed")
        try await first.value
        try expect(completed, "matching native completion must settle the caller")
        let second = Task { try await channel.perform { ids.append($0); return true } }
        try await settle { ids.count == 2 }
        _ = reply(channel, 0x84, ids[0], "native_sequence_completed")
        _ = reply(channel, 0x91, ids[1], "rejected")
        try await expectFailure(second, .rejected)
        try expect(ids[1] > ids[0], "request IDs must never be reused")
        let noDispatch = Task { try await channel.perform { _ in false } }
        try await expectFailure(noDispatch, .rejected)
        try expect(!channel.receive(tag: 0x91, body: Data()), "legacy error must retain the human failure path")

        for mode in ["timeout", "cancel", "disconnect", "partial", "malformed"] {
            let c = IOSPreviewActionChannel()
            var dispatched = 0, invalidations = 0
            c.onUncertain = { invalidations += 1 }
            let task = Task { try await c.perform(timeout: mode == "timeout" ? 0.02 : 5) { dispatched = $0; return true } }
            try await settle { dispatched > 0 }
            switch mode {
            case "cancel": task.cancel()
            case "disconnect": c.invalidate()
            case "partial": _ = reply(c, 0x91, dispatched, "outcome_unknown")
            case "malformed": _ = c.receive(tag: 0x84, body: Data("{}".utf8))
            default: break
            }
            try await expectFailure(task, .outcomeUnknown)
            _ = reply(c, 0x84, dispatched, "native_sequence_completed") // must not double-resume
            let retry = Task { try await c.perform { _ in dispatched += 1; return true } }
            try await expectFailure(retry, .rejected)
            try expect(dispatched == 1, "\(mode) must fence subsequent input rather than replay")
            try expect(invalidations == (mode == "disconnect" ? 0 : 1), "uncertain outcome must invalidate transport once")
        }
        try expect(IOSPreviewBoundedAction.text("café 🧪").payload != nil, "bounded Unicode must be supported")
        try expect(IOSPreviewBoundedAction.text(String(repeating: "🧪", count: 4097)).payload == nil, "text byte limit is UTF-8, not character count")
        try expect(IOSPreviewBoundedAction.key("__proto__").payload == nil, "keys must use the closed named vocabulary")
        try expect(IOSPreviewBoundedAction.rotate(0).payload == nil, "unknown orientation must reject")
        try expect(IOSPreviewBoundedAction.swipe(x: 0, y: 0, endX: 1, endY: 1, milliseconds: 1501).payload == nil, "swipe duration must be bounded")
        try expect(IOSPreviewBoundedAction.swipe(x: .nan, y: 0, endX: 1, endY: 1, milliseconds: 100).payload == nil, "non-finite path must reject")
        print("IOSPreviewActionChecks passed: correlated completion, wrong/late IDs, bounded admission, rejected dispatch, timeout, cancellation, disconnect, partial effect and malformed acknowledgement; no replay")
    }
}
