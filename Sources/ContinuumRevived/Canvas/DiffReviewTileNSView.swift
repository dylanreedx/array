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
    private let gitExecutableURL: URL

    init(
        tile: Tile,
        repositoryURL: URL,
        source: DiffReviewSource? = nil,
        gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        sendCommentsToAgent: (() -> Void)? = nil
    ) {
        self.gitExecutableURL = gitExecutableURL
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
        self.gitExecutableURL = URL(fileURLWithPath: "/usr/bin/git")
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

    var qaSourcePickerTitles: [String] { sourcePicker?.itemTitles ?? [] }
    var qaRenderedText: String { textView.string }

    /// QA: spin the runloop until no git work is in flight.
    @discardableResult
    func waitForPendingLoadsForQA(timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while diffLoad != nil || branchLoad != nil {
            if Date() >= deadline { return false }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return true
    }

    private func installFlybackMenuIfNeeded() {
        guard sendCommentsToAgent != nil else { return }
        let menu = NSMenu()
        let item = NSMenuItem(title: "Send Comments to Agent", action: #selector(sendCommentsToAgentMenuItem(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        textView.menu = menu
    }

    @objc private func sendCommentsToAgentMenuItem(_ sender: Any?) { sendCommentsToAgent?() }

    // MARK: - Git, off the main thread
    //
    // This view is built on the main thread at every palette spawn, boot, zone
    // hydration and workspace switch. It used to run `git diff` once per branch
    // right here in `init` (to discover the base branch, once per candidate per
    // branch) — seconds of frozen app on a repo with many branches. Now nothing
    // in `init` touches git: the diff loads in a detached task, the branch list
    // loads once the tile is actually in a window, and every result is dropped
    // if a newer request superseded it or the tile left the window.

    /// The cheap facts the picker needs: branches, the checked-out branch, and
    /// which of main/master exists. Three or four git processes, never a diff.
    private struct BranchInventory: Sendable {
        var branches: [String]
        var current: String?
        var defaultBase: String?
    }

    private var diffLoad: Task<Void, Never>?
    private var diffLoadGeneration = 0
    private var branchLoad: Task<Void, Never>?
    private var branchInventory: BranchInventory?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            loadBranchInventoryIfNeeded()
        } else {
            branchLoad?.cancel()
            branchLoad = nil
        }
    }

    private func loadBranchInventoryIfNeeded() {
        guard let repositoryURL, branchInventory == nil, branchLoad == nil else { return }
        let git = gitExecutableURL
        branchLoad = Task { @MainActor [weak self] in
            let inventory = await Task.detached(priority: .utility) {
                Self.branchInventory(repositoryURL: repositoryURL, git: git)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.branchLoad = nil
            self.branchInventory = inventory
            self.populateBranchItems(inventory)
        }
    }

    nonisolated private static func runGit(_ arguments: [String], in repositoryURL: URL, git: URL) -> String? {
        let process = Process()
        process.executableURL = git
        process.arguments = arguments
        process.currentDirectoryURL = repositoryURL
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Read to EOF BEFORE waiting: a child that fills the 64 KB pipe buffer
        // (a long branch list) blocks until someone reads it.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated private static func branchInventory(repositoryURL: URL, git: URL) -> BranchInventory {
        let branches = (runGit(["branch", "--format=%(refname:short)"], in: repositoryURL, git: git) ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }.sorted()
        let current = runGit(["branch", "--show-current"], in: repositoryURL, git: git)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultBase = ["main", "master"].first { candidate in
            runGit(["rev-parse", "--verify", "--quiet", "\(candidate)^{commit}"], in: repositoryURL, git: git) != nil
        }
        return BranchInventory(
            branches: branches,
            current: current?.isEmpty == false ? current : nil,
            defaultBase: defaultBase
        )
    }

    nonisolated private static func currentBranch(repositoryURL: URL, git: URL) throws -> String {
        let branch = runGit(["branch", "--show-current"], in: repositoryURL, git: git)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return branch.isEmpty ? "HEAD" : branch
    }

    private static let workingTreeTitle = "Working tree vs HEAD"
    private static let worktreeTitle = "This worktree branch vs base"

    private static func branchTitle(_ branch: String, base: String) -> String {
        "Branch \(branch) vs \(base)"
    }

    private static func branchRepresentation(_ branch: String, base: String) -> String {
        "\(DiffReviewSourceKind.branchVsBase.rawValue)|\(branch)|\(base)"
    }

    /// The picker starts with what needs no git: the two fixed sources and the
    /// tile's own persisted branch choice. Other branches arrive with the
    /// inventory.
    private func installSourcePicker() {
        guard repositoryURL != nil else { return }
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        picker.controlSize = .small
        picker.font = NSFont.systemFont(ofSize: 11)
        picker.addItem(withTitle: Self.workingTreeTitle)
        picker.lastItem?.representedObject = DiffReviewSourceKind.workingTreeVsHEAD.rawValue
        if sourceSelection.kind == .branchVsBase, let branch = sourceSelection.branch, let base = sourceSelection.baseBranch {
            picker.addItem(withTitle: Self.branchTitle(branch, base: base))
            picker.lastItem?.representedObject = Self.branchRepresentation(branch, base: base)
        }
        picker.addItem(withTitle: Self.worktreeTitle)
        picker.lastItem?.representedObject = DiffReviewSourceKind.worktreeVsBase.rawValue
        picker.target = self
        picker.action = #selector(sourcePickerChanged(_:))
        self.sourcePicker = picker
        selectPickerItemForCurrentSource()
        setTitleBarAccessory(picker)
    }

    private func selectPickerItemForCurrentSource() {
        guard let picker = sourcePicker else { return }
        if sourceSelection.kind == .workingTreeVsHEAD {
            picker.selectItem(withTitle: Self.workingTreeTitle)
        } else if sourceSelection.kind == .branchVsBase, let branch = sourceSelection.branch, let base = sourceSelection.baseBranch {
            picker.selectItem(withTitle: Self.branchTitle(branch, base: base))
        } else {
            picker.selectItem(withTitle: Self.worktreeTitle)
        }
    }

    private func populateBranchItems(_ inventory: BranchInventory) {
        guard let picker = sourcePicker else { return }
        let base = sourceSelection.baseBranch ?? inventory.defaultBase ?? "main"
        let worktreeIndex = picker.indexOfItem(withTitle: Self.worktreeTitle)
        var insertAt = worktreeIndex >= 0 ? worktreeIndex : picker.numberOfItems
        for branch in inventory.branches where branch != inventory.defaultBase {
            let title = Self.branchTitle(branch, base: base)
            guard picker.indexOfItem(withTitle: title) < 0 else { continue }
            picker.insertItem(withTitle: title, at: insertAt)
            picker.item(at: insertAt)?.representedObject = Self.branchRepresentation(branch, base: base)
            insertAt += 1
        }
        selectPickerItemForCurrentSource()
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

    /// Resolved from the cached inventory only — never a git call on main. A
    /// worktree source with no inventory yet leaves its branch for the diff
    /// load to resolve (off main) through `gitSource`'s resolver.
    private func resolvedSource(kind: DiffReviewSourceKind) -> DiffReviewSource {
        let base = sourceSelection.baseBranch ?? branchInventory?.defaultBase ?? "main"
        switch kind {
        case .workingTreeVsHEAD:
            return DiffReviewSource(kind: .workingTreeVsHEAD)
        case .branchVsBase:
            let branch = sourceSelection.branch ?? branchInventory?.current ?? "HEAD"
            return DiffReviewSource(kind: .branchVsBase, branch: branch, baseBranch: base)
        case .worktreeVsBase:
            return DiffReviewSource(kind: .worktreeVsBase, branch: branchInventory?.current, baseBranch: base)
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

    private enum DiffLoadOutcome: Sendable {
        case loaded(GitDiffModel)
        case failed(String)
    }

    private func reloadDiff() {
        guard let repositoryURL else { return }
        diffLoad?.cancel()
        diffLoadGeneration += 1
        let generation = diffLoadGeneration
        let source = sourceSelection
        let git = gitExecutableURL
        if renderedModel == nil { showMessage("Loading diff…") }
        diffLoad = Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> DiffLoadOutcome in
                do {
                    let gitSource = try source.gitSource(repositoryURL: repositoryURL) { url in
                        try Self.currentBranch(repositoryURL: url, git: git)
                    }
                    return .loaded(try GitDiffEngine(gitExecutableURL: git).diff(repositoryURL: repositoryURL, source: gitSource))
                } catch {
                    return .failed("Unable to load diff: \(error)")
                }
            }.value
            // A newer selection superseded this one: its result must not land.
            guard let self, !Task.isCancelled, generation == self.diffLoadGeneration else { return }
            self.diffLoad = nil
            switch outcome {
            case let .loaded(model): self.apply(model)
            case let .failed(message): self.showMessage(message)
            }
        }
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
