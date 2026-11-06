import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import SwiftUI

// Plan: .plans/110-agent-characters/README.md, slice 6 (§4.4, §4.5)
//
// Settings › Agent characters: a card for each set, importing a set from a theme
// file, the problems a bad file has, theme files found on this Mac (each named,
// stated and pictured at rest), and a preview grid of every character of the
// chosen set in every state.
//
// Opening this page parses no pack: the cards' words come from the packs'
// manifest, and everything else is read off the main thread (see `reload()`).

/// The section's state. Paths are injected so a check can point every one of
/// them at a temp root; production uses app support and the person's home.
@MainActor
@Observable
final class AgentCharacterSettingsModel {
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let importsDirectory: URL
    @ObservationIgnored let home: URL
    private(set) var imported: [AgentCharacterTheme] = []
    /// "Found on this Mac": one row per distinct theme file a plugin points at.
    private(set) var found: [AgentCharacterImports.FoundTheme] = []
    /// The last import's problems, each saying where; empty after a clean import.
    private(set) var problems: [String] = []
    private(set) var problemFile: URL?
    private(set) var message: String?
    /// Sound files the last import left out, each with why ("file: reason").
    private(set) var droppedSounds: [String] = []
    private(set) var selectedID: String
    /// The set the preview shows: the selected one, once it has loaded.
    private(set) var previewTheme: AgentCharacterTheme?
    /// Files in the themes folder that are not valid sets right now.
    private(set) var folderProblems: [(file: URL, problems: [String])] = []
    /// The pictures the cards draw, by set and appearance, as they arrive.
    private(set) var cardArt: [CardArtKey: AgentCharacterCardArt] = [:]
    @ObservationIgnored private var folderObserver: NSObjectProtocol?
    /// Only the latest pick commits; only the latest reload lands.
    @ObservationIgnored private var selectGeneration = 0
    @ObservationIgnored private var reloadGeneration = 0

    /// Checks point discovery at a fixture home; production never sets it.
    nonisolated(unsafe) static var homeOverrideForChecks: URL?

    struct SetCard: Equatable, Identifiable {
        let id: String
        let title: String
        let detail: String
    }

    struct CardArtKey: Hashable {
        let id: String
        let appearance: AgentCharacterAtlas.Appearance
    }

    /// `loadNow` false builds nothing from disk: `reload()` does, off the main
    /// thread, when the page opens.
    init(defaults: UserDefaults, importsDirectory: URL = AgentCharacterController.shared.importsDirectory,
         home: URL? = nil, loadNow: Bool = true) {
        self.defaults = defaults
        self.importsDirectory = importsDirectory
        self.home = home ?? Self.homeOverrideForChecks ?? FileManager.default.homeDirectoryForCurrentUser
        selectedID = defaults.string(forKey: AgentCharacterConfig.themeKey) ?? AgentCharacterBundled.themeID
        if loadNow {
            refresh()
            if previewTheme == nil { previewTheme = AgentCharacterBundled.theme(id: selectedID) }
        }
        // A set an agent adds or edits in the folder appears here live.
        folderObserver = NotificationCenter.default.addObserver(
            forName: AgentCharacterController.userThemesDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
    }

    /// Read the themes folder and the found files now. For the moment after an
    /// import or a removal; the page itself uses `reload()`.
    func refresh() {
        let files = AgentCharacterImports.scan(importsDirectory)
        // Reads each found file to name and state it; nothing is written until
        // the person imports one.
        apply(files: files, found: AgentCharacterImports.describe(AgentCharacterImports.discover(home: home),
                                                                  importsDirectory: importsDirectory))
    }

    /// `refresh()` off the main thread: found files can be megabytes each. The
    /// controller has already parsed the themes folder, so it is not read twice.
    func reload() {
        reloadGeneration += 1
        let generation = reloadGeneration
        let directory = importsDirectory, home = home
        let controller = AgentCharacterController.shared
        let parsed = controller.importsDirectory == directory ? controller.userThemeFiles : nil
        Task { [weak self] in
            let (files, found) = await Task.detached(priority: .utility) {
                let files = parsed ?? AgentCharacterImports.scan(directory)
                return (files, AgentCharacterImports.describe(AgentCharacterImports.discover(home: home),
                                                              importsDirectory: directory))
            }.value
            guard let self, generation == self.reloadGeneration else { return }
            self.apply(files: files, found: found)
            self.showSelected()
        }
    }

    private func apply(files: [AgentCharacterImports.UserThemeFile], found: [AgentCharacterImports.FoundTheme]) {
        let sets = AgentCharacterImports.themes(in: files).sorted { $0.title < $1.title }
        // An edited set keeps its id: its picture has to be drawn again.
        if sets != imported { cardArt = cardArt.filter { AgentCharacterBundled.isBuiltIn($0.key.id) } }
        imported = sets
        folderProblems = files.compactMap { file in
            if case let .failure(problems) = file.result { return (file.url, problems.messages) }
            return nil
        }
        self.found = found
        if !AgentCharacterBundled.isBuiltIn(selectedID), !imported.contains(where: { $0.id == selectedID }) {
            selectedID = AgentCharacterBundled.themeID
            previewTheme = nil
        }
        if let set = imported.first(where: { $0.id == selectedID }) { previewTheme = set }
    }

    /// Point the preview at the selected set, loading it off the main thread.
    private func showSelected() {
        guard previewTheme?.id != selectedID else { return }
        let id = selectedID
        Task { [weak self] in
            let theme = await AgentCharacterBundled.loadTheme(id: id)
            guard let self, id == self.selectedID, let theme else { return }
            self.previewTheme = theme
        }
    }

    /// Choose a set. The choice shows at once; a built-in set that has not been
    /// parsed yet is parsed off the main thread and then takes effect, so the
    /// app's own synchronous read of the setting finds it ready.
    func select(id: String) {
        selectedID = id
        selectGeneration += 1
        if let set = imported.first(where: { $0.id == id }) ?? AgentCharacterBundled.cachedTheme(id: id) {
            previewTheme = set
            commitSelection(id)
            return
        }
        guard AgentCharacterBundled.isBuiltIn(id) else {
            commitSelection(id)
            return
        }
        let generation = selectGeneration
        Task { [weak self] in
            let theme = await AgentCharacterBundled.loadTheme(id: id)
            guard let self, generation == self.selectGeneration else { return }
            guard let theme else { return self.select(id: AgentCharacterBundled.themeID) }
            self.previewTheme = theme
            self.commitSelection(id)
        }
    }

    private func commitSelection(_ id: String) {
        if id == AgentCharacterBundled.themeID {
            defaults.removeObject(forKey: AgentCharacterConfig.themeKey)
        } else {
            defaults.set(id, forKey: AgentCharacterConfig.themeKey)
        }
        SettingChangeEvent.post(SettingID(rawValue: AgentCharacterConfig.themeKey))
    }

    /// Build a card's picture off the main thread. A pack draws its small cut.
    func loadCardArt(id: String, appearance: AgentCharacterAtlas.Appearance) async {
        let key = CardArtKey(id: id, appearance: appearance)
        guard cardArt[key] == nil else { return }
        let set = imported.first { $0.id == id }
        let art = await Task.detached(priority: .utility) {
            (set ?? AgentCharacterBundled.cardTheme(id: id)).flatMap { AgentCharacterCardArt(theme: $0, appearance: appearance) }
        }.value
        if let art { cardArt[key] = art }
    }

    /// Settings closed: the cards' pictures go with it.
    func releaseCardArt() { cardArt = [:] }

    /// Validate and copy `url` (a file, or a folder scanned as the format scans
    /// its themes folder). A file with problems imports nothing and shows them.
    func importTheme(from url: URL) {
        problems = []
        problemFile = nil
        message = nil
        droppedSounds = []
        let results = AgentCharacterImports.importAll(from: url, into: importsDirectory)
        var added: [AgentCharacterTheme] = []
        var sounds = 0
        for result in results {
            switch result {
            case let .imported(theme, audio):
                added.append(theme)
                sounds += audio.copied.count
                droppedSounds += audio.dropped.map { "\($0.file): \($0.reason)" }
            case let .invalid(file, list):
                if problems.isEmpty { problems = list; problemFile = file }
            case let .unreadable(file, reason):
                if problems.isEmpty { problems = [reason]; problemFile = file }
            }
        }
        if results.isEmpty { message = "No theme files in that folder." }
        refresh()
        if let first = added.first {
            let withSounds = sounds == 0 ? "" : sounds == 1 ? ", 1 sound" : ", \(sounds) sounds"
            message = added.count == 1
                ? "Imported \(first.title): \(AgentCharacterCopy.count(first.characters.count))\(withSounds)."
                : "Imported \(added.count) sets\(withSounds)."
            select(id: first.id)
        }
    }

    func chooseFileToImport(window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a \(AgentCharacterCopy.one) theme file, or a folder of them."
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

    /// The picker's cards: every built-in set, then each imported set.
    var cards: [SetCard] {
        AgentCharacterBundled.summaries().map { SetCard(id: $0.id, title: $0.title, detail: AgentCharacterCopy.count($0.characters)) }
            + imported.map { SetCard(id: $0.id, title: $0.title, detail: "\(AgentCharacterCopy.count($0.characters.count)) · imported") }
    }

    /// A found row's button: Import, Update, Imported (disabled), or none for an
    /// invalid file, whose reason shows instead.
    static func foundAction(_ state: AgentCharacterImports.FoundTheme.State) -> (title: String, enabled: Bool)? {
        switch state {
        case .new: return ("Import", true)
        case .update: return ("Update", true)
        case .imported: return ("Imported", false)
        case .invalid: return nil
        }
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

/// One "Found on this Mac" row: the file's title, its characters and plugin,
/// its state, and its lead and first helpers at rest (or why it is not a set).
/// The tooltip lists every path holding these bytes.
private struct FoundThemeRow: View {
    let row: AgentCharacterImports.FoundTheme
    let index: Int
    let model: AgentCharacterSettingsModel
    let settings: SettingsModel

    var body: some View {
        let id = "ArrayFoundTheme.\(index)"
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.callout).lineLimit(1).truncationMode(.tail)
                        .settingsRenderedText(id + ".title", row.title, model: settings)
                    if !row.detail.isEmpty {
                        Text(row.detail).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .settingsRenderedText(id + ".detail", row.detail, model: settings)
                    }
                }
                Spacer()
                if let action = AgentCharacterSettingsModel.foundAction(row.state) {
                    Button(action.title) { model.importTheme(from: row.url) }
                        .disabled(!action.enabled)
                        .settingsRenderedText(id + ".action", action.title, model: settings)
                }
            }
            if case let .invalid(reason) = row.state {
                Label {
                    Text(reason).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
                .settingsRenderedText(id + ".problem", reason, model: settings)
            } else if let theme = row.theme {
                RestStrip(theme: theme, identifier: id + ".preview")
            }
        }
        .help(row.paths.map { $0.path(percentEncoded: false) }.joined(separator: "\n"))
    }
}

/// The strip in the form at exactly its own size.
private struct RestStrip: NSViewRepresentable {
    let theme: AgentCharacterTheme
    let identifier: String

    func makeNSView(context: Context) -> AgentCharacterRestStripView {
        let view = AgentCharacterRestStripView(theme: theme)
        view.setAccessibilityIdentifier(identifier)
        return view
    }
    func updateNSView(_ nsView: AgentCharacterRestStripView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AgentCharacterRestStripView, context: Context) -> CGSize? {
        nsView.naturalSize
    }
}

/// One card: the set's lead and first helpers, its name and how many characters.
private struct CharacterSetCard: View {
    let card: AgentCharacterSettingsModel.SetCard
    let selected: Bool
    let model: AgentCharacterSettingsModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var theme = AppTheme.current

    private var key: AgentCharacterSettingsModel.CardArtKey {
        .init(id: card.id, appearance: colorScheme == .dark ? .dark : .light)
    }

    var body: some View {
        let appearance: TokenTheme = colorScheme == .dark ? .dark : .light
        SettingsPreviewCard(title: card.title, selected: selected, appearance: appearance,
                            background: Color(nsColor: SurfaceToken.tileBody.color(for: theme).nsColor(for: appearance)),
                            outlined: true) {
            CharacterCardArt(art: model.cardArt[key], identifier: "ArrayAgentCharacterCardArt.\(card.id)")
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } footer: {
            Text(card.detail).font(.callout).opacity(0.65).lineLimit(1)
        }
        .task(id: key) { await model.loadCardArt(id: key.id, appearance: key.appearance) }
        .onReceive(NotificationCenter.default.publisher(for: AppThemeController.didChangeNotification)) { _ in
            theme = AppTheme.current
        }
    }
}

/// The Agent characters pane's sets: the cards, what can be done with them, the
/// files found on this Mac, and the chosen set in every state.
struct AgentCharacterSections: View {
    let model: AgentCharacterSettingsModel
    let settings: SettingsModel
    let field: SettingsField

    var body: some View {
        Section(AgentCharacterCopy.set) {
            SettingsPreviewCardGrid {
                ForEach(model.cards) { card in
                    Button { model.select(id: card.id) } label: {
                        CharacterSetCard(card: card, selected: model.selectedID == card.id, model: model)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(card.title), \(card.detail)")
                    .accessibilityAddTraits(model.selectedID == card.id ? .isSelected : [])
                    .accessibilityIdentifier("ArrayAgentCharacterSet.\(card.id)")
                    .settingsFrame("ArrayAgentCharacterSet.\(card.id)")
                }
            }
            .settingsAnchor(SettingsRegistry.anchor(for: field) ?? field.label, model: settings)
            .task { model.reload() }
            setDetail
            InfoRow(text: "Each agent gets a \(AgentCharacterCopy.one) from its id. To choose one for an agent, use \(AgentCharacterCopy.menu) in its tile's ⋯ menu.")
            if let message = model.message {
                InfoRow(text: message)
            }
            if !model.droppedSounds.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Some of the set's sounds were left out.", systemImage: "speaker.slash")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ForEach(Array(model.droppedSounds.prefix(8).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("ArrayAgentCharacterDroppedSounds")
            }
            if !model.problems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("This file is not a \(AgentCharacterCopy.one) theme, so nothing was imported.", systemImage: "exclamationmark.triangle.fill")
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
            HStack {
                InfoRow(text: "Import any theme file in the \(AgentCharacterCopy.one) format; Array keeps its own copy and reads it only.")
                Spacer()
                Button("Import…") { model.chooseFileToImport(window: settings.hostWindow) }
            }
            HStack {
                InfoRow(text: "Agents can make and edit sets in the themes folder; changes show at once.")
                Spacer()
                Button("Show Folder") {
                    try? FileManager.default.createDirectory(at: model.importsDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([model.importsDirectory])
                }
            }
            ForEach(Array(model.folderProblems.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 2) {
                    Label("\(entry.file.lastPathComponent) is not a valid set yet", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    ForEach(Array(entry.problems.enumerated()), id: \.offset) { _, problem in
                        Text(problem).font(.callout.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        if !model.found.isEmpty {
            Section("Found on this Mac") {
                ForEach(Array(model.found.enumerated()), id: \.element.hash) { index, row in
                    FoundThemeRow(row: row, index: index, model: model, settings: settings)
                }
            }
        }
        if let theme = model.previewTheme {
            // The grid belongs to the chosen set (what agents draw), and says so;
            // a found file shows its own characters in its row.
            Section {
                PreviewGrid(theme: theme)
                    .id(theme.id)
            } header: {
                Text("\(theme.title) in every state")
                    .settingsRenderedText("ArrayAgentCharacterGridTitle", "\(theme.title) in every state", model: settings)
            }
        }
    }

    /// What is known about the selected set, and what can be done to it.
    @ViewBuilder private var setDetail: some View {
        if model.selectedID == AgentCharacterBundled.themeID {
            HStack(spacing: 6) {
                InfoRow(text: "Ducks: pixel art © 2026 Ali Alsalkhadi, MIT License.")
                if let license = AgentCharacterBundled.licenseURL {
                    Button("License") { NSWorkspace.shared.open(license) }
                        .buttonStyle(.link)
                }
            }
        } else if let set = model.imported.first(where: { $0.id == model.selectedID }) {
            HStack {
                InfoRow(text: "\(set.title) · \(AgentCharacterCopy.count(set.characters.count))")
                Spacer()
                Button("Remove") { model.remove(id: set.id) }
            }
        } else if let card = model.cards.first(where: { $0.id == model.selectedID }) {
            InfoRow(text: "\(card.title) · \(card.detail) · built in")
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
    /// Each character's picture, built off the main thread: the grid holds a
    /// whole set, every frame, up to 16 times over.
    private var atlases: [AgentCharacterAtlas.Appearance: [AgentCharacterSpriteAtlas]] = [:]
    private var building: AgentCharacterAtlas.Appearance?
    private lazy var motion = CharacterPreviewMotion(view: self, sprites: { [unowned self] in sprites }, changed: { [unowned self] in apply() })

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
        motion.update()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        motion.windowChanged()
        apply()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    /// Show every cell; out of sight, everything holds still.
    func apply(now: Date = Date()) {
        let appearance = AgentCharacterController.appearance(of: self)
        guard let pictures = atlases[appearance] else { return build(appearance) }
        let moving = window != nil && AgentCharacterController.shared.allowsMotion
        for (i, sprite) in sprites.enumerated() {
            let row = i / Self.columns.count, column = i % Self.columns.count
            guard row < pictures.count else { continue }
            let plan = Self.columns[column].plan
            sprite.show(moving ? plan : .still(plan.still), sprite: pictures[row], phase: Double(row) / 8, now: now)
        }
        motion.update()
    }

    private func build(_ appearance: AgentCharacterAtlas.Appearance) {
        guard building != appearance else { return }
        building = appearance
        let theme = theme
        Task { [weak self] in
            let pictures = await Task.detached(priority: .userInitiated) {
                theme.characters.indices.compactMap { AgentCharacterSpriteAtlas(theme: theme, character: $0, appearance: appearance) }
            }.value
            guard let self else { return }
            self.atlases[appearance] = pictures
            self.building = nil
            self.apply()
        }
    }
}

/// A found set's lead (when it has lead art) and first three helpers, held at
/// rest, at the preview grid's size and bottom-aligned. Atlases are built for
/// this theme directly: the controller caches by id, and a found file with an
/// imported set's id but other art must draw its own.
final class AgentCharacterRestStripView: NSView {
    static let helpers = 3
    private(set) var sprites: [CharacterSpriteLayer] = []
    /// Its size whatever frame the form gives it.
    let naturalSize: NSSize
    /// (theme, character) per sprite, left to right.
    private var cells: [(theme: AgentCharacterTheme, character: Int, size: NSSize)] = []
    private var generation = 0

    init(theme: AgentCharacterTheme) {
        let points = AgentCharacterPreviewGridView.pointsPerPixel
        func size(_ set: AgentCharacterTheme) -> NSSize {
            NSSize(width: CGFloat(set.frameWidth / set.scale) * points, height: CGFloat(set.frameHeight / set.scale) * points)
        }
        if let lead = theme.leadSet { cells.append((lead, 0, size(lead))) }
        for character in 0..<min(Self.helpers, theme.characters.count) { cells.append((theme, character, size(theme))) }
        let width = cells.map(\.size.width).reduce(0, +) + CGFloat(max(cells.count - 1, 0)) * AgentCharacterPreviewGridView.gap
        naturalSize = NSSize(width: width, height: cells.map(\.size.height).max() ?? 0)
        super.init(frame: NSRect(origin: .zero, size: naturalSize))
        wantsLayer = true
        for _ in cells {
            let sprite = CharacterSpriteLayer()
            sprite.hostIsFlipped = isFlipped
            layer?.addSublayer(sprite)
            sprites.append(sprite)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { naturalSize }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var x: CGFloat = 0
        for (sprite, cell) in zip(sprites, cells) {
            let rect = NSRect(x: x, y: bounds.height - cell.size.height, width: cell.size.width, height: cell.size.height)
            if sprite.frame != rect { sprite.frame = rect }
            x += cell.size.width + AgentCharacterPreviewGridView.gap
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

    /// Every cell at rest, in this view's appearance, each picture built off the
    /// main thread: a found set can be megabytes of frames.
    func apply() {
        let appearance = AgentCharacterController.appearance(of: self)
        let cells = cells.map { (theme: $0.theme, character: $0.character) }
        generation += 1
        let generation = generation
        Task { [weak self] in
            let pictures = await Task.detached(priority: .utility) {
                cells.map { AgentCharacterSpriteAtlas(theme: $0.theme, character: $0.character, appearance: appearance) }
            }.value
            guard let self, generation == self.generation else { return }
            for (sprite, picture) in zip(self.sprites, pictures) {
                if let picture { sprite.show(.still(.clip(.idle)), sprite: picture, phase: 0) }
            }
        }
    }
}
