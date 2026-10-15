import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

// A Pi turn the provider refused rendered as an error card whose whole body was
// the word "error" (preview app, 2026-10-13, openai-codex/gpt-5.3-codex-spark on
// a ChatGPT login). Pi had said why, on the assistant message; the translator's
// allowlist did not recognise a model-entitlement refusal, so it fell back to
// the bare stopReason.
//
// The frames below are the real `pi --mode rpc` stream (pi 0.85.0), captured
// verbatim the same evening from
// `pi --mode rpc --model openai-codex/gpt-5.3-codex-spark --thinking high --no-session`
// with one `prompt` command. Driven through the production translator AND the
// transcript projection that builds the card, so the witness asserts the words
// the card shows, not an intermediate value.
private let piSparkRefusalFrames: [String] = [
    #"{"type":"extension_ui_request","id":"69a32926-8870-4ddd-bb16-51338abdf7a8","method":"setStatus","statusKey":"harness-agents","statusText":"\u001b[38;2;102;102;102magents 0\u001b[39m"}"#,
    #"{"id":"p1","type":"response","command":"prompt","success":true}"#,
    #"{"type":"extension_ui_request","id":"401b2f94-90b5-4f71-acc7-05caf87da142","method":"setStatus","statusKey":"context","statusText":"\u001b[38;2;102;102;102mctx 225/128k 0%\u001b[39m"}"#,
    #"{"type":"agent_start"}"#,
    #"{"type":"turn_start"}"#,
    #"{"type":"message_start","message":{"role":"user","content":[{"type":"text","text":"Reply with only OK."}],"timestamp":1791943582719}}"#,
    #"{"type":"message_end","message":{"role":"user","content":[{"type":"text","text":"Reply with only OK."}],"timestamp":1791943582719}}"#,
    #"{"type":"message_start","message":{"role":"assistant","content":[],"api":"openai-codex-responses","provider":"openai-codex","model":"gpt-5.3-codex-spark","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"error","timestamp":1791943582729,"errorMessage":"Codex error: The 'gpt-5.3-codex-spark' model is not supported when using Codex with a ChatGPT account."}}"#,
    #"{"type":"message_end","message":{"role":"assistant","content":[],"api":"openai-codex-responses","provider":"openai-codex","model":"gpt-5.3-codex-spark","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"error","timestamp":1791943582729,"errorMessage":"Codex error: The 'gpt-5.3-codex-spark' model is not supported when using Codex with a ChatGPT account."}}"#,
    #"{"type":"turn_end","message":{"role":"assistant","content":[],"api":"openai-codex-responses","provider":"openai-codex","model":"gpt-5.3-codex-spark","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"error","timestamp":1791943582729,"errorMessage":"Codex error: The 'gpt-5.3-codex-spark' model is not supported when using Codex with a ChatGPT account."},"toolResults":[]}"#,
    #"{"type":"agent_end","messages":[{"role":"user","content":[{"type":"text","text":"Reply with only OK."}],"timestamp":1791943582719},{"role":"assistant","content":[],"api":"openai-codex-responses","provider":"openai-codex","model":"gpt-5.3-codex-spark","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"error","timestamp":1791943582729,"errorMessage":"Codex error: The 'gpt-5.3-codex-spark' model is not supported when using Codex with a ChatGPT account."}],"willRetry":false}"#,
    #"{"type":"agent_settled"}"#,
    #"{"type":"extension_ui_request","id":"68802122-fbff-4623-8909-11ed7937226d","method":"setWidget","widgetKey":"harness-agents-sticky"}"#,
    #"{"type":"extension_ui_request","id":"dfa9de96-28e3-4737-9dd9-816a31c88c8c","method":"setStatus","statusKey":"harness-agents"}"#,
]

private let piSparkRefusalText =
    "Codex error: The 'gpt-5.3-codex-spark' model is not supported when using Codex with a ChatGPT account."

/// The failed turn's closing message and the error card bodies the transcript
/// projection builds from one Pi frame stream.
private func piFailureOutcome(_ frames: [String]) -> (completions: [(TurnOutcome, String?)], cards: [String]) {
    var translator = PiEventTranslator(now: { Date(timeIntervalSinceReferenceDate: 7) })
    let events = translator.translate(stream: frames)
    let completions = events.compactMap { event -> (TurnOutcome, String?)? in
        if case let .turnCompleted(_, _, outcome, message) = event { return (outcome, message) }
        return nil
    }
    var projection = AgentTranscriptProjection(threadId: "pi-unknown")
    projection.appendUserPrompt("Reply with only OK.")
    events.forEach { projection.ingest($0) }
    let cards = projection.document.entries.flatMap(\.blocks).compactMap { block -> String? in
        if case let .error(payload) = block.payload { return payload.message }
        return nil
    }
    return (completions, cards)
}

func runPiProviderFailureChecks() {
    // 1. The real refusal: one failed run, and the card carries pi's words.
    let real = piFailureOutcome(piSparkRefusalFrames)
    expect(real.completions.count == 1 && real.completions.first?.0 == .failed,
           "Pi refusal: the captured stream must close exactly one FAILED run; got \(real.completions)")
    expect(real.completions.first?.1 == piSparkRefusalText,
           "Pi refusal: the failed turn must carry the provider's message; got \(String(describing: real.completions.first?.1))")
    expect(real.cards == [piSparkRefusalText],
           "Pi refusal: the transcript must show ONE error card reading the provider's message; got \(real.cards)")

    // 2. I5 still holds: an errorMessage that does not read as a provider
    //    failure may be model or tool text, so it never crosses -- and the card
    //    still says something better than the bare stopReason "error".
    let leaked = piSparkRefusalFrames.map {
        $0.replacingOccurrences(of: piSparkRefusalText, with: "SECRET-TOOL-OUTPUT from the model")
    }
    let withheld = piFailureOutcome(leaked)
    expect(withheld.cards.count == 1,
           "Pi withheld error: expected one error card; got \(withheld.cards)")
    expect(!withheld.cards.joined().contains("SECRET-TOOL-OUTPUT"),
           "Pi withheld error I5: unrecognised error text must not reach the card; got \(withheld.cards)")
    expect(withheld.cards.allSatisfy { $0.lowercased() != "error" },
           "Pi withheld error: the card must not read the bare word 'error'; got \(withheld.cards)")

    print("PiProviderFailure checks passed: the real spark refusal frames close one failed run whose card reads \"\(real.cards.first ?? "")\"; unrecognised error text stays withheld and reads \"\(withheld.cards.first ?? "")\"")
}
