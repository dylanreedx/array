import AppKit
import ContinuumRevivedCore
import Foundation
import Observation

/// Everything the Settings modal shows and every write it makes.
///
/// `binding(for:)` is the ONLY path from a rendered row into
/// `SettingsField.setValue`, so the witnesses drive exactly what a click drives.
/// Pane, search, scroll and highlight state live here too, so a check can steer
/// the modal the way the sidebar and the search field do.
@MainActor
@Observable
final class SettingsModel {
    /// Where the last-open pane is remembered, in the model's own defaults.
    static let lastPaneKey = "continuum.settings.lastPane"

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let sections: [SettingsSection]
    @ObservationIgnored let soundLibrary: AgentSoundLibrary
    /// The iPhone pane appears only when the companion is available.
    let isCompanionEnabled: Bool

    // MARK: Hooks the app supplies

    @ObservationIgnored var onKeymapChanged: ((NavKeymap) -> Void)?
    @ObservationIgnored var onShortcutsChanged: (() -> Void)?
    /// `.action` rows, by id. A row whose id has no handler renders disabled.
    @ObservationIgnored var actionHandlers: [String: () -> Void] = [:]
    /// Runs the CLI's OWN login flow (a terminal tile). Never a key field.
    @ObservationIgnored var onSignIn: ((AgentHarness) -> Void)?
    /// `.custom` rows that embed an AppKit view, by id.
    @ObservationIgnored var customViews: [String: () -> NSView] = [:]
    /// The Appearance pane's canvas background rows.
    @ObservationIgnored var canvasBackground: CanvasBackgroundEditor?
    /// Presents the import panel for custom sounds; nil runs it app-modally.
    @ObservationIgnored weak var hostWindow: NSWindow?

    // MARK: Observed state

    var selectedPaneID: String {
        didSet {
            guard selectedPaneID != oldValue else { return }
            defaults.set(selectedPaneID, forKey: Self.lastPaneKey)
        }
    }
    var searchQuery = "" {
        didSet { if searchQuery != oldValue { recomputeSearch() } }
    }
    private(set) var searchResults: [SettingsSearch.Result] = []
    var selectedResultIndex: Int?
    /// The row anchor briefly highlighted after a search navigation.
    private(set) var highlightedEntryID: String?
    /// A pending "scroll this anchor into view"; the token makes repeats distinct.
    private(set) var scrollRequest: ScrollRequest?
    /// Bumped on every write so rows re-read their value.
    private(set) var revision = 0
    private(set) var catalogRevision = 0
    var navKeymap: NavKeymap
    private(set) var recordingEntryID: String?
    private(set) var captureMessages: [String: String] = [:]
    /// Bumped whenever the search field should take focus (⌘F, open).
    private(set) var searchFocusToken = 0

    struct ScrollRequest: Equatable {
        let anchor: String
        let token: Int
    }

    // MARK: Census (not observed: rows write these while rendering)

    /// Rendered rows by the pane that drew them. A pane's rows can outlive a pane
    /// switch by a few run-loop turns (SwiftUI delivers `onDisappear` late), so the
    /// census is always read for one pane.
    @ObservationIgnored private var renderedAnchorsByPane: [String: [String: Int]] = [:]
    /// The rows the selected pane has on screen.
    var renderedAnchors: [String: Int] { renderedAnchorsByPane[selectedPaneID] ?? [:] }
    @ObservationIgnored private(set) var anchorFrames: [String: CGRect] = [:]
    @ObservationIgnored var viewportSize: CGSize = .zero
    @ObservationIgnored private var scrollToken = 0
    @ObservationIgnored private var highlightGeneration = 0
    /// Commits for text and number rows being edited, so closing Settings mid-edit
    /// (Esc, ⌘W, the scrim) keeps what was typed instead of dropping it.
    @ObservationIgnored var pendingEdits: [String: () -> Void] = [:]
    @ObservationIgnored private var catalogObserver: NSObjectProtocol?
    @ObservationIgnored private var libraryObserver: NSObjectProtocol?

    init(
        sections: [SettingsSection] = SettingsSchema.sections(),
        defaults: UserDefaults,
        navKeymap: NavKeymap,
        isCompanionEnabled: Bool,
        soundLibrary: AgentSoundLibrary = .shared,
        initialPaneID: String? = nil
    ) {
        self.sections = sections
        self.defaults = defaults
        self.navKeymap = navKeymap
        self.isCompanionEnabled = isCompanionEnabled
        self.soundLibrary = soundLibrary
        let visible = sections.filter { $0.id != "companion" || isCompanionEnabled }.map(\.id)
        let remembered = defaults.string(forKey: Self.lastPaneKey)
        self.selectedPaneID = [initialPaneID, remembered].compactMap { $0 }.first(where: visible.contains)
            ?? visible.first ?? "general"
        catalogObserver = NotificationCenter.default.addObserver(
            forName: AgentModelCatalog.didRefreshNotification, object: AgentModelCatalog.shared, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.catalogRevision += 1 }
        }
        libraryObserver = NotificationCenter.default.addObserver(
            forName: .agentSoundLibraryDidChange, object: soundLibrary, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.revision += 1 }
        }
    }

    isolated deinit {
        if let catalogObserver { NotificationCenter.default.removeObserver(catalogObserver) }
        if let libraryObserver { NotificationCenter.default.removeObserver(libraryObserver) }
    }

    // MARK: Panes

    var visiblePanes: [SettingsSection] {
        sections.filter { $0.id != "companion" || isCompanionEnabled }
    }

    var selectedPane: SettingsSection? {
        visiblePanes.first { $0.id == selectedPaneID }
    }

    func selectPane(_ id: String) {
        guard visiblePanes.contains(where: { $0.id == id }) else { return }
        selectedPaneID = id
    }

    // MARK: The write path

    func binding(for field: SettingsField) -> SettingsBinding {
        SettingsBinding(model: self, field: field)
    }

    func value(of field: SettingsField) -> SettingsValue? {
        _ = revision
        return field.currentValue(in: defaults)
    }

    /// The single write into `SettingsField.setValue`.
    func write(_ value: SettingsValue, to field: SettingsField) {
        if field.key == AgentModelConfig.modelKey {
            // Validated against the harness snapshot the picker is SHOWING, never the
            // field's options: those were frozen when the schema was built, so after
            // a harness switch `setValue` would store the Claude seed instead.
            guard case let .string(id) = value, modelPickerItems().contains(where: { $0.id == id && $0.offered }) else { return }
            defaults.set(id, forKey: AgentModelConfig.modelKey)
        } else {
            field.setValue(value, in: defaults)
        }
        didWrite(field)
    }

    func reset(_ field: SettingsField) {
        field.reset(in: defaults)
        didWrite(field)
    }

    func isModified(_ field: SettingsField) -> Bool {
        _ = revision
        guard let key = field.key else { return false }
        return defaults.object(forKey: key) != nil
    }

    private func didWrite(_ field: SettingsField) {
        revision += 1
        if let key = field.key { post(key) }
        if !searchQuery.isEmpty { recomputeSearch() }
    }

    /// Notify only consumers registered for this stable setting id, plus the two
    /// listeners that predate setting ids.
    private func post(_ key: String) {
        SettingChangeEvent.post(SettingID(rawValue: key))
        if key.hasPrefix("continuum.floatingToolbar.") {
            NotificationCenter.default.post(name: FloatingToolbarHostView.didChangeSettings, object: nil)
        }
        if key.hasPrefix("continuum.keymap.") {
            let resolved = NavKeymap.resolve(defaults: defaults, warn: { _ in })
            navKeymap = resolved
            onKeymapChanged?(resolved)
        }
    }

    // MARK: Actions

    func canPerform(action id: String) -> Bool {
        id == "resetToolbarPosition" || actionHandlers[id] != nil
    }

    func perform(action id: String) {
        if id == "resetToolbarPosition" {
            defaults.removeObject(forKey: FloatingToolbarConfig.positionEdgeKey)
            NotificationCenter.default.post(name: FloatingToolbarHostView.didChangeSettings, object: nil)
            revision += 1
            return
        }
        actionHandlers[id]?()
    }

    // MARK: Model picker

    struct ModelItem: Equatable, Identifiable {
        let id: String
        let title: String
        let provider: String
        /// False for the saved model when the selected CLI does not offer it.
        let offered: Bool
    }

    var currentHarness: AgentHarness {
        _ = revision
        return AgentHarnessConfig.resolved(defaults: defaults)
    }

    var storedModel: String {
        _ = revision
        return defaults.string(forKey: AgentModelConfig.modelKey) ?? AgentModelConfig.defaultModel
    }

    /// Ids verbatim from the live catalogue of the selected CLI, then the saved
    /// model as an explicit invalid item when that CLI does not offer it. Picking
    /// a CLI never rewrites the saved model.
    func modelPickerItems() -> [ModelItem] {
        _ = catalogRevision
        let snapshot = AgentModelCatalog.shared.snapshot(for: currentHarness)
        var items = snapshot.models.map { id in
            ModelItem(id: id, title: snapshot.displayNames[id] ?? id,
                      provider: id.split(separator: "/").first.map(String.init) ?? "", offered: true)
        }
        let current = storedModel
        if !snapshot.models.contains(current) {
            items.append(ModelItem(id: current, title: current, provider: "", offered: false))
        }
        return items
    }

    // MARK: Agent CLIs

    func readiness(of harness: AgentHarness) -> HarnessReadiness {
        _ = catalogRevision
        return AgentModelCatalog.shared.snapshot(for: harness).readiness
    }

    // MARK: Sounds

    var soundsEnabled: Bool {
        get { _ = revision; return defaults.bool(forKey: AgentSoundConfig.masterEnabledKey) }
        set { defaults.set(newValue, forKey: AgentSoundConfig.masterEnabledKey); revision += 1 }
    }

    var soundVolume: Double {
        get { _ = revision; return AgentSoundConfig.resolvedVolume(defaults: defaults) }
        set { defaults.set(min(1, max(0, newValue)), forKey: AgentSoundConfig.volumeKey); revision += 1 }
    }

    func soundRule(_ kind: AgentSignalKind) -> AgentSoundRule {
        _ = revision
        return AgentSoundConfig.resolvedRules(defaults: defaults).rules[kind]
            ?? AgentSoundRule(sound: AgentSoundReference(rawValue: ""))
    }

    func setSoundEnabled(_ enabled: Bool, for kind: AgentSignalKind) {
        defaults.set(enabled, forKey: AgentSoundConfig.enabledKey(for: kind))
        revision += 1
    }

    func setSound(_ reference: AgentSoundReference, for kind: AgentSignalKind) {
        defaults.set(reference.rawValue, forKey: AgentSoundConfig.soundKey(for: kind))
        revision += 1
    }

    var soundEntries: [AgentSoundManifestEntry] { _ = revision; return soundLibrary.allEntries }
    var importedSounds: [AgentSoundManifestEntry] { _ = revision; return soundLibrary.importedEntries }

    func playSample(_ reference: AgentSoundReference? = nil) {
        let sound = reference ?? soundRule(.completed).sound
        AgentSoundPlayer.shared.play(sound, priority: Int.max,
                                     volume: AgentSoundConfig.resolvedVolume(defaults: defaults),
                                     library: soundLibrary)
    }

    func importSounds() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK else { return }
            do { for url in panel.urls { _ = try self.soundLibrary.importSound(from: url) } }
            catch { self.present(error) }
        }
        if let hostWindow { panel.beginSheetModal(for: hostWindow, completionHandler: finish) }
        else { finish(panel.runModal()) }
    }

    func renameSound(_ reference: AgentSoundReference, to name: String) {
        do { try soundLibrary.rename(reference, to: name) } catch { present(error) }
    }

    func removeSound(_ reference: AgentSoundReference) {
        do { try soundLibrary.remove(reference) } catch { present(error) }
    }

    private func present(_ error: Error) {
        let alert = NSAlert(error: error)
        if let hostWindow { alert.beginSheetModal(for: hostWindow) } else { alert.runModal() }
    }

    // MARK: Keyboard shortcuts

    struct ShortcutGroup: Identifiable, Equatable {
        let id: String
        let title: String
        let entries: [ShortcutCatalogEntry]
    }

    var shortcutGroups: [ShortcutGroup] {
        _ = revision
        var order: [String] = []
        var buckets: [String: [ShortcutCatalogEntry]] = [:]
        for entry in ShortcutCatalog.entries(navKeymap: navKeymap, defaults: defaults) {
            let title = Self.layerTitle(entry.layer)
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(entry)
        }
        return order.map { ShortcutGroup(id: $0, title: $0, entries: buckets[$0] ?? []) }
    }

    static func layerTitle(_ layer: ShortcutLayer) -> String {
        switch layer {
        case .global: return "Everywhere"
        case .navMode: return "Navigation mode"
        case .inbox: return "Activity Dock"
        case .tile(let kind): return "\(words(kind.rawValue)) tiles"
        }
    }

    /// "browserInspector" → "Browser inspector": a stored kind, read as words.
    static func words(_ identifier: String) -> String {
        var result = ""
        for character in identifier {
            if character.isUppercase, !result.isEmpty { result.append(" ") }
            result.append(result.isEmpty ? Character(character.uppercased()) : Character(character.lowercased()))
        }
        return result
    }

    func chordDisplay(entryID: String) -> String? {
        shortcutGroups.lazy.flatMap(\.entries).first { $0.id == entryID }?.chordDisplay
    }

    func beginRecording(_ entryID: String) {
        captureMessages[entryID] = nil
        recordingEntryID = entryID
    }

    func cancelRecording() {
        recordingEntryID = nil
    }

    private func entry(_ id: String) -> ShortcutCatalogEntry? {
        ShortcutCatalog.entries(navKeymap: navKeymap, defaults: defaults).first { $0.id == id }
    }

    @discardableResult
    func finishCapture(entryID: String, keyCode: UInt16, modifiers: FocusKeyModifiers, character: String?) -> KeybindEditor.Result? {
        guard let target = entry(entryID)?.editTarget else { return nil }
        let result = KeybindEditor.apply(
            target: target, keyCode: keyCode, modifiers: modifiers, character: character,
            currentNavKeymap: navKeymap, defaults: defaults)
        switch result {
        case .applied(let resolved):
            if let resolved { applyResolvedKeymap(resolved) }
            if case .registered = target { onShortcutsChanged?() }
            recordingEntryID = nil
            captureMessages[entryID] = nil
            revision += 1
        case .rejected(let reason):
            switch reason {
            case .collidesWithInviolableGlobal:
                captureMessages[entryID] = "That shortcut is reserved by an app command."
            case .invalidNavKey:
                captureMessages[entryID] = "Navigation keys must be one letter or number."
            case .registeredBinding(let explanation):
                captureMessages[entryID] = explanation
            }
        }
        return result
    }

    func resetShortcut(_ entryID: String) {
        guard let target = entry(entryID)?.editTarget else { return }
        if let resolved = KeybindEditor.reset(target: target, defaults: defaults) {
            applyResolvedKeymap(resolved)
        }
        if case .registered = target { onShortcutsChanged?() }
        revision += 1
    }

    func canUnassign(_ entry: ShortcutCatalogEntry) -> Bool {
        if case .registered = entry.editTarget { return true }
        return false
    }

    func unassignShortcut(_ entryID: String) {
        guard case let .registered(shortcutID)? = entry(entryID)?.editTarget,
              let registry = try? CommandRegistry.productRegistry(),
              let definition = registry.shortcuts.first(where: { $0.id == shortcutID }) else { return }
        do {
            try ShortcutBindingStore(defaults: defaults).unassign(definition, registry: registry)
            onShortcutsChanged?()
            revision += 1
        } catch {
            NSSound.beep()
        }
    }

    private func applyResolvedKeymap(_ resolved: NavKeymap) {
        navKeymap = resolved
        onKeymapChanged?(resolved)
    }

    // MARK: Search

    /// The registry for the panes shown right now; both search and the drift guard
    /// read this, and the renderer draws from the same schema rows.
    func entries() -> [SettingsEntry] {
        SettingsRegistry.entries(sections: sections, defaults: defaults, paneIDs: Set(visiblePanes.map(\.id)))
    }

    private func recomputeSearch() {
        // Stored in DISPLAY order (grouped by pane), so ↑/↓ walk what is on screen.
        searchResults = SettingsSearch.grouped(SettingsSearch.search(searchQuery, in: entries())).flatMap(\.results)
        selectedResultIndex = searchResults.isEmpty ? nil : 0
    }

    var groupedResults: [SettingsSearch.PaneResults] { SettingsSearch.grouped(searchResults) }
    var selectedResult: SettingsEntry? {
        selectedResultIndex.flatMap { searchResults.indices.contains($0) ? searchResults[$0].entry : nil }
    }

    func moveSelection(by delta: Int) {
        guard !searchResults.isEmpty else { return }
        let current = selectedResultIndex ?? (delta > 0 ? -1 : searchResults.count)
        selectedResultIndex = min(searchResults.count - 1, max(0, current + delta))
    }

    func commitSelection() {
        guard let index = selectedResultIndex, searchResults.indices.contains(index) else { return }
        reveal(searchResults[index].entry)
    }

    func clearSearch() {
        searchQuery = ""
    }

    /// Navigate to the entry's pane, scroll its row into view and flash it.
    func reveal(_ entry: SettingsEntry) {
        if let index = searchResults.firstIndex(where: { $0.entry.id == entry.id }) { selectedResultIndex = index }
        selectPane(entry.paneID)
        guard let anchor = entry.anchor else { return }
        scrollToken += 1
        scrollRequest = ScrollRequest(anchor: anchor, token: scrollToken)
        highlightedEntryID = anchor
        highlightGeneration += 1
        let generation = highlightGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1_600))
            guard let self, self.highlightGeneration == generation else { return }
            self.highlightedEntryID = nil
        }
    }

    func flushPendingEdits() {
        let edits = pendingEdits
        pendingEdits.removeAll()
        for commit in edits.values { commit() }
    }

    func requestSearchFocus() {
        searchFocusToken += 1
    }

    // MARK: Census hooks (rows call these)

    func noteAppeared(_ anchor: String, pane: String) { renderedAnchorsByPane[pane, default: [:]][anchor, default: 0] += 1 }
    func noteDisappeared(_ anchor: String, pane: String) {
        let count = (renderedAnchorsByPane[pane]?[anchor] ?? 1) - 1
        renderedAnchorsByPane[pane]?[anchor] = count > 0 ? count : nil
        if count <= 0, pane == selectedPaneID { anchorFrames[anchor] = nil }
    }
    /// The pane's full set of row frames, as the latest layout reported it: rows
    /// that left the pane leave this too.
    func noteFrames(_ frames: [String: CGRect]) { anchorFrames = frames }

    /// True when the anchor's row lies inside the pane's visible scroll viewport.
    func isAnchorVisible(_ anchor: String) -> Bool {
        guard let frame = anchorFrames[anchor], viewportSize.height > 0 else { return false }
        return frame.maxY > 0 && frame.minY < viewportSize.height
    }
}

/// A typed view onto `SettingsModel.write` for one field.
@MainActor
struct SettingsBinding {
    let model: SettingsModel
    let field: SettingsField

    var value: SettingsValue? { model.value(of: field) }
    func set(_ value: SettingsValue) { model.write(value, to: field) }

    var bool: Bool {
        if case let .bool(on)? = value { return on }
        return false
    }
    var string: String {
        if case let .string(text)? = value { return text }
        return ""
    }
    var double: Double {
        if case let .double(number)? = value { return number }
        return 0
    }
}
