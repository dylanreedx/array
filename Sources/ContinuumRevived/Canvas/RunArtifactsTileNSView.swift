import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// Read-only viewer for a pi agent run directory: run.json summary + final.md.
@MainActor
final class RunArtifactsTileNSView: TileNSView {
    private(set) var textView: NSTextView
    private let scrollView: NSScrollView
    private let runDirectoryPath: String?

    override init(tile: Tile) {
        self.runDirectoryPath = tile.metadata.filePath

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.font = NSFont.token(.bodyMono)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.hasHorizontalScroller = false
        sv.drawsBackground = false
        sv.documentView = tv

        self.textView = tv
        self.scrollView = sv

        super.init(tile: tile)

        // No explicit `applyTokens()` here: `super.init` already ran it, and
        // `textView` was assigned before that call, so the override saw it.
        setContentView(sv)
        loadRunArtifacts()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func applyTokens() {
        super.applyTokens()
        applyDocumentTokens(to: textView)
    }

    override func acquireFocus(reason: FocusRequest) -> Bool {
        canvas?.bringToFront(tileId: tile.id)
        window?.makeFirstResponder(textView)
        return true
    }

    func reloadRunArtifacts() {
        loadRunArtifacts()
    }

    private func loadRunArtifacts() {
        guard let runDirectoryPath, !runDirectoryPath.isEmpty else {
            textView.string = "Run artifacts path missing."
            return
        }
        let snapshot = RunArtifactsReader.read(runDirectory: URL(fileURLWithPath: runDirectoryPath, isDirectory: true))
        textView.string = Self.render(snapshot: snapshot, runDirectoryPath: runDirectoryPath)
    }

    static func render(snapshot: RunArtifactsSnapshot, runDirectoryPath: String) -> String {
        let run = snapshot.run
        var lines: [String] = []
        lines.append("# Run Artifacts")
        lines.append("")
        lines.append("Path: \(runDirectoryPath)")
        lines.append("Run ID: \(run.id ?? "unknown")")
        lines.append("Role: \(run.role ?? "unknown")")
        lines.append("Status: \(run.status.rawValue)")
        if let createdAt = run.createdAt { lines.append("Created: \(createdAt)") }
        if let updatedAt = run.updatedAt { lines.append("Updated: \(updatedAt)") }
        if let cwd = run.cwd { lines.append("CWD: \(cwd)") }
        lines.append("Events: \(snapshot.events.events.count) parsed, \(snapshot.events.badLineCount) bad")
        if let task = run.task, !task.isEmpty {
            lines.append("")
            lines.append("## Task")
            lines.append(task)
        }
        lines.append("")
        lines.append("## final.md")
        lines.append(snapshot.finalMarkdown?.isEmpty == false ? snapshot.finalMarkdown! : "(final.md not available)")
        return lines.joined(separator: "\n")
    }
}
