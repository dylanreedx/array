import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

@MainActor
final class FloatingToolbarController: NSObject {
    enum Selection: Equatable {
        case createZone
        case palette(LaunchPaletteAction)
        case terminalProfile(String)
        case agentHarness(AgentHarness)
        case fanOutQueueSelection
    }

    static let didChangeSettings = Notification.Name("array.floatingToolbar.settingsChanged")

    private let defaults: UserDefaults
    private let onSelection: (Selection) -> Void
    private let terminalProfiles: () -> [FloatingToolbarProfile]
    var onPositionChanged: (() -> Void)?
    private var panel: NSPanel?
    private var toolbarView: FloatingToolbarView?
    private var edge: FloatingToolbarEdge = .top
    private var observer: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        terminalProfiles: @escaping () -> [FloatingToolbarProfile],
        onSelection: @escaping (Selection) -> Void
    ) {
        self.defaults = defaults
        self.terminalProfiles = terminalProfiles
        self.onSelection = onSelection
        super.init()
        observer = NotificationCenter.default.addObserver(
            forName: Self.didChangeSettings, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshSettings() }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func show(near host: NSWindow? = nil) {
        guard isVisibleSettingEnabled else { close(); return }
        let panel = ensurePanel()
        restorePosition(host: host)
        panel.orderFront(host)
        applyVisibilityMode()
        writeVisibilityDiagnostic(reason: "show")
    }

    func close() {
        panel?.orderOut(nil)
    }

    func refreshSettings() {
        guard isVisibleSettingEnabled else { close(); return }
        guard let panel else { show(); return }
        toolbarView?.compact = defaults.bool(forKey: FloatingToolbarConfig.compactKey)
        toolbarView?.alwaysVisible = alwaysVisible
        toolbarView?.rebuildButtons()
        restorePosition(host: panel)
        panel.orderFront(nil)
        applyVisibilityMode()
        resizeAndKeepAnchored()
        writeVisibilityDiagnostic(reason: "settingsRefresh")
    }

    func writeVisibilityDiagnostic(reason: String) {
        guard let path = ProcessInfo.processInfo.environment["CONTINUUM_TOOLBAR_DIAGNOSTIC_PATH"],
              !path.isEmpty else { return }
        let panelState: String
        if let panel {
            let root = panel.contentView
            let rootState = root.map {
                "root=\(String(reflecting: type(of: $0))) rootAX=\($0.accessibilityIdentifier() ?? "nil") "
                    + "wantsLayer=\($0.wantsLayer) background=\(String(describing: $0.layer?.backgroundColor))"
            } ?? "root=nil"
            let details: [String] = [
                "exists=true visible=\(panel.isVisible) key=\(panel.isKeyWindow) main=\(panel.isMainWindow)",
                "alpha=\(panel.alphaValue) level=\(panel.level.rawValue) floating=\(panel.isFloatingPanel)",
                "hidesOnDeactivate=\(panel.hidesOnDeactivate) windowNumber=\(panel.windowNumber)",
                "axRole=\(String(describing: panel.accessibilityRole())) axTitle=\(String(reflecting: panel.accessibilityTitle() ?? "nil"))",
                "title=\(String(reflecting: panel.title)) frame=\(NSStringFromRect(panel.frame))",
                "screen=\(panel.screen?.localizedName ?? "none")", rootState,
            ]
            panelState = details.joined(separator: " ")
        } else {
            panelState = "exists=false"
        }
        let line = "\(Date().timeIntervalSince1970) reason=\(reason) appActive=\(NSApp.isActive) \(panelState)\n"
        let url = URL(fileURLWithPath: path)
        let data = Data(line.utf8)
        if FileManager.default.fileExists(atPath: path), let handle = try? FileHandle(forWritingTo: url) {
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private var isVisibleSettingEnabled: Bool {
        defaults.object(forKey: FloatingToolbarConfig.visibleKey) == nil
            ? FloatingToolbarConfig.defaultVisible
            : defaults.bool(forKey: FloatingToolbarConfig.visibleKey)
    }

    private var alwaysVisible: Bool {
        defaults.object(forKey: FloatingToolbarConfig.alwaysVisibleKey) == nil
            ? FloatingToolbarConfig.defaultAlwaysVisible
            : defaults.bool(forKey: FloatingToolbarConfig.alwaysVisibleKey)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let view = FloatingToolbarView(frame: NSRect(x: 0, y: 0, width: 520, height: 60))
        view.autoresizingMask = [.width, .height]
        view.compact = defaults.bool(forKey: FloatingToolbarConfig.compactKey)
        view.alwaysVisible = alwaysVisible
        view.defaults = defaults
        view.rebuildButtons()
        view.onSelection = { [weak self] selection in self?.onSelection(selection) }
        view.terminalProfiles = terminalProfiles
        view.onDragFinished = { [weak self] start in self?.finishDrag(startingAt: start) }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 60),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = view
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        self.panel = panel
        self.toolbarView = view
        return panel
    }

    private func restorePosition(host: NSWindow?) {
        guard let panel else { return }
        edge = FloatingToolbarEdge(rawValue: defaults.string(forKey: FloatingToolbarConfig.positionEdgeKey) ?? "top") ?? .top
        toolbarView?.orientation = edge.orientation
        let screens = NSScreen.screens
        guard let screen = host?.screen ?? NSScreen.main ?? screens.first else { panel.center(); return }
        var size = size(for: edge)
        let visible = screen.visibleFrame
        var frame: NSRect
        if defaults.object(forKey: FloatingToolbarConfig.positionXKey) != nil,
           defaults.object(forKey: FloatingToolbarConfig.positionYKey) != nil {
            frame = FloatingToolbarGeometry.restoredFreeFrame(
                screen: visible,
                xFraction: CGFloat(defaults.double(forKey: FloatingToolbarConfig.positionXKey)),
                yFraction: CGFloat(defaults.double(forKey: FloatingToolbarConfig.positionYKey)),
                size: size,
                margin: FloatingToolbarGeometry.positionMargin
            )
            let nearest = FloatingToolbarGeometry.distanceToNearestEdge(frame, screen: visible, preferredEdge: edge)
            if nearest.distance <= FloatingToolbarGeometry.edgeSnapThreshold {
                edge = nearest.edge
                toolbarView?.orientation = edge.orientation
                size = self.size(for: edge)
                frame = FloatingToolbarGeometry.snappedFrame(frame, screen: visible, edge: edge, size: size, margin: FloatingToolbarGeometry.positionMargin)
            }
        } else {
            let along = CGFloat(defaults.object(forKey: FloatingToolbarConfig.positionAlongEdgeKey) == nil
                ? 0.5 : defaults.double(forKey: FloatingToolbarConfig.positionAlongEdgeKey)).clamped(to: 0...1)
            frame = FloatingToolbarGeometry.restoredFrame(screen: visible, edge: edge, along: along, size: size, margin: FloatingToolbarGeometry.positionMargin)
        }
        panel.setFrame(frame, display: true)
    }

    private func finishDrag(startingAt origin: NSPoint) {
        guard let panel, let screen = nearestScreen(to: panel.frame) else { return }
        finishDrag(startingAt: origin, visibleFrame: screen.visibleFrame)
    }

    private func finishDrag(startingAt origin: NSPoint, visibleFrame visible: NSRect) {
        guard let panel,
              hypot(panel.frame.origin.x - origin.x, panel.frame.origin.y - origin.y) > 0.5 else { return }
        let position = FloatingToolbarGeometry.distanceToNearestEdge(panel.frame, screen: visible, preferredEdge: edge)
        var frame = panel.frame
        if position.distance <= FloatingToolbarGeometry.edgeSnapThreshold {
            edge = position.edge
            toolbarView?.orientation = edge.orientation
            let size = size(for: edge)
            frame = FloatingToolbarGeometry.snappedFrame(panel.frame, screen: visible, edge: edge, size: size, margin: FloatingToolbarGeometry.positionMargin)
        } else {
            frame = FloatingToolbarGeometry.clampedFreeFrame(panel.frame, screen: visible, margin: FloatingToolbarGeometry.positionMargin)
        }
        panel.setFrame(frame, display: true, animate: true)
        storePosition(frame: frame, screen: visible)
        onPositionChanged?()
    }

    var qaPanelFrame: NSRect? { panel?.frame }
    var qaPanelIsVisible: Bool { panel?.isVisible == true }
    var qaPanelHasTokenPaintedRoot: Bool {
        guard let root = panel?.contentView as? FloatingToolbarView,
              root.wantsLayer,
              let background = root.layer?.backgroundColor,
              let border = root.layer?.borderColor else { return false }
        return background.alpha > 0 && border.alpha > 0
    }
    var qaPanelWindowNumber: Int? { panel?.windowNumber }

    func qaSetPanelFrame(_ frame: NSRect) {
        ensurePanel().setFrame(frame, display: false)
    }

    func qaEndDrag(startingAt origin: NSPoint, frame: NSRect, screen: NSRect) {
        ensurePanel().setFrame(frame, display: false)
        finishDrag(startingAt: origin, visibleFrame: screen)
    }

    private func storePosition(frame: NSRect, screen: NSRect) {
        defaults.set(edge.rawValue, forKey: FloatingToolbarConfig.positionEdgeKey)
        let point = FloatingToolbarGeometry.normalizedFreePosition(frame, screen: screen, margin: FloatingToolbarGeometry.positionMargin)
        defaults.set(Double(point.x), forKey: FloatingToolbarConfig.positionXKey)
        defaults.set(Double(point.y), forKey: FloatingToolbarConfig.positionYKey)
        defaults.set(Double(FloatingToolbarGeometry.normalizedPosition(frame, screen: screen, edge: edge, margin: FloatingToolbarGeometry.positionMargin)), forKey: FloatingToolbarConfig.positionAlongEdgeKey)
    }

    private func resizeAndKeepAnchored() {
        guard let panel, let screen = nearestScreen(to: panel.frame) else { return }
        let nextSize = size(for: edge)
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let resized = NSRect(x: center.x - nextSize.width / 2, y: center.y - nextSize.height / 2, width: nextSize.width, height: nextSize.height)
        panel.setFrame(FloatingToolbarGeometry.clampedFreeFrame(resized, screen: screen.visibleFrame, margin: FloatingToolbarGeometry.positionMargin), display: true)
    }

    private func applyVisibilityMode() {
        panel?.alphaValue = 1
    }

    private func nearestScreen(to frame: NSRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            lhs.visibleFrame.intersection(frame).area < rhs.visibleFrame.intersection(frame).area
        }
    }

    private func size(for edge: FloatingToolbarEdge) -> NSSize {
        let buttons = toolbarView?.buttonCount ?? FloatingToolbarView.visibleToolbarItemCount(defaults: defaults)
        let compact = defaults.bool(forKey: FloatingToolbarConfig.compactKey)
        let buttonSize: CGFloat = compact ? 38 : (alwaysVisible ? 88 : 62)
        let gaps = CGFloat(max(0, buttons - 1)) * 5
        return edge.orientation == .horizontal
            ? NSSize(width: CGFloat(buttons) * buttonSize + gaps + 20, height: compact ? 48 : 62)
            : NSSize(width: compact ? 48 : 62, height: CGFloat(buttons) * buttonSize + gaps + 20)
    }
}

struct FloatingToolbarProfile: Equatable {
    let id: String
    let title: String
}

enum FloatingToolbarEdge: String {
    case top, right, bottom, left
    var orientation: NSUserInterfaceLayoutOrientation { (self == .top || self == .bottom) ? .horizontal : .vertical }
    static func nearest(to panel: NSRect, within screen: NSRect, preferredEdge: Self? = nil) -> Self {
        FloatingToolbarGeometry.distanceToNearestEdge(panel, screen: screen, preferredEdge: preferredEdge).edge
    }
}

enum FloatingToolbarGeometry {
    static let positionMargin: CGFloat = 12
    static let edgeSnapThreshold: CGFloat = 24

    static func distanceToNearestEdge(
        _ frame: NSRect,
        screen: NSRect,
        preferredEdge: FloatingToolbarEdge? = nil
    ) -> (edge: FloatingToolbarEdge, distance: CGFloat) {
        let distances: [(FloatingToolbarEdge, CGFloat)] = [
            (.left, abs(frame.minX - screen.minX)),
            (.right, abs(screen.maxX - frame.maxX)),
            (.bottom, abs(frame.minY - screen.minY)),
            (.top, abs(screen.maxY - frame.maxY)),
        ]
        let minimum = distances.map(\.1).min() ?? .greatestFiniteMagnitude
        let nearestChoices = distances.filter { abs($0.1 - minimum) < 0.5 }
        let nearest = nearestChoices.first(where: { $0.0 == preferredEdge })
            ?? nearestChoices.first
            ?? (.top, .greatestFiniteMagnitude)
        return (nearest.0, nearest.1)
    }

    static func normalizedFreePosition(_ frame: NSRect, screen: NSRect, margin: CGFloat) -> NSPoint {
        let x = (frame.minX - screen.minX - margin) / max(1, screen.width - frame.width - 2 * margin)
        let y = (frame.minY - screen.minY - margin) / max(1, screen.height - frame.height - 2 * margin)
        return NSPoint(x: x.clamped(to: 0...1), y: y.clamped(to: 0...1))
    }

    static func restoredFreeFrame(screen: NSRect, xFraction: CGFloat, yFraction: CGFloat, size: NSSize, margin: CGFloat) -> NSRect {
        let x = xFraction.clamped(to: 0...1)
        let y = yFraction.clamped(to: 0...1)
        return NSRect(
            x: screen.minX + margin + x * max(0, screen.width - size.width - 2 * margin),
            y: screen.minY + margin + y * max(0, screen.height - size.height - 2 * margin),
            width: size.width,
            height: size.height
        )
    }

    static func clampedFreeFrame(_ frame: NSRect, screen: NSRect, margin: CGFloat) -> NSRect {
        let maxX = max(screen.minX + margin, screen.maxX - frame.width - margin)
        let maxY = max(screen.minY + margin, screen.maxY - frame.height - margin)
        return NSRect(
            x: frame.minX.clamped(to: (screen.minX + margin)...maxX),
            y: frame.minY.clamped(to: (screen.minY + margin)...maxY),
            width: frame.width,
            height: frame.height
        )
    }

    static func restoredFrame(screen: NSRect, edge: FloatingToolbarEdge, along: CGFloat, size: NSSize, margin: CGFloat) -> NSRect {
        let along = along.clamped(to: 0...1)
        let origin: NSPoint
        switch edge {
        case .top:
            origin = NSPoint(x: screen.minX + margin + along * max(0, screen.width - size.width - 2 * margin), y: screen.maxY - size.height - margin)
        case .bottom:
            origin = NSPoint(x: screen.minX + margin + along * max(0, screen.width - size.width - 2 * margin), y: screen.minY + margin)
        case .left:
            origin = NSPoint(x: screen.minX + margin, y: screen.minY + margin + along * max(0, screen.height - size.height - 2 * margin))
        case .right:
            origin = NSPoint(x: screen.maxX - size.width - margin, y: screen.minY + margin + along * max(0, screen.height - size.height - 2 * margin))
        }
        return NSRect(origin: origin, size: size)
    }

    static func snappedFrame(_ frame: NSRect, screen: NSRect, edge: FloatingToolbarEdge, size: NSSize, margin: CGFloat) -> NSRect {
        var adjusted = frame
        adjusted.origin.x = frame.midX - size.width / 2
        adjusted.origin.y = frame.midY - size.height / 2
        adjusted.size = size
        let along = normalizedPosition(adjusted, screen: screen, edge: edge, margin: margin)
        return restoredFrame(screen: screen, edge: edge, along: along, size: size, margin: margin)
    }

    static func normalizedPosition(_ frame: NSRect, screen: NSRect, edge: FloatingToolbarEdge, margin: CGFloat) -> CGFloat {
        let fraction: CGFloat
        if edge.orientation == .horizontal {
            fraction = (frame.minX - screen.minX - margin) / max(1, screen.width - frame.width - 2 * margin)
        } else {
            fraction = (frame.minY - screen.minY - margin) / max(1, screen.height - frame.height - 2 * margin)
        }
        return fraction.clamped(to: 0...1)
    }
}

@MainActor
final class FloatingToolbarView: NSView, TokenThemed {
    var defaults: UserDefaults = .standard
    var compact = false { didSet { rebuildButtons() } }
    var alwaysVisible = false { didSet { rebuildButtons() } }
    var orientation: NSUserInterfaceLayoutOrientation = .horizontal { didSet { rebuildButtons() } }
    var onSelection: ((FloatingToolbarController.Selection) -> Void)?
    var terminalProfiles: (() -> [FloatingToolbarProfile])?
    var onDragFinished: ((NSPoint) -> Void)?
    private var stack: NSStackView?
    private var hoverPopover: NSPopover?
    private var choicesPopover: NSPopover?

    var qaAgentChoicesPopoverIsShown: Bool { choicesPopover?.isShown == true }

    func qaOpenAgentChoicesPopover() -> Bool {
        guard let button = stack?.arrangedSubviews.compactMap({ $0 as? ToolbarButton }).first(where: {
            if case .palette(.newManagedAgent) = $0.item.action { return true }
            return false
        }) else { return false }
        selectItem(button)
        return qaAgentChoicesPopoverIsShown
    }

    func qaDispatchAgentButtonMouseExit() -> Bool {
        guard let button = stack?.arrangedSubviews.compactMap({ $0 as? ToolbarButton }).first(where: {
            if case .palette(.newManagedAgent) = $0.item.action { return true }
            return false
        }),
        let event = NSEvent.enterExitEvent(
            with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            eventNumber: 91, trackingNumber: 1, userData: nil
        ) else { return false }
        button.mouseExited(with: event)
        return true
    }

    var qaChoicePopoverTitle: String? {
        guard choicesPopover?.isShown == true,
              let content = choicesPopover?.contentViewController?.view as? NSStackView,
              let heading = content.arrangedSubviews.first as? NSTextField else { return nil }
        return heading.stringValue
    }
    var qaHoverPopoverIsShown: Bool {
        hoverPopover?.isShown == true
            && hoverPopover?.contentViewController?.view is ToolbarHoverPillView
    }

    func qaOpenTerminalProfilesPopover() -> Bool {
        guard let button = stack?.arrangedSubviews.compactMap({ $0 as? ToolbarButton }).first(where: {
            if case .terminalProfiles = $0.item.action { return true }
            return false
        }) else { return false }
        selectItem(button)
        return qaChoicePopoverTitle == "Choose a terminal profile"
    }

    func qaDispatchMouseExitButton(titled title: String) -> Bool {
        guard let button = stack?.arrangedSubviews.compactMap({ $0 as? ToolbarButton }).first(where: {
            $0.item.title == title
        }),
        let event = NSEvent.enterExitEvent(
            with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            eventNumber: 93, trackingNumber: 3, userData: nil
        ) else { return false }
        button.mouseExited(with: event)
        return true
    }

    func qaDispatchMouseEnteredButton(titled title: String) -> Bool {
        guard let button = stack?.arrangedSubviews.compactMap({ $0 as? ToolbarButton }).first(where: {
            $0.item.title == title
        }),
        let event = NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            eventNumber: 94, trackingNumber: 4, userData: nil
        ) else { return false }
        button.mouseEntered(with: event)
        return true
    }

    var buttonCount: Int { Self.visibleToolbarItems(defaults: defaults).count + 1 }

    static func visibleToolbarItemCount(defaults: UserDefaults) -> Int {
        visibleToolbarItems(defaults: defaults).count
    }

    private static func visibleToolbarItems(defaults: UserDefaults) -> [(String, FloatingToolbarItem, String?)] {
        CommandRegistry.definitions().compactMap { definition in
            guard let item = definition.floatingToolbarItem else { return nil }
            let key = FloatingToolbarConfig.itemVisibleKey(commandID: definition.id.rawValue)
            let visible = defaults.object(forKey: key) == nil
                ? FloatingToolbarConfig.defaultItemVisible
                : defaults.bool(forKey: key)
            guard visible else { return nil }
            let shortcut = definition.shortcuts.first?.defaultGestures.first?.displayString
            return (definition.id.rawValue, item, shortcut)
        }
    }

    private static var agentToolbarChoices: [(String, FloatingToolbarController.Selection)] {
        var choices: [(String, FloatingToolbarController.Selection)] = [
            ("Claude Code", .agentHarness(.claudeCode)),
            ("Codex", .agentHarness(.codex)),
            ("Pi", .agentHarness(.pi)),
        ]
        if let fanOut = CommandRegistry.definitions().first(where: { $0.paletteAction == .fanOutQueueSelection }) {
            choices.append((fanOut.title, .fanOutQueueSelection))
        }
        return choices
    }

    var qaButtonTitles: [String] { Self.visibleToolbarItems(defaults: defaults).map { $0.1.title } }
    var qaVisibleButtonCount: Int { Self.visibleToolbarItems(defaults: defaults).count }
    var qaButtonsRemainVisible: Bool { stack?.isHidden == false && qaVisibleButtonCount > 0 }
    var qaShowsLabelsAlways: Bool { alwaysVisible }
    var qaOrientation: NSUserInterfaceLayoutOrientation { orientation }
    static var qaAgentChoices: [(String, FloatingToolbarController.Selection)] { agentToolbarChoices }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityIdentifier("ArrayFloatingToolbarRoot")
        toolTip = "Add zones, agents and terminals here, or press ⌘K"
        applyTokens()
        rebuildButtons()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        layer?.backgroundColor = SurfaceToken.panel.color.cgColor(in: self)
        layer?.borderColor = LineToken.border.color.cgColor(in: self)
        layer?.borderWidth = 1
        layer?.cornerRadius = 14
    }

    func rebuildButtons() {
        if let stack {
            stack.removeFromSuperview()
        }
        let stack = NSStackView()
        stack.orientation = orientation
        stack.alignment = orientation == .horizontal ? .centerY : .centerX
        stack.distribution = .fillProportionally
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let handle = ToolbarDragHandleView(onDragFinished: { [weak self] origin in self?.onDragFinished?(origin) })
        stack.addArrangedSubview(handle)
        handle.widthAnchor.constraint(equalToConstant: orientation == .horizontal ? 24 : 34).isActive = true
        handle.heightAnchor.constraint(equalToConstant: orientation == .horizontal ? 34 : 24).isActive = true
        for (_, item, shortcut) in Self.visibleToolbarItems(defaults: defaults) {
            let button = ToolbarButton(item: item, shortcut: shortcut, compact: compact, showLabel: alwaysVisible && !compact)
            button.target = self
            button.action = #selector(selectItem(_:))
            button.identifier = NSUserInterfaceItemIdentifier("ArrayFloatingToolbar.\(item.title.replacingOccurrences(of: " ", with: ""))")
            button.onHover = { [weak self] button, hovering in
                guard let self else { return }
                if hovering { self.showHoverPill(for: button) }
                else { self.closeHoverPopover() }
            }
            stack.addArrangedSubview(button)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        self.stack = stack
        needsLayout = true
    }

    private func closeHoverPopover() {
        hoverPopover?.performClose(nil)
        hoverPopover = nil
    }

    private func closeChoicesPopover() {
        choicesPopover?.performClose(nil)
        choicesPopover = nil
    }

    private func showHoverPill(for button: ToolbarButton) {
        guard choicesPopover?.isShown != true else { return }
        closeHoverPopover()
        let pill = ToolbarHoverPillView(title: button.item.title, shortcut: button.shortcut)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        let controller = NSViewController()
        controller.view = pill
        popover.contentViewController = controller
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: orientation == .horizontal ? .maxY : .maxX)
        hoverPopover = popover
    }

    @objc private func selectItem(_ sender: ToolbarButton) {
        switch sender.item.action {
        case .createZone:
            onSelection?(.createZone)
        case .palette(let action) where action == .newManagedAgent:
            showChoices(title: "Choose an agent action", choices: Self.agentToolbarChoices) { [weak self] selection in
                self?.onSelection?(selection)
            }
        case .terminalProfiles:
            let profiles = terminalProfiles?() ?? []
            showChoices(title: "Choose a terminal profile", choices: profiles.map { ($0.title, $0.id) }) { [weak self] profile in
                self?.onSelection?(.terminalProfile(profile))
            }
        case .palette(let action):
            onSelection?(.palette(action))
        }
    }

    private func showChoices<Value>(title: String, choices: [(String, Value)], selection: @escaping (Value) -> Void) {
        closeHoverPopover()
        closeChoicesPopover()
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4
        content.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        content.addArrangedSubview(heading)
        for (label, value) in choices {
            let button = ToolbarPopoverChoiceButton(title: label) { [weak self] in
                selection(value)
                self?.closeChoicesPopover()
            }
            button.bezelStyle = .rounded
            button.controlSize = .small
            content.addArrangedSubview(button)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = content
        choicesPopover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: orientation == .horizontal ? .minY : .maxX)
    }
}

@MainActor
private final class ToolbarButton: NSButton {
    let item: FloatingToolbarItem
    let shortcut: String?
    var onHover: ((ToolbarButton, Bool) -> Void)?
    private var shortcutTracking: NSTrackingArea?
    init(item: FloatingToolbarItem, shortcut: String?, compact: Bool, showLabel: Bool) {
        self.item = item
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .texturedRounded
        controlSize = .small
        image = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: item.title)
        imagePosition = compact ? .imageOnly : .imageAbove
        title = showLabel ? item.title : ""
        toolTip = shortcut.map { "\(item.title) · \($0)" } ?? item.title
        setAccessibilityLabel(item.title)
        setAccessibilityIdentifier("ArrayFloatingToolbarButton.\(item.title.replacingOccurrences(of: " ", with: ""))")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateTrackingAreas() {
        if let shortcutTracking { removeTrackingArea(shortcutTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        shortcutTracking = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { onHover?(self, true) }
    override func mouseExited(with event: NSEvent) { onHover?(self, false) }
}

@MainActor
private final class ToolbarPopoverChoiceButton: NSButton {
    private let callback: () -> Void
    init(title: String, callback: @escaping () -> Void) {
        self.callback = callback
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(fire(_:))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func fire(_ sender: Any?) { callback() }
}

@MainActor
private final class ToolbarDragHandleView: NSView, TokenThemed {
    private let onDragFinished: (NSPoint) -> Void
    private let glyph = NSImageView()

    init(onDragFinished: @escaping (NSPoint) -> Void) {
        self.onDragFinished = onDragFinished
        super.init(frame: .zero)
        wantsLayer = true
        glyph.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Move toolbar")
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 14),
            glyph.heightAnchor.constraint(equalToConstant: 14),
        ])
        setAccessibilityLabel("Move Floating Toolbar")
        setAccessibilityIdentifier("ArrayFloatingToolbarDragHandle")
        toolTip = "Drag to move the toolbar"
        applyTokens()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        layer?.backgroundColor = SurfaceToken.panel.color.cgColor(in: self)
        layer?.cornerRadius = 6
        glyph.contentTintColor = TextToken.textSecondary.color.nsColor(in: self)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = window.frame.origin
        window.performDrag(with: event)
        if hypot(window.frame.origin.x - start.x, window.frame.origin.y - start.y) > 0.5 {
            onDragFinished(start)
        }
    }
}

@MainActor
final class ToolbarHoverPillView: NSView, TokenThemed {
    private var textLabels: [NSTextField] = []

    init(title: String, shortcut: String?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 190, height: 34))
        wantsLayer = true
        var labels: [NSTextField] = []
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        labels.append(titleLabel)
        row.addArrangedSubview(titleLabel)
        if let shortcut {
            let shortcutLabel = NSTextField(labelWithString: shortcut)
            shortcutLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
            labels.append(shortcutLabel)
            row.addArrangedSubview(shortcutLabel)
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
            heightAnchor.constraint(equalToConstant: 34),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        textLabels = labels
        applyTokens()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        layer?.backgroundColor = SurfaceToken.panel.color.cgColor(in: self)
        layer?.borderColor = LineToken.border.color.cgColor(in: self)
        layer?.borderWidth = 1
        layer?.cornerRadius = 12
        for (index, label) in textLabels.enumerated() {
            label.textColor = (index == 0 ? TextToken.textPrimary : TextToken.textSecondary).color.nsColor(in: self)
        }
    }
}

@MainActor
final class FloatingToolbarSettingsView: NSView {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let itemCount = CommandRegistry.definitions().filter { $0.floatingToolbarItem != nil }.count
        super.init(frame: NSRect(x: 0, y: 0, width: 510, height: CGFloat(180 + itemCount * 28)))
        heightAnchor.constraint(equalToConstant: CGFloat(180 + itemCount * 28)).isActive = true
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func qaActivateControl(_ identifier: String) throws {
        guard let button = descendants(of: self).compactMap({ $0 as? NSButton })
            .first(where: { $0.accessibilityIdentifier() == identifier }) else {
            throw FloatingToolbarChecks.Failure(description: "missing settings control \(identifier)")
        }
        button.performClick(nil)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func build() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        stack.addArrangedSubview(toggle("Show Floating Toolbar", key: FloatingToolbarConfig.visibleKey, fallback: true))
        stack.addArrangedSubview(toggle("Always Show Labels", key: FloatingToolbarConfig.alwaysVisibleKey, fallback: false))
        stack.addArrangedSubview(toggle("Compact Toolbar", key: FloatingToolbarConfig.compactKey, fallback: false))
        for definition in CommandRegistry.definitions() {
            guard let item = definition.floatingToolbarItem else { continue }
            let key = FloatingToolbarConfig.itemVisibleKey(commandID: definition.id.rawValue)
            stack.addArrangedSubview(toggle("Show \(item.title) Button", key: key, fallback: FloatingToolbarConfig.defaultItemVisible))
        }
        let reset = NSButton(title: "Reset Position", target: self, action: #selector(resetPosition(_:)))
        reset.bezelStyle = .rounded
        reset.controlSize = .small
        reset.setAccessibilityIdentifier("ArrayFloatingToolbarResetPosition")
        stack.addArrangedSubview(reset)
    }

    private func toggle(_ title: String, key: String, fallback: Bool) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(settingChanged(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(key)
        button.state = (defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)) ? .on : .off
        button.setAccessibilityIdentifier("ArrayFloatingToolbarSetting.\(key)")
        return button
    }

    @objc private func settingChanged(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        defaults.set(sender.state == .on, forKey: key)
        NotificationCenter.default.post(name: FloatingToolbarController.didChangeSettings, object: nil)
        SettingChangeEvent.post(SettingID(rawValue: key))
    }

    @objc private func resetPosition(_ sender: Any?) {
        defaults.removeObject(forKey: FloatingToolbarConfig.positionEdgeKey)
        defaults.removeObject(forKey: FloatingToolbarConfig.positionAlongEdgeKey)
        defaults.removeObject(forKey: FloatingToolbarConfig.positionXKey)
        defaults.removeObject(forKey: FloatingToolbarConfig.positionYKey)
        NotificationCenter.default.post(name: FloatingToolbarController.didChangeSettings, object: nil)
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(range.upperBound, max(range.lowerBound, self)) }
}
