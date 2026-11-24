import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

@MainActor
final class LaunchProfilePalette: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    /// Returns true only when the app accepted/completed the selection far
    /// enough for it to be a truthful recent destination.
    var onSelectProfile: ((String) -> Bool)?
    /// The harness travels with the model: ids collide across CLIs.
    var onSelectAgentModel: ((AgentHarness, String) -> Bool)?
    var onSelectAction: ((LaunchPaletteAction) -> Bool)?
    /// Bring a closed agent back. Separate from `onSelectAction` because the row
    /// already carries the dispatch identity and the agent id is not a tile id —
    /// a closed agent has no tile, which is the whole reason this row exists.
    var onOpenTilelessAgent: ((UUID) -> Bool)?
    /// The Open file step. The palette owns the step's look and keys; the app owns the
    /// index and the open itself, so a file only ever opens through `openProjectFile`.
    var onSearchFiles: ((String, @escaping @MainActor ([PaletteFileRow]) -> Void) -> Void)?
    /// The step's resting sections: files agents made, then recent files.
    var onFileSections: (() -> [(title: String, rows: [PaletteFileRow])])?
    var onOpenFile: ((PaletteFileRow, PaletteFileAction) -> Bool)?
    var onClose: (() -> Void)?

    enum PaletteFileAction { case openBesideAgent, reveal, copy }

    static let rootAccessibilityIdentifier = "ContinuumLaunchProfilePaletteRoot"

    private var paletteView: NSView?
    private var tableView: NSTableView?
    private var searchField: NSTextField?
    private var footerLabel: NSTextField?
    private var fileEmptyLabel: NSTextField?
    private var fileSearchToken = 0
    private var fileSearchResults: [PaletteFileRow] = []
    /// A search is out for the typed query; a key pressed meanwhile waits for it, so it never acts on the stale list.
    private var fileSearchPending = false
    private var deferredFileAction: PaletteFileAction?
    private static let recentFilesDefaultsKey = "continuum.commandCenter.recentFiles"

    private var rows: [LaunchPaletteRow] = []
    private var rootRows: [LaunchPaletteRow] = []
    private var rootQuery = ""
    private var agentModelRows: [LaunchPaletteRow] = []
    /// The rows a check passed in place of the live catalogue (default harness).
    private var agentModelOverride: [AgentModelPaletteRow]?
    /// The root row that opened the model step: recorded as the recent.
    private var agentModelParent: LaunchPaletteRow = .action(.newManagedAgent)
    private var filtered: [LaunchPaletteRow] = []
    private var displayEntries: [CommandCenterDisplayEntry] = []
    private var filesystemCreationPreview: String?
    private weak var previousFirstResponder: NSResponder?
    private weak var previousFirstResponderWindow: NSWindow?

    private static let standardFooter = "Type to search · ↑↓ Select · Return Open · Esc Close"
    private static let fileFooter = "↑↓ Select · Return Open next to agent · ⌘Return Reveal in Finder · ⌥Return Copy file · Esc Back"

    private enum NavigationLevel {
        case root
        case agentModels
        case files
    }

    private var navigationLevel = NavigationLevel.root

    private static let recentDefaultsKey = "continuum.commandCenter.recentIDs"
    private static let recentAgentModelDefaultsKey = "continuum.commandCenter.recentAgentModelID"

    /// Every defaults read and write the palette itself makes — the recents list, the
    /// remembered model, and the read of the configured default. Injectable because
    /// `runDuplicateRootSelfCheck` runs INSIDE the app bundle from
    /// `check-app-bundle.sh`, and it drives the model step: writing
    /// `AgentModelConfig.modelKey` into `.standard` there rewrote the user's own
    /// configured agent model for the length of the run, and permanently if the run
    /// died before its `defer`. Production passes nothing and gets `.standard`.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    func show(near host: NSWindow, profiles: [TileSpawner.AnnotatedProfile], projects: [ProjectPickerRow] = [], workspaces: [WorkspaceEntry] = [], contextualActions: [LaunchPaletteAction] = [], harnessRoles: [HarnessRole] = [], jumpTiles: [JumpTileRow] = [], jumpZones: [JumpZoneRow] = [], tilelessAgents: [TilelessAgentPaletteRow] = [], initialQuery: String = "", agentModels: [AgentModelPaletteRow]? = nil, filesystemCreationPreview: String? = nil) {
        rootRows = LaunchPaletteModel.makeRows(profiles: profiles.map(Self.profileRow(for:)), projects: projects, workspaces: workspaces, contextualActions: contextualActions, harnessRoles: harnessRoles, jumpTiles: jumpTiles, jumpZones: jumpZones, tilelessAgents: tilelessAgents, agentHarnesses: Self.agentHarnessRows(defaults: defaults))
        rows = rootRows
        rootQuery = initialQuery
        navigationLevel = .root
        self.filesystemCreationPreview = filesystemCreationPreview
        agentModelOverride = agentModels
        agentModelRows = []
        guard let hostView = host.contentView else { return }
        let wasVisible = isVisible
        let paletteView = ensurePaletteView()
        if !wasVisible {
            capturePreviousFirstResponder(in: host)
        }
        if paletteView.superview !== hostView {
            paletteView.removeFromSuperview()
            hostView.addSubview(paletteView)
        }
        searchField?.stringValue = initialQuery
        searchField?.placeholderString = "Search Array…"
        applyFilter(query: initialQuery)

        let hostBounds = hostView.bounds
        let contentHeight = CGFloat(92) + displayEntries.reduce(CGFloat.zero) { total, entry in
            total + (entry.isSection ? CommandCenterSectionCell.height : 46)
        }
        let availableWidth = max(0, hostBounds.width - 32)
        let availableHeight = max(0, hostBounds.height - 32)
        let size = NSSize(
            width: min(660, max(320, hostBounds.width - 48), availableWidth),
            height: min(520, max(220, contentHeight), availableHeight)
        )
        let x = hostBounds.midX - size.width / 2
        let topInset = max(24, min(72, hostBounds.height * 0.10))
        let y = max(16, hostBounds.maxY - size.height - topInset)
        paletteView.frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        paletteView.layoutSubtreeIfNeeded()
        tableView?.sizeLastColumnToFit()
        host.makeFirstResponder(searchField)
    }

    func close() {
        close(restoreFocus: true)
    }

    @discardableResult
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard isVisible, event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if navigationLevel == .files, event.keyCode == 36 || event.keyCode == 76, !modifiers.contains(.control) {
            if modifiers.contains(.command) { commitFile(.reveal); return true }
            if modifiers.contains(.option) { commitFile(.copy); return true }
        }
        if modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) {
            return false
        }

        switch event.keyCode {
        case 36, 76: // Return / keypad Enter.
            commitSelection()
            return true
        case 53: // Escape.
            navigateBackOrClose()
            return true
        case 125: // Down arrow.
            moveSelection(by: 1)
            return true
        case 126: // Up arrow.
            moveSelection(by: -1)
            return true
        case 51: // Delete / Backspace.
            guard let searchField else { return true }
            if !searchField.stringValue.isEmpty {
                searchField.stringValue.removeLast()
                applyFilter(query: searchField.stringValue)
            }
            return true
        default:
            guard let characters = event.characters, !characters.isEmpty else { return false }
            guard characters.unicodeScalars.allSatisfy({ $0.value >= 32 }) else { return false }
            guard let searchField else { return true }
            searchField.stringValue += characters
            applyFilter(query: searchField.stringValue)
            return true
        }
    }

    private func close(restoreFocus: Bool) {
        let window = previousFirstResponderWindow ?? paletteView?.window
        let currentWasPaletteResponder = isPaletteResponder(window?.firstResponder)
        let shouldRestore = restoreFocus && shouldRestorePreviousFirstResponder(in: window)
        searchField?.delegate = nil
        tableView?.dataSource = nil
        tableView?.delegate = nil
        tableView?.target = nil
        paletteView?.removeFromSuperview()
        if shouldRestore,
           let window,
           let responder = previousFirstResponder,
           isRestorable(responder, in: window) {
            window.makeFirstResponder(responder)
        } else if restoreFocus, currentWasPaletteResponder {
            window?.makeFirstResponder(nil)
        }
        previousFirstResponder = nil
        previousFirstResponderWindow = nil
        paletteView = nil
        tableView = nil
        searchField = nil
        rows.removeAll()
        rootRows.removeAll()
        agentModelRows.removeAll()
        agentModelOverride = nil
        agentModelParent = .action(.newManagedAgent)
        rootQuery = ""
        navigationLevel = .root
        fileSearchToken += 1
        fileSearchPending = false
        deferredFileAction = nil
        fileSearchResults.removeAll()
        footerLabel = nil
        fileEmptyLabel = nil
        filtered.removeAll()
        displayEntries.removeAll()
        filesystemCreationPreview = nil
        onClose?()
    }

    var isVisible: Bool { paletteView?.superview != nil }

    var searchTextForQA: String { searchField?.stringValue ?? "" }
    var isChoosingAgentModelForQA: Bool { navigationLevel == .agentModels }
    /// QA: type into the search field as the user would.
    func typeForQA(_ text: String) { searchField?.stringValue = text; applyFilter(query: text) }
    /// QA: a real key event through the production key handler.
    @discardableResult
    func keyForQA(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: keyCode == 36 ? "\r" : "", charactersIgnoringModifiers: keyCode == 36 ? "\r" : "", isARepeat: false, keyCode: keyCode) else { return false }
        return handleKeyEvent(event)
    }
    var isChoosingFileForQA: Bool { navigationLevel == .files }
    var fileRowsForQA: [PaletteFileRow] { displayEntries.compactMap { if case let .file(row) = $0 { return row }; return nil } }
    var sectionTitlesForQA: [String] { displayEntries.compactMap { if case let .section(title) = $0 { return title }; return nil } }
    var footerTextForQA: String { footerLabel?.stringValue ?? "" }
    var filteredDisplayNamesForQA: [String] { filtered.map(\.displayName) }

    var selectedDisplayNameForQA: String? {
        if let tableView, case let .file(file) = entry(at: tableView.selectedRow) { return file.name }
        guard let tableView, case let .item(item) = entry(at: tableView.selectedRow) else { return nil }
        switch item.row {
        case let .action(action): return action.displayName
        case let .profile(profile): return profile.displayName
        case let .agentModel(model): return model.displayName
        case let .agentHarness(row): return LaunchPaletteRow.agentHarness(row).displayName
        case let .project(project): return "Switch to \(project.name)"
        case let .workspace(workspace): return "Switch to \(workspace.name) Workspace"
        case let .workspaceAction(action, workspace):
            switch action {
            case .renameWorkspace: return "Rename \(workspace.name) Workspace…"
            case .deleteWorkspace: return "Delete \(workspace.name) Workspace…"
            default: return action.displayName
            }
        case let .jumpToTile(tile): return "Jump to \(tile.title)"
        case let .jumpToZone(zone): return "Jump to \(zone.title)"
        case let .tilelessAgent(agent): return "Reopen \(agent.displayName)"
        }
    }

    static func paletteRootCount(in hostView: NSView) -> Int {
        hostView.subviews.filter { $0.accessibilityIdentifier() == rootAccessibilityIdentifier }.count
    }

    static func runDuplicateRootSelfCheck() throws {
        guard fallbackAgentModelName(for: "openai-codex/gpt-5.6-sol") == "GPT-5.6 Sol" else {
            throw PaletteSelfCheckError.failed("agent-model fallback leaked its raw model id into the primary title")
        }
        // FIRST, before anything here writes anything: every key the palette itself
        // owns, snapshotted on the USER's domain and compared at the end of this body —
        // before any restoring `defer` could hide a write. That is the witness for the
        // suite below, and the save/restore dance this replaces fails it.
        let standard = UserDefaults.standard
        let paletteOwnedKeys = [AgentModelConfig.modelKey, recentDefaultsKey, recentAgentModelDefaultsKey]
        // Read by VALUE, never `String(describing: object(forKey:))`: an array's
        // description carries its object address, so two reads of one unchanged key
        // could compare unequal.
        func paletteOwnedStandardValues() -> [String] {
            [
                standard.string(forKey: AgentModelConfig.modelKey) ?? "<absent>",
                (standard.stringArray(forKey: recentDefaultsKey) ?? ["<absent>"]).joined(separator: ","),
                standard.string(forKey: recentAgentModelDefaultsKey) ?? "<absent>",
            ]
        }
        let standardBefore = paletteOwnedStandardValues()
        // …and the persistent domain itself, watched through every write: the
        // comparison above reads `.standard` at the end, so it cannot see a write
        // that a `defer` later restored — which is how the appearance witness
        // below rewrote the owner's real glassiness inside the prod bundle.
        let standardGuard = QAStandardDefaultsGuard(keys: Set(paletteOwnedKeys).union([
            CommandCenterAppearanceConfig.glassinessKey, CommandCenterAppearanceConfig.customOpacityKey,
        ]))
        // The palette's own state goes to a PRIVATE SUITE, not the user's domain.
        // `check-app-bundle.sh` runs this leg inside the app bundle, so under
        // `--channel prod` the old dance rewrote the real configured agent model — the
        // owner's model choice — for the length of the run, and left it rewritten if
        // the run died before its `defer`.
        let suiteName = "continuum.qa.palette-duplicate-root.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw PaletteSelfCheckError.failed("could not open the private defaults suite this check writes into")
        }
        // Unique per run, and erased after it: two worktrees can run this leg at the
        // same moment, and a shared suite would have them overwriting each other's
        // fixture mid-check. Same shape as the other QA suites in this target.
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("openai-codex/gpt-5.6-sol", forKey: AgentModelConfig.modelKey)
        // Glassiness is read from the standard domain by
        // `CommandCenterSurfaceView.applyAppearance` itself, so the appearance
        // witness below pins it IN-PROCESS (argument domain, never on disk). The
        // save/write/restore this replaces rewrote the owner's real glassiness for
        // the length of the run whenever this leg ran inside the prod bundle.
        var unpinAppearance: () -> Void = {}
        func pinAppearance(_ glassiness: CommandCenterGlassiness) {
            unpinAppearance()
            unpinAppearance = QADefaultsPin.pin([
                CommandCenterAppearanceConfig.glassinessKey: glassiness.rawValue,
                CommandCenterAppearanceConfig.customOpacityKey: CommandCenterAppearanceConfig.defaultCustomOpacity,
            ])
        }
        pinAppearance(CommandCenterAppearanceConfig.defaultGlassiness)
        defer { unpinAppearance() }
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        let hostView = NSView(frame: host.contentRect(forFrameRect: host.frame))
        host.contentView = hostView
        let palette = LaunchProfilePalette(defaults: defaults)
        let profiles: [TileSpawner.AnnotatedProfile] = []
        for _ in 0..<5 {
            palette.show(near: host, profiles: profiles)
            guard paletteRootCount(in: hostView) == 1 else {
                throw PaletteSelfCheckError.unexpectedRootCount(paletteRootCount(in: hostView), expected: 1)
            }
        }
        guard palette.paletteView is CommandCenterSurfaceView else {
            throw PaletteSelfCheckError.failed("palette root is not the glass command-center surface")
        }
        guard palette.displayEntries.contains(where: {
            if case CommandCenterDisplayEntry.section(CommandCenterCategory.create.rawValue) = $0 { return true }
            return false
        }), palette.displayEntries.contains(where: {
            if case CommandCenterDisplayEntry.section(CommandCenterCategory.actions.rawValue) = $0 { return true }
            return false
        }) else {
            throw PaletteSelfCheckError.failed("default command center did not render categorized sections")
        }
        if let actionsHeader = palette.displayEntries.firstIndex(where: {
            if case CommandCenterDisplayEntry.section(CommandCenterCategory.actions.rawValue) = $0 { return true }
            return false
        }),
           let previousItem = palette.displayEntries[..<actionsHeader].lastIndex(where: {
               if case let .item(item) = $0 { return item.row.isSelectable }
               return false
           }),
           let nextItem = palette.displayEntries.indices.first(where: { index in
               guard index > actionsHeader, case let .item(item) = palette.displayEntries[index] else { return false }
               return item.row.isSelectable
           }) {
            palette.tableView?.selectRowIndexes(IndexSet(integer: previousItem), byExtendingSelection: false)
            palette.moveSelection(by: 1)
            guard palette.tableView?.selectedRow == nextItem else {
                throw PaletteSelfCheckError.failed("keyboard traversal did not skip the Actions section header")
            }
        } else {
            throw PaletteSelfCheckError.failed("could not construct the cross-category traversal witness")
        }
        guard let table = palette.tableView,
              palette.tableView(table, heightOfRow: palette.displayEntries.firstIndex(where: { !$0.isSection }) ?? -1) == 46 else {
            throw PaletteSelfCheckError.failed("command-center result density drifted from 46 points")
        }
        let regularFrame = palette.paletteView?.frame ?? .zero
        guard regularFrame.width == 660,
              regularFrame.minX >= hostView.bounds.minX,
              regularFrame.maxX <= hostView.bounds.maxX,
              regularFrame.maxY <= hostView.bounds.maxY,
              hostView.bounds.maxY - regularFrame.maxY <= 72 else {
            throw PaletteSelfCheckError.failed("command center is not width-capped, host-clamped, and upper-aligned: \(regularFrame)")
        }

        guard let surface = palette.paletteView as? CommandCenterSurfaceView else {
            throw PaletteSelfCheckError.failed("missing command-center surface for appearance witness")
        }
        pinAppearance(.solid)
        surface.reapplyAppearanceForQA()
        guard surface.appearanceSnapshotForQA == .init(usesBlur: false, opacity: 1) else {
            throw PaletteSelfCheckError.failed("Solid did not produce an opaque, blur-free command center")
        }
        pinAppearance(.frosted)
        surface.reapplyAppearanceForQA()
        guard surface.appearanceSnapshotForQA == .init(usesBlur: true, opacity: 0.84) else {
            throw PaletteSelfCheckError.failed("Frosted did not produce the 84% default command center")
        }
        pinAppearance(.glass)
        surface.reapplyAppearanceForQA()
        guard surface.appearanceSnapshotForQA == .init(usesBlur: true, opacity: 0.72) else {
            throw PaletteSelfCheckError.failed("Glass did not produce the 72% command center")
        }
        host.appearance = NSAppearance(named: .aqua)
        surface.reapplyAppearanceForQA()
        let lightFill = surface.backgroundColorForQA
        host.appearance = NSAppearance(named: .darkAqua)
        surface.reapplyAppearanceForQA()
        guard lightFill != surface.backgroundColorForQA else {
            throw PaletteSelfCheckError.failed("command-center token fill did not change across light/dark appearances")
        }
        host.appearance = nil
        pinAppearance(CommandCenterAppearanceConfig.defaultGlassiness)
        palette.close()

        host.setContentSize(NSSize(width: 360, height: 260))
        palette.show(near: host, profiles: profiles)
        let compactFrame = palette.paletteView?.frame ?? .zero
        guard compactFrame.minX >= hostView.bounds.minX,
              compactFrame.maxX <= hostView.bounds.maxX,
              compactFrame.minY >= hostView.bounds.minY,
              compactFrame.maxY <= hostView.bounds.maxY else {
            throw PaletteSelfCheckError.failed("small-window command center escaped its host bounds: \(compactFrame) vs \(hostView.bounds)")
        }
        palette.close()

        let selectableProfiles = [TileSpawner.AnnotatedProfile(
            spec: LaunchProfileSpec(id: "qa", displayName: "QA", kind: .shell, title: "QA"),
            resolution: .found(LaunchProfile(command: "/bin/zsh", arguments: [], cwd: "/tmp", title: "QA"))
        )]
        palette.onSelectProfile = { _ in false }
        palette.show(near: host, profiles: selectableProfiles, initialQuery: "QA")
        palette.commitSelection()
        guard defaults.stringArray(forKey: recentDefaultsKey) == nil else {
            throw PaletteSelfCheckError.failed("a refused profile dispatch was persisted as a recent")
        }
        palette.onSelectProfile = { _ in true }
        palette.show(near: host, profiles: selectableProfiles, initialQuery: "QA")
        palette.commitSelection()
        guard defaults.stringArray(forKey: recentDefaultsKey) == ["profile:qa"] else {
            throw PaletteSelfCheckError.failed("an accepted profile dispatch was not persisted as a recent")
        }
        palette.onSelectProfile = nil

        // MIXED PROVIDERS: pi's catalogue lists every anthropic model before the
        // first codex one, so under a single "Choose Model" header a codex user saw a
        // screenful of Claude and no evidence anything followed — reported twice as
        // "only Anthropic models" when nothing was filtered at all. Each provider's
        // block must now be headed, in catalogue order.
        let mixedProviderModels = [
            AgentModelPaletteRow(id: "anthropic/claude-opus-5", displayName: "Claude Opus 5", providerName: "Anthropic · anthropic/claude-opus-5"),
            AgentModelPaletteRow(id: "anthropic/claude-sonnet-5", displayName: "Claude Sonnet 5", providerName: "Anthropic · anthropic/claude-sonnet-5"),
            AgentModelPaletteRow(id: "openai-codex/gpt-5.6-luna", displayName: "GPT-5.6 Luna", providerName: "OpenAI Codex · openai-codex/gpt-5.6-luna"),
        ]
        palette.show(near: host, profiles: [], initialQuery: "Agent", agentModels: mixedProviderModels)
        palette.commitSelection()
        let mixedHeaders = palette.displayEntries.compactMap { entry -> String? in
            if case let .section(title) = entry { return title }
            return nil
        }
        guard mixedHeaders == ["Quick Start", "Anthropic", "OpenAI Codex"] else {
            throw PaletteSelfCheckError.failed("the model step must head each provider's block, got \(mixedHeaders)")
        }
        guard palette.displayEntries.contains(where: { entry in
            if case let .item(item) = entry { return item.row.agentModelID == "openai-codex/gpt-5.6-luna" }
            return false
        }) else {
            throw PaletteSelfCheckError.failed("a codex model must be reachable in the mixed-provider model step")
        }
        if let modelSearch = palette.searchField {
            _ = palette.control(modelSearch, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        }

        let agentModels = [
            AgentModelPaletteRow(id: "openai-codex/gpt-5.6-sol", displayName: "GPT-5.6 Sol", providerName: "OpenAI Codex · openai-codex/gpt-5.6-sol"),
            AgentModelPaletteRow(id: "openai-codex/gpt-5.6-luna", displayName: "GPT-5.6 Luna", providerName: "OpenAI Codex · openai-codex/gpt-5.6-luna"),
        ]
        // A REFUSED model dispatch must leave no trace. This is the observable end of
        // `AgentModelConfig.resolved(selection:)`: a row that left the live catalogue
        // while the palette was open spawns nothing, and ⌘K must not then offer it
        // back as "Recently Used".
        palette.onSelectAgentModel = { _, _ in false }
        palette.show(near: host, profiles: [], initialQuery: "Agent", agentModels: agentModels)
        palette.commitSelection()
        guard let refusedSearch = palette.searchField else { throw PaletteSelfCheckError.missingSearchField }
        refusedSearch.stringValue = "luna"
        palette.applyFilter(query: "luna")
        palette.commitSelection()
        guard !palette.isVisible, defaults.string(forKey: recentAgentModelDefaultsKey) == nil else {
            throw PaletteSelfCheckError.failed("a refused model dispatch was remembered as the recent model")
        }

        var selectedModelID: String?
        palette.onSelectAgentModel = { _, modelID in
            selectedModelID = modelID
            return true
        }
        palette.show(near: host, profiles: [], initialQuery: "Agent", agentModels: agentModels)
        palette.commitSelection()
        guard palette.isVisible, palette.isChoosingAgentModelForQA,
              palette.selectedDisplayNameForQA == "Default — GPT-5.6 Sol" else {
            throw PaletteSelfCheckError.failed("New Agent did not lead with the explicit configured-default shortcut")
        }
        guard let searchField = palette.searchField else { throw PaletteSelfCheckError.missingSearchField }
        searchField.stringValue = "luna"
        palette.applyFilter(query: "luna")
        guard palette.selectedDisplayNameForQA == "GPT-5.6 Luna" else {
            throw PaletteSelfCheckError.failed("model-step search did not select the matching exact model")
        }
        // A single-provider list keeps the plain header — a lone "OPENAI CODEX" over
        // every row it owns is noise, not information.
        palette.applyFilter(query: "")
        let singleHeaders = palette.displayEntries.compactMap { entry -> String? in
            if case let .section(title) = entry { return title }
            return nil
        }
        guard singleHeaders == ["Quick Start", CommandCenterCategory.models.rawValue] else {
            throw PaletteSelfCheckError.failed("a single-provider model step keeps quick start above one plain catalogue header, got \(singleHeaders)")
        }
        _ = palette.control(searchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        guard palette.isVisible, !palette.isChoosingAgentModelForQA,
              palette.searchTextForQA == "Agent",
              palette.selectedDisplayNameForQA == LaunchPaletteAction.newManagedAgent.displayName else {
            throw PaletteSelfCheckError.failed("Escape did not pop the model step and restore its root query")
        }
        palette.commitSelection()
        guard palette.isChoosingAgentModelForQA, let modelSearch = palette.searchField else {
            throw PaletteSelfCheckError.failed("New Agent could not re-enter its model step after navigating back")
        }
        modelSearch.stringValue = "luna"
        palette.applyFilter(query: "luna")
        palette.commitSelection()
        guard !palette.isVisible,
              selectedModelID == "openai-codex/gpt-5.6-luna",
              defaults.stringArray(forKey: recentDefaultsKey)?.first == "action:new-agent",
              defaults.string(forKey: recentAgentModelDefaultsKey)
                == recentAgentModelMemo(harness: AgentHarnessConfig.resolved(defaults: defaults), model: "openai-codex/gpt-5.6-luna") else {
            throw PaletteSelfCheckError.failed("model selection did not dispatch the exact id and record the completed parent action/model")
        }
        palette.show(near: host, profiles: [], initialQuery: "Agent", agentModels: agentModels)
        palette.commitSelection()
        let quickTitles = palette.displayEntries.compactMap { entry -> String? in
            guard case let .item(item) = entry,
                  case let .agentModel(model) = item.row,
                  model.kind != .catalog else { return nil }
            return model.displayName
        }
        guard quickTitles == ["Default — GPT-5.6 Sol", "Recently Used — GPT-5.6 Luna"] else {
            throw PaletteSelfCheckError.failed("model shortcuts did not keep stable default separate from recent choice: \(quickTitles)")
        }
        palette.close()
        palette.onSelectAgentModel = nil
        guard paletteRootCount(in: hostView) == 0 else {
            throw PaletteSelfCheckError.unexpectedRootCount(paletteRootCount(in: hostView), expected: 0)
        }
        let standardAfter = paletteOwnedStandardValues()
        guard standardAfter == standardBefore else {
            throw PaletteSelfCheckError.failed(
                "this check wrote the palette's own state into the USER's defaults domain \(paletteOwnedKeys): \(standardBefore) -> \(standardAfter). check-app-bundle.sh runs this leg inside the app bundle, so under --channel prod one of those keys is the owner's configured agent model."
            )
        }
        let touched = standardGuard.finish()
        guard touched.isEmpty else {
            throw PaletteSelfCheckError.failed("this check wrote the owner's standard defaults domain, if only for a moment: \(touched)")
        }
    }

    /// `--palette-agent-harness-check`: ⌘K offers a New <Harness> Agent row for
    /// Claude Code, Codex and Pi whatever Settings seeds, the default first; each
    /// row's model step lists only that CLI's ids and dispatches the PAIR, so an id
    /// two CLIs share (`openai-codex/gpt-5.6-luna`, Codex's and Pi's) runs on the
    /// CLI the person picked; a harness that cannot run is listed, unselectable,
    /// in the composer's own words.
    ///
    /// Drives the real palette — no `agentModels` override, the catalogue served
    /// from `AgentCatalogQAFixture` — with every default written to a private
    /// suite and the user's domain watched throughout.
    static func runAgentHarnessSelfCheck() throws {
        func fail(_ message: String) -> PaletteSelfCheckError { .failed("agent harness rows: " + message) }
        let standardGuard = QAStandardDefaultsGuard(keys: QAStandardDefaultsGuard.agentSelectionKeys
            .union([recentDefaultsKey, recentAgentModelDefaultsKey]))
        let suiteName = "continuum.qa.palette-agent-harness.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw fail("could not open a private suite") }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        func serveFixtureCatalogues(piReadiness: HarnessReadiness = .ready) {
            AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.claude)
            AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.codex)
            AgentModelCatalog.shared.resetForQA(snapshot: AgentHarnessCatalogSnapshot(
                harness: .pi, readiness: piReadiness, models: AgentCatalogQAFixture.pi))
        }
        serveFixtureCatalogues()
        defer { serveFixtureCatalogues() }
        let shared = "openai-codex/gpt-5.6-luna"
        guard AgentModelConfig.modelOptions(for: .codex).contains(shared),
              AgentModelConfig.modelOptions(for: .pi).contains(shared) else {
            throw fail("the fixture no longer has an id both Codex and Pi offer; the collision arm tests nothing")
        }

        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView = NSView(frame: host.contentRect(forFrameRect: host.frame))
        let names: [AgentHarness: String] = [
            .claudeCode: "New Claude Code Agent…", .codex: "New Codex Agent…", .pi: "New Pi Agent…",
        ]
        func harnessRows(_ palette: LaunchProfilePalette) -> [AgentHarnessPaletteRow] {
            palette.rootRows.compactMap { if case let .agentHarness(row) = $0 { return row }; return nil }
        }
        func homeIDs(_ palette: LaunchProfilePalette) -> [String] {
            palette.displayEntries.compactMap { if case let .item(item) = $0 { return item.stableID }; return nil }
        }
        func select(_ palette: LaunchProfilePalette, query: String, displayName: String) throws {
            guard let search = palette.searchField else { throw PaletteSelfCheckError.missingSearchField }
            search.stringValue = query
            palette.applyFilter(query: query)
            if palette.selectedDisplayNameForQA != displayName,
               let index = palette.displayEntries.firstIndex(where: { entry in
                   if case let .item(item) = entry { return item.row.displayName == displayName }
                   return false
               }) {
                palette.tableView?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
            guard palette.selectedDisplayNameForQA == displayName else {
                throw fail("could not select '\(displayName)' for query '\(query)'; selected \(palette.selectedDisplayNameForQA ?? "nil")")
            }
        }
        func stepModels(_ palette: LaunchProfilePalette) -> [AgentModelPaletteRow] {
            palette.agentModelRows.compactMap { if case let .agentModel(model) = $0 { return model }; return nil }
        }

        // 1. Every default: all three rows, the default first.
        for defaultHarness in AgentHarness.allCases {
            defaults.set(defaultHarness.rawValue, forKey: AgentHarnessConfig.key)
            let palette = LaunchProfilePalette(defaults: defaults)
            palette.show(near: host, profiles: [])
            let rows = harnessRows(palette)
            let expected = [defaultHarness] + AgentHarness.allCases.filter { $0 != defaultHarness }
            guard rows.map(\.harness) == expected else {
                throw fail("with \(defaultHarness.rawValue) as the default, the rows are \(rows.map(\.harness.rawValue)), want \(expected.map(\.rawValue))")
            }
            guard rows.first?.isDefault == true, rows.dropFirst().allSatisfy({ !$0.isDefault }), rows.allSatisfy(\.isSelectable) else {
                throw fail("only the first row may be the default and every ready harness must be selectable: \(rows)")
            }
            let rowNames = palette.rootRows.map(\.displayName)
            guard expected.allSatisfy({ rowNames.contains(names[$0]!) }), rowNames.contains("New Agent…") else {
                throw fail("the root rows lack a harness row or plain New Agent…: \(rowNames)")
            }
            let defaultItem = LaunchPaletteModel.presentation(for: .agentHarness(rows[0]))
            guard defaultItem.subtitle?.hasPrefix("Default · ") == true, defaultItem.stableID == "action:new-agent:\(AgentHarnessPaletteRow.slug(defaultHarness))" else {
                throw fail("the default row must say so and keep its stable id: \(defaultItem.subtitle ?? "nil"), \(defaultItem.stableID)")
            }
            // Typing "agent" (or "new agent") lists New Agent… and then every
            // harness, the default first.
            let order = ["action:new-agent"] + expected.map { "action:new-agent:\(AgentHarnessPaletteRow.slug($0))" }
            for query in ["agent", "new agent"] {
                if let search = palette.searchField { search.stringValue = query }
                palette.applyFilter(query: query)
                let listed = homeIDs(palette)
                let positions = order.compactMap { listed.firstIndex(of: $0) }
                guard positions.count == order.count, positions == positions.sorted() else {
                    throw fail("'\(query)' must list New Agent… then each harness, \(defaultHarness.rawValue) first; listed \(listed)")
                }
            }
            palette.close()
        }

        // 2. Claude Code default, choose Codex: only Codex's ids, and the pair
        //    reaches the handler — the shared id goes to Codex, not the default.
        defaults.set(AgentHarness.claudeCode.rawValue, forKey: AgentHarnessConfig.key)
        let palette = LaunchProfilePalette(defaults: defaults)
        var dispatched: [(AgentHarness, String)] = []
        palette.onSelectAgentModel = { harness, model in dispatched.append((harness, model)); return true }
        palette.show(near: host, profiles: [])
        try select(palette, query: "codex agent", displayName: names[.codex]!)
        palette.commitSelection()
        guard palette.isChoosingAgentModelForQA else { throw fail("New Codex Agent… did not open its model step") }
        let codexStep = stepModels(palette)
        guard !codexStep.isEmpty, codexStep.allSatisfy({ $0.harness == .codex }),
              Set(codexStep.map(\.id)) == Set(AgentModelConfig.modelOptions(for: .codex)) else {
            throw fail("the Codex step must list exactly Codex's ids, each as Codex: \(codexStep.map { "\($0.harness?.rawValue ?? "nil")|\($0.id)" })")
        }
        try select(palette, query: "luna", displayName: "GPT-5.6 Luna")
        palette.commitSelection()
        guard dispatched.count == 1, dispatched[0].0 == .codex, dispatched[0].1 == shared else {
            throw fail("choosing Luna under Codex must dispatch (Codex, \(shared)); got \(dispatched.map { "\($0.0.rawValue)|\($0.1)" })")
        }
        guard defaults.string(forKey: recentAgentModelDefaultsKey) == recentAgentModelMemo(harness: .codex, model: shared),
              defaults.stringArray(forKey: recentDefaultsKey)?.first == "action:new-agent:codex" else {
            throw fail("the recent model must be remembered as Codex|\(shared) and the recent row as the Codex row: \(defaults.string(forKey: recentAgentModelDefaultsKey) ?? "nil"), \(defaults.stringArray(forKey: recentDefaultsKey) ?? [])")
        }

        // 3. The same id under Pi goes to Pi, and Codex's recent is not Pi's.
        palette.show(near: host, profiles: [])
        try select(palette, query: "pi agent", displayName: names[.pi]!)
        palette.commitSelection()
        let piStep = stepModels(palette)
        guard piStep.allSatisfy({ $0.harness == .pi }), !piStep.contains(where: { $0.kind == .recentlyUsed }) else {
            throw fail("the Pi step must be Pi's alone, with no Recently Used carried over from Codex: \(piStep.map { "\($0.kind)|\($0.harness?.rawValue ?? "nil")|\($0.id)" })")
        }
        try select(palette, query: "luna", displayName: "GPT-5.6 Luna")
        palette.commitSelection()
        guard dispatched.count == 2, dispatched[1].0 == .pi, dispatched[1].1 == shared else {
            throw fail("choosing Luna under Pi must dispatch (Pi, \(shared)); got \(dispatched.map { "\($0.0.rawValue)|\($0.1)" })")
        }

        // 4. Plain New Agent… offers every CLI that can run, the Settings default
        //    first: it used to list the default's models alone, so with Claude as
        //    the default a GPT model meant creating a Claude tile and switching
        //    its provider (Dylan, 2026-10-19). Return still starts the default.
        defaults.set(AgentHarness.codex.rawValue, forKey: AgentHarnessConfig.key)
        palette.show(near: host, profiles: [], initialQuery: "Agent")
        guard palette.selectedDisplayNameForQA == "New Agent…" else {
            throw fail("the plain New Agent… row must still lead 'Agent'; selected \(palette.selectedDisplayNameForQA ?? "nil")")
        }
        palette.commitSelection()
        let plainStep = stepModels(palette)
        let harnessOrder = plainStep.compactMap(\.harness).reduce(into: [AgentHarness]()) { order, harness in
            if !order.contains(harness) { order.append(harness) }
        }
        guard plainStep.first?.harness == .codex, plainStep.first?.kind == .configuredDefault,
              harnessOrder == [.codex, .claudeCode, .pi],
              Set(plainStep.filter { $0.harness == .claudeCode && $0.kind == .catalog }.map(\.id))
                == Set(AgentModelConfig.modelOptions(for: .claudeCode)) else {
            throw fail("plain New Agent… must open on the default's Default row and then list every ready CLI, default first: \(plainStep.map { "\($0.kind)|\($0.harness?.rawValue ?? "nil")|\($0.id)" })")
        }
        palette.commitSelection()
        guard dispatched.count == 3, dispatched[2].0 == .codex else {
            throw fail("Return on plain New Agent…'s first row must still start the default (Codex); got \(dispatched.map { "\($0.0.rawValue)|\($0.1)" })")
        }
        // Claude Code default, a GPT model from plain New Agent…: a Codex agent.
        defaults.set(AgentHarness.claudeCode.rawValue, forKey: AgentHarnessConfig.key)
        palette.show(near: host, profiles: [], initialQuery: "Agent")
        palette.commitSelection()
        try select(palette, query: "luna", displayName: "GPT-5.6 Luna")
        palette.commitSelection()
        guard dispatched.count == 4, dispatched[3].0 == .codex, dispatched[3].1 == shared else {
            throw fail("with Claude Code the default, Luna from plain New Agent… must start (Codex, \(shared)); got \(dispatched.map { "\($0.0.rawValue)|\($0.1)" })")
        }

        // 5. A harness that cannot run: listed, unselectable, in the composer's words.
        serveFixtureCatalogues(piReadiness: .loggedOut)
        palette.show(near: host, profiles: [])
        guard let piRow = harnessRows(palette).first(where: { $0.harness == .pi }) else {
            throw fail("a signed-out Pi must still be listed")
        }
        let reason = AgentSupervisor.readinessRefusal(for: .pi, retry: "try again")
        guard !piRow.isSelectable, let reason, piRow.unavailableReason == reason,
              LaunchPaletteModel.presentation(for: .agentHarness(piRow)).subtitle == reason,
              reason.contains("signed out"), !reason.lowercased().contains("api key") else {
            throw fail("a signed-out Pi must be unselectable and say why in the CLI-login words: \(piRow), reason \(reason ?? "nil")")
        }
        if let search = palette.searchField { search.stringValue = "pi agent" }
        palette.applyFilter(query: "pi agent")
        guard let piIndex = palette.displayEntries.firstIndex(where: { entry in
            if case let .item(item) = entry { return item.row.displayName == names[.pi]! }
            return false
        }) else { throw fail("a signed-out Pi must stay findable by search") }
        palette.tableView?.selectRowIndexes(IndexSet(integer: piIndex), byExtendingSelection: false)
        palette.commitSelection()
        guard palette.isVisible, !palette.isChoosingAgentModelForQA, dispatched.count == 4 else {
            throw fail("selecting a signed-out harness must do nothing — no model step, no dispatch, no other CLI")
        }
        // ...and plain New Agent… offers none of a signed-out CLI's models.
        palette.close()
        palette.show(near: host, profiles: [], initialQuery: "Agent")
        palette.commitSelection()
        guard palette.isChoosingAgentModelForQA, !stepModels(palette).contains(where: { $0.harness == .pi }) else {
            throw fail("plain New Agent… must leave out a signed-out Pi's models: \(stepModels(palette).map { "\($0.harness?.rawValue ?? "nil")|\($0.id)" })")
        }
        palette.close()
        palette.onSelectAgentModel = nil

        let touched = standardGuard.finish()
        guard touched.isEmpty else { throw fail("this check wrote the owner's standard defaults: \(touched)") }
    }

    static func runFirstResponderRestoreSelfCheck() throws {
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        let hostView = NSView(frame: host.contentRect(forFrameRect: host.frame))
        host.contentView = hostView
        let probe = SemanticTypingProbeView(frame: NSRect(x: 20, y: 20, width: 120, height: 40))
        hostView.addSubview(probe)
        let palette = LaunchProfilePalette()
        let profiles: [TileSpawner.AnnotatedProfile] = []

        try runRestoreSelfCheckScenario(
            name: "escape",
            host: host,
            hostView: hostView,
            probe: probe,
            palette: palette,
            profiles: profiles,
            sentinel: "escape-sentinel"
        ) {
            guard let searchField = palette.searchField else {
                throw PaletteSelfCheckError.missingSearchField
            }
            _ = palette.control(searchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        }

        try runRestoreSelfCheckScenario(
            name: "direct-close",
            host: host,
            hostView: hostView,
            probe: probe,
            palette: palette,
            profiles: profiles,
            sentinel: "direct-sentinel"
        ) {
            palette.close()
        }

        let foundProfiles = [TileSpawner.AnnotatedProfile(
            spec: LaunchProfileSpec(id: "qa", displayName: "QA", kind: .shell, title: "QA"),
            resolution: .found(LaunchProfile(command: "/bin/zsh", arguments: [], cwd: "/tmp", title: "QA"))
        )]
        try runRestoreSelfCheckScenario(
            name: "selection-without-new-focus",
            host: host,
            hostView: hostView,
            probe: probe,
            palette: palette,
            profiles: foundProfiles,
            sentinel: "selection-sentinel"
        ) {
            // The recognition-first zero-query home now pins New Agent ahead of
            // dynamic profiles. Search for this fixture explicitly so this
            // witness continues to exercise a completed profile selection.
            guard let searchField = palette.searchField else {
                throw PaletteSelfCheckError.missingSearchField
            }
            searchField.stringValue = "QA"
            palette.applyFilter(query: "QA")
            _ = palette.control(NSSearchField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        }

        let selectionFocusTarget = SemanticTypingProbeView(frame: NSRect(x: 300, y: 20, width: 120, height: 40))
        hostView.addSubview(selectionFocusTarget)
        palette.onSelectProfile = { _ in
            host.makeFirstResponder(selectionFocusTarget)
            return true
        }
        try runSelectionDoesNotStealNewFocusScenario(
            host: host,
            hostView: hostView,
            previousProbe: probe,
            newFocusProbe: selectionFocusTarget,
            palette: palette,
            profiles: foundProfiles
        )
        palette.onSelectProfile = nil

        // Stale/removed responder safety: closing must not attempt to restore a
        // view that has been detached while the palette is open.
        let staleProbe = SemanticTypingProbeView(frame: NSRect(x: 160, y: 20, width: 120, height: 40))
        hostView.addSubview(staleProbe)
        guard host.makeFirstResponder(staleProbe), host.firstResponder === staleProbe else {
            throw PaletteSelfCheckError.unexpectedFirstResponder(String(describing: host.firstResponder), expected: "stale probe precondition")
        }
        palette.show(near: host, profiles: profiles)
        staleProbe.removeFromSuperview()
        palette.close()
        guard paletteRootCount(in: hostView) == 0 else {
            throw PaletteSelfCheckError.unexpectedRootCount(paletteRootCount(in: hostView), expected: 0)
        }
        guard host.firstResponder !== staleProbe else {
            throw PaletteSelfCheckError.unexpectedFirstResponder("detached stale probe", expected: "non-stale responder")
        }
    }

    enum PaletteSelfCheckError: Error, CustomStringConvertible {
        case unexpectedRootCount(Int, expected: Int)
        case missingSearchField
        case paletteDidNotTakeFocus(String)
        case unexpectedFirstResponder(String, expected: String)
        case typingProbeMissedSentinel(String, got: String)
        case failed(String)

        var description: String {
            switch self {
            case let .unexpectedRootCount(actual, expected):
                return "expected palette root count \(expected), got \(actual)"
            case .missingSearchField:
                return "palette search field was not created"
            case let .paletteDidNotTakeFocus(actual):
                return "palette/search did not take focus; got \(actual)"
            case let .unexpectedFirstResponder(actual, expected):
                return "restored \(actual), expected \(expected)"
            case let .typingProbeMissedSentinel(sentinel, got):
                return "typing sentinel \(sentinel) did not land in probe; got \(got)"
            case let .failed(message):
                return message
            }
        }
    }

    private static func runRestoreSelfCheckScenario(
        name: String,
        host: NSWindow,
        hostView: NSView,
        probe: SemanticTypingProbeView,
        palette: LaunchProfilePalette,
        profiles: [TileSpawner.AnnotatedProfile],
        sentinel: String,
        closePalette: () throws -> Void
    ) throws {
        probe.typed = ""
        guard host.makeFirstResponder(probe), host.firstResponder === probe else {
            throw PaletteSelfCheckError.unexpectedFirstResponder(String(describing: host.firstResponder), expected: "probe before \(name)")
        }
        palette.show(near: host, profiles: profiles)
        guard paletteRootCount(in: hostView) == 1 else {
            throw PaletteSelfCheckError.unexpectedRootCount(paletteRootCount(in: hostView), expected: 1)
        }
        guard palette.isPaletteResponder(host.firstResponder) else {
            throw PaletteSelfCheckError.paletteDidNotTakeFocus(String(describing: host.firstResponder))
        }

        // Re-show while visible must not overwrite the saved responder with the
        // palette's own search responder.
        palette.show(near: host, profiles: profiles)
        guard paletteRootCount(in: hostView) == 1 else {
            throw PaletteSelfCheckError.unexpectedRootCount(paletteRootCount(in: hostView), expected: 1)
        }
        try closePalette()
        guard paletteRootCount(in: hostView) == 0 else {
            throw PaletteSelfCheckError.unexpectedRootCount(paletteRootCount(in: hostView), expected: 0)
        }
        guard host.firstResponder === probe else {
            throw PaletteSelfCheckError.unexpectedFirstResponder(String(describing: host.firstResponder), expected: "probe after \(name)")
        }
        probe.keyDown(with: NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: host.windowNumber,
            context: nil,
            characters: sentinel,
            charactersIgnoringModifiers: sentinel,
            isARepeat: false,
            keyCode: 0
        )!)
        guard probe.typed == sentinel else {
            throw PaletteSelfCheckError.typingProbeMissedSentinel(sentinel, got: probe.typed)
        }
    }

    private static func runSelectionDoesNotStealNewFocusScenario(
        host: NSWindow,
        hostView: NSView,
        previousProbe: SemanticTypingProbeView,
        newFocusProbe: SemanticTypingProbeView,
        palette: LaunchProfilePalette,
        profiles: [TileSpawner.AnnotatedProfile]
    ) throws {
        guard host.makeFirstResponder(previousProbe), host.firstResponder === previousProbe else {
            throw PaletteSelfCheckError.unexpectedFirstResponder(String(describing: host.firstResponder), expected: "previous probe before selection")
        }
        palette.show(near: host, profiles: profiles, initialQuery: "QA")
        guard paletteRootCount(in: hostView) == 1 else {
            throw PaletteSelfCheckError.unexpectedRootCount(paletteRootCount(in: hostView), expected: 1)
        }
        _ = palette.control(NSSearchField(), textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        guard paletteRootCount(in: hostView) == 0 else {
            throw PaletteSelfCheckError.unexpectedRootCount(paletteRootCount(in: hostView), expected: 0)
        }
        guard host.firstResponder === newFocusProbe else {
            throw PaletteSelfCheckError.unexpectedFirstResponder(String(describing: host.firstResponder), expected: "new selection focus")
        }
    }

    private final class SemanticTypingProbeView: NSView {
        var typed = ""
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            typed += event.charactersIgnoringModifiers ?? ""
        }
    }

    private func ensurePaletteView() -> NSView {
        if let paletteView { return paletteView }

        let content = CommandCenterSurfaceView(frame: NSRect(x: 0, y: 0, width: 660, height: 520))
        content.setAccessibilityIdentifier(Self.rootAccessibilityIdentifier)

        let search = PaletteSearchField()
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false
        search.placeholderString = "Search Array…"
        search.focusRingType = .none
        search.isBezeled = false
        search.drawsBackground = false
        search.font = .systemFont(ofSize: 16, weight: .medium)

        let table = NSTableView()
        table.dataSource = self
        table.delegate = self
        table.headerView = nil
        table.allowsMultipleSelection = false
        table.target = self
        table.doubleAction = #selector(tableDidDoubleClick(_:))
        table.rowHeight = 46
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.title = "Command"
        column.width = 640
        column.resizingMask = .autoresizingMask
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let footer = NSTextField(labelWithString: Self.standardFooter)
        footerLabel = footer
        footer.font = .systemFont(ofSize: 10.5, weight: .medium)
        footer.textColor = .secondaryLabelColor
        footer.alignment = .center
        footer.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(search)
        content.addSubview(scroll)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            search.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            footer.heightAnchor.constraint(equalToConstant: 16)
        ])

        self.paletteView = content
        self.tableView = table
        self.searchField = search
        return content
    }

    private func capturePreviousFirstResponder(in host: NSWindow) {
        guard let responder = semanticRestorableResponder(for: host.firstResponder),
              !isPaletteResponder(responder),
              isRestorable(responder, in: host) else {
            previousFirstResponder = nil
            previousFirstResponderWindow = nil
            return
        }
        previousFirstResponder = responder
        previousFirstResponderWindow = host
    }

    private func semanticRestorableResponder(for responder: NSResponder?) -> NSResponder? {
        guard let responder else { return nil }
        if let fieldEditor = responder as? NSTextView,
           let owner = fieldEditor.delegate as? NSResponder,
           owner !== searchField {
            return owner
        }
        return responder
    }

    private func shouldRestorePreviousFirstResponder(in window: NSWindow?) -> Bool {
        guard let window,
              let responder = previousFirstResponder,
              isRestorable(responder, in: window) else { return false }

        // Do not steal focus back if a successful selection or another app path
        // already moved focus to a non-palette responder. Restore only when the
        // palette still owns focus, or AppKit has cleared it during teardown.
        guard let current = window.firstResponder else { return true }
        return isPaletteResponder(current) || current === responder
    }

    private func isRestorable(_ responder: NSResponder, in window: NSWindow) -> Bool {
        if let view = responder as? NSView {
            return view.window === window && !isDescendantOfPalette(view)
        }
        return responder !== window
    }

    private func isPaletteResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder === searchField || responder === tableView || responder === paletteView {
            return true
        }
        if let fieldEditor = responder as? NSTextView,
           searchField?.currentEditor() === fieldEditor {
            return true
        }
        if let view = responder as? NSView {
            return isDescendantOfPalette(view)
        }
        return false
    }

    private func isDescendantOfPalette(_ view: NSView) -> Bool {
        guard let paletteView else { return false }
        var current: NSView? = view
        while let candidate = current {
            if candidate === paletteView { return true }
            current = candidate.superview
        }
        return false
    }

    private static func profileRow(for item: TileSpawner.AnnotatedProfile) -> LaunchPaletteProfileRow {
        let detail: String
        let isSelectable: Bool
        switch item.resolution {
        case let .found(profile):
            detail = profile.command
            isSelectable = true
        case let .missing(executable):
            detail = "\(executable) not found"
            isSelectable = false
        case let .notConfigured(profileId):
            detail = "\(profileId) not configured"
            isSelectable = false
        }
        return LaunchPaletteProfileRow(
            id: item.spec.id,
            displayName: item.spec.displayName,
            detail: detail,
            isSelectable: isSelectable
        )
    }

    /// One New <Harness> Agent row per CLI, the Settings default first. A
    /// harness that cannot start an agent is listed with the composer's own
    /// refusal wording, never hidden and never swapped for another CLI.
    static func agentHarnessRows(defaults: UserDefaults) -> [AgentHarnessPaletteRow] {
        let defaultHarness = AgentHarnessConfig.resolved(defaults: defaults)
        let ordered = [defaultHarness] + AgentHarness.allCases.filter { $0 != defaultHarness }
        return ordered.map { harness in
            var reason = AgentSupervisor.readinessRefusal(for: harness, retry: "try again")
            if reason == nil, AgentModelConfig.modelOptions(for: harness).isEmpty {
                reason = "\(harness.rawValue) has not offered any model yet."
            }
            return AgentHarnessPaletteRow(harness: harness, isDefault: harness == defaultHarness, unavailableReason: reason)
        }
    }

    /// The model ids `harness` offers, verbatim from that CLI's catalogue.
    private static func availableAgentModels(for harness: AgentHarness) -> [AgentModelPaletteRow] {
        AgentModelConfig.modelOptions(for: harness).map { id in
            let provider = id.split(separator: "/", maxSplits: 1).first.map(String.init) ?? "Provider"
            let providerName: String
            switch provider {
            case "openai-codex": providerName = "OpenAI Codex"
            case "anthropic": providerName = "Anthropic"
            default: providerName = provider.replacingOccurrences(of: "-", with: " ").capitalized
            }
            let fallbackName = fallbackAgentModelName(for: id)
            return AgentModelPaletteRow(
                id: id,
                displayName: AgentModelCatalog.shared.displayName(for: id, harness: harness)
                    ?? AgentModelCatalog.shared.displayName(for: id) ?? fallbackName,
                providerName: "\(providerName) · \(id)",
                harness: harness
            )
        }
    }

    /// The remembered model is stored as `<harness>|<model>`: an id alone cannot
    /// say which CLI it was chosen under.
    static func recentAgentModelMemo(harness: AgentHarness, model: String) -> String {
        "\(harness.rawValue)|\(model)"
    }

    private static func agentModelChoices(
        _ catalog: [AgentModelPaletteRow],
        harness: AgentHarness,
        defaults: UserDefaults
    ) -> [AgentModelPaletteRow] {
        guard !catalog.isEmpty else { return [] }
        // Keyed, not `uniqueKeysWithValues`: the catalogue is a live parse of another
        // process's output, and a repeated id there must not trap the app on ⌘K.
        let byID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let resolvedDefaultID = AgentModelConfig.resolvedFromDefaults(harness: harness, defaults: defaults).model
        let defaultModel = byID[resolvedDefaultID] ?? catalog[0]
        let isSettingsHarness = harness == AgentHarnessConfig.resolved(defaults: defaults)
        var choices = [AgentModelPaletteRow(
            id: defaultModel.id,
            displayName: "Default — \(defaultModel.displayName)",
            providerName: (isSettingsHarness ? "Configured in Settings" : "\(harness.rawValue)'s default") + " · \(defaultModel.id)",
            kind: .configuredDefault,
            harness: harness
        )]
        let memo = defaults.string(forKey: recentAgentModelDefaultsKey)
        let prefix = recentAgentModelMemo(harness: harness, model: "")
        if let memo, memo.hasPrefix(prefix) {
            let recentID = String(memo.dropFirst(prefix.count))
            if recentID != defaultModel.id, let recentModel = byID[recentID] {
                choices.append(AgentModelPaletteRow(
                    id: recentModel.id,
                    displayName: "Recently Used — \(recentModel.displayName)",
                    providerName: "Last successful Cmd+K agent · \(recentModel.id)",
                    kind: .recentlyUsed,
                    harness: harness
                ))
            }
        }
        choices.append(contentsOf: catalog)
        return choices
    }

    private static func fallbackAgentModelName(for id: String) -> String {
        let model = id.split(separator: "/", maxSplits: 1).last.map(String.init) ?? id
        let parts = model.split(separator: "-").map(String.init)
        guard parts.count >= 2, parts[0].lowercased() == "gpt" else {
            return parts.map { $0.capitalized }.joined(separator: " ")
        }
        let variant = parts.dropFirst(2).map { $0.capitalized }.joined(separator: " ")
        return "GPT-\(parts[1])" + (variant.isEmpty ? "" : " \(variant)")
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { displayEntries.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let entry = entry(at: row) else { return nil }
        switch entry {
        case let .section(title):
            return CommandCenterSectionCell(title: title)
        case let .file(file):
            return CommandCenterItemCell(file: file)
        case let .item(item):
            return CommandCenterItemCell(
                item: item,
                shortcut: shortcutAccessory(for: item.row),
                creationPreview: rowUsesFilesystemScope(item.row) ? filesystemCreationPreview : nil
            )
        }
    }

    private func rowUsesFilesystemScope(_ row: LaunchPaletteRow) -> Bool {
        switch row {
        case let .profile(profile): return profile.displayName.lowercased() == "shell"
        case .action(.newManagedAgent), .action(.openFileTree), .agentHarness: return true
        default: return false
        }
    }

    private func shortcutAccessory(for row: LaunchPaletteRow) -> String? {
        if case let .action(action) = row { return Self.registeredShortcutDisplay(for: action) }
        guard case let .profile(profile) = row,
              let index = rootRows.compactMap({ candidate -> LaunchPaletteProfileRow? in
                  if case let .profile(value) = candidate { return value }
                  return nil
              }).firstIndex(where: { $0.id == profile.id }), index < 4 else { return nil }
        return "⌘\(index + 1)"
    }

    /// The binding a registered command gives this row's action, as the user
    /// has it now (Settings › Shortcuts can move or clear it).
    static func registeredShortcutDisplay(for action: LaunchPaletteAction) -> String? {
        guard let registry = try? CommandRegistry.productRegistry(),
              let command = registry.commands.first(where: { $0.paletteAction == action }),
              let shortcut = registry.shortcuts.first(where: { $0.commandID == command.id }) else { return nil }
        return ShortcutBindingStore().gestures(for: shortcut).first?.displayString
    }

    /// Not a group row: AppKit paints a group row with a tinted band and a rule under
    /// it. Headings stay unselectable (`shouldSelectRow`) and sit on the surface.
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .section = entry(at: row) { return CommandCenterSectionCell.height }
        return 46
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .file = entry(at: row) { return true }
        guard case let .item(item) = entry(at: row) else { return false }
        return item.row.isSelectable
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        applyFilter(query: field.stringValue)
    }

    private func applyFilter(query: String) {
        if navigationLevel == .files { applyFileFilter(query: query); return }
        let storedRecentIDs = defaults.stringArray(forKey: Self.recentDefaultsKey) ?? []
        let recentIDs = navigationLevel == .root
            ? LaunchPaletteModel.sanitizeRecentIDs(storedRecentIDs, rows: rows)
            : []
        if navigationLevel == .root, recentIDs != storedRecentIDs {
            defaults.set(recentIDs, forKey: Self.recentDefaultsKey)
        }
        let sections = LaunchPaletteModel.makeSections(rows: rows, query: query, recentIDs: recentIDs)
        displayEntries = sections.flatMap { section -> [CommandCenterDisplayEntry] in
            // Models get ONE HEADER PER PROVIDER instead of a single "Choose Model".
            // pi's catalogue lists 13 anthropic models before the first codex one, so
            // under one header a codex user sees a screen of Claude and no evidence
            // there is anything below — reported twice as "only Anthropic models"
            // when nothing was filtered at all. Provider blocks stay in catalogue
            // order; only the headers are added.
            if section.category == .models {
                let quickItems = section.items.filter { item in
                    guard case let .agentModel(model) = item.row else { return false }
                    return model.kind != .catalog
                }
                let catalogItems = section.items.filter { item in
                    guard case let .agentModel(model) = item.row else { return true }
                    return model.kind == .catalog
                }
                // Several CLIs in one step (plain New Agent…) group by CLI first:
                // Pi runs Anthropic models too, and "ANTHROPIC" alone would not
                // say whether a row starts Claude Code or Pi.
                func harness(of item: CommandCenterItem) -> AgentHarness? {
                    if case let .agentModel(model) = item.row { return model.harness }
                    return nil
                }
                let harnesses = catalogItems.compactMap(harness(of:)).reduce(into: [AgentHarness]()) {
                    if !$0.contains($1) { $0.append($1) }
                }
                var providersByHarness: [AgentHarness: Set<String>] = [:]
                for item in catalogItems {
                    guard let itemHarness = harness(of: item) else { continue }
                    providersByHarness[itemHarness, default: []].insert(ProviderModelGrouping.provider(forID: item.row.agentModelID ?? ""))
                }
                var order: [String] = []
                var byProvider: [String: [CommandCenterItem]] = [:]
                var headers: [String: String] = [:]
                for item in catalogItems {
                    let provider = ProviderModelGrouping.provider(forID: item.row.agentModelID ?? "")
                    var key = provider
                    var header = ProviderModelGrouping.displayName(forProvider: provider)
                    if harnesses.count > 1, let itemHarness = harness(of: item) {
                        key = "\(itemHarness.rawValue)|\(provider)"
                        header = (providersByHarness[itemHarness]?.count ?? 0) > 1
                            ? "\(itemHarness.rawValue) · \(header)"
                            : itemHarness.rawValue
                    }
                    if byProvider[key] == nil { order.append(key); headers[key] = header }
                    byProvider[key, default: []].append(item)
                }
                let quickEntries: [CommandCenterDisplayEntry] = quickItems.isEmpty
                    ? []
                    : [.section("Quick Start")] + quickItems.map(CommandCenterDisplayEntry.item)
                // A single provider keeps the plain header — a lone "ANTHROPIC" over
                // every row it owns is noise, not information.
                if order.count <= 1 {
                    return quickEntries
                        + (catalogItems.isEmpty ? [] : [.section(section.category.rawValue)] + catalogItems.map(CommandCenterDisplayEntry.item))
                }
                return quickEntries + order.flatMap { key in
                    [.section(headers[key] ?? key)]
                        + (byProvider[key] ?? []).map(CommandCenterDisplayEntry.item)
                }
            }
            return [.section(section.category.rawValue)] + section.items.map(CommandCenterDisplayEntry.item)
        }
        filtered = sections.flatMap(\.items).map(\.row)
        tableView?.reloadData()
        if let first = displayEntries.indices.first(where: { index in
            guard case let .item(item) = displayEntries[index] else { return false }
            return item.row.isSelectable
        }) {
            tableView?.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
        } else {
            tableView?.deselectAll(nil)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commitSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            navigateBackOrClose()
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        default:
            return false
        }
    }

    @objc private func tableDidDoubleClick(_ sender: Any?) {
        commitSelection()
    }

    private func commitSelection() {
        guard let table = tableView else { return }
        let row = table.selectedRow
        if navigationLevel == .files { commitFile(.openBesideAgent); return }
        guard case let .item(presented) = entry(at: row) else { return }
        let selected = presented.row
        if navigationLevel == .root, selected == .action(.openFile), onSearchFiles != nil {
            enterFileStep()
            return
        }
        if navigationLevel == .root, selected == .action(.newManagedAgent) {
            enterAgentModelStep(harnesses: Self.plainAgentHarnesses(defaults: defaults), parent: selected)
            return
        }
        if navigationLevel == .root, case let .agentHarness(harnessRow) = selected {
            guard harnessRow.isSelectable else {
                NSSound.beep()
                return
            }
            enterAgentModelStep(harness: harnessRow.harness, parent: selected)
            return
        }
        switch selected {
        case let .profile(profile):
            guard profile.isSelectable else {
                NSSound.beep()
                return
            }
            let succeeded = onSelectProfile?(profile.id) ?? false
            recordRecent(selected, succeeded: succeeded)
            close(restoreFocus: true)
        case let .agentModel(model):
            let harness = model.harness ?? AgentHarnessConfig.resolved(defaults: defaults)
            let succeeded = onSelectAgentModel?(harness, model.id) ?? false
            if succeeded {
                defaults.set(Self.recentAgentModelMemo(harness: harness, model: model.id), forKey: Self.recentAgentModelDefaultsKey)
            }
            recordRecent(agentModelParent, succeeded: succeeded)
            close(restoreFocus: true)
        case .agentHarness:
            // Only reachable from the model step's root, handled above.
            NSSound.beep()
        case let .action(action):
            let succeeded = onSelectAction?(action) ?? false
            recordRecent(selected, succeeded: succeeded)
            close(restoreFocus: true)
        case let .project(project):
            guard project.isSelectable else {
                NSSound.beep()
                return
            }
            let succeeded = onSelectAction?(.addProjectToCanvas(project.id)) ?? false
            recordRecent(selected, succeeded: succeeded)
            close(restoreFocus: true)
        case let .workspace(workspace):
            guard !workspace.projectIds.isEmpty else {
                NSSound.beep()
                return
            }
            let succeeded = onSelectAction?(.switchWorkspace(workspace.id)) ?? false
            recordRecent(selected, succeeded: succeeded)
            close(restoreFocus: true)
        case let .workspaceAction(action, _):
            let succeeded = onSelectAction?(action) ?? false
            recordRecent(selected, succeeded: succeeded)
            close(restoreFocus: true)
        case let .jumpToTile(tile):
            let succeeded = onSelectAction?(.jumpToTile(tile.id)) ?? false
            recordRecent(selected, succeeded: succeeded)
            close(restoreFocus: true)
        case let .jumpToZone(zone):
            let succeeded = onSelectAction?(.jumpToZone(zone.id)) ?? false
            recordRecent(selected, succeeded: succeeded)
            close(restoreFocus: true)
        case let .tilelessAgent(agent):
            // Deliberately NOT recorded as a recent: reopening makes the agent
            // no longer closed, so a "History" recent would point at a row that
            // has left the section. `presentation` marks it unsafe-for-recent for
            // the same reason; this mirrors it at the dispatch site.
            _ = onOpenTilelessAgent?(agent.agentId) ?? false
            close(restoreFocus: true)
        }
    }

    /// Plain New Agent…'s CLIs: the Settings default, then every other CLI that
    /// can run now. It used to be the default alone, so a GPT model under a
    /// Claude default meant making a Claude tile and switching its provider.
    private static func plainAgentHarnesses(defaults: UserDefaults) -> [AgentHarness] {
        let defaultHarness = AgentHarnessConfig.resolved(defaults: defaults)
        return [defaultHarness] + AgentHarness.allCases.filter { harness in
            harness != defaultHarness
                && AgentSupervisor.readinessRefusal(for: harness, retry: "try again") == nil
                && !AgentModelConfig.modelOptions(for: harness).isEmpty
        }
    }

    private func enterAgentModelStep(harness: AgentHarness, parent: LaunchPaletteRow) {
        enterAgentModelStep(harnesses: [harness], parent: parent)
    }

    /// The model step. Every row carries its harness, so the dispatch can never
    /// land on another CLI. Each CLI's Default (and Recently Used) leads, the
    /// first CLI's first, so Return starts the first CLI's default; the
    /// catalogues follow in the same CLI order.
    private func enterAgentModelStep(harnesses: [AgentHarness], parent: LaunchPaletteRow) {
        var quickStart: [AgentModelPaletteRow] = []
        var catalogues: [AgentModelPaletteRow] = []
        // The QA override stands in for one CLI's catalogue, so it serves only the first.
        for harness in agentModelOverride == nil ? harnesses : Array(harnesses.prefix(1)) {
            let catalog = agentModelOverride.map { rows in
                rows.map { AgentModelPaletteRow(id: $0.id, displayName: $0.displayName, providerName: $0.providerName, kind: $0.kind, harness: harness) }
            } ?? Self.availableAgentModels(for: harness)
            let choices = Self.agentModelChoices(catalog, harness: harness, defaults: defaults)
            quickStart += choices.filter { $0.kind != .catalog }
            catalogues += choices.filter { $0.kind == .catalog }
        }
        agentModelRows = (quickStart + catalogues).map(LaunchPaletteRow.agentModel)
        agentModelParent = parent
        guard !agentModelRows.isEmpty, let searchField else {
            NSSound.beep()
            return
        }
        rootQuery = searchField.stringValue
        navigationLevel = .agentModels
        rows = agentModelRows
        searchField.placeholderString = "Choose a model…"
        searchField.stringValue = ""
        applyFilter(query: "")
    }

    private func isSelectableEntry(_ entry: CommandCenterDisplayEntry) -> Bool {
        switch entry {
        case let .item(item): return item.row.isSelectable
        case .file: return true
        case .section: return false
        }
    }

    /// The Open file step: a search over the project's files with the files agents made
    /// and the recent ones resting under an empty query.
    private func enterFileStep() {
        guard let searchField else { return }
        rootQuery = searchField.stringValue
        navigationLevel = .files
        searchField.placeholderString = "Open a file…"
        searchField.stringValue = ""
        footerLabel?.stringValue = Self.fileFooter
        applyFilter(query: "")
        resizeForEntries()
    }

    private func applyFileFilter(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            fileSearchToken += 1
            fileSearchPending = false
            deferredFileAction = nil
            let sections = (onFileSections?() ?? []).filter { !$0.rows.isEmpty }
            displayEntries = sections.flatMap { [CommandCenterDisplayEntry.section($0.title)] + $0.rows.map(CommandCenterDisplayEntry.file) }
            reloadFileEntries(emptyText: "Type to search every file in this project.")
            return
        }
        fileSearchToken += 1
        let token = fileSearchToken
        fileSearchPending = true
        onSearchFiles?(trimmed) { [weak self] rows in
            guard let self, self.navigationLevel == .files, token == self.fileSearchToken else { return }
            self.fileSearchPending = false
            self.fileSearchResults = rows
            self.displayEntries = rows.isEmpty ? [] : [.section("Files")] + rows.map(CommandCenterDisplayEntry.file)
            self.reloadFileEntries(emptyText: "No files match “\(trimmed)”")
            if let action = self.deferredFileAction { self.deferredFileAction = nil; self.commitFile(action) }
        }
    }

    private func reloadFileEntries(emptyText: String) {
        tableView?.reloadData()
        showFileEmptyState(displayEntries.isEmpty ? emptyText : nil)
        if let first = displayEntries.indices.first(where: { if case .file = displayEntries[$0] { return true }; return false }) {
            tableView?.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
        } else {
            tableView?.deselectAll(nil)
        }
        resizeForEntries()
    }

    /// The words standing in an empty list: centred in the list area, in the footer's own type.
    private func showFileEmptyState(_ text: String?) {
        if fileEmptyLabel == nil, let scroll = tableView?.enclosingScrollView, let host = scroll.superview {
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 10.5, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.leadingAnchor, constant: 14),
            ])
            fileEmptyLabel = label
        }
        fileEmptyLabel?.stringValue = text ?? ""
        fileEmptyLabel?.isHidden = text == nil
    }

    var fileEmptyTextForQA: String? { fileEmptyLabel.flatMap { $0.isHidden ? nil : $0.stringValue } }

    /// Grow or shrink the surface to its rows, as `show` sizes it.
    private func resizeForEntries() {
        guard let paletteView, let host = paletteView.superview else { return }
        // The list is exactly its rows (the table knows where its last row ends), so the gap
        // above the footer is the same for one row as for many. 86 = search field, the gaps
        // around the list, and the footer.
        let rowsBottom = displayEntries.isEmpty ? 0 : (tableView?.rect(ofRow: displayEntries.count - 1).maxY ?? 0)
        let contentHeight = CGFloat(86) + (displayEntries.isEmpty ? 2 * CommandCenterItemCell.rowHeight : rowsBottom)
        let height = min(520, contentHeight, max(0, host.bounds.height - 32))
        let top = paletteView.frame.maxY
        paletteView.frame = NSRect(x: paletteView.frame.minX, y: top - height, width: paletteView.frame.width, height: height)
        paletteView.layoutSubtreeIfNeeded()
        tableView?.sizeLastColumnToFit()
    }

    private func commitFile(_ action: PaletteFileAction) {
        if fileSearchPending { deferredFileAction = action; return }
        guard navigationLevel == .files, let table = tableView, case let .file(file) = entry(at: table.selectedRow) else {
            NSSound.beep()
            return
        }
        let succeeded = onOpenFile?(file, action) ?? false
        if succeeded { recordRecentFile(file) }
        close(restoreFocus: true)
    }

    /// Recent files, newest first, as `timestamp|path`.
    private func recordRecentFile(_ file: PaletteFileRow) {
        guard let path = file.absolutePath else { return }
        var stored = (defaults.stringArray(forKey: Self.recentFilesDefaultsKey) ?? []).filter { !$0.hasSuffix("|" + path) }
        stored.insert("\(Int(Date().timeIntervalSince1970))|\(path)", at: 0)
        defaults.set(Array(stored.prefix(12)), forKey: Self.recentFilesDefaultsKey)
    }

    /// The recent files the app asks for, newest first.
    func recentFiles(limit: Int = 6) -> [(path: String, openedAt: Date)] {
        (defaults.stringArray(forKey: Self.recentFilesDefaultsKey) ?? []).prefix(limit).compactMap { entry in
            guard let bar = entry.firstIndex(of: "|"), let stamp = TimeInterval(entry[..<bar]) else { return nil }
            return (String(entry[entry.index(after: bar)...]), Date(timeIntervalSince1970: stamp))
        }
    }

    private func navigateBackOrClose() {
        guard navigationLevel != .root, let searchField else {
            close(restoreFocus: true)
            return
        }
        fileSearchToken += 1
        fileSearchPending = false
        deferredFileAction = nil
        fileEmptyLabel?.isHidden = true
        footerLabel?.stringValue = Self.standardFooter
        navigationLevel = .root
        rows = rootRows
        searchField.placeholderString = "Search Array…"
        searchField.stringValue = rootQuery
        applyFilter(query: rootQuery)
    }

    private func moveSelection(by delta: Int) {
        guard let table = tableView else { return }
        guard !displayEntries.isEmpty else { return }
        var next = table.selectedRow
        if next < 0 { next = delta > 0 ? -1 : displayEntries.count }
        repeat {
            next += delta
            guard displayEntries.indices.contains(next) else { return }
            if isSelectableEntry(displayEntries[next]) {
                table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
                table.scrollRowToVisible(next)
                return
            }
        } while displayEntries.indices.contains(next)
    }

    private func entry(at index: Int) -> CommandCenterDisplayEntry? {
        guard displayEntries.indices.contains(index) else { return nil }
        return displayEntries[index]
    }

    private func recordRecent(_ row: LaunchPaletteRow, succeeded: Bool) {
        let existing = defaults.stringArray(forKey: Self.recentDefaultsKey) ?? []
        let updated = LaunchPaletteModel.recordingRecent(row, in: existing, succeeded: succeeded)
        if updated != existing { defaults.set(updated, forKey: Self.recentDefaultsKey) }
    }
}

private enum CommandCenterDisplayEntry {
    /// A header's TITLE, not its category: the model step splits one `.models`
    /// section into one header per provider, so the text cannot be derived from
    /// the fixed category enum (.plans/10-command-center-absorbs-sidebar.md).
    case section(String)
    case item(CommandCenterItem)
    case file(PaletteFileRow)

    var isSection: Bool {
        if case .section = self { return true }
        return false
    }
}

/// The palette's search field. While its text editor is active AppKit lays the text over
/// the magnifier of a borderless field; the cell's own text rect starts after the icon
/// and ends before the clear button, and the editor is given that rect.
final class PaletteSearchField: NSSearchField {
    private final class Cell: NSSearchFieldCell {
        private func textBounds(_ rect: NSRect) -> NSRect {
            let left = searchButtonRect(forBounds: rect).maxX + 6
            let right = cancelButtonRect(forBounds: rect).minX - 6
            return NSRect(x: left, y: rect.minY, width: max(0, right - left), height: rect.height)
        }
        override func searchTextRect(forBounds rect: NSRect) -> NSRect { textBounds(rect) }
        override func drawingRect(forBounds rect: NSRect) -> NSRect { textBounds(rect) }
        override func titleRect(forBounds rect: NSRect) -> NSRect { textBounds(rect) }
        override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
            super.edit(withFrame: textBounds(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
        }
        override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
            super.select(withFrame: textBounds(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
        }
    }
    override class var cellClass: AnyClass? {
        get { Cell.self }
        set {}
    }
}

final class CommandCenterSurfaceView: NSView, CornerStyled {
    struct AppearanceSnapshot: Equatable {
        let usesBlur: Bool
        let opacity: Double
    }

    private let effect = NSVisualEffectView()
    private let tint = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = CGFloat(LineWidth.hairline)
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.24
        layer?.shadowRadius = 24
        layer?.shadowOffset = NSSize(width: 0, height: -8)

        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        effect.frame = bounds
        addSubview(effect)

        tint.wantsLayer = true
        tint.layer?.cornerRadius = 14
        tint.layer?.masksToBounds = true
        tint.autoresizingMask = [.width, .height]
        tint.frame = bounds
        addSubview(tint)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        applyAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func accessibilityDisplayOptionsChanged(_ notification: Notification) {
        applyAppearance()
    }

    private func applyAppearance() {
        let defaults = UserDefaults.standard
        let resolved = CommandCenterAppearanceConfig.resolve(
            glassinessRaw: defaults.string(forKey: CommandCenterAppearanceConfig.glassinessKey),
            customOpacityRaw: defaults.object(forKey: CommandCenterAppearanceConfig.customOpacityKey).map { String(describing: $0) },
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
        // Corner style (Settings › Appearance): the palette is a modal surface.
        for layer in [layer, effect.layer, tint.layer] { layer?.applyCorner(.modal) }
        effect.isHidden = !resolved.usesBlur
        tint.layer?.backgroundColor = SurfaceToken.overlay.color.cgColor(for: effectiveTokenTheme).copy(alpha: resolved.backgroundOpacity)
        layer?.borderColor = LineToken.separator.color.cgColor(for: effectiveTokenTheme)
    }

    func reapplyAppearanceForQA() { applyAppearance() }

    func applyCornerStyle() { applyAppearance() }

    var appearanceSnapshotForQA: AppearanceSnapshot {
        let alpha = tint.layer?.backgroundColor?.alpha ?? 0
        return AppearanceSnapshot(usesBlur: !effect.isHidden, opacity: Double((alpha * 100).rounded() / 100))
    }

    var backgroundColorForQA: String {
        guard let color = tint.layer?.backgroundColor,
              let converted = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return "nil" }
        return String(format: "%.4f,%.4f,%.4f,%.4f", converted.redComponent, converted.greenComponent, converted.blueComponent, converted.alphaComponent)
    }
}

final class CommandCenterSectionCell: NSTableCellView {
    /// A section heading takes the quiet secondary label the sidebar's own headings
    /// use (`SidebarSectionLabelView`): sentence case, no tint band, no rule, and
    /// the same left edge as the row titles below it.
    static let height: CGFloat = 28
    /// The row icon's left edge: the 14pt glyph sits centred in its 18pt box at x 14.
    static let leadingInset: CGFloat = 16

    private let label = NSTextField(labelWithString: "")

    init(title: String) {
        super.init(frame: .zero)
        label.stringValue = Self.displayTitle(title)
        label.font = .token(.label)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
        applyColour()
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColour()
    }

    private func applyColour() { label.textColor = TextToken.textSecondary.color.nsColor(in: self) }

    /// The built-in categories are Title Case in the model ("Agents & Tiles"); every
    /// other heading (a provider, a CLI, "Made by agents") is already as it should read.
    static func displayTitle(_ title: String) -> String {
        guard CommandCenterCategory(rawValue: title) != nil else { return title }
        let words = title.split(separator: " ", omittingEmptySubsequences: false)
        return words.enumerated().map { index, word in
            index == 0 ? String(word) : word.first?.isLetter == true ? word.lowercased() : String(word)
        }.joined(separator: " ")
    }
}

/// One file in the Open file step. The row the @ menu draws for a file: name over its
/// folder, the folder ending in "/", a kind icon; plus what ⌘K adds: the characters the
/// query matched, and who made it and how long ago.
struct PaletteFileRow {
    var path: String
    /// Offsets into the whole relative path, as `AgentCompletion.matchedPathIndices` gives them.
    /// The list does not draw them (neither reference does); the data stays for the ranking witness.
    var matched: [Int] = []
    var agent: AgentIdentityChipView.Identity?
    var age: String?
    /// Where the file is on disk; `path` is what the row shows (relative to the project when it is inside it).
    var absolutePath: String?

    /// The project's name: what stands under a file that sits at the project root.
    var projectName: String?

    var name: String { (path as NSString).lastPathComponent }
    /// Under the name: the folder with a trailing "/", or the project's name at the root.
    var folder: String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty || parent == "." ? (projectName ?? "./") : parent + "/"
    }
}

final class CommandCenterItemCell: NSTableCellView {
    static let rowHeight: CGFloat = 46
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private var file: PaletteFileRow?
    private var accessory: NSView?
    private var ageLabel: NSTextField?

    init(item: CommandCenterItem, shortcut: String? = nil, creationPreview: String? = nil) {
        super.init(frame: .zero)
        let combinedSubtitle = [item.subtitle, creationPreview].compactMap { $0 }.joined(separator: " · ")
        let shortcutLabel = NSTextField(labelWithString: shortcut ?? "")
        shortcutLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.alignment = .right
        shortcutLabel.isHidden = shortcut == nil
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        build(symbol: item.iconSystemName, selectable: item.row.isSelectable, trailing: shortcutLabel, trailingMinWidth: 34)
        titleField.stringValue = item.title
        titleField.textColor = item.row.isSelectable ? .labelColor : .tertiaryLabelColor
        subtitleField.stringValue = combinedSubtitle
        subtitleField.isHidden = combinedSubtitle.isEmpty
        setAccessibilityLabel(item.title)
        if !combinedSubtitle.isEmpty { setAccessibilityHelp(combinedSubtitle) }
    }

    /// A plain row: used by design stills and previews that have no `CommandCenterItem`.
    convenience init(symbol: String, title: String, subtitle: String?, shortcut: String?) {
        self.init(item: CommandCenterItem(
            row: .action(.newNote), category: .actions, title: title, subtitle: subtitle,
            iconSystemName: symbol, aliases: [], isDefaultVisible: true, isSafeRecent: false, stableID: "plain:\(title)"), shortcut: shortcut)
    }

    /// A file in the Open file step. `accessory` is the agent identity when an agent made it.
    init(file: PaletteFileRow) {
        self.file = file
        super.init(frame: .zero)
        // The age is one right-aligned column; an agent's chip (plate at its leading edge, then
        // the name) sits in its own fixed column to the left of it, so plates line up.
        let ageLabel = NSTextField(labelWithString: file.age ?? "")
        ageLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        ageLabel.textColor = .secondaryLabelColor
        ageLabel.alignment = .right
        ageLabel.translatesAutoresizingMaskIntoConstraints = false
        ageLabel.widthAnchor.constraint(equalToConstant: 56).isActive = true
        self.ageLabel = ageLabel
        let trailing: NSView
        if let agent = file.agent {
            let chip = AgentIdentityChipView(frame: .zero)
            chip.configure(agent, age: file.age ?? "")
            accessory = chip
            let row = NSStackView(views: [chip, ageLabel])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 0
            trailing = row
        } else {
            trailing = ageLabel
        }
        trailing.translatesAutoresizingMaskIntoConstraints = false
        build(symbol: FileKindIcon.symbol(forPath: file.path), selectable: true, trailing: trailing, trailingMinWidth: 0)
        refreshFileText()
        let who = file.agent.map { ", made by \($0.name)" } ?? ""
        setAccessibilityLabel(file.name + who)
        setAccessibilityHelp(file.folder)
    }

    required init?(coder: NSCoder) { nil }

    /// The metrics every command-center row shares: icon 14pt in an 18pt box at 14,
    /// text at 42, name 13.5 medium over a 11.5 line, 14pt trailing inset.
    private func build(symbol: String, selectable: Bool, trailing: NSView, trailingMinWidth: CGFloat) {
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.contentTintColor = selectable ? .labelColor : .tertiaryLabelColor
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        image.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .systemFont(ofSize: 13.5, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail
        subtitleField.font = .systemFont(ofSize: 11.5)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingMiddle

        let stack = NSStackView(views: [titleField, subtitleField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        addSubview(stack)
        addSubview(trailing)
        var constraints = [
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            image.heightAnchor.constraint(equalToConstant: 18),
            stack.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -10),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ]
        if trailingMinWidth > 0 { constraints.append(trailing.widthAnchor.constraint(greaterThanOrEqualToConstant: trailingMinWidth)) }
        NSLayoutConstraint.activate(constraints)
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            guard backgroundStyle != oldValue, file != nil else { return }
            refreshFileText()
            (accessory as? AgentIdentityChipView)?.isEmphasized = backgroundStyle == .emphasized
        }
    }

    /// The name and folder in the row's own weights. Selected rows take the selection's
    /// contrast colour, as every other palette row's text does.
    private func refreshFileText() {
        guard let file else { return }
        let emphasized = backgroundStyle == .emphasized
        titleField.stringValue = file.name
        subtitleField.stringValue = file.folder
        titleField.textColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
        subtitleField.textColor = emphasized ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
        ageLabel?.textColor = emphasized ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
    }
}

// MARK: - Design reference

extension LaunchProfilePalette {
    /// DESIGN ONLY: the real palette on its Open file step, headless, fed fixture rows,
    /// so the stills show the production view rather than a copy of it.
    static func designFileStep(host: NSWindow, query: String, sections: [(title: String, rows: [PaletteFileRow])], results: [PaletteFileRow]) -> NSView? {
        let suite = "continuum.design.palette-files.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return nil }
        defer { defaults.removePersistentDomain(forName: suite) }
        let palette = LaunchProfilePalette(defaults: defaults)
        palette.onSearchFiles = { _, deliver in deliver(results) }
        palette.onFileSections = { sections }
        palette.show(near: host, profiles: [])
        palette.enterFileStep()
        if !query.isEmpty { palette.typeForQA(query) }
        guard let view = palette.paletteView else { return nil }
        objc_setAssociatedObject(view, "palette", palette, .OBJC_ASSOCIATION_RETAIN)
        return view
    }

    /// DESIGN ONLY: the real palette on its agent → model step, headless, so a new
    /// step can be put beside it at the same state. Nothing in the app calls this.
    static func designReferenceModelStep(host: NSWindow, query: String) -> NSView? {
        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.claude)
        AgentModelCatalog.shared.resetForQA(snapshot: AgentCatalogQAFixture.codex)
        let suite = "continuum.design.palette-reference.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return nil }
        defer { defaults.removePersistentDomain(forName: suite) }
        let palette = LaunchProfilePalette(defaults: defaults)
        palette.show(near: host, profiles: [])
        palette.enterAgentModelStep(harnesses: [.claudeCode, .codex], parent: .action(.newManagedAgent))
        if !query.isEmpty {
            palette.searchField?.stringValue = query
            palette.applyFilter(query: query)
        }
        guard let view = palette.paletteView else { return nil }
        objc_setAssociatedObject(view, "palette", palette, .OBJC_ASSOCIATION_RETAIN)
        let rows = palette.displayEntries.reduce(CGFloat.zero) { $0 + ($1.isSection ? CommandCenterSectionCell.height : 46) }
        view.frame.size.height = min(520, max(220, 92 + rows))
        return view
    }
}
