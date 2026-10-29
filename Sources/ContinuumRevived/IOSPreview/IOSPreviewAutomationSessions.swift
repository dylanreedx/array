import Foundation
import ContinuumRevivedCore

/// App-owned attachments: the tile remains a viewer of the same native runtime.
/// This layer never mints permission, selects a project, boots or creates a tile.
@MainActor
final class IOSPreviewAutomationSessions {
    static let shared = IOSPreviewAutomationSessions()
    static let idleSeconds: TimeInterval = 30
    enum Failure: Error { case busy, notOwned, staleObservation, unavailable, permissionDenied, handoverRequired }
    struct Scope: Equatable, Sendable {
        let principal: UUID
        let project: UUID
        let checkout: CheckoutHandle
    }
    @MainActor
    final class Attachment {
        let id = UUID()
        let scope: Scope
        let runtime: IOSPreviewRuntime
        let connection: UUID
        let control: UInt64
        var touchedAt: ContinuousClock.Instant
        var observation: (id: UUID, value: IOSPreviewObservation, expiresAt: ContinuousClock.Instant)?
        var inFlight: Task<Void, Error>?
        var observing = false
        init(scope: Scope, runtime: IOSPreviewRuntime, now: ContinuousClock.Instant) {
            self.scope = scope; self.runtime = runtime; connection = runtime.connectionID
            control = runtime.controlGeneration; touchedAt = now
        }
    }
    private(set) var attachments: [UUID: Attachment] = [:]
    var now: () -> ContinuousClock.Instant = { .now }
    private var timer: Timer?
    private var reclaimedDevices: [String: UUID] = [:]
    func isReclaimed(deviceID: String?) -> Bool { deviceID.map { reclaimedDevices[$0] != nil } ?? false }
    func reclaim(deviceID: String, tileID: UUID) { reclaimedDevices[deviceID] = tileID }
    func allowAutomation(deviceID: String?) { if let deviceID { reclaimedDevices[deviceID] = nil } }

    func attach(runtime: IOSPreviewRuntime, scope: Scope, displayName: String = "Agent") throws -> Attachment {
        sweep()
        guard !isReclaimed(deviceID: runtime.deviceID) else { throw Failure.handoverRequired }
        if let current = attachments.values.first(where: { $0.runtime.tileID == runtime.tileID }) {
            guard current.scope == scope else { throw Failure.notOwned }
            _ = try validate(id: current.id, scope: scope); current.touchedAt = now(); return current
        }
        guard runtime.state == .connected, runtime.deviceID != nil else { throw Failure.unavailable }
        guard attachments.count < 2, !attachments.values.contains(where: { $0.scope.principal == scope.principal }) else { throw Failure.busy }
        let entry = Attachment(scope: scope, runtime: runtime, now: now())
        attachments[entry.id] = entry
        runtime.setAutomationRetained(true, controllerName: String(displayName.prefix(100)))
        let attachmentID = entry.id
        runtime.onAutomationInvalidated = { [weak self] in self?.release(id: attachmentID) }
        let deviceID = runtime.deviceID!, tileID = runtime.tileID
        runtime.onHumanTakeover = { [weak self] in
            self?.reclaimedDevices[deviceID] = tileID
            self?.release(id: attachmentID)
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sweep() }
            }
        }
        return entry
    }
    func retainedRuntime(tileID: UUID, deviceID: String?) -> IOSPreviewRuntime? {
        attachments.values.first { $0.runtime.tileID == tileID && $0.runtime.deviceID == deviceID }?.runtime
    }
    func validate(id: UUID, scope: Scope) throws -> Attachment {
        guard let entry = attachments[id], entry.scope == scope else { throw Failure.notOwned }
        if entry.inFlight == nil, !entry.observing, entry.touchedAt.duration(to: now()) >= .seconds(Self.idleSeconds) {
            release(id: id); throw Failure.notOwned
        }
        guard entry.runtime.state == .connected, entry.runtime.connectionID == entry.connection,
              entry.runtime.controlGeneration == entry.control else { release(id: id); throw Failure.unavailable }
        return entry
    }
    func observe(id: UUID, scope: Scope, authorized: @escaping () -> Bool) async throws -> (UUID, IOSPreviewObservation) {
        try Task.checkCancellation()
        guard authorized() else { throw Failure.permissionDenied }
        let entry = try validate(id: id, scope: scope)
        guard !entry.observing, entry.inFlight == nil else { throw Failure.busy }
        entry.observing = true; entry.touchedAt = now()
        defer { entry.observing = false; entry.touchedAt = now() }
        let value = try await entry.runtime.observe()
        try Task.checkCancellation()
        guard authorized() else { release(id: id); throw Failure.permissionDenied }
        _ = try validate(id: id, scope: scope)
        let observationID = UUID()
        entry.observation = (observationID, value, now().advanced(by: .seconds(Self.idleSeconds)))
        return (observationID, value)
    }
    func tap(id: UUID, scope: Scope, observationID: UUID, x: Double, y: Double, authorized: @escaping () -> Bool) async throws {
        try await act(id: id, scope: scope, observationID: observationID, action: .tap(x: x, y: y), authorized: authorized)
    }
    /// Coordinates here are upright observation pixels. Transform both swipe
    /// endpoints exactly once, with the same epoch/grant/lease fences as taps.
    func act(id: UUID, scope: Scope, observationID: UUID, action: IOSPreviewBoundedAction, authorized: @escaping () -> Bool) async throws {
        try Task.checkCancellation()
        guard authorized() else { throw Failure.permissionDenied }
        let entry = try validate(id: id, scope: scope)
        guard entry.inFlight == nil, !entry.observing else { throw Failure.busy }
        guard let observation = entry.observation, observation.id == observationID, observation.expiresAt > now() else { throw Failure.staleObservation }
        func point(_ x: Double, _ y: Double) throws -> (x: Double, y: Double) {
            guard x.isFinite, y.isFinite, x >= 0, y >= 0,
                  x < Double(observation.value.image.width), y < Double(observation.value.image.height),
                  let raw = IOSPreviewImageGeometry.rawPoint(x: x / Double(observation.value.image.width),
                    y: y / Double(observation.value.image.height), orientation: observation.value.orientation) else { throw Failure.staleObservation }
            return (Double(raw.x), Double(raw.y))
        }
        let native: IOSPreviewBoundedAction
        switch action {
        case let .tap(x, y):
            let raw = try point(x, y); native = .tap(x: raw.x, y: raw.y)
        case let .swipe(x, y, endX, endY, milliseconds):
            let from = try point(x, y), to = try point(endX, endY)
            native = .swipe(x: from.x, y: from.y, endX: to.x, endY: to.y, milliseconds: milliseconds)
        default: native = action
        }
        guard native.payload != nil else { throw IOSPreviewActionChannel.Failure.rejected }
        entry.touchedAt = now()
        let task = Task { [weak self] in
            try Task.checkCancellation()
            guard let self, authorized() else { throw Failure.permissionDenied }
            _ = try self.validate(id: id, scope: scope)
            try await entry.runtime.acknowledgedAction(native, geometryGeneration: observation.value.geometryGeneration)
        }
        entry.inFlight = task
        defer { entry.inFlight = nil; entry.touchedAt = now() }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard authorized() else { release(id: id); throw IOSPreviewActionChannel.Failure.outcomeUnknown }
        do { _ = try validate(id: id, scope: scope) }
        catch { throw IOSPreviewActionChannel.Failure.outcomeUnknown }
        if case .rotate = native { entry.observation = nil }
    }
    func close(id: UUID, scope: Scope) throws {
        _ = try validate(id: id, scope: scope); release(id: id)
    }
    func revoke(principal: UUID) {
        for entry in Array(attachments.values) where entry.scope.principal == principal { release(id: entry.id) }
    }
    func release(id: UUID) {
        guard let entry = attachments.removeValue(forKey: id) else { return }
        entry.inFlight?.cancel(); entry.observation = nil
        entry.runtime.onAutomationInvalidated = nil; entry.runtime.onHumanTakeover = nil
        entry.runtime.setAutomationRetained(false)
        if attachments.isEmpty { timer?.invalidate(); timer = nil }
    }
    func sweep() {
        for entry in Array(attachments.values) where entry.inFlight == nil && !entry.observing && entry.touchedAt.duration(to: now()) >= .seconds(Self.idleSeconds) {
            release(id: entry.id)
        }
    }
}
