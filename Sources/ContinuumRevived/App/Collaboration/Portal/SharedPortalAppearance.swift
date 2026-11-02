import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// Mode B's surfaces, in every state a person sees them, for the collaboration
/// appearance census and `--shared-portal-render-check <dir>` (light and dark
/// pictures): the guest's portal live (an agent, a note card and a terminal
/// card at the host's positions, with the hover's Open beside), offline,
/// stopped and as a placeholder on another install; and the sharer's tile
/// with its "Yours · shared" tab and an "Add to share" offer.
@MainActor
enum SharedPortalAppearance {
    static let size = NSSize(width: 2200, height: 720)

    private final class Canvas: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) { SurfaceToken.canvas.color.nsColor(in: self).setFill(); bounds.fill() }
    }

    /// The live views each portal state shows, kept so the render waits for them.
    private(set) static var bodies: [SharedPortalBodyView] = []

    static func surface() throws -> NSView {
        bodies = []
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("array-shared-portal-appearance-\(UUID())")
        let me = Collaboration.Identity(person: .init(), device: UUID())
        let host = Collaboration.Identity(person: .init(), device: UUID())
        let hostID = SharedArea.ID<SharedArea.Host>()
        let agent = SharedArea.Item(id: .init(), kind: .agentObservation, source: .init(owner: host.person, host: hostID, binding: .init()))
        let note = SharedArea.Item(id: .init(), kind: .artifact, source: .init(owner: host.person, host: hostID, binding: .init()))
        let terminal = SharedArea.Item(id: .init(), kind: .artifact, source: .init(owner: host.person, host: hostID, binding: .init()))
        let rects: [(SharedArea.Item, SharedArea.Rect)] = [
            (agent, .init(x: 0, y: 0, width: 640, height: 520)),
            (note, .init(x: 680, y: 0, width: 420, height: 300)),
            (terminal, .init(x: 680, y: 340, width: 420, height: 180))]
        var document = SharedArea.Document()
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: rects.enumerated().map { index, entry in
            .admit(entry.0, .init(id: .init(), object: entry.0.id, rect: entry.1, z: index)) }))
        let authority = SharedAreaCheckRig.Authority(document: document, members: [(me, .editor), (host, .owner)])
        let model = try SharedAreaCheckRig.controller(root: root, identity: me, label: "Sam", authority: authority, seed: (document, .editor))
        let snapshot = Collaboration.AgentProjection.Snapshot(host: hostID, object: agent.id, generation: 1, history: .assistantOutput,
            phase: .working, capabilities: .init(locallyManaged: true, canSend: true, canQueue: true, canSteer: true, canInterrupt: true),
            rows: [
                .init(id: "p1", turn: "t1", kind: .prompt(host.person), text: "Map every state the checkout can be in."),
                .init(id: "a1", turn: "t1", kind: .assistant, text: "Seven states: Cart, Address, Payment, Authorising, Paid, Declined, Abandoned.")],
            lastPrompt: .init(person: host.person, at: Date()))
        let names: [SharedArea.ID<SharedArea.Person>: String] = [host.person: "Dylan", me.person: "Sam"]
        let colour = SharedAreaPersonColour.color(for: host.person, host: host.person)
        let entries: [SharedArea.ID<SharedArea.Object>: SharedPortal.Entry] = [
            agent.id: .init(object: agent.id, kind: .agent, title: "Map the checkout state machine"),
            note.id: .init(object: note.id, kind: .note, title: "Checkout notes"),
            terminal.id: .init(object: terminal.id, kind: .terminal, title: "Terminal")]

        let canvas = Canvas(frame: NSRect(origin: .zero, size: size))
        canvas.wantsLayer = true
        let reference = SharedPortalTileReference(areaId: document.id.rawValue, hostName: "Dylan", hostPerson: host.person.rawValue, name: "Checkout")
        func portal(_ state: SharedPortalTileNSView.State, x: CGFloat, withBody: Bool, hover: Bool = false) {
            let tile = Tile(id: UUID(), kind: .sharedPortal, title: "Checkout", frame: .init(x: 0, y: 0, width: 440, height: 600),
                            zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: .init(sharedPortal: reference))
            let view = SharedPortalTileNSView(tile: tile)
            view.frame = NSRect(x: x, y: 80, width: 440, height: 600)
            if withBody {
                let guest = SharedPortalGuestContext(controller: model, hostName: "Dylan", hostColour: colour)
                let body = SharedPortalBodyView(controller: model, camera: nil)
                view.install(body: body)
                body.setItems(rects.map { ($0.0.id, $0.1) }) { object in
                    guard let entry = entries[object] else { return nil }
                    if entry.kind == .agent {
                        let item = SharedPortalAgentItemView(entry: entry, guest: guest, read: { _, _ in .resnapshot(snapshot) })
                        item.live.personName = { names[$0] }
                        item.show(in: document)
                        return item
                    }
                    return SharedPortalKinds.kind(for: entry.kind).makeView(entry: entry, guest: guest)
                }
                for item in body.items.values { item.apply(state: state.itemState) }
                bodies.append(body)
                if hover {
                    view.layoutSubtreeIfNeeded()
                    if let frame = body.displayedFrame(for: agent.id) { body.hover(at: NSPoint(x: frame.midX, y: frame.midY)) }
                }
            }
            view.apply(state, hostName: "Dylan", colour: colour)
            canvas.addSubview(view)
        }
        portal(.live, x: 20, withBody: true, hover: true)
        portal(.offline(lastSeen: Date().addingTimeInterval(-245)), x: 480, withBody: true)
        portal(.stopped("Dylan stopped sharing"), x: 940, withBody: true)
        portal(.placeholder("Shared by Dylan · sign in to see it"), x: 1400, withBody: false)

        // The sharer's own note, shared in a portal, and a private note
        // dragged into the region with "Add to share" offered.
        let mine = Tile(id: UUID(), kind: .note, title: "Checkout notes", frame: .init(x: 0, y: 0, width: 300, height: 260),
                        zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: .init())
        let sharedNote = NoteTileNSView(tile: mine, noteId: UUID(), initialBody: "Checkout states: cart, address, payment, paid.")
        sharedNote.frame = NSRect(x: size.width - 300 - 20, y: 80, width: 300, height: 260)
        sharedNote.setOwnershipMark(.init(text: "Yours · shared with Sam", colour: colour, outlined: false))
        canvas.addSubview(sharedNote)
        let late = NoteTileNSView(tile: Tile(id: UUID(), kind: .note, title: "Late note", frame: .init(x: 0, y: 0, width: 300, height: 260),
                                             zPosition: .fromLegacyRank(2), runtimeRef: nil, metadata: .init()),
                                  noteId: UUID(), initialBody: "Wallet retries")
        late.frame = NSRect(x: size.width - 300 - 20, y: 400, width: 300, height: 260)
        let pill = SharedPortalAddPill(title: "Add to share · Checkout")
        let pillSize = pill.preferredSize
        pill.frame = NSRect(x: 300 - pillSize.width - 12, y: TileNSView.titleBarHeight + 8, width: pillSize.width, height: pillSize.height)
        late.addSubview(pill)
        canvas.addSubview(late)

        let banner = SharedAgentArrivalBanner(text: "Dylan shared part of their canvas with you. Everything in it runs on Dylan's Mac.", colour: colour)
        let bannerSize = banner.preferredSize
        banner.frame = NSRect(x: (size.width - bannerSize.width) / 2, y: 20, width: bannerSize.width, height: bannerSize.height)
        canvas.addSubview(banner)
        return canvas
    }

    /// `--shared-portal-render-check <dir>`: the surface in light and dark as
    /// PNGs, off-screen. Fails if a portal state draws no items, if the live
    /// portal's hover offers no "Open beside", or if light and dark render the
    /// same pixels.
    static func render(to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var pngs: [Data] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = try surface()
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = view
            window.orderFrontOffscreenForChecks()
            try await Task.sleep(for: .milliseconds(600))
            view.layoutSubtreeIfNeeded()
            for body in bodies {
                guard body.items.count == 3, body.items.values.allSatisfy({ !$0.frame.isEmpty }) else {
                    throw SharedAreaCheckRig.Failure(description: "a portal state drew \(body.items.count) items")
                }
            }
            guard bodies.first?.qaHoverActionTitles == ["Open beside"] else {
                throw SharedAreaCheckRig.Failure(description: "the live portal's hover offers \(bodies.first?.qaHoverActionTitles ?? [])")
            }
            guard let agent = bodies.first?.items.values.compactMap({ $0 as? SharedPortalAgentItemView }).first,
                  agent.live.transcriptText.contains("Seven states") else {
                throw SharedAreaCheckRig.Failure(description: "the portal's agent did not draw its projection")
            }
            view.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw SharedAreaCheckRig.Failure(description: "no bitmap") }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw SharedAreaCheckRig.Failure(description: "no png") }
            pngs.append(png)
            let name = "shared-portal-\(appearance == .aqua ? "light" : "dark").png"
            try png.write(to: directory.appendingPathComponent(name))
            print("WROTE \(directory.appendingPathComponent(name).path)")
            window.orderOut(nil)
        }
        guard pngs.count == 2, pngs[0] != pngs[1] else { throw SharedAreaCheckRig.Failure(description: "light and dark rendered the same") }
        print("Shared portal render check passed: live, offline, stopped and placeholder portals, the sharer's tab and Add to share, in light and dark.")
    }
}
