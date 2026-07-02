import Foundation

public struct LaunchProfileRegistry: Sendable {
    private let specs: [LaunchProfileSpec]

    public init() {
        self.specs = LaunchProfileRegistry.builtIns
    }

    public init(specs: [LaunchProfileSpec]) {
        self.specs = specs
    }

    public func all() -> [LaunchProfileSpec] { specs }

    public func spec(for id: String) -> LaunchProfileSpec? {
        specs.first { $0.id == id }
    }

    public func resolve(
        _ spec: LaunchProfileSpec,
        in cwd: String,
        environment: [String: String],
        detector: ToolDetector
    ) -> LaunchProfileResolution {
        switch spec.kind {
        case .shell:
            guard let profile = try? ShellLaunchResolver(environment: environment).resolveShell(cwd: cwd) else {
                return .missing(executableName: "shell")
            }
            return .found(LaunchProfile(
                command: profile.command,
                arguments: profile.arguments,
                cwd: profile.cwd,
                title: spec.title
            ))

        case let .tool(executableName, args):
            let dirs = ToolDetector.splitPath(environment["PATH"] ?? "")
            guard let resolved = detector.locate(executableName, in: dirs) else {
                return .missing(executableName: executableName)
            }
            return .found(LaunchProfile(
                command: resolved,
                arguments: args,
                cwd: cwd,
                title: spec.title
            ))

        case .custom:
            return .notConfigured(profileId: spec.id)
        }
    }

    private static let builtIns: [LaunchProfileSpec] = [
        LaunchProfileSpec(
            id: "shell",
            displayName: "Shell",
            kind: .shell,
            title: "Shell"
        ),
        LaunchProfileSpec(
            id: "claude",
            displayName: "New Claude Agent",
            kind: .tool(executableName: "claude", args: []),
            title: "Agent · Claude",
            agentKind: .claude
        ),
        LaunchProfileSpec(
            id: "codex",
            displayName: "New Codex Agent",
            kind: .tool(executableName: "codex", args: []),
            title: "Agent · Codex",
            agentKind: .codex
        ),
        LaunchProfileSpec(
            id: "nvim",
            displayName: "Neovim",
            kind: .tool(executableName: "nvim", args: ["."]),
            title: "Neovim"
        ),
        LaunchProfileSpec(
            id: "custom",
            displayName: "Custom Command",
            kind: .custom,
            title: "Custom"
        )
    ]
}
