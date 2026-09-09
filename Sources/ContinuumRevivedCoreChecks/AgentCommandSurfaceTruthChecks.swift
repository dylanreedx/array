import ContinuumRevivedCore
import Foundation

/// TR-04 — what the slash menu OFFERS and what dispatch can DO are one set.
///
/// Three separate failures shared one shape: the surface advertised something
/// nothing behind it could perform.
///
///  1. `AgentCommandCompletionProvider` offered
///     `allBaselines() + discovered + manifests`; `AgentSupervisor.accept`
///     resolved out of `allBaselines()` alone. Every discovered skill, prompt
///     template, extension and `.array/commands` manifest was an enabled row
///     whose dispatch ended in a bare "unsupported".
///  2. Nine of the thirteen `.array` commands had no implementation at all.
///     They presented as enabled, accepted, and echoed their own one-line
///     DESCRIPTION back as a system notice — `/model` answered "Choose the
///     active model" and changed no model.
///  3. Every `.cli` row said "Run from Array Command Center" about a route that
///     does not exist: `AgentHarnessCommandManifestDiscovery.invoke` and
///     `AgentHarnessCommandRunner.run` have no production callers.
func runAgentCommandSurfaceTruthChecks() throws {
    struct CheckError: Error, CustomStringConvertible { let description: String }
    func fail(_ message: String) -> CheckError {
        CheckError(description: "command surface truth: \(message)")
    }

    // MARK: 1 · an Array-owned command is offered only if Array implements it

    let arrayCommands = AgentCommandCatalog.arrayCommands()
    guard !arrayCommands.isEmpty else { throw fail("the Array baseline is empty") }
    for descriptor in arrayCommands where descriptor.surface == .array {
        let implemented = AgentCommandCatalog.implementedArrayCommandNames.contains(descriptor.name)
        guard descriptor.isEnabled == implemented else {
            throw fail("/\(descriptor.name) is \(descriptor.isEnabled ? "offered" : "hidden") but \(implemented ? "is" : "is not") implemented")
        }
        if !implemented {
            guard descriptor.disabledReason == AgentCommandCatalog.unimplementedArrayReason else {
                throw fail("/\(descriptor.name) has no implementation and no honest reason, got \(String(describing: descriptor.disabledReason))")
            }
        }
    }
    // The specific nine that used to lie. Named literally so that "implement it"
    // and "stop offering it" are both green, and "quietly re-enable it" is not.
    for name in ["plan", "model", "resume", "fork", "diff", "review", "goal"] {
        guard let descriptor = arrayCommands.first(where: { $0.name == name }) else {
            throw fail("the Array baseline lost /\(name)")
        }
        guard !descriptor.isEnabled else {
            throw fail("/\(name) is offered again — either implement it and add it to implementedArrayCommandNames, or leave it disabled")
        }
    }

    // MARK: 2 · a `.cli` row names no route that does not exist

    let context = AgentCompletionContext(
        agentID: AgentID(rawValue: UUID()),
        backend: .claudeCode,
        checkoutRoot: FileManager.default.temporaryDirectory,
        arrayProjectRoot: FileManager.default.temporaryDirectory,
        trustState: .trusted
    )
    for descriptor in AgentCommandCatalog.offeredDescriptors(context: context)
    where descriptor.surface == .cli && descriptor.harness == nil {
        guard descriptor.disabledReason == AgentCommandCatalog.cliSurfaceReason else {
            throw fail("/\(descriptor.name) still points at a route: \(String(describing: descriptor.disabledReason))")
        }
    }
    guard !AgentCommandCatalog.cliSurfaceReason.localizedCaseInsensitiveContains("command center") else {
        throw fail("the CLI-surface reason still names Command Center, which has no command route")
    }

    // MARK: 3 · every enabled row resolves, including discovered resources

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("array-command-surface-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let commands = root.appendingPathComponent(".claude/commands", isDirectory: true)
    let manifests = root.appendingPathComponent(".array/commands", isDirectory: true)
    try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: manifests, withIntermediateDirectories: true)
    try """
    ---
    name: tr04-project-command
    description: A project command discovered from .claude/commands
    ---
    Do the thing.
    """.write(to: commands.appendingPathComponent("tr04-project-command.md"), atomically: true, encoding: .utf8)
    // Every key: `AgentHarnessCommandManifest`'s synthesized `Decodable` does
    // not fall back to the memberwise initializer's defaults.
    try """
    {"name":"tr04-manifest","description":"A project manifest command",\
    "executable":"/bin/echo","arguments":["hi"],"capabilities":["processControl"],\
    "approval":"confirm","supportsArguments":false}
    """.write(to: manifests.appendingPathComponent("tr04.json"), atomically: true, encoding: .utf8)

    let discoveredContext = AgentCompletionContext(
        agentID: AgentID(rawValue: UUID()),
        backend: .claudeCode,
        checkoutRoot: root,
        arrayProjectRoot: root,
        trustState: .trusted
    )
    let offered = AgentCommandCatalog.offeredDescriptors(context: discoveredContext)
    guard offered.contains(where: { $0.name == "tr04-project-command" }) else {
        throw fail("the discovered project command did not reach the offered set")
    }
    guard offered.contains(where: { $0.name == "tr04-manifest" }) else {
        throw fail("the discovered manifest command did not reach the offered set")
    }
    // The load-bearing assertion: everything the menu can offer, dispatch can
    // find, BY THE SAME ID and with the SAME verdict.
    for descriptor in offered {
        guard let resolved = AgentCommandCatalog.resolve(
            descriptorID: descriptor.id, context: discoveredContext) else {
            throw fail("offered row /\(descriptor.name) (\(descriptor.id)) does not resolve for dispatch")
        }
        guard resolved.availability == descriptor.availability else {
            throw fail("/\(descriptor.name) resolves with a different availability than the menu showed")
        }
    }

    // MARK: 4 · discovery narrows a real, discovered command too

    guard let projectCommand = offered.first(where: { $0.name == "tr04-project-command" }) else {
        throw fail("lost the discovered project command")
    }
    var advertised = AgentSessionCommandCapabilities.claudeOneShot
    advertised.advertisedNames = ["compact"]
    let narrowed = AgentCommandExecutionPlanner.resolve(projectCommand, capabilities: advertised)
    if case .unavailable = narrowed {} else {
        throw fail("a discovered command the harness did not advertise must be disabled, got \(narrowed)")
    }
    advertised.advertisedNames = ["compact", "tr04-project-command"]
    guard AgentCommandExecutionPlanner.resolve(projectCommand, capabilities: advertised) == .skillTemplate else {
        throw fail("an advertised discovered command must expand as a real turn")
    }

    print("Agent command surface truth checks passed: Array-owned commands offered only where implemented, CLI rows naming no phantom route, every offered row resolvable for dispatch with the same verdict, and discovery narrowing discovered resources")
}
