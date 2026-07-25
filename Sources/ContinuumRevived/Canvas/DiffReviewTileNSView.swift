import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// Read-only hunk/file renderer for a diff review tile.
@MainActor
final class DiffReviewTileNSView: TileNSView {
    private(set) var textView: NSTextView
    private let scrollView: NSScrollView
    private let sendCommentsToAgent: (() -> Void)?
    private let repositoryURL: URL?
    private var sourceSelection: DiffReviewSource
    private var sourcePicker: NSPopUpButton?
    /// The last model rendered into the text view, so `applyTokens()` can re-render
    /// it in the new theme. `nil` until a diff is applied.
    private var renderedModel: GitDiffModel?
    var onSourceChanged: ((Tile) -> Void)?

    init(tile: Tile, repositoryURL: URL, source: DiffReviewSource? = nil, sendCommentsToAgent: (() -> Void)? = nil) {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.font = NSFont.token(.bodyMono)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.lineBreakMode = .byClipping

        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.documentView = tv

        self.textView = tv
        self.scrollView = sv
        self.sendCommentsToAgent = sendCommentsToAgent
        self.repositoryURL = repositoryURL
        self.sourceSelection = source ?? DiffReviewSource(metadata: tile.metadata)
        super.init(tile: tile)
        setContentView(sv)
        installFlybackMenuIfNeeded()
        installSourcePicker()
        reloadDiff()
    }

    init(tile: Tile, model: GitDiffModel, sendCommentsToAgent: (() -> Void)? = nil) {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.font = NSFont.token(.bodyMono)
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.lineBreakMode = .byClipping
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.documentView = tv
        self.textView = tv
        self.scrollView = sv
        self.sendCommentsToAgent = sendCommentsToAgent
        self.repositoryURL = nil
        self.sourceSelection = DiffReviewSource(metadata: tile.metadata)
        super.init(tile: tile)
        setContentView(sv)
        installFlybackMenuIfNeeded()
        apply(model)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acquireFocus(reason: FocusRequest) -> Bool {
        canvas?.bringToFront(tileId: tile.id)
        window?.makeFirstResponder(textView)
        return true
    }

    func triggerSendCommentsToAgentForQA() { sendCommentsToAgent?() }

    func selectSourceForQA(_ source: DiffReviewSource) {
        applySourceSelection(source)
    }

    func selectSourcePickerItemForQA(title: String) -> Bool {
        guard let sourcePicker, let item = sourcePicker.item(withTitle: title) else { return false }
        sourcePicker.select(item)
        sourcePickerChanged(sourcePicker)
        return true
    }

    var selectedSourceDescription: String { sourceSelection.displayName }

    private func installFlybackMenuIfNeeded() {
        guard sendCommentsToAgent != nil else { return }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Send Comments to Agent", action: #selector(sendCommentsToAgentMenuItem(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        textView.menu = menu
    }

    @objc private func sendCommentsToAgentMenuItem(_ sender: Any?) { sendCommentsToAgent?() }

    private func installSourcePicker() {
        guard repositoryURL != nil else { return }
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        picker.controlSize = .small
        picker.font = NSFont.systemFont(ofSize: 11)
        picker.addItem(withTitle: "Working tree vs HEAD")
        picker.lastItem?.representedObject = DiffReviewSourceKind.workingTreeVsHEAD.rawValue
        for branch in branchNames() where branch != defaultBaseBranch() {
            let base = sourceSelection.baseBranch ?? defaultBaseBranch() ?? "main"
            picker.addItem(withTitle: "Branch \(branch) vs \(base)")
            picker.lastItem?.representedObject = "\(DiffReviewSourceKind.branchVsBase.rawValue)|\(branch)|\(base)"
        }
        picker.addItem(withTitle: "This worktree branch vs base")
        picker.lastItem?.representedObject = DiffReviewSourceKind.worktreeVsBase.rawValue
        picker.target = self
        picker.action = #selector(sourcePickerChanged(_:))
        if sourceSelection.kind == .workingTreeVsHEAD {
            picker.selectItem(withTitle: "Working tree vs HEAD")
        } else if sourceSelection.kind == .branchVsBase, let branch = sourceSelection.branch, let base = sourceSelection.baseBranch {
            picker.selectItem(withTitle: "Branch \(branch) vs \(base)")
        } else {
            picker.selectItem(withTitle: "This worktree branch vs base")
        }
        self.sourcePicker = picker
        setTitleBarAccessory(picker)
    }

    @objc private func sourcePickerChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String else { return }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let kind = DiffReviewSourceKind(rawValue: parts[0]) else { return }
        let resolved: DiffReviewSource
        if kind == .branchVsBase, parts.count == 3 {
            resolved = DiffReviewSource(kind: .branchVsBase, branch: parts[1], baseBranch: parts[2])
        } else {
            resolved = resolvedSource(kind: kind)
        }
        applySourceSelection(resolved)
    }

    private func resolvedSource(kind: DiffReviewSourceKind) -> DiffReviewSource {
        switch kind {
        case .workingTreeVsHEAD:
            return DiffReviewSource(kind: .workingTreeVsHEAD)
        case .branchVsBase:
            let branch = sourceSelection.branch ?? currentBranch() ?? "HEAD"
            let base = sourceSelection.baseBranch ?? defaultBaseBranch() ?? "main"
            return DiffReviewSource(kind: .branchVsBase, branch: branch, baseBranch: base)
        case .worktreeVsBase:
            let base = sourceSelection.baseBranch ?? defaultBaseBranch() ?? "main"
            return DiffReviewSource(kind: .worktreeVsBase, branch: currentBranch(), baseBranch: base)
        }
    }

    private func applySourceSelection(_ source: DiffReviewSource) {
        sourceSelection = source
        var updated = tile
        updated.metadata = source.applying(to: updated.metadata)
        tile = updated
        onSourceChanged?(updated)
        reloadDiff()
    }

    private func reloadDiff() {
        guard let repositoryURL else { return }
        do {
            let model = try GitDiffEngine().diff(repositoryURL: repositoryURL, source: try sourceSelection.gitSource(repositoryURL: repositoryURL, currentBranchResolver: Self.currentBranch))
            apply(model)
        } catch {
            showMessage("Unable to load diff: \(error)")
        }
    }

    private func currentBranch() -> String? {
        try? Self.currentBranch(repositoryURL: repositoryURL!)
    }

    private static func currentBranch(repositoryURL: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["branch", "--show-current"]
        process.currentDirectoryURL = repositoryURL
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let branch = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return branch.isEmpty ? "HEAD" : branch
    }

    private func branchNames() -> [String] {
        guard let repositoryURL else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["branch", "--format=%(refname:short)"]
        process.currentDirectoryURL = repositoryURL
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }.sorted()
        } catch {
            return []
        }
    }

    private func defaultBaseBranch() -> String? {
        guard let repositoryURL else { return nil }
        let candidates = ["main", "master"]
        for candidate in candidates where (try? GitDiffEngine().diff(repositoryURL: repositoryURL, source: .branchVsBase(branch: currentBranch() ?? "HEAD", base: candidate))) != nil {
            return candidate
        }
        return nil
    }

    func apply(_ model: GitDiffModel) {
        renderedModel = model
        if model.files.isEmpty {
            textView.string = "No changes"
            return
        }
        textView.textStorage?.setAttributedString(Self.render(model, theme: effectiveTokenTheme))
    }

    override func applyTokens() {
        super.applyTokens()
        applyDocumentTokens(to: textView)
        // The diff body is an attributed string, so its colours are baked into the
        // storage rather than re-resolved at draw time — re-render it, or an
        // appearance flip leaves dark-theme accents on a light surface.
        if let renderedModel, !renderedModel.files.isEmpty {
            textView.textStorage?.setAttributedString(Self.render(renderedModel, theme: effectiveTokenTheme))
        }
    }

    struct VisibilityEvidence: CustomStringConvertible {
        var containsExpectedText = false
        var documentViewMatches = false
        var editable = true
        var visibleGlyphRange: NSRange = NSRange(location: NSNotFound, length: 0)
        var expectedGlyphRange: NSRange = NSRange(location: NSNotFound, length: 0)
        var expectedGlyphIntersectsVisibleRect = false
        var clipBounds: NSRect = .zero
        var usedRect: NSRect = .zero
        var ok: Bool { containsExpectedText && documentViewMatches && !editable && visibleGlyphRange.length > 0 && expectedGlyphRange.location != NSNotFound && expectedGlyphIntersectsVisibleRect && clipBounds.width > 0 && clipBounds.height > 0 && usedRect.width > 0 && usedRect.height > 0 }
        var description: String { "containsExpectedText=\(containsExpectedText) documentViewMatches=\(documentViewMatches) editable=\(editable) visibleGlyphRange=\(visibleGlyphRange) expectedGlyphRange=\(expectedGlyphRange) expectedGlyphIntersectsVisibleRect=\(expectedGlyphIntersectsVisibleRect) clipBounds=\(clipBounds) usedRect=\(usedRect)" }
    }

    func visibilityEvidence(containing expectedText: String) -> VisibilityEvidence {
        layoutSubtreeIfNeeded(); scrollView.layoutSubtreeIfNeeded(); textView.layoutSubtreeIfNeeded()
        var evidence = VisibilityEvidence()
        evidence.containsExpectedText = textView.string.contains(expectedText)
        evidence.documentViewMatches = scrollView.documentView === textView
        evidence.editable = textView.isEditable
        evidence.clipBounds = scrollView.contentView.bounds
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return evidence }
        layoutManager.ensureLayout(for: textContainer)
        evidence.usedRect = layoutManager.usedRect(for: textContainer)
        evidence.visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: textContainer)
        if let range = textView.string.range(of: expectedText) {
            let nsRange = NSRange(range, in: textView.string)
            evidence.expectedGlyphRange = layoutManager.glyphRange(forCharacterRange: nsRange, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: evidence.expectedGlyphRange, in: textContainer)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            evidence.expectedGlyphIntersectsVisibleRect = rect.intersects(textView.visibleRect)
        }
        return evidence
    }

    private func showMessage(_ message: String) { textView.string = message }

    /// P1.11: the diff's six colours are `AccentToken`s resolved for `theme`, not
    /// `NSColor.system*`. The system colours were the shipped defect twice over —
    /// `systemOrange` measures 2.31:1 on a near-white surface (P0.4's own finding,
    /// root cause 3) and none of them moved with the appearance because the text
    /// view held a fixed dark fill underneath.
    ///
    /// The mapping is by MEANING, and it is the same one `StatusChipPresenter`
    /// already uses for a status: an addition is a done/good thing (`accentDone`),
    /// a deletion is a failure-shaped one (`accentFailed`), a file header is the
    /// thing being worked on (`accentWorking`), a hunk header is structure
    /// (`accentInput`, the palette's violet), and metadata is the "look at this"
    /// amber (`accentApproval`). Context lines are prose, so `textSecondary`.
    ///
    /// `theme` is a parameter rather than read from a view because this is a pure
    /// renderer — which is also what lets `runDiffRenderTokenCheck` assert both
    /// themes without hosting a window.
    static func render(_ model: GitDiffModel, theme: TokenTheme) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.token(.bodyMono),
            .foregroundColor: TextToken.textPrimary.color.nsColor(for: theme)
        ]
        func color(_ token: AccentToken) -> NSColor { token.color.nsColor(for: theme) }
        func append(_ text: String, color: NSColor, background: NSColor? = nil) {
            var attrs = base
            attrs[.foregroundColor] = color
            if let background { attrs[.backgroundColor] = background }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        let context = TextToken.textSecondary.color.nsColor(for: theme)
        for file in model.files {
            let path = file.newPath ?? file.oldPath ?? "(unknown)"
            append("diff -- \(path) [\(file.change.rawValue)]\n", color: color(.accentWorking))
            if file.isBinary { append("Binary file changed\n\n", color: color(.accentApproval)); continue }
            for hunk in file.hunks {
                append("\(hunk.header)\n", color: color(.accentInput))
                for line in hunk.lines {
                    switch line.kind {
                    // The 10% wash behind a changed line is kept: it is the
                    // gutter-free way a diff says "this line moved", and the READ
                    // comes from the accent-on-`tileBody` foreground, which IS one
                    // of P1.3's documented pairs.
                    case .addition:
                        append("+\(line.text)\n", color: color(.accentDone),
                               background: color(.accentDone).withAlphaComponent(0.10))
                    case .deletion:
                        append("-\(line.text)\n", color: color(.accentFailed),
                               background: color(.accentFailed).withAlphaComponent(0.10))
                    case .metadata: append("\(line.text)\n", color: color(.accentApproval))
                    case .context: append(" \(line.text)\n", color: context)
                    }
                }
            }
            append("\n", color: context)
        }
        return out
    }
}
