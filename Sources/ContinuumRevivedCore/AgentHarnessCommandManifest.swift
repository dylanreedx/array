import Foundation

public enum AgentCommandApprovalPolicy: String, Codable, CaseIterable, Sendable {
    case automatic
    case confirm
}

/// Opt-in Array-native command manifest.  This is deliberately narrower than a
/// shell script: an executable plus an argv array, a checkout-relative cwd, and
/// explicit capabilities.  Arbitrary `scripts/` files are never auto-exposed.
public struct AgentHarnessCommandManifest: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String?
    public let capabilities: Set<AgentCommandCapability>
    public let approval: AgentCommandApprovalPolicy
    public let supportsArguments: Bool

    public init(
        name: String,
        description: String,
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        capabilities: Set<AgentCommandCapability> = [.processControl],
        approval: AgentCommandApprovalPolicy = .confirm,
        supportsArguments: Bool = false
    ) {
        self.name = name
        self.description = description
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.capabilities = capabilities
        self.approval = approval
        self.supportsArguments = supportsArguments
    }

    public var isSafeShape: Bool {
        guard !name.isEmpty, !executable.isEmpty,
              !executable.contains("\n"), !executable.contains("\r"),
              !arguments.contains(where: { $0.contains("\n") || $0.contains("\r") }) else { return false }
        if let workingDirectory {
            guard !workingDirectory.hasPrefix("/"), !workingDirectory.split(separator: "/").contains("..") else { return false }
        }
        return true
    }
}

public enum AgentHarnessCommandManifestDiscovery {
    public static func discover(context: AgentCompletionContext?) -> [AgentCommandDescriptor] {
        guard let checkout = context?.checkoutRoot else { return [] }
        let root = checkout.appendingPathComponent(".array/commands", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let manifest = try? JSONDecoder().decode(AgentHarnessCommandManifest.self, from: data),
                      manifest.isSafeShape else { return nil }
                let name = manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: " ", with: "-").lowercased()
                guard !name.isEmpty else { return nil }
                var capabilities = manifest.capabilities
                if manifest.approval == .confirm { capabilities.insert(.processControl) }
                return AgentCommandDescriptor(
                    id: "array:manifest:\(name)",
                    name: name,
                    detail: manifest.description,
                    argumentHint: manifest.supportsArguments ? "arguments" : nil,
                    harness: nil,
                    scope: .project,
                    sourceIdentifier: url.path,
                    surface: .cli,
                    capabilities: capabilities,
                    availability: .available,
                    supportsArguments: manifest.supportsArguments,
                    supportsQueueing: true,
                    runsImmediately: true
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func manifest(
        for descriptorID: String,
        context: AgentCompletionContext?
    ) -> AgentHarnessCommandManifest? {
        guard let descriptor = discover(context: context).first(where: { $0.id == descriptorID }),
              let data = try? Data(contentsOf: URL(fileURLWithPath: descriptor.sourceIdentifier)),
              let manifest = try? JSONDecoder().decode(AgentHarnessCommandManifest.self, from: data),
              manifest.isSafeShape else { return nil }
        return manifest
    }

    public static func invoke(
        _ invocation: AgentCommandInvocation,
        context: AgentCompletionContext?
    ) async -> AgentCommandExecutionResult {
        guard let checkout = context?.checkoutRoot.standardizedFileURL,
              let manifest = manifest(for: invocation.descriptorID, context: context) else {
            return AgentCommandExecutionResult(
                status: .refused("Command manifest is unavailable"),
                summary: "Refresh the project command catalog and try again."
            )
        }
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
}
