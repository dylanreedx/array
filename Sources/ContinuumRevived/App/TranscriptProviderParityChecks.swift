import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// Raw-provider parity witness. IDs, titles, and timestamps are intentionally
/// ignored; semantic stream, item kind, order, and outcome remain blocking.
enum TranscriptProviderParityChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    final class Box: @unchecked Sendable {
        private let lock = NSLock(); private var values: [AgentRuntimeObservation] = []
        func append(_ value: AgentRuntimeObservation) { lock.withLock { values.append(value) } }
        func snapshot() -> [AgentRuntimeObservation] { lock.withLock { values } }
    }

    static func run() throws {
        let claude = [
            #"{"type":"system","subtype":"init","session_id":"claude-fixture","cwd":"/fixture"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"consider"}},"parent_tool_use_id":null}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"answer"}},"parent_tool_use_id":null}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"c1","name":"Bash","input":{"command":"true"}}]},"parent_tool_use_id":null}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"c1","is_error":false,"content":"ok"}]},"parent_tool_use_id":null}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"c2","name":"Edit","input":{"file_path":"fixture.txt"}}]},"parent_tool_use_id":null}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"c2","is_error":true,"content":"failed"}]},"parent_tool_use_id":null}"#,
        ]
        let codex = [
            #"{"type":"thread.started","thread_id":"codex-fixture"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.completed","item":{"id":"r","type":"reasoning","text":"consider"}}"#,
            #"{"type":"item.completed","item":{"id":"a","type":"agent_message","text":"answer"}}"#,
            #"{"type":"item.started","item":{"id":"c1","type":"command_execution","status":"in_progress"}}"#,
            #"{"type":"item.completed","item":{"id":"c1","type":"command_execution","exit_code":0,"status":"completed"}}"#,
            #"{"type":"item.started","item":{"id":"c2","type":"file_change","changes":[{"path":"fixture.txt","kind":"update"}],"status":"in_progress"}}"#,
            #"{"type":"item.completed","item":{"id":"c2","type":"file_change","changes":[{"path":"fixture.txt","kind":"update"}],"status":"failed"}}"#,
        ]
        let pi = [
            #"{"type":"session","id":"pi-fixture","cwd":"/fixture"}"#,
            #"{"type":"agent_start"}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","contentIndex":0,"delta":"consider"}}"#,
            #"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","contentIndex":1,"delta":"answer"}}"#,
            #"{"type":"tool_execution_start","toolCallId":"c1","toolName":"bash","args":{"command":"true"}}"#,
            #"{"type":"tool_execution_end","toolCallId":"c1","toolName":"bash","isError":false}"#,
            #"{"type":"tool_execution_start","toolCallId":"c2","toolName":"edit","args":{"path":"fixture.txt"}}"#,
            #"{"type":"tool_execution_end","toolCallId":"c2","toolName":"edit","isError":true}"#,
        ]
        let cb = Box(), xb = Box(), pb = Box()
        var ct = ClaudeEventTranslator(runToken: "parity"); ct.onRuntimeObservation = cb.append
        var xt = CodexEventTranslator(runToken: "parity"); xt.onRuntimeObservation = xb.append
        var pt = PiEventTranslator(); pt.onRuntimeObservation = pb.append
        let signatures = [signature(ct.translate(stream: claude)), signature(xt.translate(stream: codex)), signature(pt.translate(stream: pi))]
        guard signatures.dropFirst().allSatisfy({ $0 == signatures[0] }) else {
            throw Failure(description: "raw provider semantic parity diverged: \(signatures)")
        }
        let sharedDetails = [cb, xb, pb].map { detailSignature($0.snapshot()) }
        guard sharedDetails.dropFirst().allSatisfy({ $0 == sharedDetails[0] }), sharedDetails[0].contains("edit:fixture.txt") else {
            throw Failure(description: "raw provider host-local detail parity diverged: \(sharedDetails)")
        }

        let capabilityBox = Box()
        var capability = CodexEventTranslator(runToken: "capability")
        capability.onRuntimeObservation = capabilityBox.append
        _ = capability.translate(stream: [
            #"{"type":"thread.started","thread_id":"cap"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.started","item":{"id":"files","type":"file_change","changes":[{"path":"Sources/New.swift","kind":"add","diff":"+new"},{"path":"Sources/Old.swift","kind":"delete","diff":"-old"},{"path":"Sources/A.swift","new_path":"Sources/B.swift","kind":"rename","diff":"-a\n+b"},{"path":"Sources/Edit.swift","kind":"update","diff":"-x\n+y"}]}}"#,
        ])
        let capabilities = capabilityBox.snapshot().compactMap { observation -> AgentToolDetailObservation? in
            guard case let .toolDetail(_, detail) = observation else { return nil }; return detail
        }.flatMap(\.fileChanges)
        guard capabilities.map(\.action) == [.add, .delete, .rename, .edit],
              capabilities[2].renamePath == "Sources/B.swift", capabilities.allSatisfy({ $0.diffPreview != nil }) else {
            throw Failure(description: "Codex explicit file capabilities were discarded: \(capabilities)")
        }
        let absolute = AgentToolDetailObservation.FileChange(action: .write, path: "/Users/private/secret.txt")
        guard absolute.path == "secret.txt", absolute.renamePath == nil else {
            throw Failure(description: "private absolute path was retained: \(absolute)")
        }
        let hostileClaudeBox = Box(), hostileCodexBox = Box(), hostilePiBox = Box()
        var hostileClaude = ClaudeEventTranslator(runToken: "hostile"); hostileClaude.onRuntimeObservation = hostileClaudeBox.append
        var hostileCodex = CodexEventTranslator(runToken: "hostile"); hostileCodex.onRuntimeObservation = hostileCodexBox.append
        var hostilePi = PiEventTranslator(); hostilePi.onRuntimeObservation = hostilePiBox.append
        _ = hostileClaude.translate(stream: [
            #"{"type":"system","subtype":"init","session_id":"hostile","cwd":"/fixture"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"h1","name":"Edit","input":{"file_path":"C:\\Users\\Alice\\Secrets\\token.txt"}}]},"parent_tool_use_id":"file:///Users/alice/private/parent"}"#
        ])
        _ = hostileCodex.translate(stream: [
            #"{"type":"thread.started","thread_id":"hostile"}"#, #"{"type":"turn.started"}"#,
            #"{"type":"item.started","item":{"id":"h1","type":"file_change","changes":[{"path":"../../.ssh/id_rsa","new_path":"\\\\server\\private\\renamed.txt","kind":"rename","diff":"+ Authorization: Bearer codex-secret\n+ /Users/alice/private"}]}}"#
        ])
        _ = hostilePi.translate(stream: [
            #"{"type":"session","id":"hostile","cwd":"/fixture"}"#, #"{"type":"agent_start"}"#,
            #"{"type":"tool_execution_start","toolCallId":"h1","toolName":"edit","args":{"path":"file:///Users/alice/private/pi.swift"},"parentToolCallId":"https://user:password@example.invalid/parent"}"#
        ])
        for (provider, box) in [("claude", hostileClaudeBox), ("codex", hostileCodexBox), ("pi", hostilePiBox)] {
            let details = box.snapshot().compactMap { observation -> AgentToolDetailObservation? in
                guard case let .toolDetail(_, detail) = observation else { return nil }; return detail
            }
            let surface = details.flatMap(\.fileChanges).map { [$0.path, $0.renamePath ?? "", $0.diffPreview ?? ""].joined(separator: "\n") }.joined(separator: "\n")
                + details.compactMap(\.parentItemID).joined(separator: "\n")
            guard !surface.contains("Alice"), !surface.contains("alice"), !surface.contains("server"),
                  !surface.contains("codex-secret"), !surface.contains("/Users/"), !surface.contains(":\\") else {
                throw Failure(description: "\(provider) hostile raw detail leaked into host-local presentation facts: \(surface)")
            }
        }
        print("TranscriptProviderParityChecks passed: shared hierarchy/detail parity plus honest Codex add/delete/rename/diff capability and path privacy")
    }

    private static func signature(_ events: [AgentRuntimeEvent]) -> [String] {
        events.compactMap { event in
            switch event {
            case .contentDelta(_, _, let stream, _): return "stream:\(stream)"
            case .itemStarted(_, _, let kind, _): return "start:\(kind.rawValue)"
            case .itemCompleted(_, _, let kind, let status): return "end:\(kind.rawValue):\(status.rawValue)"
            default: return nil
            }
        }
    }

    private static func detailSignature(_ observations: [AgentRuntimeObservation]) -> [String] {
        observations.compactMap { observation in
            guard case let .toolDetail(_, detail) = observation, detail.phase == .started else { return nil }
            if let change = detail.fileChanges.first { return "\(change.action.rawValue):\(change.path)" }
            return detail.toolName?.lowercased() == "shell" || detail.toolName?.lowercased() == "bash" ? "command" : nil
        }
    }
}
