import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Darwin

// Plan: .plans/79-session-handoff/README.md, phase 2.
//
// What happens to a session another app holds, after the sidebar's click or
// Move here made a tile for it, and to an Array agent whose session another
// app opens. Every decision is re-taken whenever discovery publishes
// (`ExternalSessionMonitor.onChange`), from the one rule in
// `ExternalSessionHandoff`: a session is held elsewhere while a process that
// is not one of Array's own agents holds it.
//
// - Watching: the tile follows the file. When the holder exits, "Ended" with
//   Continue here (edge case 7).
// - Move here: the tile waits; when the holder exits it becomes the session's
//   agent at once (edge case 8). Array never ends another app's process.
// - Paused (edge case 1): an Array agent's own session opened elsewhere. Its
//   runner stops, sends are refused, and when the other process exits what it
//   wrote is appended and the agent carries on.

/// A Terminal face no tile shows: the claude discovery last saw running it,
/// and the session it was on, which the agent continues once that claude exits.
struct UnshownTerminalFace: Equatable {
    var pid: Int32?
    var startedAt: Date?
    var sessionId: String?
    /// The face as its tile saved it — the mark its turns are read from —
    /// and the tile, when the hold came from a saved face.
    var saved: AgentTerminalFaceState?
    var tileId: UUID?
}

/// One paused agent: where its session is open, and the byte the file ended at
/// when the pause began.
struct ExternalSessionPause: Equatable {
    var hostName: String
    var pid: Int32?
    /// When `pid` started: the pause lifts only once that process is gone.
    var startedAt: Date?
    var provider: ExternalSessionProvider
    var url: URL?
    var offset: UInt64
}

extension AppDelegate {
    /// Re-takes every decision against the monitor's latest snapshot. Cheap:
    /// one pass over the records, file work only on a pause's start and end.
    func reconcileExternalSessions() {
        let snapshot = externalSessionMonitor.snapshot
        let discovered = externalSessionMonitor.hasDiscovered
        dropDetachedExternalSessionAgents()
        reconcileTerminalFaceHolds()
        for record in Array(agentSupervisor.records.values) {
            if let link = record.externalSession {
                let holding = ExternalSessionHandoff.holding(link, in: snapshot, discovered: discovered)
                if case let .heldElsewhere(session) = holding {
                    let name = externalHostName(of: session)
                    if name != link.hostName || session.pid != link.holderPid {
                        var renamed = link
                        renamed.hostName = name
                        renamed.holderPid = session.pid
                        renamed.holderStartedAt = session.pid.flatMap(ExternalSessionHandoff.processStart)
                        agentSupervisor.linkExternalSession(record.id, renamed)
                    }
                } else if case .released = holding, link.mode == .movingHere {
                    continueExternalSessionHere(record.id)
                    continue
                }
            } else {
                reconcilePause(record, snapshot: snapshot, discovered: discovered)
            }
            applyExternalSessionState(record.id)
        }
        for id in externalSessionPauses.keys where agentSupervisor.records[id] == nil {
            externalSessionPauses[id] = nil
        }
    }

    /// The banner, the band's marker and status, for one agent's resident tile.
    func applyExternalSessionState(_ agentId: AgentID) {
        guard let tileId = agentSupervisor.records[agentId]?.tileId,
              let view = canvasView?.tileView(for: tileId) as? ManagedAgentTileNSView else { return }
        let (state, status) = externalSessionPresentation(agentId) ?? (nil, nil)
        if view.sessionHandoffState != state || view.agentStatusOverride != status {
            view.applySessionHandoff(state, status: status)
        }
    }

    private func externalSessionPresentation(_ agentId: AgentID) -> (AgentSessionHandoffState, AgentStatus?)? {
        guard let record = agentSupervisor.records[agentId] else { return nil }
        guard let link = record.externalSession else {
            return externalSessionPauses[agentId].map { (.paused(app: $0.hostName), .needsAttention) }
        }
        let holding = ExternalSessionHandoff.holding(
            link, in: externalSessionMonitor.snapshot, discovered: externalSessionMonitor.hasDiscovered)
        var host: ExternalAgentSession?
        if case let .heldElsewhere(session) = holding { host = session }
        let status = host.map { session -> AgentStatus in
            switch session.status {
            case .busy: return .working
            case .waiting: return .needsAttention
            case .idle, .unknown: return .idle
            }
        }
        switch link.mode {
        case .watching:
            if case .released = holding { return (.ended(app: link.hostName), nil) }
            return (.watching(
                app: link.hostName, canCopy: link.provider == .claude && link.transcriptPath != nil,
                canMove: link.tracksProcess), status)
        case .movingHere:
            return (.waitingToMove(
                app: link.hostName, closesInApp: ExternalSessionHandoff.isDesktopApp(link.hostName),
                canCopy: link.provider == .claude && link.transcriptPath != nil), status)
        }
    }

    /// Called from `wireManagedAgentTile` after the attach. True when the tile
    /// shows a session another app holds, so the agent's own restore is not
    /// run over it.
    func wireExternalSessionTile(_ view: ManagedAgentTileNSView, agentId: AgentID) -> Bool {
        view.onSessionHandoffAction = { [weak self] action in
            self?.performSessionHandoffAction(action, agentId: agentId)
        }
        applyExternalSessionState(agentId)
        guard let link = agentSupervisor.records[agentId]?.externalSession else {
            return false
        }
        if let path = link.transcriptPath {
            view.followSessionFile(URL(fileURLWithPath: path), provider: link.provider, origin: link.hostName)
        }
        return true
    }

    func performSessionHandoffAction(_ action: AgentSessionHandoffAction, agentId: AgentID) {
        guard let record = agentSupervisor.records[agentId] else { return }
        switch action {
        case .moveHere:
            guard var link = record.externalSession else { return }
            link.mode = .movingHere
            agentSupervisor.linkExternalSession(agentId, link)
            reconcileExternalSessions()
        case .continueHere:
            continueExternalSessionHere(agentId)
        case .copyHere, .copyInstead:
            copyExternalSessionInPlace(agentId)
        case .cancel:
            cancelExternalSessionTile(agentId)
        case .showApp:
            let pause = externalSessionPauses[agentId]
            activateExternalSessionHost(pid: pause?.pid, hostName: pause?.hostName ?? "")
        }
        pushExternalSessionRows()
    }

    /// The session is this agent's now: Move here after the other app let go,
    /// or Continue here on an ended watch. Whatever the other app wrote since
    /// the last read is rendered first, so nothing is missing; the next prompt
    /// resumes the session (`claude --resume <id>`).
    func continueExternalSessionHere(_ agentId: AgentID) {
        guard let record = agentSupervisor.records[agentId], let link = record.externalSession else { return }
        let view = record.tileId.flatMap { canvasView?.tileView(for: $0) as? ManagedAgentTileNSView }
        view?.stopFollowingSessionFile(catchUp: true)
        agentSupervisor.adoptExternalSession(agentId)
        view?.applySessionHandoff(nil)
        seedAdoptedTranscript(agentId, link: link)
        pushExternalSessionRows()
    }

    /// Copy here / Copy instead: the tile becomes the copy. Its first turn
    /// forks the session (`--resume <id> --fork-session`) while the original
    /// stays where it is — Copy's own mechanism, on this tile.
    private func copyExternalSessionInPlace(_ agentId: AgentID) {
        guard let record = agentSupervisor.records[agentId], let link = record.externalSession,
              link.provider == .claude else { return }
        let view = record.tileId.flatMap { canvasView?.tileView(for: $0) as? ManagedAgentTileNSView }
        view?.stopFollowingSessionFile(catchUp: true)
        agentSupervisor.linkExternalSession(agentId, nil)
        agentSupervisor.markSessionFork(agentId, from: link.sessionId)
        view?.applySessionHandoff(nil)
        seedAdoptedTranscript(agentId, link: link)
    }

    /// Cancel on a waiting tile: it goes, and so does the agent it was — it
    /// never owned anything.
    private func cancelExternalSessionTile(_ agentId: AgentID) {
        guard let record = agentSupervisor.records[agentId], record.externalSession != nil else { return }
        if let tileId = record.tileId { agentSupervisor.suppressAgentRespawn(forTile: tileId) }
        _ = agentSupervisor.archive(agentId)
        if let tileId = record.tileId { deleteTile(id: tileId) }
    }

    /// A watch or Move here agent whose tile was closed: dropped, never filed
    /// in History — there is no work of Array's in it.
    func dropDetachedExternalSessionAgents() {
        for record in agentSupervisor.records.values where record.externalSession != nil && record.tileId == nil {
            _ = agentSupervisor.archive(record.id)
        }
    }

    /// The transcript a later re-attach of this tile shows: the session as its
    /// file holds it now, seeded the way a restore seeds one.
    private func seedAdoptedTranscript(_ agentId: AgentID, link: AgentExternalSessionLink) {
        guard let path = link.transcriptPath else { return }
        let url = URL(fileURLWithPath: path)
        let threadId = "rehydrated-\(agentId.rawValue.uuidString)"
        let provider = link.provider
        Task.detached(priority: .utility) { [weak self] in
            let tail = SessionFileTail.tail(in: url, maxBytes: RehydrationLimits().maxBytes)
            let transcript = provider == .claude
                ? ClaudeSessionTranscriptReader.parse(lines: tail.lines, threadId: threadId, truncated: tail.truncated)
                : CodexSessionTranscriptReader.parse(lines: tail.lines, threadId: threadId, truncated: tail.truncated)
            await MainActor.run {
                guard let self, !transcript.steps.isEmpty,
                      self.agentSupervisor.rehydratedTranscript(for: agentId) == nil else { return }
                self.agentSupervisor.seedRehydratedTranscript(transcript, for: agentId)
            }
        }
    }

    // MARK: - Paused elsewhere (edge case 1)

    /// The session ids an agent of Array's writes, and their CLI.
    private func ownSessions(of record: AgentRecord) -> (ExternalSessionProvider, Set<String>)? {
        switch record.harness {
        case .claudeCode:
            return (.claude, [AgentSupervisor.claudeSessionLocation(for: record).sessionId])
        case .codex:
            return record.codexThreadId.map { (.codex, [$0]) }
        case .pi, nil:
            return nil
        }
    }

    private func reconcilePause(_ record: AgentRecord, snapshot: ExternalSessionSnapshot, discovered: Bool) {
        let id = record.id
        guard record.capabilities.locallyManaged, !agentSupervisor.isInTerminalFace(id),
              let (provider, sessionIds) = ownSessions(of: record) else { return }
        if let holder = ExternalSessionHandoff.pausingHolder(provider: provider, sessionIds: sessionIds, in: snapshot) {
            let name = externalHostName(of: holder)
            if var pause = externalSessionPauses[id] {
                if pause.hostName != name || pause.pid != holder.pid {
                    pause.hostName = name
                    pause.pid = holder.pid
                    pause.startedAt = holder.pid.flatMap(ExternalSessionHandoff.processStart)
                    externalSessionPauses[id] = pause
                }
                return
            }
            let url = holder.transcriptURL ?? (provider == .claude ? ClaudeTerminalFace.sessionFileURL(
                claudeHome: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
                cwd: AgentSupervisor.claudeSessionLocation(for: record).cwd,
                sessionId: holder.sessionId) : nil)
            // The mark: where the agent's own transcript ends — where its last
            // turn left the file — not where the file had got to by the time
            // discovery noticed, which already holds the other app's first
            // prompt (review #11). Without one, just past the last whole line,
            // so a line mid-write is appended whole later.
            let offset = url.map {
                agentSupervisor.sessionFileMark(for: id, url: $0) ?? SessionFileTail.tail(in: $0, maxBytes: 64 * 1024).end
            } ?? 0
            externalSessionPauses[id] = ExternalSessionPause(
                hostName: name, pid: holder.pid, startedAt: holder.pid.flatMap(ExternalSessionHandoff.processStart),
                provider: provider, url: url, offset: offset)
            agentSupervisor.beginExternalHold(for: id, hostName: name)
            return
        }
        // Released only once the holding process is really gone: one pass that
        // missed it (its status file mid-rewrite) is not the other app letting go.
        guard let pause = externalSessionPauses[id],
              discovered, !(provider == .claude && snapshot.claudeUnreadable),
              ExternalSessionHandoff.holderIsGone(pid: pause.pid, startedAt: pause.startedAt) else { return }
        // The other process let go: what it wrote comes into the agent's
        // transcript — once, read off the main thread, for every tile of the
        // agent now and later (review #7) — then the agent is Array's again.
        externalSessionPauses[id] = nil
        guard let url = pause.url else {
            agentSupervisor.endExternalHold(for: id, tookTurns: false)
            return
        }
        agentSupervisor.takeBackOutsideTurns(
            for: id, url: url, from: pause.offset, provider: provider, place: pause.hostName
        ) { [weak self] wroteLines in
            // Opened elsewhere again while the read ran: that pause holds it.
            guard let self, self.externalSessionPauses[id] == nil else { return }
            self.agentSupervisor.endExternalHold(for: id, tookTurns: wroteLines > 0)
        }
    }

    // MARK: - Terminal faces no tile shows (review finding 3)

    /// Holds every Claude agent whose Terminal face runs, or may run, without a
    /// tile showing it, and lets go once its claude has exited. The evidence:
    /// discovery's claude carrying the agent's tag in its Terminal face; and,
    /// until discovery's first pass, a tile saved in that face. A face this
    /// launch watches (`AgentSupervisor.terminalFaceWatch`: a tile showed it,
    /// parked or not) is the watch's, and is left to it. Either way the face
    /// ends through `AgentSupervisor.finishTerminalFace`, the one end, which
    /// brings its turns home and adopts what claude ended on.
    func reconcileTerminalFaceHolds() {
        let monitor = externalSessionMonitor
        var running: [String: ExternalAgentSession] = [:]
        for session in monitor.snapshot.sessions {
            // Alive now: a pass from before a face's claude exited still lists it.
            guard case let .arrayTerminalFace(tag) = session.host,
                  let pid = session.pid, ExternalSessionHandoff.processStart(pid) != nil else { continue }
            running[tag] = session
        }
        let saved = monitor.hasDiscovered ? [:] : savedTerminalFaces()
        for record in agentSupervisor.records.values where record.harness == .claudeCode {
            let id = record.id
            if agentSupervisor.terminalFaceWatch(for: id) != nil {
                unshownTerminalFaces[id] = nil
                continue
            }
            if let live = running[AgentProcessAttribution.ownerTag(for: id)] {
                var face = unshownTerminalFaces[id] ?? UnshownTerminalFace()
                if face.pid != live.pid {
                    face.pid = live.pid
                    face.startedAt = live.pid.flatMap(ExternalSessionHandoff.processStart)
                }
                face.sessionId = live.sessionId
                unshownTerminalFaces[id] = face
                agentSupervisor.holdForTerminalFace(id)
            } else if let tileId = record.tileId, let state = saved[tileId],
                      !agentSupervisor.hasEndedTerminalFace(onTile: tileId) {
                if unshownTerminalFaces[id] == nil {
                    unshownTerminalFaces[id] = UnshownTerminalFace(
                        sessionId: state.sessionIds.last, saved: state, tileId: tileId)
                }
                agentSupervisor.holdForTerminalFace(id)
            } else if let face = unshownTerminalFaces[id], monitor.hasDiscovered,
                      !monitor.snapshot.claudeUnreadable,
                      ExternalSessionHandoff.holderIsGone(pid: face.pid, startedAt: face.startedAt) {
                unshownTerminalFaces[id] = nil
                if var state = face.saved {
                    // Discovery saw claude move session (`/clear`) after the save.
                    if let latest = face.sessionId, latest != state.sessionIds.last { state.latestSessionId = latest }
                    agentSupervisor.finishTerminalFace(for: id, persisted: state, tileId: face.tileId)
                } else {
                    // No mark to read from: the record's half only.
                    agentSupervisor.endTerminalFace(for: id, sessionId: face.sessionId, model: nil, tookTurns: false)
                }
            }
        }
        for id in unshownTerminalFaces.keys where agentSupervisor.records[id] == nil {
            unshownTerminalFaces[id] = nil
        }
    }

    /// "Show Ghostty": the app the holding process runs in, from its ancestry;
    /// a session in tmux has no app above it, so the app is found by name.
    func activateExternalSessionHost(pid: Int32?, hostName: String) {
        if let qa = activateExternalSessionHostForQA {
            qa(pid, hostName)
            return
        }
        var cursor = pid
        for _ in 0..<64 {
            guard let current = cursor, current > 1 else { break }
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                app.activate()
                return
            }
            cursor = Self.parentPid(of: current)
        }
        let appName: String
        switch hostName {
        case "Claude app": appName = "Claude"
        case "Codex app": appName = "Codex"
        case "Terminal.app": appName = "Terminal"
        default: appName = hostName
        }
        NSWorkspace.shared.runningApplications.first { $0.localizedName == appName }?.activate()
    }

    private static func parentPid(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let parent = Int32(info.pbi_ppid)
        return parent == pid ? nil : parent
    }
}
