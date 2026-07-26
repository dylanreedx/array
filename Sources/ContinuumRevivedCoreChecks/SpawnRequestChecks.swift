import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// Ticket: docs/38-tickets/90-agent-ux/P2D.2-detect-spawn-tool-call.md
//
// The reading half of orchestration, held against the REAL captured stream:
// `Fixtures/spawn-agent-tool-call.jsonl` is a verbatim `pi --mode json` run with
// P2D.1's extension loaded, so this check never needs a live model and the shape
// it parses is the shape Pi actually emits.
//
// Five properties:
//   1. The fixture produces exactly ONE `SpawnRequest`, with the three arguments
//      the model sent — parsed off `tool_execution_start`, not off the
//      `toolcall_delta` fragments (which are partial JSON by construction and
//      carry the same arguments a second time).
//   2. The side channel changes NOTHING about the event stream: the same lines
//      translate to the same events with and without an observer.
//   3. I5 — neither the child's prompt, nor its role, nor the capturing machine's
//      cwd appears in any produced `AgentRuntimeEvent` or in any
//      `AgentActivityEventDraft` the bridge makes from them. The tool NAME does.
//   4. A tool that is not `spawn_agent` gets its args ignored, even when they are
//      shaped exactly like a spawn's. The whitelist is on the NAME.
//   5. Malformed args are refused rather than defaulted: no prompt, a blank
//      prompt, a non-string prompt, args that are not an object, args that are not
//      JSON at all.
//
// Negative tests observed red at exit 1 with the final code are quoted at each
// assertion.
func runSpawnRequestChecks() {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent("spawn-agent-tool-call.jsonl", isDirectory: false)
    guard let fixtureText = try? String(contentsOf: fixtureURL, encoding: .utf8) else {
        fputs("FAIL: SpawnRequest fixture missing at \(fixtureURL.path)\n", stderr)
        Foundation.exit(1)
    }
    let lines = fixtureText
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map(String.init)

    // The captured call, quoted from the fixture so a re-capture that changes the
    // arguments makes this check fail rather than pass vacuously.
    let capturedPrompt = "Find every call site of AgentSupervisor.spawn and report the file:line list."
    let capturedRole = "code-scout"
    // The `session` line records the capturing machine's project root. That is part
    // of the verbatim capture, and it is exactly what must not reach an event.
    let capturedCwd = "/Users/dylan/Documents/personal/continuum-overnight"
    expect(fixtureText.contains(capturedPrompt) && fixtureText.contains(capturedCwd),
           "SpawnRequest: the fixture no longer contains the arguments/cwd this check asserts on — re-check it after a re-capture")

    // MARK: 1 · one request out of the real stream

    // A box, not a `var` captured by an @Sendable closure: the translator's channel
    // is declared `@Sendable` because in production it fires on the runner's queue.
    final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [SpawnRequest] = []
        func append(_ request: SpawnRequest) { lock.withLock { storage.append(request) } }
        var requests: [SpawnRequest] { lock.withLock { storage } }
    }
    let box = RequestBox()
    var translator = PiEventTranslator()
    translator.onSpawnRequest = { box.append($0) }
    let events = translator.translate(stream: lines)

    // Red when the side channel reads the `toolcall_delta`/`toolcall_end` fragments
    // as well: `got 2 spawn request(s), expected exactly 1`.
    expect(box.requests.count == 1,
           "SpawnRequest: got \(box.requests.count) spawn request(s) from the captured stream, expected exactly 1")
    guard let request = box.requests.first else {
        fputs("FAIL: SpawnRequest: the captured spawn_agent call produced no request at all\n", stderr)
        Foundation.exit(1)
    }
    expect(request == SpawnRequest(role: capturedRole, prompt: capturedPrompt, isolated: true),
           "SpawnRequest: the captured call parsed as role \(String(describing: request.role)), isolated \(request.isolated), prompt \(request.prompt.count) chars — expected role \(capturedRole), isolated true, the captured prompt")

    // MARK: 2 · the channel is a side channel

    var plain = PiEventTranslator()
    let eventsWithoutObserver = plain.translate(stream: lines)
    expect(events == eventsWithoutObserver,
           "SpawnRequest: observing spawn requests changed the event stream — \(events.count) events with an observer, \(eventsWithoutObserver.count) without")
    expect(events.contains(where: { event in
        if case let .itemStarted(_, _, _, title) = event { return title == SpawnRequest.toolName }
        return false
    }), "SpawnRequest: the observed call must still emit its itemStarted carrying the tool NAME")

    // MARK: 3 · I5 — the args stay off the stream, and off the timeline

    let encodedEvents = String(decoding: try! JSONEncoder().encode(events), as: UTF8.self)
    // Red when the translator puts the args into the item title
    // (`title: "\(toolName) \(args)"`): `the child's prompt reached an
    // AgentRuntimeEvent`.
    expect(!encodedEvents.contains(capturedPrompt),
           "SpawnRequest I5: the child's prompt reached an AgentRuntimeEvent")
    expect(!encodedEvents.contains(capturedRole),
           "SpawnRequest I5: the child's role reached an AgentRuntimeEvent")
    expect(!encodedEvents.contains(capturedCwd),
           "SpawnRequest I5: the capturing machine's cwd reached an AgentRuntimeEvent")

    let agentId = UUID()
    let drafts = events.compactMap {
        ManagedAgentActivityBridge.draft(
            for: $0, agentId: agentId, tileId: nil, status: .working,
            now: Date(timeIntervalSinceReferenceDate: 0)
        )
    }
    expect(!drafts.isEmpty, "SpawnRequest I5: the bridge produced no drafts, so the witness below is vacuous")
    // Stamped into the PUBLISHED type, which is the one that crosses: a draft is
    // not Codable, so encoding it would witness a shape nothing ever sends.
    let published = drafts.enumerated().map {
        AgentActivityEvent(stamping: $0.element, sequence: UInt64($0.offset), replicaId: UUID())
    }
    let encodedDrafts = String(decoding: try! JSONEncoder().encode(published), as: UTF8.self)
    expect(!encodedDrafts.contains(capturedPrompt) && !encodedDrafts.contains(capturedRole)
            && !encodedDrafts.contains(capturedCwd),
           "SpawnRequest I5: a published activity draft carries the spawn arguments: \(encodedDrafts)")
    expect(encodedDrafts.contains(SpawnRequest.toolName),
           "SpawnRequest: the tool NAME may cross — the timeline should still show tool.spawn_agent")

    // MARK: 4 · the whitelist is on the tool NAME

    let spawnArgs = #"{"role":"code-scout","prompt":"do the thing","isolated":true}"#
    // Red when `parse` drops the `toolName ==` guard: `a tool that is not
    // spawn_agent had its arguments read`.
    expect(SpawnRequest.parse(toolName: "read", argsJSON: spawnArgs) == nil,
           "SpawnRequest: a tool that is not \(SpawnRequest.toolName) had its arguments read")
    expect(SpawnRequest.parse(toolName: "spawn_Agent", argsJSON: spawnArgs) == nil,
           "SpawnRequest: the tool name must match exactly, not case-insensitively")
    expect(SpawnRequest.parse(toolName: SpawnRequest.toolName, argsJSON: spawnArgs)
            == SpawnRequest(role: "code-scout", prompt: "do the thing", isolated: true),
           "SpawnRequest: the whitelisted tool's args must parse")

    // The same thing through the translator, since that is the production entry
    // point: a `read` call whose args are shaped exactly like a spawn's.
    let disguised = RequestBox()
    var disguisedTranslator = PiEventTranslator()
    disguisedTranslator.onSpawnRequest = { disguised.append($0) }
    _ = disguisedTranslator.translate(stream: [
        #"{"type":"session","version":3,"id":"SID-x","timestamp":"t","cwd":"/x"}"#,
        #"{"type":"tool_execution_start","toolCallId":"c1","toolName":"read","args":{"role":"code-scout","prompt":"do the thing","isolated":true}}"#
    ])
    expect(disguised.requests.isEmpty,
           "SpawnRequest: a `read` call with spawn-shaped args produced \(disguised.requests.count) request(s)")

    // MARK: 5 · malformed args are refused, not defaulted

    let refused: [(String, String)] = [
        ("not JSON at all", "{oops"),
        ("a JSON array", #"["prompt","x"]"#),
        ("no prompt", #"{"role":"code-scout","isolated":true}"#),
        ("a blank prompt", #"{"prompt":"   \n "}"#),
        ("a non-string prompt", #"{"prompt":42}"#),
        ("an empty object", "{}")
    ]
    for (label, argsJSON) in refused {
        // Red when `prompt` falls back to "" or to the role: `<label> produced a
        // request`.
        expect(SpawnRequest.parse(toolName: SpawnRequest.toolName, argsJSON: argsJSON) == nil,
               "SpawnRequest: \(label) produced a request — malformed args must be refused, not defaulted")
    }

    // Accepted, with the optional fields taking their documented defaults.
    expect(SpawnRequest.parse(toolName: SpawnRequest.toolName, argsJSON: #"{"prompt":"just a task"}"#)
            == SpawnRequest(role: nil, prompt: "just a task", isolated: false),
           "SpawnRequest: prompt-only args must parse as an unnamed, non-isolated spawn")
    expect(SpawnRequest.parse(toolName: SpawnRequest.toolName, argsJSON: #"{"prompt":"x","role":"  "}"#)?.role == nil,
           "SpawnRequest: a blank role must read as no role, not as a role named \"\"")
    // A STRING "true" is not an isolated spawn. Reading it as one would put an
    // agent in the shared checkout while telling the caller it is isolated.
    expect(SpawnRequest.parse(toolName: SpawnRequest.toolName, argsJSON: #"{"prompt":"x","isolated":"true"}"#)?.isolated == false,
           "SpawnRequest: a string `isolated` must not be coerced to a Bool")

    // MARK: 6 · it cannot be serialized by accident

    // The I5 property this type's shape carries: `SpawnRequest` is deliberately NOT
    // Codable, so nothing can publish it even by mistake. Asserted by reading the
    // declaration, because a missing conformance has no runtime witness.
    let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()          // ContinuumRevivedCoreChecks
        .deletingLastPathComponent()          // Sources
        .appendingPathComponent("ContinuumRevivedCore/Agents/SpawnRequest.swift", isDirectory: false)
    guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
        fputs("FAIL: SpawnRequest: cannot read \(sourceURL.path) — the I5 conformance scan is looking in the wrong place\n", stderr)
        Foundation.exit(1)
    }
    guard let declaration = source
        .split(separator: "\n", omittingEmptySubsequences: false)
        .first(where: { $0.hasPrefix("public struct SpawnRequest") })
    else {
        fputs("FAIL: SpawnRequest: no `public struct SpawnRequest` declaration found in \(sourceURL.lastPathComponent)\n", stderr)
        Foundation.exit(1)
    }
    for conformance in ["Codable", "Encodable", "Decodable"] {
        expect(!declaration.contains(conformance),
               "SpawnRequest I5: the declaration conforms to \(conformance) — the args must not be serializable at all (\(declaration))")
    }
    // …and nowhere else either (from the cross-review): a retroactive
    // `extension SpawnRequest: Codable {}` in any target would restore the
    // conformance while the declaration above stays clean, so the whole source tree
    // is scanned for one. `scanned` is asserted non-zero — a scan that reads no files
    // would pass this silently.
    let sourcesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()          // ContinuumRevivedCoreChecks
        .deletingLastPathComponent()          // Sources
    var scanned = 0
    var retroConformances: [String] = []
    if let walker = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil) {
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            guard text.contains("SpawnRequest") else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                // Anchored at the start of the line, so prose ABOUT the forbidden
                // extension — including the comment above — is not a match. Found by
                // the negative test, which flagged this file's own comment.
                let code = line.trimmingCharacters(in: .whitespaces)
                guard code.hasPrefix("extension SpawnRequest"),
                      ["Codable", "Encodable", "Decodable"].contains(where: { code.contains($0) })
                else { continue }
                retroConformances.append("\(url.lastPathComponent): \(code)")
            }
        }
    }
    expect(scanned > 0, "SpawnRequest I5: the conformance scan read no Swift files — it is looking in the wrong place")
    expect(retroConformances.isEmpty,
           "SpawnRequest I5: something makes SpawnRequest serializable after the fact: \(retroConformances)")

    print("SpawnRequest checks passed: 1 request parsed out of the real \(lines.count)-line capture (role \(capturedRole), isolated true), the side channel left all \(events.count) events unchanged, prompt/role/cwd absent from every event and every activity draft while tool.\(SpawnRequest.toolName) still crosses, a spawn-shaped `read` call ignored, \(refused.count) malformed arg shapes refused, and the type is not Codable at its declaration nor by extension anywhere in \(scanned) scanned source files")
}
