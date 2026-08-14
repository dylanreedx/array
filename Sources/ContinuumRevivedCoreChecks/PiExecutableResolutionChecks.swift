import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/88-provider-adapter-pi-gpt.md (slice 88.4b)
//
// Pins PiAgentRunner's executable resolution — the GUI PATH fix. A shell
// launch inherits a full PATH; a GUI-launched .app gets a thin PATH
// (/usr/bin:/bin:/usr/sbin:/sbin) that omits nvm/homebrew, so `/usr/bin/env
// pi` fails to find Pi. The resolver prefers an absolute `pi` from either the
// process PATH or the well-known install dirs, and only falls back to
// `/usr/bin/env pi` when nothing is found.
func runPiExecutableResolutionChecks() {
    typealias Runner = PiAgentRunner

    // 1. GUI case: pi is NOT on the (thin) PATH but IS in an extra dir (nvm
    //    bin). The resolver must return the absolute path so the app finds it.
    let nvmBin = "/Users/x/.nvm/versions/node/v22.22.2/bin"
    let guiResolved = Runner.resolvedCommand(
        pathDirs: ["/usr/bin", "/bin", "/usr/sbin", "/sbin"],
        extraDirs: [nvmBin, "/opt/homebrew/bin"],
        fileExists: { $0 == "\(nvmBin)/pi" }
    )
    expect(guiResolved == .init(executable: "\(nvmBin)/pi", prefixArgs: []),
           "resolvedCommand (GUI): must resolve pi absolutely from an extra dir, got \(guiResolved)")

    // 2. PATH wins over extra dirs when pi is on PATH (shell launch), and is
    //    still returned as an absolute path (no env indirection needed).
    let shellResolved = Runner.resolvedCommand(
        pathDirs: ["/usr/local/bin", "/usr/bin"],
        extraDirs: [nvmBin],
        fileExists: { $0 == "/usr/local/bin/pi" || $0 == "\(nvmBin)/pi" }
    )
    expect(shellResolved == .init(executable: "/usr/local/bin/pi", prefixArgs: []),
           "resolvedCommand (PATH): earliest PATH dir wins, got \(shellResolved)")

    // 3. Nowhere on disk: fall back to `/usr/bin/env pi` (still works for a
    //    shell that inherits a full PATH the resolver can't see via fileExists).
    let missing = Runner.resolvedCommand(
        pathDirs: ["/usr/bin", "/bin"],
        extraDirs: [nvmBin],
        fileExists: { _ in false }
    )
    expect(missing == .init(executable: "/usr/bin/env", prefixArgs: ["pi"]),
           "resolvedCommand (missing): must fall back to /usr/bin/env pi, got \(missing)")

    // 4. PATH augmentation: pi is a node script, so the child needs node on
    //    PATH too. augmentedPath prepends the install dirs a GUI launch omits,
    //    preserving order and de-duping ones already present.
    let thin = "/usr/bin:/bin:/usr/sbin:/sbin"
    let augmented = Runner.augmentedPath(basePath: thin, extraDirs: [nvmBin, "/opt/homebrew/bin", "/usr/bin"])
    expect(augmented == "\(nvmBin):/opt/homebrew/bin:\(thin)",
           "augmentedPath: extra dirs prepend in order, already-present /usr/bin not duplicated, got \(augmented)")

    // Empty extras is a no-op; empty base still yields the extras.
    expect(Runner.augmentedPath(basePath: thin, extraDirs: []) == thin,
           "augmentedPath: no extras leaves PATH unchanged")
    expect(Runner.augmentedPath(basePath: "", extraDirs: [nvmBin]) == nvmBin,
           "augmentedPath: empty base yields just the extra dir")

    // 5. Every managed provider uses this shared environment constructor. The
    // marker lets self-hosted repositories defer only deliberate crash
    // subprocesses without weakening an ordinary external matrix run.
    let childEnvironment = Runner.childEnvironment(
        base: ["PATH": thin, "PRESERVE": "yes"],
        extraDirs: [nvmBin])
    expect(childEnvironment[Runner.arrayHostedEnvironmentKey] == "1",
           "childEnvironment: managed descendants must be marked as Array-hosted")
    expect(childEnvironment["PATH"] == "\(nvmBin):\(thin)" && childEnvironment["PRESERVE"] == "yes",
           "childEnvironment: PATH augmentation must preserve unrelated inherited values")
    expect(!coreCheckCrashWitnessesEnabled(environment: childEnvironment),
           "CoreChecks must suppress deliberate crash witnesses under an Array-managed agent")
    expect(coreCheckCrashWitnessesEnabled(environment: [:]),
           "ordinary external CoreChecks must retain deliberate crash witnesses")

    print("PiAgentRunner executable-resolution checks passed: GUI absolute resolve, PATH precedence, env fallback, PATH augmentation, self-host marker")
}

// 88.5: a stable sessionId makes prompts continue the same conversation
// (--session-id); nil is ephemeral (--no-session).
func runPiSessionArgsChecks() {
    typealias Runner = PiAgentRunner

    // P0.10: the model is the fully-qualified id from AgentModelConfig (no fuzzy
    // matching), and the thinking level is passed explicitly.
    let model = AgentModelConfig.defaultModel
    let thinking = AgentModelConfig.defaultThinking

    let withSession = Runner.processArguments(
        model: model, thinking: thinking, sessionId: "continuum-TILE", extraArgs: [], prompt: "hi")
    expect(withSession == ["-p", "--mode", "json", "--model", model, "--thinking", thinking,
                           "--session-id", "continuum-TILE", "hi"],
           "processArguments(session): must pass --model/--thinking then --session-id for continuity, got \(withSession)")

    let ephemeral = Runner.processArguments(
        model: model, thinking: thinking, sessionId: nil, extraArgs: [], prompt: "hi")
    expect(ephemeral == ["-p", "--mode", "json", "--model", model, "--thinking", thinking,
                         "--no-session", "hi"],
           "processArguments(nil): must be ephemeral --no-session, got \(ephemeral)")

    // Prompt is always last (Pi treats the trailing positional as the prompt);
    // extras slot between the session flag and the prompt.
    let withExtras = Runner.processArguments(
        model: "m", thinking: "low", sessionId: "s", extraArgs: ["--tools", "read"], prompt: "do it")
    expect(withExtras.last == "do it" && withExtras.contains("--tools"),
           "processArguments(extras): prompt stays last, extras included, got \(withExtras)")

    print("PiAgentRunner session-args checks passed: --session-id for continuity, --no-session ephemeral, prompt last")
}
