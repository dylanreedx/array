import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// Mode A's surfaces, in every state a person sees them, for the collaboration
/// appearance census and `--shared-agent-render-check <dir>` (light and dark
/// pictures): the guest's shared agent tile live, offline, stopped and as a
/// placeholder on another install; the sharer's tile with its "Yours · shared
/// with Sam" tab; and the arrival banner.
@MainActor
enum SharedAgentAppearance {
    static let size = NSSize(width: 1880, height: 640)

    private struct NoRoute: SharedAgentHandoffTransport {
        struct Unused: Error {}
        func state() async throws -> Collaboration.State { throw Unused() }
        func register(_ request: Collaboration.AgentHostRegistration) async throws -> Collaboration.AgentControlState { throw Unused() }
        func control(object: UUID) async throws -> Collaboration.AgentControlState { throw Unused() }
        func change(object: UUID, request: Collaboration.AgentControlMutation) async throws -> Collaboration.AgentControlState { throw Unused() }
        func send(object: UUID, request: Collaboration.AgentPromptRequest) async throws -> Collaboration.AgentDispatchReceipt { throw Unused() }
        func receipt(id: UUID) async throws -> Collaboration.AgentDispatchReceipt { throw Unused() }
        func pending(host: UUID) async throws -> [Collaboration.AgentDispatchReceipt] { throw Unused() }
        func claim(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { throw Unused() }
        func admit(id: UUID, request: Collaboration.AgentHostClaim) async throws -> Collaboration.AgentDispatchReceipt { throw Unused() }
        func finish(id: UUID, outcome: Collaboration.AgentHostOutcome) async throws -> Collaboration.AgentDispatchReceipt { throw Unused() }
    }

    private final class Canvas: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) { SurfaceToken.canvas.color.nsColor(in: self).setFill(); bounds.fill() }
    }

    static func surface() throws -> NSView {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-shared-agent-appearance-\(UUID())")
        let me = Collaboration.Identity(person: .init(), device: UUID())
        let host = Collaboration.Identity(person: .init(), device: UUID())
        let hostID = SharedArea.ID<SharedArea.Host>()
        let item = SharedArea.Item(id: .init(), kind: .agentObservation, source: .init(owner: host.person, host: hostID, binding: .init()))
        var document = SharedArea.Document()
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
            .admit(item, .init(id: .init(), object: item.id, rect: .init(x: 0, y: 0, width: 400, height: 500), z: 1))]))
        let authority = SharedAreaCheckRig.Authority(document: document, members: [(me, .editor), (host, .owner)])
        let model = try SharedAreaCheckRig.controller(root: root, identity: me, label: "Sam", authority: authority, seed: (document, .editor))
        let snapshot = Collaboration.AgentProjection.Snapshot(host: hostID, object: item.id, generation: 1, history: .assistantOutput,
            phase: .working, capabilities: .init(locallyManaged: true, canSend: true, canQueue: true, canSteer: true, canInterrupt: true),
            rows: [
                .init(id: "p1", turn: "t1", kind: .prompt(host.person), text: "Map every state the checkout can be in and the events that move it."),
                .init(id: "a1", turn: "t1", kind: .assistant, text: "Seven states: Cart, Address, Payment, Authorising, Paid, plus Declined and Abandoned."),
                .init(id: "p2", turn: "t2", kind: .prompt(me.person), text: "Add wallets as their own path."),
                .init(id: "a2", turn: "t2", kind: .assistant, text: "Adding Wallet between Payment and Authorising. A wallet failure returns to Payment.")],
            lastPrompt: .init(person: me.person, at: Date()))
        let names: [SharedArea.ID<SharedArea.Person>: String] = [host.person: "Dylan", me.person: "Sam"]

        let canvas = Canvas(frame: NSRect(origin: .zero, size: size))
        canvas.wantsLayer = true
        let reference = SharedAgentTileReference(areaId: document.id.rawValue, objectId: item.id.rawValue, hostName: "Dylan",
                                                 hostPerson: host.person.rawValue)
        let colour = SharedAreaPersonColour.color(for: host.person, host: host.person)
        func sharedTile(_ state: SharedAgentTileNSView.State, x: CGFloat, live withLive: Bool) throws -> SharedAgentTileNSView {
            let tile = Tile(id: UUID(), kind: .sharedAgent, title: "Map the checkout state machine",
                            frame: .init(x: 0, y: 0, width: 360, height: 540), zPosition: .fromLegacyRank(1), runtimeRef: nil,
                            metadata: .init(sharedAgent: reference))
            let view = SharedAgentTileNSView(tile: tile)
            view.frame = NSRect(x: x, y: 70, width: 360, height: 540)
            if withLive {
                let live = SharedAgentLiveView(controller: model, read: { _, _ in .resnapshot(snapshot) })
                live.personName = { names[$0] }
                live.prompter = try SharedAgentHandoffController(identity: me, transport: NoRoute(),
                    directory: root.appendingPathComponent("handoff-\(UUID())"))
                view.install(live: live)
                live.show(object: item.id, in: document)
                // What the session sets for these states.
                if case .offline = state { live.hostOnline = false }
                if case .stopped = state { live.prompter = nil; live.ended = "No longer shared · showing what arrived before" }
            }
            view.apply(state, hostName: "Dylan", colour: colour)
            canvas.addSubview(view)
            return view
        }
        _ = try sharedTile(.live, x: 20, live: true)
        _ = try sharedTile(.offline(lastSeen: Date().addingTimeInterval(-245)), x: 396, live: true)
        _ = try sharedTile(.stopped("Dylan stopped sharing"), x: 772, live: true)
        _ = try sharedTile(.placeholder("Shared by Dylan · sign in to see it"), x: 1148, live: false)

        // The sharer's own agent tile, with its tab.
        let mine = ManagedAgentTileNSView(tile: Tile(id: UUID(), kind: .managedAgent, title: "Map the checkout state machine",
                                         frame: .init(x: 0, y: 0, width: 330, height: 540), zPosition: .fromLegacyRank(1),
                                         runtimeRef: nil, metadata: .init()))
        mine.frame = NSRect(x: 1524, y: 70, width: 336, height: 540)
        mine.setOwnershipMark(.init(text: "Yours · shared with Sam", colour: colour, outlined: false))
        canvas.addSubview(mine)

        let banner = SharedAgentArrivalBanner(text: "Dylan shared an agent with you. It runs on Dylan's Mac.", colour: colour)
        let bannerSize = banner.preferredSize
        banner.frame = NSRect(x: (size.width - bannerSize.width) / 2, y: 18, width: bannerSize.width, height: bannerSize.height)
        canvas.addSubview(banner)
        return canvas
    }

    /// `--shared-agent-render-check <dir>`: the surface in light and dark, once
    /// the live views have read their projection, as PNGs. Off-screen.
    static func render(to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = try surface()
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = view
            window.orderFrontOffscreenForChecks()
            // The live views poll once and draw.
            try await Task.sleep(for: .milliseconds(600))
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw SharedAreaCheckRig.Failure(description: "no bitmap") }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw SharedAreaCheckRig.Failure(description: "no png") }
            let name = "shared-agent-\(appearance == .aqua ? "light" : "dark").png"
            try png.write(to: directory.appendingPathComponent(name))
            print("WROTE \(directory.appendingPathComponent(name).path)")
            window.orderOut(nil)
        }
    }
}
