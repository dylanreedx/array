import Foundation

/// Serializes only inventory and creation, never a page load or approval.
@MainActor
final class BrowserOpenAdmission {
    private final class Waiter {
        let id: UUID
        let deadline: Date
        let continuation: CheckedContinuation<UUID?, Never>
        init(id: UUID, deadline: Date, continuation: CheckedContinuation<UUID?, Never>) {
            self.id = id; self.deadline = deadline; self.continuation = continuation
        }
    }
    private var owner: UUID?
    private var waiting: [Waiter] = []

    func acquire(deadline: Date) async -> UUID? {
        guard deadline > Date() else { return nil }
        let id = UUID()
        if owner == nil {
            owner = id
            expireReservation(id, deadline: deadline)
            return id
        }
        return await withCheckedContinuation { continuation in
            waiting.append(Waiter(id: id, deadline: deadline, continuation: continuation))
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow)) { [weak self] in
                guard let self, let index = self.waiting.firstIndex(where: { $0.id == id }) else { return }
                self.waiting.remove(at: index).continuation.resume(returning: nil)
            }
        }
    }

    private func expireReservation(_ id: UUID, deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow)) { [weak self] in
            self?.release(id)
        }
    }

    func owns(_ id: UUID) -> Bool { owner == id }

    func qaExpireCurrentReservation() {
        if let owner { release(owner) }
    }

    func release(_ id: UUID) {
        guard owner == id else { return }
        owner = nil
        while !waiting.isEmpty {
            let next = waiting.removeFirst()
            if next.deadline <= Date() { next.continuation.resume(returning: nil); continue }
            owner = next.id
            expireReservation(next.id, deadline: next.deadline)
            next.continuation.resume(returning: next.id)
            break
        }
    }
}
