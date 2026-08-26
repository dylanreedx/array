import ContinuumRevivedAgentUI
import Foundation

public struct ReaderConfiguration: Equatable, Sendable {
    public var now: Date
    public var freshWorkingWindow: TimeInterval
    public var idleWindow: TimeInterval
    public var staleWindow: TimeInterval

    public init(
        now: Date,
        freshWorkingWindow: TimeInterval = 30,
        idleWindow: TimeInterval = 120,
        staleWindow: TimeInterval = 900
    ) {
        self.now = now
        self.freshWorkingWindow = freshWorkingWindow
        self.idleWindow = idleWindow
        self.staleWindow = staleWindow
    }
}

public struct PiAgentStateReader: AgentStateReader {
    public let kind: AgentKind = .pi

    private let globalAgentRunsRoot: URL
    public static var defaultGlobalAgentRunsRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".pi/agent-runs", isDirectory: true)
    }

    public init(
        globalAgentRunsRoot: URL = Self.defaultGlobalAgentRunsRoot
    ) {
        self.globalAgentRunsRoot = globalAgentRunsRoot
    }

    public func detect(processName: String) -> Bool {
        processName == "pi"
    }

    public func locate(pid: pid_t?, cwd: String, runId: String?) -> URL? {
        locate(runId: runId, projectRoot: URL(fileURLWithPath: cwd, isDirectory: true))
    }

    public func locate(runId: String?, projectRoot: URL) -> URL? {
        guard let runId, !runId.isEmpty else { return nil }

        let projectLocal = projectRoot
            .appendingPathComponent(".pi/agent-runs", isDirectory: true)
            .appendingPathComponent(runId, isDirectory: true)
        if directoryExists(projectLocal) {
            return projectLocal
        }

        let global = globalAgentRunsRoot.appendingPathComponent(runId, isDirectory: true)
        if directoryExists(global) {
            return global
        }

        return nil
    }

    public func read(storeURL: URL, asOf: Date) -> AgentSnapshot {
        read(storeURL: storeURL, config: ReaderConfiguration(now: asOf))
    }

    public func read(storeURL: URL, config: ReaderConfiguration) -> AgentSnapshot {
        let runURL = storeURL.appendingPathComponent("run.json", isDirectory: false)
        guard let mtime = modificationDate(of: runURL) else {
            return AgentSnapshot(
                kind: .pi,
                status: .idle,
                title: nil,
                mode: nil,
                asOf: config.now,
                detail: nil,
                evidence: AgentSnapshot.Evidence(
                    source: "pi:run.json:absent",
                    lastEventType: nil,
                    mtimeAgeSeconds: 0
                )
            )
        }

        let run = RunArtifactsReader.readRunJSON(at: runURL)
        let events = RunArtifactsReader.readEventsJSONL(
            at: storeURL.appendingPathComponent("events.jsonl", isDirectory: false)
        )
        let status = deriveStatus(run: run, events: events, mtime: mtime, config: config)

        return AgentSnapshot(
            kind: .pi,
            status: status,
            title: run.task,
            mode: nil,
            asOf: mtime,
            detail: nil,
            evidence: AgentSnapshot.Evidence(
                source: "pi:run.json",
                lastEventType: events.events.last?.type,
                mtimeAgeSeconds: max(0, config.now.timeIntervalSince(mtime))
            )
        )
    }

    private func deriveStatus(
        run: RunArtifact,
        events: RunEventsArtifact,
        mtime: Date,
        config: ReaderConfiguration
    ) -> AgentStatus {
        let age = config.now.timeIntervalSince(mtime)
        if age > config.staleWindow {
            return .idle
        }

        switch run.status {
        case .done, .failed, .killed:
            return .done
        case .queued:
            return .configuring
        case .running, .stale, .unknown:
            break
        }

        switch events.events.last?.type {
        case "finished", "agent_settled":
            return .done
        case "agent_end":
            // Pi may automatically retry, compact, or drain a queued
            // continuation after agent_end. Only agent_settled is terminal;
            // old completed run artifacts are still covered by run.status.done.
            return run.status == .running && age <= config.freshWorkingWindow ? .working : .idle
        case "turn_start", "tool_execution_start", "message_start":
            return age <= config.freshWorkingWindow ? .working : .idle
        case "turn_end", "tool_execution_end", "message_end":
            return run.status == .running && age <= config.freshWorkingWindow ? .working : .idle
        case "started", "session", "agent_start":
            return run.status == .running ? .working : .configuring
        default:
            break
        }

        if run.status == .running {
            return .working
        }

        return .idle
    }

    private func modificationDate(of url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }
}
