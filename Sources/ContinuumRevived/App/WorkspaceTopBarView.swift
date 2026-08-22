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
    private let nameLabel: NSTextField
    private let countsLabel: NSTextField
    private let saveStateLabel: NSTextField
    private let managementMessageLabel: NSTextField
    private let switchWorkspaceButton: NSPopUpButton
    private let createButton: NSButton
    private let renameButton: NSButton
    private let deleteButton: NSButton
    private let toggleSidebarButton: NSButton
    private let commandCenterButton: NSButton

    private var currentWorkspaceId: UUID?
    /// The save state the label is currently showing, so `applyTokens()` can
    /// re-resolve its token on an appearance flip without waiting for a `reload`.
    private var currentSaveState: WorkspaceDocumentSaveState = .saved

    var onSwitchWorkspace: ((UUID) -> Void)?
    var onCreateWorkspace: (() -> Void)?
    var onRenameWorkspace: ((UUID) -> Void)?
    var onDeleteWorkspace: ((UUID) -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onOpenCommandCenter: (() -> Void)?

    override init(frame frameRect: NSRect) {
        nameLabel = NSTextField(labelWithString: "Workspace")
        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        countsLabel = NSTextField(labelWithString: "0 projects · 0 zones")
        countsLabel.font = .systemFont(ofSize: 12, weight: .regular)
        countsLabel.lineBreakMode = .byTruncatingTail

        saveStateLabel = NSTextField(labelWithString: WorkspaceDocumentSaveState.saved.displayTitle)
        saveStateLabel.font = .systemFont(ofSize: 12, weight: .medium)
        saveStateLabel.lineBreakMode = .byTruncatingTail

        managementMessageLabel = NSTextField(labelWithString: "")
        managementMessageLabel.font = .systemFont(ofSize: 12, weight: .medium)
        managementMessageLabel.lineBreakMode = .byTruncatingTail
        managementMessageLabel.isHidden = true

        switchWorkspaceButton = NSPopUpButton(frame: .zero, pullsDown: false)
        switchWorkspaceButton.toolTip = "Switch workspace"
        switchWorkspaceButton.bezelStyle = .rounded
        switchWorkspaceButton.controlSize = .small
        switchWorkspaceButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        createButton = NSButton(title: "+", target: nil, action: nil)
        createButton.bezelStyle = .rounded
        createButton.controlSize = .small
        createButton.toolTip = "Create workspace"

        renameButton = NSButton(title: "Rename", target: nil, action: nil)
        renameButton.bezelStyle = .rounded
        renameButton.controlSize = .small
        renameButton.toolTip = "Rename workspace"

        deleteButton = NSButton(title: "Delete", target: nil, action: nil)
        deleteButton.bezelStyle = .rounded
        deleteButton.controlSize = .small
        deleteButton.toolTip = "Delete workspace"

        toggleSidebarButton = NSButton(title: "☰", target: nil, action: nil)
        toggleSidebarButton.bezelStyle = .rounded
        toggleSidebarButton.controlSize = .small
        toggleSidebarButton.toolTip = "Toggle workspace sidebar"

        commandCenterButton = NSButton(title: "Add or jump…  ⌘K", target: nil, action: nil)
        commandCenterButton.bezelStyle = .rounded
        commandCenterButton.controlSize = .small
        commandCenterButton.toolTip = "Open Command Center"

        super.init(frame: frameRect)

        wantsLayer = true
        applyTokens()
        setAccessibilityIdentifier("ContinuumWorkspaceTopBarRoot")

        nameLabel.setAccessibilityIdentifier("ContinuumWorkspaceTopBarName")
        countsLabel.setAccessibilityIdentifier("ContinuumWorkspaceTopBarCounts")
        saveStateLabel.setAccessibilityIdentifier("ContinuumWorkspaceTopBarSaveState")
        managementMessageLabel.setAccessibilityIdentifier("ContinuumWorkspaceTopBarManagementMessage")
        switchWorkspaceButton.setAccessibilityIdentifier("ContinuumWorkspaceTopBarSwitch")
        createButton.setAccessibilityIdentifier("ContinuumWorkspaceTopBarCreate")
        renameButton.setAccessibilityIdentifier("ContinuumWorkspaceTopBarRename")
        deleteButton.setAccessibilityIdentifier("ContinuumWorkspaceTopBarDelete")
        toggleSidebarButton.setAccessibilityIdentifier("ContinuumWorkspaceTopBarToggleSidebar")
        commandCenterButton.setAccessibilityIdentifier("ContinuumWorkspaceTopBarCommandCenter")

        switchWorkspaceButton.target = self
        switchWorkspaceButton.action = #selector(switchWorkspaceSelected(_:))
        createButton.target = self
        createButton.action = #selector(createWorkspaceClicked(_:))
        renameButton.target = self
        renameButton.action = #selector(renameWorkspaceClicked(_:))
        deleteButton.target = self
        deleteButton.action = #selector(deleteWorkspaceClicked(_:))
        toggleSidebarButton.target = self
        toggleSidebarButton.action = #selector(toggleSidebarClicked(_:))
        commandCenterButton.target = self
        commandCenterButton.action = #selector(openCommandCenterClicked(_:))

        let identityStack = NSStackView(views: [nameLabel, countsLabel, saveStateLabel, managementMessageLabel])
        identityStack.orientation = .horizontal
        identityStack.alignment = .firstBaseline
        identityStack.spacing = 8
        identityStack.translatesAutoresizingMaskIntoConstraints = false
        identityStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let actionsStack = NSStackView(views: [commandCenterButton, toggleSidebarButton, switchWorkspaceButton, createButton, renameButton, deleteButton])
        actionsStack.orientation = .horizontal
        actionsStack.alignment = .centerY
        actionsStack.spacing = 6
        actionsStack.translatesAutoresizingMaskIntoConstraints = false
        actionsStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(identityStack)
        addSubview(actionsStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 36),

            identityStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            identityStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            identityStack.trailingAnchor.constraint(lessThanOrEqualTo: actionsStack.leadingAnchor, constant: -10),

            actionsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            actionsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            switchWorkspaceButton.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// P1.11: `SurfaceToken.panel`, the same token the sidebar uses — the two are
    /// one piece of chrome around the canvas and had no reason to be 92% and 96% of
    /// the same system colour. See `WorkspaceSidebarView.applyTokens()` for why the
    /// alpha went with the literal.
    ///
    /// `saveStateLabel` is deliberately NOT reset here: its colour is state-carrying
    /// and `reload(_:)` owns it. `applyTokens()` re-derives it from the last model
    /// instead, so a flip cannot revert a "save failed" label to neutral.
    func applyTokens() {
        layer?.backgroundColor = SurfaceToken.panel.color.cgColor(in: self)
        nameLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        countsLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        managementMessageLabel.textColor = AccentToken.accentApproval.color.nsColor(in: self)
        saveStateLabel.textColor = Self.color(for: currentSaveState).nsColor(in: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func reload(_ model: WorkspaceTopBarModel) {
        currentWorkspaceId = model.currentWorkspaceId
        nameLabel.stringValue = model.currentWorkspaceName
        countsLabel.stringValue = Self.countsText(projectCount: model.projectCount, zoneCount: model.zoneCount)
        saveStateLabel.stringValue = model.saveState.displayTitle
        currentSaveState = model.saveState
        saveStateLabel.textColor = Self.color(for: model.saveState).nsColor(in: self)
        setManagementMessage(model.managementMessage)

        switchWorkspaceButton.removeAllItems()
        for workspace in model.workspaces {
            switchWorkspaceButton.addItem(withTitle: workspace.name)
            switchWorkspaceButton.lastItem?.representedObject = workspace.id.uuidString
        }
        if let selectedIndex = model.workspaces.firstIndex(where: { $0.id == model.currentWorkspaceId }) {
            switchWorkspaceButton.selectItem(at: selectedIndex)
        }
        switchWorkspaceButton.isEnabled = !model.workspaces.isEmpty
        createButton.isEnabled = true
        renameButton.isEnabled = currentWorkspaceId != nil
        deleteButton.isEnabled = model.workspaces.count > 1 && currentWorkspaceId != nil
    }

    func setManagementMessage(_ message: String?) {
        let text = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        managementMessageLabel.stringValue = text
        managementMessageLabel.isHidden = text.isEmpty
    }

    func updateCommandCenterShortcut(_ display: String?) {
        commandCenterButton.title = display.map { "Add or jump…  \($0)" } ?? "Add or jump…"
        commandCenterButton.toolTip = display.map { "Open Command Center (\($0))" }
            ?? "Open Command Center"
    }

    var workspaceNameForQA: String { nameLabel.stringValue }
    var countsTextForQA: String { countsLabel.stringValue }
    var saveStateTextForQA: String { saveStateLabel.stringValue }
    var managementMessageForQA: String { managementMessageLabel.stringValue }
    var deleteEnabledForQA: Bool { deleteButton.isEnabled }
    var switchWorkspaceNamesForQA: [String] { switchWorkspaceButton.itemArray.map(\.title) }

    @discardableResult
    func selectWorkspaceForQA(_ workspaceId: UUID) -> Bool {
        guard let item = switchWorkspaceButton.itemArray.first(where: { ($0.representedObject as? String) == workspaceId.uuidString }) else {
            return false
        }
        switchWorkspaceButton.select(item)
        switchWorkspaceSelected(switchWorkspaceButton)
        return true
    }

    @discardableResult
    func clickCreateForQA() -> Bool {
        guard createButton.isEnabled else { return false }
        createButton.performClick(nil)
        return true
    }

    @discardableResult
    func clickRenameForQA() -> Bool {
        guard renameButton.isEnabled else { return false }
        renameButton.performClick(nil)
        return true
    }

    @discardableResult
    func clickDeleteForQA() -> Bool {
        guard deleteButton.isEnabled else { return false }
        deleteButton.performClick(nil)
        return true
    }

    @discardableResult
    func clickToggleSidebarForQA() -> Bool {
        guard toggleSidebarButton.isEnabled else { return false }
        toggleSidebarButton.performClick(nil)
        return true
    }

    @discardableResult
    func clickCommandCenterForQA() -> Bool {
        commandCenterButton.performClick(nil)
        return true
    }


    @objc private func switchWorkspaceSelected(_ sender: NSPopUpButton) {
        guard let idString = sender.selectedItem?.representedObject as? String,
              let workspaceId = UUID(uuidString: idString),
              workspaceId != currentWorkspaceId else { return }
        onSwitchWorkspace?(workspaceId)
    }

    @objc private func createWorkspaceClicked(_ sender: NSButton) {
        onCreateWorkspace?()
    }

    @objc private func renameWorkspaceClicked(_ sender: NSButton) {
        guard let currentWorkspaceId else { return }
        onRenameWorkspace?(currentWorkspaceId)
    }

    @objc private func deleteWorkspaceClicked(_ sender: NSButton) {
        guard let currentWorkspaceId else { return }
        onDeleteWorkspace?(currentWorkspaceId)
    }

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

    /// P1.11: four tokens for four states. `secondaryLabelColor` and
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
