import Foundation
import ContinuumRevivedCore

func runCodexHookBridgeChecks() {
    #if os(macOS)
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("codex-hook-check-\(UUID().uuidString)")
    try! fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let fixture = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("scripts/fixtures/codex-hook-cli.py")
    let codex = root.appendingPathComponent("codex")
    try! fm.copyItem(at: fixture, to: codex)
    let previousPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let keys = ["ARRAY_HOOK_FIXTURE_LOG", "ARRAY_HOOK_FIXTURE_MISSING", "ARRAY_HOOK_FIXTURE_UNTRUSTED", "CONTINUUM_CODEX_TRANSPORT"]
    let previous = keys.map { ProcessInfo.processInfo.environment[$0] }
    setenv("PATH", root.path + ":" + previousPath, 1)
    setenv("CONTINUUM_CODEX_TRANSPORT", "app-server", 1)
    defer {
        setenv("PATH", previousPath, 1)
        for (key, value) in zip(keys, previous) {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
    }
    let log = root.appendingPathComponent("argv.jsonl")
    setenv("ARRAY_HOOK_FIXTURE_LOG", log.path, 1)
    let config = WorkspaceMCPConfiguration(serverExecutable: "/usr/bin/true", endpoint: "http://127.0.0.1:1",
                                            agentID: "fixture-agent", token: "never-in-argv", directory: root)
    let command = PiAgentRunner.ResolvedCommand(executable: codex.path, prefixArgs: [])
    let catalog = AgentHookSurfaceCatalog()
    let prepared = catalog.codexOverrides(command: command, hookCommand: config.claudeHookCommand)
    expect(prepared.count == 8, "Codex probe must obtain seven definitions and exact trusted-hash state")
    expect(catalog.snapshot(for: .codex)?.available == true, "probe exposes supported capability")
    let runner = CodexAgentRunner(config: .init(model: "fixture", cwd: root, workspaceMCP: config))
    do { try runner.run(prompt: AgentPrompt(text: "tiny fixture")) { _ in } }
    catch { expect(false, "Codex real runner failed: \(error)") }
    let lines = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n") ?? []
    let args = lines.last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] } ?? []
    expect(prepared.allSatisfy(args.contains), "real Codex launch omitted verified hook config/trust: \(args)")
    expect(!args.contains { $0.contains("bypass_hook_trust") || $0.contains("bypass-hook-trust") || $0.contains("never-in-argv") }, "trust bypass or token leaked")
    setenv("ARRAY_HOOK_FIXTURE_MISSING", "1", 1)
    expect(catalog.codexOverrides(command: command, hookCommand: config.claudeHookCommand).isEmpty, "missing surface must omit hooks")
    expect(catalog.snapshot(for: .codex)?.available == false, "missing surface must be observable")
    do { try CodexAgentRunner(config: .init(model: "fixture", cwd: root, workspaceMCP: config)).run(prompt: AgentPrompt(text: "old fixture")) { _ in } }
    catch { expect(false, "unsupported CLI must still run: \(error)") }
    let oldLines = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n") ?? []
    let oldArgs = oldLines.last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] } ?? []
    expect(!oldArgs.isEmpty && !oldArgs.contains { $0.hasPrefix("hooks.") }, "unsupported CLI got hook wiring")
    let claudeFixture = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("scripts/fixtures/claude-hook-cli.py")
    let claudeCommand = PiAgentRunner.ResolvedCommand(executable: claudeFixture.path, prefixArgs: [])
    expect(!catalog.claudeAvailable(command: claudeCommand), "Claude missing a required event must fail open")
    try! fm.copyItem(at: claudeFixture, to: root.appendingPathComponent("claude"))
    func runClaudeFixture() -> [String] {
        let runner = ClaudeAgentRunner(config: .init(model: "fixture", cwd: root, sessionId: UUID().uuidString,
            conversationMayExist: false, workspaceMCP: config))
        defer { runner.stop() }
        do { try runner.run(prompt: "fixture") { _ in } }
        catch { expect(false, "Claude production runner failed: \(error)") }
        let lines = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n") ?? []
        return lines.last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] } ?? []
    }
    let missingClaudeArgs = runClaudeFixture()
    expect(!missingClaudeArgs.isEmpty && !missingClaudeArgs.contains("--settings"), "unsupported Claude launch must omit hooks")
    unsetenv("ARRAY_HOOK_FIXTURE_MISSING")
    expect(catalog.claudeAvailable(command: claudeCommand), "Claude listing plus real SessionStart smoke must qualify")
    expect(catalog.snapshot(for: .claudeCode)?.events == WorkspaceAgentHook.claudeEvents, "Claude exposes seven events for installed version")
    expect(runClaudeFixture().contains("--settings"), "supported Claude launch must carry hooks")
    setenv("ARRAY_HOOK_FIXTURE_UNTRUSTED", "1", 1)
    expect(AgentHookSurfaceCatalog().codexOverrides(command: command, hookCommand: config.claudeHookCommand).isEmpty,
           "Codex must omit hooks when trusted-hash verification fails; no bypass fallback")
    unsetenv("ARRAY_HOOK_FIXTURE_UNTRUSTED")
    let claude = ClaudeAgentRunner.processArguments(model: "fixture", effort: nil, sessionMode: .start,
        sessionId: UUID().uuidString, extraArgs: [], workspaceMCP: config, hookSurfaceAvailable: false)
    expect(!claude.contains("--settings") && claude.contains("--mcp-config"), "unsupported Claude must keep MCP and omit hooks")
    #endif
    print("Codex hook bridge checks passed: real runner argv, exact per-command trust, unsupported surfaces fail open")
}
