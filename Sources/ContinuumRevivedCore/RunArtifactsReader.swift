import Foundation

public struct RunArtifactsSnapshot: Equatable, Sendable {
    public var run: RunArtifact
    public var events: RunEventsArtifact
    public var finalMarkdown: String?

    public init(run: RunArtifact, events: RunEventsArtifact, finalMarkdown: String?) {
        self.run = run
        self.events = events
        self.finalMarkdown = finalMarkdown
    }
}

public struct RunArtifact: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case queued
        case running
        case done
        case failed
        case killed
        case stale
        case unknown
    }

    public var id: String?
    public var role: String?
    public var status: Status
    public var task: String?
    public var cwd: String?
    public var createdAt: String?
    public var updatedAt: String?
    /// The delegated child process's pid, when the run recorded one.
    ///
    /// T6.6 — `status: "running"` in a run.json is NOT evidence that the run is
    /// live. The parent `pi` process is what writes these files, so if Array has
    /// restarted, any run still marked running was abandoned mid-flight and the
    /// status is simply stale. Treating a stale "running" as live is the
    /// resurrection bug: Array would wait forever for a child that died with the
    /// last session. Measured: this is the CHILD pi's pid, a direct child of the
    /// parent pi.
    public var pid: Int?
    public var rawJSON: String?

    public init(
        id: String?,
        role: String?,
        status: Status,
        task: String?,
        cwd: String?,
        createdAt: String?,
        updatedAt: String?,
        pid: Int? = nil,
        rawJSON: String?
    ) {
        self.id = id
        self.role = role
        self.status = status
        self.task = task
        self.cwd = cwd
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pid = pid
        self.rawJSON = rawJSON
    }
}

public struct RunEventArtifact: Equatable, Sendable {
    public var timestamp: String?
    public var type: String?
    public var rawJSON: String

    public init(timestamp: String?, type: String?, rawJSON: String) {
        self.timestamp = timestamp
        self.type = type
        self.rawJSON = rawJSON
    }
}

public struct RunEventsArtifact: Equatable, Sendable {
    public var events: [RunEventArtifact]
    public var badLineCount: Int

    public init(events: [RunEventArtifact], badLineCount: Int) {
        self.events = events
        self.badLineCount = badLineCount
    }
}

public enum RunArtifactsReader {
    public static func read(runDirectory: URL, fileManager: FileManager = .default) -> RunArtifactsSnapshot {
        let runURL = runDirectory.appendingPathComponent("run.json", isDirectory: false)
        let eventsURL = runDirectory.appendingPathComponent("events.jsonl", isDirectory: false)
        let finalURL = runDirectory.appendingPathComponent("final.md", isDirectory: false)
        return RunArtifactsSnapshot(
            run: readRunJSON(at: runURL),
            events: readEventsJSONL(at: eventsURL),
            finalMarkdown: readUTF8IfPresent(at: finalURL, fileManager: fileManager)
        )
    }

    public static func readRunJSON(at url: URL) -> RunArtifact {
        guard let raw = readUTF8IfPresent(at: url) else {
            return RunArtifact(id: nil, role: nil, status: .unknown, task: nil, cwd: nil, createdAt: nil, updatedAt: nil, rawJSON: nil)
        }
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return RunArtifact(id: nil, role: nil, status: .unknown, task: nil, cwd: nil, createdAt: nil, updatedAt: nil, rawJSON: raw)
        }
        let statusString = object["status"] as? String
        return RunArtifact(
            id: object["id"] as? String,
            role: object["role"] as? String,
            status: statusString.flatMap(RunArtifact.Status.init(rawValue:)) ?? .unknown,
            task: object["task"] as? String,
            cwd: object["cwd"] as? String,
            createdAt: object["createdAt"] as? String,
            updatedAt: object["updatedAt"] as? String,
            pid: (object["pid"] as? NSNumber)?.intValue,
            rawJSON: raw
        )
    }

    public static func readEventsJSONL(at url: URL) -> RunEventsArtifact {
        guard let raw = readUTF8IfPresent(at: url), !raw.isEmpty else {
            return RunEventsArtifact(events: [], badLineCount: 0)
        }
        var events: [RunEventArtifact] = []
        var badLineCount = 0
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                badLineCount += 1
                continue
            }
            events.append(RunEventArtifact(timestamp: object["ts"] as? String, type: object["type"] as? String, rawJSON: text))
        }
        return RunEventsArtifact(events: events, badLineCount: badLineCount)
    }

    private static func readUTF8IfPresent(at url: URL, fileManager: FileManager = .default) -> String? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}


extension RunArtifact {
    /// Whether this run is finished as far as Array is concerned.
    ///
    /// A terminal status is terminal. A `running` status is trusted only while the
    /// recorded pid is still alive — `kill(pid, 0)`, the same probe the extension's
    /// own `markStaleRuns` uses. With no pid to check, a `running` run is treated as
    /// finished rather than hung: the alternative is a watcher that never stops.
    public func isFinished(isProcessAlive: (Int) -> Bool = RunArtifact.processIsAlive) -> Bool {
        switch status {
        case .done, .failed, .killed, .stale: return true
        case .queued, .running:
            guard let pid, pid > 0 else { return true }
            return !isProcessAlive(pid)
        case .unknown: return true
        }
    }

    /// `kill(pid, 0)` succeeds for a live process, and fails with EPERM for one
    /// this user cannot signal — which still means it exists.
    public static func processIsAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }
}
