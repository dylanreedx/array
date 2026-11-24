import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

// Unshare always finishes on this Mac. Revoke stops hosting, forgets the share
// and clears the tile's marks at once, with no relay round trip in the way.
// What the relay still holds (live links, people they let in, the published
// item) is cleaned up here, after the fact: the area is written down first, so
// a relay that is slow, unreachable, or has lost the area cannot keep a tile
// "shared", and a quit or crash mid-unshare picks up again at the next launch.

/// The areas this Mac has stopped sharing whose relay side is not cleaned up
/// yet. App state, beside the hosted-share indexes.
@MainActor
final class PendingShareRevocations {
    struct Entry: Codable, Equatable {
        let account: String
        let area: UUID
    }
    private struct File: Codable { var schema = 1; var entries: [Entry] }

    let url: URL
    private(set) var entries: [Entry]

    init(directory: URL) {
        url = directory.appendingPathComponent("pending-revocations.json")
        entries = (try? JSONDecoder().decode(File.self, from: Data(contentsOf: url)))?.entries ?? []
    }
    func contains(area: UUID) -> Bool { entries.contains { $0.area == area } }
    func entries(account: String) -> [Entry] { entries.filter { $0.account == account } }
    func add(_ entry: Entry) throws {
        guard !entries.contains(entry) else { return }
        let previous = entries
        entries.append(entry)
        do { try save() } catch { entries = previous; throw error }
    }
    func remove(area: UUID) {
        guard contains(area: area) else { return }
        entries.removeAll { $0.area == area }
        try? save()
    }
    private func save() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(File(entries: entries)).write(to: url, options: .atomic)
    }
}

/// What one relay clean-up attempt came to.
enum ShareRevocationOutcome: Equatable {
    /// Every link is revoked, or the relay no longer has the area for us.
    case done
    /// Try again later: the relay could not be reached or did not answer in time.
    case retry
}

extension AppDelegate {
    var pendingShareRevocations: PendingShareRevocations? {
        if let pendingShareRevocationsStorage { return pendingShareRevocationsStorage }
        guard let model = try? collaborationAccountModel() else { return nil }
        let index = PendingShareRevocations(directory: model.storeDirectory)
        pendingShareRevocationsStorage = index
        return index
    }

    /// The host closed (deleted) a tile it shares. A tile shared on its own
    /// ends its share; a portal ends once none of its tiles is left on this
    /// canvas. The rest of the portal stays shared.
    func endSharesOnTileClose(_ tile: UUID) {
        var areas: [UUID] = hostedAgentShares?.entries.filter { $0.tile == tile }.map(\.area) ?? []
        if let canvas = canvasView {
            for entry in hostedPortalIndex?.entries ?? [] where entry.tiles.contains(where: { $0.tile == tile }) {
                let left = entry.tiles.filter { $0.tile != tile && canvas.tileRecord(for: $0.tile) != nil }
                if left.isEmpty { areas.append(entry.area) }
            }
        }
        guard !areas.isEmpty else { return }
        Task { [weak self] in
            for area in areas {
                do { try await self?.stopSharing(area: area) }
                catch { fputs("endSharesOnTileClose: \(area) stays shared: \(error)\n", stderr) }
            }
        }
    }

    /// How long one area's relay clean-up may take before it is left for the
    /// next pass. Nothing waits on it but the clean-up itself.
    static var shareRevocationAttemptDeadline: Duration = .seconds(45)
    /// Pause before the next pass while some area is still pending.
    static var shareRevocationRetryDelay: Duration = .seconds(30)

    /// Runs a pass now unless one is running; a pass that leaves work schedules
    /// the next. Never asks for a sign-in: with no ready account it waits.
    func reconcilePendingShareRevocations() {
        guard shareRevocationTask == nil else { shareRevocationRerun = true; return }
        shareRevocationTask = Task { [weak self] in
            guard let self else { return }
            var remaining = await self.shareRevocationPass()
            while remaining > 0 || self.shareRevocationRerun {
                if !self.shareRevocationRerun {
                    try? await Task.sleep(for: Self.shareRevocationRetryDelay)
                    if Task.isCancelled { break }
                }
                self.shareRevocationRerun = false
                remaining = await self.shareRevocationPass()
            }
            self.shareRevocationTask = nil
        }
    }

    /// One attempt at every pending area of the ready account. Returns how
    /// many are left.
    private func shareRevocationPass() async -> Int {
        guard let pending = pendingShareRevocations, !pending.entries.isEmpty,
              let model = try? collaborationAccountModel() else { return 0 }
        if model.status != .ready { await Self.awaitPortalAccount(model) }
        // Still signed out: keep the entries for the next launch or unshare.
        guard model.status == .ready, let account = model.activeAccount?.id else { return 0 }
        for entry in pending.entries(account: account) {
            let outcome = await Self.withDeadline(Self.shareRevocationAttemptDeadline, fallback: .retry) {
                await self.revokeOnRelay(area: entry.area, model: model)
            }
            if outcome == .done { pending.remove(area: entry.area) }
        }
        return pending.entries.count
    }

    /// Ends every link on the area that still admits or holds someone, then
    /// takes the published items out so a teammate's tile reads "stopped
    /// sharing". A relay that answers 403/404 has nothing left for us to end.
    func revokeOnRelay(area: UUID, model: CollaborationAccountController) async -> ShareRevocationOutcome {
        do {
            let rows = try await ShareLinkCoordinator.waitingOutBusy(deadline: .seconds(10)) { try await model.shareLinks(area: area) }
            for row in rows where row.status != .revoked {
                try await ShareLinkCoordinator.waitingOutBusy(deadline: .seconds(10)) { try await model.revokeShareLink(area: area, link: row.id) }
            }
        } catch let error as CollaborationClientError {
            if case .server(let status, _) = error, status == 403 || status == 404 || status == 410 { return .done }
            return .retry
        } catch {
            return .retry
        }
        if let controller = try? model.makeSharedAreaController(area: area) {
            await controller.open()
            if let document = controller.document, !document.items.isEmpty, controller.canSubmit {
                _ = await controller.submit(.init(area: document.id, expectedRevision: document.revision,
                                                  edits: document.items.map { .remove($0.id) }))
            }
            await controller.close()
        }
        return .done
    }

    /// `body`'s result, or `fallback` once `deadline` passes. A body that
    /// ignores cancellation is left to finish on its own; the caller moves on.
    static func withDeadline<T: Sendable>(_ deadline: Duration, fallback: T,
                                          _ body: @escaping @MainActor () async -> T) async -> T {
        let once = DeadlineOnce()
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            work = Task { @MainActor in
                let value = await body()
                if once.claim() { continuation.resume(returning: value) }
            }
            timer = Task {
                try? await Task.sleep(for: deadline)
                if once.claim() { continuation.resume(returning: fallback) }
            }
        }
        timer?.cancel(); work?.cancel()
        return result
    }
}

/// Resumes a deadline race's continuation once, whichever side wins.
private final class DeadlineOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
