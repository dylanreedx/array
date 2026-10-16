import ContinuumRevivedAgentContent
import Foundation

// Launch polish, item J — the one shell-invocation shape every harness's
// command row is drawn from. Pure: wrapper unwrapping, the headline, the badge,
// the duration column, and the I5 rule that none of it reaches the document's
// Codable shape.
func runShellInvocationChecks() {
    // Unwrapping. Codex wraps every command in a login shell; the reader typed
    // the inside.
    let unwraps: [(String, String)] = [
        ("/bin/zsh -lc 'echo hi-from-codex'", "echo hi-from-codex"),
        ("/bin/zsh -lc \"wc -l note.txt && sed -n '1p' note.txt\"", "wc -l note.txt && sed -n '1p' note.txt"),
        ("bash -lc 'git status --short'", "git status --short"),
        ("sh -c 'it'\\''s'", "it's"),
        ("/bin/bash -c \"echo \\\"$HOME\\\"\"", "echo \"$HOME\""),
        ("zsh -lc \"bash -c 'ls'\"", "ls"),
        ("/bin/zsh -lc \"set -e\nfor f in a b; do\n  echo \\\"$f\\\"\ndone\"", "set -e\nfor f in a b; do\n  echo \"$f\"\ndone"),
        // Not exactly one wrapper around one word: shown as sent.
        ("ls -la", "ls -la"),
        ("python -c 'print(1)'", "python -c 'print(1)'"),
        ("sh -c 'echo $0' name", "sh -c 'echo $0' name"),
        ("bash -lc 'unterminated", "bash -lc 'unterminated"),
        ("bash --login -c 'x'", "bash --login -c 'x'"),
    ]
    for (raw, expected) in unwraps {
        let got = AgentShellInvocation.unwrapShellWrapper(raw)
        expect(got == expected, "unwrapShellWrapper(\(raw.debugDescription)) = \(got.debugDescription), expected \(expected.debugDescription)")
    }
    expect(AgentShellInvocation.unwrapShellWrapper(argv: ["bash", "-lc", "git status"]) == "git status",
           "argv [bash, -lc, script] must unwrap to the script")
    expect(AgentShellInvocation.unwrapShellWrapper(argv: ["/bin/zsh", "-c", "bash -lc 'ls'"]) == "ls",
           "a wrapped argv whose script is itself wrapped must peel both")
    expect(AgentShellInvocation.unwrapShellWrapper(argv: ["rg", "-n", "two words"]) == "rg -n 'two words'",
           "a plain argv must join back into the line a person types")

    // The headline: first line, and a marker when there is more.
    let multi = AgentShellInvocation(command: "set -e\nfor f in a b; do\n  echo $f\ndone", status: .succeeded)
    expect(multi.headline == "set -e …", "multi-line headline was \(multi.headline.debugDescription)")
    expect(multi.disclosureText.contains("done"), "the expanded body must hold the whole command")
    let long = AgentShellInvocation(command: String(repeating: "x", count: 500), status: .succeeded)
    expect(long.headline.count == AgentShellInvocation.maxHeadlineCharacters + 2 && long.headline.hasSuffix(" …"),
           "an over-long headline is bounded and marked")

    // The badge: nothing on success, the code on failure, words for the rest.
    expect(AgentShellInvocation(command: "true", exitCode: 0, status: .succeeded).badgeText == nil,
           "exit 0 must carry no badge")
    expect(AgentShellInvocation(command: "false", exitCode: 2, status: .failed).badgeText == "exit 2",
           "a non-zero exit must badge its code")
    expect(AgentShellInvocation(command: "x", exitCode: 2, status: .failed).needsAttention, "a failure needs attention")
    expect(AgentShellInvocation(command: "x", status: .timedOut).badgeText == "timed out", "timed out badge")
    expect(AgentShellInvocation(command: "x", status: .timedOut).needsAttention, "a timeout needs attention")
    expect(AgentShellInvocation(command: "x", status: .interrupted).badgeText == "interrupted", "interrupted badge")
    expect(AgentShellInvocation(command: "x", status: .backgrounded).badgeText == "background", "background badge")
    expect(AgentShellInvocation(command: "x", status: .running).badgeText == nil, "running has no badge")

    // The duration: only a real, readable one.
    func duration(_ seconds: TimeInterval?) -> String? {
        AgentShellInvocation(command: "x", duration: seconds, status: .succeeded).durationText
    }
    expect(duration(nil) == nil, "no measurement, no duration")
    expect(duration(0) == nil, "0s would print as 0.0s and must be hidden")
    expect(duration(0.049) == nil, "a span that rounds to 0.0s must be hidden")
    expect(duration(1.24) == "1.2s", "1.24s reads 1.2s, got \(duration(1.24) ?? "nil")")
    expect(duration(42) == "42s", "42s reads 42s")
    expect(duration(125) == "2m 5s", "125s reads 2m 5s, got \(duration(125) ?? "nil")")

    // I5: the command never enters the document's encoded shape.
    var payload = AgentToolCallPayload(name: "ls /secret-dir", status: .completed)
    payload.presentedShell = AgentShellInvocation(command: "cat /secret-dir/SECRET-SHELL", output: "SECRET-SHELL-OUT", status: .succeeded)
    let encoded = String(decoding: try! JSONEncoder().encode(payload), as: UTF8.self)
    expect(!encoded.contains("SECRET-SHELL"), "presentedShell leaked into the Codable payload: \(encoded)")

    print("AgentShellInvocation checks passed: \(unwraps.count) wrapper cases, headline, badge, duration and the Codable exclusion")
}
