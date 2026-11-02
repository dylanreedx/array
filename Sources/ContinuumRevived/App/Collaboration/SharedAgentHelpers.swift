import Foundation
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// A shared agent's helpers, both ends (`~/array-scratch/mp-polish/transcript-subagents/STATE.md`).
///
/// The host reads its own child records through the same seams its tile and
/// sidebar read (`turnSnapshot` → `InboxState`); the guest feeds what arrived
/// into the same render seams the host's transcript uses
/// (`AgentReferenceStatusSource`, `AgentMessageSenderSource`), so a chip, a
/// message card and the lead's working glyph answer identically on both Macs.
enum SharedAgentHelpers {
    typealias Wire = SharedAgentTranscriptWire

    /// Every descendant of `lead`, breadth first (parents before children),
    /// siblings in spawn order, capped at `maxHelpers`. A helper whose parent was
    /// capped away is dropped with it, so the roster always nests.
    @MainActor
    static func roster(_ supervisor: AgentSupervisor, lead: AgentID) -> [Wire.Helper] {
        roster(records: Array(supervisor.records.values), lead: lead) { supervisor.turnSnapshot(for: $0) }
    }

    static func roster(records: [AgentRecord], lead: AgentID,
                       turn: (AgentID) -> AgentTileTurnSnapshot?) -> [Wire.Helper] {
        let byParent = Dictionary(grouping: records.filter { $0.parentAgentID != nil }, by: { $0.parentAgentID! })
        var result: [Wire.Helper] = [], frontier = [lead], visited: Set<AgentID> = [lead]
        while !frontier.isEmpty, result.count < Wire.maxHelpers {
            var next: [AgentID] = []
            for parent in frontier {
                let children = (byParent[parent] ?? []).sorted {
                    ($0.createdAt, $0.id.rawValue.uuidString) < ($1.createdAt, $1.id.rawValue.uuidString)
                }
                for child in children where visited.insert(child.id).inserted {
                    guard result.count < Wire.maxHelpers else { break }
                    result.append(helper(child, parent: parent == lead ? nil : parent.rawValue, turn: turn(child.id)))
                    next.append(child.id)
                }
            }
            frontier = next
        }
        return result
    }

    static func helper(_ record: AgentRecord, parent: UUID?, turn: AgentTileTurnSnapshot?) -> Wire.Helper {
        .init(id: record.id.rawValue, parent: parent, name: Wire.helperName(record.displayName),
              origin: record.capabilities == .observedReadOnly ? .provider : .delegated,
              harness: record.harness?.rawValue, state: state(turn), identityColor: record.identityColor,
              spawnedAt: record.createdAt)
    }

    /// The host chip's own mapping (`InboxState.state(forSnapshot:)`); no live
    /// runner reads as `stopped`, which the chip draws with no status.
    static func state(_ turn: AgentTileTurnSnapshot?) -> Wire.HelperState {
        guard let turn else { return .stopped }
        return Wire.HelperState(rawValue: InboxState.state(forSnapshot: turn).rawValue) ?? .ready
    }
}

/// The guest's live helper roster for one shared agent, from the transcript
/// lane's mirror; drives transcript chips, message senders and the rollup.
@MainActor
final class SharedAgentHelperRoster {
    typealias Wire = SharedAgentTranscriptWire

    private(set) var helpers: [Wire.Helper] = []
    /// False until a host that publishes helpers has answered.
    private(set) var known = false
    private var subscribers: [UUID: (agent: UUID, callback: (InboxState?) -> Void)] = [:]
    private var observers: [UUID: () -> Void] = [:]

    var rollup: Wire.HelperRollup { .init(helpers) }

    /// Takes the roster from a replica's state. Nil (an older host) clears it.
    func update(_ next: [Wire.Helper]?) {
        known = next != nil
        let next = next ?? []
        guard next != helpers else { return }
        let before = Dictionary(uniqueKeysWithValues: helpers.map { ($0.id, $0) })
        helpers = next
        let after = Dictionary(uniqueKeysWithValues: next.map { ($0.id, $0) })
        for subscriber in subscribers.values where before[subscriber.agent]?.state != after[subscriber.agent]?.state
            || (before[subscriber.agent] == nil) != (after[subscriber.agent] == nil) {
            subscriber.callback(state(subscriber.agent))
        }
        for observer in observers.values { observer() }
    }

    func helper(_ id: UUID) -> Wire.Helper? { helpers.first { $0.id == id } }

    /// What the host's chip would read for `id` (`InboxState.state(forSnapshot:)`).
    func state(_ id: UUID) -> InboxState? {
        helper(id).flatMap { InboxState(rawValue: $0.state.rawValue) }
    }

    /// Any change to the roster (sidebar rows, the lead's outline and glyph).
    @discardableResult
    func observe(_ observer: @escaping () -> Void) -> UUID {
        let token = UUID(); observers[token] = observer; return token
    }
    func removeObserver(_ token: UUID) { observers[token] = nil }

    /// The guest's `AgentRenderContext.agentStatus`.
    var statusSource: AgentReferenceStatusSource {
        AgentReferenceStatusSource(
            current: { [weak self] id in MainActor.assumeIsolated { self?.state(id) } },
            subscribe: { [weak self] id, callback in
                MainActor.assumeIsolated {
                    guard let self else { return nil }
                    let token = UUID()
                    self.subscribers[token] = (id, callback)
                    return token
                }
            },
            unsubscribe: { [weak self] token in MainActor.assumeIsolated { self?.subscribers[token] = nil } }
        )
    }

    /// The guest's `AgentRenderContext.agentMessageSenders`: a helper's colour,
    /// and no tile to open here, because its tile lives on the host.
    var senderSource: AgentMessageSenderSource {
        AgentMessageSenderSource(current: { [weak self] id in
            MainActor.assumeIsolated {
                self?.helper(id).map { .init(identityColorName: $0.identityColor, hasTile: false) }
            }
        })
    }

    var subscriberCountForQA: Int { subscribers.count }
}
