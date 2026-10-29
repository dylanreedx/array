import Foundation

/// Reads an account's identity and live limits ON DEMAND, with no model turn.
///
/// Before this, a 5h/weekly reading existed only after a turn ran: it rode the
/// turn's `rate_limit_event`. An idle morning showed nothing, or yesterday's
/// number. Both CLIs answer the question directly:
///
/// - claude: `auth status --json` for who, and the `get_usage` control request
///   over stream-json for the windows. Measured on 2.1.312: no turn starts, no
///   session is persisted (`--no-session-persistence`), ~0.4s.
/// - codex: app-server `account/read` and `account/rateLimits/read`, after the
///   same `initialize` handshake the catalogue probe uses.
///
/// `configDirectory` is the claude account's config dir. Nil is the CLI's
/// default dir; a non-nil value is passed as `CLAUDE_CONFIG_DIR`, which is how
/// the CLI itself keys its login (its keychain item is named after the dir).
/// Array passes the dir; it never reads what the login stores there.
public enum AgentAccountUsageProbe {
    public struct Reading: Sendable, Equatable {
        public var identity: AgentAccountIdentity?
        public var quota: AgentAccountQuotaSnapshot?
        public init(identity: AgentAccountIdentity?, quota: AgentAccountQuotaSnapshot?) {
            self.identity = identity
            self.quota = quota
        }
    }

    public static let claudeUsageRequestId = "array-usage"
    public static var claudeUsageRequestLine: String {
        #"{"type":"control_request","request_id":"\#(claudeUsageRequestId)","request":{"subtype":"get_usage","skip_behaviors":true}}"#
    }
    /// The model probe's flags (no tools, no MCP, no settings, no hooks) plus no
    /// session file: asking for usage must not leave a conversation behind.
    public static let claudeUsageArguments = ClaudeCLIBackend.modelProbeArguments + ["--no-session-persistence"]

    /// One stdout line → the `get_usage` answer. The outer optional is "is this
    /// the answer at all"; the inner is "did the answer carry windows" (nil for
    /// a signed-out dir).
    public static func parseClaudeUsage(
        controlResponseLine line: String,
        observedAt: Date
    ) -> AgentAccountQuotaSnapshot?? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              (object["type"] as? String) == "control_response",
              let envelope = object["response"] as? [String: Any],
              (envelope["request_id"] as? String) == claudeUsageRequestId else { return nil }
        guard (envelope["subtype"] as? String) == "success",
              let body = envelope["response"] as? [String: Any] else { return .some(nil) }
        return .some(AgentAccountQuota.claudeUsageSnapshot(getUsageResponse: body, observedAt: observedAt))
    }

    #if os(macOS)
    /// The environment every claude account probe runs in. `CLAUDE_CONFIG_DIR`
    /// is set for a named dir and REMOVED for the default one, so an inherited
    /// value can never make the default account read another login. `HOME` is
    /// never touched.
    public static func claudeEnvironment(
        base: [String: String],
        configDirectory: String?
    ) -> [String: String] {
        var environment = base
        environment["PATH"] = PiAgentRunner.augmentedPath(
            basePath: environment["PATH"] ?? "", extraDirs: PiAgentRunner.liveExtraDirs())
        if let configDirectory, !configDirectory.isEmpty {
            environment["CLAUDE_CONFIG_DIR"] = configDirectory
        } else {
            environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        }
        return environment
    }

    public static func readClaude(
        command: PiAgentRunner.ResolvedCommand,
        configDirectory: String?,
        timeout: TimeInterval,
        now: @escaping () -> Date = Date.init
    ) -> Reading {
        let environment = claudeEnvironment(
            base: ProcessInfo.processInfo.environment, configDirectory: configDirectory)
        let identity = run(
            command: command, arguments: ["auth", "status", "--json"],
            environment: environment, input: nil, timeout: timeout
        ) { _, whole in
            whole.flatMap { AgentAccountIdentity.claude(authStatusJSON: $0, observedAt: now()) }
        }
        // A signed-out dir has no windows to ask for.
        guard identity != nil else { return Reading(identity: nil, quota: nil) }
        let quota = run(
            command: command, arguments: claudeUsageArguments,
            environment: environment, input: claudeUsageRequestLine + "\n", timeout: timeout
        ) { line, _ in
            line.flatMap { parseClaudeUsage(controlResponseLine: $0, observedAt: now()) }
        }
        return Reading(identity: identity, quota: quota ?? nil)
    }

    public static func readCodex(
        command: PiAgentRunner.ResolvedCommand,
        timeout: TimeInterval,
        now: @escaping () -> Date = Date.init
    ) -> Reading {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = PiAgentRunner.augmentedPath(
            basePath: environment["PATH"] ?? "", extraDirs: PiAgentRunner.liveExtraDirs())
        guard let child = try? ProcessGroupChild.spawn(
            executable: command.executable,
            arguments: command.prefixArgs + CodexCLIBackend.appServerArguments(extraArgs: []),
            environment: environment,
            currentDirectory: nil,
            standardInput: .pipe)
        else { return Reading(identity: nil, quota: nil) }
        let transport = CodexAppServerTransport(child: child) { _ in }
        defer {
            transport.shutdown()
            child.terminateGroup(graceSeconds: ProcessGroupChild.Grace.interactive)
        }
        do {
            _ = try transport.sendRequest(
                method: "initialize",
                params: [
                    "clientInfo": ["name": "array", "title": "Array", "version": "0.0.1"],
                    "capabilities": ["experimentalApi": true],
                ],
                timeout: timeout)
            try transport.sendNotification(method: "initialized", params: [:])
            let account = try transport.sendRequest(method: "account/read", params: [:], timeout: timeout)
            let identity = (account as? [String: Any])
                .flatMap { AgentAccountIdentity.codex(accountReadResult: $0, observedAt: now()) }
            guard identity != nil else { return Reading(identity: nil, quota: nil) }
            let limits = try? transport.sendRequest(method: "account/rateLimits/read", params: [:], timeout: timeout)
            let quota = (limits as? [String: Any])
                .flatMap { AgentAccountQuota.codexReadSnapshot(rateLimitsReadResult: $0, observedAt: now()) }
            return Reading(identity: identity, quota: quota)
        } catch {
            return Reading(identity: nil, quota: nil)
        }
    }

    /// One bounded child. `parse` sees each complete stdout line as it arrives
    /// (`line`, `nil`) and, once stdout closes, the whole output (`nil`,
    /// `data`). The first non-nil answer wins and the group is terminated; so
    /// does the deadline. Both pipes are drained so a chatty stderr cannot
    /// wedge the child.
    private static func run<T>(
        command: PiAgentRunner.ResolvedCommand,
        arguments: [String],
        environment: [String: String],
        input: String?,
        timeout: TimeInterval,
        parse: (String?, Data?) -> T?
    ) -> T? {
        guard let child = try? ProcessGroupChild.spawn(
            executable: command.executable,
            arguments: command.prefixArgs + arguments,
            environment: environment,
            currentDirectory: nil,
            standardInput: input == nil ? .inherit : .pipe)
        else { return nil }
        defer { child.terminateGroup(graceSeconds: ProcessGroupChild.Grace.interactive) }
        if let input {
            guard let stdin = child.standardInput,
                  (try? stdin.write(contentsOf: Data(input.utf8))) != nil else { return nil }
        }
        let descriptors = [child.standardOutput.fileDescriptor, child.standardError.fileDescriptor]
        for descriptor in descriptors {
            let flags = fcntl(descriptor, F_GETFL)
            if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
        }
        var whole = Data()
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let deadline = Date().addingTimeInterval(timeout)
        while deadline.timeIntervalSinceNow > 0 {
            var stdoutOpen = true
            for (index, descriptor) in descriptors.enumerated() {
                while true {
                    let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress!, $0.count) }
                    if count > 0 {
                        if index == 0 {
                            pending.append(contentsOf: buffer.prefix(count))
                            whole.append(contentsOf: buffer.prefix(count))
                        }
                        continue
                    }
                    if count == 0, index == 0 { stdoutOpen = false }
                    break
                }
            }
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                if let answer = parse(line, nil) { return answer }
            }
            guard stdoutOpen else { return parse(nil, whole) }
            var fds = descriptors.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let remaining = max(0, deadline.timeIntervalSinceNow)
            _ = poll(&fds, nfds_t(fds.count), Int32(min(remaining * 1000, 50)))
        }
        return nil
    }
    #endif
}
