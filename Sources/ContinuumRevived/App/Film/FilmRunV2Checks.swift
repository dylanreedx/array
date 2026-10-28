// Film harness: `--film-scene-check`'s assertions over the v2 surfaces
// (.plans/68-launch-film/research/19-full-day-v2). Each is driven by what the scene
// does, so any committed scene that uses a verb is checked on it:
//
//  - hover: a `pointer {"hover": true, "dwell": N}` onto a sidebar row opens the row's
//    hover card exactly the inbox's 0.15 s dwell (on the film clock) after the pointer
//    reached the row, beside the row, and `rects.hoverCard` records it;
//  - navigation: every jump an input action with `dur` causes (`jump`, `jumpZone`, a
//    sidebar row click) glides from where the camera was to production's target on the
//    scene's camera curve, landing exactly on it; a `jump`/`jumpZone` target is the
//    viewport production's own framing names (`framedViewportForTileJump`,
//    `fitZoneToViewport`);
//  - Settings: the panel shows as a child window (`window:settings`), each targeted
//    control is measured, a ticked checkbox lands in the film's throwaway suite and NOT in
//    the user's defaults, and each Preview records its rule's sound without playing it;
//  - unseen Done: a finished agent nobody clicked reads "Done" in the sidebar on every
//    frame until it is clicked, and stops reading it once clicked; at the end an unseen
//    one still carries its tile's Completed badge;
//  - the close nudge: shows on the row the scene points at after a clock jump, and a
//    click closes the agent to History;
//  - follow-ups: a composer send reaches the film runner (no CLI), as a fresh turn;
//  - the bulk bar: ⌘/⇧-clicked rows plus the bar's Archive close every selected agent;
//  - zones: every staged and drawn zone is placed, every project registered.
// Compiled only into the film build (`scripts/film-capture.sh`, -DARRAY_FILM).
#if ARRAY_FILM
import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// `--film-scene-check`'s window for a scene that drives keys or hover: borderless and
/// off every display like the others, but able to be key (never main, never activating).
final class FilmCheckWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

extension FilmSceneCheck {
    /// Every agent-sound key, as the defaults hold it (`nil` when unset).
    static func soundSettingsSnapshot(_ defaults: UserDefaults) -> [String: String] {
        var keys = [AgentSoundConfig.masterEnabledKey, AgentSoundConfig.volumeKey]
        for kind in AgentSignalKind.allCases { keys += [AgentSoundConfig.enabledKey(for: kind), AgentSoundConfig.soundKey(for: kind)] }
        return Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0).map { "\($0)" } ?? "nil") })
    }

    /// A take's actions in timeline order, each delivered click paired with the target
    /// of the last pointer move before it.
    static func clicksWithTargets(_ take: FilmScene.Take) -> [(click: FilmAction, target: FilmAction.PointerTarget?)] {
        var last: FilmAction.PointerTarget?
        var out: [(FilmAction, FilmAction.PointerTarget?)] = []
        for action in take.actions.sorted(by: { $0.at < $1.at }) {
            if let to = action.pointer?.to { last = to }
            if action.click?.deliver == true { out.append((action, last)) }
        }
        return out
    }

    static func v2Assertions(scene: FilmScene, director: FilmDirector, delegate: AppDelegate, canvas: CanvasNSView,
                             records: [Int: [FilmDirector.FrameRecord]], standardSoundSettings: [String: String],
                             failures: inout [String]) -> String {
        var local: [String] = []
        func expect(_ condition: Bool, _ message: @autoclosure () -> String) { if !condition { local.append(message()) } }
        func near(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool { abs(a - b) <= tolerance }
        func same(_ a: CanvasViewport, _ b: CanvasViewport) -> Bool {
            near(a.x, b.x, 1e-6) && near(a.y, b.y, 1e-6) && near(a.zoom, b.zoom, 1e-9)
        }
        let fps = Double(scene.framesPerSecond)
        var offsets: [Int] = []
        var total = 0
        for take in scene.takes { offsets.append(total); total += take.frames }
        // Global frame -> (take, frame record).
        func record(_ global: Int) -> FilmDirector.FrameRecord? {
            guard let take = offsets.lastIndex(where: { $0 <= global }) else { return nil }
            let frames = records[take] ?? []
            let index = global - offsets[take]
            return frames.indices.contains(index) ? frames[index] : nil
        }
        var counts = (hovers: 0, navigations: 0, jumps: 0, settings: 0, ticks: 0, previews: 0, unseen: 0, seen: 0,
                      nudges: 0, followUps: 0, bulk: 0)
        let inbox = delegate.filmSidebar?.agentInbox
        let rows = inbox?.qaAllRowsForQA ?? []
        func row(_ key: String) -> AgentInboxRow? {
            director.agents[key].flatMap { handle in rows.first { $0.id == handle.agentId.rawValue } }
        }

        // 1) Hover: the card opens after exactly the dwell, on the film clock, beside its row.
        let dwellFrames = Int((0.15 * fps).rounded(.up))
        for (takeIndex, take) in scene.takes.enumerated() {
            guard let frames = records[takeIndex] else { continue }
            for action in take.actions {
                guard let move = action.pointer, move.hover == true, let key = move.to?.sidebar, key != "history",
                      (move.dwell ?? 0) > dwellFrames else { continue }
                let end = action.at + action.duration
                guard end < frames.count else { continue }
                let entered = (action.at...end).first { f in
                    frames[f].rects["sidebar:\(key)"].map { $0.contains(frames[f].pointer.point) } ?? false
                }
                guard let entered else { local.append("hover \(key) at \(action.at): the pointer never reached the row"); continue }
                let opened = (entered...end).first { frames[$0].rects["hoverCard"] != nil }
                guard let opened else {
                    local.append("hover \(key) at \(action.at): no hover card by frame \(end) (pointer on the row from \(entered))"); continue
                }
                expect(abs((opened - entered) - dwellFrames) <= 1,
                       "hover \(key): the card opened \(opened - entered) frames after the pointer reached the row; the dwell is \(dwellFrames) film frames")
                if let card = frames[end].rects["hoverCard"], let rowRect = frames[end].rects["sidebar:\(key)"] {
                    expect(card.minX >= rowRect.maxX - 1 && card.minY < rowRect.maxY && card.maxY > rowRect.minY - card.height,
                           "hover \(key): card \(card) is not beside its row \(rowRect)")
                } else {
                    local.append("hover \(key): the card closed during the dwell (frame \(end))")
                }
                counts.hovers += 1
            }
        }

        // 2) Navigation glides.
        for nav in director.navigations where nav.glided {
            guard let takeIndex = nav.takeIndex, let at = nav.at, let start = nav.startLocal, let frames = records[takeIndex],
                  let action = scene.takes[takeIndex].actions.first(where: { $0.at == at && $0.ownsNavigation }) else { continue }
            let end = at + action.duration
            guard end < frames.count else { local.append("navigation \(nav.label ?? "?") at \(at): ends after the take"); continue }
            expect(same(frames[at + start].viewport, nav.before), "navigation \(nav.label ?? "?") at \(at): the camera cut on the frame production moved it")
            expect(same(frames[end].viewport, nav.target), "navigation \(nav.label ?? "?") at \(at): landed \(frames[end].viewport), production's target \(nav.target)")
            let span = action.duration - start
            for l in start...action.duration {
                let want = FilmCameraMath.interpolate(nav.before, nav.target, p: Double(l - start) / Double(max(span, 1)),
                                                      curve: scene.cameraCurve(for: action), duration: Double(span) / fps,
                                                      size: canvas.bounds.size)
                if !same(frames[at + l].viewport, want) {
                    local.append("navigation \(nav.label ?? "?") at \(at)+\(l): \(frames[at + l].viewport) is off the glide \(want)"); break
                }
            }
            if let expected = nav.expected {
                expect(same(expected, nav.target), "navigation \(nav.label ?? "?"): production went to \(nav.target), its own framing said \(expected)")
            }
            expect(frames[at + start].events.contains("revealStart") && frames[end].events.contains("revealEnd"),
                   "navigation \(nav.label ?? "?") at \(at): revealStart/revealEnd missing")
            counts.navigations += 1
        }
        for (takeIndex, take) in scene.takes.enumerated() {
            for action in take.actions where (action.jump != nil || action.jumpZone != nil) && action.duration > 0 {
                let made = director.navigations.contains { $0.glided && $0.takeIndex == takeIndex && $0.at == action.at && $0.expected != nil }
                expect(made, "\(action.label) at \(action.at) in \(take.name): production made no jump the film could glide")
                if made { counts.jumps += 1 }
                if let frames = records[takeIndex], action.at < frames.count {
                    let label = frames[action.at].keys.first { ($0["kind"] as? String) == "press" }?["label"] as? String
                    expect(label?.hasPrefix("⌥") == true, "\(action.label) at \(action.at): key cap \(label ?? "none"), want ⌥ + its key")
                }
            }
        }

        // 3) Settings: on camera, measured, ticks in the film's suite only, previews recorded.
        for (takeIndex, take) in scene.takes.enumerated() {
            guard let frames = records[takeIndex] else { continue }
            for action in take.actions {
                guard let target = action.pointer?.to?.settings else { continue }
                let end = action.at + action.duration
                guard end < frames.count else { continue }
                expect(frames[end].rects["window:settings"] != nil, "settings \(target) at \(action.at): the Settings panel is not on camera")
                expect(frames[end].rects["settings:\(target)"] != nil, "settings \(target) at \(action.at): the control is not measured (hidden or scrolled away)")
                counts.settings += 1
            }
            var toggles: [AgentSignalKind: Int] = [:]
            for (click, target) in clicksWithTargets(take) {
                guard let text = target?.settings, case let .sound(kind, part)? = FilmSettingsTarget(text) else { continue }
                if part == .enabled { toggles[kind, default: 0] += 1 }
                if part == .preview {
                    let release = offsets[takeIndex] + click.at + 5
                    let want = AgentSoundRules.defaults[kind]?.sound.rawValue
                    let heard = director.soundLog.contains { $0.preview && $0.sound == want && abs($0.frame - release) <= 1 }
                    expect(heard, "settings: Preview for \(kind.rawValue) at \(click.at) recorded no \(want ?? "?") preview (log \(director.soundLog.map { "\($0.frame):\($0.sound)" }))")
                    if heard { counts.previews += 1 }
                }
            }
            for (kind, count) in toggles {
                let ticked = FilmPanelHost.defaults?.bool(forKey: AgentSoundConfig.enabledKey(for: kind)) ?? false
                expect(ticked == (count % 2 == 1), "settings: \(kind.displayName) clicked \(count) time(s), its rule reads \(ticked) in the film's suite")
                counts.ticks += 1
            }
        }
        expect(soundSettingsSnapshot(UserDefaults.standard) == standardSoundSettings,
               "settings: the film wrote the user's own sound settings")
        if counts.previews > 0 || counts.ticks > 0 {
            expect(director.soundLog.allSatisfy { !$0.sound.isEmpty }, "sounds: an empty sound was recorded")
        }

        // 4) Unseen Done until clicked; seen after.
        var lastFrame = total - 1
        if lastFrame < 0 { lastFrame = 0 }
        var seenBy: [String: [Int]] = [:]
        // Any sidebar click (a row, a nudge, the bulk bar, History) can move the
        // selection or close a row, and production's advance then reads the next row:
        // an unseen stretch is only owed until the film next touches the sidebar. A
        // tile's ✕ closes its agent to History the same way, so it counts too.
        var sidebarTouches: [Int] = []
        var dones: [String: [Int]] = [:]
        var starts: [String: [Int]] = [:]
        for (takeIndex, take) in scene.takes.enumerated() {
            for action in take.actions where action.child == nil {
                guard let key = action.agent, let turn = action.turn else { continue }
                if turn == "done" { dones[key, default: []].append(offsets[takeIndex] + action.at) }
                if turn == "start" { starts[key, default: []].append(offsets[takeIndex] + action.at) }
            }
            for action in take.actions { if let key = action.reveal { seenBy[key, default: []].append(offsets[takeIndex] + action.at) } }
            for (click, target) in clicksWithTargets(take) {
                if target?.sidebar != nil || target?.bulk != nil || (target?.tile != nil && target?.at == .close) {
                    sidebarTouches.append(offsets[takeIndex] + click.at + 5)
                }
                guard click.allMods == nil, let key = target?.sidebar ?? target?.tile, target?.at != .nudge else { continue }
                seenBy[key, default: []].append(offsets[takeIndex] + click.at + 5)
            }
        }
        for (key, doneFrames) in dones where director.agents[key] != nil {
            for done in doneFrames {
                let nextSeen = seenBy[key]?.filter { $0 > done }.min()
                let nextStart = starts[key]?.filter { $0 > done }.min()
                let nextTouch = sidebarTouches.filter { $0 > done }.min()
                let until = min(nextSeen ?? lastFrame + 1, nextStart ?? lastFrame + 1, nextTouch ?? lastFrame + 1)
                // A send's turn ends through its runner, a hop later: the row settles into
                // Done within a few frames, then holds it until the film clicks it.
                var sampled = 0
                let settled = (done..<min(until, done + 30)).first { record($0)?.sidebarStates[key] == "Done" }
                if settled == nil, until > done + 2, record(done + 2)?.sidebarStates[key] != nil {
                    local.append("\(key): finished at frame \(done), but its row never read Done (reads \"\(record(min(until - 1, done + 29))?.sidebarStates[key] ?? "?")\")")
                }
                for frame in (settled ?? until)..<max(settled ?? until, until) {
                    guard let label = record(frame)?.sidebarStates[key], !label.isEmpty else { continue }
                    if label != "Done" { local.append("\(key): finished at frame \(done), unseen, but its row reads \"\(label)\" at frame \(frame)"); break }
                    sampled += 1
                }
                if sampled > 0 { counts.unseen += 1 }
                if let seen = nextSeen, seen < (nextStart ?? Int.max), seen <= (nextTouch ?? Int.max),
                   let label = record(seen + 2)?.sidebarStates[key] {
                    expect(label != "Done", "\(key): clicked at frame \(seen), its row still reads Done")
                    counts.seen += 1
                }
            }
            // Never clicked since its last finish: still unseen, and its tile still says Completed.
            if let last = doneFrames.max(), (seenBy[key]?.filter { $0 > last } ?? []).isEmpty,
               sidebarTouches.allSatisfy({ $0 <= last }),
               (starts[key]?.filter { $0 > last } ?? []).isEmpty, let current = row(key), current.lifecycle == .active {
                expect(AgentInbox96CellView.isUnseen(current), "\(key): never clicked since it finished, but the row is seen")
                // Every tree the tile draws: a resting tile's header is in its body.
                let badge = director.agentView(key).flatMap { view in
                    view.qaPresentedViewRoots.lazy.flatMap { FilmDirector.descendants(of: $0, AgentSignalBadgeView.self) }
                        .first { !$0.isHidden }
                }
                expect(badge?.signal?.kind == .completed, "\(key): unseen, but its tile badge is \(badge?.signal?.kind.rawValue ?? "hidden"), want completed")
            }
        }

        // 5) The "✓ All set?" nudge, and what its click does: it settles the agent, which
        //    closes its tile (integration's launch polish, 0ffd832f; it used to archive).
        for (takeIndex, take) in scene.takes.enumerated() {
            guard let frames = records[takeIndex] else { continue }
            for action in take.actions {
                guard let target = action.pointer?.to, let key = target.sidebar, target.at == .nudge else { continue }
                let end = action.at + action.duration
                guard end < frames.count else { continue }
                expect(frames[end].rects["nudge:\(key)"] != nil, "nudge \(key) at \(action.at): no All set? nudge on its row")
                if (frames[0].index...end).contains(where: { frames[$0].rects["nudge:\(key)"] != nil }) { counts.nudges += 1 }
            }
            for (click, target) in clicksWithTargets(take) {
                guard let key = target?.sidebar, target?.at == .nudge else { continue }
                expect(row(key).map { if case .settled = $0.lifecycle { return true } else { return false } } ?? false,
                       "nudge \(key): its click did not settle the agent (\(String(describing: row(key)?.lifecycle)))")
                expect(director.agents[key].map { canvas.tileView(for: $0.tileId) == nil } ?? false,
                       "nudge \(key): its tile is still on the canvas")
                _ = click
            }
            // ...and never early: a turn that finished less than the settle delay ago on the
            // film's clock has nothing to close yet. (The activity stamp read the wall clock,
            // hours before the film's day, so the Planner asked to be closed as it finished.)
            for action in take.actions {
                guard let key = action.agent, action.turn == "done" else { continue }
                for local in action.at..<frames.count
                where Double(local - action.at) / fps < AgentInbox96CellView.settleNudgeDelay {
                    if frames[local].rects["nudge:\(key)"] != nil {
                        expect(false, "nudge \(key) at \(local): Close asked \(local - action.at) frame(s) after its turn finished")
                        break
                    }
                }
            }
        }

        // 6) Follow-ups: every composer send reached the film runner as a fresh turn.
        var sends: [String: Int] = [:]
        for take in scene.takes {
            for (_, target) in clicksWithTargets(take) {
                guard let key = target?.tile, target?.at == .send else { continue }
                sends[key, default: 0] += 1
            }
            // Return in a composer the scene clicked into and typed in sends too.
            var composer: String?
            var typed = false
            for action in take.actions.sorted(by: { $0.at < $1.at }) {
                if action.click != nil {
                    let target = clicksWithTargets(take).first { $0.click.at == action.at }?.target
                    composer = target?.at == .composer ? target?.tile : nil
                    typed = false
                } else if let text = action.type, composer != nil {
                    typed = typed || !text.isEmpty
                } else if action.key == "Return", action.allMods == nil, let key = composer, typed {
                    sends[key, default: 0] += 1
                    typed = false
                } else if action.key != nil || action.jump != nil || action.jumpZone != nil {
                    // Any other key (⌘K opens the palette, which then owns typing and
                    // Return) moves focus out of the composer.
                    composer = nil
                    typed = false
                }
            }
        }
        for (key, count) in sends {
            guard let agent = director.agents[key] else { continue }
            let prompts = FilmAgentRunner.prompts(for: agent.agentId)
            expect(prompts.count == count, "\(key): \(count) send(s), the film runner took \(prompts.count) prompt(s) \(prompts)")
            if let firstDone = dones[key]?.min(), let send = starts[key]?.filter({ $0 > firstDone }).min() {
                _ = send
                counts.followUps += 1
            }
        }

        // 7) The bulk bar: every ⌘/⇧-selected row ends where the chosen action puts it
        //    (Settle: settled, its tile closed; Archive: archived).
        for take in scene.takes {
            var selected: [String] = []
            for (click, target) in clicksWithTargets(take) {
                if let key = target?.sidebar, let mods = click.allMods, mods.contains(where: { ["cmd", "command", "shift"].contains($0) }) {
                    selected.append(key)
                } else if let bulk = target?.bulk, let chosen = InboxBulkAction(rawValue: bulk), [.settle, .archive].contains(chosen) {
                    for key in selected {
                        let landed = row(key).map {
                            switch $0.lifecycle {
                            case .settled: return chosen == .settle
                            case .archived: return chosen == .archive
                            default: return false
                            }
                        } ?? false
                        expect(landed, "bulk \(bulk): \(key) was selected but is \(String(describing: row(key)?.lifecycle))")
                        if chosen == .settle {
                            expect(director.agents[key].map { canvas.tileView(for: $0.tileId) == nil } ?? false,
                                   "bulk settle: \(key)'s tile is still on the canvas")
                        }
                    }
                    counts.bulk += selected.count
                    selected = []
                }
            }
        }
        for (takeIndex, take) in scene.takes.enumerated() {
            guard let frames = records[takeIndex] else { continue }
            for action in take.actions {
                guard let bulk = action.pointer?.to?.bulk else { continue }
                let end = action.at + action.duration
                guard end < frames.count else { continue }
                expect(frames[end].rects["bulk:\(bulk)"] != nil, "bulk \(bulk) at \(action.at): not measured (bar or list not showing)")
            }
        }

        // 8) Every zone placed (staged and drawn), every project in the workspace.
        let document = delegate.filmWorkspaceRuntime?.document
        for key in director.zoneKeys {
            expect(canvas.zonePlacement(for: director.zoneId(forKey: key)) != nil, "zone \(key) has no placement on the canvas")
        }
        let registered = (try? RegistryStore(applicationSupportDirectory: director.roots.appSupport).loadOrEmpty())?
            .workspaces.first { $0.id == scene.workspaceId }?.projectIds.count ?? 0
        expect(registered == scene.projects.count, "workspace registers \(registered) of \(scene.projects.count) projects")
        expect((document?.zones.count ?? 0) == director.zoneKeys.count,
               "the workspace has \(document?.zones.count ?? 0) zones, the scene knows \(director.zoneKeys.count)")

        failures += local
        return "v2: \(counts.hovers) hover card(s) opened after the \(dwellFrames)-frame dwell beside their row, \(counts.navigations) navigation(s) glided onto production's target (\(counts.jumps) ⌥ jumps on production's own framing), \(counts.settings) Settings target(s) on camera, \(counts.ticks) sound rule(s) ticked in the film's suite only, \(counts.previews) preview(s) recorded unplayed, \(counts.unseen) unseen Done stretch(es), \(counts.seen) seen after a click, \(counts.nudges) close nudge(s), \(counts.followUps) follow-up(s), \(counts.bulk) agent(s) bulk-archived, \(director.zoneKeys.count) zones over \(scene.projects.count) projects"
    }
}
#endif
