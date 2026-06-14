import Foundation

public struct HarnessRole: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let promptPath: String
    public let model: String?
    public let reasoning: String?
    public let tools: String?

    public init(id: String, displayName: String, promptPath: String, model: String? = nil, reasoning: String? = nil, tools: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.promptPath = promptPath
        self.model = model
        self.reasoning = reasoning
        self.tools = tools
    }
}

public enum HarnessRoleParser {
    public static func parse(roleFilePaths: [String]) -> [HarnessRole] {
        roleFilePaths
            .filter { $0.hasSuffix(".md") }
            .compactMap { path -> HarnessRole? in
                let url = URL(fileURLWithPath: path)
                let id = url.deletingPathExtension().lastPathComponent
                guard isValidRoleId(id) else { return nil }
                let frontmatter = parseFrontmatter(path: path)
                return HarnessRole(
                    id: id,
                    displayName: displayName(for: frontmatter["name"] ?? id),
                    promptPath: path,
                    model: frontmatter["model"],
                    reasoning: frontmatter["reasoning"],
                    tools: frontmatter["tools"]
                )
            }
            .sorted { $0.id < $1.id }
    }

    private static func parseFrontmatter(path: String) -> [String: String] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "---" else { return [:] }
        lines.removeFirst()
        var fields: [String: String] = [:]
        for line in lines {
            if line == "---" { break }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !value.isEmpty { fields[key] = value }
        }
        return fields
    }

    public static func isValidRoleId(_ id: String) -> Bool {
        guard !id.isEmpty, !id.hasPrefix(".") else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains(scalar)
        }
    }

    public static func displayName(for id: String) -> String {
        id.split(separator: "-")
            .map { token in token.prefix(1).uppercased() + token.dropFirst() }
            .joined(separator: " ")
    }
}

public enum HarnessRoleRunBuilder {
    public static func makeRunId(roleId: String, now: Date, suffix: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let safeSuffix = suffix.filter { $0.isLetter || $0.isNumber }.prefix(6)
        return "\(roleId)-\(formatter.string(from: now))-\(safeSuffix.isEmpty ? "000000" : String(safeSuffix))"
    }

    public static func buildLaunchProfile(role: HarnessRole, prompt: String, projectRoot: String, runId: String) -> LaunchProfile {
        var arguments = [
            "CONTINUUM_HARNESS_RUN_ID=\(runId)",
            "pi",
            "--mode", "json",
            "-p",
            "--no-session"
        ]
        if let model = role.model { arguments += ["--model", model] }
        if let reasoning = role.reasoning { arguments += ["--thinking", reasoning] }
        if let tools = role.tools { arguments += ["--tools", tools] }
        arguments += ["--system-prompt", role.promptPath, prompt]
        return LaunchProfile(
            command: "/usr/bin/env",
            arguments: arguments,
            cwd: projectRoot,
            title: "Agent · \(role.displayName)"
        )
    }
}
