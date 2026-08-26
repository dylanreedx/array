import ContinuumRevivedAgentUI
import Foundation

// Ticket: docs/38-tickets/88-provider-adapter-pi-gpt.md (slice 88.4c)
//
// The bridge from the RICH observation stream a managed-agent tile ingests
// (AgentRuntimeEvent) to the I5-safe activity log that crosses to the phone
// (AgentActivityEventDraft). Pure + total so it can be pinned in the matrix.
//
// It deliberately DROPS streaming content deltas: they are high-frequency and
// carry assistant/reasoning text, which must never become an activity summary
// (I5 forbids transcript bodies at the sync boundary). What crosses is the
// SHAPE of what the agent is doing — turn boundaries, tool names, approvals,
// errors — plus the derived status the tile already computes.
public enum ManagedAgentActivityBridge {
    /// Cap on how many recent drafts we keep per agent before publishing. The
    /// phone's fold caps `recent` at 200; this keeps the wire payload bounded.
    public static let recentCap = 100

    /// Map one runtime event to a syncable activity draft, or nil for events
    /// that should not appear on the timeline (streaming deltas, token usage).
    /// `status` is the tile's current derived status at ingest time.
    /// P2A.8: keyed by `agentId`; `tileId` is the optional view hint (nil = headless).
    public static func draft(
        for event: AgentRuntimeEvent,
        agentId: UUID,
        tileId: UUID?,
        status: AgentStatus,
        now: Date
    ) -> AgentActivityEventDraft? {
        switch event {
        case .turnStarted:
            return make(agentId, tileId, .info, "turn.started", status, "Turn started", now)
        case .turnCompleted(_, _, let outcome, let errorMessage):
            switch outcome {
            case .completed:
                return make(agentId, tileId, .info, "turn.completed", status, "Turn complete", now,
                            terminalOutcome: .succeeded)
            case .failed:
                // I5: NEVER forward the raw error text — it carries the
                // provider's stderr (file paths, cwd, secrets). Truncation is
                // not sanitization. The local tile shows the detail; the synced
                // summary stays generic.
                return make(agentId, tileId, .error, "turn.failed", status, "Turn failed", now,
                            terminalOutcome: .failed)
            case .interrupted, .cancelled:
                let terminal: AgentTerminalOutcome = outcome == .interrupted ? .interrupted : .cancelled
                return make(agentId, tileId, .info, "turn.\(outcome.rawValue)", status,
                            "Turn \(outcome.rawValue)", now, terminalOutcome: terminal)
            }
        case .itemStarted(_, _, let kind, let title):
            // I5 defense-in-depth: the title is a tool NAME by the Pi adapter's
            // construction, but the bridge is provider-agnostic — sanitize to a
            // conservative token so no upstream can smuggle a path/arg through.
            let name = safeToolToken(title ?? kind.rawValue)
            return make(agentId, tileId, tone(for: kind), "tool.\(name)", status, "Started \(name)", now)
        case .itemCompleted(_, _, let kind, let itemStatus):
            let tone: ActivityEventTone = (itemStatus == .failed) ? .error : .tool
            return make(agentId, tileId, tone, "tool.\(itemStatus.rawValue)", status, "\(kind.rawValue) \(itemStatus.rawValue)", now)
        case .requestOpened(_, let requestId, let kind):
            return make(agentId, tileId, .approval, "approval.\(kind.rawValue)", status, "Needs approval", now, approvalRequestId: requestId)
        case .requestResolved(_, let requestId, let decision):
            return make(agentId, tileId, .approval, "approval.resolved", status, "Approval \(decision)", now, approvalRequestId: requestId)
        case .runtimeError:
            // I5: drop the raw message (provider stderr → paths/secrets). Local
            // tile keeps the detail; the phone gets only that an error occurred.
            return make(agentId, tileId, .error, "error", status, "Runtime error", now,
                        terminalOutcome: .runtimeError)
        case .semanticSignal(_, _, let kind):
            switch kind {
            case .gitPushSucceeded:
                return make(agentId, tileId, .tool, "git.push", status, "Pushed changes", now)
            case .gitMergeSucceeded:
                return make(agentId, tileId, .tool, "git.merge", status, "Merged changes", now)
            }
        case .childAgentSpawned:
            // Identity details travel only in the encrypted transcript channel;
            // the legacy activity projection receives a generic safe milestone.
            return make(agentId, tileId, .info, "agent.spawned", status, "Subagent started", now)
        case .sessionStateChanged, .contentDelta, .userInputRequested, .userInputResolved,
             .tokenUsageUpdated, .contextWindowUpdated:
            // Status changes ride on the other events' `status` field; content
            // deltas / token/context telemetry never cross (I5 + noise).
            return nil
        }
    }

    private static func tone(for kind: ItemKind) -> ActivityEventTone {
        switch kind {
        case .error: return .error
        default: return .tool
        }
    }

    /// A tool label must be a bare identifier-ish token (a tool NAME). If it
    /// contains anything else — a path separator, whitespace, arguments — we do
    /// NOT try to salvage it (salvaging concatenates surviving path components
    /// / secret words); we collapse to a generic token so nothing rides along.
    /// Belt-and-suspenders for I5 — the current Pi adapter already passes only a
    /// tool name.
    private static func safeToolToken(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.")
        if s.isEmpty || s.contains(where: { !allowed.contains($0) }) { return "tool" }
        return String(s.prefix(40))
    }

    private static func make(
        _ agentId: UUID, _ tileId: UUID?, _ tone: ActivityEventTone, _ kind: String,
        _ status: AgentStatus, _ summary: String, _ now: Date,
        terminalOutcome: AgentTerminalOutcome? = nil,
        approvalRequestId: String? = nil
    ) -> AgentActivityEventDraft {
        AgentActivityEventDraft(
            agentId: agentId, tileId: tileId, runId: nil, tone: tone, kind: kind,
            status: status, terminalOutcome: terminalOutcome, summary: summary, occurredAt: now,
            approvalRequestId: approvalRequestId
        )
    }
}
