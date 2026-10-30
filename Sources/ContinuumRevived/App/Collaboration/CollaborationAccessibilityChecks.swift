import AppKit
import Foundation
import ContinuumRevivedCore
import ContinuumRevivedCollaborationProtocol

/// Keyboard parity and Reduce Motion for the collaboration surfaces (COL-21).
///
/// Every key goes through `NSApp.sendEvent` into the production window
/// controllers, which the check-focus guard parks off every display; the app is
/// never activated. Focus is read back from the window, never set by the check
/// except where a step names it.
@MainActor
enum CollaborationAccessibilityChecks {
    private typealias Rig = SharedAreaCheckRig
    private static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw Rig.Failure(description: message) }
        print("PASS collaboration accessibility: \(message)")
    }

    static func run(delegate: AppDelegate) async throws {
        try await runSceneKeyboard(delegate: delegate)
        try await runHubKeyboard()
        try await runCaptureKeyboard()
        try await runHandoffKeyboard()
        try await runReduceMotion(delegate: delegate)
        print("Collaboration accessibility passed: real-key focus loops and activation across scene, hub, capture review and handoff; follow glides or jumps by Reduce Motion.")
    }

    // MARK: - Key delivery

    /// The window AppKit treats as key: a presented choice panel, else `window`.
    private static func keyTarget(_ window: NSWindow) -> NSWindow {
        NSApp.windows.first { $0.isKeyWindow && $0.parent === window } ?? window
    }
    private static func press(_ window: NSWindow, _ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) throws {
        let target = keyTarget(window)
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else {
            throw Rig.Failure(description: "could not construct key \(code)")
        }
        NSApp.sendEvent(event)
    }
    /// A real Shift-Tab arrives as the back-tab character, which text views
    /// bind to `insertBacktab:`; a tab with Shift held would read as Tab.
    private static func tab(_ window: NSWindow, backwards: Bool = false) throws {
        try press(window, 48, backwards ? "\u{19}" : "\t", backwards ? [.shift] : [])
    }
    private static func controlTab(_ window: NSWindow) throws { try press(window, 48, "\t", [.control]) }
    private static func space(_ window: NSWindow) throws { try press(window, 49, " ") }
    private static func enter(_ window: NSWindow) throws { try press(window, 36, "\r") }
    private static func down(_ window: NSWindow) throws {
        try press(window, 125, String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), [.numericPad, .function])
    }
    private static func typeText(_ window: NSWindow, _ text: String) throws {
        for character in text { try press(window, 0, String(character)) }
    }

    /// The control a person is on: a text field rather than its field editor.
    private static func focused(_ window: NSWindow) -> NSView? {
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView { return field }
        return window.firstResponder as? NSView
    }
    private static func name(_ view: NSView?) -> String {
        guard let view else { return "nil" }
        return view.accessibilityLabel() ?? String(describing: type(of: view))
    }
    /// Controls a keyboard user must be able to reach: every visible, enabled
    /// stop that takes focus. Generic on purpose, so a control added later that
    /// is left out of its surface's loop fails here.
    private static func reachableControls(in root: NSView) -> [NSView] {
        Rig.descendants(root).filter { view in
            guard !view.isHiddenOrHasHiddenAncestor, view.acceptsFirstResponder else { return false }
            if let field = view as? NSTextField { return field.isEditable }
            if let text = view as? NSTextView { return !text.isFieldEditor }
            return view is NSControl || view.accessibilityLabel() == "Shared objects"
        }
    }
    /// The shared canvas keeps Tab for cycling its objects; Control-Tab leaves it.
    private static func ownsTab(_ view: NSView?) -> Bool { view?.accessibilityLabel() == "Shared objects" }
    /// One step of keyboard navigation, as a person would take it.
    private static func step(_ window: NSWindow, backwards: Bool = false) throws {
        if ownsTab(focused(window)) { try press(window, 48, backwards ? "\u{19}" : "\t", backwards ? [.control, .shift] : [.control]) }
        else { try tab(window, backwards: backwards) }
    }
    /// Steps until focus returns to where it started.
    private static func walk(_ window: NSWindow, backwards: Bool = false) throws -> [NSView] {
        guard let start = focused(window) else { throw Rig.Failure(description: "no initial keyboard focus") }
        var visited: [NSView] = []
        for _ in 0..<40 {
            let before = focused(window)
            try step(window, backwards: backwards)
            if focused(window) === before { throw Rig.Failure(description: "keyboard focus stuck on \(name(before)) after \(visited.map(name))") }
            guard let now = focused(window) else { throw Rig.Failure(description: "Tab left nothing focused after \(visited.map(name))") }
            if now === start { return visited }
            visited.append(now)
        }
        throw Rig.Failure(description: "Tab never returned to \(name(start)); visited \(visited.map(name))")
    }
    private static func assertLoop(_ window: NSWindow, root: NSView, order expected: [String], surface: String) throws {
        let start = focused(window)
        let forward = try walk(window)
        let names = [name(start)] + forward.map(name)
        let dump = names == expected ? "" : " — got \(names.joined(separator: " → ")); stops: " + Rig.descendants(root)
            .filter { $0.nextKeyView != nil }
            .map { "\(name($0))[enabled \(($0 as? NSControl)?.isEnabled ?? true) first \($0.acceptsFirstResponder) key \($0.canBecomeKeyView) hidden \($0.isHiddenOrHasHiddenAncestor) next \(name($0.nextKeyView))]" }
            .joined(separator: "; ")
        try expect(names == expected, "\(surface): Tab visits \(expected.joined(separator: " → ")) in reading order\(dump)")
        let missing = reachableControls(in: root).filter { control in !([start] + forward).contains { $0 === control } }
        try expect(missing.isEmpty, "\(surface): every visible enabled control is in the Tab loop\(missing.isEmpty ? "" : " — missing \(missing.map(name))")")
    }
    /// Opens a choice menu with Space, moves with Down and accepts with Return.
    private static func choose(_ button: ChoiceButton, _ id: String, in window: NSWindow) throws {
        guard focused(window) === button else { throw Rig.Failure(description: "\(name(button)) is not focused") }
        try space(window)
        guard let list = button.qaPresentedList else { throw Rig.Failure(description: "Space did not open \(name(button))") }
        for _ in 0..<40 where list.focusedID != id { try down(window) }
        guard list.focusedID == id else { throw Rig.Failure(description: "Down never reached \(id) in \(name(button))") }
        try enter(window)
        guard button.qaPresentedList == nil else { throw Rig.Failure(description: "Return did not close \(name(button))") }
        // With the app active, AppKit gives key status back to the parent when
        // the key menu panel orders out. A check never activates the app, so it
        // re-keys the parent; the focus assertion below is the production half.
        if !window.isKeyWindow { window.makeKey() }
        guard focused(window) === button else { throw Rig.Failure(description: "focus did not return to \(name(button)) after choosing") }
    }
    private static func focus(_ window: NSWindow, on target: NSView) throws {
        var path: [String] = []
        for _ in 0..<40 {
            if focused(window) === target { return }
            try step(window)
            path.append(name(focused(window)))
        }
        throw Rig.Failure(description: "Tab never reached \(name(target)); went \(path.prefix(12).joined(separator: " → ")); key window \(keyTarget(window) === window ? "shared" : "panel")")
    }
    private static func choice(_ label: String, in root: NSView) throws -> ChoiceButton {
        guard let button = Rig.descendants(root).compactMap({ $0 as? ChoiceButton }).first(where: { $0.accessibilityLabel() == label }) else {
            throw Rig.Failure(description: "missing choice \(label)")
        }
        return button
    }

    // MARK: - Shared scene

    private static func runSceneKeyboard(delegate: AppDelegate) async throws {
        let root = try Rig.root("keyboard-scene")
        defer { try? FileManager.default.removeItem(at: root) }
        let me = Collaboration.Identity(person: .init(), device: UUID()), mate = Collaboration.Identity(person: .init(), device: UUID())
        let discussion = SharedArea.Item(id: .init(), kind: .discussion), agreement = SharedArea.Item(id: .init(), kind: .agreement)
        let revision = SharedArea.Context(id: .init(), object: agreement.id, parent: nil, author: mate.person, text: "Agents keep changes in the parser.")
        var document = SharedArea.Document()
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
            .admit(discussion, .init(id: .init(), object: discussion.id, rect: .init(x: 40, y: 40, width: 260, height: 180), z: 1)),
            .admit(agreement, .init(id: .init(), object: agreement.id, rect: .init(x: 340, y: 40, width: 300, height: 200), z: 2)),
            .context(revision)]))
        let authority = Rig.Authority(document: document, members: [(me, .owner), (mate, .editor)])
        let model = try Rig.controller(root: root.appendingPathComponent("me"), identity: me, label: "Peer Me", authority: authority)
        let controller = SharedAreaWindowController(controller: model, person: me.person, delegate: delegate)
        defer { controller.window.close() }
        controller.show(); await controller.waitUntilOpen()
        let window = controller.window, scene = controller.scene
        window.layoutIfNeeded()
        try await authority.setPresence(.init(identity: mate, cursor: .init(x: 100, y: 90),
            viewport: .init(x: 0, y: 0, width: 700, height: 500), expiresAt: Date().addingTimeInterval(60), label: "Peer Mate"))
        try await Rig.eventually("teammate offered for follow") { scene.followTargets.map(\.device) == [mate.device] }
        try expect(focused(window) === scene.areaCanvasView, "the shared window opens with keyboard focus on the shared canvas")

        try press(window, 48, "\t")
        try expect(scene.selectedObject != nil && focused(window) === scene.areaCanvasView, "Tab inside the canvas selects a shared object and keeps focus there")
        let camera = scene.localViewCamera
        try press(window, 124, String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), [.numericPad, .function])
        try expect(scene.localViewCamera.x > camera.x, "an arrow key pans the shared canvas")

        let objects = try choice("Objects", in: scene), workspace = try choice("Workspace", in: scene)
        try controlTab(window)
        try expect(focused(window) === objects, "Control-Tab leaves the canvas for the Objects menu")
        try choose(objects, agreement.id.rawValue.uuidString, in: window)
        try await Rig.eventually("agreement selected by keys") { scene.selectedObject == agreement.id }
        window.layoutIfNeeded()
        try focus(window, on: scene.areaCanvasView)
        try assertLoop(window, root: scene, order: ["Shared objects", "Objects", "Workspace", "History", "Endorse revision 1",
            "Selected shared entry", "Private discussion or agreement draft"], surface: "shared scene with an agreement")
        guard let draft = Rig.descendants(scene).first(where: { $0.accessibilityLabel() == "Private discussion or agreement draft" }) else {
            throw Rig.Failure(description: "draft editor missing")
        }
        try focus(window, on: draft)
        let reverse = try walk(window, backwards: true).map(name)
        try expect(reverse == ["Selected shared entry", "Endorse revision 1", "History", "Workspace", "Objects", "Shared objects"],
            "shared scene: Shift-Tab walks the same stops in reverse (\(reverse.joined(separator: " → ")))")

        guard let endorse = Rig.descendants(scene).first(where: { $0.accessibilityLabel() == "Endorse revision 1" }) else {
            throw Rig.Failure(description: "Endorse control missing")
        }
        try focus(window, on: endorse); try enter(window)
        try await Rig.eventually("endorsed by keys") { model.document?.endorsements(of: revision.id).map(\.person) == [me.person] }
        try expect(true, "Return on the focused Endorse control records this person's endorsement")
        try expect(name(focused(window)) == "Selected shared entry",
            "when Endorse turns into a disabled Endorsed, keyboard focus moves on to the next stop instead of dropping to the window")

        let appliesBefore = await authority.applies
        try focus(window, on: workspace)
        try choose(workspace, "discussion", in: window)
        try await Rig.eventually("discussion created by keys") {
            await authority.applies == appliesBefore + 1 && model.document?.items.count == 3 && scene.selectedObject.map { $0 != agreement.id } == true
        }
        try expect(true, "Workspace › New discussion by keyboard creates and selects a shared discussion")
        guard let editor = Rig.descendants(scene).first(where: { $0.accessibilityLabel() == "Private discussion or agreement draft" }) as? NSTextView else {
            throw Rig.Failure(description: "draft editor missing")
        }
        try focus(window, on: editor)
        try typeText(window, "Hi")
        try tab(window)
        try expect(editor.string == "Hi" && name(focused(window)) == "Post to discussion",
            "typed keys reach the draft, and Tab leaves it for Post instead of inserting a tab")
        try enter(window)
        try await Rig.eventually("posted by keys") { model.document?.posts.last?.text == "Hi" }
        try expect(true, "Return on Post shares the typed message")

        try focus(window, on: workspace)
        try choose(workspace, "follow:" + mate.device.uuidString, in: window)
        try await Rig.eventually("following by keys") { controller.presencePublisher.followedDevice == mate.device }
        try expect(controller.presencePublisher.overlay.followBanner?.hasPrefix("Following Peer Mate") == true,
            "Workspace › Follow by keyboard follows the teammate's view and says so")
        try focus(window, on: workspace)
        try choose(workspace, "unfollow", in: window)
        try expect(controller.presencePublisher.followedDevice == nil, "Workspace › Stop following by keyboard ends follow")
    }

    // MARK: - Hub, capture review, handoff

    private static func runHubKeyboard() async throws {
        guard let fixture = try CollaborationHubChecks.makeAppearanceFixture() as? CollaborationHubView else {
            throw Rig.Failure(description: "hub fixture is not a hub view")
        }
        fixture.stop()
        let controller = CollaborationHubWindowController(model: fixture.model)
        defer { controller.window.close() }
        controller.show()
        let window = controller.window, hub = controller.content
        window.layoutIfNeeded()
        let account = try choice("Choose an account", in: hub)
        try expect(focused(window) === account, "the hub opens with keyboard focus on the account menu")
        try choose(account, "new", in: window)
        window.layoutIfNeeded()
        try expect(focused(window) === account, "choosing by keyboard returns focus to the account menu")
        try assertLoop(window, root: hub, order: ["Choose an account", "Collaboration service URL", "One-time Array enrollment code",
            "Device name", "Connect"], surface: "hub")
        try tab(window)
        try typeText(window, "https://team.example")
        let url = Rig.descendants(hub).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Collaboration service URL" }
        try expect(url?.stringValue == "https://team.example", "typed keys reach the hub's service URL field")
    }

    private static func runCaptureKeyboard() async throws {
        let wrapper = try SharedAreaCaptureChecks.makeAppearanceFixture()
        guard let fixture = Rig.descendants(wrapper).compactMap({ $0 as? SharedAreaCaptureView }).first else {
            throw Rig.Failure(description: "capture fixture missing")
        }
        let controller = SharedAreaCaptureWindowController(coordinator: fixture.coordinator)
        defer { controller.window.close() }
        controller.show()
        let window = controller.window, review = controller.content
        window.layoutIfNeeded()
        try expect(focused(window) === review.sourceChoice, "capture review opens with keyboard focus on the tile list")
        try assertLoop(window, root: review, order: ["Tile to review", "Sharing mode", "Captured content to share",
            "Refresh review", "Cancel"], surface: "capture review (Share selection disabled until something is opted in)")
        guard let target = review.modeChoice.items.first(where: { $0.enabled && $0.id != review.modeChoice.selectedID }) else {
            throw Rig.Failure(description: "no other sharing mode to choose")
        }
        try focus(window, on: review.modeChoice)
        try choose(review.modeChoice, target.id, in: window)
        try expect(review.modeChoice.selectedID == target.id, "a sharing mode is chosen by keyboard")
        _ = wrapper
    }

    private static func runHandoffKeyboard() async throws {
        let root = try Rig.root("keyboard-handoff")
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try await SharedAreaHandoffViewChecks.makeWindowFixture(root: root)
        defer { controller.window.close() }
        controller.show()
        let window = controller.window, view = controller.content
        window.layoutIfNeeded()
        try await Rig.eventually("handoff loaded") { view.window != nil }
        try expect(name(focused(window)) == "Handoff recipient collaboration ID", "the handoff window opens on the recipient field")
        let start = focused(window)
        let loop = [start] + (try walk(window))
        let missing = reachableControls(in: view).filter { control in !loop.contains { $0 === control } }
        let order = loop.map(name)
        try expect(missing.isEmpty && order.firstIndex(of: "Prompt for handed-off agent").map { index in
                order.firstIndex(of: "Reviewed shared agreement").map { $0 < index } ?? true } == true,
            "handoff: every visible enabled control is in the Tab loop, agreement before prompt (\(order.joined(separator: " → ")))")
        guard let prompt = Rig.descendants(view).first(where: { $0.accessibilityLabel() == "Prompt for handed-off agent" }) as? NSTextView else {
            throw Rig.Failure(description: "prompt editor missing")
        }
        try focus(window, on: prompt)
        let text = prompt.string
        try typeText(window, "ok"); try tab(window)
        try expect(prompt.string == text + "ok" && focused(window) !== prompt, "Tab leaves the handoff prompt without inserting a tab")
        let timing = try choice("Prompt timing", in: view)
        try focus(window, on: timing)
        let other = timing.selectedID == "queue" ? "send" : "queue"
        try choose(timing, other, in: window)
        try expect(timing.selectedID == other, "prompt timing is chosen by keyboard")
    }

    // MARK: - Reduce Motion

    /// Follow glides the camera normally and jumps when Reduce Motion is on.
    /// Both settings are driven through the scene's injected reader, never the
    /// Mac's real setting, so the witness is the same on every machine.
    private static func runReduceMotion(delegate: AppDelegate) async throws {
        let root = try Rig.root("reduce-motion")
        defer { try? FileManager.default.removeItem(at: root) }
        let leaderID = Collaboration.Identity(person: .init(), device: UUID()), followerID = Collaboration.Identity(person: .init(), device: UUID())
        let item = SharedArea.Item(id: .init(), kind: .discussion)
        var document = SharedArea.Document()
        try document.apply(.init(area: document.id, expectedRevision: 0, edits: [
            .admit(item, .init(id: .init(), object: item.id, rect: .init(x: 40, y: 30, width: 260, height: 180), z: 1))]))
        let authority = Rig.Authority(document: document, members: [(leaderID, .editor), (followerID, .editor)])
        let leaderModel = try Rig.controller(root: root.appendingPathComponent("leader"), identity: leaderID, label: "Peer Leader", authority: authority)
        let followerModel = try Rig.controller(root: root.appendingPathComponent("follower"), identity: followerID, label: "Peer Follower", authority: authority)
        let leaderHost = NSView(frame: .init(x: 0, y: 0, width: 1000, height: 760)), followerHost = NSView(frame: .init(x: 0, y: 0, width: 1200, height: 700))
        let leader = delegate.mountWorkspaceSceneAtBoot(sharedAreaController: leaderModel, person: leaderID.person, in: leaderHost)
        let follower = delegate.mountWorkspaceSceneAtBoot(sharedAreaController: followerModel, person: followerID.person, in: followerHost)
        leaderHost.layoutSubtreeIfNeeded(); followerHost.layoutSubtreeIfNeeded()
        await leaderModel.open(); await followerModel.open()
        let leaderPublisher = SharedAreaPresencePublisher(scene: leader), followerPublisher = SharedAreaPresencePublisher(scene: follower)
        leaderPublisher.start(); followerPublisher.start()
        defer { leaderPublisher.stop(); followerPublisher.stop(); leader.unmount(); follower.unmount() }
        try follower.setCamera(.init(x: -300, y: -200, zoom: 0.5))

        func publish(_ camera: SharedAreaLocalView) async throws {
            try leader.setCamera(camera)
            let bounds = leader.areaCanvasView.bounds
            let wanted = SharedArea.Rect(x: camera.x, y: camera.y, width: bounds.width / camera.zoom, height: bounds.height / camera.zoom)
            try await Rig.eventually("leader view published") {
                if followerModel.presence.first(where: { $0.identity.device == leaderID.device })?.viewport == wanted { return true }
                await leaderPublisher.publishPointer(.init(x: 120, y: 90)); return false
            }
        }
        func tracking() -> Bool {
            guard let viewport = followerModel.presence.first(where: { $0.identity.device == leaderID.device })?.viewport else { return false }
            let canvas = follower.areaCanvasView.frame, bounds = follower.areaCanvasView.bounds
            let centre = follower.areaPoint(forScreenPoint: .init(x: canvas.midX, y: canvas.midY))
            let zoom = min(Double(bounds.width) / viewport.width, Double(bounds.height) / viewport.height)
            return abs(centre.x - (viewport.x + viewport.width / 2)) < 1e-6 && abs(centre.y - (viewport.y + viewport.height / 2)) < 1e-6
                && abs(follower.localViewCamera.zoom - zoom) < 1e-9
        }

        try await publish(.init(x: 200, y: 150, zoom: 1.2))
        follower.reduceMotion = { true }
        var frames = follower.followCameraFrames
        try expect(followerPublisher.follow(device: leaderID.device) && tracking() && !follower.isFollowGliding
            && follower.followCameraFrames == frames + 1,
            "with Reduce Motion on, following jumps to the teammate's view in one frame")
        try await publish(.init(x: 640, y: 420, zoom: 0.8))
        try expect(tracking() && !follower.isFollowGliding, "with Reduce Motion on, tracked moves also jump")
        followerPublisher.stopFollowing(notice: nil)

        try await publish(.init(x: -100, y: -60, zoom: 1.6))
        follower.reduceMotion = { false }
        frames = follower.followCameraFrames
        let writes = follower.privateViewWrites
        try expect(followerPublisher.follow(device: leaderID.device) && follower.isFollowGliding && !tracking(),
            "with Reduce Motion off, following starts a glide instead of jumping")
        try await Rig.eventually("glide settles") { !follower.isFollowGliding }
        try expect(tracking() && follower.followCameraFrames - frames >= 6 && follower.privateViewWrites == writes,
            "the glide lands exactly on the teammate's view over \(follower.followCameraFrames - frames) frames with no private camera writes")
        followerPublisher.stopFollowing(notice: nil)
        await leaderModel.close(); await followerModel.close()
    }
}
