import Foundation

/// The only subprocess seam exposed to Array-native command manifests.  A
/// request carries an argv vector and a checkout-relative working directory;
/// it is never converted to a shell string.  Command Center is responsible for
/// deciding when to call this seam (after approval) and for presenting the
/// returned artifact.
public enum AgentHarnessCommandRunner {
    private static let maximumCapturedBytes = 1_000_000

    public static func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        checkoutRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> AgentCommandExecutionResult {
        let safeRoot = checkoutRoot.standardizedFileURL
        let safeWorkingDirectory = workingDirectory.standardizedFileURL
        guard safeWorkingDirectory.path == safeRoot.path
                || safeWorkingDirectory.path.hasPrefix(safeRoot.path + "/") else {
            return AgentCommandExecutionResult(
                status: .refused("Working directory must remain inside the checkout"),
                summary: "The declared working directory is outside the checkout."
            )
        }
        guard FileManager.default.fileExists(atPath: safeWorkingDirectory.path) else {
            return AgentCommandExecutionResult(
                status: .refused("Working directory does not exist"),
                summary: "The declared working directory is unavailable."
            )
        }
        guard !executable.contains("\n"), !executable.contains("\r"),
              !arguments.contains(where: { $0.contains("\n") || $0.contains("\r") }) else {
            return AgentCommandExecutionResult(
                status: .refused("Command arguments contain a newline"),
                summary: "The command shape is not safe to execute."
            )
        }

        // Every validation above is pure and belongs on both platforms — the shape
        // refusals are part of this seam's contract, and Core is shared with the
        // phone. Only the SPAWN is macOS-only: `Process` does not exist on iOS, and
        // naming it unconditionally broke the iOS build of Core (which a macOS
        // `swift build` cannot see — the matrix's own iOS leg names this exact
        // hazard). The same shape as `AgentModelCatalog`'s probe seam: the platform
        // that cannot execute refuses, rather than the symbol disappearing and
        // taking its callers with it.
        #if os(macOS)
        return await Task.detached(priority: .userInitiated) {
            Self.runBlocking(
                executable: executable,
                arguments: arguments,
                workingDirectory: safeWorkingDirectory,
                environment: Self.sanitizedEnvironment(environment)
            )
        }.value
        #else
        return AgentCommandExecutionResult(
            status: .refused("Running commands is not available on this device"),
            summary: "Array runs harness commands on the Mac that owns the checkout."
        )
        #endif
    }

    #if os(macOS)
    private static func runBlocking(
        executable: String,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]
    ) -> AgentCommandExecutionResult {
        guard let executableURL = resolveExecutable(executable, environment: environment, workingDirectory: workingDirectory) else {
            return AgentCommandExecutionResult(
                status: .refused("Executable is not available"),
                summary: "The requested executable could not be resolved."
            )
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return AgentCommandExecutionResult(
                status: .failed("Unable to start command"),
                summary: error.localizedDescription
            )
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let captured = Data(data.prefix(maximumCapturedBytes))
        let text = String(data: captured, encoding: .utf8) ?? "(command returned non-text output)"
        let artifact = writeArtifact(text: text, executable: executableURL.lastPathComponent)
        let status: AgentCommandExecutionStatus = process.terminationStatus == 0
            ? .completed
            : .failed("Command exited with status \(process.terminationStatus)")
        return AgentCommandExecutionResult(status: status, summary: text, artifactURL: artifact)
    }

    private static func resolveExecutable(
        _ raw: String,
        environment: [String: String],
        workingDirectory: URL
    ) -> URL? {
        if raw.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: raw).standardizedFileURL
            return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
        }
        if raw.contains("/") {
            let candidate = workingDirectory.appendingPathComponent(raw).standardizedFileURL
            return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(raw)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.standardizedFileURL }
        }
        return nil
    }

    private static func sanitizedEnvironment(_ environment: [String: String]) -> [String: String] {
        let allowed = ["PATH", "LANG", "LC_ALL", "TERM", "TMPDIR"]
        return environment.filter { allowed.contains($0.key) }
    }

    private static func writeArtifact(text: String, executable: String) -> URL? {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Array/command-results", isDirectory: true) else { return nil }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let safeName = executable.replacingOccurrences(of: "/", with: "-")
            let path = root.appendingPathComponent("\(safeName)-\(UUID().uuidString).txt")
            try Data(text.utf8).write(to: path, options: .atomic)
            return path
        } catch {
            return nil
        }
    }
    #endif
}
