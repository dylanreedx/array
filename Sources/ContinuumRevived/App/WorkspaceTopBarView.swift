import AppKit
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
}

@MainActor
final class WorkspaceTopBarView: NSView {
    private let nameLabel: NSTextField
    private let countsLabel: NSTextField
    private let saveStateLabel: NSTextField
    private let switchWorkspaceButton: NSPopUpButton
    private let renameButton: NSButton
    private let toggleSidebarButton: NSButton

    private var currentWorkspaceId: UUID?

    var onSwitchWorkspace: ((UUID) -> Void)?
    var onRenameWorkspace: ((UUID) -> Void)?
    var onToggleSidebar: (() -> Void)?

    override init(frame frameRect: NSRect) {
        nameLabel = NSTextField(labelWithString: "Workspace")
        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        countsLabel = NSTextField(labelWithString: "0 projects · 0 zones")
        countsLabel.font = .systemFont(ofSize: 12, weight: .regular)
        countsLabel.textColor = .secondaryLabelColor
        countsLabel.lineBreakMode = .byTruncatingTail

        saveStateLabel = NSTextField(labelWithString: WorkspaceDocumentSaveState.saved.displayTitle)
        saveStateLabel.font = .systemFont(ofSize: 12, weight: .medium)
        saveStateLabel.textColor = .secondaryLabelColor
        saveStateLabel.lineBreakMode = .byTruncatingTail

        switchWorkspaceButton = NSPopUpButton(frame: .zero, pullsDown: false)
        switchWorkspaceButton.toolTip = "Switch workspace"
        switchWorkspaceButton.bezelStyle = .rounded
        switchWorkspaceButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        renameButton = NSButton(title: "Rename", target: nil, action: nil)
        renameButton.bezelStyle = .rounded
        renameButton.toolTip = "Rename workspace"

        toggleSidebarButton = NSButton(title: "Sidebar", target: nil, action: nil)
        toggleSidebarButton.bezelStyle = .rounded
        toggleSidebarButton.toolTip = "Toggle workspace sidebar"

        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        setAccessibilityIdentifier("ContinuumWorkspaceTopBarRoot")

        nameLabel.setAccessibilityIdentifier("ContinuumWorkspaceTopBarName")
        countsLabel.setAccessibilityIdentifier("ContinuumWorkspaceTopBarCounts")
        saveStateLabel.setAccessibilityIdentifier("ContinuumWorkspaceTopBarSaveState")
        switchWorkspaceButton.setAccessibilityIdentifier("ContinuumWorkspaceTopBarSwitch")
        renameButton.setAccessibilityIdentifier("ContinuumWorkspaceTopBarRename")
        toggleSidebarButton.setAccessibilityIdentifier("ContinuumWorkspaceTopBarToggleSidebar")

        switchWorkspaceButton.target = self
        switchWorkspaceButton.action = #selector(switchWorkspaceSelected(_:))
        renameButton.target = self
        renameButton.action = #selector(renameWorkspaceClicked(_:))
        toggleSidebarButton.target = self
        toggleSidebarButton.action = #selector(toggleSidebarClicked(_:))

        let identityStack = NSStackView(views: [nameLabel, countsLabel, saveStateLabel])
        identityStack.orientation = .horizontal
        identityStack.alignment = .firstBaseline
        identityStack.spacing = 10
        identityStack.translatesAutoresizingMaskIntoConstraints = false

        let actionsStack = NSStackView(views: [switchWorkspaceButton, renameButton, toggleSidebarButton])
        actionsStack.orientation = .horizontal
        actionsStack.alignment = .centerY
        actionsStack.spacing = 8
        actionsStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(identityStack)
        addSubview(actionsStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 42),

            identityStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            identityStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            identityStack.trailingAnchor.constraint(lessThanOrEqualTo: actionsStack.leadingAnchor, constant: -16),

            actionsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            actionsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func reload(_ model: WorkspaceTopBarModel) {
        currentWorkspaceId = model.currentWorkspaceId
        nameLabel.stringValue = model.currentWorkspaceName
        countsLabel.stringValue = Self.countsText(projectCount: model.projectCount, zoneCount: model.zoneCount)
        saveStateLabel.stringValue = model.saveState.displayTitle
        saveStateLabel.textColor = Self.color(for: model.saveState)

        switchWorkspaceButton.removeAllItems()
        for workspace in model.workspaces {
            switchWorkspaceButton.addItem(withTitle: workspace.name)
            switchWorkspaceButton.lastItem?.representedObject = workspace.id.uuidString
        }
        if let selectedIndex = model.workspaces.firstIndex(where: { $0.id == model.currentWorkspaceId }) {
            switchWorkspaceButton.selectItem(at: selectedIndex)
        }
        switchWorkspaceButton.isEnabled = !model.workspaces.isEmpty
        renameButton.isEnabled = true
    }

    var workspaceNameForQA: String { nameLabel.stringValue }
    var countsTextForQA: String { countsLabel.stringValue }
    var saveStateTextForQA: String { saveStateLabel.stringValue }
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
    func clickRenameForQA() -> Bool {
        guard renameButton.isEnabled else { return false }
        renameButton.performClick(nil)
        return true
    }

    @discardableResult
    func clickToggleSidebarForQA() -> Bool {
        guard toggleSidebarButton.isEnabled else { return false }
        toggleSidebarButton.performClick(nil)
        return true
    }

    @objc private func switchWorkspaceSelected(_ sender: NSPopUpButton) {
        guard let idString = sender.selectedItem?.representedObject as? String,
              let workspaceId = UUID(uuidString: idString),
              workspaceId != currentWorkspaceId else { return }
        onSwitchWorkspace?(workspaceId)
    }

    @objc private func renameWorkspaceClicked(_ sender: NSButton) {
        guard let currentWorkspaceId else { return }
        onRenameWorkspace?(currentWorkspaceId)
    }

    @objc private func toggleSidebarClicked(_ sender: NSButton) {
        onToggleSidebar?()
    }

    private static func countsText(projectCount: Int, zoneCount: Int) -> String {
        "\(projectCount) \(projectCount == 1 ? "project" : "projects") · \(zoneCount) \(zoneCount == 1 ? "zone" : "zones")"
    }

    private static func color(for state: WorkspaceDocumentSaveState) -> NSColor {
        switch state {
        case .saved:
            return .secondaryLabelColor
        case .saving:
            return .controlAccentColor
        case .unsavedChanges:
            return .systemOrange
        case .saveFailed:
            return .systemRed
        }
    }
}
