import AppKit
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol
import ContinuumRevivedCollaborationClient

private final class HubMemoryVault: CollaborationCredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(service: String, account: String) throws -> Data? { lock.withLock { values[service + account] } }
    func write(_ data: Data, service: String, account: String) throws { lock.withLock { values[service + account] = data } }
    func remove(service: String, account: String) throws { _ = lock.withLock { values.removeValue(forKey: service + account) } }
}
private actor HubTransport: CollaborationAccountTransport {
    let credential = Collaboration.Credential(identity: .init(person: .init(), device: UUID()), token: "synthetic-hub-device-credential")
    let document = SharedArea.Document()
    private(set) var redeemCount = 0
    private(set) var createCount = 0
    private(set) var inviteCount = 0
    private(set) var invitedPerson: SharedArea.ID<SharedArea.Person>?
    private var holdCreate = false
    private var createContinuation: CheckedContinuation<Void, Never>?
    private var holdInvite = false
    private var inviteContinuation: CheckedContinuation<Void, Never>?
    func redeem(code: String, deviceLabel: String) async throws -> Collaboration.Credential { redeemCount += 1; return credential }
    func identity() async throws -> Collaboration.Identity { credential.identity }
    func createArea() async throws -> Collaboration.State {
        createCount += 1
        if holdCreate { await withCheckedContinuation { createContinuation = $0 } }
        return stateValue()
    }
    func state(area: UUID) async throws -> Collaboration.State { stateValue() }
    func accept(code: String) async throws -> Collaboration.Scope { stateValue().scope }
    func invite(area: UUID, person: SharedArea.ID<SharedArea.Person>, role: Collaboration.Role) async throws -> Collaboration.Invitation {
        inviteCount += 1; invitedPerson = person
        if holdInvite { await withCheckedContinuation { inviteContinuation = $0 } }
        return .init(code: "synthetic-invitation-code", expiresAt: Date(timeIntervalSince1970: 1_900_000_000))
    }
    func registerHost() async throws -> Collaboration.Host { .init(id: .init()) }
    func setHoldCreate() { holdCreate = true }
    func releaseCreate() { holdCreate = false; createContinuation?.resume(); createContinuation = nil }
    func setHoldInvite() { holdInvite = true }
    func releaseInvite() { holdInvite = false; inviteContinuation?.resume(); inviteContinuation = nil }
    private func stateValue() -> Collaboration.State { .init(scope: .init(area: document.id, epoch: 1, role: .owner), document: document) }
}

@MainActor
enum CollaborationHubChecks {
    private struct Failure: Error { let message: String }
    private static func expect(_ value: Bool, _ label: String) throws {
        guard value else { throw Failure(message: label) }
        print("PASS collaboration hub: \(label)")
    }
    private static func eventually(_ label: String, _ body: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await body() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure(message: "timeout: \(label)")
    }
    private static func model(root: URL, transport: HubTransport) throws -> CollaborationAccountController {
        try .init(store: CollaborationAccountStore(applicationSupportRoot: root, bundleIdentifier: nil),
            credentialStore: CollaborationCredentialStore(vault: HubMemoryVault(), bundleIdentifier: nil), bundleIdentifier: nil,
            transportFactory: { _, _ in transport })
    }
    static func makeAppearanceFixture() throws -> NSView {
        // The empty registry does not create files. No real vault or transport is
        // constructed or called while this fixture paints the disconnected hub.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-hub-appearance-\(UUID())")
        return CollaborationHubView(model: try model(root: root, transport: HubTransport()))
    }
    private static func field(_ label: String, in view: NSView) throws -> NSTextField {
        guard let found = view.subviews.compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityLabel() == label }) else {
            throw Failure(message: "missing input: \(label)")
        }
        return found
    }
    private static func click(_ label: String, in view: NSView) throws {
        guard let found = view.subviews.compactMap({ $0 as? NSControl }).first(where: { $0.accessibilityLabel() == label }), found.isEnabled else {
            throw Failure(message: "missing enabled action: \(label)")
        }
        guard found.sendAction(found.action, to: found.target) else { throw Failure(message: "action not wired: \(label)") }
    }
    static func run(delegate: AppDelegate) async throws {
        guard let parent = ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] else { throw Failure(message: "isolated app support required") }
        let root = URL(fileURLWithPath: parent).appendingPathComponent("hub-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = HubTransport(), model = try model(root: root, transport: transport)
        let hub = delegate.presentCollaborationHub(model: model)
        let view = hub.content
        var opened = 0
        view.onOpenArea = { _, _, _ in opened += 1 }
        try expect(await transport.redeemCount == 0 && model.activeAccount == nil, "opening the shipping hub constructs no login or network request")
        try field("Collaboration service URL", in: view).stringValue = "https://collaboration-hub.example.test"
        try field("One-time Array enrollment code", in: view).stringValue = "synthetic-enrollment-code"
        try click("Connect", in: view)
        try await eventually("native enrollment") { model.status == .ready }
        try expect(await transport.redeemCount == 1 && model.accounts.count == 1, "native Connect uses Array enrollment and saves a scoped account once")
        try click("Create workspace", in: view)
        try await eventually("native area open") { opened == 1 }
        try expect(await transport.createCount == 1 && model.activeAccount?.knownAreas.count == 1, "native Create opens and remembers the admitted area through its production callback")
        let teammate = UUID()
        try field("Teammate collaboration ID", in: view).stringValue = teammate.uuidString
        try click("Create invitation", in: view)
        try await eventually("native targeted invite") { await transport.inviteCount == 1 }
        try expect(await transport.invitedPerson?.rawValue == teammate, "native invitation targets the entered collaboration person")
        try await eventually("invitation finished") { !model.isBusy }
        await transport.setHoldInvite()
        try click("Create invitation", in: view)
        try await eventually("held invitation") { await transport.inviteCount == 2 }
        view.setOpenArea(UUID())
        await transport.releaseInvite()
        try await eventually("old invitation finished") { !model.isBusy }
        try expect(!view.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.contains(where: { $0.contains("synthetic-invitation-code") }),
            "retargeting the hub discards a late invitation reply from the previous workspace")
        try expect(try field("Collaboration status", in: view).stringValue.hasPrefix("Ready."),
            "a discarded invitation leaves a completed status instead of a false connection activity")
        if let area = model.activeAccount?.knownAreas.first?.id { view.setOpenArea(area, role: .owner) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let probe = try UIProbe.render(.init(id: "collaboration.hub.\(appearance.rawValue)", size: .init(width: 680, height: 720), appearance: appearance), make: { view })
            try expect(probe.view.effectiveAppearance.tokenTheme == (appearance == .aqua ? .light : .dark), "hub renders in \(appearance.rawValue)")
            try retainImage(probe, name: "hub-\(appearance == .aqua ? "light" : "dark")")
            let sceneRoot = try SharedAreaSceneChecks.makeAppearanceFixture()
            func scene(in root: NSView) -> SharedAreaSceneView? {
                if let scene = root as? SharedAreaSceneView { return scene }
                return root.subviews.lazy.compactMap { scene(in: $0) }.first
            }
            if let mounted = scene(in: sceneRoot) {
                await mounted.controller.open()
                let sceneProbe = try UIProbe.render(.init(id: "collaboration.scene.\(appearance.rawValue)", size: .init(width: 960, height: 680), appearance: appearance), make: { sceneRoot })
                try retainImage(sceneProbe, name: "scene-\(appearance == .aqua ? "light" : "dark")")
                try expect(mounted.controller.status == .connected, "shared scene renders an admitted connected fixture in \(appearance.rawValue)")
                mounted.unmount(); await mounted.controller.close()
            } else { throw Failure(message: "appearance fixture has no mounted shared scene") }
        }
        // A late successful create response after closing the hub cannot open a
        // window, write a new selected scope, or consume another enrollment.
        await transport.setHoldCreate()
        try click("Create workspace", in: view)
        try await eventually("held create") { await transport.createCount == 2 }
        let pending = view.stop()
        await transport.releaseCreate()
        await pending?.value
        try expect(opened == 1 && model.activeAccount == nil && model.status == .signedOut,
            "closing the hub fences a late workspace response and preserves existing source work")
        hub.window.close()
    }
    private static func retainImage(_ probe: UIProbe.Probed, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["CONTINUUM_COLLABORATION_RENDER_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let bytes = probe.hostRep.representation(using: .png, properties: [:]) else { throw Failure(message: "PNG encoding failed") }
        try bytes.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }
}
