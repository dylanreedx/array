import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// 0.7.30 — what agents left running, as a live panel rather than a menu.
///
/// A menu is a snapshot: it truncates, cannot update while open and can only
/// offer actions one submenu deep. This panel stays current while it is open
/// (the tracker scans every second while anyone is looking), shows each job in
/// full, and puts Open, Copy and Stop on the row. Opened from the top bar's icon
/// (every agent, then the rest of the Mac) and from a tile's chip (that agent).
@MainActor
final class ProcessesPanelController {
    static let width: CGFloat = 480
    static let maximumHeight: CGFloat = 560
    /// Every move in the panel shares one curve: quick out, long settle.
    static let easing = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    static var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func duration(_ seconds: TimeInterval) -> TimeInterval { reduceMotion() ? 0 : seconds }

    private weak var tracker: AgentProcessTracker?
    private(set) var panel: NSPanel?
    private(set) var content: ProcessesPanelContentView?
    private weak var anchor: NSView?
    private weak var parentWindow: NSWindow?
    private var onClose: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var ticker: Timer?

    init(tracker: AgentProcessTracker) {
        self.tracker = tracker
    }

    var isPresented: Bool { panel != nil }
    var presentedScope: AgentID?? { content.map { $0.scope } }

    /// Present under `anchor`, or close if it is already open from there.
    func toggle(from anchor: NSView, scope: AgentID?, onClose: (() -> Void)? = nil) {
        if isPresented, self.anchor === anchor {
            dismiss()
            return
        }
        present(from: anchor, scope: scope, onClose: onClose)
    }

    func present(from anchor: NSView, scope: AgentID?, onClose: (() -> Void)? = nil) {
        dismiss(animated: false)
        guard let tracker, let window = anchor.window else { return }
        let content = ProcessesPanelContentView(tracker: tracker, scope: scope)
        content.onRequestClose = { [weak self] in self?.dismiss() }
        content.onHeightChange = { [weak self] in self?.resize(animated: true) }
        let chrome = ChoicePanelShadowView(surface: content)
        let panel = ProcessesPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        panel.contentView = chrome
        panel.setAccessibilityLabel(scope == nil ? "Processes" : "Background processes")
        panel.onCancel = { [weak self] in self?.dismiss() }
        self.panel = panel
        self.content = content
        self.anchor = anchor
        self.parentWindow = window
        self.onClose = onClose

        content.reload(animated: false)
        panel.setFrame(frame(contentHeight: content.preferredHeight), display: false)
        chrome.layoutSubtreeIfNeeded()
        window.addChildWindow(panel, ordered: .above)

        // In: fade, and settle 6pt down into place.
        panel.alphaValue = 0
        let landed = panel.frame
        panel.setFrame(landed.offsetBy(dx: 0, dy: 6), display: false)
        panel.orderFront(nil)
        panel.makeKey()
        // The surface, not its first button, takes the keyboard: Escape closes,
        // and no control opens wearing a focus ring.
        panel.makeFirstResponder(content)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.duration(0.22)
            context.timingFunction = Self.easing
            panel.animator().alphaValue = 1
            panel.animator().setFrame(landed, display: true)
        }

        tracker.liveDemand += 1
        installDismissal(window: window, anchor: anchor)
        observers.append(NotificationCenter.default.addObserver(
            forName: .agentBackgroundJobsDidChange, object: tracker, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.content?.reload(animated: true) } })
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.content?.tick() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    func dismiss(animated: Bool = true) {
        guard let panel else { return }
        removeDismissal()
        ticker?.invalidate()
        ticker = nil
        if let tracker { tracker.liveDemand = max(0, tracker.liveDemand - 1) }
        let parent = parentWindow
        let close = onClose
        self.panel = nil
        content = nil
        anchor = nil
        parentWindow = nil
        onClose = nil
        close?()
        guard animated, Self.duration(0.14) > 0 else {
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.duration(0.14)
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
        })
    }

    /// Top-anchored under the anchor, clamped to the screen; content height
    /// capped so a long list scrolls instead of leaving the screen.
    private func frame(contentHeight: CGFloat) -> NSRect {
        let margin = ChoicePanelShadowView.margin
        guard let anchor, let window = anchor.window else { return .zero }
        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let width = Self.width
        let gap: CGFloat = 6
        // Right edges line up for the top bar's icon at the window's right;
        // a chip in a tile opens from its own left edge.
        var x = anchorRect.midX > window.frame.midX ? anchorRect.maxX - width : anchorRect.minX
        var height = min(contentHeight, Self.maximumHeight)
        // Clamped to the window's screen. A window on no screen (a check's
        // off-display fixture) keeps its panel off every screen with it.
        if let screen = window.screen?.visibleFrame {
            height = min(height, max(160, anchorRect.minY - screen.minY - gap - 8))
            x = min(max(x, screen.minX + 8), screen.maxX - width - 8)
        }
        let surface = NSRect(x: x, y: anchorRect.minY - gap - height, width: width, height: height)
        return surface.insetBy(dx: -margin, dy: -margin)
    }

    private func resize(animated: Bool) {
        guard let panel, let content else { return }
        let target = frame(contentHeight: content.preferredHeight)
        guard target != panel.frame else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? Self.duration(0.24) : 0
            context.timingFunction = Self.easing
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
        }
    }

    private func installDismissal(window: NSWindow, anchor: NSView) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } })
        observers.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss(animated: false) } })
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel, event.window !== panel else { return event }
            // A press on the anchor closes; it must not reopen on the same click.
            if let anchor = self.anchor, event.window === anchor.window,
               anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) {
                self.dismiss()
                return nil
            }
            self.dismiss()
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismiss() }
        }
    }

    private func removeDismissal() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }
}

@MainActor
private final class ProcessesPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

// MARK: - Content

/// The panel's surface: a header, the list, a footer. Rows are kept by key
/// across reloads, so a row under the pointer keeps its hover and a row being
/// stopped keeps its state while the list moves around it.
@MainActor
final class ProcessesPanelContentView: NSView, TokenThemed {
    static let headerHeight: CGFloat = 44
    static let footerHeight: CGFloat = 30

    let scope: AgentID?
    private weak var tracker: AgentProcessTracker?
    var onRequestClose: (() -> Void)?
    var onHeightChange: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let liveDot = NSView()
    private let headerSeparator = NSView()
    private let footerSeparator = NSView()
    private let footerLabel = NSTextField(labelWithString: "Live · Stop asks a process to quit, then force-quits it after 2s")
    let scrollView = NSScrollView()
    private let list = FlippedView()

    private var rows: [String: ProcessesPanelRow] = [:]
    private var order: [String] = []
    private(set) var otherPortsExpanded = false
    private var otherApps: [OtherListeningApp]?
    private var otherScanInFlight = false
    private(set) var preferredHeight: CGFloat = 0

    init(tracker: AgentProcessTracker, scope: AgentID?) {
        self.tracker = tracker
        self.scope = scope
        super.init(frame: NSRect(x: 0, y: 0, width: ProcessesPanelController.width, height: 200))
        wantsLayer = true
        layer?.masksToBounds = true
        titleLabel.font = .token(.title)
        titleLabel.stringValue = scope.map { tracker.agentName($0) } ?? "Processes"
        titleLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.font = .token(.caption)
        footerLabel.font = .token(.caption)
        footerLabel.lineBreakMode = .byTruncatingTail
        liveDot.wantsLayer = true
        headerSeparator.wantsLayer = true
        footerSeparator.wantsLayer = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = list
        for view in [titleLabel, summaryLabel, liveDot, headerSeparator, scrollView, footerSeparator, footerLabel] {
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(titleLabel.stringValue)
        applyTokens()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.applyCorner(.popover)
        layer?.backgroundColor = SurfaceToken.overlay.color.cgColor(for: theme)
        layer?.borderWidth = ChoiceListView.panelBorderWidth
        layer?.borderColor = AgentLineRole.decorativeHairline.color.cgColor(for: theme)
        titleLabel.textColor = TextToken.textPrimary.color.nsColor(for: theme)
        summaryLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        footerLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        liveDot.layer?.backgroundColor = AccentToken.accentDone.color.cgColor(for: theme)
        liveDot.layer?.applyCapsule()
        let hairline = AgentLineRole.decorativeHairline.color.cgColor(for: theme)
        headerSeparator.layer?.backgroundColor = hairline
        footerSeparator.layer?.backgroundColor = hairline
    }

    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) { onRequestClose?() }

    override func layout() {
        super.layout()
        let width = bounds.width
        let pad: CGFloat = 16
        liveDot.frame = NSRect(x: width - pad - 7, y: Self.headerHeight / 2 - 3.5, width: 7, height: 7)
        let summaryWidth = min(200, fitWidth(summaryLabel))
        let lineHeight = ceil(titleLabel.intrinsicContentSize.height)
        summaryLabel.frame = NSRect(x: liveDot.frame.minX - 8 - summaryWidth,
                                    y: (Self.headerHeight - ceil(summaryLabel.intrinsicContentSize.height)) / 2,
                                    width: summaryWidth, height: ceil(summaryLabel.intrinsicContentSize.height))
        titleLabel.frame = NSRect(x: pad, y: (Self.headerHeight - lineHeight) / 2,
                                  width: max(0, summaryLabel.frame.minX - 12 - pad), height: lineHeight)
        headerSeparator.frame = NSRect(x: 0, y: Self.headerHeight - 1, width: width, height: 1)
        let footerTop = bounds.height - Self.footerHeight
        footerSeparator.frame = NSRect(x: 0, y: footerTop, width: width, height: 1)
        let footerLine = ceil(footerLabel.intrinsicContentSize.height)
        footerLabel.frame = NSRect(x: pad, y: footerTop + (Self.footerHeight - footerLine) / 2,
                                   width: width - pad * 2, height: footerLine)
        scrollView.frame = NSRect(x: 0, y: Self.headerHeight, width: width, height: max(0, footerTop - Self.headerHeight))
        list.frame.size.width = scrollView.contentSize.width
        for key in order { rows[key]?.frame.size.width = list.bounds.width }
    }

    // MARK: Building the list

    /// What the list should hold now, in order, from the tracker's current
    /// state. Each entry names a row by a key that survives reloads.
    private func entries() -> [(key: String, make: () -> ProcessesPanelRow, update: (ProcessesPanelRow) -> Void)] {
        guard let tracker else { return [] }
        let now = Date()
        var result: [(String, () -> ProcessesPanelRow, (ProcessesPanelRow) -> Void)] = []
        let agents = (scope.map { [$0] } ?? tracker.jobsByAgent.keys.sorted { tracker.agentName($0) < tracker.agentName($1) })
            .filter { !tracker.jobs(for: $0).isEmpty }
        if agents.isEmpty {
            let text = scope == nil ? "No agent has anything running" : "Nothing running in the background"
            result.append(("empty", { ProcessesEmptyRow(text: text) }, { _ in }))
        }
        for agent in agents {
            let jobs = tracker.jobs(for: agent)
            if scope == nil || jobs.count > 1 {
                let name = tracker.agentName(agent)
                let detail = tracker.agentDetail(agent)
                result.append(("agent-\(agent.rawValue)", {
                    ProcessesAgentRow(name: name, detail: detail, showsName: self.scope == nil)
                }, { row in
                    guard let row = row as? ProcessesAgentRow else { return }
                    row.update(name: name, detail: detail, jobCount: jobs.count)
                    row.onReveal = { [weak self, weak tracker] in
                        tracker?.revealAgent?(agent)
                        self?.onRequestClose?()
                    }
                    row.onStopAll = { [weak tracker] in tracker?.stop(jobs) }
                }))
            }
            for job in jobs {
                result.append(("job-\(job.id)", { ProcessesJobRow(job: job, now: now) }, { [weak self] row in
                    guard let self, let row = row as? ProcessesJobRow else { return }
                    row.update(job: job, now: now)
                    row.onOpen = { [weak self, weak tracker] port in
                        tracker?.openURL?("http://localhost:\(port)", agent)
                        self?.onRequestClose?()
                    }
                    row.onStop = { [weak tracker] in tracker?.stop([job]) }
                    row.onToggleExpanded = { [weak self] in self?.relayout(animated: true) }
                }))
            }
        }
        guard scope == nil else { return result }
        result.append(("other-header", { ProcessesDisclosureRow() }, { [weak self] row in
            guard let self, let row = row as? ProcessesDisclosureRow else { return }
            row.update(expanded: self.otherPortsExpanded, count: self.otherApps?.count)
            row.onToggle = { [weak self] in self?.toggleOtherPorts() }
        }))
        if otherPortsExpanded {
            guard let apps = otherApps else {
                result.append(("other-loading", { ProcessesEmptyRow(text: "Looking…") }, { _ in }))
                return result
            }
            if apps.isEmpty {
                result.append(("other-none", { ProcessesEmptyRow(text: "Nothing else is listening") }, { _ in }))
            }
            for app in apps {
                result.append(("other-\(app.name)", { ProcessesOtherAppRow(app: app) }, { [weak self] row in
                    guard let row = row as? ProcessesOtherAppRow else { return }
                    row.update(app: app)
                    row.onOpen = { [weak self, weak tracker] port in
                        tracker?.openURL?("http://localhost:\(port)", nil)
                        self?.onRequestClose?()
                    }
                    row.onStop = { [weak tracker] in tracker?.stop(app.processes) }
                }))
            }
        }
        return result
    }

    func reload(animated: Bool) {
        guard let tracker else { return }
        let total = tracker.totalJobCount
        let shown = scope.map { tracker.jobs(for: $0).count } ?? total
        summaryLabel.stringValue = shown == 0 ? "Nothing running" : (shown == 1 ? "1 running" : "\(shown) running")
        let next = entries()
        var nextRows: [String: ProcessesPanelRow] = [:]
        var inserted: Set<String> = []
        for entry in next {
            let row = rows[entry.key] ?? {
                let row = entry.make()
                inserted.insert(entry.key)
                return row
            }()
            entry.update(row)
            nextRows[entry.key] = row
        }
        let removed = rows.filter { nextRows[$0.key] == nil }.map(\.value)
        rows = nextRows
        order = next.map(\.key)
        for key in order where inserted.contains(key) {
            guard let row = rows[key] else { continue }
            list.addSubview(row)
        }
        relayout(animated: animated, inserted: inserted, removed: removed)
        needsLayout = true
    }

    /// Place every row; animate moves, fade new rows in from 4pt above, fade
    /// leaving rows out, then tell the controller the height changed.
    func relayout(animated: Bool, inserted: Set<String> = [], removed: [ProcessesPanelRow] = []) {
        let width = scrollView.contentSize.width > 0 ? scrollView.contentSize.width : ProcessesPanelController.width
        var y: CGFloat = 6
        var targets: [(ProcessesPanelRow, NSRect)] = []
        for key in order {
            guard let row = rows[key] else { continue }
            let height = row.preferredHeight(width: width)
            targets.append((row, NSRect(x: 0, y: y, width: width, height: height)))
            y += height
        }
        y += 6
        let listHeight = y
        let duration = animated ? ProcessesPanelController.duration(0.24) : 0
        list.frame = NSRect(x: 0, y: 0, width: width, height: max(listHeight, list.frame.height))
        for (row, target) in targets where inserted.contains(row.key) {
            row.frame = target.offsetBy(dx: 0, dy: -4)
            row.alphaValue = duration > 0 ? 0 : 1
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = ProcessesPanelController.easing
            context.allowsImplicitAnimation = true
            for (row, target) in targets {
                (duration > 0 ? row.animator() : row).frame = target
                (duration > 0 ? row.animator() : row).alphaValue = row.isStopping ? 0.5 : 1
                row.layoutSubtreeIfNeeded()
            }
            for row in removed {
                (duration > 0 ? row.animator() : row).alphaValue = 0
            }
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                for row in removed { row.removeFromSuperview() }
                self?.list.frame.size.height = listHeight
            }
        })
        preferredHeight = Self.headerHeight + listHeight + Self.footerHeight
        onHeightChange?()
    }

    private func toggleOtherPorts() {
        otherPortsExpanded.toggle()
        if otherPortsExpanded { scanOtherPorts() }
        reload(animated: true)
    }

    private func scanOtherPorts() {
        guard !otherScanInFlight, let tracker else { return }
        otherScanInFlight = true
        tracker.otherListeningApps { [weak self] apps in
            guard let self else { return }
            self.otherScanInFlight = false
            guard apps != self.otherApps else { return }
            self.otherApps = apps
            self.reload(animated: true)
        }
    }

    /// Once a second while open: uptimes move, and the rest of the Mac is
    /// rescanned when that section is open. Agent jobs arrive by notification.
    func tick() {
        let now = Date()
        for row in rows.values { (row as? ProcessesJobRow)?.refreshUptime(now: now) }
        if otherPortsExpanded { scanOtherPorts() }
    }

    // MARK: QA

    var qaJobRows: [ProcessesJobRow] { order.compactMap { rows[$0] as? ProcessesJobRow } }
    var qaAgentRows: [ProcessesAgentRow] { order.compactMap { rows[$0] as? ProcessesAgentRow } }
    var qaOtherAppRows: [ProcessesOtherAppRow] { order.compactMap { rows[$0] as? ProcessesOtherAppRow } }
    var qaDisclosure: ProcessesDisclosureRow? { order.compactMap { rows[$0] as? ProcessesDisclosureRow }.first }
    var qaRowOrder: [String] { order }
    var qaSummary: String { summaryLabel.stringValue }
}

/// The width a label needs to draw without truncating. Its own
/// `intrinsicContentSize` comes up ~4pt short of its cell's drawing width, and
/// a label framed to it truncates its last word.
@MainActor
func fitWidth(_ field: NSTextField) -> CGFloat {
    ceil(field.cell?.cellSize.width ?? field.intrinsicContentSize.width)
}

@MainActor
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Rows

/// One row of the list. Hover paints `rowHover`; rows that act on click say so.
@MainActor
class ProcessesPanelRow: NSView, TokenThemed {
    private(set) var key = ""
    var isStopping = false
    var isHovered = false { didSet { if isHovered != oldValue { applyTokens() } } }
    var paintsHover: Bool { false }
    private var tracking: NSTrackingArea?

    init(key: String) {
        self.key = key
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func preferredHeight(width: CGFloat) -> CGFloat { 36 }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        layer?.backgroundColor = paintsHover && isHovered ? AgentSurfaceRole.rowHover.color.cgColor(in: self) : nil
        layer?.applyCorner(.control)
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    static func label(_ role: TextRole, lines: Int = 1) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = .token(role)
        if lines == 1 {
            // Single-line mode: a wrapping cell capped at one line lays out with
            // line-fragment padding and truncates text its own intrinsic width fits.
            field.lineBreakMode = .byTruncatingTail
            field.usesSingleLineMode = true
        } else {
            field.lineBreakMode = .byCharWrapping
            field.maximumNumberOfLines = lines
            field.cell?.truncatesLastVisibleLine = true
        }
        return field
    }
}

@MainActor
final class ProcessesEmptyRow: ProcessesPanelRow {
    private let label = ProcessesPanelRow.label(.label)

    init(text: String) {
        super.init(key: "empty")
        label.stringValue = text
        label.alignment = .center
        addSubview(label)
        applyTokens()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func preferredHeight(width: CGFloat) -> CGFloat { 52 }

    override func layout() {
        super.layout()
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 16, y: (bounds.height - height) / 2, width: bounds.width - 32, height: height)
    }

    override func applyTokens() {
        super.applyTokens()
        label.textColor = TextToken.textSecondary.color.nsColor(in: self)
    }
}

/// An agent: its name, its harness and project, and Show / Stop All.
@MainActor
final class ProcessesAgentRow: ProcessesPanelRow {
    private let nameLabel = ProcessesPanelRow.label(.label)
    private let detailLabel = ProcessesPanelRow.label(.caption)
    let showButton = ProcessesTextButton(title: "Show Agent", symbol: "arrow.up.forward")
    let stopAllButton = ProcessesTextButton(title: "Stop All", symbol: "stop.circle")
    var onReveal: (() -> Void)?
    var onStopAll: (() -> Void)?
    private let showsName: Bool

    init(name: String, detail: String?, showsName: Bool) {
        self.showsName = showsName
        super.init(key: "agent")
        nameLabel.font = NSFont.systemFont(ofSize: NSFont.token(.label).pointSize, weight: .semibold)
        for view in [nameLabel, detailLabel, showButton, stopAllButton] { addSubview(view) }
        showButton.isHidden = !showsName
        showButton.onClick = { [weak self] in self?.onReveal?() }
        stopAllButton.onClick = { [weak self] in
            guard let self else { return }
            self.stopAllButton.isEnabled = false
            self.stopAllButton.text = "Stopping…"
            self.onStopAll?()
        }
        update(name: name, detail: detail, jobCount: 1)
        applyTokens()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(name: String, detail: String?, jobCount: Int) {
        nameLabel.stringValue = showsName ? name : "\(jobCount) running"
        detailLabel.stringValue = showsName ? (detail ?? "") : ""
        stopAllButton.isHidden = jobCount < 2
        if stopAllButton.isEnabled { stopAllButton.text = "Stop All \(jobCount)" }
        needsLayout = true
    }

    override func preferredHeight(width: CGFloat) -> CGFloat { 38 }

    override func layout() {
        super.layout()
        let pad: CGFloat = 16
        var right = bounds.width - 10
        for button in [stopAllButton, showButton] where !button.isHidden {
            let size = button.intrinsicContentSize
            button.frame = NSRect(x: right - size.width, y: (bounds.height - size.height) / 2 + 2, width: size.width, height: size.height)
            right = button.frame.minX - 4
        }
        let nameWidth = min(fitWidth(nameLabel), max(0, right - pad - 8))
        let line = ceil(nameLabel.intrinsicContentSize.height)
        let y = (bounds.height - line) / 2 + 2
        nameLabel.frame = NSRect(x: pad, y: y, width: nameWidth, height: line)
        let detailLine = ceil(detailLabel.intrinsicContentSize.height)
        detailLabel.frame = NSRect(x: nameLabel.frame.maxX + 8, y: y + (line - detailLine) / 2,
                                   width: max(0, right - nameLabel.frame.maxX - 16), height: detailLine)
    }

    override func applyTokens() {
        super.applyTokens()
        nameLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        detailLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
    }
}

/// One job, readable in full: the command on the first line; its ports (each
/// one opens), pid, uptime and whether it outlives the agent on the second.
/// Copy and Stop sit at the trailing edge. Clicking the row shows the whole
/// command line, selectable.
@MainActor
final class ProcessesJobRow: ProcessesPanelRow {
    private(set) var job: AgentBackgroundJob
    private let titleLabel = ProcessesPanelRow.label(.body)
    private let metaLabel = ProcessesPanelRow.label(.captionMono)
    private let commandLabel = ProcessesPanelRow.label(.captionMono, lines: 6)
    private var portButtons: [ProcessesPortButton] = []
    let copyButton = ChromeIconButton(symbolName: "doc.on.doc", accessibilityLabel: "Copy")
    let stopButton = ChromeIconButton(symbolName: "stop.circle", accessibilityLabel: "Stop")
    var onOpen: ((UInt16) -> Void)?
    var onStop: (() -> Void)?
    var onToggleExpanded: (() -> Void)?
    private(set) var isExpanded = false
    private var copiedUntil: Date?
    override var paintsHover: Bool { true }

    init(job: AgentBackgroundJob, now: Date) {
        self.job = job
        super.init(key: "job-\(job.id)")
        commandLabel.isSelectable = true
        commandLabel.isHidden = true
        for view in [titleLabel, metaLabel, commandLabel, copyButton, stopButton] { addSubview(view) }
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        update(job: job, now: now)
        applyTokens()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(job: AgentBackgroundJob, now: Date) {
        self.job = job
        titleLabel.stringValue = job.label
        titleLabel.toolTip = job.commandLine
        commandLabel.stringValue = job.commandLine
        copyButton.toolTip = job.ports.first.map { "Copy http://localhost:\($0)" } ?? "Copy the command"
        stopButton.toolTip = isStopping ? "Stopping…" : "Stop"
        if portButtons.map(\.port) != job.ports {
            portButtons.forEach { $0.removeFromSuperview() }
            portButtons = job.ports.map { port in
                let button = ProcessesPortButton(port: port)
                button.onClick = { [weak self] in self?.onOpen?(port) }
                addSubview(button)
                return button
            }
        }
        refreshUptime(now: now)
        setAccessibilityLabel("\(job.label), \(metaLabel.stringValue)")
        needsLayout = true
    }

    func refreshUptime(now: Date) {
        var parts = ["pid \(job.rootPid)", AgentBackgroundJobText.uptime(since: job.startedAt, now: now)]
        if job.pids.count > 1 { parts.append("\(job.pids.count) processes") }
        if job.detached { parts.append("outlives the agent") }
        if isStopping { parts = ["stopping…"] }
        let text = parts.joined(separator: " · ")
        if metaLabel.stringValue != text {
            metaLabel.stringValue = text
            needsLayout = true
        }
        if let copiedUntil, now >= copiedUntil {
            self.copiedUntil = nil
            copyButton.image = CanvasSymbolImage.image(named: "doc.on.doc", pointSize: 15, weight: .medium)
        }
    }

    override func preferredHeight(width: CGFloat) -> CGFloat {
        guard isExpanded else { return 52 }
        let textWidth = max(40, width - 32 - 8)
        let height = commandLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 400)).height ?? 16
        return 52 + ceil(height) + 8
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 16
        let side = ChromeIconButton.side
        stopButton.frame = NSRect(x: bounds.width - 8 - side, y: 12, width: side, height: side)
        copyButton.frame = stopButton.frame.offsetBy(dx: -side, dy: 0)
        let textRight = copyButton.frame.minX - 6
        let line = ceil(titleLabel.intrinsicContentSize.height)
        titleLabel.frame = NSRect(x: pad, y: 7, width: max(0, textRight - pad), height: line)
        var x = pad
        let pillY = titleLabel.frame.maxY + 3
        for button in portButtons {
            let size = button.intrinsicContentSize
            button.frame = NSRect(x: x, y: pillY, width: size.width, height: size.height)
            x = button.frame.maxX + 4
        }
        let metaLine = ceil(metaLabel.intrinsicContentSize.height)
        let pillHeight = portButtons.first?.intrinsicContentSize.height ?? metaLine
        metaLabel.frame = NSRect(x: x + (portButtons.isEmpty ? 0 : 4), y: pillY + (pillHeight - metaLine) / 2,
                                 width: max(0, textRight - x), height: metaLine)
        commandLabel.isHidden = !isExpanded
        if isExpanded {
            let width = bounds.width - pad * 2 - 8
            let height = commandLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 400)).height ?? 16
            commandLabel.frame = NSRect(x: pad, y: 52, width: width, height: ceil(height))
        }
    }

    override func applyTokens() {
        super.applyTokens()
        titleLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        metaLabel.textColor = (job.detached && !isStopping ? AccentToken.accentApproval : nil)?.color.nsColor(in: self)
            ?? TextToken.textSecondary.color.nsColor(in: self)
        commandLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard event.clickCount == 1, !isStopping else { return }
        isExpanded.toggle()
        needsLayout = true
        onToggleExpanded?()
    }

    @objc private func copyClicked() {
        AgentProcessUI.copy(job.ports.first.map { "http://localhost:\($0)" } ?? job.commandLine)
        copyButton.image = CanvasSymbolImage.image(named: "checkmark", pointSize: 15, weight: .medium)
        copiedUntil = Date().addingTimeInterval(1.2)
    }

    @objc private func stopClicked() {
        guard !isStopping else { return }
        isStopping = true
        stopButton.isEnabled = false
        copyButton.isEnabled = false
        refreshUptime(now: Date())
        applyTokens()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ProcessesPanelController.duration(0.18)
            context.timingFunction = ProcessesPanelController.easing
            animator().alphaValue = 0.5
        }
        onStop?()
    }
}

/// The rest of the Mac, closed until asked for.
@MainActor
final class ProcessesDisclosureRow: ProcessesPanelRow {
    private let chevron = NSImageView()
    private let label = ProcessesPanelRow.label(.label)
    private let countLabel = ProcessesPanelRow.label(.caption)
    var onToggle: (() -> Void)?
    private(set) var isExpanded = false
    override var paintsHover: Bool { true }

    init() {
        super.init(key: "other-header")
        label.stringValue = "Other ports on this Mac"
        chevron.image = CanvasSymbolImage.image(named: "chevron.right", pointSize: 10, weight: .semibold)
        chevron.imageScaling = .scaleNone
        chevron.wantsLayer = true
        for view in [chevron, label, countLabel] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel("Other ports on this Mac")
        applyTokens()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(expanded: Bool, count: Int?) {
        if expanded != isExpanded {
            isExpanded = expanded
            NSAnimationContext.runAnimationGroup { context in
                context.duration = ProcessesPanelController.duration(0.2)
                context.timingFunction = ProcessesPanelController.easing
                context.allowsImplicitAnimation = true
                chevron.layer?.setAffineTransform(expanded ? CGAffineTransform(rotationAngle: -.pi / 2) : .identity)
            }
        }
        countLabel.stringValue = count.map(String.init) ?? ""
        setAccessibilityValue(expanded ? "expanded" : "collapsed")
        needsLayout = true
    }

    override func preferredHeight(width: CGFloat) -> CGFloat { 36 }

    override func layout() {
        super.layout()
        chevron.frame = NSRect(x: 14, y: (bounds.height - 14) / 2, width: 14, height: 14)
        if let layer = chevron.layer {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.position = CGPoint(x: chevron.frame.midX, y: chevron.frame.midY)
        }
        let line = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: 34, y: (bounds.height - line) / 2, width: fitWidth(label), height: line)
        let countLine = ceil(countLabel.intrinsicContentSize.height)
        countLabel.frame = NSRect(x: label.frame.maxX + 6, y: (bounds.height - countLine) / 2, width: 60, height: countLine)
    }

    override func applyTokens() {
        super.applyTokens()
        label.textColor = TextToken.textSecondary.color.nsColor(in: self)
        countLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
        chevron.contentTintColor = TextToken.textSecondary.color.nsColor(in: self)
    }

    override func mouseUp(with event: NSEvent) { onToggle?() }
}

/// One app listening on this Mac: its name, its ports (each one opens), and
/// Stop behind a confirmation, since nothing here is an agent's.
@MainActor
final class ProcessesOtherAppRow: ProcessesPanelRow {
    private(set) var app: OtherListeningApp
    private let nameLabel = ProcessesPanelRow.label(.body)
    private let metaLabel = ProcessesPanelRow.label(.captionMono)
    private var portButtons: [ProcessesPortButton] = []
    let stopButton = ProcessesTextButton(title: "Stop", symbol: nil)
    var onOpen: ((UInt16) -> Void)?
    var onStop: (() -> Void)?
    private var confirming = false
    override var paintsHover: Bool { true }

    init(app: OtherListeningApp) {
        self.app = app
        super.init(key: "other-\(app.name)")
        for view in [nameLabel, metaLabel, stopButton] { addSubview(view) }
        stopButton.onClick = { [weak self] in self?.stopClicked() }
        update(app: app)
        applyTokens()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(app: OtherListeningApp) {
        self.app = app
        nameLabel.stringValue = app.name
        let pids = app.processes.map { "\($0.pid)" }
        metaLabel.stringValue = (pids.count == 1 ? "pid \(pids[0])" : "\(pids.count) processes")
        toolTip = app.processes.map { $0.arguments.joined(separator: " ") }.joined(separator: "\n")
        if portButtons.map(\.port) != app.ports {
            portButtons.forEach { $0.removeFromSuperview() }
            portButtons = app.ports.map { port in
                let button = ProcessesPortButton(port: port)
                button.onClick = { [weak self] in self?.onOpen?(port) }
                addSubview(button)
                return button
            }
        }
        needsLayout = true
    }

    override func preferredHeight(width: CGFloat) -> CGFloat { 48 }

    override func layout() {
        super.layout()
        let size = stopButton.intrinsicContentSize
        stopButton.frame = NSRect(x: bounds.width - 10 - size.width, y: (bounds.height - size.height) / 2,
                                  width: size.width, height: size.height)
        let left: CGFloat = 34
        let right = stopButton.frame.minX - 8
        let line = ceil(nameLabel.intrinsicContentSize.height)
        nameLabel.frame = NSRect(x: left, y: 6, width: max(0, min(fitWidth(nameLabel), right - left)), height: line)
        var x = left
        let pillY = nameLabel.frame.maxY + 3
        for button in portButtons {
            let size = button.intrinsicContentSize
            button.frame = NSRect(x: x, y: pillY, width: size.width, height: size.height)
            x = button.frame.maxX + 4
        }
        let metaLine = ceil(metaLabel.intrinsicContentSize.height)
        let pillHeight = portButtons.first?.intrinsicContentSize.height ?? metaLine
        metaLabel.frame = NSRect(x: x + 4, y: pillY + (pillHeight - metaLine) / 2,
                                 width: max(0, right - x - 4), height: metaLine)
    }

    override func applyTokens() {
        super.applyTokens()
        nameLabel.textColor = TextToken.textPrimary.color.nsColor(in: self)
        metaLabel.textColor = TextToken.textSecondary.color.nsColor(in: self)
    }

    private func stopClicked() {
        guard confirming else {
            confirming = true
            stopButton.text = "Stop \(app.name)?"
            stopButton.isDestructive = true
            needsLayout = true
            // Unconfirmed, it goes back to plain Stop.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.confirming, !self.isStopping else { return }
                self.confirming = false
                self.stopButton.text = "Stop"
                self.stopButton.isDestructive = false
                self.needsLayout = true
            }
            return
        }
        isStopping = true
        stopButton.text = "Stopping…"
        stopButton.isEnabled = false
        needsLayout = true
        onStop?()
    }
}

// MARK: - Controls

/// `:8080` — a port you can open, drawn as a small capsule.
@MainActor
final class ProcessesPortButton: NSButton, TokenThemed {
    let port: UInt16
    var onClick: (() -> Void)?
    var isHovered = false { didSet { if isHovered != oldValue { applyTokens() } } }
    private var tracking: NSTrackingArea?

    init(port: UInt16) {
        self.port = port
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        target = self
        action = #selector(clicked)
        toolTip = "Open localhost:\(port) in a browser tile"
        setAccessibilityLabel("Open port \(port)")
        applyTokens()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        let text = attributedTitle.size()
        return NSSize(width: ceil(text.width) + 14, height: 18)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        layer?.backgroundColor = (isHovered ? AgentSurfaceRole.rowSelected : AgentSurfaceRole.codeSubdued).color.cgColor(in: self)
        layer?.applyCapsule()
        attributedTitle = NSAttributedString(string: ":\(port)", attributes: [
            .font: NSFont.token(.captionMono),
            .foregroundColor: TextToken.textPrimary.color.nsColor(in: self),
        ])
    }

    override func layout() {
        super.layout()
        layer?.applyCapsule()
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    @objc private func clicked() { onClick?() }
}

/// A compact text action: `Show Agent ↗`, `Stop All 3`, `Stop postgres?`.
@MainActor
final class ProcessesTextButton: NSButton, TokenThemed {
    var onClick: (() -> Void)?
    var isDestructive = false { didSet { applyTokens() } }
    private let symbol: String?
    var isHovered = false { didSet { if isHovered != oldValue { applyTokens() } } }
    private var tracking: NSTrackingArea?

    var text: String { didSet { applyTokens(); invalidateIntrinsicContentSize() } }

    init(title: String, symbol: String?) {
        text = title
        self.symbol = symbol
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        target = self
        action = #selector(clicked)
        if let symbol {
            image = CanvasSymbolImage.image(named: symbol, pointSize: 10, weight: .semibold)
            imagePosition = .imageTrailing
            imageHugsTitle = true
        }
        setAccessibilityLabel(title)
        applyTokens()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(attributedTitle.size().width) + (symbol == nil ? 16 : 30), height: 22)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        layer?.backgroundColor = isHovered && isEnabled ? AgentSurfaceRole.rowSelected.color.cgColor(in: self) : nil
        layer?.applyCorner(.control)
        let color = (isDestructive ? AccentToken.accentFailed.color : TextToken.textSecondary.color).nsColor(in: self)
        contentTintColor = color
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.token(.caption).pointSize, weight: .medium),
            .foregroundColor: color,
        ])
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    @objc private func clicked() { onClick?() }
}
