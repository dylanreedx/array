import AppKit
import ContinuumRevivedCore

@MainActor
final class ConductorQueueTileNSView: TileNSView {
    private(set) var renderedTaskIds: [String] = []
    private(set) var emptyStateMessage: String?
    private(set) var warningMessages: [String] = []
    private(set) var observedText: String = ""
    private let projectRoot: URL?
    nonisolated(unsafe) private var refreshTimer: Timer?

    init(tile: Tile, snapshot: ConductorQueueSnapshot, emptyStateMessage: String? = "No conductor tasks") {
        self.projectRoot = nil
        super.init(tile: tile)
        apply(snapshot: snapshot, emptyStateMessage: emptyStateMessage)
    }

    convenience init(tile: Tile, projectRoot: URL) {
        self.init(tile: tile, projectRoot: projectRoot, startTimer: true)
    }

    init(tile: Tile, projectRoot: URL, startTimer: Bool) {
        self.projectRoot = projectRoot
        super.init(tile: tile)
        refreshNow()
        if startTimer {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshNow() }
            }
        }
    }

    func refreshNow() {
        guard let projectRoot else { return }
        do {
            apply(snapshot: try ConductorQueueReader().read(projectRoot: projectRoot))
        } catch {
            apply(snapshot: ConductorQueueSnapshot(tasks: [], warnings: [String(describing: error)]), emptyStateMessage: "Conductor queue unavailable")
        }
    }

    private func apply(snapshot: ConductorQueueSnapshot, emptyStateMessage: String? = "No conductor tasks") {
        renderedTaskIds = snapshot.tasks.map(\.id)
        warningMessages = snapshot.warnings
        self.emptyStateMessage = snapshot.tasks.isEmpty && snapshot.warnings.isEmpty ? emptyStateMessage : nil
        observedText = Self.text(for: snapshot, emptyStateMessage: emptyStateMessage)

        let body = NSStackView()
        body.orientation = .vertical
        body.spacing = 8
        body.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        body.wantsLayer = true
        body.layer?.backgroundColor = NSColor(red: 0.10, green: 0.14, blue: 0.18, alpha: 1).cgColor

        let header = NSTextField(labelWithString: tile.title)
        header.font = NSFont.boldSystemFont(ofSize: 14)
        header.textColor = .white
        body.addArrangedSubview(header)

        if !snapshot.warnings.isEmpty {
            let warning = NSTextField(labelWithString: "Conductor queue unavailable: \(snapshot.warnings.joined(separator: "; "))")
            warning.font = NSFont.systemFont(ofSize: 12)
            warning.textColor = .systemOrange
            warning.lineBreakMode = .byTruncatingTail
            body.addArrangedSubview(warning)
        } else if snapshot.tasks.isEmpty {
            let empty = NSTextField(labelWithString: emptyStateMessage ?? "No conductor tasks")
            empty.font = NSFont.systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            body.addArrangedSubview(empty)
        } else {
            for task in snapshot.tasks {
                let label = NSTextField(labelWithString: Self.line(for: task))
                label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                label.textColor = .lightGray
                label.lineBreakMode = .byTruncatingTail
                body.addArrangedSubview(label)
            }
        }

        setContentView(body)
    }

    static func text(for snapshot: ConductorQueueSnapshot, emptyStateMessage: String? = "No conductor tasks") -> String {
        if !snapshot.warnings.isEmpty { return "Conductor queue unavailable: \(snapshot.warnings.joined(separator: "; "))" }
        guard !snapshot.tasks.isEmpty else { return emptyStateMessage ?? "No conductor tasks" }
        return snapshot.tasks.map(line(for:)).joined(separator: "\n")
    }

    private static func line(for task: ConductorQueueTask) -> String {
        let project = task.projectName ?? task.projectId ?? "no-project"
        return "\(task.id) · \(task.status) · p\(task.priority) · phase \(task.phase) · \(project) · attempts \(task.attemptCount) · \(task.description)"
    }

    deinit {
        refreshTimer?.invalidate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
