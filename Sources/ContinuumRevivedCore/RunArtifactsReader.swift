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
    /// True when this read reflects a file identity change — the pi extension's
    /// completion rewrite (temp-file + rename, which changes the inode) — rather
    /// than an append. `events`/`badLineCount` in that case describe the FRESH
    /// file's content read from byte 0, not a continuation of any earlier read.
    /// A consumer tracking its own read position against `events` must reset
    /// that position, never slice at it: the old position was computed against a
    /// file that no longer exists.
    public var rewrote: Bool

    public init(events: [RunEventArtifact], badLineCount: Int, rewrote: Bool = false) {
        self.events = events
        self.badLineCount = badLineCount
        self.rewrote = rewrote
    }
}

/// A byte-cursor position in one run's `events.jsonl`, plus the inode it was
/// taken against. Valid only while the inode is unchanged and the file's size is
/// non-decreasing — exactly the append-only-while-live guarantee the pi
/// extension gives. See `RunArtifactsReader.tailEventsJSONL`.
public struct RunEventsFileState: Equatable, Sendable {
    public var inode: UInt64
    public var byteOffset: UInt64

    public init(inode: UInt64, byteOffset: UInt64) {
        self.inode = inode
        self.byteOffset = byteOffset
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

    /// Incrementally parses `events.jsonl`, reading only the bytes appended since
    /// `previous` rather than the whole file. This is the E fix: the naive
    /// re-read-and-reparse-everything approach costs ~19ms/MB of file, all of it
    /// in `split`/`JSONSerialization`, re-incurred on every poll — a live 5MB
    /// file costs ~193ms of CPU per wall second at the watcher's 0.25s interval.
    /// A tail read pays only for what is new.
    ///
    /// Detects the extension's completion rewrite (temp-file + rename) by
    /// comparing inode, not size: a rewrite is a DIFFERENT file, and a byte
    /// offset computed against the old one is meaningless against the new one —
    /// re-using it (as a size-only shrink check would tempt) reads the new
    /// file's bytes at the wrong position and misparses or misdelivers content.
    /// On a detected rewrite this reads the fresh file from byte 0 instead.
    ///
    /// The read always stops at the last `\n`. A line-index cursor gets partial-
    /// trailing-line safety for free — an incomplete line just fails to parse and
    /// reappears whole next time — but a byte cursor does not: without stopping
    /// at the last newline, a half-written line would be sliced mid-write and its
    /// second half silently dropped, corrupting the stream.
    public static func tailEventsJSONL(
        at url: URL,
        from previous: RunEventsFileState?,
        fileManager: FileManager = .default
    ) -> (events: [RunEventArtifact], badLineCount: Int, state: RunEventsFileState?, rewrote: Bool) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else {
            return ([], 0, nil, false)
        }
        let rewrote = previous.map { $0.inode != inode } ?? false
        let startOffset: UInt64 = (previous != nil && !rewrote) ? previous!.byteOffset : 0
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            return ([], 0, nil, rewrote)
        }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: startOffset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else {
            // Nothing new past the cursor; the cursor itself is still valid since
            // the inode has not changed (or, on a rewrite with an empty fresh
            // file, there is nothing to read yet).
            return ([], 0, RunEventsFileState(inode: inode, byteOffset: startOffset), rewrote)
        }
        guard let lastNewline = data.lastIndex(of: 0x0A) else {
            // No complete line at all yet — do not advance the cursor.
            return ([], 0, RunEventsFileState(inode: inode, byteOffset: startOffset), rewrote)
        }
        let consumedLength = lastNewline - data.startIndex + 1
        let complete = data.subdata(in: data.startIndex..<(data.startIndex + consumedLength))
        guard let text = String(data: complete, encoding: .utf8) else {
            return ([], 0, RunEventsFileState(inode: inode, byteOffset: startOffset), rewrote)
        }
        var events: [RunEventArtifact] = []
        var badLineCount = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let lineData = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else {
                badLineCount += 1
                continue
            }
            events.append(RunEventArtifact(timestamp: object["ts"] as? String, type: object["type"] as? String, rawJSON: trimmed))
        }
        let newState = RunEventsFileState(inode: inode, byteOffset: startOffset + UInt64(consumedLength))
        return (events, badLineCount, newState, rewrote)
    }

    // `internal` rather than `private`: `RunArtifactsWatcher` (same module,
    // different file) reuses this for `final.md`, which is small and unbatched
    // and does not need the incremental treatment `tailEventsJSONL` above gives
    // `events.jsonl`.
    static func readUTF8IfPresent(at url: URL, fileManager: FileManager = .default) -> String? {
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
