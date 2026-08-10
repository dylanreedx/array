import AppKit
import ContinuumRevivedCore

/// Go-live Phase 4: the first-run window. Shown once when the app boots on a
/// fresh profile (empty registry), and reopenable any time from
/// Help > Environment Setup… — the same panel is also where the
/// missing-command alert points, replacing the dead-end "not found on $PATH".
///
/// v1 ships welcome + environment check (live re-check) + connect-via-real-
/// tile. The claude notification-hook consent step (ticket 42) slots in here
/// once its installer/consent machinery exists — today only the consumer half
/// of that ticket is built.
@MainActor
final class OnboardingPanel {
    /// One environment probe: how to check a tool (or a provider login) and
    /// what to tell the user when it's missing. Injected so the self-check is
    /// deterministic.
    struct Probe {
        let id: String
        let title: String
        /// One-line role shown under the title.
        let detail: String
        /// Full guidance line shown when the probe fails — a copy-paste
        /// install command, or the CLI login flow for provider auth. Auth is
        /// ALWAYS the CLI's own login (OAuth), never a pasted API key.
        let missingGuidance: String
        /// Launch profile that opens a real tile so the CLI's own login/auth
        /// flow runs inside Array; nil for non-tile tools (tmux, git).
        let connectProfileId: String?
        /// Returns a short display string when satisfied (a path, or an auth
        /// status), nil when not. May run a bounded subprocess — refresh is
        /// synchronous, so keep probes under ~a second each.
        let locate: () -> String?
    }

    var onOpenTile: ((String) -> Void)?
    var onClose: (() -> Void)?

    private let probes: [Probe]
    private var panel: NSPanel?
    private var previousKeyWindow: NSWindow?
    private var statusLabels: [String: NSTextField] = [:]
    private var guidanceLabels: [String: NSTextField] = [:]
    private var connectButtons: [String: NSButton] = [:]

    init(probes: [Probe]) {
        self.probes = probes
    }

    /// The real environment: claude/codex/pi through the augmented PATH
    /// (ToolEnvironment), tmux through its locator, git through the CLT
    /// presence check that does NOT trigger the Xcode CLT install dialog, and
    /// pi provider logins through `pi auth check` — auth is always the CLI's
    /// own `/login` OAuth flow, never a pasted API key.
    static func liveProbes(
        environment: @escaping () -> [String: String],
        defaults: UserDefaults = .standard
    ) -> [Probe] {
        func locateOnPath(_ name: String) -> (() -> String?) {
            {
                ToolDetector.live.locate(name, in: ToolDetector.splitPath(environment()["PATH"] ?? ""))
            }
        }
        func piAuthStatus(provider: String) -> (() -> String?) {
            {
                guard let pi = locateOnPath("pi")() else { return nil }
                guard let output = boundedOutput(
                    executable: pi,
                    arguments: ["auth", "check", "--provider", provider, "--json", "--no-refresh"],
                    environment: environment(),
                    timeout: 3.0
                ) else { return nil }
                guard output.contains("\"status\":\"ready\"") else { return nil }
                if let match = output.range(of: "\"authType\":\"([a-z-]+)\"", options: .regularExpression) {
                    let authType = output[match].split(separator: ":").last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                    return "signed in (\(authType ?? "CLI auth"))"
                }
                return "signed in (CLI auth)"
            }
        }
        func claudeAuthStatus() -> (() -> String?) {
            {
                guard let claude = locateOnPath("claude")() else { return nil }
                guard let output = boundedOutput(
                    executable: claude,
                    arguments: ["auth", "status", "--json"],
                    environment: environment(),
                    timeout: 3.0
                ) else { return nil }
                guard ClaudeCLIBackend.isLoggedIn(authStatusJSON: Data(output.utf8)) else { return nil }
                return "signed in (claude.ai)"
            }
        }
        return [
            Probe(
                id: "claude",
                title: "Claude Code",
                detail: "Claude terminal tiles, and managed agents on Claude models.",
                missingGuidance: "Install: curl -fsSL https://claude.ai/install.sh | bash",
                connectProfileId: "claude",
                locate: locateOnPath("claude")
            ),
            Probe(
                id: "claude-auth",
                title: "Claude models (Claude Code)",
                detail: "Managed agents run Claude models through your own Claude Code sign-in — no API keys.",
                missingGuidance: "Sign in: run claude in a terminal and follow its login (OAuth — no API keys)",
                connectProfileId: nil,
                locate: claudeAuthStatus()
            ),
            Probe(
                id: "codex",
                title: "Codex",
                detail: "Agent CLI — at least one agent CLI is recommended.",
                missingGuidance: "Install: npm install -g @openai/codex",
                connectProfileId: "codex",
                locate: locateOnPath("codex")
            ),
            Probe(
                id: "pi",
                title: "pi",
                detail: "Managed agents on GPT and other providers (optional) — Claude models run through Claude Code itself.",
                missingGuidance: "Install: npm install -g @earendil-works/pi-coding-agent (needs Node — no npm? brew install node first)",
                connectProfileId: nil,
                locate: locateOnPath("pi")
            ),
            Probe(
                id: "pi-auth-anthropic",
                title: "Claude models (pi ▸ anthropic)",
                detail: "Fallback for Claude models only when Claude Code isn't installed (metered separately from a Claude subscription).",
                missingGuidance: "Sign in: run pi in a terminal, then /login anthropic (OAuth — no API keys)",
                connectProfileId: nil,
                locate: piAuthStatus(provider: "anthropic")
            ),
            Probe(
                id: "pi-auth-openai-codex",
                title: "GPT models (pi ▸ openai-codex)",
                detail: "Lets managed agents run GPT models.",
                missingGuidance: "Sign in: run pi in a terminal, then /login openai-codex (OAuth — no API keys)",
                connectProfileId: nil,
                locate: piAuthStatus(provider: "openai-codex")
            ),
            Probe(
                id: "tmux",
                title: "tmux",
                detail: "Keeps terminal sessions alive across app restarts (optional).",
                missingGuidance: "Install: brew install tmux",
                connectProfileId: nil,
                locate: { TmuxLocator.resolve(defaults: defaults) }
            ),
            Probe(
                id: "git",
                title: "Git (Command Line Tools)",
                detail: "File tree status, diff review, and agent worktrees.",
                missingGuidance: "Install: xcode-select --install",
                connectProfileId: nil,
                locate: {
                    for candidate in [
                        "/Library/Developer/CommandLineTools/usr/bin/git",
                        "/Applications/Xcode.app/Contents/Developer/usr/bin/git"
                    ] where FileManager.default.isExecutableFile(atPath: candidate) {
                        return candidate
                    }
                    return nil
                }
            )
        ]
    }

    /// Small bounded runner for probe subprocesses (`pi auth check`). Returns
    /// stdout on clean exit within the timeout, nil otherwise.
    private static func boundedOutput(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let killer = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func show(near host: NSWindow?) {
        let panel = ensurePanel()
        previousKeyWindow = host ?? NSApp.keyWindow
        if let host, host.screen != nil {
            let hostFrame = host.frame
            let size = panel.frame.size
            let origin = NSPoint(x: hostFrame.midX - size.width / 2, y: hostFrame.midY - size.height / 2)
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }
        refreshStatuses()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        let restoreTarget = previousKeyWindow
        panel = nil
        statusLabels = [:]
        guidanceLabels = [:]
        connectButtons = [:]
        previousKeyWindow = nil
        restoreTarget?.makeKeyAndOrderFront(nil)
        onClose?()
    }

    // MARK: - Panel construction

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.appearance = NSApp?.effectiveAppearance
        panel.title = "Welcome to Array"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false

        let root = NSView(frame: panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 560, height: 480))
        root.autoresizingMask = [.width, .height]
        root.setAccessibilityIdentifier("onboarding-panel-root")
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.appResolvedCGColor
        panel.contentView = root

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor)
        ])

        let intro = NSTextField(wrappingLabelWithString:
            "Array is a spatial workspace for coding agents: projects, agents, terminals, and browsers share one canvas, so parallel work stays visible instead of stacking up in hidden tabs.")
        intro.font = NSFont.systemFont(ofSize: 13)
        stack.addArrangedSubview(intro)
        intro.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true

        let envHeader = NSTextField(labelWithString: "Environment")
        envHeader.font = NSFont.boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(envHeader)

        for probe in probes {
            let row = NSStackView()
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 2

            let headline = NSStackView()
            headline.orientation = .horizontal
            headline.spacing = 6
            let status = NSTextField(labelWithString: "…")
            status.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
            statusLabels[probe.id] = status
            let title = NSTextField(labelWithString: probe.title)
            title.font = NSFont.boldSystemFont(ofSize: 12)
            headline.addArrangedSubview(status)
            headline.addArrangedSubview(title)
            if let profileId = probe.connectProfileId {
                let connect = NSButton(title: "Open a \(probe.title) tile", target: self, action: #selector(connectPressed(_:)))
                connect.identifier = NSUserInterfaceItemIdentifier(profileId)
                connect.bezelStyle = .rounded
                connect.controlSize = .small
                connectButtons[probe.id] = connect
                headline.addArrangedSubview(connect)
            }
            row.addArrangedSubview(headline)

            let detail = NSTextField(wrappingLabelWithString: probe.detail)
            detail.font = NSFont.systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            row.addArrangedSubview(detail)

            let guidance = NSTextField(labelWithString: "")
            guidance.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            guidance.isSelectable = true
            guidanceLabels[probe.id] = guidance
            row.addArrangedSubview(guidance)

            stack.addArrangedSubview(row)
        }

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 10
        let recheck = NSButton(title: "Re-check", target: self, action: #selector(recheckPressed(_:)))
        recheck.bezelStyle = .rounded
        let done = NSButton(title: "Done", target: self, action: #selector(donePressed(_:)))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        footer.addArrangedSubview(recheck)
        footer.addArrangedSubview(done)
        stack.addArrangedSubview(footer)

        self.panel = panel
        return panel
    }

    private func refreshStatuses() {
        // The Re-check moment is exactly when a provider login just happened
        // — re-probe the model catalogue too (throttled; inert in QA).
        AgentModelCatalog.shared.requestRefresh()
        for probe in probes {
            let located = probe.locate()
            guard let status = statusLabels[probe.id], let guidance = guidanceLabels[probe.id] else { continue }
            if let located {
                status.stringValue = "✓"
                status.textColor = .systemGreen
                guidance.stringValue = located
                guidance.textColor = .secondaryLabelColor
            } else {
                status.stringValue = "✗"
                status.textColor = .systemOrange
                guidance.stringValue = probe.missingGuidance
                guidance.textColor = .labelColor
            }
            connectButtons[probe.id]?.isEnabled = located != nil
        }
    }

    @objc private func recheckPressed(_ sender: Any?) {
        refreshStatuses()
    }

    @objc private func connectPressed(_ sender: NSButton) {
        guard let profileId = sender.identifier?.rawValue else { return }
        onOpenTile?(profileId)
    }

    @objc private func donePressed(_ sender: Any?) {
        close()
    }

    // MARK: - QA accessors (`--onboarding-panel-check`)

    var contentViewForQA: NSView? { panel?.contentView }
    var panelWindowNumberForQA: Int? { panel?.windowNumber }
    func statusTextForQA(_ id: String) -> String? { statusLabels[id]?.stringValue }
    func guidanceTextForQA(_ id: String) -> String? { guidanceLabels[id]?.stringValue }
    func connectButtonForQA(_ id: String) -> NSButton? { connectButtons[id] }
    func recheckForQA() { refreshStatuses() }

    enum SelfCheckError: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            if case let .message(text) = self { return text }
            return "onboarding self-check failed"
        }
    }

    /// Deterministic witness: found/missing rows render status + guidance, a
    /// re-check picks up a tool that appeared, connect buttons follow found
    /// state and deliver their profile id, the render isn't blank, and the
    /// panel doesn't leak its window.
    static func runSelfCheck() throws {
        final class MutableLocation: @unchecked Sendable {
            var path: String?
            init(_ path: String?) { self.path = path }
        }
        let claudeLocation = MutableLocation("/qa/bin/claude")
        let codexLocation = MutableLocation(nil)
        let authLocation = MutableLocation(nil)
        let probes = [
            Probe(id: "claude", title: "Claude Code", detail: "agent", missingGuidance: "Install: install-claude",
                  connectProfileId: "claude", locate: { claudeLocation.path }),
            Probe(id: "codex", title: "Codex", detail: "agent", missingGuidance: "Install: install-codex",
                  connectProfileId: "codex", locate: { codexLocation.path }),
            Probe(id: "pi-auth", title: "Claude models (pi ▸ anthropic)", detail: "auth",
                  missingGuidance: "Sign in: /login anthropic", connectProfileId: nil,
                  locate: { authLocation.path }),
            Probe(id: "tmux", title: "tmux", detail: "persistence", missingGuidance: "Install: brew install tmux",
                  connectProfileId: nil, locate: { nil })
        ]
        let panel = OnboardingPanel(probes: probes)
        var opened: [String] = []
        panel.onOpenTile = { opened.append($0) }
        panel.show(near: nil)

        guard panel.statusTextForQA("claude") == "✓", panel.guidanceTextForQA("claude") == "/qa/bin/claude" else {
            throw SelfCheckError.message("claude row should show found + path, got \(panel.statusTextForQA("claude") ?? "nil") / \(panel.guidanceTextForQA("claude") ?? "nil")")
        }
        guard panel.statusTextForQA("codex") == "✗", panel.guidanceTextForQA("codex") == "Install: install-codex" else {
            throw SelfCheckError.message("codex row should show missing + guidance")
        }
        guard panel.statusTextForQA("pi-auth") == "✗", panel.guidanceTextForQA("pi-auth") == "Sign in: /login anthropic" else {
            throw SelfCheckError.message("auth row should show missing + CLI login guidance")
        }
        guard panel.connectButtonForQA("claude")?.isEnabled == true else {
            throw SelfCheckError.message("claude connect button should be enabled when found")
        }
        guard panel.connectButtonForQA("codex")?.isEnabled == false else {
            throw SelfCheckError.message("codex connect button should be disabled when missing")
        }
        guard panel.connectButtonForQA("tmux") == nil else {
            throw SelfCheckError.message("tmux must not offer a connect tile")
        }

        // Live re-check: codex "gets installed" and the provider "gets signed
        // in" (CLI auth); one click updates both rows.
        codexLocation.path = "/qa/bin/codex"
        authLocation.path = "signed in (oauth)"
        panel.recheckForQA()
        guard panel.statusTextForQA("codex") == "✓", panel.guidanceTextForQA("codex") == "/qa/bin/codex",
              panel.connectButtonForQA("codex")?.isEnabled == true else {
            throw SelfCheckError.message("re-check should pick up newly installed codex")
        }
        guard panel.statusTextForQA("pi-auth") == "✓", panel.guidanceTextForQA("pi-auth") == "signed in (oauth)" else {
            throw SelfCheckError.message("re-check should pick up fresh provider auth")
        }

        panel.connectButtonForQA("claude")?.performClick(nil)
        guard opened == ["claude"] else {
            throw SelfCheckError.message("connect click should deliver the profile id, got \(opened)")
        }

        guard let content = panel.contentViewForQA,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw SelfCheckError.message("no content view to render")
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        let metrics = VisualSnapshot.metrics(of: rep)
        guard !metrics.isBlank else {
            throw SelfCheckError.message("onboarding panel rendered blank (\(metrics.distinctSampledColors) colors)")
        }

        // Artifact so the rendered panel is reviewable (SettingsPanel precedent).
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let artifactDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs/\(timestamp)/onboarding-panel", isDirectory: true)
        try? FileManager.default.createDirectory(at: artifactDir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: artifactDir.appendingPathComponent("panel.png"))

        let windowNumber = panel.panelWindowNumberForQA
        panel.close()
        if let windowNumber, NSApp.windows.contains(where: { $0.windowNumber == windowNumber && $0.isVisible }) {
            throw SelfCheckError.message("onboarding panel window leaked after close")
        }
    }
}
