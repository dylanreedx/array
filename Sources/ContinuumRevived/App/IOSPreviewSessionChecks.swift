import AppKit
import ContinuumRevivedCore

/// Drives actual runtime exclusivity, session retention, epochs and input through
/// a deterministic native adapter. Production scene round-trip is checked below
/// by IOSPreviewChecks against its already-mounted scene.
@MainActor
enum IOSPreviewSessionChecks {
    private struct CheckFailure: Error { let message: String }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw CheckFailure(message: message) }
    }
    private static func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(1)) }
        throw CheckFailure(message: "session did not settle")
    }
    private final class Session: IOSPreviewSession {
        var onFrame: ((CGImage) -> Void)?
        var onFailure: ((String) -> Void)?
        var stopped = false
        var inputs: [(Double, Double, Int?)] = []
        var sequence = 0
        var deferObservation: CheckedContinuation<Void, Never>?
        var holdObservation = false
        let image = IOSPreviewChecks.image()
        func start(deviceID: String, allowBoot: Bool, orientation: Int) async throws { onFrame?(image) }
        func send(tag: UInt8, payload: [String: Any]) {}
        func stop() { stopped = true }
        func observe() async throws -> IOSPreviewObservation {
            if holdObservation { await withCheckedContinuation { deferObservation = $0 } }
            sequence += 1
            return IOSPreviewObservation(image: image, orientation: 1, geometryGeneration: 1, sequence: sequence,
                helperEmittedAt: Date(), hostReceivedAt: Date())
        }
        func acknowledgedTap(x: Double, y: Double, geometryGeneration: Int?) async throws { inputs.append((x,y,geometryGeneration)) }
    }
    static func run() async throws {
        let factory = IOSPreviewRuntime.sessionFactory
        var native: [Session] = []
        IOSPreviewRuntime.sessionFactory = { let session = Session(); native.append(session); return session }
        let service = IOSPreviewAutomationSessions()
        let owner = UUID(), project = UUID(), checkout = CheckoutHandle.derive(canonicalRoot: "/isolated/ios-session-check")
        let scope = IOSPreviewAutomationSessions.Scope(principal: owner, project: project, checkout: checkout)
        let foreign = IOSPreviewAutomationSessions.Scope(principal: UUID(), project: project, checkout: checkout)
        let runtime = IOSPreviewRuntime(tileID: UUID(), deviceID: UUID().uuidString)
        defer { for id in Array(service.attachments.keys) { service.release(id: id) }; runtime.disconnect(); IOSPreviewRuntime.sessionFactory = factory }
        runtime.connect(allowBoot: false)
        try await settle { runtime.state == .connected }
        let original = native[0]
        let entry = try service.attach(runtime: runtime, scope: scope)
        let reused = try service.attach(runtime: runtime, scope: scope)
        try expect(reused.id == entry.id, "same host owner must reuse attachment")
        do { _ = try service.attach(runtime: runtime, scope: foreign); throw CheckFailure(message: "foreign owner admitted") }
        catch is IOSPreviewAutomationSessions.Failure {}
        runtime.suspend(); runtime.retireViewer()
        try expect(runtime.state == .connected && !original.stopped, "hidden/retired viewer must retain one active native session")
        let (frameID, frame) = try await service.observe(id: entry.id, scope: scope, authorized: { true })
        try expect(frame.sequence == 1, "observation must reach native adapter")
        try await service.tap(id: entry.id, scope: scope, observationID: frameID, x: Double(frame.image.width) * 0.25,
            y: Double(frame.image.height) * 0.75, authorized: { true })
        try expect(original.inputs.count == 1 && original.inputs[0].0 == 0.25 && original.inputs[0].1 == 0.75,
            "one pixel-space tap must become one normalized native action")
        do { try await service.tap(id: entry.id, scope: foreign, observationID: frameID, x: 0, y: 0, authorized: { true }); throw CheckFailure(message: "foreign tap admitted") }
        catch is IOSPreviewAutomationSessions.Failure {}
        do { try await service.tap(id: entry.id, scope: scope, observationID: UUID(), x: 0, y: 0, authorized: { true }); throw CheckFailure(message: "forged observation admitted") }
        catch is IOSPreviewAutomationSessions.Failure {}
        try expect(original.inputs.count == 1, "rejected targets must cause zero input")
        runtime.resume()
        runtime.humanInputBegan()
        try expect(service.attachments.isEmpty && !original.stopped, "human takeover releases automation while preserving the visible viewer")
        do { _ = try service.attach(runtime: runtime, scope: scope); throw CheckFailure(message: "human control was silently reclaimed") }
        catch is IOSPreviewAutomationSessions.Failure {}
        service.allowAutomation(deviceID: runtime.deviceID)
        let again = try service.attach(runtime: runtime, scope: scope)
        var authorized = true
        original.holdObservation = true
        let pending = Task { try await service.observe(id: again.id, scope: scope, authorized: { authorized }) }
        try await settle { original.deferObservation != nil }
        authorized = false; original.deferObservation?.resume(); original.deferObservation = nil
        do { _ = try await pending.value; throw CheckFailure(message: "revoked image leaked") }
        catch is IOSPreviewAutomationSessions.Failure {}
        try expect(service.attachments.isEmpty, "revoked delivery must release automation")
        original.holdObservation = false
        var clock = ContinuousClock.now
        service.now = { clock }
        let idle = try service.attach(runtime: runtime, scope: scope)
        runtime.suspend()
        clock = clock.advanced(by: .seconds(IOSPreviewAutomationSessions.idleSeconds + 1))
        service.sweep()
        try expect(service.attachments[idle.id] == nil && original.stopped && runtime.state == .disconnected,
            "idle hidden lease must release native capture rather than encode indefinitely")
        try expect(native.count == 1, "view hiding, takeover and observation must not spawn another helper")
        print("IOSPreviewSessionChecks passed: shared helper, exact owner, hidden retention, image-space tap, forged frame/owner rejection, takeover, revoked image delivery and finite idle teardown")
    }
}
