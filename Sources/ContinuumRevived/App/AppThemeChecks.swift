import AppKit
import SwiftUI
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

@MainActor
enum AppThemeChecks {
    struct Failure: Error { let message: String }

    private static func waitForTheme(_ theme: AppTheme) throws {
        let deadline = Date().addingTimeInterval(1)
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            if AppTheme.current == theme { return }
        } while Date() < deadline
        throw Failure(message: "Deferred theme update did not complete")
    }

    static func run() throws {
        if ProcessInfo.processInfo.environment["CONTINUUM_SKIP_UI_BASELINES"] == "1" {
            print("MATRIX-NOTE: App theme surface-cache witness skipped with display-dependent checks; native theme persistence and token checks still run.")
        } else {
            try TileSurfaceResidencyChecks.checkThemeChangeGivesTheBodyBack()
        }
        let saved = AppTheme.current
        let suite = "ArrayThemeChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let observer = AppThemeController.observeSetting(defaults: defaults)
        defer {
            NotificationCenter.default.removeObserver(observer)
            defaults.removePersistentDomain(forName: suite)
            AppThemeController.apply(saved)
        }
        let model = SettingsModel(defaults: defaults, navKeymap: .default)
        let fields = model.sections.flatMap(\.groups).flatMap(\.rows).map(\.field)
        guard let field = fields.first(where: { $0.key == AppTheme.defaultsKey }) else {
            throw Failure(message: "App theme missing from the settings schema")
        }
        let tile = Tile(id: UUID(), kind: .note, title: "Neutral theme witness",
                        frame: TileFrame(x: 0, y: 0, width: 480, height: 320),
                        zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        let view = NoteTileNSView(tile: tile, noteId: UUID(), initialBody: "Array · app colours")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        var signatures = Set<String>()
        for theme in AppTheme.allCases {
            var signature = ""
            for appearance in TokenTheme.allCases {
                window.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
                model.write(.string(theme.rawValue), to: field)
                try waitForTheme(theme)
                guard defaults.string(forKey: AppTheme.defaultsKey) == theme.rawValue,
                      AppTheme.current == theme,
                      view.layer?.backgroundColor == SurfaceToken.tileBody.color.cgColor(for: appearance) else {
                    throw Failure(message: "\(theme) did not persist and repaint the existing tile in \(appearance)")
                }
                signature += (view.layer?.backgroundColor?.components ?? []).map { String(describing: $0) }.joined(separator: ",")
                if let directory = ProcessInfo.processInfo.environment["CONTINUUM_QA_CAPTURE"] {
                    let url = URL(fileURLWithPath: directory).appendingPathComponent("themes", isDirectory: true)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    let render = try UIProbe.render(.init(id: "theme.\(theme.rawValue)", size: NSSize(width: 640, height: 560), appearance: appearance == .dark ? .darkAqua : .aqua)) {
                        LabCatalog.makeManagedAgentFixtureView(includeApproval: false)
                    }
                    try render.hostRep.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("\(theme.rawValue)-\(appearance.rawValue).png"))
                }
            }
            guard signatures.insert(signature).inserted else { throw Failure(message: "Duplicate painted theme: \(theme)") }
        }
        if let directory = ProcessInfo.processInfo.environment["CONTINUUM_QA_CAPTURE"] {
            model.selectPane("appearance")
            for theme in [AppTheme.neutral, .paper] {
                model.write(.string(theme.rawValue), to: field)
                try waitForTheme(theme)
                let render = try UIProbe.render(.init(id: "settings.themes", size: NSSize(width: 1040, height: 900), appearance: theme.appearance == .dark ? .darkAqua : .aqua)) {
                    NSHostingView(rootView: SettingsRootView(model: model))
                }
                let path = URL(fileURLWithPath: directory).appendingPathComponent("settings-\(theme.appearance.rawValue).png")
                try render.hostRep.representation(using: .png, properties: [:])?.write(to: path)
            }
        }
        model.reset(field)
        try waitForTheme(.neutral)
        guard AppTheme.current == .neutral, defaults.object(forKey: AppTheme.defaultsKey) == nil else {
            throw Failure(message: "Reset did not restore the default neutral theme")
        }
        defaults.set("unknown-theme", forKey: AppTheme.defaultsKey)
        AppThemeController.adoptSavedTheme(defaults: defaults)
        guard AppTheme.current == .neutral else { throw Failure(message: "Unknown saved theme did not recover") }
        print("AppThemeChecks: ten Settings choices persist, repaint the same native tile in both appearances, paint distinct palettes and reset")
    }
}
