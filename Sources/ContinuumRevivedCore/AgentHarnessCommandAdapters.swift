import Foundation

/// A small, provider-neutral adapter used by the command catalog.  It keeps
/// discovery metadata separate from command execution: probing may inspect an
/// executable and frontmatter, but it never loads a skill body or runs an
/// extension.
public struct AgentBaselineHarnessCommandAdapter: AgentHarnessCommandAdapter, Sendable {
    public let harness: AgentHarness

    public init(harness: AgentHarness) {
        self.harness = harness
    }

    public func probe(context: AgentCompletionContext?) async -> AgentCommandProbeSnapshot {
        let executable = AgentHarnessExecutableProbe.locate(harness: harness)
        let version = executable.flatMap { AgentHarnessExecutableProbe.version(for: $0) }
        let commands = await discoverCommands(context: context)
        var diagnostics: [String] = []
        if executable == nil {
            diagnostics.append("\(harness.rawValue) executable is not available on PATH")
        }
        if version == nil, executable != nil {
            diagnostics.append("Unable to read \(harness.rawValue) version")
        }
        let snapshot = AgentCommandProbeSnapshot(
            harness: harness,
            executableURL: executable,
            version: version,
            commands: commands,
            diagnostics: diagnostics
        )
        AgentHarnessCommandCache.store(snapshot: snapshot, context: context)
        return snapshot
    }

    public func discoverCommands(context: AgentCompletionContext?) async -> [AgentCommandDescriptor] {
        let baseline = AgentCommandCatalog.baseline(for: harness)
        let resources = AgentCommandResourceDiscovery.discover(context: context)
            .filter { $0.harness == harness }
        return Self.merge(baseline + resources)
    }

    public func invoke(
        _ invocation: AgentCommandInvocation,
        context: AgentCompletionContext?
    ) async throws -> AgentCommandExecutionResult {
        guard invocation.harness == harness else {
            return AgentCommandExecutionResult(
                status: .refused("Command belongs to a different harness"),
                summary: "Switch to \(harness.rawValue) before invoking this command."
            )
        }
        let descriptors = await discoverCommands(context: context)
        guard let descriptor = descriptors.first(where: { $0.id == invocation.descriptorID }) else {
            return AgentCommandExecutionResult(
                status: .refused("Command is not present in the current provider snapshot"),
                summary: "Refresh \(harness.rawValue) commands and try again."
            )
        }
        guard descriptor.isEnabled else {
            return AgentCommandExecutionResult(
                status: .refused(descriptor.disabledReason ?? "Command is unavailable"),
                summary: descriptor.disabledReason ?? "Command is unavailable."
            )
        }
        if invocation.surface == .cli {
            guard let checkout = context?.checkoutRoot.standardizedFileURL else {
                return AgentCommandExecutionResult(
                    status: .refused("A checkout is required for CLI commands"),
                    summary: "The harness command has no constrained working directory."
                )
            }
            if let manifest = AgentHarnessCommandManifestDiscovery.manifest(
                for: invocation.descriptorID, context: context
            ) {
                let workingDirectory = checkout.appendingPathComponent(
                    manifest.workingDirectory ?? ".", isDirectory: true
                ).standardizedFileURL
                let args = manifest.arguments + (manifest.supportsArguments ? invocation.arguments : [])
                return await AgentHarnessCommandRunner.run(
                    executable: manifest.executable,
                    arguments: args,
                    workingDirectory: workingDirectory,
                    checkoutRoot: checkout
                )
            }
            guard let executable = AgentHarnessExecutableProbe.locate(harness: harness) else {
                return AgentCommandExecutionResult(
                    status: .refused("\(harness.rawValue) executable is unavailable"),
                    summary: "Install or select the \(harness.rawValue) CLI in Command Center."
                )
            }
            return await AgentHarnessCommandRunner.run(
                executable: executable.path,
                arguments: [invocation.name] + invocation.arguments,
                workingDirectory: checkout,
                checkoutRoot: checkout
            )
        }
        // Native slash commands are dispatched through AgentSupervisor.  The
        // adapter deliberately does not invent a second execution path.
        return AgentCommandExecutionResult(
            status: .completed,
            summary: invocation.nativeSlashText
        )
    }

    public func cancel(_ invocation: AgentCommandInvocation, context: AgentCompletionContext?) async {
        // Provider turns are supervisor-owned.  This no-op is intentional and
        // gives callers one cancellation seam for both native and CLI actions.
    }

    private static func merge(_ descriptors: [AgentCommandDescriptor]) -> [AgentCommandDescriptor] {
        var byID: [String: AgentCommandDescriptor] = [:]
        for descriptor in descriptors {
            byID[descriptor.id] = descriptor
        }
        return byID.values.sorted {
            if $0.scope != $1.scope { return scopeRank($0.scope) < scopeRank($1.scope) }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func scopeRank(_ scope: AgentCompletionScope) -> Int {
        switch scope {
        case .system: return 0
        case .project: return 1
        case .personal: return 2
        default: return 3
        }
    }
}

public enum AgentHarnessCommandAdapters {
    public static func make(harness: AgentHarness) -> any AgentHarnessCommandAdapter {
        AgentBaselineHarnessCommandAdapter(harness: harness)
    }

    public static func all() -> [any AgentHarnessCommandAdapter] {
        AgentHarness.allCases.map(make(harness:))
    }
}

/// Metadata-only executable probe.  It uses argv directly and never invokes a
/// shell, which keeps provider discovery safe even when PATH contains spaces or
/// user-controlled characters.
public enum AgentHarnessExecutableProbe {
    public static func locate(harness: AgentHarness, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let name: String
        switch harness {
        case .claudeCode: name = "claude"
        case .codex: name = "codex"
        case .pi: name = "pi"
        }
        let path = environment["PATH"] ?? ""
        for directory in path.split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.standardizedFileURL }
        }
        return nil
    }

    public static func version(for executable: URL) -> String? {
        #if os(macOS) || os(Linux)
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(1.5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning { process.terminate() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init)
        return firstLine?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        #else
        return nil
        #endif
    }
}

/// A host-local cache for probe metadata.  The cache intentionally stores no
/// prompt text, skill bodies, environment values, or secrets.  Entries are
/// keyed by harness, executable, version, checkout, and resource fingerprint.
public enum AgentHarnessCommandCache {
    private struct Record: Codable {
        let harness: AgentHarness
        let executablePath: String?
        let version: String?
        let checkoutRoot: String?
        let resourceFingerprint: String
        let commands: [AgentCommandDescriptor]
        let refreshedAt: Date

        init(
            harness: AgentHarness,
            executablePath: String?,
            version: String?,
            checkoutRoot: String?,
            resourceFingerprint: String,
            commands: [AgentCommandDescriptor],
            refreshedAt: Date
        ) {
            self.harness = harness
            self.executablePath = executablePath
            self.version = version
            self.checkoutRoot = checkoutRoot
            self.resourceFingerprint = resourceFingerprint
            self.commands = commands
            self.refreshedAt = refreshedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            harness = try container.decode(AgentHarness.self, forKey: .harness)
            executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath)
            version = try container.decodeIfPresent(String.self, forKey: .version)
            checkoutRoot = try container.decodeIfPresent(String.self, forKey: .checkoutRoot)
            resourceFingerprint = try container.decode(String.self, forKey: .resourceFingerprint)
            // Entries written before descriptor caching remain valid; they
            // simply fall back to the static provider baseline.
            commands = try container.decodeIfPresent([AgentCommandDescriptor].self, forKey: .commands) ?? []
            refreshedAt = try container.decode(Date.self, forKey: .refreshedAt)
        }
    }

    public static func store(snapshot: AgentCommandProbeSnapshot, context: AgentCompletionContext?) {
        let checkout = context?.checkoutRoot.standardizedFileURL.path
        let fingerprint = resourceFingerprint(context: context)
        let record = Record(
            harness: snapshot.harness,
            executablePath: snapshot.executableURL?.standardizedFileURL.path,
            version: snapshot.version,
            checkoutRoot: checkout,
            resourceFingerprint: fingerprint,
            commands: snapshot.commands,
            refreshedAt: snapshot.refreshedAt
        )
        guard let directory = cacheDirectory() else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let key = [snapshot.harness.rawValue, record.executablePath ?? "", record.version ?? "", checkout ?? "", fingerprint].joined(separator: "\n")
            let path = directory.appendingPathComponent("\(stableHash(key)).json")
            let data = try JSONEncoder().encode(record)
            try data.write(to: path, options: .atomic)
        } catch {
            // Discovery remains useful when Application Support is read-only.
        }
    }

    public static func cachedSnapshot(
        harness: AgentHarness,
        context: AgentCompletionContext?
    ) -> AgentCommandProbeSnapshot? {
        guard let directory = cacheDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
              ) else { return nil }
        let checkout = context?.checkoutRoot.standardizedFileURL.path
        let fingerprint = resourceFingerprint(context: context)
        let candidates = files.compactMap { url -> Record? in
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  record.harness == harness,
                  record.checkoutRoot == checkout,
                  record.resourceFingerprint == fingerprint else { return nil }
            return record
        }
        guard let record = candidates.max(by: { $0.refreshedAt < $1.refreshedAt }) else { return nil }
        return AgentCommandProbeSnapshot(
            harness: harness,
            executableURL: record.executablePath.map { URL(fileURLWithPath: $0) },
            version: record.version,
            commands: record.commands.isEmpty ? AgentCommandCatalog.baseline(for: harness) : record.commands,
            refreshedAt: record.refreshedAt,
            diagnostics: ["Loaded cached provider metadata"]
        )
    }

    private static func cacheDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Array/command-catalogs", isDirectory: true)
    }

    private static func resourceFingerprint(context: AgentCompletionContext?) -> String {
        guard let checkout = context?.checkoutRoot else { return "no-checkout" }
        let roots = [".claude", ".codex", ".pi", ".agents", ".array/commands"]
        var values: [String] = []
        for relative in roots {
            let url = checkout.appendingPathComponent(relative)
            guard let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let file as URL in enumerator {
                guard let valuesForURL = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
                values.append("\(file.path):\(valuesForURL.contentModificationDate?.timeIntervalSince1970 ?? 0):\(valuesForURL.fileSize ?? 0)")
            }
        }
        return stableHash(values.sorted().joined(separator: "\n"))
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(hash, radix: 16)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
