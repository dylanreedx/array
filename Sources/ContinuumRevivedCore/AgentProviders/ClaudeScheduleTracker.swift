import Foundation

/// Queue-confined facts from successful main-session tools, not tool names in
/// assistant prose. Native timers belong to the live CLI process only.
struct ClaudeScheduleTracker {
    private struct Call { var name: String; var input: [String: Any] }
    private var calls: [String: Call] = [:]
    private var jobs: [String: Date] = [:]
    private var dynamicWakeup: Date?

    mutating func hasWork(at now: Date = Date()) -> Bool {
        jobs = jobs.filter { $0.value > now }
        return !jobs.isEmpty || dynamicWakeup.map { $0 > now } == true
    }

    mutating func consume(_ object: [String: Any], now: Date = Date()) {
        guard object["parent_tool_use_id"] == nil || object["parent_tool_use_id"] is NSNull,
              let message = object["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return }
        for block in blocks {
            if block["type"] as? String == "tool_use", let id = block["id"] as? String,
               let name = block["name"] as? String,
               ["CronCreate", "CronDelete", "CronList", "ScheduleWakeup"].contains(name) {
                if calls.count < 128 { calls[id] = Call(name: name, input: block["input"] as? [String: Any] ?? [:]) }
            }
            guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String,
                  let call = calls.removeValue(forKey: id), block["is_error"] as? Bool != true else { continue }
            let text = (block["content"] as? String) ?? (block["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
            let metadata = (object["tool_use_result"] ?? object["toolUseResult"]) as? [String: Any]
            switch call.name {
            case "CronCreate":
                // The CLI's own acknowledgement, never the requested cron alone.
                guard let match = text.range(of: #"^Scheduled (?:recurring|one-shot|one-time) job ([A-Za-z0-9_-]+)"#, options: .regularExpression) else { continue }
                let words = text[match].split(separator: " ")
                guard let job = words.last else { continue }
                let recurring = (call.input["recurring"] as? Bool) ?? text.hasPrefix("Scheduled recurring")
                let next = (metadata?["nextFireAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                jobs[String(job)] = recurring ? now.addingTimeInterval(7 * 86400) : next ?? now.addingTimeInterval(86400)
            case "CronDelete":
                if let job = call.input["id"] as? String, text.hasPrefix("Cancelled job \(job).") { jobs[job] = nil }
            case "CronList":
                if let listed = metadata?["jobs"] as? [[String: Any]] {
                    jobs = [:]
                    for job in listed.prefix(128) {
                        guard let id = job["id"] as? String else { continue }
                        let next = (job["nextFireAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                        jobs[id] = job["recurring"] as? Bool == true
                            ? now.addingTimeInterval(7 * 86400) : next ?? now.addingTimeInterval(86400)
                    }
                } else if text.hasPrefix("No scheduled jobs") { jobs = [:] }
            case "ScheduleWakeup":
                if call.input["stop"] as? Bool == true { dynamicWakeup = nil }
                else if let seconds = call.input["delaySeconds"] as? Double {
                    dynamicWakeup = now.addingTimeInterval(max(60, min(3600, seconds)))
                }
            default: break
            }
        }
    }
}
