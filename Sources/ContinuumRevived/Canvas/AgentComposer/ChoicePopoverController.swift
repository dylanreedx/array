import AppKit
import ContinuumRevivedAgentUI

@MainActor
private final class ChoicePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The panel's content: a transparent margin that carries the surface's shadow,
/// with the surface itself inset by `margin`.
///
/// The shadow is drawn here rather than by the window server on purpose. A
/// borderless panel with `hasShadow` gets the server's shadow RIM with it — a
/// light outline around the window shape that no layer property can turn off.
/// Over the 0.5pt hairline the surface already paints, that rim read as a thick
/// light border (the zone-creation cancel menu, and the same note on the first
/// floating toolbar, which was also a shadowed panel).
@MainActor
final class ChoicePanelShadowView: NSView {
    static let margin: CGFloat = 16
    let surface: NSView
    private let shadowLayer = CALayer()

    init(surface: NSView) {
        self.surface = surface
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.22
        shadowLayer.shadowRadius = 10
        shadowLayer.shadowOffset = CGSize(width: 0, height: -3)
        layer?.addSublayer(shadowLayer)
        addSubview(surface)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        surface.frame = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.frame = surface.frame
        // Follows the surface's own radius, so the shadow can never show a
        // corner the surface does not have.
        let radius = min(surface.layer?.cornerRadius ?? 0, surface.bounds.height / 2, surface.bounds.width / 2)
        shadowLayer.shadowPath = CGPath(
            roundedRect: shadowLayer.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.commit()
    }

    /// The margin is not part of the menu: a press there must not land on it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return surface.frame.contains(local) ? super.hitTest(point) : nil
    }
}

struct CompletionPopoverLayout: Equatable {
    let breadcrumb: String
    let footer: String
    var maximumVisibleRows = 8
    var minimumWidth: CGFloat = 360
    var maximumWidth: CGFloat = 520
}

struct CommandPopoverLayout: Equatable {
    var maximumVisibleRows = 12
    var minimumWidth: CGFloat = 300
    var maximumWidth: CGFloat = 560
}

enum ChoicePopoverLayout: Equatable {
    case intrinsic
    case completion(CompletionPopoverLayout)
    case commands(CommandPopoverLayout)
}

@MainActor
final class CompletionPopoverContentView: NSView, TokenThemed, AgentPageZoomScalable {
    static let headerHeight: CGFloat = 32
    static let footerHeight: CGFloat = 28

    /// WS5: the same two metrics at a page zoom. The `static let`s above are kept
    /// so callers outside a zoomed surface keep compiling; these are the same
    /// values scaled, and exact identities at 100%.
    static func headerHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(32)) }
    static func footerHeight(zoom: AgentPageZoom) -> CGFloat { CGFloat(zoom.scaled(28)) }

    let listView: ChoiceListView
    let scrollView = NSScrollView(frame: .zero)
    fileprivate let breadcrumbLabel = NSTextField(labelWithString: "")
    fileprivate let footerLabel = NSTextField(labelWithString: "")
    private let locationIcon = NSImageView(frame: .zero)
    private let breadcrumbText: String
    private let headerSeparator = NSView(frame: .zero)
    private let footerSeparator = NSView(frame: .zero)
    private var positionedInitialScroll = false
    /// WS5: the page zoom this panel draws at. A panel is not a subview of the
    /// tile, so the rung arrives through this initializer, not through the walk.
    private(set) var pageZoom: AgentPageZoom = .default

    init(listView: ChoiceListView, layout: CompletionPopoverLayout, zoom: AgentPageZoom = .default) {
        self.listView = listView
        self.breadcrumbText = layout.breadcrumb
        self.pageZoom = zoom
        super.init(frame: .zero)
        listView.applyPageZoom(zoom)
        wantsLayer = true
        layer?.cornerRadius = CGFloat(pageZoom.scaled(Radius.container))
        layer?.masksToBounds = true

        breadcrumbLabel.lineBreakMode = .byTruncatingMiddle
        breadcrumbLabel.setAccessibilityLabel("Current folder: \(layout.breadcrumb)")

        // Use the same frozen symbol representation as result rows so the root
        // glyph has identical optical bounds instead of AppKit's baseline-heavy
        // live SF Symbol metrics.
        locationIcon.image = CanvasSymbolImage.image(named: "folder")
        locationIcon.imageScaling = .scaleProportionallyDown
        locationIcon.setAccessibilityElement(false)

        footerLabel.stringValue = layout.footer
        footerLabel.font = .token(.caption, zoom: pageZoom)
        footerLabel.alignment = .center
        footerLabel.lineBreakMode = .byTruncatingTail

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = listView

        for view in [headerSeparator, footerSeparator] { view.wantsLayer = true }
        addSubview(scrollView)
        addSubview(locationIcon)
        addSubview(breadcrumbLabel)
        addSubview(footerLabel)
        addSubview(headerSeparator)
        addSubview(footerSeparator)
        setAccessibilityRole(.group)
        setAccessibilityLabel("File suggestions")
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let hairline = LineWidth.hairline
        let headerHeight = Self.headerHeight(zoom: pageZoom)
        let footerHeight = Self.footerHeight(zoom: pageZoom)
        let footerInset = CGFloat(pageZoom.scaled(10))
        footerLabel.frame = NSRect(x: footerInset, y: 0, width: max(0, bounds.width - footerInset * 2), height: footerHeight)
        footerSeparator.frame = NSRect(x: 0, y: footerHeight, width: bounds.width, height: hairline)
        scrollView.frame = NSRect(
            x: 0,
            y: footerHeight,
            width: bounds.width,
            height: max(0, bounds.height - headerHeight - footerHeight)
        )
        headerSeparator.frame = NSRect(x: 0, y: bounds.height - headerHeight, width: bounds.width, height: hairline)
        let headerOriginY = bounds.height - headerHeight
        let headerCenterY = headerOriginY + headerHeight / 2
        let glyphSide = CGFloat(pageZoom.scaled(14))
        locationIcon.frame = NSRect(
            x: CGFloat(pageZoom.scaled(12)),
            y: floor(headerCenterY - glyphSide / 2),
            width: glyphSide,
            height: glyphSide
        )
        let breadcrumbHeight = ceil(breadcrumbLabel.intrinsicContentSize.height)
        let breadcrumbX = CGFloat(pageZoom.scaled(36))
        breadcrumbLabel.frame = NSRect(
            x: breadcrumbX,
            y: floor(headerCenterY - breadcrumbHeight / 2),
            width: max(0, bounds.width - breadcrumbX - CGFloat(pageZoom.scaled(12))),
            height: breadcrumbHeight
        )

        let documentHeight = listView.intrinsicContentSize.height
        listView.frame = NSRect(
            x: 0, y: 0,
            width: max(0, scrollView.contentSize.width),
            height: documentHeight
        )
        listView.layoutSubtreeIfNeeded()
        if !positionedInitialScroll {
            positionedInitialScroll = true
            listView.scrollFocusedRowToVisible()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = SurfaceToken.overlay.color.cgColor(for: theme)
        layer?.borderWidth = ChoiceListView.panelBorderWidth
        layer?.borderColor = AgentLineRole.decorativeHairline.color.cgColor(for: theme)
        locationIcon.contentTintColor = TextToken.textSecondary.color.nsColor(for: theme)
        applyBreadcrumb(theme: theme)
        footerLabel.textColor = TextToken.textSecondary.color.nsColor(for: theme)
        let separator = AgentLineRole.decorativeHairline.color.cgColor(for: theme)
        headerSeparator.layer?.backgroundColor = separator
        footerSeparator.layer?.backgroundColor = separator
        listView.applyTokens()
    }

    /// WS5: re-derive every zoom-owned metric from scratch, including the
    /// breadcrumb's own attributed fonts, and pass the rung to the embedded list.
    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        layer?.cornerRadius = CGFloat(pageZoom.scaled(Radius.container))
        footerLabel.font = .token(.caption, zoom: pageZoom)
        listView.applyPageZoom(pageZoom)
        applyBreadcrumb(theme: effectiveTokenTheme)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func applyBreadcrumb(theme: TokenTheme) {
        let segments = breadcrumbText.components(separatedBy: "  ›  ")
        let result = NSMutableAttributedString()
        let secondary = TextToken.textSecondary.color.nsColor(for: theme)
        let primary = TextToken.textPrimary.color.nsColor(for: theme)
        let breadcrumbSize = CGFloat(pageZoom.scaled(Double(NSFont.smallSystemFontSize)))
        let regular = NSFont.systemFont(ofSize: breadcrumbSize, weight: .medium)
        let current = NSFont.systemFont(ofSize: breadcrumbSize, weight: .semibold)
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(
                    string: "  ›  ",
                    attributes: [.font: regular, .foregroundColor: secondary]
                ))
            }
            result.append(NSAttributedString(
                string: segment,
                attributes: [
                    .font: index == segments.count - 1 ? current : regular,
                    .foregroundColor: index == segments.count - 1 ? primary : secondary,
                ]
            ))
        }
        breadcrumbLabel.attributedStringValue = result
    }
}

@MainActor
final class CommandPopoverContentView: NSView, TokenThemed, AgentPageZoomScalable {
    let listView: ChoiceListView
    let scrollView = NSScrollView(frame: .zero)
    /// WS5: the page zoom this panel draws at, delivered through the initializer
    /// because a panel is not a subview of the tile.
    private(set) var pageZoom: AgentPageZoom = .default

    init(listView: ChoiceListView, zoom: AgentPageZoom = .default) {
        self.listView = listView
        self.pageZoom = zoom
        super.init(frame: .zero)
        listView.applyPageZoom(zoom)
        wantsLayer = true
        layer?.cornerRadius = CGFloat(pageZoom.scaled(Radius.container))
        layer?.masksToBounds = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = listView
        addSubview(scrollView)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Commands")
        applyTokens()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        listView.frame = NSRect(
            x: 0,
            y: 0,
            width: max(0, scrollView.contentSize.width),
            height: listView.intrinsicContentSize.height
        )
        listView.layoutSubtreeIfNeeded()
        listView.scrollFocusedRowToVisible()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTokens()
    }

    /// WS5: re-derive every zoom-owned metric from scratch and pass the rung to
    /// the embedded list.
    func applyPageZoom(_ zoom: AgentPageZoom) {
        pageZoom = zoom
        layer?.cornerRadius = CGFloat(pageZoom.scaled(Radius.container))
        listView.applyPageZoom(pageZoom)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    func applyTokens() {
        let theme = effectiveTokenTheme
        layer?.backgroundColor = SurfaceToken.overlay.color.cgColor(for: theme)
        layer?.borderWidth = ChoiceListView.panelBorderWidth
        layer?.borderColor = AgentLineRole.decorativeHairline.color.cgColor(for: theme)
        listView.applyTokens()
    }
}

/// Owns the anchored panel and all dismissal observers. Closures capture the
/// controller weakly so presenting a choice never extends a tile's lifetime.
@MainActor
final class ChoicePopoverController {
    private(set) var panel: NSPanel?
    private(set) var listView: ChoiceListView?
    /// The visible menu surface inside `panel` (the panel itself is larger by
    /// `ChoicePanelShadowView.margin` on every side, which holds the shadow).
    private(set) weak var surfaceView: NSView?

    /// Canvas chrome a menu must never cover: the floating toolbar registers its
    /// bar here when it is installed. Weak, so a removed toolbar stops counting.
    private static let obstacleViews = NSHashTable<NSView>.weakObjects()

    static func registerObstacle(_ view: NSView) { obstacleViews.add(view) }

    /// The screen frames of the registered obstacles that are on screen in
    /// `window`. A bar in another window, or a hidden one, is not in the way.
    static func obstacleScreenFrames(in window: NSWindow) -> [NSRect] {
        obstacleViews.allObjects.compactMap { view in
            guard view.window === window, !view.isHiddenOrHasHiddenAncestor else { return nil }
            return window.convertToScreen(view.convert(view.bounds, to: nil))
        }
    }

    /// The menu surface in screen coordinates, without the shadow margin.
    var surfaceFrame: NSRect? {
        panel.map { $0.frame.insetBy(dx: ChoicePanelShadowView.margin, dy: ChoicePanelShadowView.margin) }
    }
    private(set) var lastAccessibilityAnnouncementForQA: String?
    private weak var completionContentView: CompletionPopoverContentView?

    private weak var anchorView: NSView?
    private weak var focusReturnView: NSView?
    private weak var parentWindow: NSWindow?
    private var anchorWasPostingFrameChanges: Bool?
    // AppKit monitor/observer tokens are main-thread resources but are not marked
    // Sendable. `nonisolated(unsafe)` lets nonisolated deinit remove them; every
    // read/write elsewhere remains confined to this @MainActor type.
    nonisolated(unsafe) private var localMonitor: Any?
    nonisolated(unsafe) private var globalMonitor: Any?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private var anchorWindowObservation: NSKeyValueObservation?
    private var cancellationHandler: (() -> Void)?

    /// WS5: the page zoom the presented surface draws at.
    ///
    /// A panel is NOT a subview of the tile, so `AgentPageZoomScaling.apply`
    /// can never reach it. The anchoring view — which the walk DOES reach —
    /// forwards its rung here before presenting.
    var pageZoom: AgentPageZoom = .default

    var isPresented: Bool { panel?.isVisible == true }

    deinit {
        // This controller is created, retained, and released only by MainActor
        // views. Swift deinitializers are nonisolated, so state the invariant while
        // synchronously restoring the anchor and detaching any visible child panel.
        MainActor.assumeIsolated { dismiss() }
    }

    func present(
        items: [ChoiceItem],
        selectedID: String?,
        presentation: ChoiceListPresentation = .choices,
        layout: ChoicePopoverLayout = .intrinsic,
        anchor: NSRect,
        relativeTo view: NSView,
        placementFrame: NSRect? = nil,
        takesFocus: Bool = true,
        accessibilityLabel customAccessibilityLabel: String? = nil,
        onSelection: @escaping (ChoiceItem) -> Void,
        focusReturnView: NSView? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        dismiss()
        lastAccessibilityAnnouncementForQA = nil
        guard !items.isEmpty else { return }
        // Build the production choice list before asking AppKit for a window. QA
        // probes can exercise the exact rendered contents while the host window is
        // not yet attached; a missing panel must not make that seam vacuous.
        let list = ChoiceListView(
            items: items,
            selectedID: selectedID,
            presentation: presentation,
            chrome: layout == .intrinsic ? .standalone : .embedded
        )
        list.applyPageZoom(pageZoom)
        listView = list
        guard let window = view.window else { return }

        // A window on no screen (a check fixture parked off every display) has
        // no screen to clamp to: falling back to the main screen put its menu ON
        // that screen, far from its anchor.
        let screenFrame = window.screen?.visibleFrame
            ?? placementFrame
            ?? NSScreen.main?.visibleFrame
            ?? window.frame
        let requestedFrame = placementFrame.map { $0.intersection(screenFrame) }
        let visibleFrame: NSRect
        if let requestedFrame, !requestedFrame.isNull, !requestedFrame.isEmpty {
            visibleFrame = requestedFrame
        } else {
            visibleFrame = screenFrame
        }
        let windowAnchor = view.convert(anchor, to: nil)
        let screenAnchor = window.convertToScreen(windowAnchor)
        // Only a menu confined to a canvas viewport (`placementFrame`) steers
        // around canvas chrome. A screen-wide menu — a composer picker, a
        // sidebar row menu — keeps its own placement: the toolbar is not in its
        // way, and cutting the screen around it would move menus nowhere near it.
        let obstacles = placementFrame == nil ? [] : Self.obstacleScreenFrames(in: window)
        let contentView: NSView
        let contentSize: NSSize
        let placementFrame: NSRect
        switch layout {
        case .intrinsic:
            contentView = list
            contentSize = list.intrinsicContentSize
            placementFrame = visibleFrame
        case .completion(let configuration):
            let safeFrame = Self.region(visibleFrame.insetBy(dx: 8, dy: 8), clearOf: obstacles, zoom: pageZoom)
            let container = CompletionPopoverContentView(
                listView: list, layout: configuration, zoom: pageZoom)
            completionContentView = container
            contentView = container
            contentSize = Self.completionContentSize(
                list: list,
                configuration: configuration,
                screenAnchor: screenAnchor,
                visibleFrame: safeFrame,
                zoom: pageZoom
            )
            container.frame = NSRect(origin: .zero, size: contentSize)
            container.layoutSubtreeIfNeeded()
            placementFrame = safeFrame
        case .commands(let configuration):
            let safeFrame = Self.region(visibleFrame.insetBy(dx: 8, dy: 8), clearOf: obstacles, zoom: pageZoom)
            let container = CommandPopoverContentView(listView: list, zoom: pageZoom)
            contentView = container
            contentSize = Self.commandContentSize(
                list: list,
                configuration: configuration,
                visibleFrame: safeFrame,
                zoom: pageZoom
            )
            container.frame = NSRect(origin: .zero, size: contentSize)
            container.layoutSubtreeIfNeeded()
            placementFrame = safeFrame
        }
        let panel = ChoicePanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // See `ChoicePanelShadowView`: the server's shadow brings a rim with it.
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        let chrome = ChoicePanelShadowView(surface: contentView)
        panel.contentView = chrome
        let margin = ChoicePanelShadowView.margin
        panel.setFrame(Self.panelFrame(
            contentSize: contentSize,
            anchor: anchor,
            relativeTo: view,
            visibleFrame: Self.region(placementFrame, clearOf: obstacles, zoom: pageZoom),
            zoom: pageZoom
        ).insetBy(dx: -margin, dy: -margin), display: false)
        chrome.layoutSubtreeIfNeeded()

        self.panel = panel
        surfaceView = contentView
        listView = list
        anchorView = view
        self.focusReturnView = focusReturnView
        cancellationHandler = onDismiss
        parentWindow = window
        let defaultAccessibilityLabel: String
        switch layout {
        case .intrinsic: defaultAccessibilityLabel = "Agent actions"
        case .completion: defaultAccessibilityLabel = "File suggestions"
        case .commands: defaultAccessibilityLabel = "Commands"
        }
        let accessibilityLabel = customAccessibilityLabel ?? defaultAccessibilityLabel
        list.setAccessibilityLabel(accessibilityLabel)
        panel.setAccessibilityLabel(accessibilityLabel)
        anchorWasPostingFrameChanges = view.postsFrameChangedNotifications

        list.onSelection = { [weak self] item in
            self?.dismiss()
            onSelection(item)
        }
        list.onDismiss = { [weak self] in self?.dismissAsCancellation() }

        window.addChildWindow(panel, ordered: .above)
        installDismissalObservers(for: window, anchor: view, takesFocus: takesFocus)
        panel.orderFront(nil)
        if takesFocus {
            panel.makeKey()
            panel.makeFirstResponder(list)
        }
        let announcement = customAccessibilityLabel.map { "\($0) menu" } ?? {
            switch layout {
            case .intrinsic: return "Agent actions menu"
            case .completion: return "File suggestions"
            case .commands: return "Commands"
            }
        }()
        // Keep the observable value on the same path as the real VoiceOver post;
        // checks do not claim an announcement merely because a label exists.
        lastAccessibilityAnnouncementForQA = announcement
        NSAccessibility.post(
            element: list,
            notification: .announcementRequested,
            userInfo: [.announcement: announcement])
    }

    /// Passive completion panels keep the editor first responder and forward its
    /// unmodified navigation commands through the same enabled-row selection path.
    @discardableResult
    func perform(_ command: ChoiceListCommand) -> Bool {
        guard isPresented, let listView else { return false }
        listView.perform(command)
        return true
    }

    func dismiss() {
        removeDismissalObservers()
        if let panel {
            parentWindow?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        let returnView = focusReturnView
        let window = parentWindow
        panel = nil
        listView = nil
        surfaceView = nil
        completionContentView = nil
        anchorView = nil
        focusReturnView = nil
        parentWindow = nil
        cancellationHandler = nil
        if let returnView, let window, returnView.window === window {
            window.makeFirstResponder(returnView)
        }
    }

    private func dismissAsCancellation() {
        let handler = cancellationHandler
        dismiss()
        handler?()
    }

    /// Resizes the presented surface to `width`, keeping its origin. The panel
    /// grows with it, margin included.
    func setSurfaceWidth(_ width: CGFloat) {
        guard let panel, let surfaceView else { return }
        let margin = ChoicePanelShadowView.margin
        var frame = panel.frame
        frame.size.width = width + margin * 2
        panel.setFrame(frame, display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        surfaceView.needsLayout = true
        surfaceView.layoutSubtreeIfNeeded()
    }

    /// `frame` less every obstacle in it: for each obstacle (grown by the menu
    /// gap) that cuts the frame, keep the largest of the four bands either side
    /// of it. The floating toolbar rests on one canvas edge, so this keeps the
    /// whole menu on the open side of the bar rather than nudging it off one
    /// corner. A frame no obstacle touches is returned unchanged.
    static func region(_ frame: NSRect, clearOf obstacles: [NSRect], zoom: AgentPageZoom = .default) -> NSRect {
        var region = frame
        let gap = CGFloat(zoom.scaled(Space.s))
        for obstacle in obstacles {
            let cut = obstacle.insetBy(dx: -gap, dy: -gap).intersection(region)
            guard !cut.isNull, !cut.isEmpty else { continue }
            let bands = [
                NSRect(x: region.minX, y: region.minY, width: region.width, height: cut.minY - region.minY),
                NSRect(x: region.minX, y: cut.maxY, width: region.width, height: region.maxY - cut.maxY),
                NSRect(x: region.minX, y: region.minY, width: cut.minX - region.minX, height: region.height),
                NSRect(x: cut.maxX, y: region.minY, width: region.maxX - cut.maxX, height: region.height),
            ].filter { $0.width > 0 && $0.height > 0 }
            guard let largest = bands.max(by: { $0.width * $0.height < $1.width * $1.height }) else { continue }
            region = largest
        }
        return region
    }

    /// Places below when it fits, otherwise above, then clamps both axes to the
    /// screen's visible frame. Inputs and output are screen coordinates.
    static func panelFrame(
        contentSize: NSSize,
        anchor: NSRect,
        relativeTo view: NSView,
        visibleFrame: NSRect,
        zoom: AgentPageZoom = .default
    ) -> NSRect {
        guard let window = view.window else { return NSRect(origin: .zero, size: contentSize) }
        let windowAnchor = view.convert(anchor, to: nil)
        let screenAnchor = window.convertToScreen(windowAnchor)
        let gap = CGFloat(zoom.scaled(Space.s))
        let roomBelow = screenAnchor.minY - visibleFrame.minY
        let roomAbove = visibleFrame.maxY - screenAnchor.maxY
        let placeBelow = roomBelow >= contentSize.height + gap || roomBelow >= roomAbove
        var origin = NSPoint(
            x: screenAnchor.minX,
            y: placeBelow ? screenAnchor.minY - contentSize.height - gap : screenAnchor.maxY + gap
        )
        origin.x = min(max(origin.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - contentSize.width))
        origin.y = min(max(origin.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - contentSize.height))
        return NSRect(origin: origin, size: contentSize)
    }

    private static func completionContentSize(
        list: ChoiceListView,
        configuration: CompletionPopoverLayout,
        screenAnchor: NSRect,
        visibleFrame: NSRect,
        zoom: AgentPageZoom = .default
    ) -> NSSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.token(.caption, zoom: zoom)]
        let padding = CGFloat(zoom.scaled(24))
        let breadcrumbWidth = ceil((configuration.breadcrumb as NSString).size(withAttributes: attributes).width) + padding
        let footerWidth = ceil((configuration.footer as NSString).size(withAttributes: attributes).width) + padding
        let availableWidth = max(1, visibleFrame.width)
        // The caller's width band is a CONTENT bound, so it scales with the rung;
        // the screen's available width does not.
        let upperWidth = min(CGFloat(zoom.scaled(Double(configuration.maximumWidth))), availableWidth)
        let lowerWidth = min(CGFloat(zoom.scaled(Double(configuration.minimumWidth))), upperWidth)
        let width = min(upperWidth, max(lowerWidth, list.intrinsicContentSize.width, breadcrumbWidth, footerWidth))

        let visibleRows = min(max(1, configuration.maximumVisibleRows), max(1, list.items.count))
        let desiredListHeight = CGFloat(visibleRows) * ChoiceListView.rowHeight(zoom: zoom)
            + CGFloat(zoom.scaled(8))
        let desiredHeight = CompletionPopoverContentView.headerHeight(zoom: zoom)
            + desiredListHeight
            + CompletionPopoverContentView.footerHeight(zoom: zoom)
        let gap = CGFloat(zoom.scaled(Space.s))
        let roomBelow = screenAnchor.minY - visibleFrame.minY
        let roomAbove = visibleFrame.maxY - screenAnchor.maxY
        let availableHeight = max(1, max(roomBelow, roomAbove) - gap)
        return NSSize(width: width, height: min(desiredHeight, availableHeight))
    }

    private static func commandContentSize(
        list: ChoiceListView,
        configuration: CommandPopoverLayout,
        visibleFrame: NSRect,
        zoom: AgentPageZoom = .default
    ) -> NSSize {
        // The caller's width band is a CONTENT bound, so it scales with the rung;
        // the screen's available width does not.
        let width = min(
            visibleFrame.width,
            max(
                CGFloat(zoom.scaled(Double(configuration.minimumWidth))),
                min(CGFloat(zoom.scaled(Double(configuration.maximumWidth))), list.intrinsicContentSize.width)
            )
        )
        let rowHeight = list.layoutRowHeight
        let maxHeight = CGFloat(configuration.maximumVisibleRows) * rowHeight
            + ChoiceListView.verticalPadding(zoom: zoom) * 2
        let height = min(maxHeight, max(1, list.intrinsicContentSize.height))
        return NSSize(width: max(1, width), height: max(1, height))
    }

    private func installDismissalObservers(
        for window: NSWindow,
        anchor: NSView,
        takesFocus: Bool
    ) {
        let center = NotificationCenter.default
        if let resignationOwner = takesFocus ? panel : window {
            // Choice menus become key and therefore observe their panel. Passive
            // completion panels leave the editor's parent key and observe it.
            observers.append(center.addObserver(
                forName: NSWindow.didResignKeyNotification, object: resignationOwner, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.dismissAsCancellation() } })
        }
        observers.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } })
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.dismissAsCancellation() } })
        observers.append(center.addObserver(
            forName: NSView.frameDidChangeNotification, object: anchor, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.dismissAsCancellation() } })
        anchor.postsFrameChangedNotifications = true
        anchorWindowObservation = anchor.observe(\.window, options: [.old, .new]) { [weak self] _, change in
            // `window` is optional, so KVO wraps both values in a second Optional.
            let oldWindow = change.oldValue ?? nil
            let newWindow = change.newValue ?? nil
            guard oldWindow != nil, newWindow == nil else { return }
            // NSView window changes are AppKit-main-thread events.
            MainActor.assumeIsolated { self?.dismiss() }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel { self.dismissAsCancellation() }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in Task { @MainActor [weak self] in self?.dismissAsCancellation() }
        }
    }

    private func removeDismissalObservers() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        anchorWindowObservation?.invalidate()
        anchorWindowObservation = nil
        if let anchorWasPostingFrameChanges {
            anchorView?.postsFrameChangedNotifications = anchorWasPostingFrameChanges
        }
        anchorWasPostingFrameChanges = nil
    }

    var qaCompletionBreadcrumb: String? { completionContentView?.breadcrumbLabel.stringValue }
    var qaCompletionFooter: String? { completionContentView?.footerLabel.stringValue }
    var qaCompletionViewportHeight: CGFloat? { completionContentView?.scrollView.contentSize.height }
    var qaCompletionDocumentHeight: CGFloat? { completionContentView?.listView.frame.height }
}
