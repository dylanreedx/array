// Film harness: the director's v2 seams (.plans/68-launch-film/research/19-full-day-v2).
//
//  - navigation: every jump the user asks for reaches `CanvasNSView.navigateViewport`,
//    which hands its target to `filmNavigationCamera` in a film. The input action that
//    caused it (`key`, `jump`, `jumpZone`, a delivered `click`) glides there over the rest
//    of its `dur` on the scene's camera curve; with no `dur` it cuts, as it did before;
//  - hover: `pointer {"hover": true, "dwell": N}` sends real mouseMoved events, the
//    window's mouse location IS the film pointer (`FilmInput.pointerLocation`), and the
//    sidebar's hover-card dwell runs on the film clock (`hoverCardScheduler`);
//  - the inbox's clock-derived state (the "Close" settle nudge, five film minutes after a
//    finished agent was read) is re-rendered when the film clock moves: at every take's
//    first frame and every 30 film seconds, which is production's 30 s timer on film time;
//  - Settings: since integration's in-window Settings modal (61b1fc8e) it is a view
//    inside the film window, captured like any other; its controls are found inside that
//    overlay (the SwiftUI form exposes none of the old panel's AgentSoundSettingsView, so
//    a scene's `settings` pointer targets are not ported yet and fail by name);
//  - sounds: `FilmPanelHost.sound` records every sound production asks to play (a
//    Preview, a push/merge/completion signal) in frames.json `sounds`; none is played;
//  - targets and rects for the hover card, the nudge, Settings controls, the bulk bar and
//    the undo toast.
// Compiled only into the film build (`scripts/film-capture.sh`, -DARRAY_FILM).
#if ARRAY_FILM
import AppKit
import ContinuumRevivedCore

/// Film runs only (nil otherwise): where production would play a sound, the director
/// takes it instead.
@MainActor
enum FilmPanelHost {
    /// A throwaway defaults suite for the film's Settings assertions.
    static var defaults: UserDefaults?
    /// `AgentSoundPlayer.play`: the sound and its priority (`Int.max`: a Preview).
    static var sound: ((AgentSoundReference, Int) -> Void)?
}

extension FilmDirector {
    struct GlidePlan { var v0: CanvasViewport; var v1: CanvasViewport; var start: Int }

    /// One navigation production made (witness only): what caused it, where the camera
    /// was, where production sent it, and (for `jump`/`jumpZone`) the viewport
    /// production's own framing named just before the key.
    struct NavigationRecord {
        var label: String?
        var takeIndex: Int?
        var at: Int?
        var startLocal: Int?
        var before: CanvasViewport
        var target: CanvasViewport
        var expected: CanvasViewport?
        var glided: Bool
    }

    // MARK: Install / uninstall

    func installV2Hooks() {
        canvas.filmNavigationCamera = { [weak self] target in self?.captureNavigation(target) }
        // The film pointer is THE pointer, for the film window and its child panels.
        FilmInput.pointerLocation = { [weak self] target in
            guard let self else { return nil }
            if target === self.window { return self.windowPoint(fromTopLeft: self.pointer.point) }
            guard (self.window.childWindows ?? []).contains(where: { $0 === target }) else { return nil }
            return target.convertPoint(fromScreen: self.screenPoint(fromTopLeft: self.pointer.point))
        }
        // The depicted app is active: its window is key (Settings is a view inside it).
        FilmInput.keyWindowOverride = { [weak self] candidate in
            guard let self else { return nil }
            return candidate === self.window ? true : nil
        }
        FilmInput.keepsPanelsUnconstrained = true
        let suite = "array.film.settings.\(UUID().uuidString)"
        settingsSuite = suite
        FilmPanelHost.defaults = UserDefaults(suiteName: suite)
        FilmPanelHost.sound = { [weak self] reference, priority in self?.recordSound(reference, priority: priority) }
        installHoverCardClock()
    }

    func uninstallV2Hooks() {
        canvas.filmNavigationCamera = nil
        FilmInput.pointerLocation = nil
        FilmInput.keyWindowOverride = nil
        FilmInput.keepsPanelsUnconstrained = false
        FilmPanelHost.sound = nil
        FilmPanelHost.defaults = nil
        if let suite = settingsSuite { UserDefaults.standard.removePersistentDomain(forName: suite) }
        settingsSuite = nil
        delegate.filmSidebar?.agentInbox.hoverCardScheduler = nil
        filmCallbacks.removeAll()
    }

    // MARK: Navigation

    /// `CanvasNSView.navigateViewport`'s target. The input action that caused it glides
    /// there over the rest of its `dur`; anything else cuts (the old offscreen behaviour).
    func captureNavigation(_ target: CanvasViewport) {
        guard let owner = navigationOwner, owner.local < owner.duration else {
            navigations.append(NavigationRecord(before: canvas.viewport, target: target, glided: false))
            log("navigate (cut, no input action with dur owns it): \(canvas.viewport) -> \(target)")
            canvas.setViewport(target)
            return
        }
        actionState[owner.key + "/glide"] = GlidePlan(v0: canvas.viewport, v1: target, start: owner.local)
        navigations.append(NavigationRecord(label: owner.label, takeIndex: owner.takeIndex, at: owner.at, startLocal: owner.local,
                                            before: canvas.viewport, target: target,
                                            expected: actionState[owner.key + "/expected"] as? CanvasViewport, glided: true))
        frameEvents.append("revealStart")
        log("navigate (\(owner.label) +\(owner.local)): \(canvas.viewport) -> \(target) over \(owner.duration - owner.local) frames")
    }

    /// The frames after a captured navigation: production's target on the v2 split,
    /// landing exactly on it on the action's last frame.
    func advanceNavigationGlide(key: String, action: FilmAction, local: Int) {
        guard let plan = actionState[key + "/glide"] as? GlidePlan, local > plan.start else { return }
        let span = max(action.duration - plan.start, 1)
        let p = min(1, Double(local - plan.start) / Double(span))
        canvas.setViewport(FilmCameraMath.interpolate(plan.v0, plan.v1, p: p, curve: scene.cameraCurve(for: action),
                                                      duration: Double(span) / fps, size: canvas.bounds.size))
        if local == action.duration { frameEvents.append("revealEnd") }
    }

    // MARK: Scroll

    /// One scroll-wheel event per frame at the pointer, the eased share of `by` each.
    func applyScroll(_ scroll: FilmAction.Scroll, action: FilmAction, key: String, local: Int) {
        if local == 0 {
            actionState[key] = (sent: CGPoint.zero, mode: pointer.mode)
            pointer.mode = "scroll"
        }
        guard let state = actionState[key] as? (sent: CGPoint, mode: String) else { return }
        let curve = FilmCurve.pointer(spring: nil, ease: scroll.ease) ?? .bezier(.inOut)
        let e = action.duration == 0 ? 1 : curve.value(Double(local + 1) / Double(action.duration + 1), duration: Double(action.duration) / fps)
        let want = CGPoint(x: (scroll.by[0] * e).rounded(), y: (scroll.by[1] * e).rounded())
        let dx = Int32(want.x - state.sent.x), dy = Int32(want.y - state.sent.y)
        // The window server routes a wheel event to the window under the pointer, and
        // AppKit to the view it hit-tests there; neither happens for an off-display
        // window, so the director does that routing: the hit view's `scrollWheel`, which
        // climbs the responder chain to its scroll view exactly as AppKit's dispatch does.
        let target = targetWindow()
        if dx != 0 || dy != 0, let event = input.scrollEvent(dx: dx, dy: dy, screenPoint: screenPoint(fromTopLeft: pointer.point),
                                                              window: target, modifiers: heldModifiers),
           let root = target.contentView?.superview ?? target.contentView {
            let local = target.convertPoint(fromScreen: screenPoint(fromTopLeft: pointer.point))
            (root.hitTest(root.convert(local, from: nil)) ?? root).scrollWheel(with: event)
        }
        actionState[key] = (sent: want, mode: state.mode)
        if local >= action.duration { pointer.mode = state.mode }
    }

    // MARK: Hover

    /// One real mouseMoved at the pointer when it moved (or `force`), to the window
    /// under it, so tracking areas (the sidebar's row hover) see the film pointer.
    func postMouseMovedIfNeeded(force: Bool) {
        let point = pointer.point
        if !force, let last = lastMovedPoint, hypot(Double(last.x - point.x), Double(last.y - point.y)) < 0.01 { return }
        lastMovedPoint = point
        guard windowBounds.contains(point),
              let event = input.mouseEvent(.mouseMoved, screenPoint: screenPoint(fromTopLeft: point), window: targetWindow(),
                                           clickCount: 0, modifiers: heldModifiers) else { return }
        input.post(event)
        input.dispatchTracking(event, in: event.window ?? window)
    }

    /// The sidebar hover card's dwell on the film clock (the inbox's own injection seam).
    func installHoverCardClock() {
        guard let inbox = delegate.filmSidebar?.agentInbox, inbox.hoverCardScheduler == nil else { return }
        inbox.hoverCardScheduler = { [weak self] delay, run in
            let id = MainActor.assumeIsolated { self?.filmSchedule(delay, run) }
            return { [weak self] in
                MainActor.assumeIsolated { if let id { self?.filmCallbacks.removeAll { $0.id == id } } }
            }
        }
    }

    /// Runs `run` on the first frame whose film time reaches now + `delay`.
    func filmSchedule(_ delay: TimeInterval, _ run: @escaping () -> Void) -> Int {
        filmCallbackSerial += 1
        filmCallbacks.append((Self.filmSeconds + max(delay, 0), filmCallbackSerial, run))
        return filmCallbackSerial
    }

    // MARK: The inbox's clock-derived state

    /// Production's 30 s settle-nudge timer, on the film clock: every visible row is
    /// redrawn (`reloadData(forRowIndexes:)`, exactly the timer's `redraw`) at each
    /// take's first frame (where a `clock` jumps hours) and every 30 film seconds.
    func redrawInboxIfClockMoved(takeStart: Bool) {
        guard let inbox = delegate.filmSidebar?.agentInbox else { return }
        installHoverCardClock()
        let now = Self.filmSeconds
        guard takeStart || lastInboxClockRedraw.map({ now - $0 >= 30 - 1e-9 }) ?? true else { return }
        lastInboxClockRedraw = now
        guard let table = Self.descendants(of: inbox, NSTableView.self).first(where: { ($0.dataSource as AnyObject?) === inbox }),
              table.numberOfRows > 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<table.numberOfRows), columnIndexes: IndexSet(integer: 0))
    }

    // MARK: Settings

    func recordSound(_ reference: AgentSoundReference, priority: Int) {
        let preview = priority == Int.max
        frameSounds.append(["sound": reference.rawValue, "kind": preview ? "preview" : "signal"])
        frameEvents.append("sound")
        soundLog.append((globalFrame, reference.rawValue, preview))
        log("sound \(reference.rawValue) (\(preview ? "preview" : "signal")) at frame \(globalFrame): recorded, not played")
    }

    /// Integration's in-window Settings modal, when it is open over the film window.
    var settingsOverlay: NSView? {
        window.contentView.flatMap { Self.descendants(of: $0, SettingsOverlayView.self).first { !$0.isHiddenOrHasHiddenAncestor } }
    }

    func settingsControlView(_ target: FilmSettingsTarget) -> NSView? {
        guard let content = settingsOverlay else { return nil }
        switch target {
        case let .section(title):
            guard let table = Self.descendants(of: content, NSTableView.self).first,
                  let label = Self.label(titled: title, in: table) else { return nil }
            var row: NSView = label
            while !(row is NSTableRowView), let parent = row.superview, parent !== table { row = parent }
            return row
        case .soundsMaster:
            return Self.descendants(of: content, AgentSoundSettingsView.self).first
                .flatMap { Self.descendants(of: $0, NSButton.self).first { $0.title == "Play agent sound indicators" } }
        case let .sound(kind, part):
            guard let sounds = Self.descendants(of: content, AgentSoundSettingsView.self).first else { return nil }
            let mine = Self.descendants(of: sounds, NSView.self).filter { $0.identifier?.rawValue == kind.rawValue }
            switch part {
            case .enabled: return mine.first { ($0 as? NSButton)?.title == kind.displayName && !($0 is NSPopUpButton) }
            case .preview: return mine.first { ($0 as? NSButton)?.title == "Preview" }
            case .sound: return mine.first { $0 is NSPopUpButton }
            }
        }
    }

    /// The visible part of a Settings control, in top-left MAIN window points (nil when
    /// it is scrolled out of the panel's detail view).
    func settingsControlRect(_ target: FilmSettingsTarget) -> CGRect? {
        guard let view = settingsControlView(target), view.window != nil, !view.isHiddenOrHasHiddenAncestor else { return nil }
        // AppKit's visibleRect is not clipped to the view's own bounds when the view is
        // scrolled out entirely.
        var area = view.bounds
        // A checkbox is wider than what it draws (its stack gives it 140 pt), and only
        // its box and title take a click: the box and title are the target.
        if let checkbox = view as? NSButton, let cell = checkbox.cell as? NSButtonCell, !(view is NSPopUpButton),
           case .sound(_, .enabled) = target {
            let drawn = cell.imageRect(forBounds: checkbox.bounds).union(cell.titleRect(forBounds: checkbox.bounds))
            if !drawn.isEmpty { area = drawn.intersection(checkbox.bounds) }
        }
        let visible = view.visibleRect.intersection(area)
        guard !visible.isEmpty else { return nil }
        return mainTopLeftRect(of: view, visible)
    }

    /// Any view's rect (its own window may be a child panel) in top-left MAIN window points.
    func mainTopLeftRect(of view: NSView, _ rect: CGRect) -> CGRect {
        guard let own = view.window else { return .zero }
        let screen = own.convertToScreen(view.convert(rect, to: nil))
        let local = window.convertFromScreen(screen)
        let content = window.contentLayoutRect
        return CGRect(x: local.minX - content.minX, y: content.maxY - local.maxY, width: local.width, height: local.height)
    }

    // MARK: Sidebar: nudge, bulk bar, undo toast, hover card

    func nudgeView(_ agentKey: String) -> NSView? {
        guard let cell = sidebarRowCell(agentKey) else { return nil }
        return Self.descendants(of: cell, NSView.self).first {
            $0.accessibilityIdentifier() == "ContinuumAgentInboxSettleNudge" && !$0.isHiddenOrHasHiddenAncestor
        }
    }

    func nudgeRect(_ agentKey: String) -> CGRect? { nudgeView(agentKey).map { topLeftRect(of: $0, $0.bounds) } }

    func bulkTargetRect(_ name: String) -> CGRect? {
        guard let inbox = delegate.filmSidebar?.agentInbox, inbox.isBulkBarVisibleForQA else { return nil }
        if name == "menu" { return topLeftRect(of: inbox, inbox.bulkActionTriggerFrameForQA) }
        guard let action = InboxBulkAction(rawValue: name) else { return nil }
        return choiceRowRect(title: action.title)
    }

    /// The open choice panel's row titled `title`, in top-left main window points.
    func choiceRowRect(title: String) -> CGRect? {
        for panel in (window.childWindows ?? []).reversed() where panel.isVisible {
            guard let content = panel.contentView, let label = Self.label(titled: title, in: content) else { continue }
            var row: NSView = label
            while let parent = row.superview, !(row is NSControl && row !== label) { row = parent }
            return mainTopLeftRect(of: row, row.bounds)
        }
        return nil
    }

    var undoToastView: NSView? {
        guard let inbox = delegate.filmSidebar?.agentInbox else { return nil }
        return Self.descendants(of: inbox, NSView.self).first {
            $0.accessibilityIdentifier() == "ContinuumAgentInboxUndoToast" && !$0.isHiddenOrHasHiddenAncestor
        }
    }

    var hoverCardView: InboxHoverCardView? {
        window.contentView?.subviews.compactMap { $0 as? InboxHoverCardView }.first { !$0.isHiddenOrHasHiddenAncestor }
    }

    /// The scene's Settings targets (each measured into `rects` while it shows).
    var sceneSettingsTargets: [String] {
        Array(Set(scene.takes.flatMap { $0.actions.compactMap { $0.pointer?.to?.settings } })).sorted()
    }

    /// frames.json `rects` for the v2 surfaces: `hoverCard`, `nudge:<agentKey>`,
    /// `settings:<target>`, `bulk` / `bulk:menu` / `bulk:<action>`, `toast`
    /// (`window:settings` comes with the child windows).
    func measureV2Rects(into rects: inout [String: CGRect]) {
        func put(_ key: String, _ rect: CGRect?) {
            if let rect, !rect.isEmpty, rect.intersects(windowBounds) { rects[key] = rect }
        }
        if let card = hoverCardView { put("hoverCard", topLeftRect(of: card, card.bounds)) }
        for key in agents.keys { put("nudge:\(key)", nudgeRect(key)) }
        for target in sceneSettingsTargets {
            if let parsed = FilmSettingsTarget(target) { put("settings:\(target)", settingsControlRect(parsed)) }
        }
        if let inbox = delegate.filmSidebar?.agentInbox, inbox.isBulkBarVisibleForQA {
            put("bulk", topLeftRect(of: inbox, inbox.bulkBarFrameForQA))
            put("bulk:menu", topLeftRect(of: inbox, inbox.bulkActionTriggerFrameForQA))
            for action in InboxBulkAction.allCases { put("bulk:\(action.rawValue)", choiceRowRect(title: action.title)) }
        }
        if let toast = undoToastView { put("toast", topLeftRect(of: toast, toast.bounds)) }
    }

    static func descendants<T: NSView>(of view: NSView, _ type: T.Type) -> [T] {
        var found: [T] = []
        func walk(_ node: NSView) {
            if let match = node as? T { found.append(match) }
            node.subviews.forEach(walk)
        }
        walk(view)
        return found
    }
}
#endif
