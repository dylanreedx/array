import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

/// The surfaces the chrome censuses walk: every surface the token census
/// already renders (`UIProbeAppearance.adoptedSurfaces` — each tile kind, the
/// managed-agent tile with its composer, sidebar, top bar, toolbar, its menu
/// and label, hover card, onboarding), plus the chrome that census does not
/// reach: the settings modal card, the ⌘K palette, the app toast, zone chrome,
/// the canvas menus (command, completion and standalone choice panels, in
/// their shadow chrome), the focused composer, and the signal badge.
@MainActor
enum ChromeCensusSurfaces {
    struct Surface {
        let id: String
        let size: NSSize
        let make: () -> NSView
        var prepare: (NSView) -> Void = { _ in }
    }

    static func all() throws -> [Surface] {
        let adopted = try UIProbeAppearance.adoptedSurfaces().map {
            Surface(id: $0.id, size: $0.size, make: $0.make, prepare: $0.prepare)
        }
        return adopted + extras()
    }

    static func menuItems() -> [ChoiceItem] {
        [
            ChoiceItem(id: "keep", title: "Keep Choosing", detail: "Return to project and Home selection"),
            ChoiceItem(id: "cancel", title: "Cancel and Delete New Zone", destructive: true),
        ]
    }

    private static func extras() -> [Surface] {
        [
            Surface(id: "settingsModal", size: NSSize(width: 960, height: 700), make: {
                SettingsOverlayView(content: NSView(frame: NSRect(x: 0, y: 0, width: 880, height: 620)))
            }),
            Surface(id: "commandPalette", size: NSSize(width: 660, height: 520), make: {
                CommandCenterSurfaceView(frame: NSRect(x: 0, y: 0, width: 660, height: 520))
            }),
            Surface(id: "toast", size: NSSize(width: 420, height: 80), make: {
                let toast = WorkspaceNotificationView(frame: NSRect(x: 0, y: 0, width: 420, height: 80))
                toast.show("The workspace changed while the picker was open; nothing was changed.", kind: .warning)
                return toast
            }),
            Surface(id: "zoneChrome", size: NSSize(width: 700, height: 220), make: {
                let placement = ZonePlacement(
                    zoneId: UUID(), projectId: UUID(), origin: ZonePoint(x: 0, y: 0),
                    size: ZoneSize(width: 700, height: 220), color: "blue", collapsed: false,
                    hydrationPolicy: .automatic, name: "Array")
                let zone = ZoneChromeNSView(placement: placement, presentation: .init(
                    title: "Array", homeLabel: "Array / Project Root", isProvisional: false,
                    agentStatusRollup: .empty, qaVerdict: nil))
                zone.frame = NSRect(x: 0, y: 0, width: 700, height: 220)
                return zone
            }),
            Surface(id: "provisionalZoneChrome", size: NSSize(width: 700, height: 220), make: {
                let placement = ZonePlacement(
                    zoneId: UUID(), projectId: nil, origin: ZonePoint(x: 0, y: 0),
                    size: ZoneSize(width: 700, height: 220), color: "green", collapsed: false,
                    hydrationPolicy: .automatic, name: "")
                let zone = ZoneChromeNSView(placement: placement, presentation: .init(
                    title: "New Zone", homeLabel: nil, isProvisional: true,
                    agentStatusRollup: .empty, qaVerdict: nil))
                zone.frame = NSRect(x: 0, y: 0, width: 700, height: 220)
                return zone
            }),
            Surface(id: "commandMenu", size: NSSize(width: 360, height: 140), make: {
                let list = ChoiceListView(
                    items: menuItems(), selectedID: "keep", presentation: .commands, chrome: .embedded)
                let content = CommandPopoverContentView(listView: list)
                let chrome = ChoicePanelShadowView(surface: content)
                chrome.frame = NSRect(x: 0, y: 0, width: 360, height: 140)
                return chrome
            }),
            Surface(id: "completionMenu", size: NSSize(width: 420, height: 260), make: {
                let items = (0..<5).map {
                    ChoiceItem(id: "f\($0)", title: "File-\($0).swift", detail: "Sources/Feature/", icon: .system("doc.text"))
                }
                let list = ChoiceListView(items: items, selectedID: nil, presentation: .completions, chrome: .embedded)
                let content = CompletionPopoverContentView(listView: list, layout: CompletionPopoverLayout(
                    breadcrumb: "Array  ›  Sources", footer: "↵ Select   Esc Close"))
                let chrome = ChoicePanelShadowView(surface: content)
                chrome.frame = NSRect(x: 0, y: 0, width: 420, height: 260)
                return chrome
            }),
            Surface(id: "choiceMenu", size: NSSize(width: 280, height: 160), make: {
                ChoiceListView(items: [
                    ChoiceItem(id: "a", title: "Balanced"),
                    ChoiceItem(id: "b", title: "Thorough", detail: "Slower, deeper"),
                ], selectedID: "a", presentation: .choices)
            }),
            Surface(id: "focusedComposer", size: NSSize(width: 480, height: 72), make: {
                AgentComposerView(frame: NSRect(x: 0, y: 0, width: 480, height: 72))
            }, prepare: { root in
                guard let composer = root as? AgentComposerView ?? firstDescendant(AgentComposerView.self, in: root) else { return }
                _ = composer.window?.makeFirstResponder(composer.textView)
                composer.applyTokens()
            }),
            Surface(id: "signalBadge", size: NSSize(width: 200, height: 120), make: {
                let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
                let badge = AgentSignalBadgeView(frame: NSRect(x: 10, y: 10, width: 80, height: 22))
                let border = AgentSignalBorderView(frame: NSRect(x: 100, y: 10, width: 90, height: 90))
                border.isHidden = false
                host.addSubview(badge)
                host.addSubview(border)
                return host
            }),
        ]
    }

    static func firstDescendant<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = firstDescendant(type, in: subview) { return match }
        }
        return nil
    }

    /// Every view in `root`'s tree, root first.
    static func views(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { views(in: $0) }
    }

    /// The layers a view answers for: its own and the sublayers it created,
    /// never a subview's (that subview answers for its own).
    static func ownedLayers(of view: NSView) -> [CALayer] {
        guard let root = view.layer else { return [] }
        let subviewLayers = Set(view.subviews.compactMap { $0.layer.map(ObjectIdentifier.init) })
        var layers: [CALayer] = []
        func visit(_ layer: CALayer) {
            layers.append(layer)
            for sublayer in layer.sublayers ?? [] where !subviewLayers.contains(ObjectIdentifier(sublayer)) {
                visit(sublayer)
            }
        }
        visit(root)
        return layers
    }

    static func ownerName(_ view: NSView) -> String { String(describing: type(of: view)) }
}

/// `--border-census-check`: no border anywhere in the app's chrome is wider
/// than THE hairline (`LineWidth.hairline`, 0.5pt).
///
/// Walks the real view trees of every census surface in both appearances and
/// reads what Core Animation will draw: every layer's `borderWidth` (with a
/// visible border colour), every stroked `CAShapeLayer`'s `lineWidth`, and
/// every custom `NSBox` border. Any value above the hairline fails, unless its
/// owner is on the exemption list below — and an exemption must say why.
@MainActor
enum BorderCensusChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Owners whose wide lines are not hairline borders. Nothing else may
    /// exceed the ceiling.
    static let exemptOwners: [String: String] = [
        "FocusBorderOverlayView": "the canvas focus ring: marching ants, user-configurable in Settings › Focus",
        "DragGhostOverlayView": "the moving highlight that previews a tile or zone destination",
        "CornerOverlayView": "resize-handle glyphs at the tile corners, not an outline",
        "AgentLineageOverlayView": "connector lines between agents, not a border",
        "DocumentRelationshipOverlayView": "connector lines between documents and agents, not a border",
        "AgentRadialContextMeterView": "a gauge's arc, a data mark rather than a border",
        "DualPlaneGyroTiltedThinkingIndicatorView": "the working throbber's guide rings, an animated glyph",
    ]

    static let ceiling = CGFloat(LineWidth.hairline)

    struct Violation: CustomStringConvertible {
        let surface: String
        let owner: String
        let what: String
        let width: CGFloat
        var description: String { "\(surface): \(owner) \(what) is \(width)pt" }
    }

    static func run() throws {
        var violations: [Violation] = []
        var measured = 0
        var exempted: Set<String> = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for surface in try ChromeCensusSurfaces.all() {
                let probe = try UIProbe.render(
                    UIProbe.Spec(id: "border.\(surface.id).\(appearance.rawValue)", size: surface.size, appearance: appearance),
                    make: surface.make)
                surface.prepare(probe.view)
                probe.host.layoutSubtreeIfNeeded()
                for view in ChromeCensusSurfaces.views(in: probe.view) {
                    let owner = ChromeCensusSurfaces.ownerName(view)
                    var lines: [(String, CGFloat)] = []
                    for layer in ChromeCensusSurfaces.ownedLayers(of: view) {
                        if layer.borderWidth > 0, (layer.borderColor?.alpha ?? 0) > 0 {
                            lines.append(("layer border", layer.borderWidth))
                        }
                        if let shape = layer as? CAShapeLayer, shape.path != nil,
                           (shape.strokeColor?.alpha ?? 0) > 0, shape.lineWidth > 0 {
                            lines.append(("stroked path", shape.lineWidth))
                        }
                    }
                    if let box = view as? NSBox, box.boxType == .custom, box.borderWidth > 0,
                       box.borderColor.alphaComponent > 0 {
                        lines.append(("box border", box.borderWidth))
                    }
                    for (what, width) in lines {
                        measured += 1
                        guard width > ceiling + 0.001 else { continue }
                        if exemptOwners[owner] != nil { exempted.insert(owner); continue }
                        // AppKit's own private views inside a native control
                        // (NSSearchField's bezel is a hosted `_NSCoreHostingView`):
                        // system control chrome, which the app keeps as AppKit draws it.
                        if owner.hasPrefix("_NS") { exempted.insert(owner); continue }
                        violations.append(Violation(surface: surface.id, owner: owner, what: what, width: width))
                    }
                }
            }
        }
        guard measured >= 40 else {
            throw Failure(description: "measured only \(measured) lines across the census surfaces — the walk stopped reaching the chrome")
        }
        guard violations.isEmpty else {
            let unique = Array(Set(violations.map(\.description))).sorted()
            throw Failure(description: "\(unique.count) border(s) exceed the \(ceiling)pt hairline:\n  " + unique.joined(separator: "\n  "))
        }
        print("border census: \(measured) lines measured, none above \(ceiling)pt; exempt owners seen: \(exempted.sorted())")
    }
}
