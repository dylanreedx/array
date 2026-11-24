import AppKit
import ContinuumRevivedCore

/// Offscreen stills of the Agents, Editor, Terminal and Browser panes, light and
/// dark, Managed on and off. Runs from `--settings-panel-check` when
/// `CONTINUUM_SETTINGS_RENDER_DIR` names a directory; never takes the screen.
@MainActor
enum SettingsPaneStills {
    static func renderIfRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["CONTINUUM_SETTINGS_RENDER_DIR"], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (look, name) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            for managed in [true, false] {
                let suite = "array.settings-stills.\(UUID().uuidString)"
                guard let defaults = QAIsolatedDefaults(isolatedSuiteName: suite) else { continue }
                defer { defaults.removePersistentDomain(forName: suite) }
                defaults.set(managed, forKey: AgentManagedModeConfig.enabledKey)
                // Show the rows that appear only under a switch.
                defaults.set(true, forKey: PersonalRulesConfig.enabledKey)
                defaults.set(7.0 as Double, forKey: AgentSpawnLimitConfig.maximumActiveChildrenKey)
                defaults.set("7", forKey: AgentAutoSettleConfig.afterDaysKey)
                let model = SettingsModel(sections: SettingsSchema.sections(), defaults: defaults,
                                          navKeymap: .resolve(defaults: defaults, warn: { _ in }))
                let fixture = SettingsFixtureWindow(model: model, size: NSSize(width: 1_000, height: 2_300),
                                                    appearance: NSAppearance(named: name))
                defer { fixture.tearDown() }
                fixture.show(paneID: "agents")
                for pane in ["agents", "editor", "terminal", "browser"] {
                    if pane != "agents" && !managed { continue }
                    fixture.select(pane)
                    fixture.settle(0.3)
                    guard let rep = fixture.snapshot(), let png = rep.representation(using: .png, properties: [:]) else {
                        throw SettingsStillsError.noImage(pane)
                    }
                    let suffix = pane == "agents" ? (managed ? "-managed-on" : "-managed-off") : ""
                    try png.write(to: directory.appendingPathComponent("\(pane)\(suffix)-\(look).png"))
                }
                if managed {
                    // Terminal with its switches off, to see the dependents hidden.
                    defaults.set(false, forKey: TmuxPersistenceConfig.enabledKey)
                    defaults.set(false, forKey: SessionResumeConfig.scrollbackEnabledKey)
                    defaults.set(0.0 as Double, forKey: TerminalDisplayConfig.fontSizeKey)
                    fixture.select("terminal")
                    fixture.settle(0.3)
                    if let rep = fixture.snapshot(), let png = rep.representation(using: .png, properties: [:]) {
                        try png.write(to: directory.appendingPathComponent("terminal-off-\(look).png"))
                    }
                }
            }
        }
    }
}

private enum SettingsStillsError: Error { case noImage(String) }
