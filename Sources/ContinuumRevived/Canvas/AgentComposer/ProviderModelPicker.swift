import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// The provider>model picker (design ported from t3code's ProviderModelPicker):
/// the composer's model trigger opens a two-pane surface — a narrow provider
/// icon rail on the left, the selected provider's models on the right —
/// instead of one flat list. The right pane IS a `ChoiceListView`, so rows,
/// keyboard handling, and selection stay pixel- and behavior-identical to
/// every other choice menu; this file adds only the grouping, the rail, and
/// a popover host mirroring `ChoicePopoverController`.

/// Pure grouping: fully-qualified `provider/model` ids → ordered provider
/// groups. Ids without a slash group under "other" (an off-catalog record
/// value stays visible rather than being hidden — same rule as the footer).
enum ProviderModelGrouping {
    struct Group: Equatable {
        let id: String
        let title: String
        let models: [ChoiceItem]
    }

    private static let displayNames: [String: String] = [
        "anthropic": "Anthropic",
        "openai": "OpenAI",
        "openai-codex": "OpenAI Codex",
        "google": "Google",
        "xai": "xAI",
    ]

    static func displayName(forProvider provider: String) -> String {
        if let known = displayNames[provider] { return known }
        return provider.split(separator: "-").map(\.capitalized).joined(separator: " ")
    }

    static func provider(forID id: String) -> String {
        // The split rule lives once in Core (`AgentBackendConfig.provider`) so
        // the backend filter and this grouping pin the same logic in the matrix.
        AgentBackendConfig.provider(forID: id)
    }

    /// First-appearance provider order (pi's own catalogue order). Row titles
    /// prefer the human name from pi's synced catalog ("Claude Fable 5"),
    /// with the raw id-tail demoted to the caption line; without a name the
    /// tail IS the title — the rail already names the provider, and
    /// `provider/model` twice over is exactly the noise the grouped picker
    /// exists to remove. Slashless ids (off-catalog record values) keep their
    /// full title. QA sees no display names unless a check injects them.
    static func groups(
        from items: [ChoiceItem],
        displayNames: [String: String] = [:]
    ) -> [Group] {
        var order: [String] = []
        var byProvider: [String: [ChoiceItem]] = [:]
        for item in items {
            let provider = provider(forID: item.id)
            let tail = item.id.contains("/")
                ? item.id.split(separator: "/", maxSplits: 1).last.map(String.init) ?? item.title
                : item.title
            let nice = displayNames[item.id]
            let row = ChoiceItem(
                id: item.id, title: nice ?? tail, detail: nice != nil ? tail : item.detail,
                enabled: item.enabled, destructive: item.destructive)
            if byProvider[provider] == nil { order.append(provider) }
            byProvider[provider, default: []].append(row)
        }
        return order.map { provider in
            Group(id: provider, title: displayName(forProvider: provider), models: byProvider[provider] ?? [])
        }
    }
}

/// One square rail button: provider glyph (first letter of the display name),
/// tooltip with the full name, hover/selected painted with the same surface
/// roles as choice rows.
@MainActor
private final class ProviderRailButton: NSControl, TokenThemed {
    let groupID: String
    private let glyphLabel = NSTextField(labelWithString: "")
    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    var isSelectedProvider = false { didSet { applyTokens() } }
    var onPick: ((String) -> Void)?

    static let side: CGFloat = 36

    init(group: ProviderModelGrouping.Group) {
        self.groupID = group.id
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CGFloat(Radius.card)
        glyphLabel.stringValue = String(group.title.prefix(1)).uppercased()
        glyphLabel.font = .token(.body)
        glyphLabel.alignment = .center
        addSubview(glyphLabel)
        toolTip = group.title
        setAccessibilityRole(.button)
        setAccessibilityLabel(group.title)
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    override func layout() {
        super.layout()
        glyphLabel.sizeToFit()
        glyphLabel.frame = NSRect(
            x: floor((bounds.width - glyphLabel.frame.width) / 2),
            y: floor((bounds.height - glyphLabel.frame.height) / 2),
            width: glyphLabel.frame.width,
            height: glyphLabel.frame.height
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; applyTokens() }
    override func mouseExited(with event: NSEvent) { isHovered = false; applyTokens() }
    override func mouseDown(with event: NSEvent) { onPick?(groupID) }
    override func accessibilityPerformPress() -> Bool {
        onPick?(groupID)
        return true
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        let background: TokenColor? = isSelectedProvider
            ? AgentSurfaceRole.rowSelected.color
            : (isHovered ? AgentSurfaceRole.rowHover.color : nil)
        // A resting rail button owns NO colour slot (nil, never .clear) — the
        // inbox card precedent: painting transparent would re-enter the value
        // gate as an unregistered literal.
        layer?.backgroundColor = background?.cgColor(for: theme)
        glyphLabel.textColor = (isSelectedProvider ? TextToken.textPrimary : .textSecondary).color.nsColor(for: theme)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }
}

/// The two-pane surface: provider rail + the selected provider's models as a
/// real `ChoiceListView`. The panel is sized once for the WIDEST/TALLEST
/// group so switching providers never resizes the popover under the pointer.
@MainActor
final class ProviderModelPickerView: NSView, TokenThemed {
    static let railWidth: CGFloat = 44

    private let groups: [ProviderModelGrouping.Group]
    private let selectedModelID: String?
    private var railButtons: [ProviderRailButton] = []
    private let indicator = NSView()
    private let railDivider = NSView()
    private var listView: ChoiceListView?
    private let listPaneSize: NSSize
    private(set) var selectedGroupID: String

    var onSelection: ((ChoiceItem) -> Void)?
    var onDismiss: (() -> Void)?

    init(items: [ChoiceItem], selectedID: String?) {
        let groups = ProviderModelGrouping.groups(
            from: items,
            displayNames: AgentModelCatalog.shared.displayNamesSnapshot())
        self.groups = groups
        self.selectedModelID = selectedID
        self.selectedGroupID = selectedID.map(ProviderModelGrouping.provider(forID:)) ?? groups.first?.id ?? "other"
        var paneSize = NSSize(width: 160, height: 44)
        for group in groups {
            let size = ChoiceListView(items: group.models, selectedID: nil).intrinsicContentSize
            paneSize.width = max(paneSize.width, size.width)
            paneSize.height = max(paneSize.height, size.height)
        }
        self.listPaneSize = paneSize
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = CGFloat(Radius.container)
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 1.25
        railDivider.wantsLayer = true
        addSubview(railDivider)
        addSubview(indicator)
        for group in groups {
            let button = ProviderRailButton(group: group)
            button.onPick = { [weak self] id in self?.selectGroup(id: id) }
            railButtons.append(button)
            addSubview(button)
        }
        installList(for: selectedGroupID)
        applyTokens()
        setAccessibilityLabel("Model picker")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let railHeight = CGFloat(railButtons.count) * (ProviderRailButton.side + 4) + 8
        return NSSize(
            width: Self.railWidth + listPaneSize.width,
            height: max(listPaneSize.height, railHeight)
        )
    }

    override func layout() {
        super.layout()
        var y = bounds.height - 6 - ProviderRailButton.side
        for button in railButtons {
            button.frame = NSRect(
                x: floor((Self.railWidth - ProviderRailButton.side) / 2),
                y: y,
                width: ProviderRailButton.side,
                height: ProviderRailButton.side
            )
            y -= ProviderRailButton.side + 4
        }
        positionIndicator()
        railDivider.frame = NSRect(x: Self.railWidth - 1, y: 0, width: 1, height: bounds.height)
        listView?.frame = NSRect(x: Self.railWidth, y: 0, width: bounds.width - Self.railWidth, height: bounds.height)
        neutralizeInnerCard()
    }

    private func positionIndicator() {
        guard let selected = railButtons.first(where: { $0.groupID == selectedGroupID }) else {
            indicator.isHidden = true
            return
        }
        indicator.isHidden = railButtons.count < 2
        indicator.frame = NSRect(
            x: Self.railWidth - 2.5,
            y: selected.frame.midY - 10,
            width: 2.5,
            height: 20
        )
    }

    private func selectGroup(id: String) {
        guard id != selectedGroupID else { return }
        selectedGroupID = id
        installList(for: id)
        needsLayout = true
        layoutSubtreeIfNeeded()
        for button in railButtons { button.isSelectedProvider = button.groupID == id }
        window?.makeFirstResponder(listView)
    }

    private func installList(for groupID: String) {
        listView?.removeFromSuperview()
        let group = groups.first(where: { $0.id == groupID }) ?? ProviderModelGrouping.Group(id: groupID, title: groupID, models: [])
        let list = ChoiceListView(
            items: group.models,
            selectedID: group.models.contains(where: { $0.id == selectedModelID }) ? selectedModelID : nil
        )
        list.onSelection = { [weak self] item in self?.onSelection?(item) }
        list.onDismiss = { [weak self] in self?.onDismiss?() }
        addSubview(list)
        listView = list
        for button in railButtons { button.isSelectedProvider = button.groupID == groupID }
        neutralizeInnerCard()
    }

    /// The embedded list paints its own card (corner + hairline) for the flat
    /// popover; inside this surface the OUTER container is the card, so the
    /// inner paint is flattened. Re-applied after layout/theme changes because
    /// the list's own applyTokens restores it.
    private func neutralizeInnerCard() {
        listView?.layer?.cornerRadius = 0
        listView?.layer?.borderWidth = 0
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = AgentSurfaceRole.composer.color.cgColor(for: theme)
        layer?.borderColor = AgentLineRole.decorativeHairline.color.cgColor(for: theme)
        railDivider.layer?.backgroundColor = AgentLineRole.decorativeHairline.color.cgColor(for: theme)
        indicator.layer?.backgroundColor = AgentLineRole.focusRing.color.cgColor(for: theme)
        for button in railButtons { button.applyTokens() }
        neutralizeInnerCard()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
        DispatchQueue.main.async { [weak self] in self?.neutralizeInnerCard() }
    }

    var keyboardTarget: NSView? { listView }

    // Deterministic probes (`--provider-model-picker-check`).
    var qaProviderIDs: [String] { groups.map(\.id) }
    var qaProviderTitles: [String] { groups.map(\.title) }
    var qaSelectedProviderID: String { selectedGroupID }
    var qaVisibleModelIDs: [String] { listView?.qaItems.map(\.id) ?? [] }

    /// Every row the pane holds must actually FIT it.
    ///
    /// `ChoiceListView` is a plain view sized by `intrinsicContentSize` — it does
    /// NOT scroll — and the pane is laid out to a fixed height. A list taller than
    /// its pane therefore draws rows nobody can reach or click: the picker looks
    /// frozen. That shipped in 0.4.7 (one list of every provider's models under a
    /// 420pt cap) and was reverted; this is the assertion that would have caught
    /// it. Any future "show more in one pane" change must add real scrolling
    /// first, and this check is what will say so.
    var qaListContentFitsPane: Bool {
        guard let listView else { return true }
        // Compared against the pane size the picker COMPUTED, not the live bounds:
        // bounds are still zero right after `presentPopover()`, so a bounds check
        // fails on layout timing instead of on the defect.
        return listView.intrinsicContentSize.height <= listPaneSize.height + 0.5
    }
    var qaVisibleModelTitles: [String] { listView?.qaItems.map(\.title) ?? [] }
    var qaVisibleModelDetails: [String?] { listView?.qaItems.map(\.detail) ?? [] }
    func selectProviderForQA(_ id: String) { selectGroup(id: id) }
    func chooseModelForQA(_ id: String) { listView?.choose(id: id) }
}

/// Panel host for the picker surface. Deliberately mirrors
/// `ChoicePopoverController`'s anchoring and dismissal machinery (that
/// controller is pinned by existing checks and stays untouched); if a third
/// popover surface ever appears, unify the three then.
@MainActor
final class ProviderModelPopoverController {
    private(set) var panel: NSPanel?
    private(set) var pickerView: ProviderModelPickerView?

    private weak var anchorView: NSView?
    private weak var parentWindow: NSWindow?
    nonisolated(unsafe) private var localMonitor: Any?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    var isPresented: Bool { panel?.isVisible == true }

    deinit {
        MainActor.assumeIsolated { dismiss() }
    }

    func present(
        items: [ChoiceItem],
        selectedID: String?,
        anchor: NSRect,
        relativeTo view: NSView,
        onSelection: @escaping (ChoiceItem) -> Void
    ) {
        dismiss()
        guard !items.isEmpty else { return }
        let picker = ProviderModelPickerView(items: items, selectedID: selectedID)
        pickerView = picker
        guard let window = view.window else { return }

        let contentSize = picker.intrinsicContentSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        panel.contentView = picker
        panel.setFrame(ChoicePopoverController.panelFrame(
            contentSize: contentSize,
            anchor: anchor,
            relativeTo: view,
            visibleFrame: window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        ), display: false)

        self.panel = panel
        anchorView = view
        parentWindow = window

        picker.onSelection = { [weak self] item in
            self?.dismiss()
            onSelection(item)
        }
        picker.onDismiss = { [weak self] in self?.dismiss() }

        window.addChildWindow(panel, ordered: .above)
        installDismissalObservers(for: window, anchor: view)
        panel.orderFront(nil)
        panel.makeKey()
        if let target = picker.keyboardTarget { panel.makeFirstResponder(target) }
        NSAccessibility.post(
            element: picker,
            notification: .announcementRequested,
            userInfo: [.announcement: "Model picker"])
    }

    func dismiss() {
        removeDismissalObservers()
        if let panel {
            parentWindow?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        pickerView = nil
        anchorView = nil
        parentWindow = nil
    }

    private func installDismissalObservers(for window: NSWindow, anchor: NSView) {
        let center = NotificationCenter.default
        if let panel {
            observers.append(center.addObserver(
                forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } })
        }
        observers.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } })
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } })
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel { self.dismiss() }
            return event
        }
    }

    private func removeDismissalObservers() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}

/// The composer's model trigger: identical `ChoiceButton` paint/items/QA,
/// different surface — the provider>model picker instead of the flat list.
@MainActor
final class ProviderModelButton: ChoiceButton {
    private let providerPopover = ProviderModelPopoverController()

    override var presentedPopoverIsVisible: Bool { providerPopover.isPresented }
    override func dismissPresentedPopover() { providerPopover.dismiss() }

    override func presentPopover() {
        // A provider authed while the app runs reaches the NEXT open without
        // a relaunch (throttled; inert in QA, which never enables refresh).
        AgentModelCatalog.shared.requestRefresh()
        providerPopover.present(
            items: items, selectedID: selectedID, anchor: bounds, relativeTo: self
        ) { [weak self] item in
            guard let self else { return }
            self.handleSelection(item)
            _ = self.sendAction(self.action, to: self.target)
        }
    }

    /// The flat-list QA path drives `popoverController.listView`, which this
    /// button never populates — select through the same handleSelection path
    /// the picker's rows use instead.
    @discardableResult
    override func chooseForQA(id: String) -> Bool {
        guard let item = items.first(where: { $0.id == id && $0.enabled }) else { return false }
        handleSelection(item)
        _ = sendAction(action, to: target)
        return true
    }

    var qaPickerView: ProviderModelPickerView? { providerPopover.pickerView }
}

// MARK: - Self-check (`--provider-model-picker-check`)

extension ProviderModelButton {
    enum SelfCheckError: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            if case let .message(text) = self { return text }
            return "provider model picker self-check failed"
        }
    }

    /// Deterministic witness for the grouped picker: pure grouping, rail
    /// contents and initial selection, provider switching, selection funneling
    /// through the footer's settings write, dismissal, a non-blank render, and
    /// no leaked panel. Catalogue options are fixture-injected and restored.
    static func runSelfCheck() throws {
        func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
            if !condition { throw SelfCheckError.message(message()) }
        }

        // Hermetic against ambient harness state. The Agent Harness lives in the
        // standard defaults domain, which is shared across matrix legs and
        // persists on the machine (cfprefsd ignores per-leg isolation), so a
        // leftover .codex/.claudeCode from another leg or an earlier run would
        // filter the catalogue and make the unfiltered-rail assertions below
        // flaky. Force the pi baseline (unfiltered) here and clear on exit; the
        // harness-filter sub-test further down sets its own value explicitly.
        UserDefaults.standard.removeObject(forKey: AgentBackendConfig.key)
        defer { UserDefaults.standard.removeObject(forKey: AgentBackendConfig.key) }

        // 1. Pure grouping: order-preserving, fully-qualified split, slashless
        //    ids grouped under "other", display names title-cased.
        let grouped = ProviderModelGrouping.groups(from: [
            ChoiceItem(id: "openai-codex/gpt-a", title: "gpt-a"),
            ChoiceItem(id: "anthropic/claude-x", title: "claude-x"),
            ChoiceItem(id: "openai-codex/gpt-b", title: "gpt-b"),
            ChoiceItem(id: "legacy-value", title: "legacy-value"),
        ])
        try expect(grouped.map(\.id) == ["openai-codex", "anthropic", "other"],
                   "groups keep first-appearance provider order, got \(grouped.map(\.id))")
        try expect(grouped[0].models.map(\.id) == ["openai-codex/gpt-a", "openai-codex/gpt-b"],
                   "models stay in catalogue order within a provider")
        try expect(grouped[0].title == "OpenAI Codex" && grouped[1].title == "Anthropic",
                   "known providers get display names, got \(grouped.map(\.title))")

        // 1b. Display names ride the same grouping: name becomes the title,
        //     the id tail demotes to the caption; unnamed ids keep the tail.
        let named = ProviderModelGrouping.groups(
            from: [
                ChoiceItem(id: "anthropic/claude-x", title: "claude-x"),
                ChoiceItem(id: "anthropic/claude-y", title: "claude-y"),
            ],
            displayNames: ["anthropic/claude-x": "Claude X"])
        try expect(named[0].models.map(\.title) == ["Claude X", "claude-y"],
                   "display names become row titles, unnamed ids keep the tail, got \(named[0].models.map(\.title))")
        try expect(named[0].models.map(\.detail) == ["claude-x", nil],
                   "named rows demote the id tail to the caption, got \(named[0].models.map(\.detail))")

        // 2. Live surface over a fixture catalogue (with one display name, so
        //    the surface path is proven too).
        AgentModelCatalog.shared.resetForQA(
            options: ["openai-codex/gpt-a", "openai-codex/gpt-b", "anthropic/claude-x"],
            displayNames: ["anthropic/claude-x": "Claude X"])
        defer { AgentModelCatalog.shared.resetForQA() }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let footer = AgentComposerFooterView(frame: NSRect(x: 0, y: 60, width: 520, height: AgentComposerFooterView.height))
        var writes: [(model: String?, thinking: String?)] = []
        footer.onSettingsWrite = { model, thinking in
            writes.append((model, thinking))
            return true
        }
        window.contentView?.addSubview(footer)
        footer.apply(AgentLaunchSelection(harness: .pi, model: "openai-codex/gpt-b", thinking: "medium"))
        footer.layoutSubtreeIfNeeded()
        window.orderFront(nil)

        guard let button = footer.modelButton as? ProviderModelButton else {
            throw SelfCheckError.message("footer's model trigger must be the ProviderModelButton")
        }
        button.presentPopover()
        guard let picker = button.qaPickerView else {
            throw SelfCheckError.message("presenting must install the picker surface")
        }
        try expect(button.presentedPopoverIsVisible, "picker panel should be visible after present")
        try expect(picker.qaProviderIDs == ["openai-codex", "anthropic"],
                   "rail lists the catalogue's providers, got \(picker.qaProviderIDs)")
        try expect(picker.qaSelectedProviderID == "openai-codex",
                   "picker opens on the selected model's provider")
        // No unreachable rows: the list does not scroll, so anything taller than
        // the pane is clipped and the picker reads as frozen (the 0.4.7 regression).
        try expect(picker.qaListContentFitsPane,
                   "every model row must fit the pane — ChoiceListView does not scroll, so a taller list is unreachable")
        try expect(picker.qaVisibleModelIDs == ["openai-codex/gpt-a", "openai-codex/gpt-b"],
                   "right pane lists the active provider's models, got \(picker.qaVisibleModelIDs)")

        // 3. Switching providers swaps the pane without resizing the panel.
        let widthBefore = button.qaPickerView.flatMap { $0.window?.frame.width }
        picker.selectProviderForQA("anthropic")
        try expect(picker.qaVisibleModelIDs == ["anthropic/claude-x"],
                   "switching the rail swaps the model pane, got \(picker.qaVisibleModelIDs)")
        try expect(picker.qaVisibleModelTitles == ["Claude X"] && picker.qaVisibleModelDetails == ["claude-x"],
                   "the live surface renders the display name with the id caption, got \(picker.qaVisibleModelTitles)/\(picker.qaVisibleModelDetails)")
        try expect(button.qaPickerView.flatMap { $0.window?.frame.width } == widthBefore,
                   "provider switch must not resize the panel")

        // 4. Render gate + artifact before the choose dismisses the panel.
        guard let rep = picker.bitmapImageRepForCachingDisplay(in: picker.bounds) else {
            throw SelfCheckError.message("picker surface did not render")
        }
        picker.cacheDisplay(in: picker.bounds, to: rep)
        let metrics = VisualSnapshot.metrics(of: rep)
        try expect(!metrics.isBlank, "picker rendered blank (\(metrics.distinctSampledColors) colors)")
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let artifactDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa-runs/\(timestamp)/provider-model-picker", isDirectory: true)
        try? FileManager.default.createDirectory(at: artifactDir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: artifactDir.appendingPathComponent("picker.png"))

        // 5. Choosing funnels through the footer's partial write and dismisses.
        let panelWindowNumber = button.qaPickerView?.window?.windowNumber
        picker.chooseModelForQA("anthropic/claude-x")
        try expect(writes.map(\.model) == ["anthropic/claude-x"] && writes.map(\.thinking) == [nil],
                   "choosing writes a model-only partial settings write, got \(writes)")
        try expect(footer.qaSettings.model == "anthropic/claude-x",
                   "footer settings must reflect the chosen model, got \(footer.qaSettings.model)")
        try expect(!button.presentedPopoverIsVisible, "choose must dismiss the picker")
        if let panelWindowNumber,
           NSApp.windows.contains(where: { $0.windowNumber == panelWindowNumber && $0.isVisible }) {
            throw SelfCheckError.message("picker panel window leaked after choose")
        }

        // 6. Backend filtering (Plan 02 §4.4): the SAME catalogue the composer
        //    reads (`AgentModelConfig.modelOptions`) narrows to the selected
        //    backend's providers. The fixture catalogue from step 2 (two codex +
        //    one anthropic id) is still active via its defer. Pure form first,
        //    then the resolved form through `.standard` (save/restore).
        try expect(AgentModelConfig.modelOptions(for: .codex) == ["openai-codex/gpt-a", "openai-codex/gpt-b"],
                   "Codex backend must narrow to openai-codex/*, got \(AgentModelConfig.modelOptions(for: .codex))")
        try expect(AgentModelConfig.modelOptions(for: .claudeCode) == ["anthropic/claude-x"],
                   "Claude Code backend must narrow to anthropic/*, got \(AgentModelConfig.modelOptions(for: .claudeCode))")
        try expect(AgentModelConfig.modelOptions(for: .pi) == ["openai-codex/gpt-a", "openai-codex/gpt-b", "anthropic/claude-x"],
                   "pi backend must show every provider, got \(AgentModelConfig.modelOptions(for: .pi))")

        let priorBackend = UserDefaults.standard.string(forKey: AgentBackendConfig.key)
        AgentBackendConfig.store(.codex)
        try expect(AgentModelConfig.modelOptions == ["openai-codex/gpt-a", "openai-codex/gpt-b"],
                   "resolved Codex backend must narrow the live modelOptions, got \(AgentModelConfig.modelOptions)")
        if let priorBackend {
            UserDefaults.standard.set(priorBackend, forKey: AgentBackendConfig.key)
        } else {
            UserDefaults.standard.removeObject(forKey: AgentBackendConfig.key)
        }

        // 7. Footer FILL in the Send row (the recurring effort-picker truncation):
        //    the footer has no intrinsic width, so sharing a row with the Send
        //    button it must absorb the remainder — otherwise it collapses to its
        //    minimum and model/effort truncate while free space sits before Send.
        let fillFooter = AgentComposerFooterView(frame: .zero)
        fillFooter.apply(AgentModelConfig.Resolution(model: "openai-codex/gpt-b", thinking: "medium"))
        let sendStandIn = NSButton(title: "Send", target: nil, action: nil)
        sendStandIn.setContentHuggingPriority(.required, for: .horizontal)
        sendStandIn.setContentCompressionResistancePriority(.required, for: .horizontal)
        let fillRow = NSStackView(views: [fillFooter, sendStandIn])
        fillRow.orientation = .horizontal
        fillRow.spacing = CGFloat(Space.m)
        fillRow.translatesAutoresizingMaskIntoConstraints = false
        // Replicate the tile's real container: a VERTICAL stack with `.leading`
        // alignment (which does NOT stretch its children horizontally) plus the
        // explicit footerRow width pin. This is the context that made the footer
        // collapse; a plain host does not reproduce it.
        let fillColumn = NSStackView(views: [fillRow])
        fillColumn.orientation = .vertical
        fillColumn.alignment = .leading
        fillColumn.translatesAutoresizingMaskIntoConstraints = false
        let fillHost = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 40))
        fillHost.addSubview(fillColumn)
        NSLayoutConstraint.activate([
            fillColumn.leadingAnchor.constraint(equalTo: fillHost.leadingAnchor),
            fillColumn.trailingAnchor.constraint(equalTo: fillHost.trailingAnchor),
            fillColumn.centerYAnchor.constraint(equalTo: fillHost.centerYAnchor),
            fillRow.widthAnchor.constraint(equalTo: fillColumn.widthAnchor),
            fillFooter.heightAnchor.constraint(equalToConstant: AgentComposerFooterView.height),
        ])
        fillHost.layoutSubtreeIfNeeded()
        try expect(fillFooter.bounds.width > 200,
                   "footer collapsed in the Send row (width \(fillFooter.bounds.width)) instead of filling — model/effort truncate")
        try expect(fillFooter.qaFitsCurrentTitles,
                   "footer did not fit its model/effort titles in the Send row (width \(fillFooter.bounds.width)) — the effort picker truncates")
    }
}
