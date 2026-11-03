import CryptoKit
import Foundation
import ContinuumRevivedAgentUI
import ContinuumRevivedCollaborationProtocol

// Guest sidebar (0.7.40, `~/array-scratch/mp-polish/guest-sidebar-2/`).
//
// Someone else's shared agent, as rows in this Mac's own sidebar: the lead is
// a row like a local agent's, its helpers are its child rows, and the rows go
// through the same `AgentInboxView`, sort, filter, rollup, outline and working
// glyph as every other row. Nothing here is a second list.
//
// What the guest knows comes from the wire only: the lead's phase from its
// projection, its helpers from `SharedAgentHelperRoster`
// (`~/array-scratch/mp-polish/transcript-subagents/STATE.md`), its title from
// the tile, the owner's name from the area. No `AgentRecord` is minted.
//
// Clocks are THIS Mac's: when it first saw the tile, when it saw a turn or a
// helper start working, when a read last changed something. The projection
// carries no host activity times, and a host clock would sort against a
// skewed local one anyway. A helper's `spawnedAt` is the host's, used only to
// order siblings.

/// The rows, from what this Mac knows about each `.sharedAgent` tile.
enum SharedAgentSidebarRows {
    typealias Projection = Collaboration.AgentProjection

    /// How the tile reaches its owner, as `SharedAgentTileSession` reports it.
    enum Connection: Equatable { case connecting, live, offline, stopped }

    /// What one read told the sidebar. Equal facts push nothing.
    struct Facts: Equatable {
        var connection: Connection = .connecting
        var phase: Projection.Phase?
        var helpers: [Projection.Helper] = []
    }

    /// This Mac's clocks for one tile, advanced by `Tracker.note`.
    struct Clocks: Equatable {
        var seenAt: Date
        var lastActiveAt: Date?
        var workingSince: Date?
        var helperWorkingSince: [UUID: Date] = [:]
        var helperLastActive: [UUID: Date] = [:]
    }

    /// One `.sharedAgent` tile on this Mac, with where it sits.
    struct Lead: Equatable {
        var tileId: UUID
        var title: String
        var hostName: String
        var projectId: UUID?
        var projectName: String?
        var workspaceId: UUID?
        var workspaceName: String?
        var facts: Facts
        var clocks: Clocks
        /// The host agent's colour token and character, once the wire carries
        /// them; until then the row draws no dot and the id's own character.
        var identityColor: String? = nil
        var characterName: String? = nil
    }

    /// A helper's row id: stable for its lead tile and host agent id, and
    /// outside both local keyspaces (random v4 record ids and tile ids) by
    /// construction, so a guest that also runs agents, or watches the same
    /// host agent through two areas, never draws one row for two things.
    static func helperRowId(lead tileId: UUID, helper: UUID) -> UUID {
        let key = "array.shared-agent-helper:\(tileId.uuidString):\(helper.uuidString)"
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // name-based
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// The lead's phase as the row's state. The projection folds approval and
    /// input into `needsAction`; both draw "Needs you".
    static func state(_ phase: Projection.Phase?) -> InboxState {
        switch phase {
        case .working?, .starting?: return .working
        case .needsAction?: return .approval
        case .failed?: return .failed
        case .ready?, .stopped?, nil: return .ready
        }
    }

    static func state(_ helper: Projection.HelperState) -> InboxState {
        InboxState(rawValue: helper.rawValue) ?? .ready
    }

    static func harness(_ raw: String?) -> String? {
        switch raw {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "pi": return "Pi"
        default: return nil
        }
    }

    /// "Shared by Dylan", or why it is quiet: the existing where marker, drawn
    /// after the project chip in the row's own metadata style.
    static func marker(_ lead: Lead) -> InboxWhereMarker {
        switch lead.facts.connection {
        case .offline: return InboxWhereMarker(symbol: "person.2", text: "\(lead.hostName) · offline")
        case .stopped: return InboxWhereMarker(symbol: "person.2", text: "\(lead.hostName) stopped sharing")
        case .connecting, .live: return InboxWhereMarker(symbol: "person.2", text: "Shared by \(lead.hostName)")
        }
    }

    static func rows(_ leads: [Lead], now: Date) -> [AgentInboxRow] {
        leads.flatMap { rows(for: $0, now: now) }
    }

    static func rows(for lead: Lead, now: Date) -> [AgentInboxRow] {
        let facts = lead.facts, clocks = lead.clocks
        // Offline or not yet heard: the last phase is history, not news.
        let confirmed = facts.connection == .live && facts.phase != nil
        let stopped = facts.connection == .stopped
        let state = stopped ? .ready : Self.state(facts.phase)
        let shared = InboxSharedAgent(hostName: lead.hostName, tileId: lead.tileId)
        let started = state == .working && confirmed ? clocks.workingSince : nil
        var leadRow = AgentInboxRow(
            id: lead.tileId, title: lead.title, projectName: lead.projectName, projectId: lead.projectId,
            workspaceName: lead.workspaceName, workspaceId: lead.workspaceId, state: state,
            elapsed: started.map { max(0, now.timeIntervalSince($0)) }, elapsedStartedAt: started,
            lastActiveAt: clocks.lastActiveAt ?? clocks.seenAt, createdAt: clocks.seenAt,
            isUnconfirmed: !confirmed && !stopped, settlementBlocked: true,
            identityColor: lead.identityColor, whereMarker: marker(lead),
            characterName: lead.characterName)
        leadRow.sharedAgent = shared
        guard !stopped else { return [leadRow] }
        let present = Set(facts.helpers.map(\.id))
        let helperRows = facts.helpers.map { helper -> AgentInboxRow in
            let state = confirmed ? Self.state(helper.state) : .ready
            let started = state == .working ? clocks.helperWorkingSince[helper.id] : nil
            // A parent capped away by the host never arrives; the helper then
            // hangs off the lead rather than off nothing.
            let parent = helper.parent.flatMap { present.contains($0) ? helperRowId(lead: lead.tileId, helper: $0) : nil }
            var row = AgentInboxRow(
                id: helperRowId(lead: lead.tileId, helper: helper.id), title: helper.name,
                projectName: lead.projectName, projectId: lead.projectId,
                workspaceName: lead.workspaceName, workspaceId: lead.workspaceId, state: state,
                elapsed: started.map { max(0, now.timeIntervalSince($0)) }, elapsedStartedAt: started,
                lastActiveAt: clocks.helperLastActive[helper.id] ?? helper.spawnedAt,
                createdAt: helper.spawnedAt, parentId: parent ?? lead.tileId,
                isUnconfirmed: !confirmed, settlementBlocked: true,
                harness: harness(helper.harness), identityColor: helper.identityColor,
                // Its tile, if it has one, is on the host: here it lives in its lead's card.
                hasTile: false)
            row.sharedAgent = shared
            return row
        }
        return [leadRow] + helperRows
    }

    /// The facts and clocks of every shared tile this Mac has heard from, kept
    /// past its session (a parked tile closes its session; its row stays,
    /// unconfirmed, with what was last known).
    @MainActor
    final class Tracker {
        private(set) var facts: [UUID: Facts] = [:]
        private(set) var clocks: [UUID: Clocks] = [:]

        /// This tile's clocks, starting them on first sight.
        func clocks(for tile: UUID, now: Date) -> Clocks {
            if let existing = clocks[tile] { return existing }
            let fresh = Clocks(seenAt: now)
            clocks[tile] = fresh
            return fresh
        }

        /// Record a read. True when the rows would change.
        @discardableResult
        func note(tile: UUID, _ next: Facts, now: Date) -> Bool {
            var clock = clocks(for: tile, now: now)
            let previous = facts[tile]
            guard previous != next else { return false }
            let wasWorking = previous.map { state($0.phase) == .working } ?? false
            if state(next.phase) == .working {
                if !wasWorking || clock.workingSince == nil { clock.workingSince = now }
            } else {
                clock.workingSince = nil
            }
            let before = Dictionary((previous?.helpers ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var since: [UUID: Date] = [:], last: [UUID: Date] = [:]
            for helper in next.helpers {
                last[helper.id] = clock.helperLastActive[helper.id]
                if helper.state == .working {
                    since[helper.id] = before[helper.id]?.state == .working
                        ? (clock.helperWorkingSince[helper.id] ?? now) : now
                }
                if before[helper.id]?.state != helper.state { last[helper.id] = now }
            }
            clock.helperWorkingSince = since
            clock.helperLastActive = last
            if previous?.phase != next.phase || previous?.helpers != next.helpers { clock.lastActiveAt = now }
            facts[tile] = next
            clocks[tile] = clock
            return true
        }

        func forget(tile: UUID) { facts[tile] = nil; clocks[tile] = nil }
    }
}
