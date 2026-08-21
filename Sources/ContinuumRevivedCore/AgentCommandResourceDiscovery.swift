import Foundation

/// Metadata-only discovery for provider skill, prompt, command, and extension
/// resources. It never executes a skill body or an extension while indexing.
public enum AgentCommandResourceDiscovery {
    public static func discover(
        context: AgentCompletionContext?,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> [AgentCommandDescriptor] {
        let fileManager = FileManager.default
        var roots: [(URL, AgentHarness?, AgentCompletionScope)] = []

        if let checkout = context?.checkoutRoot.standardizedFileURL {
            // A checkout can inherit provider resources from a parent project
            // (for example a monorepo's `.claude/skills`). Search the checkout
            // first, then its parents, so the stable-ID de-dupe gives the most
            // specific resource precedence without loading prompt bodies.
            var projectRoots: [URL] = [checkout]
            var parent = checkout.deletingLastPathComponent().standardizedFileURL
            for _ in 0..<3 where parent.path != "/" {
                projectRoots.append(parent)
                parent = parent.deletingLastPathComponent().standardizedFileURL
            }
            for projectRoot in projectRoots {
                roots += [
                    (projectRoot.appendingPathComponent(".claude/skills", isDirectory: true), .claudeCode, .project),
                    (projectRoot.appendingPathComponent(".claude/commands", isDirectory: true), .claudeCode, .project),
                    (projectRoot.appendingPathComponent(".claude/plugins", isDirectory: true), .claudeCode, .plugin),
                    (projectRoot.appendingPathComponent(".pi/skills", isDirectory: true), .pi, .project),
                    (projectRoot.appendingPathComponent(".pi/prompts", isDirectory: true), .pi, .project),
                    (projectRoot.appendingPathComponent(".pi/extensions", isDirectory: true), .pi, .project),
                    (projectRoot.appendingPathComponent(".pi/packages", isDirectory: true), .pi, .package),
                    (projectRoot.appendingPathComponent(".agents/skills", isDirectory: true), nil, .project),
                    (projectRoot.appendingPathComponent(".codex/skills", isDirectory: true), .codex, .project),
                ]
            }
        }
        roots += [
            (homeDirectory.appendingPathComponent(".claude/skills", isDirectory: true), .claudeCode, .personal),
            (homeDirectory.appendingPathComponent(".claude/commands", isDirectory: true), .claudeCode, .personal),
            (homeDirectory.appendingPathComponent(".claude/plugins", isDirectory: true), .claudeCode, .plugin),
            (homeDirectory.appendingPathComponent(".pi/agent/skills", isDirectory: true), .pi, .personal),
            (homeDirectory.appendingPathComponent(".pi/agent/prompts", isDirectory: true), .pi, .personal),
            (homeDirectory.appendingPathComponent(".pi/agent/extensions", isDirectory: true), .pi, .personal),
            (homeDirectory.appendingPathComponent(".pi/agent/packages", isDirectory: true), .pi, .package),
            (homeDirectory.appendingPathComponent(".codex/skills", isDirectory: true), .codex, .personal),
        ]

        var results: [AgentCommandDescriptor] = []
        var seen = Set<String>()
        for (root, harness, scope) in roots {
            guard fileManager.fileExists(atPath: root.path), !isSymlink(root) else { continue }
            for url in resourceURLs(in: root, fileManager: fileManager) {
                guard let descriptor = descriptor(for: url, root: root, harness: harness, scope: scope) else { continue }
                guard seen.insert(descriptor.id).inserted else { continue }
                results.append(descriptor)
            }
        }
        return results.sorted {
            if $0.scope != $1.scope { return scopeRank($0.scope) < scopeRank($1.scope) }
            if $0.name != $1.name { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return $0.sourceIdentifier < $1.sourceIdentifier
        }
    }

    private static func resourceURLs(in root: URL, fileManager: FileManager) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var values: [URL] = []
        for case let url as URL in enumerator {
            // Provider package trees can contain generated bundles and nested
            // node_modules. Discovery is metadata-first and must stay cheap
            // enough to run while the user is typing in the composer.
            let pathComponents = url.pathComponents
            if pathComponents.contains(where: { [".git", "node_modules", "dist", "build", ".build"].contains($0) }) {
                enumerator.skipDescendants()
                continue
            }
            guard !isSymlink(url) else {
                enumerator.skipDescendants()
                continue
            }
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            if name == "SKILL.md" || (ext == "md" && root.lastPathComponent == "commands") ||
                (ext == "md" && root.lastPathComponent == "prompts") || ext == "ts" || ext == "js" {
                values.append(url)
                if values.count >= 128 {
                    break
                }
            }
        }
        return values
    }

    private static func descriptor(
        for url: URL,
        root: URL,
        harness: AgentHarness?,
        scope: AgentCompletionScope
    ) -> AgentCommandDescriptor? {
        let extensionName = url.pathExtension.lowercased()
        let isExtension = extensionName == "ts" || extensionName == "js"
        let metadata = isExtension ? Metadata() : parseMetadata(url: url)
        let name = metadata.name ?? commandName(for: url)
        guard !name.isEmpty else { return nil }
        let relative = url.path == root.path ? url.lastPathComponent : String(url.path.dropFirst(root.path.count + 1))
        let normalizedName = name.replacingOccurrences(of: " ", with: "-").lowercased()
        let prefix: String
        switch harness {
        case .claudeCode: prefix = "claude"
        case .codex: prefix = "codex"
        case .pi: prefix = "pi"
        case nil: prefix = "array"
        }
        let components = Set(url.pathComponents.map { $0.lowercased() })
        let surface: AgentCommandSurface
        if isExtension { surface = .extensionCommand }
        else if components.contains("prompts") { surface = .promptTemplate }
        else { surface = .skill }
        let defaultCapabilities: Set<AgentCommandCapability> =
            surface == .promptTemplate || surface == .skill ? [.promptOnly] : [.localWrite]
        let availability: AgentCommandAvailability = isExtension
            ? .requiresTrust("Trust this extension before loading executable code")
            : .available
        return AgentCommandDescriptor(
            id: "\(prefix):\(normalizedName):\(stablePath(relative))",
            name: normalizedName,
            detail: metadata.description ?? "Discovered \(surface.rawValue)",
            argumentHint: metadata.arguments,
            harness: harness,
            scope: scope,
            sourceIdentifier: url.path,
            surface: surface,
            capabilities: defaultCapabilities,
            availability: availability,
            supportsArguments: metadata.arguments != nil,
            supportsQueueing: harness == .codex,
            runsImmediately: false,
            userInvocable: metadata.userInvocable,
            modelInvocable: !metadata.disableModelInvocation,
            contextFork: metadata.contextFork
        )
    }

    private struct Metadata {
        var name: String?
        var description: String?
        var arguments: String?
        var userInvocable = true
        var disableModelInvocation = false
        var contextFork = false
    }

    private static func parseMetadata(url: URL) -> Metadata {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let text = String(data: Data(data.prefix(32 * 1024)), encoding: .utf8) else { return Metadata() }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return Metadata() }
        var metadata = Metadata()
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            switch key {
            case "name": metadata.name = value.isEmpty ? nil : value
            case "description", "when_to_use":
                if metadata.description == nil { metadata.description = value }
            case "arguments": metadata.arguments = value.isEmpty ? nil : value
            case "user-invocable": metadata.userInvocable = value.lowercased() != "false"
            case "disable-model-invocation": metadata.disableModelInvocation = value.lowercased() == "true"
            case "context": metadata.contextFork = value.lowercased() == "fork"
            default: break
            }
        }
        return metadata
    }

    private static func commandName(for url: URL) -> String {
        if url.lastPathComponent == "SKILL.md" { return url.deletingLastPathComponent().lastPathComponent }
        return url.deletingPathExtension().lastPathComponent
    }

    private static func stablePath(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
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
