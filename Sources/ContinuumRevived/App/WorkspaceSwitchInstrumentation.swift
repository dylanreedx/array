import ContinuumRevivedCore
import Foundation
import os

/// What a workspace switch costs, counted rather than timed (`.plans/70` S5).
///
/// A switch used to be one blocking main-thread transaction nobody measured:
/// no signposts, no witness, every fixture with no terminals. These counters are
/// bumped at the sites that made it slow — a tile view built, a spawner built,
/// a synchronous tmux round trip on the main thread, a full tile layout pass, a
/// sidebar reload, a store read — and `--workspace-switch-confidence-check`
/// gates on their deltas across a switch. Counts, because wall-clock on a shared
/// host is noise; the signposts (`dev.arrayapp` / `WorkspaceSwitch`) are for
/// Instruments, where the time is worth reading.
@MainActor
enum WorkspaceSwitchCounters {
    static var tileViewsBuilt = 0
    static var spawnersBuilt = 0
    static var syncTmuxOperationsOnMain = 0
    static var layoutPasses = 0
    static var sidebarReloads = 0

    struct Snapshot: Equatable {
        var tileViewsBuilt: Int
        var spawnersBuilt: Int
        var syncTmuxOperationsOnMain: Int
        var layoutPasses: Int
        var sidebarReloads: Int
        var storeReads: Int

        static func - (lhs: Snapshot, rhs: Snapshot) -> Snapshot {
            Snapshot(
                tileViewsBuilt: lhs.tileViewsBuilt - rhs.tileViewsBuilt,
                spawnersBuilt: lhs.spawnersBuilt - rhs.spawnersBuilt,
                syncTmuxOperationsOnMain: lhs.syncTmuxOperationsOnMain - rhs.syncTmuxOperationsOnMain,
                layoutPasses: lhs.layoutPasses - rhs.layoutPasses,
                sidebarReloads: lhs.sidebarReloads - rhs.sidebarReloads,
                storeReads: lhs.storeReads - rhs.storeReads)
        }

        var dictionary: [String: Int] {
            ["tileViewsBuilt": tileViewsBuilt, "spawnersBuilt": spawnersBuilt,
             "syncTmuxOperationsOnMain": syncTmuxOperationsOnMain, "layoutPasses": layoutPasses,
             "sidebarReloads": sidebarReloads, "storeReads": storeReads]
        }
    }

    static func snapshot() -> Snapshot {
        Snapshot(
            tileViewsBuilt: tileViewsBuilt, spawnersBuilt: spawnersBuilt,
            syncTmuxOperationsOnMain: syncTmuxOperationsOnMain, layoutPasses: layoutPasses,
            sidebarReloads: sidebarReloads, storeReads: AtomicWriter.readCount)
    }
}

/// One switch, as the runtime saw it: which path it took, how long each phase
/// held the main thread, and what it did to the warm set.
struct WorkspaceSwitchReport {
    var from: UUID
    var to: UUID
    /// The target was re-attached from the warm set rather than rebuilt.
    var warm = false
    var succeeded = false
    var failure: String?
    var phases: [(name: String, milliseconds: Double)] = []
    var acquiredProjects = 0
    var evictedWorkspaces: [UUID] = []
    /// File editors that did not answer the scene-transition barrier in time;
    /// their last known draft was kept instead of failing the switch.
    var unansweredEditors = 0

    var dictionary: [String: Any] {
        [
            "from": from.uuidString, "to": to.uuidString, "warm": warm, "succeeded": succeeded,
            "failure": failure ?? NSNull(),
            "phasesMs": Dictionary(phases.map { ($0.name, ($0.milliseconds * 1000).rounded() / 1000) },
                                   uniquingKeysWith: { first, _ in first }),
            "acquiredProjects": acquiredProjects,
            "evictedWorkspaces": evictedWorkspaces.map(\.uuidString),
            "unansweredEditors": unansweredEditors
        ]
    }
}

/// Times a switch's phases into its report and brackets each in a signpost.
@MainActor
final class WorkspaceSwitchPhaseClock {
    private static let signposter = OSSignposter(subsystem: "dev.arrayapp", category: "WorkspaceSwitch")
    private var current: (name: StaticString, start: DispatchTime, state: OSSignpostIntervalState)?
    private(set) var phases: [(name: String, milliseconds: Double)] = []
    private let overall: OSSignpostIntervalState

    init() {
        overall = Self.signposter.beginInterval("switch")
    }

    func begin(_ name: StaticString) {
        end()
        current = (name, DispatchTime.now(), Self.signposter.beginInterval(name))
    }

    func end() {
        guard let current else { return }
        Self.signposter.endInterval(current.name, current.state)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - current.start.uptimeNanoseconds) / 1_000_000
        phases.append(("\(current.name)", elapsed))
        self.current = nil
    }

    func finish() {
        end()
        Self.signposter.endInterval("switch", overall)
    }
}
