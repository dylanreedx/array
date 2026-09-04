import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// Tile view for a single file: source files are readable agent-change
/// projections, while Markdown documents share Preview/Split/Edit behavior
/// with notes and retain explicit repository-file save semantics.
@MainActor
final class FileTileNSView: TileNSView, NSTextViewDelegate, NSSplitViewDelegate {
    typealias Mode = MarkdownDocumentMode

    private struct RecoveryDraft: Codable, Equatable {
        var filePath: String
        var baseText: String
        var draftText: String
        var updatedAt: Date
    }

    private struct FileSignature: Equatable {
        var modificationDate: Date?
        var byteCount: UInt64?
        var fileNumber: UInt64?
    }

    private(set) var textView: NSTextView
    private let scrollView: NSScrollView
    private var filePath: String?
    private var sourceLanguage: FilePreview.SourceLanguage
    private var documentSession: FileDocumentSession?
    private var codeEditor: CodeEditorHostView?
    private var documentGeneration = UUID()
    private var bridgeDocumentID: String { (filePath ?? "") + "#" + documentGeneration.uuidString }
    private var documentTransitionPending = false
    var isCodeEditorFocused: Bool {
        guard let codeEditor, let responder = window?.firstResponder as? NSView else { return false }
        return responder === codeEditor.webView || responder.isDescendant(of: codeEditor.webView)
    }
    private var editorAppearanceButton: NSButton?
    private let vimModeLabel = NSTextField(labelWithString: "")
    var qaSetSwitchDecision: (() -> NSApplication.ModalResponse)?
    var qaCodeEditor: CodeEditorHostView? { codeEditor }
    var qaDocumentID: String { bridgeDocumentID }
    var qaDraftText: String? { documentSession?.draftText }
    var qaSidebarRoot: String? { fileBrowser == nil ? nil : tile.metadata.documentLocation?.checkoutRootPath }
    var onOpenEditorSettings: (() -> Void)?
    var onNavigateDocument: ((URL, UUID, EditorDocumentOpenDisposition) -> Void)?

    private weak var languageServiceManager: EditorLanguageServiceManager?
    private let markdownEditorSplit = NSSplitView()
    private let editorSplitView = NSSplitView()
    private let documentContainer = NSView()
    private var fileBrowser: FileTreeBrowserView?
    private var sidebarButton: NSButton?
    private var rebuildingEditorShell = false
    private var editorState: FileEditorViewState
    private var lineNumberRuler: CodeLineNumberRulerView?
    private var languageLabel: NSTextField?
    private(set) var mode: Mode = .preview
    private(set) var presentation: FilePreview.Presentation = .sourceText
    /// One immutable loaded-text snapshot shared by both modes, so switching is
    /// instant and Preview can never drift from Source inside one tile.
    private(set) var loadedText: String?
    private var markdownSurface: MarkdownDocumentSurface?
    private var modeControl: NSSegmentedControl?
    private var markdownFormatControl: NSPopUpButton?
    private let dirtyLabel = NSTextField(labelWithString: "")
    private let referenceLabel = NSTextField(labelWithString: "")
    private var titleAccessoryStack: NSStackView?
    var onRevealReferencedAgentTile: ((UUID) -> Void)?
    var onOpenDocument: ((URL, UUID) -> Void)?
    var onOpenExternally: ((URL) -> Void)?
    var onEditorStateChange: ((Tile) -> Void)?
    var onLanguageDocumentChange: ((URL, String, UInt64) -> Void)?
    var onLanguageDocumentSave: ((URL) -> Void)?
    var onLanguageDocumentClose: ((URL) -> Void)?
    private(set) var isDirty = false
    private(set) var hasExternalConflict = false
    private var savedText: String?
    private var loadedFileSignature: FileSignature?
    private var externalChangeTimer: Timer?
    private var recoverySaveTimer: Timer?
    private var editorStateSaveTimer: Timer?
    var onSaveFailure: ((String) -> Void)?
    private var pendingReveal: (line: Int, column: Int?)?
    private var lastEditorRevealLine: Int?
    /// The "file unavailable" placeholder, built lazily by `showMessage`. Held so
    /// `applyTokens()` can re-paint it — it is a content view like any other, and
    /// a placeholder that stays dark under Aqua is the same bug as a tile that does.
    private var messageLabel: NSTextField?
    private var messageContainer: NSView?
    private var trashedOriginalURL: URL?
    private var trashedItemURL: URL?

    override init(tile: Tile) {
        let resolvedPath = tile.metadata.documentLocation?.path ?? tile.metadata.filePath
        self.filePath = resolvedPath
        self.sourceLanguage = FilePreview.sourceLanguage(
            forPath: resolvedPath ?? ""
        )
        self.documentSession = resolvedPath.map(FileDocumentSession.init(path:))
        self.editorState = tile.metadata.fileEditorViewState ?? FileEditorViewState(sidebarExpanded: false)

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.font = NSFont.token(.bodyMono)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 8, height: 8)
        // Match NoteTileNSView's NSScrollView document-view layout. The
        // NSClipView owns its document view frame via autoresizing; adding
        // Auto Layout constraints to the NSTextView can leave loaded file text
        // present in `string` but invisible due to a zero-height document view.
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        // File tiles preserve code-file usability: long source lines should be
        // horizontally scrollable instead of wrapped like notes. The document
        // view still avoids Auto Layout; AppKit owns the NSClipView/document
        // relationship while the text container lays out against an effectively
        // unbounded width.
        tv.isHorizontallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        tv.textContainer?.lineBreakMode = .byClipping

        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.hasHorizontalScroller = true
        sv.drawsBackground = false
        sv.documentView = tv

        self.textView = tv
        self.scrollView = sv

        super.init(tile: tile)

        NotificationCenter.default.addObserver(self, selector: #selector(projectFileMoved(_:)), name: .arrayProjectFileMoved, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(projectFileTrashed(_:)), name: .arrayProjectFileTrashed, object: nil)
        for key in EditorPreferences.allKeys {
            NotificationCenter.default.addObserver(self, selector: #selector(editorPreferencesChanged(_:)),
                name: SettingChangeEvent.name(for: SettingID(rawValue: key)), object: nil)
        }
        configureEditorShell()
        tv.delegate = self
        loadFile()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            externalChangeTimer?.invalidate()
            externalChangeTimer = nil
        } else if loadedText != nil {
            startExternalChangeMonitoring()
        }
    }

    override func prepareForRemovalFromScene() {
        externalChangeTimer?.invalidate()
        externalChangeTimer = nil
        flushRecoveryDraft()
        editorStateSaveTimer?.invalidate()
        persistEditorState()
        fileBrowser?.stop()
        if let filePath { onLanguageDocumentClose?(URL(fileURLWithPath: filePath)) }
        codeEditor?.tearDown()
    }

    override func applyTokens() {
        super.applyTokens()
        applyDocumentTokens(to: textView)
        if presentation == .sourceText, loadedText != nil { applyCodePresentation() }
        messageContainer?.layer?.backgroundColor = SurfaceToken.tileBody.color.cgColor(in: self)
        messageLabel?.textColor = TextToken.textSecondary.color.nsColor(in: self)
        markdownSurface?.applyTheme()
        fileBrowser?.applyTokens()
        applyEditorPreferences()
        bumpSurfaceEpoch()
    }

    override func acquireFocus(reason: FocusRequest) -> Bool {
        canvas?.bringToFront(tileId: tile.id)
        // Before targeting a view inside the body: while surfaced, that view is
        // PARKED, and AppKit will happily focus it there.
        promoteForIncomingFocus()
        if (presentation == .sourceText || mode != .preview), let codeEditor {
            codeEditor.focusEditor(documentID: bridgeDocumentID)
        } else {
            window?.makeFirstResponder(mode == .preview ? (markdownSurface?.previewView ?? textView) : textView)
        }
        return true
    }

    // MARK: - Surface residency (Option A, `.plans/38`)

    /// A markdown file tile was the HEAVIEST body in the real-gesture profile —
    /// a 183-block document re-measuring inside the camera cascade — and it is
    /// content that changes only when the file is reloaded, the mode switches, or
    /// the theme does. The ideal candidate for rendering from a surface at rest.
    ///
    /// The body handle is tracked (`activeBody`), not derived from `contentView`:
    /// this family swaps its content view between the source scroller, the
    /// markdown document and the unavailable-message placeholder, and while
    /// surfaced `contentView` is the surface host.
    private var activeBody: NSView?
    private var surfaceEpoch: UInt64 = 1

    override var surfacesTitleAccessory: Bool { true }

    override var surfaceableBody: NSView? {
        // WKWebView snapshots are intentionally excluded until a dedicated
        // visual/performance witness proves they survive canvas residency.
        if presentation == .sourceText || (presentation == .markdown && mode != .preview) { return nil }
        return activeBody
    }
    override var surfaceContentRevision: UInt64? { surfaceEpoch }

    /// `activeBody` is a scroll view for some file kinds and a container holding
    /// one for others, so both shapes are covered — one level only, deliberately:
    /// this is polled per residency pass.
    override var surfaceScrollOffsets: [CGPoint] {
        guard let body = activeBody else { return [] }
        if let scrollView = body as? NSScrollView { return [scrollView.contentView.bounds.origin] }
        return body.subviews.compactMap { ($0 as? NSScrollView)?.contentView.bounds.origin }
    }

    /// Anything that changes what the body renders. Appearance is already in the
    /// revision vector; the epoch covers content and mode.
    private func bumpSurfaceEpoch() { surfaceEpoch &+= 1 }

    private var editorTheme: EditorThemeTokens {
        EditorPreferences().resolve(systemIsDark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }
    private var editorTokenTheme: TokenTheme { editorTheme.isDark ? .dark : .light }

    @objc private func editorPreferencesChanged(_ notification: Notification) { applyEditorPreferences() }

    private func applyEditorPreferences() {
        let preferences = EditorPreferences()
        let theme = editorTheme
        let appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        documentContainer.appearance = appearance
        editorSplitView.appearance = appearance
        markdownEditorSplit.appearance = appearance
        fileBrowser?.applyEditorAppearance(isDark: theme.isDark)
        codeEditor?.setPreferences(preferences, isDark: theme.isDark)
        markdownSurface?.applyTheme()
        vimModeLabel.isHidden = !preferences.vimEnabled
        if preferences.vimEnabled && vimModeLabel.stringValue.isEmpty { vimModeLabel.stringValue = "NORMAL" }
        func color(_ key: KeyPath<EditorThemeTokens, String>) -> NSColor {
            StatusChipNSView.nsColor(theme.resolvedColor(key))
        }
        documentContainer.wantsLayer = true
        documentContainer.layer?.backgroundColor = color(\.background).cgColor
        textView.backgroundColor = color(\.background)
        if presentation == .markdown { textView.textColor = color(\.foreground) }
        textView.insertionPointColor = color(\.accent)
        messageContainer?.layer?.backgroundColor = color(\.background).cgColor
        messageLabel?.textColor = color(\.mutedForeground)
        vimModeLabel.textColor = color(\.accent)
        bumpSurfaceEpoch()
    }

    @objc private func showEditorMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let preferences = EditorPreferences()
        for appearance in EditorAppearance.allCases {
            let item = NSMenuItem(title: appearance.rawValue + " Appearance", action: #selector(selectEditorAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = appearance.rawValue
            item.state = preferences.appearance == appearance ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let vim = NSMenuItem(title: "Vim Mode — All Editors", action: #selector(toggleEditorVim(_:)), keyEquivalent: "")
        vim.target = self
        vim.state = preferences.vimEnabled ? .on : .off
        menu.addItem(vim)
        let settings = NSMenuItem(title: "Editor Settings…", action: #selector(openEditorSettings(_:)), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    @objc private func selectEditorAppearance(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        UserDefaults.standard.set(value, forKey: EditorPreferences.appearanceKey)
        SettingChangeEvent.post(SettingID(rawValue: EditorPreferences.appearanceKey))
    }
    @objc private func toggleEditorVim(_ sender: Any?) { EditorPreferences.setVimEnabled(!EditorPreferences().vimEnabled) }
    @objc private func openEditorSettings(_ sender: Any?) { onOpenEditorSettings?() }

    private func navigateDocument(_ url: URL, disposition: EditorDocumentOpenDisposition) {
        if let onNavigateDocument { onNavigateDocument(url, tile.id, disposition) }
        else { onOpenDocument?(url, tile.id) }
    }

    /// Freeze web input while the snapshot crosses the bridge. Native draft and
    /// revision become authoritative before presenting any Save/Discard choice.
    func flushEditorBarrier(_ completion: @escaping (Bool) -> Void) {
        guard !documentTransitionPending else { completion(false); return }
        guard let codeEditor else { completion(true); return }
        documentTransitionPending = true
        let identity = bridgeDocumentID
        var finished = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard !finished else { return }
            finished = true
            self?.resumeEditorAfterBarrier()
            self?.showSaveFailure("The editor did not respond. Your current draft is retained; try again.")
            completion(false)
        }
        codeEditor.requestSnapshot(documentID: identity, freeze: true) { [weak self] result in
            guard !finished else { return }
            finished = true
            guard let self, identity == self.bridgeDocumentID else { completion(false); return }
            switch result {
            case let .success(snapshot):
                self.replaceDraftFromEditor(snapshot)
                completion(true)
            case .failure:
                self.resumeEditorAfterBarrier()
                completion(false)
            }
        }
    }

    func restoreCurrentFileSelection() {
        fileBrowser?.selectFile(filePath.map { URL(fileURLWithPath: $0) })
    }

    func resumeEditorAfterBarrier() {
        documentTransitionPending = false
        restoreCurrentFileSelection()
        codeEditor?.runCommand(documentID: bridgeDocumentID, command: "resumeEditing")
    }

    private func saveFromEditor() {
        flushEditorBarrier { [weak self] success in
            guard let self else { return }
            if success { _ = self.saveInteractively() }
            self.resumeEditorAfterBarrier()
        }
    }

    /// One tile owns one document. Navigation commits only after draft handling
    /// and relationship persistence succeed; geometry and sidebar state survive.
    func switchDocument(to location: DocumentLocation, beforeCommit: @escaping () throws -> Void,
                        completion: @escaping (Bool) -> Void = { _ in }) {
        guard location.path != filePath else { completion(true); return }
        flushEditorBarrier { [weak self] success in
            guard let self else { completion(false); return }
            guard success else { completion(false); return }
            if self.isDirty {
                let alert = NSAlert()
                alert.messageText = "Save changes before switching files?"
                alert.informativeText = URL(fileURLWithPath: self.filePath ?? "").lastPathComponent
                alert.addButton(withTitle: "Save")
                alert.addButton(withTitle: "Discard")
                alert.addButton(withTitle: "Cancel")
                switch self.qaSetSwitchDecision?() ?? alert.runModal() {
                case .alertFirstButtonReturn:
                    guard self.saveInteractively() else {
                        self.resumeEditorAfterBarrier(); completion(false); return
                    }
                case .alertSecondButtonReturn: break
                default: self.resumeEditorAfterBarrier(); completion(false); return
                }
            }
            do { try beforeCommit() }
            catch {
                self.showSaveFailure(error.localizedDescription)
                self.resumeEditorAfterBarrier(); completion(false); return
            }
            self.recoverySaveTimer?.invalidate()
            self.editorStateSaveTimer?.invalidate()
            self.externalChangeTimer?.invalidate()
            self.discardRecoveryDraft()
            if let path = self.filePath { self.onLanguageDocumentClose?(URL(fileURLWithPath: path)) }
            self.onLanguageDocumentChange = nil
            self.onLanguageDocumentSave = nil
            self.onLanguageDocumentClose = nil
            // Keep WebKit mounted; loading a new document resets its editing state.
            self.documentGeneration = UUID()
            self.documentTransitionPending = false
            let oldRoot = self.tile.metadata.documentLocation?.checkoutRootPath
            self.filePath = location.path
            self.documentSession = FileDocumentSession(path: location.path)
            self.sourceLanguage = FilePreview.sourceLanguage(forPath: location.path)
            self.loadedText = nil
            self.savedText = nil
            self.markdownSurface = nil
            self.modeControl = nil
            self.markdownFormatControl = nil
            self.languageLabel = nil
            self.mode = .preview
            self.pendingReveal = nil
            self.trashedOriginalURL = nil
            self.trashedItemURL = nil
            self.hasExternalConflict = false
            self.setDirty(false)
            self.setReferencedAgentTiles([])
            self.editorState.cursorLine = 1
            self.editorState.cursorColumn = 1
            self.editorState.verticalScrollOffset = 0
            self.editorState.horizontalScrollOffset = 0
            self.tile.metadata.filePath = location.path
            self.tile.metadata.documentLocation = location
            self.tile.metadata.markdownDocumentMode = nil
            self.tile.title = URL(fileURLWithPath: location.path).lastPathComponent
            if oldRoot != location.checkoutRootPath {
                self.fileBrowser?.stop()
                self.fileBrowser?.removeFromSuperview()
                self.fileBrowser = nil
                self.sidebarButton = nil
                self.editorState.expandedPaths = []
                self.editorState.searchQuery = ""
                self.editorState.selectedPath = nil
                self.configureEditorShell()
            }
            self.editorState.selectedPath = location.relativePath
            self.fileBrowser?.selectFile(URL(fileURLWithPath: location.path))
            self.persistEditorState()
            self.loadFile()
            self.applyEditorPreferences()
            completion(true)
        }
    }

    // MARK: - Editor shell

    private func configureEditorShell() {
        editorSplitView.delegate = self
        editorSplitView.isVertical = true
        editorSplitView.dividerStyle = .thin
        editorSplitView.autosaveName = nil
        documentContainer.wantsLayer = true

        if let rootPath = tile.metadata.documentLocation?.checkoutRootPath {
            let persisted = tile.metadata.fileEditorViewState
            let browserState = FileTreeBrowserView.State(
                expandedPaths: persisted?.expandedPaths ?? [],
                selectedPath: persisted?.selectedPath,
                searchQuery: persisted?.searchQuery ?? ""
            )
            let browser = FileTreeBrowserView(
                rootURL: URL(fileURLWithPath: rootPath, isDirectory: true),
                state: browserState
            )
            browser.onActivateFile = { [weak self] url in
                guard let self else { return }
                self.navigateDocument(url, disposition: .replaceCurrent)
            }
            browser.onOpenInNewTile = { [weak self] url in self?.navigateDocument(url, disposition: .newTile) }
            browser.onOpenExternally = { [weak self] url in self?.onOpenExternally?(url) }
            browser.onCreateFile = { [weak self] parent in self?.promptToCreate(in: parent, directory: false) }
            browser.onCreateFolder = { [weak self] parent in self?.promptToCreate(in: parent, directory: true) }
            browser.onRename = { [weak self] url in self?.promptToRename(url) }
            browser.onMoveToTrash = { [weak self] url in self?.confirmMoveToTrash(url) }
            browser.onStateChange = { [weak self] state in self?.persistBrowserState(state) }
            fileBrowser = browser
        }

        installSidebarButton()
        rebuildEditorShell(documentBody: scrollView)
    }

    private func installSidebarButton() {
        guard fileBrowser != nil else { return }
        let button = NSButton(
            image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle files")!,
            target: self,
            action: #selector(toggleSidebar(_:))
        )
        button.title = "Files"
        button.imagePosition = .imageLeading
        button.isBordered = false
        button.controlSize = .small
        button.toolTip = "Show or hide project files"
        sidebarButton = button
        rebuildTitleAccessory()
    }

    private func rebuildTitleAccessory() {
        dirtyLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        dirtyLabel.textColor = .systemOrange
        referenceLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        referenceLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        referenceLabel.isHidden = referenceLabel.stringValue.isEmpty
        if editorAppearanceButton == nil {
            let button = NSButton(image: NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Editor appearance and Vim")!, target: self, action: #selector(showEditorMenu(_:)))
            button.isBordered = false
            button.toolTip = "Editor appearance and Vim"
            editorAppearanceButton = button
        }
        vimModeLabel.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        vimModeLabel.isHidden = !EditorPreferences().vimEnabled
        var views: [NSView] = [referenceLabel, dirtyLabel, vimModeLabel]
        if let editorAppearanceButton { views.append(editorAppearanceButton) }
        if let sidebarButton { views.append(sidebarButton) }
        if let languageLabel { views.append(languageLabel) }
        if let markdownFormatControl { views.append(markdownFormatControl) }
        if let modeControl { views.append(modeControl) }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 4
        titleAccessoryStack = stack
        setTitleBarAccessory(stack)
    }

    private func rebuildEditorShell(documentBody: NSView) {
        let expectedSubviews: [NSView] = editorState.sidebarExpanded
            ? [fileBrowser, documentContainer].compactMap { $0 }
            : [documentContainer]
        if documentBody.superview === documentContainer,
           editorSplitView.subviews == expectedSubviews { return }
        rebuildingEditorShell = true
        defer { rebuildingEditorShell = false }
        promoteForIncomingFocus()
        editorSplitView.subviews.forEach { $0.removeFromSuperview() }
        documentContainer.subviews.forEach { $0.removeFromSuperview() }
        documentBody.translatesAutoresizingMaskIntoConstraints = false
        documentContainer.addSubview(documentBody)
        NSLayoutConstraint.activate([
            documentBody.leadingAnchor.constraint(equalTo: documentContainer.leadingAnchor),
            documentBody.trailingAnchor.constraint(equalTo: documentContainer.trailingAnchor),
            documentBody.topAnchor.constraint(equalTo: documentContainer.topAnchor),
            documentBody.bottomAnchor.constraint(equalTo: documentContainer.bottomAnchor)
        ])
        if editorState.sidebarExpanded, let browser = fileBrowser {
            editorSplitView.addSubview(browser)
            editorSplitView.addSubview(documentContainer)
            let total = max(bounds.width, 500)
            let width = min(max(CGFloat(editorState.sidebarWidth), 150), total * 0.55)
            editorSplitView.setPosition(width, ofDividerAt: 0)
            browser.start()
        } else {
            fileBrowser?.stop()
            editorSplitView.addSubview(documentContainer)
        }
        setContentView(editorSplitView)
        activeBody = editorSplitView
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard splitView === editorSplitView else { splitView.adjustSubviews(); return }
        let size = splitView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if editorState.sidebarExpanded, let browser = fileBrowser, splitView.subviews.count == 2 {
            let width = min(max(CGFloat(editorState.sidebarWidth), 160), min(320, size.width * 0.45))
            browser.frame = NSRect(x: 0, y: 0, width: width, height: size.height)
            let start = width + splitView.dividerThickness
            documentContainer.frame = NSRect(x: start, y: 0, width: max(0, size.width - start), height: size.height)
        } else { documentContainer.frame = splitView.bounds }
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !rebuildingEditorShell, notification.object as? NSSplitView === editorSplitView,
              editorState.sidebarExpanded, let browser = fileBrowser, browser.frame.width > 0 else { return }
        editorState.sidebarWidth = Double(browser.frame.width)
        editorStateSaveTimer?.invalidate()
        editorStateSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.persistEditorState() }
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView === editorSplitView ? 160 : proposedMinimumPosition
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView === editorSplitView ? min(360, splitView.bounds.width * 0.55) : proposedMaximumPosition
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        editorState.sidebarExpanded.toggle()
        persistEditorState()
        rebuildEditorShell(documentBody: currentDocumentBody())
    }

    private func currentDocumentBody() -> NSView {
        if presentation == .sourceText, let codeEditor { return codeEditor }
        if presentation == .markdown, let markdownSurface {
            switch mode {
            case .preview: return markdownSurface.previewBody()
            case .edit: return codeEditor ?? scrollView
            case .split: return markdownEditorSplit
            }
        }
        return scrollView
    }

    private func persistBrowserState(_ state: FileTreeBrowserView.State) {
        editorState.expandedPaths = state.expandedPaths
        editorState.selectedPath = state.selectedPath
        editorState.searchQuery = state.searchQuery
        persistEditorState()
    }

    private func persistEditorState() {
        tile.metadata.fileEditorViewState = editorState
        canvas?.updateTile(tile, recalculateZoneBounds: false)
        onEditorStateChange?(tile)
    }

    private func promptName(title: String, value: String = "") -> String? {
        let field = NSTextField(string: value)
        field.placeholderString = "Name"
        field.frame.size.width = 300
        let alert = NSAlert()
        alert.messageText = title
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        window?.makeFirstResponder(field)
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    private func promptToCreate(in parent: URL, directory: Bool) {
        guard let root = tile.metadata.documentLocation?.checkoutRootPath, let fileBrowser else { return }
        fileBrowser.beginNameEntry(initialValue: "", placeholder: directory ? "New folder name" : "New file name") { [weak self] name in
            guard let self, let name, self.tile.metadata.documentLocation?.checkoutRootPath == root else { return }
            do {
                let coordinator = ProjectFileOperationCoordinator(rootURL: URL(fileURLWithPath: root))
                let url = directory ? try coordinator.createDirectory(parent: parent, name: name)
                    : try coordinator.createFile(parent: parent, name: name)
                self.fileBrowser?.refresh()
                if !directory { self.navigateDocument(url, disposition: .replaceCurrent) }
            } catch { self.presentFileOperationError(error) }
        }
    }

    private func promptToRename(_ url: URL) {
        guard let root = tile.metadata.documentLocation?.checkoutRootPath, let fileBrowser else { return }
        fileBrowser.beginNameEntry(initialValue: url.lastPathComponent, placeholder: "Rename file or folder") { [weak self] name in
            guard let self, let name, name != url.lastPathComponent,
                  self.tile.metadata.documentLocation?.checkoutRootPath == root else { return }
            do {
                let result = try ProjectFileOperationCoordinator(rootURL: URL(fileURLWithPath: root)).rename(entry: url, newName: name)
                NotificationCenter.default.post(name: .arrayProjectFileMoved, object: nil,
                    userInfo: ["source": result.source.path, "destination": result.destination.path, "directory": result.isDirectory])
                self.fileBrowser?.refresh()
            } catch { self.presentFileOperationError(error) }
        }
    }

    private func confirmMoveToTrash(_ url: URL) {
        guard let root = tile.metadata.documentLocation?.checkoutRootPath else { return }
        let alert = NSAlert()
        alert.messageText = "Move “\(url.lastPathComponent)” to Trash?"
        let affectsThisDraft = filePath.map {
            Self.replacingPathPrefix($0, source: url.path, destination: url.path) != nil
        } ?? false
        alert.informativeText = affectsThisDraft && isDirty
            ? "This editor has unsaved changes. Save them first, discard them, or cancel."
            : "Open editor drafts will be kept available."
        alert.alertStyle = .warning
        if affectsThisDraft && isDirty {
            alert.addButton(withTitle: "Save & Move to Trash")
            alert.addButton(withTitle: "Discard & Move to Trash")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: guard saveInteractively() else { return }
            case .alertSecondButtonReturn: discardUnsavedChanges()
            default: return
            }
        } else {
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            let result = try ProjectFileOperationCoordinator(rootURL: URL(fileURLWithPath: root)).moveToTrash(entry: url)
            NotificationCenter.default.post(
                name: .arrayProjectFileTrashed,
                object: nil,
                userInfo: [
                    "source": result.original.path,
                    "trash": result.trashed?.path as Any,
                    "directory": result.isDirectory
                ]
            )
            fileBrowser?.refresh()
        } catch { presentFileOperationError(error) }
    }

    private func presentFileOperationError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "File operation failed"
        alert.runModal()
    }

    @objc private func projectFileMoved(_ notification: Notification) {
        guard let current = filePath,
              let source = notification.userInfo?["source"] as? String,
              let destination = notification.userInfo?["destination"] as? String,
              let mapped = Self.replacingPathPrefix(current, source: source, destination: destination) else { return }
        onLanguageDocumentClose?(URL(fileURLWithPath: current))
        let draft = documentSession?.draftText ?? loadedText
        filePath = mapped
        sourceLanguage = FilePreview.sourceLanguage(forPath: mapped)
        let replacement = FileDocumentSession(path: mapped)
        if let draft, replacement.draftText != draft { _ = replacement.updateDraft(draft) }
        documentSession = replacement
        loadedText = draft ?? replacement.draftText
        savedText = replacement.baselineText
        tile.metadata.filePath = mapped
        if var location = tile.metadata.documentLocation {
            location.path = mapped
            if case let .checkout(projectId, rootPath, _) = location.scope {
                let root = URL(fileURLWithPath: rootPath, isDirectory: true)
                let relative = URL(fileURLWithPath: mapped).pathComponents
                    .dropFirst(root.pathComponents.count).joined(separator: "/")
                location.scope = .checkout(projectId: projectId, rootPath: rootPath, relativePath: relative)
            }
            tile.metadata.documentLocation = location
        }
        if current == source { tile.title = URL(fileURLWithPath: mapped).lastPathComponent }
        canvas?.updateTile(tile, recalculateZoneBounds: false)
        configureCodeEditorIfNeeded()
        setDirty(replacement.isDirty)
        if let languageServiceManager { connectLanguageServices(languageServiceManager) }
    }

    @objc private func projectFileTrashed(_ notification: Notification) {
        guard let current = filePath,
              let source = notification.userInfo?["source"] as? String,
              Self.replacingPathPrefix(current, source: source, destination: source) != nil else { return }
        flushRecoveryDraft()
        trashedOriginalURL = URL(fileURLWithPath: current)
        if let trashRoot = notification.userInfo?["trash"] as? String {
            trashedItemURL = URL(fileURLWithPath: Self.replacingPathPrefix(
                current, source: source, destination: trashRoot
            ) ?? trashRoot)
        }
        showMissingFileActions("File moved to Trash. Your editor draft is preserved.")
    }

    private func showMissingFileActions(_ message: String) {
        let label = NSTextField(labelWithString: message)
        label.alignment = .center
        label.maximumNumberOfLines = 0
        let restore = NSButton(title: "Restore", target: self, action: #selector(restoreTrashedFile(_:)))
        restore.isEnabled = trashedItemURL != nil
        let saveAs = NSButton(title: "Save As…", target: self, action: #selector(saveMissingDraftAs(_:)))
        let buttons = NSStackView(views: [restore, saveAs])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [label, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16)
        ])
        messageLabel = label
        messageContainer = container
        setContentView(container)
        activeBody = container
        applyTokens()
    }

    @objc private func restoreTrashedFile(_ sender: Any?) {
        guard let source = trashedItemURL, let destination = trashedOriginalURL else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            presentFileOperationError(ProjectFileOperationCoordinator.OperationError.collision(destination.lastPathComponent))
            return
        }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: source, to: destination)
            trashedItemURL = nil
            trashedOriginalURL = nil
            refreshFromDisk(force: true)
            showBody()
        } catch { presentFileOperationError(error) }
    }

    @objc private func saveMissingDraftAs(_ sender: Any?) {
        guard let draft = documentSession?.draftText ?? loadedText else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = trashedOriginalURL?.lastPathComponent ?? filePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Untitled"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw ProjectFileOperationCoordinator.OperationError.collision(url.lastPathComponent)
            }
            try Data(draft.utf8).write(to: url, options: [.atomic, .withoutOverwriting])
            relocateDocument(to: url.standardizedFileURL.resolvingSymlinksInPath().path, preservingDraft: draft)
            trashedItemURL = nil
            trashedOriginalURL = nil
            showBody()
        } catch { presentFileOperationError(error) }
    }

    private func relocateDocument(to mapped: String, preservingDraft draft: String?) {
        if let filePath { onLanguageDocumentClose?(URL(fileURLWithPath: filePath)) }
        codeEditor?.tearDown()
        codeEditor?.removeFromSuperview()
        codeEditor = nil
        documentGeneration = UUID()
        filePath = mapped
        sourceLanguage = FilePreview.sourceLanguage(forPath: mapped)
        let replacement = FileDocumentSession(path: mapped)
        if let draft, replacement.draftText != draft { _ = replacement.updateDraft(draft) }
        documentSession = replacement
        loadedText = draft ?? replacement.draftText
        savedText = replacement.baselineText
        tile.metadata.filePath = mapped
        if var location = tile.metadata.documentLocation {
            location.path = mapped
            if case let .checkout(projectId, rootPath, _) = location.scope,
               DocumentLocationResolver.contains(URL(fileURLWithPath: mapped), in: URL(fileURLWithPath: rootPath)) {
                let root = URL(fileURLWithPath: rootPath, isDirectory: true)
                location.scope = .checkout(
                    projectId: projectId, rootPath: rootPath,
                    relativePath: URL(fileURLWithPath: mapped).pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
                )
            } else {
                location.scope = .standalone
                fileBrowser?.stop()
                fileBrowser = nil
                sidebarButton = nil
            }
            tile.metadata.documentLocation = location
        }
        tile.title = URL(fileURLWithPath: mapped).lastPathComponent
        canvas?.updateTile(tile, recalculateZoneBounds: false)
        configureCodeEditorIfNeeded()
        setDirty(replacement.isDirty)
        if let manager = languageServiceManager { connectLanguageServices(manager) }
    }

    private static func replacingPathPrefix(_ path: String, source: String, destination: String) -> String? {
        if path == source { return destination }
        let prefix = source.hasSuffix("/") ? source : source + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return destination + "/" + path.dropFirst(prefix.count)
    }

    // MARK: - Markdown mode

    /// Switches the body in place. The tile keeps its identity, its persisted
    /// metadata, and its already-loaded text.
    func setMode(_ newMode: Mode) {
        guard presentation == .markdown, newMode != mode else { return }
        promoteForIncomingFocus()
        mode = newMode
        modeControl?.selectedSegment = newMode.segmentIndex
        markdownSurface?.setMode(newMode, sourceDraft: documentSession?.draftText ?? loadedText)
        showBody()
        if newMode != .preview, let codeEditor { codeEditor.focusEditor(documentID: bridgeDocumentID) }
        else { window?.makeFirstResponder(markdownSurface?.previewView ?? textView) }
        tile.metadata.markdownDocumentMode = newMode
        canvas?.updateTile(tile)
    }

    func textDidChange(_ notification: Notification) {
        guard presentation == .markdown else { return }
        loadedText = textView.string
        _ = documentSession?.updateDraft(textView.string)
        markdownSurface?.draftDidChange(textView.string)
        setDirty(documentSession?.isDirty ?? (savedText != loadedText))
        scheduleRecoveryDraftSave()
        bumpSurfaceEpoch()
    }

    @discardableResult
    func save(overwriteExternalChanges: Bool = false) -> Bool {
        guard let filePath, let session = documentSession else { return false }
        if codeEditor == nil, presentation == .markdown, session.draftText != textView.string {
            _ = session.updateDraft(textView.string)
        }
        let editorRevisionBeforeSave = session.revision
        switch session.save(overwriteExternalChanges: overwriteExternalChanges) {
        case .saved, .unchanged:
            savedText = session.baselineText
            loadedText = session.draftText
            if let loadedText { markdownSurface?.replaceDraft(loadedText) }
            loadedFileSignature = Self.fileSignature(for: filePath)
            hasExternalConflict = false
            setDirty(session.isDirty)
            if !session.isDirty { discardRecoveryDraft() }
            onLanguageDocumentSave?(URL(fileURLWithPath: filePath))
            if session.revision != editorRevisionBeforeSave {
                codeEditor?.applyEdits(
                    documentID: bridgeDocumentID,
                    expectedRevision: editorRevisionBeforeSave,
                    revision: session.revision,
                    changes: []
                )
            }
            return true
        case .conflict:
            hasExternalConflict = true
            dirtyLabel.stringValue = "!"
            dirtyLabel.toolTip = "The file changed on disk"
            return false
        case let .unavailable(reason):
            let message = Self.unavailableMessage(reason)
            showSaveFailure(message); onSaveFailure?(message); return false
        case let .draftTooLarge(maxBytes):
            let message = "Draft is larger than \(maxBytes / 1_024) KB"
            showSaveFailure(message); onSaveFailure?(message); return false
        case let .writeFailed(message):
            showSaveFailure(message); onSaveFailure?(message); return false
        case .stale:
            let message = "The editor changed while saving. Try again."
            showSaveFailure(message); return false
        }
    }

    /// Reloads external edits only while the tile has no local draft. A dirty
    /// draft is never overwritten; it is marked conflicted for the next save.
    func refreshFromDisk(force: Bool = false) {
        guard !documentTransitionPending || force else { return }
        guard let filePath, let session = documentSession else { return }
        let signature = Self.fileSignature(for: filePath)
        guard force || signature != loadedFileSignature else { return }
        let result = session.refreshFromDisk()
        switch result {
        case .unchanged:
            loadedFileSignature = signature
        case .conflict:
            hasExternalConflict = true
            dirtyLabel.stringValue = "!"
            dirtyLabel.toolTip = "The file changed on disk"
        case .reloaded:
            savedText = session.baselineText
            loadedText = session.draftText
            loadedFileSignature = signature
            if let text = session.draftText {
                textView.string = text
                if presentation == .sourceText { applyCodePresentation() }
                markdownSurface?.replaceDraft(text)
                codeEditor?.loadDocument(
                    documentID: bridgeDocumentID, text: text,
                    language: Self.codeMirrorLanguage(sourceLanguage), revision: session.revision
                )
            }
            showBody()
        case let .unavailable(reason):
            let message = Self.unavailableMessage(reason)
            showSaveFailure(message)
            trashedOriginalURL = URL(fileURLWithPath: filePath)
            trashedItemURL = nil
            showMissingFileActions(message)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isCodeEditorFocused || TileNSView.enclosingTileId(of: window?.firstResponder) == tile.id else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if presentation == .markdown, modifiers == [.command, .option],
           let key = event.charactersIgnoringModifiers,
           let selectedMode = ["1": Mode.preview, "2": .split, "3": .edit][key] {
            setMode(selectedMode)
            return true
        }
        if codeEditor == nil, presentation == .markdown, mode != .preview,
           MarkdownEditingCommands.handleKeyEquivalent(event, in: textView) {
            return true
        }
        if isCodeEditorFocused, modifiers.contains(.command),
           let key = event.charactersIgnoringModifiers?.lowercased(),
           ["z", "f"].contains(key) {
            let command = key == "f" ? "find" : (modifiers.contains(.shift) ? "redo" : "undo")
            codeEditor?.runCommand(documentID: bridgeDocumentID, command: command)
            return true
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "s",
           loadedText != nil {
            saveFromEditor()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard presentation == .markdown else { return false }
        return MarkdownEditingCommands.handleCommand(commandSelector, in: textView)
    }

    /// Shared by Command-S and dirty-tile close. Returns true only when there is
    /// no longer an unsaved draft; Cancel and write failure keep the tile open.
    @discardableResult
    func saveInteractively() -> Bool {
        guard hasExternalConflict else { return save() }
        let alert = NSAlert()
        alert.messageText = "This file changed on disk"
        alert.informativeText = "Reload the disk version, overwrite it with your draft, or keep editing."
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Overwrite")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            documentSession?.discardDraft()
            setDirty(false)
            hasExternalConflict = false
            refreshFromDisk(force: true)
            discardRecoveryDraft()
            return !isDirty
        case .alertSecondButtonReturn:
            return save(overwriteExternalChanges: true)
        default:
            return false
        }
    }

    private func setDirty(_ dirty: Bool) {
        isDirty = dirty
        dirtyLabel.stringValue = dirty ? "•" : ""
        dirtyLabel.toolTip = dirty ? "Unsaved editor changes" : nil
        dirtyLabel.setAccessibilityLabel(dirty ? "Unsaved changes" : "Saved")
    }

    /// The close orchestrator uses these rather than reaching into recovery
    /// implementation details. Discard is explicit and only follows the user's
    /// Discard choice; scene teardown merely flushes the draft.
    func discardUnsavedChanges() {
        recoverySaveTimer?.invalidate()
        recoverySaveTimer = nil
        discardRecoveryDraft()
        documentSession?.discardDraft()
        if let filePath, let session = documentSession, let text = session.draftText {
            loadedText = text
            textView.string = text
            markdownSurface?.replaceDraft(text)
            codeEditor?.loadDocument(
                documentID: bridgeDocumentID, text: text,
                language: presentation == .markdown ? "markdown" : Self.codeMirrorLanguage(sourceLanguage),
                revision: session.revision
            )
        }
        setDirty(false)
        hasExternalConflict = false
    }

    func flushUnsavedRecovery() { flushRecoveryDraft() }

    /// Existing workspace lifecycle APIs are synchronous. Pump only the main
    /// run loop until the asynchronous web barrier acknowledges, and fail the
    /// owner's transition closed on timeout instead of tearing down stale text.
    func captureForSceneTransition() throws {
        var captured: Bool?
        flushEditorBarrier { captured = $0 }
        let deadline = Date().addingTimeInterval(5.5)
        while captured == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        guard captured == true else {
            resumeEditorAfterBarrier()
            throw CodeEditorHostError.bridgeUnavailable
        }
        guard flushRecoveryDraft() else {
            resumeEditorAfterBarrier()
            throw CodeEditorHostError.javaScript("The recovery draft could not be saved.")
        }
        resumeEditorAfterBarrier()
    }

    @objc private func modeControlChanged(_ sender: NSSegmentedControl) {
        setMode(Mode(segmentIndex: sender.selectedSegment) ?? .edit)
    }

    private func installModeControl() {
        guard modeControl == nil else { return }
        let control = NSSegmentedControl(labels: ["Preview", "Split", "Edit"], trackingMode: .selectOne, target: self, action: #selector(modeControlChanged(_:)))
        control.controlSize = .small
        control.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        for segment in 0..<control.segmentCount { control.setWidth(160 / 3, forSegment: segment) }
        control.selectedSegment = mode.segmentIndex
        control.setAccessibilityLabel("Markdown display mode")
        modeControl = control
        let formatControl = MarkdownEditingCommands.makeToolbarPopUp(
            target: self,
            action: #selector(applyMarkdownCommand(_:))
        )
        markdownFormatControl = formatControl
        dirtyLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        dirtyLabel.textColor = NSColor.systemOrange
        dirtyLabel.alignment = .center
        referenceLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        referenceLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        referenceLabel.isHidden = true
        rebuildTitleAccessory()
    }

    func setReferencedAgentTiles(_ agentTileIds: [UUID]) {
        invalidateTitleBarAccessory()
        let count = agentTileIds.count
        referenceLabel.stringValue = count == 0 ? "" : (count == 1 ? "1 reference" : "\(count) references")
        referenceLabel.toolTip = count == 0 ? nil : "Referenced by \(count) agent\(count == 1 ? "" : "s")"
        referenceLabel.isHidden = count == 0
        guard count > 0 else {
            referenceLabel.menu = nil
            return
        }
        let menu = NSMenu(title: "Referenced by")
        for (index, tileId) in agentTileIds.enumerated() {
            let item = NSMenuItem(title: "Reveal agent \(index + 1)", action: #selector(revealReferencedAgent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tileId.uuidString
            menu.addItem(item)
        }
        referenceLabel.menu = menu
    }

    @objc private func revealReferencedAgent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tileId = UUID(uuidString: raw) else { return }
        onRevealReferencedAgentTile?(tileId)
    }

    /// Installs the body for the current mode from the loaded snapshot.
    private func showBody() {
        guard let loadedText else { return }
        // A mode switch arrives via a click, so `hitTest` has already promoted —
        // but this must hold even for a programmatic switch (`reveal(line:)`),
        // because `setContentView` below would replace the surface host and strand
        // the parked body.
        promoteForIncomingFocus()
        if presentation == .markdown, let markdownSurface {
            markdownSurface.replaceDraft(loadedText)
            let body: NSView
            switch mode {
            case .preview:
                body = markdownSurface.previewBody()
            case .edit:
                configureCodeEditorIfNeeded()
                body = codeEditor ?? scrollView
            case .split:
                configureCodeEditorIfNeeded()
                markdownEditorSplit.isVertical = true
                markdownEditorSplit.dividerStyle = .thin
                markdownEditorSplit.subviews.forEach { $0.removeFromSuperview() }
                let source = codeEditor ?? scrollView
                let preview = markdownSurface.previewBody()
                source.removeFromSuperview()
                preview.removeFromSuperview()
                markdownEditorSplit.addSubview(source)
                markdownEditorSplit.addSubview(preview)
                body = markdownEditorSplit
            }
            rebuildEditorShell(documentBody: body)
            markdownSurface.restorePresentationState()
            if mode != .preview { applyPendingReveal() }
        } else {
            configureCodeEditorIfNeeded()
            rebuildEditorShell(documentBody: codeEditor ?? scrollView)
            applyPendingReveal()
        }
        bumpSurfaceEpoch()
    }

    /// Scrolls the source view to a one-based line (and optional column) without
    /// persisting anything. Called when an agent link named `file.swift:42`.
    /// Preview switches to Edit because a coordinate refers to source. Split
    /// remains Split and reveals within its already-visible source pane.
    func reveal(line: Int, column: Int? = nil) {
        guard line > 0 else { return }
        pendingReveal = (line, column)
        if presentation == .markdown, mode == .preview {
            setMode(.edit)
        } else {
            applyPendingReveal()
        }
    }

    private func applyPendingReveal() {
        guard let pendingReveal, !textView.string.isEmpty else { return }
        self.pendingReveal = nil
        lastEditorRevealLine = pendingReveal.line
        if let codeEditor, let filePath {
            codeEditor.reveal(documentID: bridgeDocumentID, line: pendingReveal.line, column: pendingReveal.column)
        }
        let text = textView.string as NSString
        var lineStart = 0
        var currentLine = 1
        while currentLine < pendingReveal.line {
            let searchRange = NSRange(location: lineStart, length: text.length - lineStart)
            let newline = text.range(of: "\n", options: [], range: searchRange)
            guard newline.location != NSNotFound else { break }
            lineStart = newline.location + newline.length
            currentLine += 1
        }
        let lineEnd = text.range(
            of: "\n",
            options: [],
            range: NSRange(location: lineStart, length: text.length - lineStart)
        )
        let lineLength = (lineEnd.location == NSNotFound ? text.length : lineEnd.location) - lineStart
        var location = lineStart
        if let column = pendingReveal.column, column > 1 {
            location = min(lineStart + column - 1, lineStart + max(lineLength, 0))
        }
        let range = NSRange(location: min(location, text.length), length: 0)
        textView.scrollRangeToVisible(range)
        // Select from the coordinate to the end of that line — a subtle "here",
        // never a selection that runs past the line.
        let selectionLength = max(0, min(lineStart + lineLength, text.length) - range.location)
        textView.setSelectedRange(NSRange(location: range.location, length: selectionLength))
        // The QA reveal assertion reads the clip origin, which only moves once
        // AppKit has laid the document out.
        scrollView.layoutSubtreeIfNeeded()
        textView.scrollRangeToVisible(range)
    }

    /// QA: the one-based line currently at the top of the visible source rect.
    func qaFirstVisibleSourceLine() -> Int? {
        if let lastEditorRevealLine { return lastEditorRevealLine }
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return nil }
        layoutManager.ensureLayout(for: container)
        let visible = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        guard glyphRange.location != NSNotFound else { return nil }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
        let text = textView.string as NSString
        guard charIndex <= text.length else { return nil }
        var line = 1
        var index = 0
        while index < charIndex {
            let newline = text.range(of: "\n", options: [], range: NSRange(location: index, length: charIndex - index))
            guard newline.location != NSNotFound else { break }
            index = newline.location + newline.length
            line += 1
        }
        return line
    }

    /// QA: the rendered Markdown document, when one is installed.
    var qaMarkdownDocument: FileMarkdownDocumentView? { markdownSurface?.previewView }
    /// QA: the mode control, which must exist for Markdown and never otherwise.
    var qaModeControl: NSSegmentedControl? { modeControl }
    var qaSourceLanguage: FilePreview.SourceLanguage { sourceLanguage }
    var qaHasLineNumbers: Bool { scrollView.rulersVisible && scrollView.verticalRulerView === lineNumberRuler }
    var qaCodeEditorVisible: Bool {
        guard let codeEditor, codeEditor.superview != nil else { return false }
        layoutSubtreeIfNeeded()
        return !codeEditor.isHidden && codeEditor.frame.width > 0 && codeEditor.frame.height > 0
    }
    var qaExternalChangeMonitoringActive: Bool { externalChangeTimer?.isValid == true }
    var qaRecoveryURL: URL? { recoveryURL }
    func qaFlushRecoveryDraft() { flushRecoveryDraft() }
    var qaSyntaxForegroundCount: Int {
        guard let storage = textView.textStorage, storage.length > 0 else { return 0 }
        var colors = Set<String>()
        storage.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: min(storage.length, 2_000))
        ) { value, _, _ in
            guard let color = value as? NSColor,
                  let rgb = color.usingColorSpace(.sRGB) else { return }
            colors.insert("\(rgb.redComponent)-\(rgb.greenComponent)-\(rgb.blueComponent)")
        }
        return colors.count
    }

    struct TextVisibilityEvidence: CustomStringConvertible {
        var containsExpectedText = false
        var documentViewMatches = false
        var clipBounds: NSRect = .zero
        var textFrame: NSRect = .zero
        var usedRect: NSRect = .zero
        var textVisibleRect: NSRect = .zero
        var visibleGlyphRange: NSRange = NSRange(location: NSNotFound, length: 0)
        var expectedGlyphRange: NSRange = NSRange(location: NSNotFound, length: 0)
        var expectedGlyphRect: NSRect = .zero
        var expectedGlyphIntersectsVisibleRect = false
        var tileWindowRect: NSRect = .zero
        var textVisibleWindowRect: NSRect = .zero
        var windowContentRect: NSRect = .zero
        var textIntersectsWindow = false
        var verticalScrollable = false
        var verticalScrollAdvanced = false
        var horizontalScrollable = false
        var documentWidthExceedsClipWidth = false
        var horizontalScrollAdvanced = false
        var horizontalScrollOriginBefore: CGFloat = 0
        var horizontalScrollOriginAfter: CGFloat = 0
        var hasHorizontalScroller = false

        var visibleLayoutOK: Bool {
            containsExpectedText
                && documentViewMatches
                && clipBounds.width > 0
                && clipBounds.height > 0
                && textFrame.width > 0
                && textFrame.height > 0
                && usedRect.width > 0
                && usedRect.height > 0
                && textVisibleRect.width > 0
                && textVisibleRect.height > 0
                && visibleGlyphRange.location != NSNotFound
                && visibleGlyphRange.length > 0
                && expectedGlyphRange.location != NSNotFound
                && expectedGlyphIntersectsVisibleRect
                && textIntersectsWindow
        }

        var longFileBehaviorOK: Bool {
            verticalScrollable
                && verticalScrollAdvanced
                && horizontalScrollable
                && documentWidthExceedsClipWidth
                && horizontalScrollAdvanced
                && hasHorizontalScroller
        }

        var description: String {
            "containsExpectedText=\(containsExpectedText) documentViewMatches=\(documentViewMatches) clipBounds=\(clipBounds) textFrame=\(textFrame) usedRect=\(usedRect) textVisibleRect=\(textVisibleRect) visibleGlyphRange=\(visibleGlyphRange) expectedGlyphRange=\(expectedGlyphRange) expectedGlyphRect=\(expectedGlyphRect) expectedGlyphIntersectsVisibleRect=\(expectedGlyphIntersectsVisibleRect) tileWindowRect=\(tileWindowRect) textVisibleWindowRect=\(textVisibleWindowRect) windowContentRect=\(windowContentRect) textIntersectsWindow=\(textIntersectsWindow) verticalScrollable=\(verticalScrollable) verticalScrollAdvanced=\(verticalScrollAdvanced) horizontalScrollable=\(horizontalScrollable) documentWidthExceedsClipWidth=\(documentWidthExceedsClipWidth) horizontalScrollAdvanced=\(horizontalScrollAdvanced) horizontalScrollOriginBefore=\(horizontalScrollOriginBefore) horizontalScrollOriginAfter=\(horizontalScrollOriginAfter) hasHorizontalScroller=\(hasHorizontalScroller)"
        }
    }

    /// Deterministic QA hook: verifies not just that text loaded into
    /// `textView.string`, but that AppKit produced visible glyph layout inside
    /// the scroll view and that the tile's visible text rect intersects the
    /// window content rect. For long smoke files it also records scrollability
    /// and the visible glyph range before/after a programmatic scroll.
    func textVisibilityEvidence(containing expectedText: String) -> TextVisibilityEvidence {
        layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        textView.layoutSubtreeIfNeeded()

        var evidence = TextVisibilityEvidence()
        evidence.containsExpectedText = textView.string.contains(expectedText)
        evidence.documentViewMatches = scrollView.documentView === textView
        evidence.clipBounds = scrollView.contentView.bounds
        evidence.textFrame = textView.frame
        evidence.textVisibleRect = textView.visibleRect
        evidence.hasHorizontalScroller = scrollView.hasHorizontalScroller

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return evidence }
        layoutManager.ensureLayout(for: textContainer)
        evidence.usedRect = layoutManager.usedRect(for: textContainer)
        evidence.visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: evidence.textVisibleRect, in: textContainer)

        if let range = textView.string.range(of: expectedText) {
            let nsRange = NSRange(range, in: textView.string)
            evidence.expectedGlyphRange = layoutManager.glyphRange(forCharacterRange: nsRange, actualCharacterRange: nil)
            evidence.expectedGlyphRect = layoutManager.boundingRect(forGlyphRange: evidence.expectedGlyphRange, in: textContainer)
            evidence.expectedGlyphRect.origin.x += textView.textContainerOrigin.x
            evidence.expectedGlyphRect.origin.y += textView.textContainerOrigin.y
            evidence.expectedGlyphIntersectsVisibleRect = evidence.expectedGlyphRect.intersects(evidence.textVisibleRect)
        }

        if let window, let contentView = window.contentView {
            evidence.tileWindowRect = convert(bounds, to: nil)
            evidence.textVisibleWindowRect = textView.convert(evidence.textVisibleRect, to: nil)
            evidence.windowContentRect = contentView.convert(contentView.bounds, to: nil)
            evidence.textIntersectsWindow = evidence.textVisibleWindowRect.intersects(evidence.windowContentRect)
                && evidence.tileWindowRect.intersects(evidence.windowContentRect)
        }

        evidence.verticalScrollable = evidence.usedRect.height > evidence.textVisibleRect.height + 1
        evidence.horizontalScrollable = evidence.usedRect.width > evidence.textVisibleRect.width + 1
        evidence.documentWidthExceedsClipWidth = textView.frame.width > scrollView.contentView.bounds.width + 1
        let originalOrigin = scrollView.contentView.bounds.origin
        if evidence.verticalScrollable {
            let before = originalOrigin.y
            textView.scrollRangeToVisible(NSRange(location: max(textView.string.utf16.count - 1, 0), length: 0))
            scrollView.layoutSubtreeIfNeeded()
            let after = scrollView.contentView.bounds.origin.y
            evidence.verticalScrollAdvanced = after > before + 1
            scrollView.contentView.scroll(to: originalOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        if evidence.documentWidthExceedsClipWidth {
            let clipView = scrollView.contentView
            let maxX = max(textView.frame.width - clipView.bounds.width, 0)
            evidence.horizontalScrollOriginBefore = clipView.bounds.origin.x
            clipView.scroll(to: NSPoint(x: maxX, y: clipView.bounds.origin.y))
            scrollView.reflectScrolledClipView(clipView)
            scrollView.layoutSubtreeIfNeeded()
            evidence.horizontalScrollOriginAfter = clipView.bounds.origin.x
            evidence.horizontalScrollAdvanced = evidence.horizontalScrollOriginAfter > evidence.horizontalScrollOriginBefore + 1
            clipView.scroll(to: originalOrigin)
            scrollView.reflectScrolledClipView(clipView)
        }

        return evidence
    }

    func hasVisibleTextLayout(containing expectedText: String) -> Bool {
        textVisibilityEvidence(containing: expectedText).visibleLayoutOK
    }

    private func loadFile() {
        guard let filePath, !filePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showMessage("File not found")
            return
        }

        if Self.shouldLoadAsynchronously(path: filePath) {
            textView.string = "Loading file..."
            let generation = documentGeneration
            Task.detached { [filePath] in
                let result = FilePreview.load(path: filePath)
                await MainActor.run { [weak self] in
                    guard let self, self.documentGeneration == generation else { return }
                    self.apply(result)
                }
            }
        } else {
            apply(FilePreview.load(path: filePath))
        }
    }

    private func apply(_ result: FilePreview) {
        switch result {
        case let .text(content):
            let recovery = loadRecoveryDraft(forDiskText: content)
            if let recovery {
                _ = documentSession?.restoreRecovery(FileDocumentRecoverySnapshot(
                    filePath: recovery.filePath,
                    baselineText: recovery.baseText,
                    draftText: recovery.draftText,
                    updatedAt: recovery.updatedAt
                ))
            }
            let initialText = documentSession?.draftText ?? recovery?.draftText ?? content
            loadedText = initialText
            textView.string = initialText
            savedText = documentSession?.baselineText ?? content
            loadedFileSignature = filePath.flatMap { Self.fileSignature(for: $0) }
            presentation = filePath.map { FilePreview.presentation(forPath: $0) } ?? .sourceText
            if presentation == .markdown {
                configureMarkdownEditor()
                mode = tile.metadata.markdownDocumentMode ?? .preview
                markdownSurface = MarkdownDocumentSurface(
                    textView: textView,
                    sourceScrollView: scrollView,
                    initialDraft: initialText,
                    mode: mode,
                    theme: { [weak self] in self?.editorTokenTheme ?? .dark }
                )
                installModeControl()
                if recovery != nil {
                    textView.string = initialText
                    hasExternalConflict = recovery?.baseText != content
                    setDirty(true)
                    if hasExternalConflict {
                        dirtyLabel.stringValue = "!"
                        dirtyLabel.toolTip = "Recovered draft; the file also changed on disk"
                    }
                }
            } else {
                configureCodePresentation()
                applyCodePresentation()
            }
            configureCodeEditorIfNeeded()
            showBody()
            startExternalChangeMonitoring()
            if let manager = languageServiceManager { connectLanguageServices(manager) }
        case let .unavailable(message):
            if let recovery = readRecoveryDraft(), let session = documentSession,
               session.restoreRecovery(FileDocumentRecoverySnapshot(
                   filePath: recovery.filePath,
                   baselineText: recovery.baseText,
                   draftText: recovery.draftText,
                   updatedAt: recovery.updatedAt
               )) {
                loadedText = recovery.draftText
                savedText = recovery.baseText
                textView.string = recovery.draftText
                presentation = filePath.map { FilePreview.presentation(forPath: $0) } ?? .sourceText
                if presentation == .markdown {
                    configureMarkdownEditor()
                    mode = tile.metadata.markdownDocumentMode ?? .preview
                    markdownSurface = MarkdownDocumentSurface(
                        textView: textView, sourceScrollView: scrollView,
                        initialDraft: recovery.draftText, mode: mode,
                        theme: { [weak self] in self?.editorTokenTheme ?? .dark }
                    )
                    installModeControl()
                } else {
                    configureCodePresentation()
                    applyCodePresentation()
                }
                configureCodeEditorIfNeeded()
                setDirty(true)
                hasExternalConflict = true
                showBody()
            } else {
                loadedText = nil
                showMessage(message)
            }
        }
    }

    private func configureMarkdownEditor() {
        textView.isEditable = true
        textView.menu = MarkdownEditingCommands.makeContextMenu(
            target: self,
            action: #selector(applyMarkdownCommand(_:))
        )
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineBreakMode = .byWordWrapping
        scrollView.hasHorizontalScroller = false
    }

    @objc private func applyMarkdownCommand(_ sender: NSMenuItem) {
        guard let command = MarkdownEditingCommands.Command(rawValue: sender.tag) else { return }
        if let codeEditor {
            if mode == .preview { setMode(.edit) }
            codeEditor.runCommand(documentID: bridgeDocumentID, command: "markdown" + String(command.rawValue))
        } else { MarkdownEditingCommands.apply(command, in: textView) }
    }

    private func configureCodePresentation() {
        // Keep the lightweight native projection as a deterministic fallback
        // and test witness while CodeMirror owns the visible editor surface.
        let ruler = CodeLineNumberRulerView(scrollView: scrollView, textView: textView)
        lineNumberRuler = ruler
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        let label = NSTextField(labelWithString: sourceLanguage.rawValue.uppercased())
        label.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        label.textColor = TextToken.textSecondary.color.nsColor(in: self)
        label.setAccessibilityLabel("Language: \(sourceLanguage.rawValue)")
        languageLabel = label
        rebuildTitleAccessory()
    }

    private func configureCodeEditorIfNeeded() {
        guard let filePath,
              let session = documentSession, let text = loadedText ?? session.draftText else { return }
        let language = presentation == .markdown ? "markdown" : Self.codeMirrorLanguage(sourceLanguage)
        if codeEditor?.activeDocumentID == bridgeDocumentID { return }
        let editor = codeEditor ?? CodeEditorHostView(frame: .zero)
        editor.onProcessTerminated = { [weak self, weak editor] in
            guard let self, let editor, let filePath = self.filePath,
                  let session = self.documentSession, let text = session.draftText else { return }
            self.documentTransitionPending = false
            self.documentGeneration = UUID()
            editor.setPreferences(EditorPreferences(), isDark: self.editorTheme.isDark)
            editor.loadDocument(
                documentID: self.bridgeDocumentID, text: text,
                language: self.presentation == .markdown ? "markdown" : Self.codeMirrorLanguage(self.sourceLanguage),
                revision: session.revision
            )
        }
        editor.onSaveRequest = { [weak self] in self?.saveFromEditor() }
        editor.onVimModeChange = { [weak self] mode in
            self?.vimModeLabel.stringValue = mode == "off" ? "" : mode.uppercased()
            self?.vimModeLabel.setAccessibilityLabel("Vim " + mode)
        }
        editor.onDocumentChange = { [weak self] change in self?.applyEditorChange(change) }
        editor.onViewStateChange = { [weak self] state in
            guard let self else { return }
            self.editorState.cursorLine = state.line
            self.editorState.cursorColumn = state.column
            self.editorState.verticalScrollOffset = state.scrollTop
            self.editorState.horizontalScrollOffset = state.scrollLeft
            self.editorStateSaveTimer?.invalidate()
            self.editorStateSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.persistEditorState() }
            }
        }
        editor.onBridgeError = { [weak self] error in self?.showSaveFailure(error.localizedDescription) }
        codeEditor = editor
        applyEditorPreferences()
        editor.loadDocument(
            documentID: self.bridgeDocumentID, text: text,
            language: language, revision: session.revision
        ) { [weak self, weak editor] result in
            guard case .success = result, let self, let editor else { return }
            editor.restoreViewState(
                documentID: self.bridgeDocumentID,
                state: CodeEditorViewState(
                    line: self.editorState.cursorLine, column: self.editorState.cursorColumn,
                    scrollTop: self.editorState.verticalScrollOffset,
                    scrollLeft: self.editorState.horizontalScrollOffset
                )
            )
        }
    }

    private func applyEditorChange(_ change: CodeEditorDocumentChange) {
        guard change.documentID == bridgeDocumentID, let session = documentSession,
              let current = session.draftText else { return }
        let mutable = NSMutableString(string: Self.normalizedEditorText(current))
        // CodeMirror changes are measured against the same pre-transaction
        // document; apply from the end so earlier UTF-16 offsets stay valid.
        for edit in change.changes.sorted(by: { $0.fromUTF16 > $1.fromUTF16 }) {
            guard edit.fromUTF16 >= 0, edit.toUTF16 >= edit.fromUTF16,
                  edit.toUTF16 <= mutable.length else {
                codeEditor?.requestSnapshot(documentID: change.documentID) { [weak self] result in
                    if case let .success(snapshot) = result { self?.replaceDraftFromEditor(snapshot) }
                }
                return
            }
            mutable.replaceCharacters(
                in: NSRange(location: edit.fromUTF16, length: edit.toUTF16 - edit.fromUTF16),
                with: edit.insertedText
            )
        }
        switch session.updateDraft(nativeLineEndings(mutable as String), expectedRevision: change.baseRevision) {
        case .updated:
            loadedText = session.draftText
            if let draft = session.draftText {
                textView.string = draft
                markdownSurface?.draftDidChange(draft)
            }
            setDirty(session.isDirty)
            scheduleRecoveryDraftSave()
            if let filePath, let draft = session.draftText {
                onLanguageDocumentChange?(URL(fileURLWithPath: filePath), draft, session.revision)
            }
        case .stale:
            codeEditor?.requestSnapshot(documentID: change.documentID) { [weak self] result in
                if case let .success(snapshot) = result { self?.replaceDraftFromEditor(snapshot) }
            }
        }
    }

    private func replaceDraftFromEditor(_ snapshot: CodeEditorSnapshot) {
        guard snapshot.documentID == bridgeDocumentID, let session = documentSession else { return }
        _ = session.synchronizeDraft(nativeLineEndings(snapshot.text), revision: snapshot.revision)
        loadedText = session.draftText
        textView.string = session.draftText ?? snapshot.text
        markdownSurface?.draftDidChange(session.draftText ?? snapshot.text)
        if let filePath, let text = session.draftText {
            onLanguageDocumentChange?(URL(fileURLWithPath: filePath), text, session.revision)
        }
        setDirty(session.isDirty)
        scheduleRecoveryDraftSave()
    }

    private static func normalizedEditorText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private func nativeLineEndings(_ text: String) -> String {
        let normalized = Self.normalizedEditorText(text)
        let baseline = documentSession?.baselineText ?? ""
        if baseline.contains("\r\n") { return normalized.replacingOccurrences(of: "\n", with: "\r\n") }
        if baseline.contains("\r") && !baseline.contains("\n") { return normalized.replacingOccurrences(of: "\n", with: "\r") }
        return normalized
    }

    private static func codeMirrorLanguage(_ language: FilePreview.SourceLanguage) -> String {
        switch language {
        case .javascript: return "javascript"
        case .typescript: return "typescript"
        case .html: return "html"
        case .css: return "css"
        case .go: return "go"
        case .rust: return "rust"
        case .c: return "cpp"
        case .csharp: return "csharp"
        case .python: return "python"
        case .swift: return "swift"
        case .json: return "json"
        case .shell: return "shell"
        case .plainText: return "plaintext"
        }
    }

    func connectLanguageServices(_ manager: EditorLanguageServiceManager) {
        languageServiceManager = manager
        guard let filePath,
              let rootPath = tile.metadata.documentLocation?.checkoutRootPath,
              let text = documentSession?.draftText else { return }
        languageServiceManager = manager
        let fileURL = URL(fileURLWithPath: filePath)
        let identity = bridgeDocumentID
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        onLanguageDocumentChange = { [weak manager] url, text, revision in
            manager?.change(fileURL: url, projectRoot: rootURL, text: text, version: revision)
        }
        onLanguageDocumentSave = { [weak manager] url in
            manager?.save(fileURL: url, projectRoot: rootURL)
        }
        onLanguageDocumentClose = { [weak manager] url in
            manager?.close(fileURL: url, projectRoot: rootURL)
        }
        manager.open(
            fileURL: fileURL,
            projectRoot: rootURL,
            text: text,
            version: documentSession?.revision ?? 0,
            status: { [weak self] status in
                guard let self, self.bridgeDocumentID == identity else { return }
                self.showLanguageServiceStatus(status)
            },
            diagnostics: { [weak self] diagnostics in
                guard let self, self.bridgeDocumentID == identity, let editor = self.codeEditor, self.filePath != nil,
                      let session = self.documentSession else { return }
                editor.setDiagnostics(
                    documentID: self.bridgeDocumentID,
                    revision: session.revision,
                    diagnostics: diagnostics.compactMap { value in
                        guard let range = self.utf16Range(value.range) else { return nil }
                        let severity: CodeEditorDiagnostic.Severity
                        switch value.severity {
                        case 1: severity = .error
                        case 2: severity = .warning
                        case 3: severity = .info
                        default: severity = .hint
                        }
                        return CodeEditorDiagnostic(fromUTF16: range.location, toUTF16: range.location + range.length, severity: severity, message: value.message)
                    }
                )
            }
        )
        codeEditor?.onCompletionRequest = { [weak manager] request in
            guard let manager else { return }
            Task {
                let items = await manager.completion(
                    fileURL: fileURL, projectRoot: rootURL,
                    position: LSPPosition(line: request.line, character: request.columnUTF16)
                )
                await MainActor.run { [weak self] in
                    guard let self, self.bridgeDocumentID == identity,
                          self.documentSession?.revision == request.revision else { return }
                    self.codeEditor?.provideCompletions(
                        documentID: request.documentID,
                        requestID: request.requestID,
                        items: items.map { CodeEditorCompletionItem(label: $0.label, detail: $0.detail, insertText: $0.insertText, kind: nil) },
                        isIncomplete: false
                    )
                }
            }
        }
        codeEditor?.onHoverRequest = { [weak self, weak manager] request in
            guard let manager else { return }
            Task {
                let text = await manager.hover(
                    fileURL: fileURL, projectRoot: rootURL,
                    position: LSPPosition(line: request.line, character: request.columnUTF16)
                )
                await MainActor.run { [weak self] in
                    guard let self, self.bridgeDocumentID == identity,
                          self.documentSession?.revision == request.revision else { return }
                    self.codeEditor?.provideHover(
                        documentID: request.documentID,
                        requestID: request.requestID,
                        text: text
                    )
                }
            }
        }
        codeEditor?.onDefinitionRequest = { [weak self, weak manager] request in
            guard let manager else { return }
            Task {
                let locations = await manager.definition(
                    fileURL: fileURL, projectRoot: rootURL,
                    position: LSPPosition(line: request.line, character: request.columnUTF16)
                )
                guard let first = locations.first, let url = URL(string: first.uri), url.isFileURL else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.bridgeDocumentID == identity,
                          self.documentSession?.revision == request.revision else { return }
                    self.navigateDocument(url, disposition: .replaceCurrent)
                }
            }
        }
    }

    private func utf16Range(_ range: LSPRange) -> NSRange? {
        guard let text = documentSession?.draftText else { return nil }
        func offset(_ position: LSPPosition) -> Int? {
            let ns = Self.normalizedEditorText(text) as NSString
            var start = 0
            for _ in 0..<position.line {
                let hit = ns.range(of: "\n", options: [], range: NSRange(location: start, length: ns.length - start))
                guard hit.location != NSNotFound else { return nil }
                start = hit.location + hit.length
            }
            return min(ns.length, start + max(0, position.character))
        }
        guard let lower = offset(range.start), let upper = offset(range.end), upper >= lower else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    private func showLanguageServiceStatus(_ status: EditorLanguageServiceManager.Status) {
        switch status {
        case .unavailable: languageLabel?.toolTip = "No language service available"
        case let .installing(name): languageLabel?.toolTip = "Installing \(name)…"
        case let .starting(name): languageLabel?.toolTip = "Starting \(name)…"
        case let .ready(name): languageLabel?.toolTip = "\(name) ready"
        case let .failed(message): languageLabel?.toolTip = "Language service unavailable: \(message)"
        }
    }

    private func applyCodePresentation() {
        let selection = textView.selectedRange()
        let visibleOrigin = scrollView.contentView.bounds.origin
        textView.textStorage?.setAttributedString(CodeSyntaxHighlighter.attributedString(
            textView.string,
            language: sourceLanguage,
            in: self
        ))
        let length = textView.string.utf16.count
        textView.setSelectedRange(NSRange(
            location: min(selection.location, length),
            length: min(selection.length, max(0, length - min(selection.location, length)))
        ))
        scrollView.contentView.scroll(to: visibleOrigin)
        lineNumberRuler?.needsDisplay = true
        languageLabel?.textColor = TextToken.textSecondary.color.nsColor(in: self)
    }

    private func startExternalChangeMonitoring() {
        guard window != nil, externalChangeTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshFromDisk() }
        }
        RunLoop.main.add(timer, forMode: .common)
        externalChangeTimer = timer
    }

    private var recoveryURL: URL? {
        let root: URL
        if let checkoutRoot = tile.metadata.documentLocation?.checkoutRootPath {
            root = URL(fileURLWithPath: checkoutRoot, isDirectory: true)
                .appendingPathComponent(".array", isDirectory: true)
        } else {
            guard let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else { return nil }
            root = applicationSupport
                .appendingPathComponent(AppChannel.liveApplicationSupportDirectoryName, isDirectory: true)
        }
        return root
            .appendingPathComponent("recovery", isDirectory: true)
            .appendingPathComponent("file-drafts", isDirectory: true)
            .appendingPathComponent("\(tile.id.uuidString).json", isDirectory: false)
    }

    private func scheduleRecoveryDraftSave() {
        recoverySaveTimer?.invalidate()
        guard isDirty else {
            discardRecoveryDraft()
            return
        }
        recoverySaveTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushRecoveryDraft() }
        }
    }

    @discardableResult
    private func flushRecoveryDraft() -> Bool {
        recoverySaveTimer?.invalidate()
        recoverySaveTimer = nil
        guard isDirty, let recoveryURL, let filePath,
              let baseline = documentSession?.baselineText ?? savedText,
              let draft = documentSession?.draftText ?? loadedText else { return !isDirty }
        let record = RecoveryDraft(
            filePath: filePath,
            baseText: baseline,
            draftText: draft,
            updatedAt: Date()
        )
        do {
            try AtomicWriter(backupsDirectory: nil, retainedBackups: 0).write(record, to: recoveryURL)
            return true
        } catch {
            let message = "Could not protect the unsaved draft: \(error.localizedDescription)"
            showSaveFailure(message)
            onSaveFailure?(message)
            return false
        }
    }

    private func showSaveFailure(_ message: String) {
        dirtyLabel.stringValue = "!"
        dirtyLabel.toolTip = "Save failed: \(message)"
        dirtyLabel.setAccessibilityLabel("File save failed: \(message)")
    }

    private func loadRecoveryDraft(forDiskText diskText: String) -> RecoveryDraft? {
        guard let record = readRecoveryDraft() else { return nil }
        if record.draftText == diskText {
            discardRecoveryDraft()
            return nil
        }
        return record
    }

    private func readRecoveryDraft() -> RecoveryDraft? {
        guard let recoveryURL, let filePath,
              let record: RecoveryDraft = try? AtomicWriter(
                backupsDirectory: nil,
                retainedBackups: 0
              ).read(at: recoveryURL),
              record.filePath == filePath else { return nil }
        return record
    }

    private func discardRecoveryDraft() {
        guard let recoveryURL else { return }
        try? FileManager.default.removeItem(at: recoveryURL)
    }

    private func showMessage(_ message: String) {
        let label = NSTextField(labelWithString: message)
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0

        let container = NSView()
        container.wantsLayer = true
        messageLabel = label
        messageContainer = container
        applyTokens()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        promoteForIncomingFocus()
        setContentView(container)
        activeBody = container
        bumpSurfaceEpoch()
    }

    nonisolated private static func shouldLoadAsynchronously(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey]),
           values.volumeIsLocal == false {
            return true
        }
        return false
    }

    private static func unavailableMessage(_ reason: FileDocumentUnavailableReason) -> String {
        switch reason {
        case .missing: return "The file no longer exists. Your draft was preserved."
        case .notRegularFile: return "The path is no longer a regular file."
        case let .tooLarge(maxBytes): return "The file is larger than \(maxBytes / 1_024) KB."
        case .unsupportedEncoding: return "The file is binary or is not UTF-8."
        case let .unreadable(message): return "The file could not be read: \(message)"
        }
    }

    nonisolated private static func fileSignature(for path: String) -> FileSignature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return FileSignature(
            modificationDate: attributes[.modificationDate] as? Date,
            byteCount: (attributes[.size] as? NSNumber)?.uint64Value,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }
}

extension Notification.Name {
    static let arrayProjectFileMoved = Notification.Name("ArrayProjectFileMoved")
    static let arrayProjectFileTrashed = Notification.Name("ArrayProjectFileTrashed")
}
