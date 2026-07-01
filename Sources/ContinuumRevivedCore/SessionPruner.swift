import Foundation

/// Removes all terminal session descriptors that have a non-nil `lastExit`
/// from the given store. Called once at app boot, before the tile loop, so
/// stale descriptors from previous launches do not accumulate in `sessions/`.
///
/// Best-effort: a failure to list or delete a single session writes a warning
/// to stderr and continues rather than propagating. This mirrors the
/// `listSessions` internal skip-on-error behavior.
public func pruneExitedSessions(in store: any ProjectStoring) {
    let sessions: [TerminalSessionDescriptor]
    do {
        sessions = try store.listSessions()
    } catch {
        fputs("pruneExitedSessions: could not list sessions: \(error)\n", stderr)
        return
    }

    for descriptor in sessions where descriptor.lastExit != nil {
        do {
            try store.deleteSession(id: descriptor.id)
        } catch {
            fputs("pruneExitedSessions: could not delete session \(descriptor.id): \(error)\n", stderr)
        }
    }
}
