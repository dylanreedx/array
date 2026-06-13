import Foundation

public struct AgentKickoffTicket: Equatable, Sendable {
    public var identifier: String
    public var title: String
    public var projectName: String?

    public init(identifier: String, title: String, projectName: String? = nil) {
        self.identifier = identifier
        self.title = title
        self.projectName = projectName
    }
}

public enum AgentKickoffPrompt {
    /// Docs/21 is the source template; keep this pure so queue-row dispatch can be
    /// tested without Linear, Ghostty, or a live CLI agent.
    public static func make(ticket: AgentKickoffTicket, repoPath: String, branch: String = "main") -> String {
        let projectLine = ticket.projectName.map { "Epic/project: \($0)" } ?? "Epic/project: infer from Linear ticket"
        return """
        # Task: Work the Linear backlog — ticket `\(ticket.identifier)`

        Repo: \(repoPath) (branch: \(branch))

        Ticket: \(ticket.identifier) — \(ticket.title)
        \(projectLine)

        Read the ticket's CURRENT Linear description before changing code. Claim the ticket, stay inside its Scope, and follow docs/21-agent-workflow.md plus docs/22-linear-master-overnight-workflow.md.

        Required loop: SCOUT → PLAN → IMPLEMENT → VERIFY → REVIEW → COMMIT → LINEAR_UPDATE.

        Verification contract: run ./scripts/run-matrix.sh and the ticket's named checks. Evidence must include real command output, artifact paths, reviewer decisions, commit SHA, and PENDING items or "none".

        Do not start Backlog tickets or widen scope. Stop and comment on Linear if blocked, ambiguous, or if required checks fail.
        """
    }

    public static func make(row: LinearTicketQueueRow, repoPath: String, projectName: String? = nil, branch: String = "main") -> String {
        make(ticket: AgentKickoffTicket(identifier: row.identifier, title: row.title, projectName: projectName), repoPath: repoPath, branch: branch)
    }
}
