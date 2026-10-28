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
/// than THE hairline (`LineWidth.hairline`, 1pt).
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
        try checkToastMatchesPopoverStyle()
        print("border census: \(measured) lines measured, none above \(ceiling)pt; exempt owners seen: \(exempted.sorted())")
    }

    /// The app toast reads like the app's other floating surfaces (the canvas
    /// menus, the hover card): a hairline in the quiet decorative line token,
    /// with a soft shadow doing the separating — not a 1pt `LineToken.border`
    /// frame, which is the strongest grey in the line palette.
    private static func checkToastMatchesPopoverStyle() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let theme: TokenTheme = appearance == .darkAqua ? .dark : .light
            let probe = try UIProbe.render(
                UIProbe.Spec(id: "border.toastStyle.\(appearance.rawValue)", size: NSSize(width: 420, height: 80), appearance: appearance),
                make: {
                    let toast = WorkspaceNotificationView(frame: NSRect(x: 0, y: 0, width: 420, height: 80))
                    toast.show("Couldn't determine the active workspace.", kind: .error)
                    return toast
                })
            guard let toast = ChromeCensusSurfaces.firstDescendant(WorkspaceNotificationView.self, in: probe.view),
                  let layer = toast.layer else {
                throw Failure(description: "toast: the notification view did not render")
            }
            let expected = AgentLineRole.decorativeHairline.color.cgColor(for: theme)
            guard layer.borderWidth > 0, layer.borderWidth <= ceiling,
                  let border = layer.borderColor, border == expected else {
                throw Failure(description: "toast (\(appearance.rawValue)): border \(layer.borderWidth)pt in \(String(describing: layer.borderColor)), want a ≤\(ceiling)pt decorativeHairline")
            }
            guard layer.shadowOpacity > 0, !layer.masksToBounds else {
                throw Failure(description: "toast (\(appearance.rawValue)): no soft shadow (opacity \(layer.shadowOpacity), masksToBounds \(layer.masksToBounds))")
            }
        }
    }
}

/// `--corner-style-check`: Settings › Appearance › Corner style reaches every
/// rounded surface, live.
///
/// Renders every census surface at Default and records every radius Core
/// Animation will draw: each layer's `cornerRadius`, each stroked or filled
/// rounded-rect `CAShapeLayer` path, each `shadowPath` (paths are MEASURED,
/// see `PathCornerRadius`). Then it switches the style through the production
/// controller — with the views already on screen — and re-reads them:
///  * Sharp: every one of them is 0, pills included;
///  * Rounded: each is `CornerStyle.rounded.radius(default)`, a capsule stays
///    a capsule (or the radius is clamped to half the shorter side);
///  * back to Default: each is exactly what it was.
/// A surface that still draws its Default radius after a switch is either not
/// routed through `CornerRole` or only sets its radius once, at init.
/// Separately: the marching ants follow the tile radius (concentric at their
/// gap, square at Sharp), and the zone's moving highlight draws the zone's
/// own radius.
@MainActor
enum CornerStyleChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Owners whose rounded shapes are glyphs, not corners: a status dot, a
    /// throbber orbit, a gauge. They keep their geometry in every style.
    static let exemptOwners: [String: String] = [
        "DualPlaneGyroTiltedThinkingIndicatorView": "the working throbber's rings and orbit, an animated glyph",
        "AgentRadialContextMeterView": "a gauge's circular track",
        "CornerOverlayView": "the tile's resize-handle brackets: right-angle glyphs with no corner to round",
        "NSTableRowView": "a native table row's selection, drawn by AppKit in its own inset style",
    ]

    /// The same exemption for a glyph that is a sublayer of a view that owns
    /// other chrome: the canvas transcript draws the working throbber as a
    /// layer, not as the exempt `DualPlaneGyroTiltedThinkingIndicatorView`.
    static let exemptLayers: [String: String] = [
        "AgentTranscriptCanvasGyroLayer": "the canvas transcript's working throbber: the same rings and orbit as DualPlaneGyroTiltedThinkingIndicatorView",
    ]

    private static func isExemptGlyph(_ layer: CALayer) -> Bool {
        var current: CALayer? = layer
        while let candidate = current {
            if exemptLayers[String(describing: type(of: candidate))] != nil { return true }
            current = candidate.superlayer
        }
        return false
    }

    /// `drawn`: a surface a `DrawnCornerReporting` view filled or stroked in
    /// `draw(_:)`, measured from the path it drew.
    private enum Kind: String { case corner, path, shadowPath, drawn }

    /// One radius, found by WHERE it is rather than by object identity: a
    /// re-render may rebuild a view (a transcript row, a table cell), and the
    /// replacement at the same place must follow the style just the same.
    @MainActor
    private struct Sample {
        let surface: String
        let root: NSView
        let owner: String
        let ordinal: Int
        let layerIndex: Int
        let kind: Kind
        let standard: CGFloat
        weak var view: NSView?
        /// For `.drawn`: where the surface is, in the view's drawn record.
        var drawnKey: String? = nil

        var label: String { "\(surface): \(owner) \(kind.rawValue)" }

        func currentHost() -> NSView? {
            var host = view
            if host?.window == nil {
                host = ChromeCensusSurfaces.views(in: root).filter { CornerStyleChecks.label($0) == owner }
                    .dropFirst(ordinal).first
            }
            return host
        }

        func currentLayer() -> CALayer? {
            guard let host = currentHost() else { return nil }
            let layers = ChromeCensusSurfaces.ownedLayers(of: host)
            return layerIndex < layers.count ? layers[layerIndex] : nil
        }

        func read() -> (radius: CGFloat, half: CGFloat)? {
            if kind == .drawn {
                guard let reporter = currentHost() as? DrawnCornerReporting else { return nil }
                // A full draw, now, in the style just applied.
                reporter.display()
                guard let path = reporter.qaDrawnCorners.first(where: { $0.key == drawnKey })?.path,
                      let radius = PathCornerRadius.measure(path) else { return nil }
                return (radius, min(path.boundingBoxOfPath.width, path.boundingBoxOfPath.height) / 2)
            }
            guard let layer = currentLayer() else { return nil }
            switch kind {
            case .drawn:
                return nil
            case .corner:
                return (layer.cornerRadius, min(layer.bounds.width, layer.bounds.height) / 2)
            case .path:
                guard let path = (layer as? CAShapeLayer)?.path, let radius = PathCornerRadius.measure(path) else { return nil }
                return (radius, min(path.boundingBoxOfPath.width, path.boundingBoxOfPath.height) / 2)
            case .shadowPath:
                guard let path = layer.shadowPath, let radius = PathCornerRadius.measure(path) else { return nil }
                return (radius, min(path.boundingBoxOfPath.width, path.boundingBoxOfPath.height) / 2)
            }
        }
    }

    static func run() throws {
        CornerStyleController.apply(.standard)
        DrawnCornerCensus.isRecording = true
        defer {
            CornerStyleController.apply(.standard)
            DrawnCornerCensus.isRecording = false
        }

        var probes: [UIProbe.Probed] = []
        var samples: [Sample] = []
        let surfaces = try ChromeCensusSurfaces.all() + overlaySurfaces()
        for surface in surfaces {
            let probe = try UIProbe.render(
                UIProbe.Spec(id: "corner.\(surface.id)", size: surface.size, appearance: .darkAqua),
                make: surface.make)
            surface.prepare(probe.view)
            probe.host.layoutSubtreeIfNeeded()
            probes.append(probe)
            samples += collect(surface: surface.id, root: probe.view)
        }
        CornerStyleController.apply(.standard)
        for (probe, surface) in zip(probes, surfaces) {
            probe.host.layoutSubtreeIfNeeded()
            probe.host.displayIfNeeded()
            samples += collectDrawn(surface: surface.id, root: probe.view)
        }
        guard samples.count >= 60 else {
            throw Failure(description: "found only \(samples.count) rounded corners across \(surfaces.count) surfaces — the census stopped reaching the chrome")
        }

        var failures: [String] = []
        for style in [CornerStyle.sharp, .rounded, .standard] {
            let visited = CornerStyleController.apply(style)
            for probe in probes { probe.host.layoutSubtreeIfNeeded(); probe.host.displayIfNeeded() }
            guard visited > samples.count / 4 else {
                throw Failure(description: "switching to \(style.title) reached only \(visited) views — the live walk does not reach the windows on screen")
            }
            for sample in samples {
                guard let now = sample.read() else {
                    failures.append("[\(style.title)] \(sample.label) lost its rounded shape (was \(sample.standard))")
                    continue
                }
                if let problem = verdict(style: style, standard: sample.standard, now: now.radius, half: now.half) {
                    failures.append("[\(style.title)] \(sample.label): \(problem)")
                }
            }
            try checkHighlights(style: style, failures: &failures)
        }
        guard failures.isEmpty else {
            let unique = Array(Set(failures)).sorted()
            throw Failure(description: "\(unique.count) corner(s) ignore the corner style:\n  " + unique.prefix(80).joined(separator: "\n  ")
                + (unique.count > 80 ? "\n  … and \(unique.count - 80) more" : ""))
        }
        try checkSettingDrivesTheStyle(probes: probes)
        print("corner style census: \(samples.count) corners over \(surfaces.count) surfaces follow Sharp, Rounded and Default live; Settings › Appearance › Corner style drives it")
    }

    /// The setting itself: Appearance carries a three-way Corner style row
    /// (Default by default) that search finds by its words, and choosing a
    /// value through the Settings write path re-renders the open windows.
    private static func checkSettingDrivesTheStyle(probes: [UIProbe.Probed]) throws {
        let suite = "array.cornerStyle.check.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw Failure(description: "could not create isolated settings defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let observer = CornerStyleController.observeSetting(defaults: defaults)
        defer { NotificationCenter.default.removeObserver(observer) }

        let model = SettingsModel(defaults: defaults, navKeymap: .default)
        guard let appearance = model.sections.first(where: { $0.id == "appearance" }),
              let row = appearance.groups.flatMap(\.rows).first(where: { $0.field.key == CornerStyle.defaultsKey }),
              case let .choice(_, label, options, defaultValue, _) = row.field else {
            throw Failure(description: "Settings › Appearance has no Corner style row")
        }
        guard label == "Corner style", options == ["sharp", "default", "rounded"], defaultValue == "default",
              CornerStyle.resolve(defaults.string(forKey: CornerStyle.defaultsKey)) == .standard else {
            throw Failure(description: "Corner style row is \(label) \(options) default \(defaultValue); want Sharp / Default / Rounded defaulting to Default")
        }
        for word in ["corners", "radius", "rounded", "sharp", "square", "bubbly"] {
            model.searchQuery = word
            guard model.searchResults.contains(where: { $0.entry.label == "Corner style" }) else {
                throw Failure(description: "searching Settings for \"\(word)\" does not find Corner style")
            }
        }
        model.searchQuery = ""

        // A tile already on screen, re-read after the write.
        guard let tile = probes.lazy.compactMap({ ChromeCensusSurfaces.firstDescendant(TileNSView.self, in: $0.view) }).first,
              let layer = tile.layer else {
            throw Failure(description: "no tile on screen to watch for the setting")
        }
        for (raw, want) in [("sharp", CGFloat(0)), ("rounded", CornerRole.tile.cgRadius() == 0 ? 0 : CGFloat(CornerStyle.rounded.radius(CornerRole.tile.base))), ("default", CGFloat(CornerRole.tile.base))] {
            model.binding(for: row.field).set(.string(raw))
            guard CornerStyle.current == CornerStyle.resolve(raw), abs(layer.cornerRadius - want) < 0.05 else {
                throw Failure(description: "choosing \(raw) in Settings left the style \(CornerStyle.current.title) and an on-screen tile at \(layer.cornerRadius), want \(want)")
            }
        }
    }

    private static func verdict(style: CornerStyle, standard: CGFloat, now: CGFloat, half: CGFloat) -> String? {
        let capsule = half > 0 && standard >= half - 0.5
        switch style {
        case .sharp:
            return now < 0.05 ? nil : "draws \(now), want 0"
        case .standard:
            return abs(now - standard) < 0.05 ? nil : "draws \(now), want its Default \(standard)"
        case .rounded:
            if capsule { return now >= half - 0.5 ? nil : "draws \(now), want a capsule (\(half))" }
            let want = CGFloat(CornerStyle.rounded.radius(Double(standard)))
            if abs(now - want) < 0.6 { return nil }
            // Clamped to half the shorter side, never below the Default.
            if want > half, now >= max(standard, half) - 0.5, now <= half + 0.5 { return nil }
            return "draws \(now), want \(want) (Default \(standard))"
        }
    }

    /// A plain AppKit view (an `NSView` card, an `NSVisualEffectView`) is named
    /// for the nearest app-owned ancestor, so `SettingsOverlayView.NSView` is
    /// the settings card rather than an anonymous view.
    fileprivate static func label(_ view: NSView) -> String {
        let own = ChromeCensusSurfaces.ownerName(view)
        guard own.hasPrefix("NS") else { return own }
        var ancestor = view.superview
        while let current = ancestor {
            let name = ChromeCensusSurfaces.ownerName(current)
            if !name.hasPrefix("NS"), !name.hasPrefix("_NS") { return "\(name).\(own)" }
            ancestor = current.superview
        }
        return own
    }

    /// The surfaces `DrawnCornerReporting` views drew at Default, sampled once
    /// every surface has been built and laid out: a drawn surface exists only
    /// while it is in view, so it is sampled from the settled tile, not the one
    /// still taking its first content.
    private static func collectDrawn(surface: String, root: NSView) -> [Sample] {
        var samples: [Sample] = []
        var ordinals: [String: Int] = [:]
        for view in ChromeCensusSurfaces.views(in: root) {
            let owner = label(view)
            let ordinal = ordinals[owner, default: 0]
            ordinals[owner] = ordinal + 1
            guard let reporter = view as? DrawnCornerReporting, reporter.window != nil, !reporter.bounds.isEmpty else { continue }
            reporter.flushPendingVisualUpdate()
            reporter.display()
            for corner in reporter.qaDrawnCorners {
                guard let radius = PathCornerRadius.measure(corner.path), radius > 0.5 else { continue }
                var sample = Sample(surface: surface, root: root, owner: owner, ordinal: ordinal,
                                    layerIndex: -1, kind: .drawn, standard: radius, view: view)
                sample.drawnKey = corner.key
                samples.append(sample)
            }
        }
        return samples
    }

    private static func collect(surface: String, root: NSView) -> [Sample] {
        var samples: [Sample] = []
        var ordinals: [String: Int] = [:]
        for view in ChromeCensusSurfaces.views(in: root) {
            let raw = ChromeCensusSurfaces.ownerName(view)
            let owner = label(view)
            let ordinal = ordinals[owner, default: 0]
            ordinals[owner] = ordinal + 1
            // AppKit's private internals of native controls keep the system's shape.
            guard !raw.hasPrefix("_NS"), exemptOwners[raw] == nil else { continue }
            for (index, layer) in ChromeCensusSurfaces.ownedLayers(of: view).enumerated() {
                // A layer with no size draws no corner.
                guard layer.bounds.width > 0, layer.bounds.height > 0 else { continue }
                // A glyph's circles are not corners (`exemptLayers`).
                guard !isExemptGlyph(layer) else { continue }
                func add(_ kind: Kind, _ radius: CGFloat) {
                    samples.append(Sample(surface: surface, root: root, owner: owner, ordinal: ordinal,
                                          layerIndex: index, kind: kind, standard: radius, view: view))
                }
                if layer.cornerRadius > 0.05 { add(.corner, layer.cornerRadius) }
                if let shape = layer as? CAShapeLayer, let path = shape.path,
                   let radius = PathCornerRadius.measure(path), radius > 0.5 {
                    add(.path, radius)
                }
                if let shadow = layer.shadowPath, let radius = PathCornerRadius.measure(shadow), radius > 0.5 {
                    add(.shadowPath, radius)
                }
            }
        }
        return samples
    }

    // MARK: - The canvas highlights

    private static let antsGap: CGFloat = 4

    private static func overlaySurfaces() -> [ChromeCensusSurfaces.Surface] {
        [
            ChromeCensusSurfaces.Surface(id: "zoneMovingHighlight", size: NSSize(width: 700, height: 480), make: {
                let canvas = CanvasNSView(canvasState: CanvasState(
                    viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
                canvas.frame = NSRect(x: 0, y: 0, width: 700, height: 480)
                return canvas
            }, prepare: { root in
                guard let canvas = ChromeCensusSurfaces.firstDescendant(CanvasNSView.self, in: root) else { return }
                canvas.showDragGhost(at: TileFrame(x: 60, y: 60, width: 420, height: 260), label: "New Zone", detail: nil, role: .zone)
            }),
        ]
    }

    /// The marching ants and the zone's moving highlight, measured against the
    /// surfaces they outline.
    private static func checkHighlights(style: CornerStyle, failures: inout [String]) throws {
        // Marching ants: concentric with the tile at their gap; square at Sharp.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let ants = FocusBorderOverlayView(frame: .zero)
        host.addSubview(ants)
        ants.configure(color: .systemBlue, gap: antsGap, animationDuration: 1)
        ants.show(around: CGRect(x: 40, y: 40, width: 300, height: 200), tileScale: 1)
        ants.layoutSubtreeIfNeeded()
        let antsPath = ants.qaShapePath.flatMap(PathCornerRadius.measure)
        let antsWant: CGFloat = style == .sharp ? 0 : CornerRole.tile.cgRadius() + antsGap
        if let antsPath, abs(antsPath - antsWant) < 0.6 {} else {
            failures.append("[\(style.title)] marching ants draw radius \(String(describing: antsPath)), want \(antsWant) (tile \(CornerRole.tile.cgRadius()) + gap \(antsGap))")
        }

        // The zone's moving highlight draws the zone's radius, and so does the
        // zone's own outline.
        let canvas = CanvasNSView(canvasState: CanvasState(
            viewport: CanvasViewport(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
        canvas.frame = NSRect(x: 0, y: 0, width: 700, height: 480)
        canvas.showDragGhost(at: TileFrame(x: 60, y: 60, width: 420, height: 260), label: "New Zone", detail: nil, role: .zone)
        let ghost = canvas.qaDragGhostCornerRadius
        let zoneWant = CornerRole.zone.cgRadius()
        if let ghost, abs(ghost - zoneWant) < 0.05 {} else {
            failures.append("[\(style.title)] the zone's moving highlight draws \(String(describing: ghost)), want the zone radius \(zoneWant)")
        }
        let placement = ZonePlacement(
            zoneId: UUID(), projectId: UUID(), origin: ZonePoint(x: 0, y: 0),
            size: ZoneSize(width: 600, height: 300), color: "blue", collapsed: false,
            hydrationPolicy: .automatic, name: "Array")
        let zone = ZoneChromeNSView(placement: placement, presentation: .init(
            title: "Array", homeLabel: nil, isProvisional: false, agentStatusRollup: .empty, qaVerdict: nil))
        zone.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        zone.layoutSubtreeIfNeeded()
        let outline = zone.qaOutlinePath.flatMap(PathCornerRadius.measure)
        if let outline, abs(outline - zoneWant) < 0.6 {} else {
            failures.append("[\(style.title)] the zone outline draws \(String(describing: outline)), want the zone radius \(zoneWant)")
        }
    }
}
