import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

@MainActor
final class LaunchProfilePalette: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    /// Returns true only when the app accepted/completed the selection far
    /// enough for it to be a truthful recent destination.
    var onSelectProfile: ((String) -> Bool)?
    var onSelectAgentModel: ((String) -> Bool)?
    var onSelectAction: ((LaunchPaletteAction) -> Bool)?
    /// Bring a closed agent back. Separate from `onSelectAction` because the row
    /// already carries the dispatch identity and the agent id is not a tile id —
    /// a closed agent has no tile, which is the whole reason this row exists.
    var onOpenTilelessAgent: ((UUID) -> Bool)?
    var onClose: (() -> Void)?

    static let rootAccessibilityIdentifier = "ContinuumLaunchProfilePaletteRoot"

    private var paletteView: NSView?
    private var tableView: NSTableView?
    private var searchField: NSTextField?

    private var rows: [LaunchPaletteRow] = []
    private var rootRows: [LaunchPaletteRow] = []
    private var rootQuery = ""
    private var agentModelRows: [LaunchPaletteRow] = []
    private var filtered: [LaunchPaletteRow] = []
    private var displayEntries: [CommandCenterDisplayEntry] = []
    private weak var previousFirstResponder: NSResponder?
    private weak var previousFirstResponderWindow: NSWindow?

    private enum NavigationLevel {
        case root
        case agentModels
    }

    private var navigationLevel = NavigationLevel.root

    private static let recentDefaultsKey = "continuum.commandCenter.recentIDs"
    private static let recentAgentModelDefaultsKey = "continuum.commandCenter.recentAgentModelID"

    func show(near host: NSWindow, profiles: [TileSpawner.AnnotatedProfile], projects: [ProjectPickerRow] = [], workspaces: [WorkspaceEntry] = [], contextualActions: [LaunchPaletteAction] = [], harnessRoles: [HarnessRole] = [], jumpTiles: [JumpTileRow] = [], jumpZones: [JumpZoneRow] = [], tilelessAgents: [TilelessAgentPaletteRow] = [], initialQuery: String = "", agentModels: [AgentModelPaletteRow]? = nil) {
        rootRows = LaunchPaletteModel.makeRows(profiles: profiles.map(Self.profileRow(for:)), projects: projects, workspaces: workspaces, contextualActions: contextualActions, harnessRoles: harnessRoles, jumpTiles: jumpTiles, jumpZones: jumpZones, tilelessAgents: tilelessAgents)
        rows = rootRows
        rootQuery = initialQuery
        navigationLevel = .root
        let catalogModels = agentModels ?? Self.availableAgentModels()
        agentModelRows = Self.agentModelChoices(catalogModels, defaults: .standard)
            .map(LaunchPaletteRow.agentModel)
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
        let contentHeight = CGFloat(64) + displayEntries.reduce(CGFloat.zero) { total, entry in
            total + (entry.isSection ? 24 : 46)
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
        host.makeFirstResponder(searchField)
    }

    func close() {
        close(restoreFocus: true)
    }

    @discardableResult
    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard isVisible, event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
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
        rootQuery = ""
        navigationLevel = .root
        filtered.removeAll()
        displayEntries.removeAll()
        onClose?()
    }

    var isVisible: Bool { paletteView?.superview != nil }

    var searchTextForQA: String { searchField?.stringValue ?? "" }
    var isChoosingAgentModelForQA: Bool { navigationLevel == .agentModels }
    var filteredDisplayNamesForQA: [String] { filtered.map(\.displayName) }

    var selectedDisplayNameForQA: String? {
        guard let tableView, case let .item(item) = entry(at: tableView.selectedRow) else { return nil }
        switch item.row {
        case let .action(action): return action.displayName
        case let .profile(profile): return profile.displayName
        case let .agentModel(model): return model.displayName
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
        let defaults = UserDefaults.standard
        let previousRecents = defaults.object(forKey: recentDefaultsKey)
        let previousGlassiness = defaults.object(forKey: CommandCenterAppearanceConfig.glassinessKey)
        let previousCustomOpacity = defaults.object(forKey: CommandCenterAppearanceConfig.customOpacityKey)
        let previousAgentModel = defaults.object(forKey: AgentModelConfig.modelKey)
        let previousRecentAgentModel = defaults.object(forKey: recentAgentModelDefaultsKey)
        defaults.removeObject(forKey: recentDefaultsKey)
        defaults.set("openai-codex/gpt-5.6-sol", forKey: AgentModelConfig.modelKey)
        defaults.removeObject(forKey: recentAgentModelDefaultsKey)
        defer {
            if let previousRecents { defaults.set(previousRecents, forKey: recentDefaultsKey) }
            else { defaults.removeObject(forKey: recentDefaultsKey) }
            if let previousGlassiness { defaults.set(previousGlassiness, forKey: CommandCenterAppearanceConfig.glassinessKey) }
            else { defaults.removeObject(forKey: CommandCenterAppearanceConfig.glassinessKey) }
            if let previousCustomOpacity { defaults.set(previousCustomOpacity, forKey: CommandCenterAppearanceConfig.customOpacityKey) }
            else { defaults.removeObject(forKey: CommandCenterAppearanceConfig.customOpacityKey) }
            if let previousAgentModel { defaults.set(previousAgentModel, forKey: AgentModelConfig.modelKey) }
            else { defaults.removeObject(forKey: AgentModelConfig.modelKey) }
            if let previousRecentAgentModel { defaults.set(previousRecentAgentModel, forKey: recentAgentModelDefaultsKey) }
            else { defaults.removeObject(forKey: recentAgentModelDefaultsKey) }
        }
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        let hostView = NSView(frame: host.contentRect(forFrameRect: host.frame))
        host.contentView = hostView
        let palette = LaunchProfilePalette()
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
        defaults.set(CommandCenterGlassiness.solid.rawValue, forKey: CommandCenterAppearanceConfig.glassinessKey)
        surface.reapplyAppearanceForQA()
        guard surface.appearanceSnapshotForQA == .init(usesBlur: false, opacity: 1) else {
            throw PaletteSelfCheckError.failed("Solid did not produce an opaque, blur-free command center")
        }
        defaults.set(CommandCenterGlassiness.frosted.rawValue, forKey: CommandCenterAppearanceConfig.glassinessKey)
        surface.reapplyAppearanceForQA()
        guard surface.appearanceSnapshotForQA == .init(usesBlur: true, opacity: 0.84) else {
            throw PaletteSelfCheckError.failed("Frosted did not produce the 84% default command center")
        }
        defaults.set(CommandCenterGlassiness.glass.rawValue, forKey: CommandCenterAppearanceConfig.glassinessKey)
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
        defaults.removeObject(forKey: CommandCenterAppearanceConfig.glassinessKey)
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
        palette.onSelectAgentModel = { _ in false }
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
        palette.onSelectAgentModel = { modelID in
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
              defaults.string(forKey: recentAgentModelDefaultsKey) == "openai-codex/gpt-5.6-luna" else {
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
        palette.show(near: host, profiles: profiles)
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

        let search = NSSearchField()
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
        table.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        content.addSubview(search)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            search.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
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

    private static func availableAgentModels() -> [AgentModelPaletteRow] {
        AgentModelConfig.modelOptions.map { id in
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
                displayName: AgentModelCatalog.shared.displayName(for: id) ?? fallbackName,
                providerName: "\(providerName) · \(id)"
            )
        }
    }

    private static func agentModelChoices(
        _ catalog: [AgentModelPaletteRow],
        defaults: UserDefaults
    ) -> [AgentModelPaletteRow] {
        guard !catalog.isEmpty else { return [] }
        // Keyed, not `uniqueKeysWithValues`: the catalogue is a live parse of another
        // process's output, and a repeated id there must not trap the app on ⌘K.
        let byID = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let resolvedDefaultID = AgentModelConfig.resolvedFromDefaults(defaults: defaults).model
        let defaultModel = byID[resolvedDefaultID] ?? catalog[0]
        var choices = [AgentModelPaletteRow(
            id: defaultModel.id,
            displayName: "Default — \(defaultModel.displayName)",
            providerName: "Configured in Settings · \(defaultModel.id)",
            kind: .configuredDefault
        )]
        if let recentID = defaults.string(forKey: recentAgentModelDefaultsKey),
           recentID != defaultModel.id,
           let recentModel = byID[recentID] {
            choices.append(AgentModelPaletteRow(
                id: recentModel.id,
                displayName: "Recently Used — \(recentModel.displayName)",
                providerName: "Last successful Cmd+K agent · \(recentModel.id)",
                kind: .recentlyUsed
            ))
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
        case let .item(item):
            return CommandCenterItemCell(item: item)
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .section = entry(at: row) { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .section = entry(at: row) { return 24 }
        return 46
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard case let .item(item) = entry(at: row) else { return false }
        return item.row.isSelectable
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        applyFilter(query: field.stringValue)
    }

    private func applyFilter(query: String) {
        let defaults = UserDefaults.standard
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
                var order: [String] = []
                var byProvider: [String: [CommandCenterItem]] = [:]
                for item in catalogItems {
                    let provider = ProviderModelGrouping.provider(forID: item.row.agentModelID ?? "")
                    if byProvider[provider] == nil { order.append(provider) }
                    byProvider[provider, default: []].append(item)
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
                return quickEntries + order.flatMap { provider in
                    [.section(ProviderModelGrouping.displayName(forProvider: provider))]
                        + (byProvider[provider] ?? []).map(CommandCenterDisplayEntry.item)
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
        guard case let .item(presented) = entry(at: row) else { return }
        let selected = presented.row
        if navigationLevel == .root, selected == .action(.newManagedAgent) {
            enterAgentModelStep()
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
            let succeeded = onSelectAgentModel?(model.id) ?? false
            if succeeded { UserDefaults.standard.set(model.id, forKey: Self.recentAgentModelDefaultsKey) }
            recordRecent(.action(.newManagedAgent), succeeded: succeeded)
            close(restoreFocus: true)
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

    private func enterAgentModelStep() {
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

    private func navigateBackOrClose() {
        guard navigationLevel == .agentModels, let searchField else {
            close(restoreFocus: true)
            return
        }
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
            if case let .item(item) = displayEntries[next], item.row.isSelectable {
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
        let defaults = UserDefaults.standard
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

    var isSection: Bool {
        if case .section = self { return true }
        return false
    }
}

private final class CommandCenterSurfaceView: NSView {
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
        layer?.borderWidth = 0.5
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
        effect.isHidden = !resolved.usesBlur
        tint.layer?.backgroundColor = SurfaceToken.overlay.color.cgColor(for: effectiveTokenTheme).copy(alpha: resolved.backgroundOpacity)
        layer?.borderColor = LineToken.separator.color.cgColor(for: effectiveTokenTheme)
    }

    func reapplyAppearanceForQA() { applyAppearance() }

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

private final class CommandCenterSectionCell: NSTableCellView {
    init(title: String) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 42),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

private final class CommandCenterItemCell: NSTableCellView {
    init(item: CommandCenterItem) {
        super.init(frame: .zero)
        let image = NSImageView(image: NSImage(systemSymbolName: item.iconSystemName, accessibilityDescription: nil) ?? NSImage())
        image.contentTintColor = item.row.isSelectable ? .labelColor : .tertiaryLabelColor
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        image.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 13.5, weight: .medium)
        title.textColor = item.row.isSelectable ? .labelColor : .tertiaryLabelColor
        title.lineBreakMode = .byTruncatingTail

        let subtitle = NSTextField(labelWithString: item.subtitle ?? "")
        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.isHidden = item.subtitle == nil

        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        addSubview(stack)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            image.heightAnchor.constraint(equalToConstant: 18),
            stack.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityLabel(item.title)
        if let detail = item.subtitle { setAccessibilityHelp(detail) }
    }

    required init?(coder: NSCoder) { nil }
}
