import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// Raw-provider parity witness. IDs, titles, and timestamps are intentionally
/// ignored; semantic stream, item kind, order, and outcome remain blocking.
enum TranscriptProviderParityChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

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
        var ct = ClaudeEventTranslator(runToken: "parity")
        var xt = CodexEventTranslator(runToken: "parity")
        var pt = PiEventTranslator()
        let signatures = [signature(ct.translate(stream: claude)), signature(xt.translate(stream: codex)), signature(pt.translate(stream: pi))]
        guard signatures.dropFirst().allSatisfy({ $0 == signatures[0] }) else {
            throw Failure(description: "raw provider semantic parity diverged: \(signatures)")
        }
        print("TranscriptProviderParityChecks passed: Claude/Codex/Pi raw fixtures preserve reasoning, prose, command success, and file failure hierarchy")
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
}
