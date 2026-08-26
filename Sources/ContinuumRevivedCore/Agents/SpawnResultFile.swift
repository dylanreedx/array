import Foundation

// The file channel that makes `spawn_agent` collectable.
//
// Witnessed live 2026-08-22: a managed pi agent's model called Array's
// `spawn_agent` tool twice; both children ran, but the tool is fire-and-forget,
// so the model had no way to collect their results, slept in a loop, gave up
// and redid the work itself. Separately, when Array REFUSED a spawn the model
// still saw "spawned: <role>" — `refuseSpawn` synthesizes transcript items the
// model never receives.
//
// The channel is deliberately a FILE, not IPC: production pi is one process
// per turn (`PiAgentRunner`), the extension is re-instantiated every turn and
// keeps no memory across turns, and pi enforces no tool timeout — so the
// extension's `wait_agents` tool simply polls
// `<parent cwd>/.array/spawn-results/<toolCallId>.json` until every requested
// handle reaches a terminal status. `.array/` is project-local scratch, keyed
// by the parent's working directory — the same directory `ctx.cwd` names
// inside the extension.
//
// Array writes three times per spawn:
//   1. `refused`   — synchronously, with the refusal reason (the first time a
//                    refusal is visible to the MODEL rather than only the UI),
//   2. `spawned`   — right after a successful launch,
//   3. terminal    — from the child's `.turnCompleted`, carrying the child's
//                    final assistant text (capped; truncation is noted).
public struct SpawnResultFile: Codable, Equatable, Sendable {
    public static let currentSchema = 1
    /// Bytes of `finalText` kept in a terminal result. The child's full answer
    /// stays in its own transcript; this is a courier, not an archive.
    public static let finalTextByteCap = 32 * 1024

    public enum Status: String, Codable, Sendable {
        case spawned
        case refused
        case completed
        case failed
        case interrupted
    }

    public var schema: Int
    public var toolCallId: String
    public var status: Status
    public var agentId: UUID?
    public var role: String?
    public var reason: String?
    public var finalText: String?
    /// True when `finalText` was cut at `finalTextByteCap`.
    public var finalTextTruncated: Bool?
    public var endedAt: Date?

    public init(
        schema: Int = SpawnResultFile.currentSchema,
        toolCallId: String,
        status: Status,
        agentId: UUID? = nil,
        role: String? = nil,
        reason: String? = nil,
        finalText: String? = nil,
        finalTextTruncated: Bool? = nil,
        endedAt: Date? = nil
    ) {
        self.schema = schema
        self.toolCallId = toolCallId
        self.status = status
        self.agentId = agentId
        self.role = role
        self.reason = reason
        self.finalText = finalText
        self.finalTextTruncated = finalTextTruncated
        self.endedAt = endedAt
    }

    /// `<parent cwd>/.array/spawn-results` — the directory the extension polls.
    public static func directory(parentCwd: String) -> URL {
        URL(fileURLWithPath: parentCwd, isDirectory: true)
            .appendingPathComponent(".array", isDirectory: true)
            .appendingPathComponent("spawn-results", isDirectory: true)
    }

    /// The handle becomes a path component, so it is validated as one — the
    /// same rule `ObservedRunHandle.validated` applies to pi's runId. nil means
    /// "do not write a file for this call".
    public static func validatedHandle(_ toolCallId: String?) -> String? {
        guard let trimmed = toolCallId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed.count <= 256,
              !trimmed.hasPrefix("."), !trimmed.contains("/"), !trimmed.contains("\\"),
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return trimmed
    }

    public static func url(parentCwd: String, handle: String) -> URL {
        directory(parentCwd: parentCwd).appendingPathComponent("\(handle).json", isDirectory: false)
    }

    /// Cap model-bound text at `finalTextByteCap` UTF-8 bytes on a character
    /// boundary. Returns the kept text and whether anything was cut.
    public static func cappedFinalText(_ text: String) -> (text: String, truncated: Bool) {
        guard text.utf8.count > finalTextByteCap else { return (text, false) }
        var kept = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            if bytes + size > finalTextByteCap { break }
            kept.append(character)
            bytes += size
        }
        return (kept, true)
    }

    /// Atomic write via the records' own idiom (no backups: one file per call,
    /// last status wins). Failures are reported, not thrown — a result file is
    /// best-effort courier state and must never fail a spawn.
    @discardableResult
    public static func write(
        _ result: SpawnResultFile,
        parentCwd: String,
        warn: (String) -> Void = { _ in }
    ) -> Bool {
        guard let handle = validatedHandle(result.toolCallId) else { return false }
        do {
            try AtomicWriter(retainedBackups: 0).write(result, to: url(parentCwd: parentCwd, handle: handle))
            return true
        } catch {
            warn("SpawnResultFile: could not write \(result.status.rawValue) for \(handle): \(error)")
            return false
        }
    }
}
