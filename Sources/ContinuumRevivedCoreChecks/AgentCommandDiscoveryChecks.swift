import ContinuumRevivedCore
import Foundation

/// TR-04 — the harness's own command list actually reaches the classifier.
///
/// `AgentSessionCommandCapabilities.advertisedNames` documented itself as coming
/// from claude's `slash_commands` on `system/init`, and
/// `AgentCommandExecutionPlanner` had a branch that refuses anything outside it.
/// Nothing in the app had ever read the key. The list was nil in every code path
/// that has ever run, the refusal branch was unreachable, and all 34 baseline
/// claude commands — including the ones that only mean anything inside claude's
/// own TUI — were serialized and sent as ordinary prompts.
///
/// This drives the REAL translator over a real init line, not a hand-built
/// capability struct: the planner's own checks were green throughout the whole
/// period the plumbing did not exist.
func runAgentCommandDiscoveryChecks() throws {
    struct CheckError: Error, CustomStringConvertible { let description: String }
    func fail(_ message: String) -> CheckError {
        CheckError(description: "command discovery: \(message)")
    }

    // MARK: 1 · claude publishes its commands on system/init and Array keeps them

    final class ObservationSink: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [AgentRuntimeObservation] = []
        func append(_ observation: AgentRuntimeObservation) {
            lock.lock(); values.append(observation); lock.unlock()
        }
        var observations: [AgentRuntimeObservation] { lock.lock(); defer { lock.unlock() }; return values }
    }

    let sink = ObservationSink()
    var translator = ClaudeEventTranslator(workingDirectory: URL(fileURLWithPath: "/tmp"))
    translator.onRuntimeObservation = { sink.append($0) }
    let initLine = """
    {"type":"system","subtype":"init","session_id":"tr04-session","model":"claude-opus-5",\
    "cwd":"/tmp","slash_commands":["compact","context","some-plugin:review","  "]}
    """
    _ = translator.translate(line: initLine)
    let observations = sink.observations
    let advertised = observations.compactMap { observation -> [String]? in
        guard case let .advertisedCommands(names) = observation else { return nil }
        return names
    }
    guard let names = advertised.first else {
        throw fail("system/init carried slash_commands and no advertisedCommands observation was emitted")
    }
    guard names == ["compact", "context", "some-plugin:review"] else {
        throw fail("advertised names were not carried verbatim minus blanks, got \(names)")
    }
    // Same line, and the facts that already worked must still work — an init
    // parser is easy to break by adding to it.
    guard observations.contains(.providerSessionId("tr04-session")),
          observations.contains(.resolvedModel("anthropic/claude-opus-5")) else {
        throw fail("adding slash_commands broke session-id or resolved-model capture")
    }

    // An init WITHOUT the key must leave the list undiscovered, not empty: nil
    // means "answer from the baseline catalogue" and an empty set means "this
    // session has no commands", and confusing the two disables everything.
    var quiet = ClaudeEventTranslator(workingDirectory: URL(fileURLWithPath: "/tmp"))
    let quietSink = ObservationSink()
    quiet.onRuntimeObservation = { quietSink.append($0) }
    _ = quiet.translate(line: """
    {"type":"system","subtype":"init","session_id":"tr04-quiet","cwd":"/tmp"}
    """)
    guard !quietSink.observations.contains(where: {
        if case .advertisedCommands = $0 { return true }
        return false
    }) else {
        throw fail("an init with no slash_commands key must not report a discovered list")
    }

    // MARK: 2 · the narrowing that list unlocks

    var capabilities = AgentSessionCommandCapabilities.claudeOneShot
    capabilities.advertisedNames = Set(names)
    let known = AgentCommandDescriptor(
        id: "check.context", name: "context", sourceIdentifier: "discovery-check", surface: .providerSlash)
    let unknown = AgentCommandDescriptor(
        id: "check.hooks", name: "hooks", sourceIdentifier: "discovery-check", surface: .providerSlash)
    guard AgentCommandExecutionPlanner.resolve(known, capabilities: capabilities) == .harnessDelegated else {
        throw fail("an advertised command must stay delegated")
    }
    if case .unavailable = AgentCommandExecutionPlanner.resolve(unknown, capabilities: capabilities) {} else {
        throw fail("a command claude did not advertise must be disabled once the list exists")
    }
    // And with no list at all it stays delegated — refusing on a missing list
    // would disable every command until the first turn had run.
    guard AgentCommandExecutionPlanner.resolve(unknown, capabilities: .claudeOneShot) == .harnessDelegated else {
        throw fail("before discovery the baseline catalogue must answer")
    }

    // MARK: 3 · pi's get_commands parse fails OPEN

    // Unlike every other entry in `PiRpcCommand.knownTypes`, `get_commands`'
    // response shape was never measured. Adopting an empty set on a shape we
    // guessed wrong would disable EVERY pi slash command, which is strictly
    // worse than the frozen baseline it replaces.
    for unrecognised: [String: Any] in [
        [:],
        ["something": "else"],
        ["commands": []],
        ["commands": [[:] as [String: Any]]],
        ["result": ["commands": []]],
    ] {
        guard PiRpcAgentRunner.parseAdvertisedCommands(unrecognised) == nil else {
            throw fail("an unrecognised or empty get_commands response must leave discovery undone, not empty")
        }
    }
    for recognised: [String: Any] in [
        ["commands": ["compact", "fork"]],
        ["result": ["commands": ["compact", "fork"]]],
        ["result": ["compact", "fork"]],
        ["commands": [["name": "compact"], ["command": "fork"]]],
    ] {
        guard PiRpcAgentRunner.parseAdvertisedCommands(recognised) == ["compact", "fork"] else {
            throw fail("a recognised get_commands response was not parsed, got \(String(describing: PiRpcAgentRunner.parseAdvertisedCommands(recognised)))")
        }
    }

    print("Agent command discovery checks passed: claude's slash_commands parsed off the real init line without disturbing session id or model, an absent key left undiscovered rather than empty, the narrowing branch reachable at last, and pi's unmeasured get_commands parse failing open")
}
