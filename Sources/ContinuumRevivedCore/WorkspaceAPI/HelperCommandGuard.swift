import Foundation

/// Evidence about commands, never a claim about correctness. Indexes refer to
/// report.checks; bounded wording keeps the parent's wait_agents result small.
public struct AgentCommandEvidence: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case observed, stale
        case observedFailed = "observed-failed"
        case notObserved = "not-observed"
    }
    public var check: Int
    public var outcome: Outcome
    public var detail: String
}

public enum HelperCommandGuard {
    static let runners = ["swift test", "swift build", "run-matrix", "xcodebuild", "npm test", "npm run test",
                          "npm run build", "pnpm test", "pnpm build", "yarn test", "yarn build", "pytest",
                          "python -m pytest", "python3 -m pytest", "cargo test", "cargo build", "go test", "go build", "make test", "make build"]
    static func folded(_ text: String) -> String { text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    static func contains(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
    static func runner(in text: String) -> String? {
        runners.sorted { $0.count > $1.count }.first { contains(text, #"\b"# + NSRegularExpression.escapedPattern(for: $0) + #"\b"#) }
    }
    public static func normalizedTool(_ name: String?) -> String {
        let name = (name ?? "").lowercased().split(separator: ".").last.map(String.init) ?? ""
        return ["bash", "exec_command", "shell", "shell_command"].contains(name) ? "bash" : name
    }
    static func isEdit(_ receipt: AgentHookReceipt) -> Bool {
        let tool = normalizedTool(receipt.toolName)
        if ["edit", "write", "multiedit", "notebookedit", "apply_patch"].contains(tool) { return true }
        guard tool == "bash", let command = receipt.command else { return false }
        // Best effort, intentionally errs toward invalidating evidence. Build
        // outputs are not source edits; redirects, patchers and script writers are.
        return contains(command, #">|\b(tee|touch|cp|mv|rm|apply_patch|patch)\b|\bsed\s+-i|\b(perl|python[0-9.]*|ruby|node)\s+(-[ce]|-\s+<<|<<)"#)
    }
    static func invocation(_ command: String) -> String? {
        guard !command.contains("\n") else { return nil }
        let text = folded(command)
        // Do not credit quoted text, pipelines, conditional/failing wrappers or
        // multiple commands with a shell's aggregate exit status.
        guard !contains(text, #"[;|&\n`<>]|\$\("#) else { return nil }
        guard let runner = runner(in: text) else { return nil }
        if runner == "run-matrix", text == "scripts/run-matrix.sh" || text.hasPrefix("scripts/run-matrix.sh ") { return text }
        guard text == runner || text.hasPrefix(runner + " ") else { return nil }
        return text
    }
    public static func evidence(for report: AgentReport, receipts: [AgentHookReceipt]) -> [AgentCommandEvidence]? {
        let lastEdit = receipts.lastIndex(where: isEdit) ?? -1
        let runs = receipts.enumerated().compactMap { index, receipt -> (Int, String, Int?)? in
            guard receipt.event == "PostToolUse", normalizedTool(receipt.toolName) == "bash",
                  let command = receipt.command, let invocation = invocation(command) else { return nil }
            return (index, invocation, receipt.exitCode)
        }
        let evidence = report.checks.enumerated().compactMap { index, check -> AgentCommandEvidence? in
            var claim = folded(check.what)
            for suffix in [" passed", " pass", " succeeded"] where claim.hasSuffix(suffix) {
                claim = String(claim.dropLast(suffix.count))
            }
            guard check.result == .pass else { return nil }
            let named = runner(in: claim)
            guard named != nil || contains(claim, #"\b(tests?|build|matrix)\b"#) else { return nil }
            let matching = runs.filter { run in
                if let named {
                    guard runner(in: run.1) == named else { return false }
                    // A command-shaped claim with arguments must match those too.
                    if claim.hasPrefix(named), claim != named {
                        return run.1 == claim || run.1.hasPrefix(claim + " ")
                    }
                    return true
                }
                return claim.contains("build") ? run.1.contains("build") : (run.1.contains("test") || run.1.contains("run-matrix"))
            }
            let latest = matching.last
            let outcome: AgentCommandEvidence.Outcome
            let detail: String
            if let latest, latest.0 > lastEdit, let code = latest.2 {
                outcome = code == 0 ? .observed : .observedFailed
                detail = "Array saw `\(named ?? runner(in: latest.1) ?? "test")` exit \(code) after the last edit"
            } else if let latest, latest.0 <= lastEdit {
                outcome = .stale
                detail = "Array saw a matching command only before the last edit"
            } else {
                outcome = .notObserved
                detail = latest == nil ? "Array saw no matching test/build run after the last edit" : "Array saw a matching command; exit status was not reported"
            }
            return AgentCommandEvidence(check: index, outcome: outcome, detail: detail)
        }
        return evidence.isEmpty ? nil : evidence
    }
}
