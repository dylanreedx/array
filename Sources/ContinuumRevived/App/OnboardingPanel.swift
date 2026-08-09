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
    /// One environment probe: how to find a tool and what to tell the user
    /// when it's missing. Injected so the self-check is deterministic.
    struct Probe {
        let id: String
        let title: String
        /// One-line role shown under the title.
        let detail: String
        /// Copy-paste install command shown when the tool is missing.
        let installGuidance: String
        /// Launch profile that opens a real tile so the CLI's own login/auth
        /// flow runs inside Array; nil for non-tile tools (tmux, git).
        let connectProfileId: String?
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

    /// The real environment: claude/codex through the augmented PATH
    /// (ToolEnvironment), tmux through its locator, git through the CLT
    /// presence check that does NOT trigger the Xcode CLT install dialog.
    static func liveProbes(
        environment: @escaping () -> [String: String],
        defaults: UserDefaults = .standard
    ) -> [Probe] {
        func locateOnPath(_ name: String) -> (() -> String?) {
            {
                ToolDetector.live.locate(name, in: ToolDetector.splitPath(environment()["PATH"] ?? ""))
            }
        }
        return [
            Probe(
                id: "claude",
                title: "Claude Code",
                detail: "Agent CLI — at least one agent CLI is recommended.",
                installGuidance: "curl -fsSL https://claude.ai/install.sh | bash",
                connectProfileId: "claude",
                locate: locateOnPath("claude")
            ),
            Probe(
                id: "codex",
                title: "Codex",
                detail: "Agent CLI — at least one agent CLI is recommended.",
                installGuidance: "npm install -g @openai/codex",
                connectProfileId: "codex",
                locate: locateOnPath("codex")
            ),
            Probe(
                id: "tmux",
                title: "tmux",
                detail: "Keeps terminal sessions alive across app restarts (optional).",
                installGuidance: "brew install tmux",
                connectProfileId: nil,
                locate: { TmuxLocator.resolve(defaults: defaults) }
            ),
            Probe(
                id: "git",
                title: "Git (Command Line Tools)",
                detail: "File tree status, diff review, and agent worktrees.",
                installGuidance: "xcode-select --install",
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
                guidance.stringValue = "Install: \(probe.installGuidance)"
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
        let probes = [
            Probe(id: "claude", title: "Claude Code", detail: "agent", installGuidance: "install-claude",
                  connectProfileId: "claude", locate: { claudeLocation.path }),
            Probe(id: "codex", title: "Codex", detail: "agent", installGuidance: "install-codex",
                  connectProfileId: "codex", locate: { codexLocation.path }),
            Probe(id: "tmux", title: "tmux", detail: "persistence", installGuidance: "brew install tmux",
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
        guard panel.connectButtonForQA("claude")?.isEnabled == true else {
            throw SelfCheckError.message("claude connect button should be enabled when found")
        }
        guard panel.connectButtonForQA("codex")?.isEnabled == false else {
            throw SelfCheckError.message("codex connect button should be disabled when missing")
        }
        guard panel.connectButtonForQA("tmux") == nil else {
            throw SelfCheckError.message("tmux must not offer a connect tile")
        }

        // Live re-check: codex "gets installed", one click updates the row.
        codexLocation.path = "/qa/bin/codex"
        panel.recheckForQA()
        guard panel.statusTextForQA("codex") == "✓", panel.guidanceTextForQA("codex") == "/qa/bin/codex",
              panel.connectButtonForQA("codex")?.isEnabled == true else {
            throw SelfCheckError.message("re-check should pick up newly installed codex")
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
