import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import SwiftUI

// Plan: .plans/110-agent-characters/README.md, slice 6 (§4.4, §4.5)
//
// Settings › Appearance › Agent characters: which set, importing a set from a
// theme file, the problems a bad file has, theme files found on this Mac, and a
// preview grid of every character in every state.

/// The section's state. Paths are injected so a check can point every one of
/// them at a temp root; production uses app support and the person's home.
@MainActor
@Observable
final class AgentCharacterSettingsModel {
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let importsDirectory: URL
    @ObservationIgnored let home: URL
    private(set) var imported: [AgentCharacterTheme] = []
    private(set) var found: [URL] = []
    /// The last import's problems, each saying where; empty after a clean import.
    private(set) var problems: [String] = []
    private(set) var problemFile: URL?
    private(set) var message: String?
    private(set) var selectedID: String

    /// Checks point discovery at a fixture home; production never sets it.
    nonisolated(unsafe) static var homeOverrideForChecks: URL?

    init(defaults: UserDefaults, importsDirectory: URL = AgentCharacterController.shared.importsDirectory,
         home: URL? = nil) {
        self.defaults = defaults
        self.importsDirectory = importsDirectory
        self.home = home ?? Self.homeOverrideForChecks ?? FileManager.default.homeDirectoryForCurrentUser
        selectedID = defaults.string(forKey: AgentCharacterConfig.themeKey) ?? AgentCharacterBundled.themeID
        refresh()
    }

    func refresh() {
        imported = AgentCharacterImports.list(in: importsDirectory)
        // Lists file locations only; no theme is read until the person imports it.
        found = AgentCharacterImports.discover(home: home)
        if selectedID != AgentCharacterBundled.themeID, !imported.contains(where: { $0.id == selectedID }) {
            selectedID = AgentCharacterBundled.themeID
        }
    }

    var builtIn: AgentCharacterTheme? { AgentCharacterBundled.theme() }

    /// The set the preview shows: the selected one.
    var previewTheme: AgentCharacterTheme? {
        imported.first { $0.id == selectedID } ?? builtIn
    }

    func select(id: String) {
        selectedID = id
        if id == AgentCharacterBundled.themeID {
            defaults.removeObject(forKey: AgentCharacterConfig.themeKey)
        } else {
            defaults.set(id, forKey: AgentCharacterConfig.themeKey)
        }
        SettingChangeEvent.post(SettingID(rawValue: AgentCharacterConfig.themeKey))
    }

    /// Validate and copy `url` (a file, or a folder scanned as the format scans
    /// its themes folder). A file with problems imports nothing and shows them.
    func importTheme(from url: URL) {
        problems = []
        problemFile = nil
        message = nil
        let results = AgentCharacterImports.importAll(from: url, into: importsDirectory)
        var added: [AgentCharacterTheme] = []
        for result in results {
            switch result {
            case let .imported(theme): added.append(theme)
            case let .invalid(file, list):
                if problems.isEmpty { problems = list; problemFile = file }
            case let .unreadable(file, reason):
                if problems.isEmpty { problems = [reason]; problemFile = file }
            }
        }
        if results.isEmpty { message = "No theme files in that folder." }
        refresh()
        if let first = added.first {
            message = added.count == 1
                ? "Imported \(first.title): \(first.characters.count) characters."
                : "Imported \(added.count) sets."
            select(id: first.id)
        }
    }

    func chooseFileToImport(window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a character theme file, or a folder of them."
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.importTheme(from: url) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    func remove(id: String) {
        AgentCharacterImports.remove(id: id, from: importsDirectory)
        if selectedID == id { select(id: AgentCharacterBundled.themeID) }
        refresh()
    }

    /// The set picker's rows: the built-in set, each imported set, then Import….
    var choiceItems: [ChoiceItem] {
        var items = [ChoiceItem(id: AgentCharacterBundled.themeID, title: "Ducks (built in)",
                                detail: "\(builtIn?.characters.count ?? 0) characters")]
        items += imported.map { ChoiceItem(id: $0.id, title: $0.title, detail: "\($0.characters.count) characters") }
        items.append(ChoiceItem(id: Self.importItemID, title: "Import…", icon: nil))
        return items
    }

    static let importItemID = "array.agentCharacters.import"

    /// What a found file is called in the list. A plugin's theme file has the
    /// format's fixed name, which is another product's; the row names where it
    /// came from instead, and the tooltip carries the path.
    static func foundLabel(_ url: URL) -> String {
        url.lastPathComponent == AgentCharacterImports.folderThemeName
            ? "Theme from an installed Claude Code plugin"
            : url.lastPathComponent
    }
}

/// The set picker: Array's `ChoiceButton`, hosted in the Settings form.
private struct CharacterSetChoice: NSViewRepresentable {
    let model: AgentCharacterSettingsModel

    func makeNSView(context: Context) -> ChoiceButton {
        let button = ChoiceButton(title: "Ducks (built in)")
        button.setAccessibilityLabel("Character set")
        return button
    }

    func updateNSView(_ button: ChoiceButton, context: Context) {
        button.items = model.choiceItems
        button.selectedID = model.selectedID
        button.onSelection = { [model, weak button] item in
            if item.id == AgentCharacterSettingsModel.importItemID {
                model.chooseFileToImport(window: button?.window)
                button?.selectedID = model.selectedID
            } else {
                model.select(id: item.id)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChoiceButton, context: Context) -> CGSize? {
        let fitting = nsView.fittingSize
        return CGSize(width: max(fitting.width, 200), height: max(fitting.height, 24))
    }
}

/// The grid in the form at exactly its own size, top-aligned.
private struct PreviewGrid: NSViewRepresentable {
    let theme: AgentCharacterTheme

    func makeNSView(context: Context) -> AgentCharacterPreviewGridView { AgentCharacterPreviewGridView(theme: theme) }
    func updateNSView(_ nsView: AgentCharacterPreviewGridView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AgentCharacterPreviewGridView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.frame.width, height: AgentCharacterPreviewGridView.height(for: theme))
    }
}

/// The custom rows of the section, below the switch and the Motion choice.
struct AgentCharacterSettingsRows: View {
    @State var model: AgentCharacterSettingsModel

    var body: some View {
        let _ = model.selectedID
        LabeledContent {
            CharacterSetChoice(model: model)
        } label: {
            SettingsRowLabel(title: "Character set",
                             help: "Import any theme file in the character format; Array keeps its own copy and reads it only.")
        }
        if model.selectedID == AgentCharacterBundled.themeID {
            HStack(spacing: 6) {
                InfoRow(text: "Ducks: pixel art © 2026 Ali Alsalkhadi, MIT License.")
                if let license = AgentCharacterBundled.licenseURL {
                    Button("License") { NSWorkspace.shared.open(license) }
                        .buttonStyle(.link)
                }
            }
        } else if let theme = model.previewTheme {
            HStack {
                InfoRow(text: "\(theme.title) · \(theme.characters.count) characters")
                Spacer()
                Button("Remove") { model.remove(id: theme.id) }
            }
        }
        if let message = model.message {
            InfoRow(text: message)
        }
        if !model.problems.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("This file is not a character theme, so nothing was imported.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                ForEach(Array(model.problems.enumerated()), id: \.offset) { _, problem in
                    Text(problem).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                if let file = model.problemFile {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                        .buttonStyle(.link)
                }
            }
            .accessibilityIdentifier("ArrayAgentCharacterProblems")
        }
        if !model.found.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Found on this Mac").font(.callout.weight(.medium))
                ForEach(model.found, id: \.self) { url in
                    HStack {
                        Text(AgentCharacterSettingsModel.foundLabel(url)).font(.callout).lineLimit(1).truncationMode(.middle)
                            .help(url.path(percentEncoded: false))
                        Spacer()
                        Button("Import") { model.importTheme(from: url) }
                    }
                }
            }
        }
        if let theme = model.previewTheme {
            PreviewGrid(theme: theme)
                .id(theme.id)
        }
    }
}

/// Every character (rows) in every state (columns), animating; still under
/// Reduce Motion or Settings' "Never". One sprite layer per cell over the shared
/// atlases, like the sidebar's.
final class AgentCharacterPreviewGridView: NSView {
    static let columns: [(title: String, plan: AgentCharacterPlan)] = [
        ("Search", .init(segments: [.loop(.dabble, slow: false)], still: .loop(.dabble), revisitAt: nil)),
        ("Read", .init(segments: [.loop(.read, slow: false)], still: .loop(.read), revisitAt: nil)),
        ("Edit", .init(segments: [.loop(.type, slow: false)], still: .loop(.type), revisitAt: nil)),
        ("Run", .init(segments: [.loop(.run, slow: false)], still: .loop(.run), revisitAt: nil)),
        ("Think", .init(segments: [.loop(.think, slow: false)], still: .loop(.think), revisitAt: nil)),
        ("Waiting", .init(segments: [.repeating(.wave)], still: .clip(.wave), revisitAt: nil)),
        ("Asleep", .init(segments: [.repeating(.asleep)], still: .clip(.asleep), revisitAt: nil)),
        ("Done", .still(.done)),
        ("Failed", .still(.failed)),
    ]
    static let pointsPerPixel: CGFloat = 2
    static let gap: CGFloat = 8
    static let header: CGFloat = 18

    static func height(for theme: AgentCharacterTheme) -> CGFloat {
        header + CGFloat(theme.characters.count) * (CGFloat(theme.frameHeight / theme.scale) * pointsPerPixel + gap)
    }

    private(set) var sprites: [CharacterSpriteLayer] = []
    private let theme: AgentCharacterTheme
    private var labels: [NSTextField] = []

    init(theme: AgentCharacterTheme) {
        self.theme = theme
        let cellW = CGFloat(theme.frameWidth / theme.scale) * Self.pointsPerPixel
        super.init(frame: NSRect(x: 0, y: 0, width: CGFloat(Self.columns.count) * (cellW + Self.gap),
                                 height: Self.height(for: theme)))
        wantsLayer = true
        for column in Self.columns {
            let label = NSTextField(labelWithString: column.title)
            label.font = .systemFont(ofSize: 10)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            addSubview(label)
            labels.append(label)
        }
        for _ in theme.characters {
            for _ in Self.columns {
                let sprite = CharacterSpriteLayer()
                sprite.hostIsFlipped = isFlipped
                layer?.addSublayer(sprite)
                sprites.append(sprite)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { frame.size }

    override func layout() {
        super.layout()
        let cellW = CGFloat(theme.frameWidth / theme.scale) * Self.pointsPerPixel
        let cellH = CGFloat(theme.frameHeight / theme.scale) * Self.pointsPerPixel
        for (n, label) in labels.enumerated() {
            label.frame = NSRect(x: CGFloat(n) * (cellW + Self.gap) - 4, y: 0, width: cellW + 8, height: 14)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, sprite) in sprites.enumerated() {
            let row = i / Self.columns.count, column = i % Self.columns.count
            let rect = NSRect(x: CGFloat(column) * (cellW + Self.gap), y: Self.header + CGFloat(row) * (cellH + Self.gap),
                              width: cellW, height: cellH)
            if sprite.frame != rect { sprite.frame = rect }
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    /// Show every cell; out of a window, everything holds still.
    func apply(now: Date = Date()) {
        let controller = AgentCharacterController.shared
        let appearance = AgentCharacterController.appearance(of: self)
        let moving = window != nil && controller.motion == .working && !controller.reduceMotion()
        for (i, sprite) in sprites.enumerated() {
            let row = i / Self.columns.count, column = i % Self.columns.count
            guard let atlas = controller.atlas(theme: theme, character: row, appearance: appearance) else { continue }
            let plan = Self.columns[column].plan
            sprite.show(moving ? plan : .still(plan.still), sprite: atlas, phase: Double(row) / 8, now: now)
        }
    }
}
