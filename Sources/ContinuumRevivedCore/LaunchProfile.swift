import Foundation

public struct LaunchProfile: Equatable, Sendable {
    public let command: String
    public let arguments: [String]
    public let cwd: String
    public let title: String

    public init(command: String, arguments: [String], cwd: String, title: String) {
        self.command = command
        self.arguments = arguments
        self.cwd = cwd
        self.title = title
    }
}

public enum ShellLaunchResolverError: Error, Equatable {
    case emptyWorkingDirectory
}

public struct ShellLaunchResolver: Sendable {
    private let environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func resolveShell(cwd: String) throws -> LaunchProfile {
        guard !cwd.isEmpty else {
            throw ShellLaunchResolverError.emptyWorkingDirectory
        }

        let shell = environment["SHELL"].flatMap { value in
            value.isEmpty ? nil : value
        } ?? "/bin/zsh"

        return LaunchProfile(
            command: shell,
            arguments: [],
            cwd: cwd,
            title: "Shell"
        )
    }
}
