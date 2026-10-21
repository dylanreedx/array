import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// Session handoff (`.plans/79-session-handoff`), stream D. An agent tile's
// Terminal face: the real `claude` TUI on the agent's own conversation, in a
// Ghostty surface inside the same tile. The flip rules live on the tile
// (`ManagedAgentTileNSView`, "Terminal face"); this file is the process.

/// What a Terminal face needs from its host. The app builds one in
/// `wireManagedAgentTile`; a check builds the same with isolated values.
@MainActor
struct AgentTerminalFaceEnvironment {
    var ghostty: GhosttyRuntimeContext
    /// tmux, so claude outlives an Array quit and the tile reattaches on
    /// relaunch (edge case 5). nil runs claude directly in the surface, where
    /// it ends with the surface.
    var tmuxPath: String?
    var defaults: UserDefaults
    /// Where claude keeps `.claude/` — the user's home. Only checks move it.
    var claudeHome: URL = FileManager.default.homeDirectoryForCurrentUser
    /// The managed runner's own resolution, so both faces run one CLI.
    var claudeCommand: () -> PiAgentRunner.ResolvedCommand = { ClaudeAgentRunner.liveResolvedCommand() }
    var reservedShortcutHandler: ((NSEvent) -> Bool)?
    /// How often the live session file is read while the face runs.
    var pollInterval: TimeInterval = 2
    /// Asks before ending a busy claude. True means go ahead.
    var confirm: (_ message: String, _ action: String) -> Bool = { message, action in
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "Its turn stops, and what it has written so far stays in the session."
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// One running Terminal face: its surface, its claude, and what claude says
/// about itself while it runs.
@MainActor
final class AgentTerminalFaceSession {
    let tileId: UUID
    let hostView = TerminalHostView(frame: .zero)
    let runtime: GhosttyTerminalRuntime
    /// The tmux session the face lives in, when tmux runs it.
    let tmuxSessionName: String?
    /// Every session id claude reported, oldest first. `/clear` and `/resume`
    /// move a running claude to a new session (edge case 3); flipping back
    /// reads all of them.
    private(set) var sessionIds: [String]
    private(set) var claudePid: Int32?
    private(set) var live: ClaudeTerminalFace.LiveSession?
    /// Called once when claude is gone — `/exit`, a crash, or Array ending it.
    var onExit: (() -> Void)?
    /// Called when claude reports a different session id than the last one.
    var onSessionChange: ((String) -> Void)?
    /// Array is tearing the surface down on purpose (a workspace switch, a
    /// close): the exit that follows is not claude leaving.
    private var detaching = false
    private var pollTimer: Timer?
    private var pollInFlight = false
    private let environment: AgentTerminalFaceEnvironment
    private let cwd: String

    init(tileId: UUID, arguments: [String], cwd: String, sessionIds: [String], environment: AgentTerminalFaceEnvironment) {
        self.tileId = tileId
        self.cwd = cwd
        self.environment = environment
        self.sessionIds = sessionIds
        let inner = LaunchProfile(
            command: arguments[0], arguments: Array(arguments.dropFirst()), cwd: cwd, title: "Claude Code")
        let profile: LaunchProfile
        if let tmuxPath = environment.tmuxPath {
            // `new-session -A`: attaches when the session already exists, which
            // is the relaunch reattach; creates it running claude otherwise.
            profile = TmuxSession.wrap(profile: inner, tileId: tileId, tmuxPath: tmuxPath, defaults: environment.defaults)
            tmuxSessionName = TmuxSession.sessionName(tileId: tileId)
        } else {
            profile = inner
            tmuxSessionName = nil
        }
        runtime = GhosttyTerminalRuntime(
            tileId: tileId, title: "Claude Code", launchProfile: profile,
            ghostty: environment.ghostty, displayDefaults: environment.defaults)
        runtime.reservedShortcutHandler = environment.reservedShortcutHandler
        runtime.onRuntimeExited = { [weak self] _, _ in self?.surfaceExited() }
    }

    var isBusy: Bool { live?.isBusy ?? false }
    var currentSessionId: String { sessionIds.last! }

    func start() {
        hostView.attach(runtime: runtime)
        let timer = Timer(timeInterval: environment.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        poll()
    }

    /// Ends the surface without ending claude — tmux keeps it.
    func detachSurface() {
        detaching = true
        pollTimer?.invalidate()
        pollTimer = nil
        runtime.terminate(policy: .force)
        hostView.detachRuntime()
    }

    /// Ends claude itself. With tmux that is the session; the surface's exit
    /// follows and reports through `onExit`.
    func endClaude() {
        if let tmuxPath = environment.tmuxPath, let name = tmuxSessionName {
            _ = try? ProcessTmuxControl(tmuxPath: tmuxPath, defaults: environment.defaults)
                .run(["kill-session", "-t", name])
        } else {
            runtime.terminate(policy: .force)
        }
    }

    /// Whether a tmux session for this tile is running now.
    static func tmuxSessionExists(tileId: UUID, environment: AgentTerminalFaceEnvironment) -> Bool {
        guard let tmuxPath = environment.tmuxPath else { return false }
        let control = ProcessTmuxControl(tmuxPath: tmuxPath, defaults: environment.defaults)
        return (try? control.run(["has-session", "-t", TmuxSession.sessionName(tileId: tileId)])) != nil
    }

    /// One read of what claude says about the process, off the main thread.
    func poll() {
        guard !pollInFlight, !detaching else { return }
        pollInFlight = true
        let known = claudePid
        // `ProcessTmuxControl` is Sendable; the defaults it holds are not.
        let control = environment.tmuxPath.map { ProcessTmuxControl(tmuxPath: $0, defaults: environment.defaults) }
        let name = tmuxSessionName
        let home = environment.claudeHome
        let lastSession = currentSessionId
        let cwd = self.cwd
        Task { @MainActor [weak self] in
            let (pid, live) = await Self.readProcess(
                known: known, control: control, sessionName: name,
                lastSession: lastSession, cwd: cwd, claudeHome: home)
            guard let self else { return }
            self.pollInFlight = false
            if self.claudePid == nil { self.claudePid = pid }
            guard let live else { return }
            self.live = live
            if live.sessionId != self.currentSessionId {
                self.sessionIds.append(live.sessionId)
                self.onSessionChange?(live.sessionId)
            }
        }
    }

    /// Off the main actor: a tmux query and two small file reads.
    nonisolated private static func readProcess(
        known: Int32?, control: ProcessTmuxControl?, sessionName: String?,
        lastSession: String, cwd: String, claudeHome: URL
    ) async -> (Int32?, ClaudeTerminalFace.LiveSession?) {
        var pid = known
        if pid == nil, let control, let sessionName {
            // `/usr/bin/env` execs claude, so the pane's pid IS claude's.
            let out = try? control.run(["list-panes", "-t", sessionName, "-F", "#{pane_pid}"])
            pid = out.flatMap { Int32($0.split(separator: "\n").first.map(String.init) ?? "") }
        }
        if pid == nil {
            pid = pidFromSessionFiles(sessionId: lastSession, cwd: cwd, claudeHome: claudeHome)
        }
        return (pid, pid.flatMap { ClaudeTerminalFace.liveSession(pid: $0, claudeHome: claudeHome) })
    }

    /// Without tmux there is no pane to ask; claude's own file for our session
    /// names the process.
    nonisolated private static func pidFromSessionFiles(sessionId: String, cwd: String, claudeHome: URL) -> Int32? {
        let directory = claudeHome.appendingPathComponent(".claude/sessions", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return nil }
        for name in names where name.hasSuffix(".json") {
            guard let pid = Int32(name.dropLast(5)),
                  let live = ClaudeTerminalFace.liveSession(pid: pid, claudeHome: claudeHome),
                  live.sessionId == sessionId, kill(pid, 0) == 0 else { continue }
            return pid
        }
        return nil
    }

    private func surfaceExited() {
        pollTimer?.invalidate()
        pollTimer = nil
        guard !detaching else { return }
        // The tmux CLIENT ended. If claude is still running behind it (the
        // tmux prefix and `d`), it is ended too: flipping back while it runs
        // would put a second writer on the session.
        if tmuxSessionName != nil, Self.tmuxSessionExists(tileId: tileId, environment: environment) {
            endClaude()
        }
        onExit?()
    }
}

/// "Switches to Terminal when this turn ends", above the composer while a flip
/// waits (edge case 9; `mocks/2-one-tile-two-faces.png`, bottom left). Paints
/// in `draw(_:)` from tokens, like the title band, so it adds no layer colour.
@MainActor
final class AgentFaceFlipBanner: NSView {
    let label = NSTextField(labelWithString: "Switches to Terminal when this turn ends")
    let stopButton = NSButton(title: "Stop now", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    var onStopNow: (() -> Void)?
    var onCancel: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("agentTile.faceFlipBanner")
        let clock = NSImageView(image: NSImage(systemSymbolName: "clock", accessibilityDescription: nil) ?? NSImage())
        clock.setAccessibilityElement(false)
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for button in [stopButton, cancelButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
        }
        stopButton.action = #selector(stopNow)
        cancelButton.action = #selector(cancel)
        let row = NSStackView(views: [clock, label, NSView(), stopButton, cancelButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = CGFloat(Space.m)
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(Space.m)),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(Space.m)),
            row.topAnchor.constraint(equalTo: topAnchor, constant: CGFloat(Space.s)),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CGFloat(Space.s)),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(label.stringValue)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func stopNow() { onStopNow?() }
    @objc private func cancel() { onCancel?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = effectiveTokenTheme
        label.textColor = TextToken.textPrimary.color.nsColor(for: theme)
        let card = bounds.insetBy(dx: CGFloat(Space.m), dy: CGFloat(Space.s))
        let radius = CGFloat(Radius.card)
        SurfaceToken.cardMessage.color.nsColor(for: theme).setFill()
        NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius).fill()
    }
}
