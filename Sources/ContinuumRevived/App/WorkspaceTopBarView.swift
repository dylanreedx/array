import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

@MainActor
struct WorkspaceTopBarModel: Equatable {
    var currentWorkspaceId: UUID
    var currentWorkspaceName: String
    var projectCount: Int
    var zoneCount: Int
    var saveState: WorkspaceDocumentSaveState
    var workspaces: [WorkspaceEntry]
    var managementMessage: String?
}

@MainActor
final class WorkspaceTopBarView: NSView, TokenThemed {
    let notificationView = WorkspaceNotificationView(frame: .zero)
    private var messageKind: WorkspaceNotificationView.Kind = .warning
    private var lastMessage: String?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        notificationView.removeFromSuperview()
        guard let host = superview else { return }
        notificationView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(notificationView, positioned: .above, relativeTo: self)
        let preferredWidth = notificationView.widthAnchor.constraint(equalToConstant: 440)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            preferredWidth,
            notificationView.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16),
            notificationView.topAnchor.constraint(equalTo: bottomAnchor, constant: 12),
            notificationView.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            notificationView.widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -32)
        ])
    }

    /// The bar is two icons and one title menu:
    ///
    ///     ● ● ●  [sidebar]  Forest ⌄  •                      [search]
    ///
    /// It used to be a row of bezelled text buttons — "Add or jump… ⌘K", "☰", a
    /// Switch popup, "+", "Rename", "Delete" — and a counts label, none of which
    /// had been revisited since they were first added. The verbs now live in the
    /// title menu (and in the sidebar's scope menu and ⌘K, as before); the counts
    /// are the title's tooltip. The title sits leading, after the sidebar icon,
    /// rather than centred: macOS's own unified titlebars lead with it, and a
    /// centred title would have to dodge the traffic lights and the search icon as
    /// the window narrows.
    private let sidebarButton = ChromeIconButton(symbolName: "sidebar.left", accessibilityLabel: "Show/Hide Sidebar")
    private let titleButton = ChromeIconButton(
        symbolName: "chevron.down", accessibilityLabel: "Workspace", title: "Workspace")
    private let titlePopover = ChoicePopoverController()
    private var titleItems: [ChoiceItem] = []
    private enum MenuID {
        static let create = "workspace.create"
        static let rename = "workspace.rename"
        static let delete = "workspace.delete"
    }
    /// Unsaved or saving: a dot beside the title, with the state as its tooltip.
    private let saveDot = NSImageView()
    /// Words only when they matter: "Save failed", or "Switching…" mid-switch.
    private let statusLabel: NSTextField
    private let managementMessageLabel: NSTextField
    private let commandCenterButton = ChromeIconButton(symbolName: "magnifyingglass", accessibilityLabel: "Command Center")
    /// 0.7.30 — what agents left running, and every other listening port. On
    /// screen only while an agent has something running; it opens the live
    /// processes panel (`onToggleProcesses`, given the button as the anchor).
    private let processesButton = ChromeIconButton(
        symbolName: AgentProcessUI.symbolName, accessibilityLabel: "Background processes")
    private var processesCount = 0
    var onToggleProcesses: ((ChromeIconButton) -> Void)?

    private var currentWorkspaceId: UUID?
    private var workspaces: [WorkspaceEntry] = []
    private var identityLeadingConstraint: NSLayoutConstraint?
    private var identityStack: NSStackView?

    /// Leading room reserved for the window's traffic lights, now that this bar
    /// IS the titlebar strip rather than a row stacked under it. Zero by default:
    /// the ui-probe appearance surfaces render this view in a borderless host with
    /// no window buttons to dodge, and full screen moves the buttons into the
    /// auto-hiding overlay, so both want the plain 10pt margin.
    var trafficLightInset: CGFloat = 0 {
        didSet {
            guard trafficLightInset != oldValue else { return }
            identityLeadingConstraint?.constant = Self.identityLeading + trafficLightInset
            needsLayout = true
        }
    }

    /// The bar's own margin, before any traffic-light clearance. The trailing
    /// search icon keeps the same margin.
    static let identityLeading: CGFloat = 10
    /// The save state the bar is currently showing, so `applyTokens()` can
    /// re-resolve its token on an appearance flip without waiting for a `reload`.
    private var currentSaveState: WorkspaceDocumentSaveState = .saved

    var onSwitchWorkspace: ((UUID) -> Void)?
    var onCreateWorkspace: (() -> Void)?
    var onRenameWorkspace: ((UUID) -> Void)?
    var onDeleteWorkspace: ((UUID) -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onOpenCommandCenter: (() -> Void)?

    override init(frame frameRect: NSRect) {
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.isHidden = true

        managementMessageLabel = NSTextField(labelWithString: "")
        managementMessageLabel.font = .systemFont(ofSize: 12, weight: .medium)
        managementMessageLabel.lineBreakMode = .byTruncatingTail
        managementMessageLabel.isHidden = true

        super.init(frame: frameRect)

        wantsLayer = true
        setAccessibilityIdentifier("ContinuumWorkspaceTopBarRoot")

        sidebarButton.setAccessibilityIdentifier("ContinuumWorkspaceTopBarToggleSidebar")
        sidebarButton.toolTip = "Show/Hide Sidebar"
        sidebarButton.target = self
        sidebarButton.action = #selector(toggleSidebarClicked(_:))

        titleButton.onOpenMenu = { [weak self] in self?.toggleTitlePopover() }
        titleButton.target = self
        titleButton.action = #selector(titleClicked(_:))
        titleButton.setAccessibilityIdentifier("ContinuumWorkspaceTopBarTitle")
        titleButton.setAccessibilityRole(.menuButton)
        titleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        saveDot.image = CanvasSymbolImage.image(named: "circle.fill", pointSize: 6, weight: .regular)
        saveDot.imageScaling = .scaleNone
        saveDot.isHidden = true
        saveDot.setAccessibilityIdentifier("ContinuumWorkspaceTopBarSaveState")

        statusLabel.setAccessibilityIdentifier("ContinuumWorkspaceTopBarStatus")
        managementMessageLabel.setAccessibilityIdentifier("ContinuumWorkspaceTopBarManagementMessage")

        commandCenterButton.setAccessibilityIdentifier("ContinuumWorkspaceTopBarCommandCenter")
        commandCenterButton.toolTip = "Command Center"
        commandCenterButton.target = self
        commandCenterButton.action = #selector(openCommandCenterClicked(_:))

        processesButton.target = self
        processesButton.action = #selector(processesClicked(_:))
        processesButton.setAccessibilityIdentifier("ContinuumWorkspaceTopBarProcesses")
        processesButton.translatesAutoresizingMaskIntoConstraints = false
        processesButton.isHidden = true

        let identityStack = NSStackView(views: [sidebarButton, titleButton, saveDot, statusLabel])
        self.identityStack = identityStack
        identityStack.orientation = .horizontal
        identityStack.alignment = .centerY
        identityStack.spacing = 6
        identityStack.setCustomSpacing(2, after: titleButton)
        identityStack.translatesAutoresizingMaskIntoConstraints = false
        identityStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        commandCenterButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(identityStack)
        addSubview(processesButton)
        addSubview(commandCenterButton)

        let identityLeadingConstraint = identityStack.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: Self.identityLeading + trafficLightInset)
        self.identityLeadingConstraint = identityLeadingConstraint

        NSLayoutConstraint.activate([
            // 28, not 36: the bar is sized to the system titlebar strip it now
            // occupies. A 36pt floor silently fought the frame the window gives it.
            heightAnchor.constraint(greaterThanOrEqualToConstant: 28),

            identityLeadingConstraint,
            identityStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            identityStack.trailingAnchor.constraint(lessThanOrEqualTo: processesButton.leadingAnchor, constant: -10),
            processesButton.trailingAnchor.constraint(equalTo: commandCenterButton.leadingAnchor, constant: -4),
            processesButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            processesButton.widthAnchor.constraint(equalToConstant: ChromeIconButton.side),
            processesButton.heightAnchor.constraint(equalToConstant: ChromeIconButton.side),

            sidebarButton.widthAnchor.constraint(equalToConstant: ChromeIconButton.side),
            sidebarButton.heightAnchor.constraint(equalToConstant: ChromeIconButton.side),
            titleButton.heightAnchor.constraint(equalToConstant: ChromeIconButton.side),
            titleButton.widthAnchor.constraint(lessThanOrEqualToConstant: 320),

            commandCenterButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.identityLeading),
            commandCenterButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            commandCenterButton.widthAnchor.constraint(equalToConstant: ChromeIconButton.side),
            commandCenterButton.heightAnchor.constraint(equalToConstant: ChromeIconButton.side),
        ])
        rebuildTitleMenu()
        applyTokens()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func updateProcessesCount(_ count: Int) {
        processesCount = count
        setProcessesIconShown(count > 0 || processesButton.isActive)
        let summary = AgentBackgroundJobText.summary(count)
        processesButton.toolTip = summary
        processesButton.setAccessibilityLabel(count == 0 ? "Background processes" : summary)
    }

    /// ⌘K and View ▸ Show Processes open the panel even when nothing runs,
    /// from where the icon would be.
    func openProcesses() {
        setProcessesIconShown(true, animated: false)
        processesClicked(processesButton)
    }

    /// Held while the panel is open; the icon leaves again once it closes if
    /// nothing is running.
    func processesPanelDidClose() {
        processesButton.isActive = false
        setProcessesIconShown(processesCount > 0)
    }

    /// The icon arrives and leaves with a fade on the panel's curve, never a
    /// pop. `processesIconShown` is the state; the alpha only catches up.
    private(set) var processesIconShown = false

    private func setProcessesIconShown(_ shown: Bool, animated: Bool = true) {
        guard shown != processesIconShown else { return }
        processesIconShown = shown
        let duration = animated ? ProcessesPanelController.duration(shown ? 0.2 : 0.24) : 0
        if shown {
            processesButton.isHidden = false
            if duration == 0 { processesButton.alphaValue = 1; return }
            processesButton.alphaValue = 0
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = ProcessesPanelController.easing
            processesButton.animator().alphaValue = shown ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.processesIconShown else { return }
                self.processesButton.isHidden = true
            }
        })
    }

    @objc private func processesClicked(_ sender: Any?) {
        processesButton.isActive = true
        onToggleProcesses?(processesButton)
    }

    var qaProcessesVisible: Bool { processesIconShown }
    var qaProcessesButton: ChromeIconButton { processesButton }

    /// P1.11: `SurfaceToken.panel`, the same token the sidebar uses — the two are
    /// one piece of chrome around the canvas and had no reason to be 92% and 96% of
    /// the same system colour. See `WorkspaceSidebarView.applyTokens()` for why the
    /// alpha went with the literal.
    ///
    /// The save dot and the status words are state-carrying; `renderStatus()`
    /// re-derives them from the last model, so a flip cannot revert a "save
    /// failed" to neutral.
    func applyTokens() {
        layer?.backgroundColor = SurfaceToken.panel.color.cgColor(in: self)
        managementMessageLabel.textColor = AccentToken.accentApproval.color.nsColor(in: self)
        renderStatus()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func reload(_ model: WorkspaceTopBarModel) {
        let previousWorkspaceId = currentWorkspaceId
        let previousItems = titleItems
        currentWorkspaceId = model.currentWorkspaceId
        workspaces = model.workspaces
        titleButton.titleText = model.currentWorkspaceName
        titleButton.setAccessibilityLabel("Workspace: \(model.currentWorkspaceName)")
        titleButton.toolTip = Self.countsText(projectCount: model.projectCount, zoneCount: model.zoneCount)
        currentSaveState = model.saveState
        renderStatus()
        setManagementMessage(model.managementMessage)
        rebuildTitleMenu()
        // Agent activity and save-state refreshes also reload this bar. Keep a
        // person's open menu and keyboard focus unless its actual choices changed.
        if currentWorkspaceId != previousWorkspaceId || titleItems != previousItems {
            dismissTitlePopover()
        }
    }

    /// UUIDs identify workspace rows; management commands never become values.
    private func rebuildTitleMenu() {
        let canManage = switchingWorkspaceId == nil
        titleItems = workspaces.map {
            ChoiceItem(id: $0.id.uuidString, title: $0.name, enabled: canManage)
        }
        var create = ChoiceItem(id: MenuID.create, title: AgentInboxView.WorkspaceManagementAction.create.title,
                                enabled: canManage)
        create.separatorBefore = !workspaces.isEmpty
        titleItems.append(create)
        titleItems.append(ChoiceItem(id: MenuID.rename, title: AgentInboxView.WorkspaceManagementAction.rename.title,
                                     enabled: canManage && currentWorkspaceId != nil))
        let reason = Self.deleteDisabledReason(workspaceCount: workspaces.count, hasCurrentWorkspace: currentWorkspaceId != nil)
        let deleteTitle = AgentInboxView.WorkspaceManagementAction.delete.title
        titleItems.append(ChoiceItem(id: MenuID.delete,
            title: reason.map { "\(deleteTitle) — \($0)" } ?? deleteTitle,
            enabled: canManage && reason == nil, destructive: true,
            toolTip: Self.deleteToolTip(workspaceCount: workspaces.count, hasCurrentWorkspace: currentWorkspaceId != nil)))
    }

    @objc private func titleClicked(_ sender: NSButton) { toggleTitlePopover() }

    private func toggleTitlePopover() {
        if titlePopover.isPresented { dismissTitlePopover(); return }
        titleButton.isActive = true
        titlePopover.dismissesOnAnchorClick = true
        titlePopover.present(
            items: titleItems, selectedID: (switchingWorkspaceId ?? currentWorkspaceId)?.uuidString,
            presentation: .compactChoices,
            layout: .commands(CommandPopoverLayout(maximumVisibleRows: 12, minimumWidth: 220, maximumWidth: 480)),
            anchor: titleButton.bounds, relativeTo: titleButton,
            accessibilityLabel: "Workspaces",
            onSelection: { [weak self] item in
                self?.titleButton.isActive = false
                self?.handleTitleChoice(item)
            }, focusReturnView: titleButton,
            onClose: { [weak self] in self?.titleButton.isActive = false })
        titleButton.isActive = titlePopover.isPresented
    }

    private func dismissTitlePopover() {
        titlePopover.dismiss()
        titleButton.isActive = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { dismissTitlePopover() }
    }

    /// Validate against the latest model, so a stale menu can never dispatch.
    private func handleTitleChoice(_ item: ChoiceItem) {
        guard titleItems.contains(where: { $0.id == item.id && $0.enabled }) else { return }
        switch item.id {
        case MenuID.create: onCreateWorkspace?()
        case MenuID.rename:
            if let currentWorkspaceId { onRenameWorkspace?(currentWorkspaceId) }
        case MenuID.delete: deleteWorkspaceClicked()
        default:
            guard let id = UUID(uuidString: item.id), id != currentWorkspaceId else { return }
            onSwitchWorkspace?(id)
        }
    }

    /// The four readings of Delete, as its tooltip states them.
    static let deleteUnloadedToolTip =
        "Delete workspace — unavailable until this workspace finishes loading"
    static let lastWorkspaceToolTip =
        "Delete workspace — you can't delete your only workspace. Create another one first."

    static func deleteToolTip(workspaceCount: Int, hasCurrentWorkspace: Bool) -> String {
        guard hasCurrentWorkspace else { return deleteUnloadedToolTip }
        return workspaceCount > 1 ? "Delete workspace" : lastWorkspaceToolTip
    }

    /// Why Delete is greyed, worded as the sidebar's scope menu words it.
    static func deleteDisabledReason(workspaceCount: Int, hasCurrentWorkspace: Bool) -> String? {
        guard hasCurrentWorkspace else { return "this workspace is still loading" }
        return workspaceCount > 1 ? nil : "this is your only workspace — create another first"
    }

    /// The dot, the words, and their colours, from the save state and any switch
    /// in flight. Nothing at all when saved.
    private func renderStatus() {
        if switchingWorkspaceId != nil {
            saveDot.isHidden = true
            statusLabel.stringValue = "Switching…"
            statusLabel.textColor = AccentToken.accentWorking.color.nsColor(in: self)
            statusLabel.isHidden = false
            return
        }
        switch currentSaveState {
        case .saved:
            saveDot.isHidden = true
            statusLabel.isHidden = true
            statusLabel.stringValue = ""
        case .saving, .unsavedChanges:
            saveDot.isHidden = false
            saveDot.contentTintColor = Self.color(for: currentSaveState).nsColor(in: self)
            saveDot.toolTip = currentSaveState.displayTitle
            saveDot.setAccessibilityLabel(currentSaveState.displayTitle)
            statusLabel.isHidden = true
            statusLabel.stringValue = ""
        case .saveFailed:
            saveDot.isHidden = true
            statusLabel.stringValue = currentSaveState.displayTitle
            statusLabel.textColor = Self.color(for: currentSaveState).nsColor(in: self)
            statusLabel.isHidden = false
        }
    }

    func setManagementMessage(_ message: String?, kind: WorkspaceNotificationView.Kind) {
        messageKind = kind
        lastMessage = nil
        setManagementMessage(message)
    }

    /// A message that offers one action (a repair the user accepts).
    func setManagementMessage(
        _ message: String?, kind: WorkspaceNotificationView.Kind, action: (title: String, handler: () -> Void)?
    ) {
        guard let action else { return setManagementMessage(message, kind: kind) }
        messageKind = kind
        let text = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        managementMessageLabel.stringValue = text
        managementMessageLabel.isHidden = true
        lastMessage = text
        notificationView.show(text, kind: kind, action: action)
    }

    func setManagementMessage(_ message: String?) {
        let text = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        managementMessageLabel.stringValue = text
        managementMessageLabel.isHidden = true
        guard lastMessage != text else { return }
        lastMessage = text
        notificationView.show(text, kind: messageKind)
    }

    func updateCommandCenterShortcut(_ display: String?) {
        commandCenterButton.toolTip = display.map { "Command Center \($0)" } ?? "Command Center"
    }

    func updateSidebarShortcut(_ display: String?) {
        sidebarButton.toolTip = display.map { "Show/Hide Sidebar \($0)" } ?? "Show/Hide Sidebar"
    }

    /// A drag anywhere on the bar's own surface moves the window, the way the
    /// titlebar it replaced did. Controls keep their own hit areas.
    override var mouseDownCanMoveWindow: Bool { true }

    /// The workspace the bar is switching to, while a switch is in flight.
    private(set) var switchingWorkspaceId: UUID?

    /// Name the target and show progress BEFORE the switch does any work, and
    /// paint it now: the switch holds the main thread, so a bar that waited for
    /// the next display cycle would only ever show the result.
    func beginSwitching(to workspaceId: UUID, name: String) {
        dismissTitlePopover()
        switchingWorkspaceId = workspaceId
        titleButton.titleText = name
        renderStatus()
        rebuildTitleMenu()
        displayIfNeeded()
    }

    /// The switch ended. The next `reload` puts back the truth — the target on
    /// success, the workspace still mounted on failure.
    func endSwitching() {
        dismissTitlePopover()
        switchingWorkspaceId = nil
        renderStatus()
        rebuildTitleMenu()
    }

    var switchProgressVisibleForQA: Bool {
        switchingWorkspaceId != nil && !statusLabel.isHidden && statusLabel.stringValue == "Switching…"
    }
    /// The workspace the title menu checks.
    var selectedWorkspaceIdForQA: UUID? {
        switchingWorkspaceId ?? currentWorkspaceId
    }

    var managementMessageIsVisibleForQA: Bool { !managementMessageLabel.isHidden && managementMessageLabel.superview != nil }

    var sidebarToggleForQA: ChromeIconButton { sidebarButton }
    var commandCenterButtonForQA: ChromeIconButton { commandCenterButton }
    var titleButtonForQA: ChromeIconButton { titleButton }
    var titleItemsForQA: [ChoiceItem] { titleItems }
    var titlePopoverForQA: ChoicePopoverController { titlePopover }
    var saveDotForQA: NSView? { saveDot }
    var saveFailedVisibleForQA: Bool { !statusLabel.isHidden && statusLabel.stringValue == WorkspaceDocumentSaveState.saveFailed.displayTitle }

    var workspaceNameForQA: String { titleButton.titleText ?? "" }
    var identityLeadingForQA: CGFloat { identityLeadingConstraint?.constant ?? 0 }
    /// The leading cluster — sidebar icon, title menu, save state — in bar space.
    var identityFrameForQA: NSRect { identityStack?.frame ?? .zero }
    /// The counts, as the title's tooltip carries them.
    var countsTextForQA: String { titleButton.toolTip ?? "" }
    /// What the bar says about saving: nothing when saved, the dot's tooltip while
    /// unsaved or saving, the words on failure.
    var saveStateTextForQA: String {
        if !statusLabel.isHidden { return statusLabel.stringValue }
        if !saveDot.isHidden { return saveDot.toolTip ?? "" }
        return ""
    }
    var managementMessageForQA: String { managementMessageLabel.stringValue }

    var deleteEnabledForQA: Bool { titleItems.first { $0.id == MenuID.delete }?.enabled ?? false }
    var deleteToolTipForQA: String { titleItems.first { $0.id == MenuID.delete }?.toolTip ?? "" }
    var deleteMenuTitleForQA: String { titleItems.first { $0.id == MenuID.delete }?.title ?? "" }

    func invokeDeleteActionForQA() { deleteWorkspaceClicked() }
    var switchWorkspaceNamesForQA: [String] {
        titleItems.filter { UUID(uuidString: $0.id) != nil }.map(\.title)
    }

    /// Drive the same list and dispatch seam as a pick, even in unmounted checks.
    private func pickTitleChoiceForQA(_ id: String) -> Bool {
        guard titleItems.contains(where: { $0.id == id && $0.enabled }) else { return false }
        if window != nil {
            if !titlePopover.isPresented { toggleTitlePopover() }
            titlePopover.listView?.choose(id: id)
        } else {
            let list = ChoiceListView(items: titleItems, selectedID: selectedWorkspaceIdForQA?.uuidString,
                                      presentation: .compactChoices)
            list.onSelection = { [weak self] in self?.handleTitleChoice($0) }
            list.choose(id: id)
        }
        return true
    }

    @discardableResult
    func selectWorkspaceForQA(_ workspaceId: UUID) -> Bool { pickTitleChoiceForQA(workspaceId.uuidString) }
    @discardableResult
    func clickCreateForQA() -> Bool { pickTitleChoiceForQA(MenuID.create) }
    @discardableResult
    func clickRenameForQA() -> Bool { pickTitleChoiceForQA(MenuID.rename) }
    @discardableResult
    func clickDeleteForQA() -> Bool { pickTitleChoiceForQA(MenuID.delete) }

    @discardableResult
    func clickToggleSidebarForQA() -> Bool {
        guard sidebarButton.isEnabled else { return false }
        sidebarButton.performClick(nil)
        return true
    }

    @discardableResult
    func clickCommandCenterForQA() -> Bool {
        commandCenterButton.performClick(nil)
        return true
    }

    private func deleteWorkspaceClicked() {
        // 0721: say so. Reaching here with no loaded workspace used to return in
        // silence, which is indistinguishable from a broken button.
        guard let currentWorkspaceId else {
            setManagementMessage(Self.deleteUnloadedMessage)
            return
        }
        onDeleteWorkspace?(currentWorkspaceId)
    }

    static let deleteUnloadedMessage =
        "This workspace hasn't finished loading, so it can't be deleted yet."

    @objc private func toggleSidebarClicked(_ sender: NSButton) {
        onToggleSidebar?()
    }

    @objc private func openCommandCenterClicked(_ sender: NSButton) {
        onOpenCommandCenter?()
    }

    private static func countsText(projectCount: Int, zoneCount: Int) -> String {
        let base = "\(projectCount) \(projectCount == 1 ? "project" : "projects") · \(zoneCount) \(zoneCount == 1 ? "zone" : "zones")"
        return zoneCount == 0 ? "\(base) · empty workspace" : base
    }

    /// P1.11: four tokens for four states (`.saved` is no longer drawn). `secondaryLabelColor` and
    /// `systemOrange` were both P0.4 failures on a light panel (3.95:1 and 2.31:1);
    /// the accents here are the same ones `StatusChipPresenter` uses for the
    /// equivalent agent states, so "saving" reads like "working" everywhere.
    static func color(for state: WorkspaceDocumentSaveState) -> TokenColor {
        switch state {
        case .saved: return TextToken.textSecondary.color
        case .saving: return AccentToken.accentWorking.color
        case .unsavedChanges: return AccentToken.accentApproval.color
        case .saveFailed: return AccentToken.accentFailed.color
        }
    }
}
