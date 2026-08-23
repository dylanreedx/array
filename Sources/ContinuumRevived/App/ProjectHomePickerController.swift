import AppKit
import ContinuumRevivedCore

struct ProjectHomeSelection: Equatable, Sendable {
    var project: ProjectEntry
    var homeRelativePath: String?

    var displayPath: String {
        guard let homeRelativePath else { return project.name }
        return "\(project.name) / \(homeRelativePath)"
    }
}

/// One reusable, Array-native project/Home chooser for zones and filesystem tile
/// creation. The picker never stores an absolute Home: every confirmation passes
/// through `ProjectHomeValidator`, including symlink resolution and containment.
@MainActor
final class ProjectHomePickerController {
    typealias AddProjectHandler = () -> ProjectEntry?

    private enum Stage {
        case projects
        case folders(project: ProjectEntry, relativePath: String?)
    }

    private let popover = ChoicePopoverController()
    private weak var anchorView: NSView?
    private var anchorRect: NSRect = .zero
    private var projects: [ProjectEntry] = []
    private var recents: [ProjectHomeSelection] = []
    private var stage: Stage = .projects
    private var selected: ProjectHomeSelection?
    private var addProject: AddProjectHandler?
    private var onConfirm: ((ProjectHomeSelection) -> Void)?
    private var onCancel: (() -> Void)?
    private var onInteractionOwnershipChanged: ((Bool) -> Void)?
    private var validationMessage: String?
    private var confirmsDestructiveCancellation = false

    var isPresented: Bool { popover.isPresented }

    func present(
        projects: [ProjectEntry],
        recents: [ProjectHomeSelection] = [],
        selected: ProjectHomeSelection? = nil,
        anchor: NSPoint,
        relativeTo view: NSView,
        addProject: AddProjectHandler? = nil,
        confirmsDestructiveCancellation: Bool = false,
        onInteractionOwnershipChanged: ((Bool) -> Void)? = nil,
        onConfirm: @escaping (ProjectHomeSelection) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.projects = projects.filter { !$0.missing }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        self.recents = recents
        self.selected = selected
        self.anchorView = view
        self.anchorRect = NSRect(x: anchor.x, y: anchor.y, width: 1, height: 1)
        self.addProject = addProject
        self.confirmsDestructiveCancellation = confirmsDestructiveCancellation
        self.onInteractionOwnershipChanged = onInteractionOwnershipChanged
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        validationMessage = nil
        stage = .projects
        onInteractionOwnershipChanged?(true)
        showProjects()
    }

    func dismiss(cancelled: Bool) {
        popover.dismiss()
        finishInteraction()
        if cancelled { onCancel?() }
    }

    private func showProjects() {
        guard let anchorView else { return }
        stage = .projects
        var items: [ChoiceItem] = []
        let knownProjectIds = Set(projects.map(\.id))
        for recent in recents where knownProjectIds.contains(recent.project.id) && recent != selected {
            let relative = recent.homeRelativePath ?? "Project Root"
            items.append(ChoiceItem(
                id: "recent:\(recent.project.id.uuidString):\(recent.homeRelativePath ?? "")",
                title: recent.project.name,
                detail: "Recent · \(relative)",
                icon: .system("clock")
            ))
        }
        let orderedProjects = projects.sorted { lhs, rhs in
            let lhsIsCurrent = lhs.id == selected?.project.id
            let rhsIsCurrent = rhs.id == selected?.project.id
            if lhsIsCurrent != rhsIsCurrent { return lhsIsCurrent }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        for project in orderedProjects {
            let detail: String
            if project.id == selected?.project.id {
                detail = "Current · \(selected?.homeRelativePath ?? "Project Root")"
            } else {
                detail = compactPath(project.rootPath)
            }
            items.append(ChoiceItem(
                id: "project:\(project.id.uuidString)",
                title: project.name,
                detail: detail,
                icon: .system(project.id == selected?.project.id ? "checkmark.circle.fill" : "folder")
            ))
        }
        // T6 (`.plans/47`): the drill-down is now OPT-IN. Choosing a project
        // confirms at its root, which is what almost every zone wants; refining
        // Home to a subfolder is a deliberate second act rather than a mandatory
        // second step. Only offered when there is a project to refine — a brand
        // new zone has no selection yet, and "which project's subfolder?" would
        // have no answer.
        if let selected {
            items.append(ChoiceItem(
                id: "choose-subfolder",
                title: "Choose a subfolder…",
                detail: "Pick a Home inside \(selected.project.name)",
                icon: .system("folder.badge.gearshape")
            ))
        }
        if addProject != nil {
            items.append(ChoiceItem(
                id: "add-project",
                title: "Add Project…",
                detail: "Register another project folder",
                icon: .system("plus")
            ))
        }
        if items.isEmpty {
            items.append(ChoiceItem(
                id: "no-projects",
                title: "No registered projects",
                detail: "Add a project to continue",
                enabled: false
            ))
        }
        popover.present(
            items: items,
            selectedID: selected.map { "project:\($0.project.id.uuidString)" },
            presentation: .completions,
            layout: .completion(.init(
                breadcrumb: "Choose Project & Home",
                footer: validationMessage ?? "Choose a project · ↑↓ Select · Return Open · Esc Cancel",
                maximumVisibleRows: 7,
                minimumWidth: 380,
                maximumWidth: 480
            )),
            anchor: anchorRect,
            relativeTo: anchorView,
            placementFrame: visibleScreenFrame(for: anchorView),
            onSelection: { [weak self] item in self?.chooseProjectRow(item) },
            focusReturnView: anchorView,
            onDismiss: { [weak self] in self?.handleDismissalRequest() }
        )
    }

    private func chooseProjectRow(_ item: ChoiceItem) {
        if item.id == "add-project" {
            guard let project = addProject?() else {
                showProjects()
                return
            }
            if !projects.contains(where: { $0.id == project.id }) { projects.append(project) }
            // T6: a freshly registered project confirms at its root too, rather
            // than dropping the user into a folder browser they did not ask for.
            confirm(project: project, relativePath: nil)
            return
        }
        if item.id == "choose-subfolder" {
            guard let selected else { return }
            showFolders(project: selected.project, relativePath: selected.homeRelativePath)
            return
        }
        if item.id.hasPrefix("recent:"),
           let recent = recents.first(where: {
               item.id == "recent:\($0.project.id.uuidString):\($0.homeRelativePath ?? "")"
           }) {
            confirm(project: recent.project, relativePath: recent.homeRelativePath)
            return
        }
        guard item.id.hasPrefix("project:"),
              let projectId = UUID(uuidString: String(item.id.dropFirst("project:".count))),
              let project = projects.first(where: { $0.id == projectId }) else { return }
        // T6: the directory you pick IS the Home. For the project that is already
        // scoped here, keep the Home it already has rather than silently resetting
        // it to the root — re-picking the current project is not a request to
        // discard its Home.
        confirm(project: project, relativePath: selected?.project.id == project.id ? selected?.homeRelativePath : nil)
    }

    private func showFolders(project: ProjectEntry, relativePath: String?) {
        guard let anchorView else { return }
        stage = .folders(project: project, relativePath: relativePath)
        let root = URL(fileURLWithPath: project.rootPath, isDirectory: true)
        let current = relativePath.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        let currentName = relativePath.flatMap { URL(fileURLWithPath: $0).lastPathComponent }
        let useTitle = relativePath == nil ? "Use Project Root" : "Use \(currentName ?? "Folder") as Home"
        var items: [ChoiceItem] = [ChoiceItem(
            id: "use-current",
            title: useTitle,
            detail: relativePath ?? compactPath(project.rootPath),
            icon: .system("checkmark")
        )]
        if relativePath != nil {
            items.append(ChoiceItem(id: "parent", title: "Parent Folder", icon: .system("arrow.up")))
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .nameKey]
        let children = (try? FileManager.default.contentsOfDirectory(
            at: current,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        )) ?? []
        for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            // `.isHiddenKey` was fetched here and never used, and `.skipsHiddenFiles`
            // was not passed — so `.git`, `.build` and `.array` were offered as Home
            // candidates alongside real source directories.
            guard let values = try? child.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true,
                  values.isHidden != true else { continue }
            let result = Result { try ProjectHomeValidator.relativeHome(projectRoot: root, selectedHome: child) }
            let relative = try? result.get()
            items.append(ChoiceItem(
                id: "folder:\(relative ?? "invalid:\(child.lastPathComponent)")",
                title: child.lastPathComponent,
                detail: relative == nil ? "Outside project or unavailable" : nil,
                icon: .system("folder"),
                enabled: relative != nil
            ))
        }
        let breadcrumb = ([project.name] + (relativePath?.split(separator: "/").map(String.init) ?? []))
            .joined(separator: "  ›  ")
        popover.present(
            items: items,
            selectedID: "use-current",
            presentation: .completions,
            layout: .completion(.init(
                breadcrumb: breadcrumb,
                footer: validationMessage ?? "Choose a folder or use the current location as Home · Esc Cancel",
                maximumVisibleRows: 7,
                minimumWidth: 380,
                maximumWidth: 480
            )),
            anchor: anchorRect,
            relativeTo: anchorView,
            placementFrame: visibleScreenFrame(for: anchorView),
            onSelection: { [weak self] item in
                guard let self else { return }
                switch item.id {
                case "use-current": self.confirm(project: project, relativePath: relativePath)
                case "parent":
                    let parent = relativePath.flatMap { path -> String? in
                        let value = (path as NSString).deletingLastPathComponent
                        return value.isEmpty ? nil : value
                    }
                    self.showFolders(project: project, relativePath: parent)
                default:
                    guard item.id.hasPrefix("folder:") else { return }
                    self.showFolders(project: project, relativePath: String(item.id.dropFirst("folder:".count)))
                }
            },
            focusReturnView: anchorView,
            onDismiss: { [weak self] in self?.handleDismissalRequest() }
        )
    }

    /// Keep the project/Home chooser inside the canvas viewport. The generic
    /// choice controller otherwise clamps to the whole screen, which lets a
    /// zone near the canvas edge place this panel over the Agents sidebar.
    private func visibleScreenFrame(for view: NSView) -> NSRect? {
        guard let window = view.window else { return nil }
        let clipped = view.bounds.intersection(view.visibleRect)
        let localFrame = clipped.isNull || clipped.isEmpty ? view.bounds : clipped
        return window.convertToScreen(view.convert(localFrame, to: nil))
    }

    private func confirm(project: ProjectEntry, relativePath: String?) {
        let root = URL(fileURLWithPath: project.rootPath, isDirectory: true)
        let selectedURL = relativePath.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        do {
            let validated = try ProjectHomeValidator.relativeHome(projectRoot: root, selectedHome: selectedURL)
            let result = ProjectHomeSelection(project: project, homeRelativePath: validated)
            popover.dismiss()
            finishInteraction()
            onConfirm?(result)
        } catch {
            NSSound.beep()
            validationMessage = error.localizedDescription
            showFolders(project: project, relativePath: relativePath)
        }
    }

    private func handleDismissalRequest() {
        if confirmsDestructiveCancellation {
            requestCancellationConfirmation()
        } else {
            finishInteraction()
            onCancel?()
        }
    }

    private func requestCancellationConfirmation() {
        guard let anchorView else { return }
        popover.present(
            items: [
                ChoiceItem(id: "keep", title: "Keep Choosing", detail: "Return to project and Home selection"),
                ChoiceItem(id: "cancel", title: "Cancel and Delete New Zone", destructive: true),
            ],
            selectedID: "keep",
            presentation: .commands,
            layout: .commands(.init(maximumVisibleRows: 2, minimumWidth: 320, maximumWidth: 420)),
            anchor: anchorRect,
            relativeTo: anchorView,
            placementFrame: visibleScreenFrame(for: anchorView),
            onSelection: { [weak self] item in
                guard let self else { return }
                if item.id == "cancel" {
                    self.finishInteraction()
                    self.onCancel?()
                } else {
                    self.restoreStageAndShake()
                }
            },
            focusReturnView: anchorView,
            onDismiss: { [weak self] in self?.restoreStageAndShake() }
        )
    }

    private func restoreStageAndShake() {
        switch stage {
        case .projects: showProjects()
        case let .folders(project, relativePath): showFolders(project: project, relativePath: relativePath)
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let panel = popover.panel else { return }
        let original = panel.frame.origin
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            panel.animator().setFrameOrigin(NSPoint(x: original.x + 5, y: original.y))
        } completionHandler: {
            Task { @MainActor in
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.08
                    panel.animator().setFrameOrigin(original)
                }
            }
        }
    }

    private func finishInteraction() {
        onInteractionOwnershipChanged?(false)
        onInteractionOwnershipChanged = nil
    }

    private func compactPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
