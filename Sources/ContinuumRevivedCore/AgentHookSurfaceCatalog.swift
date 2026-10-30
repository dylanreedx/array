import Foundation

#if os(macOS)
/// No-model, isolated CLI probes. Unknown or changed surfaces fail open by
/// omitting Array's hooks, never by widening trust. Snapshots are available to UI.
public final class AgentHookSurfaceCatalog: @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        public let version: String
        public let events: [String]
        public let available: Bool
        public let detail: String
    }
    public static let shared = AgentHookSurfaceCatalog()
    private let lock = NSLock()
    private let probeLock = NSLock()
    private var snapshots: [AgentHarness: Snapshot] = [:]
    private var configurations: [String: [String]] = [:]
    public init() {}

    public func snapshot(for harness: AgentHarness) -> Snapshot? {
        lock.withLock { snapshots[harness] }
    }

    public func startRefresh() {
        DispatchQueue.global(qos: .utility).async {
            _ = self.claudeAvailable(command: ClaudeAgentRunner.liveResolvedCommand())
            _ = self.codexOverrides(command: CodexAgentRunner.liveResolvedCommand(), hookCommand: "/usr/bin/true")
        }
    }

    /// Read the exact key and normalized hash from Codex, then start a second
    /// listing with only those entries trusted. Never compute serde's hash in Swift.
    /// The command (including endpoint, agent and token-file path) is part of
    /// the cache key, as is the CLI version. No auth or user config is needed.
    public func codexOverrides(command: PiAgentRunner.ResolvedCommand, hookCommand: String,
                               timeout: TimeInterval = 5) -> [String] {
        probeLock.lock(); defer { probeLock.unlock() }
        return isolated { directory, environment in
            let version = capture(command, ["--version"], environment, directory, timeout)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            let cacheKey = ([command.executable] + command.prefixArgs + [version, hookCommand]).joined(separator: "\n")
            if let cached = configurations[cacheKey] {
                publish(.codex, version: version, available: true)
                return cached
            }
            let definitions = WorkspaceAgentHook.codexDefinitions(command: hookCommand)
            var result: [String] = []
            if version != "unknown",
               let first = listHooks(command, definitions, environment, directory, timeout),
               let identities = Self.arrayIdentities(first, command: hookCommand),
               let second = listHooks(command, definitions + [Self.trustOverride(identities)], environment, directory, timeout),
               let verified = Self.arrayIdentities(second, command: hookCommand, requireTrusted: true),
               identities == verified {
                result = definitions + [Self.trustOverride(identities)]
            }
            publish(.codex, version: version, available: !result.isEmpty)
            // Failed probes are retried next launch (a timeout is not a permanent capability).
            if !result.isEmpty { configurations[cacheKey] = result }
            return result
        } ?? []
    }

    /// The installed CLI's control-protocol listing owns event support. A
    /// successful initialize alone is insufficient: unknown event keys are
    /// silently ignored. Also require --settings to execute SessionStart.
    public func claudeAvailable(command: PiAgentRunner.ResolvedCommand, timeout: TimeInterval = 5) -> Bool {
        probeLock.lock(); defer { probeLock.unlock() }
        return isolated { directory, environment in
            let version = capture(command, ["--version"], environment, directory, timeout)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            let key = ([command.executable] + command.prefixArgs + [version, "claude-hooks"]).joined(separator: "\n")
            if configurations[key] != nil {
                publish(.claudeCode, version: version, available: true)
                return true
            }
            var available = false
            if version != "unknown",
               let help = capture(command, ["--help"], environment, directory, timeout), help.contains("--settings") {
                let receipt = directory.appendingPathComponent("session-start")
                let hookCommand = "/usr/bin/touch " + WorkspaceAgentHook.shellQuoted(receipt.path)
                let settings = WorkspaceAgentHook.claudeSettingsJSON(command: hookCommand)
                let args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                            "--tools", "", "--strict-mcp-config", "--setting-sources", "", "--settings", settings]
                let input = ClaudeCLIBackend.modelProbeRequestLine + "\n"
                    + #"{"type":"control_request","request_id":"array-hooks","request":{"subtype":"get_hooks_listing"}}"# + "\n"
                if let response = capture(command, args, environment, directory, timeout, input: input) {
                    available = Self.claudeListingAvailable(response, command: hookCommand)
                        && FileManager.default.fileExists(atPath: receipt.path)
                }
            }
            publish(.claudeCode, version: version, available: available)
            if available { configurations[key] = [] }
            return available
        } ?? false
    }

    public static func claudeListingAvailable(_ response: String, command: String) -> Bool {
        for line in response.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let envelope = object["response"] as? [String: Any],
                  envelope["request_id"] as? String == "array-hooks", envelope["subtype"] as? String == "success",
                  let listing = envelope["response"] as? [String: Any],
                  let events = listing["eventCatalog"] as? [[String: Any]],
                  let hooks = listing["hooks"] as? [[String: Any]] else { continue }
            let supported = Set(events.compactMap { $0["name"] as? String })
            return WorkspaceAgentHook.claudeEvents.allSatisfy { event in
                supported.contains(event) && hooks.contains {
                    $0["event"] as? String == event && $0["source"] as? String == "flagSettings"
                        && $0["type"] as? String == "command" && $0["commandText"] as? String == command
                        && $0["timeout"] as? Int == 5 && $0["disabled"] as? Bool != true
                        && ($0["matcher"] as? String ?? "") == (WorkspaceAgentHook.toolMatcherEvents.contains(event) ? "*" : "")
                }
            }
        }
        return false
    }

    private func publish(_ harness: AgentHarness, version: String, available: Bool) {
        let events = harness == .codex ? WorkspaceAgentHook.codexEvents : WorkspaceAgentHook.claudeEvents
        let detail = harness == .codex
            ? "hooks/list verifies sessionFlags keys, hashes and trust"
            : "get_hooks_listing verifies seven flagSettings events; SessionStart smoke"
        lock.withLock {
            snapshots[harness] = Snapshot(version: version, events: available ? events : [], available: available,
                detail: available ? detail : "Unavailable: " + detail)
        }
    }

    private func isolated<T>(_ body: (URL, [String: String]) -> T) -> T? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("array-hook-probe-\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch { return nil }
        defer { try? FileManager.default.removeItem(at: directory) }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = PiAgentRunner.augmentedPath(basePath: environment["PATH"] ?? "", extraDirs: PiAgentRunner.liveExtraDirs())
        environment["CODEX_HOME"] = directory.path
        environment["CLAUDE_CONFIG_DIR"] = directory.path
        return body(directory, environment)
    }

    private func listHooks(_ command: PiAgentRunner.ResolvedCommand, _ overrides: [String],
                           _ environment: [String: String], _ directory: URL, _ timeout: TimeInterval) -> [String: Any]? {
        guard let child = try? ProcessGroupChild.spawn(executable: command.executable,
            arguments: command.prefixArgs + overrides.flatMap { ["-c", $0] } + ["app-server"],
            environment: environment, currentDirectory: directory, standardInput: .pipe) else { return nil }
        child.standardError.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        let transport = CodexAppServerTransport(child: child) { _ in }
        defer {
            transport.shutdown()
            child.terminateGroup(graceSeconds: ProcessGroupChild.Grace.interactive)
            child.standardError.readabilityHandler = nil
        }
        do {
            _ = try transport.sendRequest(method: "initialize", params: ["clientInfo": ["name": "array-hook-probe", "version": "1"], "capabilities": ["experimentalApi": true]], timeout: timeout)
            try transport.sendNotification(method: "initialized", params: [:])
            return try transport.sendRequest(method: "hooks/list", params: ["cwds": [directory.path]], timeout: timeout)
        } catch { return nil }
    }

    /// Only Array's exact single-handler definitions from the session layer
    /// qualify. User/project/plugin entries can never acquire trust here.
    public static func arrayIdentities(_ result: [String: Any], command: String,
                                       requireTrusted: Bool = false) -> [String: String]? {
        guard let data = result["data"] as? [[String: Any]], data.count == 1,
              let entries = data[0]["hooks"] as? [[String: Any]],
              (data[0]["errors"] as? [Any])?.isEmpty == true else { return nil }
        var identities: [String: String] = [:]
        for (event, snake) in WorkspaceAgentHook.codexEventKeys {
            let wireEvent = event.prefix(1).lowercased() + event.dropFirst()
            let key = "/<session-flags>/config.toml:\(snake):0:0"
            let matches = entries.filter { $0["key"] as? String == key }
            guard matches.count == 1, let entry = matches.first,
                  entry["source"] as? String == "sessionFlags", entry["eventName"] as? String == wireEvent,
                  entry["handlerType"] as? String == "command", entry["command"] as? String == command,
                  entry["enabled"] as? Bool == true, entry["async"] as? Bool == false,
                  entry["timeoutSec"] as? Int == 5,
                  (entry["matcher"] as? String) == (WorkspaceAgentHook.toolMatcherEvents.contains(event) ? "*" : nil),
                  let hash = entry["currentHash"] as? String,
                  hash.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                  !requireTrusted || entry["trustStatus"] as? String == "trusted" else { return nil }
            identities[key] = hash
        }
        return identities
    }

    public static func trustOverride(_ identities: [String: String]) -> String {
        "hooks.state={" + identities.keys.sorted().map {
            WorkspaceAgentHook.tomlString($0) + "={trusted_hash=" + WorkspaceAgentHook.tomlString(identities[$0]!) + "}"
        }.joined(separator: ",") + "}"
    }

    private func capture(_ command: PiAgentRunner.ResolvedCommand, _ args: [String],
                         _ environment: [String: String], _ directory: URL, _ timeout: TimeInterval,
                         input: String = "") -> String? {
        guard let child = try? ProcessGroupChild.spawn(executable: command.executable, arguments: command.prefixArgs + args,
                environment: environment, currentDirectory: directory, standardInput: .pipe) else { return nil }
        let killer = DispatchWorkItem { child.terminateGroup(graceSeconds: ProcessGroupChild.Grace.interactive) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        defer { killer.cancel(); child.terminateGroup(graceSeconds: ProcessGroupChild.Grace.interactive) }
        child.standardError.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        defer { child.standardError.readabilityHandler = nil }
        try? child.standardInput?.write(contentsOf: Data(input.utf8))
        try? child.standardInput?.close()
        let output = child.standardOutput.readDataToEndOfFile()
        guard child.wait() == 0 else { return nil }
        return String(decoding: output, as: UTF8.self)
    }
}
#endif
