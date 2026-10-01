import ContinuumRevivedCore
import Foundation

/// 0.7.24: every model Array offers comes from the CLI that runs it.
///
/// Opus 5.5 shipped and the claude picker never showed it, because the claude
/// catalogue was a list typed into the source in 0.7.21 and the default was a
/// literal beside it. Codex and Pi had frozen lists too, served whenever their
/// probe had not answered. These pin the replacement:
///
/// - (A) The claude probe: the REAL spawn, pipe and parse, driven against a
///   fixture executable that speaks claude's `initialize` handshake. It must
///   answer from the handshake without waiting for the CLI to exit, and give up
///   at its timeout when the CLI never answers.
/// - (B) A live app serves only what a CLI reported. A probe that finds nothing
///   leaves a harness EMPTY, never holding the QA fixture; the same instance
///   with live refresh off serves the fixture (the positive control).
/// - (C) The default seed is the CLI's own `default` / `isDefault`.
func runLiveModelCatalogChecks() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("live-model-catalog-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }

    func script(_ name: String, _ body: String) -> PiAgentRunner.ResolvedCommand {
        let url = root.appendingPathComponent(name)
        try? ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        _ = chmod(url.path, 0o755)
        return PiAgentRunner.ResolvedCommand(executable: url.path, prefixArgs: [])
    }

    // (A) A fake claude that checks its argv, answers `initialize` with the real
    // capture after a hook-style frame, then refuses to exit. A probe that waited
    // for EOF would sit out the whole timeout.
    let responseFile = root.appendingPathComponent("initialize.jsonl")
    try? (AgentCatalogQAFixture.claudeInitializeResponse + "\n").write(to: responseFile, atomically: true, encoding: .utf8)
    let argvLog = root.appendingPathComponent("argv.txt")
    let answering = script("claude-answering", """
    echo "$@" > '\(argvLog.path)'
    read -r request
    case "$request" in
      *'"subtype":"initialize"'*) ;;
      *) exit 3 ;;
    esac
    echo '{"type":"system","subtype":"hook_started"}'
    cat '\(responseFile.path)'
    sleep 30
    """)
    let started = Date()
    let probed = AgentModelCatalog.probeClaudeModels(command: answering, timeout: 10)
    let elapsed = Date().timeIntervalSince(started)
    let expected = AgentCatalogQAFixture.claude
    expect(probed?.models == expected.models && probed?.defaultModel == expected.defaultModel,
           "live-models: the claude probe must parse the handshake's answer, got \(String(describing: probed?.models))")
    expect(probed?.models.contains("anthropic/claude-opus-5-5") == true,
           "live-models: Opus 5.5 must reach the catalogue from claude's own answer")
    expect(elapsed < 5,
           "live-models: the probe must return on the answer, not wait for the CLI to exit (took \(elapsed)s)")
    let argv = (try? String(contentsOf: argvLog, encoding: .utf8)) ?? ""
    expect(argv.contains("--input-format stream-json") && argv.contains("disableAllHooks"),
           "live-models: the probe must speak stream-json with hooks disabled, argv was \(argv)")

    let silent = script("claude-silent", "read -r request\nsleep 30\n")
    let silentStarted = Date()
    let silentResult = AgentModelCatalog.probeClaudeModels(command: silent, timeout: 1)
    let silentElapsed = Date().timeIntervalSince(silentStarted)
    expect(silentResult == nil && silentElapsed < 4,
           "live-models: a claude that never answers must time out to nil (got \(String(describing: silentResult?.models)) after \(silentElapsed)s)")

    // (B) Live mode with every probe failing: nothing anywhere.
    let failing = AgentModelCatalog(probeExecutor: { _, _, _ in nil })
    for harness in AgentHarness.allCases {
        expect(!failing.snapshot(for: harness).models.isEmpty,
               "live-models: positive control — with live refresh off, \(harness.rawValue) must serve the QA fixture")
    }
    failing.enableLiveRefresh()
    for _ in 0..<500 where failing.refreshInFlightForQA { Thread.sleep(forTimeInterval: 0.01) }
    for harness in AgentHarness.allCases {
        let snapshot = failing.snapshot(for: harness)
        expect(snapshot.models.isEmpty && snapshot.seedModel == nil,
               "live-models: a live app whose \(harness.rawValue) probe found nothing must offer nothing, served \(snapshot.models)")
    }
    expect(failing.options().isEmpty,
           "live-models: the legacy union must not fall back to the QA fixture in a live app, got \(failing.options())")

    // A live answer is served verbatim, and its default seeds new agents.
    failing.apply(claudeCatalog: expected)
    let live = failing.snapshot(for: .claudeCode)
    expect(live.models == expected.models && live.seedModel == "anthropic/claude-fable-5-1",
           "live-models: claude's answer must be served as-is with its default as the seed, got \(live.models) / \(String(describing: live.seedModel))")

    // (C) Codex names its default with `isDefault`; without one, the first listed.
    let codex = AgentModelCatalog.parseCodexModelListResponse(["data": [
        ["model": "gpt-6-sol", "displayName": "GPT-6-Sol"],
        ["model": "gpt-6-astra", "displayName": "GPT-6-Astra", "isDefault": true],
        ["model": "gpt-reserve", "hidden": true],
    ]])
    expect(codex?.models == ["openai-codex/gpt-6-sol", "openai-codex/gpt-6-astra"] && codex?.seedModel == "openai-codex/gpt-6-astra",
           "live-models: codex model/list must keep its order, drop hidden models and seed its isDefault, got \(String(describing: codex?.models)) / \(String(describing: codex?.seedModel))")
    let undefaulted = AgentModelCatalog.parseCodexModelListResponse(["data": [["model": "gpt-6-sol"], ["model": "gpt-6-luna"]]])
    expect(undefaulted?.seedModel == "openai-codex/gpt-6-sol",
           "live-models: with no isDefault the seed is codex's first model, got \(String(describing: undefaulted?.seedModel))")

    // The shared catalogue in QA seeds claude's own default. The capture's is
    // Fable 5.1 because that machine's `~/.claude/settings.json` chose it: the
    // CLI's `default` is the user's own default, which is the point.
    expect(AgentModelConfig.defaultModel(for: .claudeCode) == "anthropic/claude-fable-5-1",
           "live-models: the claude seed must be the CLI's default, got \(String(describing: AgentModelConfig.defaultModel(for: .claudeCode)))")

    print("Live model catalog checks passed: claude initialize probe (answer, argv, timeout), live mode serves only CLI answers, CLI-named defaults")
}
