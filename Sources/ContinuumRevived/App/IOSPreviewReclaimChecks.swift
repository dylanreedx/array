import AppKit
import ContinuumRevivedCore

/// `--ios-preview-reclaim-check`: Settings › Advanced › "Shut down simulators
/// no preview is showing". Drives a real preview tile through its parking and
/// visibility hooks over a stand-in simulator; no simctl, helper or tmux.
@MainActor
enum IOSPreviewReclaimChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }
    private static func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }
    private static func settle(_ what: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        try expect(condition(), what)
    }

    /// Stand-in for the simulator: boots only when allowed, as the shipping
    /// session does, and reports a boot the way the shipping session does.
    final class Simulators {
        var booted: Set<String> = []
        var shutdowns: [String] = []
        var holdShutdown = false
        var releaseShutdown: (() -> Void)?
        var holdBoot = false
        var releaseBoot: (() -> Void)?
    }
    final class Session: IOSPreviewSession {
        var onFrame: ((CGImage) -> Void)?
        var onFailure: ((String) -> Void)?
        let simulators: Simulators
        var allowBootValues: [Bool] = []
        init(_ simulators: Simulators) { self.simulators = simulators }
        func start(deviceID: String, allowBoot: Bool, orientation: Int) async throws {
            allowBootValues.append(allowBoot)
            if !simulators.booted.contains(deviceID) {
                guard allowBoot else { throw IOSPreviewError.unavailable("Simulator stopped. Connect to start it again.") }
                if simulators.holdBoot {
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in simulators.releaseBoot = { c.resume() } }
                }
                simulators.booted.insert(deviceID)
                IOSPreviewRuntime.noteArrayBooted(deviceID)
            }
        }
        func send(tag: UInt8, payload: [String: Any]) {}
        func stop() {}
        func stop(completion: @escaping @MainActor () -> Void) { completion() }
    }

    static func run() throws {
        let suite = "continuum-ios-reclaim-check-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(description: "no isolated defaults") }
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let simulators = Simulators()
        var sessions: [Session] = []
        let saved = (IOSPreviewRuntime.sessionFactory, IOSPreviewRuntime.reclaimEnabled,
                     IOSPreviewRuntime.reclaimGraceSeconds, IOSPreviewRuntime.shutdownSimulator)
        IOSPreviewRuntime.sessionFactory = { let s = Session(simulators); sessions.append(s); return s }
        IOSPreviewRuntime.reclaimEnabled = { IOSPreviewReclaimConfig.isEnabled(defaults: defaults) }
        IOSPreviewRuntime.reclaimGraceSeconds = 0.2
        IOSPreviewRuntime.shutdownSimulator = { deviceID in
            simulators.shutdowns.append(deviceID)
            if simulators.holdShutdown {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in simulators.releaseShutdown = { c.resume() } }
            }
            simulators.booted.remove(deviceID)
        }
        defer {
            (IOSPreviewRuntime.sessionFactory, IOSPreviewRuntime.reclaimEnabled,
             IOSPreviewRuntime.reclaimGraceSeconds, IOSPreviewRuntime.shutdownSimulator) = saved
        }
        func tile(_ deviceID: String) -> IOSPreviewTileNSView {
            let tile = Tile(id: UUID(), kind: .iosPreview, title: "iOS Preview", frame: TileFrame(x: 0, y: 0, width: 440, height: 880),
                            zPosition: .fromLegacyRank(1), zoneId: nil, runtimeRef: nil, metadata: TileMetadata(iosPreviewDeviceID: deviceID))
            return IOSPreviewTileNSView(tile: tile, runtime: IOSPreviewRuntime(tileID: tile.id, deviceID: deviceID))
        }
        func returnToView(_ view: IOSPreviewTileNSView) { view.windowOcclusionChanged(visible: true) }
        var summary: [String] = []

        // 1. Off by default: a parked preview keeps its simulator, as before.
        try expect(!IOSPreviewReclaimConfig.isEnabled(defaults: defaults), "the setting must default to off")
        do {
            let device = UUID().uuidString, view = tile(device)
            view.runtime.connect()
            try settle("off: the preview did not boot its simulator") { simulators.booted.contains(device) }
            view.prepareForParking(); pump(0.5)
            try expect(!simulators.shutdowns.contains(device), "off: a parked preview's simulator was shut down")
            returnToView(view)
            try settle("off: the returning preview did not reconnect") { sessions.last?.allowBootValues == [false] }
            view.runtime.disconnect()
            summary.append("off keeps the simulator")
        }
        defaults.set(true, forKey: IOSPreviewReclaimConfig.enabledKey)

        // 2. On: parked past the grace period, the simulator Array booted is
        //    shut down; the tile returning boots it again.
        do {
            let device = UUID().uuidString, view = tile(device)
            view.runtime.connect()
            try settle("on: the preview did not boot its simulator") { simulators.booted.contains(device) }
            view.prepareForParking()
            try settle("on: an unviewed simulator Array booted was not shut down") { simulators.shutdowns == [device] }
            try expect(!simulators.booted.contains(device), "on: the simulator is still booted")
            returnToView(view)
            try settle("on: the returning preview did not boot its simulator again") {
                simulators.booted.contains(device) && sessions.last?.allowBootValues == [true]
            }
            try expect(view.runtime.state == .connecting, "on: the returning preview failed: \(view.runtime.state)")
            view.runtime.disconnect(); pump(0.4); simulators.shutdowns.removeAll()
            summary.append("parked past grace shuts down, return reboots")
        }

        // 3. Back within the grace period: nothing is shut down.
        do {
            let device = UUID().uuidString, view = tile(device)
            view.runtime.connect()
            try settle("grace: no boot") { simulators.booted.contains(device) }
            view.prepareForParking(); pump(0.05); returnToView(view); pump(0.5)
            try expect(simulators.shutdowns.isEmpty, "grace: a preview back within the grace period lost its simulator")
            view.runtime.disconnect(); pump(0.4); simulators.shutdowns.removeAll()
            summary.append("return within grace keeps it")
        }

        // 4. A simulator Array did not boot is never shut down.
        do {
            let device = UUID().uuidString, view = tile(device)
            simulators.booted.insert(device)
            view.runtime.connect()
            try settle("foreign: no connection") { sessions.last?.allowBootValues == [true] }
            view.prepareForParking(); pump(0.5)
            try expect(!simulators.shutdowns.contains(device), "foreign: shut down a simulator Array did not boot")
            view.runtime.disconnect()
            summary.append("never touches a simulator it did not boot")
        }

        // 5. A tile returning mid-shutdown waits, then boots the device again.
        do {
            let device = UUID().uuidString, view = tile(device)
            view.runtime.connect()
            try settle("race: no boot") { simulators.booted.contains(device) }
            simulators.holdShutdown = true
            view.prepareForParking()
            try settle("race: shutdown did not start") { simulators.shutdowns == [device] }
            let started = sessions.count
            returnToView(view); pump(0.1)
            try expect(sessions.count == started, "race: a session started while the simulator was shutting down")
            simulators.holdShutdown = false; simulators.releaseShutdown?()
            try settle("race: the returning preview did not boot after the shutdown finished") {
                sessions.count == started + 1 && sessions.last?.allowBootValues == [true] && simulators.booted.contains(device)
            }
            view.runtime.disconnect(); pump(0.4)
            summary.append("return mid-shutdown waits then reboots")
        }
        // 6. A preview closed while `simctl boot` is still running: the boot
        //    completes after the disconnect, and the device is still reclaimed.
        do {
            let device = UUID().uuidString, view = tile(device)
            simulators.shutdowns.removeAll(); simulators.holdBoot = true
            view.runtime.connect()
            try settle("mid-boot: the boot did not start") { simulators.releaseBoot != nil }
            view.prepareForParking(); pump(0.1)
            simulators.holdBoot = false; simulators.releaseBoot?(); simulators.releaseBoot = nil
            try settle("mid-boot: a simulator booted after its preview closed was never shut down") {
                simulators.shutdowns == [device]
            }
            summary.append("closed mid-boot is still reclaimed")
        }
        print("IOSPreviewReclaimChecks passed: " + summary.joined(separator: "; "))
    }
}
