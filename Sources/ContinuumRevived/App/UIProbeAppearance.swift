import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import ContinuumRevivedFileTree

// Ticket: docs/38-tickets/90-agent-ux/P1.9-live-appearance-switching.md
//
// The live-appearance gate, run inside `--ui-probe-check` (it asserts nothing
// about colour VALUES — that is `--ui-contrast-check`'s job — so it belongs to
// the probe's own "the harness and the views do what they claim" leg rather than
// to a leg of its own).
//
// Four things are asserted, in ascending strength:
//
//  1 · Sentinel sweep over the REAL tree. Every layer colour a `TokenThemed` view
//      owns is overwritten with magenta, the appearance is then flipped for real
//      (window + NSApp), and any surviving sentinel is a failure. A sentinel can
//      only survive if that colour was assigned somewhere other than
//      `applyTokens()` — which is precisely the stale-CGColor bug. The set of views
//      swept is checked against the conformances declared in the source, so a new
//      `TokenThemed` view that this gate does not render is a failure, not a hole.
//  2 · Real re-resolution. The sidebar and the top bar paint a system colour
//      through `appResolvedCGColor`, so their resolved fill MUST differ between
//      the two appearances. Before this ticket they were assigned once at `init`
//      and never moved again — this is the assertion that was failing silently.
//  3 · Token fixture + regression witness. A `TokenThemed` fixture painting
//      `DesignTokens` must hold the exact light leaf under Aqua and the exact dark
//      leaf after the flip; an otherwise identical fixture that snapshots its
//      `.cgColor` in `init` (the pre-ticket pattern) must FAIL the same assertion.
//      The witness runs every time rather than living in a comment.
//  4 · Token VALUES over the real tree (P1.10, widened by P1.11 to every adopted
//      surface and to the AppKit colour properties that are not layer colours).
//  5 · The Goal, as a number (P1.11): the rendered tile's outline measured against
//      the rendered canvas in both appearances, with the 1.68:1 defect as a witness.
//  5b· The descriptor tile's eleven retired fills — the ticket's one deviation, with
//      its evidence pinned rather than argued in prose.
//  6 · The title bar's status pill clears the drag handle AND the tile title, driven
//      through a real canvas at real viewport zooms.
@MainActor
enum UIProbeAppearance {
    struct AppearanceError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
        var localizedDescription: String { message }
    }

    private static func fail(_ message: String) -> AppearanceError { AppearanceError(message: message) }

    /// Magenta: not a colour any surface in this app paints, so a survivor is
    /// unambiguous. Constructed raw on purpose — this file is a witness surface
    /// (excluded from `check-color-hygiene.sh` by path, with the Lab and the other
    /// probes).
    private static let sentinel = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).cgColor

    // MARK: - Layer colour slots

    /// One assignable colour on one layer.
    struct ColorSlot {
        enum Kind: String { case background, border, stroke, fill }

        let ownerLabel: String
        let layer: CALayer
        let kind: Kind

        var label: String { "\(ownerLabel).\(kind.rawValue)" }

        var color: CGColor? {
            switch kind {
            case .background: return layer.backgroundColor
            case .border: return layer.borderColor
            case .stroke: return (layer as? CAShapeLayer)?.strokeColor
            case .fill: return (layer as? CAShapeLayer)?.fillColor
            }
        }

        func write(_ color: CGColor) {
            switch kind {
            case .background: layer.backgroundColor = color
            case .border: layer.borderColor = color
            case .stroke: (layer as? CAShapeLayer)?.strokeColor = color
            case .fill: (layer as? CAShapeLayer)?.fillColor = color
            }
        }
    }

    /// The layers a view is answerable for: its own, plus sublayers it created
    /// itself (a `CAShapeLayer` bracket), but never a subview's layer — that
    /// subview answers for its own colours, and sentinelling an AppKit control's
    /// internal layer would fail for a reason that is not this ticket's.
    private static func ownedLayers(of view: NSView) -> [CALayer] {
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

    /// Only slots the view actually PAINTS. Two AppKit/Core Animation facts decide
    /// this, and getting them wrong made the first run of this gate fail on seven
    /// colours no user can see:
    ///  * `CALayer.backgroundColor` defaults to `nil`, so non-nil really does mean
    ///    "somebody assigned a fill".
    ///  * `CALayer.borderColor` defaults to opaque BLACK, not nil — every layer in
    ///    the tree looks like it has a border colour. `borderWidth > 0` is what
    ///    separates a painted outline from the default (the same rule
    ///    `UIProbePixels` uses to decide a border is real).
    private static func ownedColorSlots(of view: NSView) -> [ColorSlot] {
        let label = describe(view)
        return ownedLayers(of: view).flatMap { layer -> [ColorSlot] in
            ColorSlot.Kind.allKinds.compactMap { kind in
                if kind == .border, layer.borderWidth <= 0 { return nil }
                let slot = ColorSlot(ownerLabel: label, layer: layer, kind: kind)
                return slot.color == nil ? nil : slot
            }
        }
    }

    private static func tokenThemedViews(in root: NSView) -> [NSView] {
        var found: [NSView] = []
        func visit(_ view: NSView) {
            if view is TokenThemed { found.append(view) }
            view.subviews.forEach(visit)
        }
        visit(root)
        return found
    }

    private static func describe(_ view: NSView) -> String {
        let name = String(describing: type(of: view))
        guard let identifier = view.identifier?.rawValue, !identifier.isEmpty else { return name }
        return "\(name)#\(identifier)"
    }

    private static func firstDescendant<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let match = firstDescendant(type, in: subview) { return match }
        }
        return nil
    }

    private static func hex(_ color: CGColor?) -> String {
        guard let color, let srgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return "nil" }
        func component(_ value: CGFloat) -> String { String(format: "%02X", Int((min(max(value, 0), 1) * 255).rounded())) }
        return "#" + component(srgb.redComponent) + component(srgb.greenComponent)
            + component(srgb.blueComponent) + component(srgb.alphaComponent)
    }

    // MARK: - Flipping a live probe

    /// Moves a rendered probe to `name` the way the system does: `NSApp` first
    /// (`appResolvedCGColor` resolves against `NSApp.effectiveAppearance`, so a
    /// window-only flip would re-apply the OLD colour and this gate would pass on a
    /// broken app), then the window, which is what makes AppKit deliver
    /// `viewDidChangeEffectiveAppearance` to the view and every descendant.
    private static func flip(_ probe: UIProbe.Probed, to name: NSAppearance.Name) throws {
        guard let appearance = NSAppearance(named: name) else {
            throw fail("no NSAppearance named '\(name.rawValue)'")
        }
        NSApp?.appearance = appearance
        probe.window.appearance = appearance
        probe.host.layoutSubtreeIfNeeded()
        guard probe.view.effectiveAppearance.name == name else {
            throw fail("\(probe.spec.id): flip to '\(name.rawValue)' did not take — effectiveAppearance is '\(probe.view.effectiveAppearance.name.rawValue)'")
        }
    }

    /// Restores the app-level pin production uses, so this gate cannot leak an
    /// appearance into the checks that run after it.
    private static func restoreAppPin() {
        NSApp?.appearance = NSAppearance(named: .darkAqua)
    }

    // MARK: - 1 + 2 · The real tree

    /// Measured on the tree this renders, and printed every run: 10 conforming views
    /// (the tile, its title bar, its corner overlay, 3 transcript cards, the approval
    /// dock and the user-input card — both `TokenThemed` since P1.10 — plus the
    /// sidebar and the top bar) owning 26 painted layer colours, of which 3 are the
    /// tile's own backdrop subviews (see `extraSlots`). Floors rather than
    /// equalities, so a new themed view or an extra card is not a failure — but a
    /// view or a whole surface silently dropping out of the sweep is.
    /// 12 / 25 since P2C.4 added `BranchChipNSView` (its fill and its outline).
    /// 27 / 53 since P3.6 made the sidebar's content the agent inbox: the list
    /// itself plus one `AgentInboxCardView` per row, on two surfaces (the sidebar
    /// and the dedicated `appearance.agentInbox`), each card owning a fill and an
    /// outline. Floored AT the measured number, the program's convention: growth
    /// passes, shrinkage is the signal.
    ///
    /// 156 / 141 — RE-MEASURED in queue 94's P1.1–P1.4, which is the packet that
    /// moved both numbers and the one change they are measured in.
    ///
    /// VIEWS 27 → 156. The 27 was measured at P3.6 and never re-floored while the
    /// swept tree grew, so it had drifted to a floor no regression could reach
    /// (the sweep was already covering 127). P1.4 adds one `InboxRowFocusRingView`
    /// per row card — 29 across the four inbox surfaces — taking the honest
    /// measurement to 156. Re-floored AT it, which is what the convention above
    /// says and what the drift had quietly stopped doing.
    ///
    /// SLOTS 53 → 141, and this one went DOWN from the 169 that was really being
    /// swept, for exactly the reason the packet exists. `ownedColorSlots` drops a
    /// border slot at zero width and a fill slot at `nil`, and after P1.1/P1.2 a
    /// row at rest has both: no perimeter in any state, and no fill until you
    /// point at it, select it, or open its tile. So each of the 29 cards gave up
    /// 2 slots (fill + outline) and gave back 1 focus-ring outline, and the one
    /// SELECTED card in `appearance.agentInbox` keeps its ladder fill:
    /// 169 − 58 + 29 + 1 = 141. A floor left at 169 would have turned this correct
    /// change red for the wrong reason; a floor left at 53 would have stopped
    /// measuring anything at all.
    private static let minimumThemedViews = 156
    private static let minimumSentineledSlots = 141

    /// P1.10: the tile paints three plain `NSView` container fills, which
    /// `ownedLayers(of:)` cannot attribute to it (a view never answers for a
    /// subview's layer) and which no `TokenThemed` view of their own covers. The
    /// tile hands them over so the three surfaces it just adopted are swept rather
    /// than sitting in that blind spot.
    private static func extraSlots(in root: NSView) -> [ColorSlot] {
        var slots: [ColorSlot] = []
        if let tile = firstDescendant(ManagedAgentTileNSView.self, in: root) {
            slots += tile.qaTokenPaintedLayers.map {
                ColorSlot(ownerLabel: "ManagedAgentTileNSView.\($0.label)", layer: $0.layer, kind: .background)
            }
        }
        // P1.11: same blind spot, same hand-off — the descriptor tile's body is a
        // plain `NSView` it fills itself.
        if let tile = firstDescendant(DescriptorTileNSView.self, in: root) {
            slots += tile.qaTokenPaintedLayers.map {
                ColorSlot(ownerLabel: "DescriptorTileNSView.\($0.label)", layer: $0.layer, kind: .background)
            }
        }
        return slots
    }

    /// A user-input card only exists once the agent asks a question, and the Lab
    /// fixture's canned events do not include one — so the sweep asks for it. Since
    /// P1.10 the card is `TokenThemed`, and `declaredConformers()` would otherwise
    /// report it as declared-but-never-swept.
    private static func openUserInputRequest(in root: NSView) {
        guard let tile = firstDescendant(ManagedAgentTileNSView.self, in: root) else { return }
        tile.ingest(.userInputRequested(
            threadId: tile.wiringThreadId, requestId: "appearance-input",
            questions: [UserInputQuestion(key: "filename", prompt: "Which migration name should I use?")]
        ))
        tile.layoutSubtreeIfNeeded()
    }

    private static func runProductionSweep() throws -> (views: Int, slots: Int, changed: Int) {
        let entries = LabCatalog.entries(env: LabEnvironment(ghostty: nil, browserEngine: nil))
        guard let entry = entries.first(where: { $0.id == "tiles.managedAgent" }),
              case let .staticCard(_, makeTile) = entry.content else {
            throw fail("missing tiles.managedAgent card")
        }

        // The managed-agent tile carries the Canvas conformers; the two chrome views
        // are constructed directly (both are `init(frame:)`, no store needed) so the
        // App-layer half of the ticket is covered by the same sweep.
        let surfaces: [(id: String, size: NSSize, make: () -> NSView)] = [
            ("appearance.managedAgentTile", NSSize(width: 640, height: 560), makeTile),
            // P3.8: 520 plus the scope control. The popup took that much off the top of
            // the list, which cost this surface one rendered `AgentInboxCardView` and
            // took the sweep under its own floor. The room is given back rather than
            // the floor lowered — the floor is measuring how many themed views the
            // sweep covers, and the answer must not fall because the control above
            // the list grew.
            ("appearance.sidebar", NSSize(width: 280, height: 520 + AgentInboxView.scopeControlHeight), {
                let view = WorkspaceSidebarView(frame: .zero)
                view.reloadInbox(rows: LabFixtures.inboxRows())
                return view
            }),
            ("appearance.topBar", NSSize(width: 900, height: 44), { WorkspaceTopBarView(frame: .zero) }),
            // P1.11 made the canvas a `TokenThemed` conformer, so `declaredConformers()`
            // requires it here — and the canvas fill is the background half of the
            // `borderStrong`-on-`canvas` pair this ticket's Goal names.
            // P3.6: the inbox and its row cards. Rows are fed here rather than
            // relying on the sidebar surface above, because an EMPTY list owns no
            // row views — `AgentInboxRowView` would be a declared conformer this
            // sweep never renders, which `declaredConformers()` is right to reject.
            ("appearance.agentInbox", NSSize(width: 320, height: 620 + AgentInboxView.scopeControlHeight), {
                LabCatalog.makeAgentInboxPreview(selecting: LabFixtures.inboxAgentIds[1])
            }),
            // Ticket: docs/38-tickets/90-agent-ux/P4.7-snoozed-shelf.md
            // The shelf's heading, which exists only while something is snoozed —
            // hence the parked fixture, and hence a surface of its own rather than
            // parked rows pushed into `appearance.agentInbox` above, whose row set
            // the floors here are measured on.
            ("appearance.agentInboxShelf", NSSize(width: 320, height: 620 + AgentInboxView.scopeControlHeight), {
                LabCatalog.makeAgentInboxPreview(selecting: nil, rows: LabFixtures.inboxParkedRows())
            }),
            // Ticket: docs/38-tickets/90-agent-ux/P4.8-settled-tail-paging.md
            // The tail's footer, which exists only while history is longer than a
            // page — hence a twelve-row settled fixture, and hence a surface of its
            // own for the reason the shelf above has one: the row sets the two
            // floors are measured on must not change to make room for it.
            ("appearance.agentInboxSettledTail", NSSize(width: 320, height: 620 + AgentInboxView.scopeControlHeight), {
                LabCatalog.makeAgentInboxPreview(selecting: nil, rows: LabFixtures.inboxPagedRows())
            }),
            // Program 96's hover card. Rendered standalone rather than through a
            // hovered sidebar, because hover is a live pointer state a static
            // sweep cannot hold — and what this sweep is for is the card's own two
            // layers resolving in both appearances, which it paints from its
            // content alone. The fixture carries a mismatch line deliberately, so
            // the warning accent is painted here too and not only in theory.
            ("appearance.inboxHoverCard", NSSize(width: 360, height: 220), {
                let card = InboxHoverCardView(frame: .zero)
                card.apply(
                    title: "Stop the camera resizing every tile view",
                    lines: [
                        .init(symbol: "folder", text: "Array"),
                        .init(symbol: "square.grid.2x2", text: "Sidebar"),
                        .init(symbol: "desktopcomputer", text: "This Mac"),
                        .init(symbol: "arrow.triangle.branch", text: "agent/retained-world-plane"),
                        .init(symbol: "exclamationmark.triangle.fill",
                              text: "Checked out on main", isWarning: true),
                        .init(symbol: "terminal", text: "Claude Code"),
                        .init(symbol: "cpu", text: "openai-codex/gpt-5.6-sol"),
                    ])
                return card
            }),
            ("appearance.canvas", NSSize(width: 700, height: 480), {
                CanvasNSView(canvasState: CanvasState(
                    viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                    tiles: [], groups: [], lastActiveTileId: nil))
            }),
            // P4.1: isolated until tile integration. It still belongs in the live
            // appearance sweep so its custom fill/focus boundary cannot retain a
            // stale light- or dark-theme CGColor.
            ("appearance.agentComposer", NSSize(width: 480, height: 72), {
                AgentComposerView(frame: NSRect(x: 0, y: 0, width: 480, height: 72))
            }),
            // Last-wave image rail remains isolated until production composer
            // wiring, but its token-owned chrome must already survive a live
            // appearance flip.
            ("appearance.composerImageRail", NSSize(width: 420, height: ComposerImageAttachmentRailView.railHeight), {
                ComposerImageAttachmentRailView(
                    frame: NSRect(x: 0, y: 0, width: 420, height: ComposerImageAttachmentRailView.railHeight)
                )
            }),
            // 91/P4.6: isolated until P5.2/P5.4 bind actions and the live tile.
            // Sweep the real custom control now so every token-owned layer color
            // must be reapplied across an effective-appearance flip.
            ("appearance.composerActionButton", NSSize(width: 112, height: 32), {
                ComposerActionButton(presentation: .resolve(
                    state: .ready,
                    capabilities: AgentComposerPresentedCapabilities(
                        canSend: true, canStop: true, canSteer: false, canQueue: false
                    ),
                    hasDraft: true
                ))
            }),
            // 91/P5.1: the v2 header shell stays behind its fixture flag until
            // P5.5 acceptance, so the live tile surfaces above never contain it.
            // Render the real header (working state, so the status dot paints)
            // with its private overflow control so neither conformer can retain
            // a stale token CGColor meanwhile.
            ("appearance.agentTileHeader", NSSize(width: 420, height: 56), {
                let header = AgentTileHeaderView(frame: NSRect(x: 0, y: 0, width: 420, height: 56))
                header.apply(AgentTileStatePresenter.present(
                    name: "sol-implementer",
                    status: .working,
                    branchContext: nil,
                    startedAt: Date(timeIntervalSince1970: 100),
                    now: Date(timeIntervalSince1970: 165)
                ))
                return header
            }),
            // Last-wave compact status row: isolated until coordinator wires the
            // production tile. The row and radial meter are TokenThemed, so they
            // must participate in the stale-CGColor sentinel sweep now.
            ("appearance.compactStatusRow", NSSize(width: 420, height: AgentCompactStatusRowView.preferredHeight), {
                let now = Date(timeIntervalSince1970: 1_000)
                let checkout = URL(fileURLWithPath: "/Users/qa/Projects/continuum", isDirectory: true)
                let home = AgentHome(projectId: nil, projectRoot: checkout, checkoutRoot: checkout)
                let row = AgentCompactStatusRowView(
                    configuration: AgentCompactStatusRowConfiguration(reducedMotion: true, deterministicSnapshotPhase: 0.25),
                    thinkingIndicatorFactory: { CompactStatusProbeThinkingIndicatorView() })
                row.apply(AgentCompactStatusPresentation.present(
                    location: AgentLocationSnapshot(home: home, whereDirectory: checkout),
                    projectName: "continuum",
                    activity: AgentCompactActivityInput(phase: .thinking, phaseStartedAt: now.addingTimeInterval(-42)),
                    now: now,
                    contextWindow: AgentContextWindowSnapshot(
                        usedTokens: 96_000,
                        maxTokens: 128_000,
                        observedAt: now,
                        source: .providerSessionStats,
                        freshness: .live),
                    contextPolicy: AgentRadialContextMeterPolicy.thresholds(warning: 0.75, critical: 0.90)))
                return row
            }),
            // 91/P4.7: the reusable control is intentionally isolated until P4.8
            // owns model/effort migration. Render its real button, list, and private
            // row descendants so none can retain a stale token CGColor meanwhile.
            ("appearance.choicePopover", NSSize(width: 280, height: 240), {
                let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 240))
                let items = [
                    ChoiceItem(id: "fast", title: "Fast", detail: "Lower latency"),
                    ChoiceItem(id: "balanced", title: "Balanced", detail: "Recommended"),
                    ChoiceItem(id: "legacy", title: "Legacy", detail: "Unavailable", enabled: false),
                    ChoiceItem(id: "deep", title: "Deep", detail: "More reasoning"),
                ]
                let button = ChoiceButton(title: "Model")
                button.items = items
                button.selectedID = "balanced"
                button.frame = NSRect(x: 0, y: 208, width: 160, height: ChoiceButton.controlHeight)
                let list = ChoiceListView(items: items, selectedID: "balanced")
                list.frame = NSRect(x: 0, y: 0, width: 280, height: list.intrinsicContentSize.height)
                root.addSubview(button)
                root.addSubview(list)
                return root
            }),
            // The completion and command layouts wrap the shared choice list in
            // their own token-painted containers. Keep both in the appearance
            // census so their overlay fill and border are exercised by a live
            // theme flip as well as the rows they host.
            ("appearance.completionPopover", NSSize(width: 420, height: 260), {
                let items = [
                    ChoiceItem(id: "file-a", title: "AgentComposerView.swift", detail: "Sources/ContinuumRevived/Canvas"),
                    ChoiceItem(id: "file-b", title: "WorkspaceRuntime.swift", detail: "Sources/ContinuumRevived/App"),
                ]
                let list = ChoiceListView(items: items, selectedID: "file-a")
                return CompletionPopoverContentView(
                    listView: list,
                    layout: CompletionPopoverLayout(
                        breadcrumb: "Array  ›  Sources  ›  ContinuumRevived",
                        footer: "Return to insert · Esc to close"
                    )
                )
            }),
            ("appearance.commandPopover", NSSize(width: 360, height: 220), {
                let items = [
                    ChoiceItem(id: "model", title: "/model", detail: "Choose provider and model"),
                    ChoiceItem(id: "effort", title: "/effort", detail: "Choose reasoning effort"),
                ]
                let list = ChoiceListView(items: items, selectedID: "model")
                return CommandPopoverContentView(listView: list)
            }),
            // Provider>model picker (t3 port): render the two-pane surface so
            // the container and its private rail buttons can never keep a
            // stale token CGColor unobserved.
            ("appearance.providerModelPicker", NSSize(width: 320, height: 200), {
                let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
                let picker = ProviderModelPickerView(
                    items: [
                        ChoiceItem(id: "openai-codex/gpt-a", title: "openai-codex/gpt-a"),
                        ChoiceItem(id: "openai-codex/gpt-b", title: "openai-codex/gpt-b"),
                        ChoiceItem(id: "anthropic/claude-x", title: "anthropic/claude-x"),
                    ],
                    selectedID: "anthropic/claude-x")
                let size = picker.intrinsicContentSize
                picker.frame = NSRect(x: 0, y: max(0, 200 - size.height), width: size.width, height: size.height)
                root.addSubview(picker)
                return root
            })
        ]
        // Read out of the source, not typed here: every declared conformer must show
        // up in this sweep, so a conformance quietly dropped is red AND a new
        // conformer that nothing renders here is red too.
        var expectedTypes = try declaredConformers()
        var totalViews = 0
        var totalSlots = 0
        var totalChanged = 0
        // Fills whose resolved value has to MOVE with the appearance, not merely be
        // re-assigned. Before P1.11 these were `windowBackgroundColor`; they are now
        // `SurfaceToken.panel`, whose two leaves differ, so the assertion still bites
        // — what it catches is a fill pinned to one theme.
        var appearanceDependent: [String: (before: String, after: String)] = [:]

        for surface in surfaces {
            let probe = try UIProbe.render(
                UIProbe.Spec(id: surface.id, size: surface.size, appearance: .aqua), make: surface.make
            )
            openUserInputRequest(in: probe.view)
            let themed = tokenThemedViews(in: probe.view)
            guard !themed.isEmpty else {
                throw fail("\(surface.id): no TokenThemed view in the rendered tree — the conformance is gone or the surface is not the one it was")
            }
            // The whole chain, so an instance of a subclass covers the base class that
            // actually declares the conformance (`ManagedAgentTileNSView` covers
            // `TileNSView`).
            for view in themed {
                var cls: AnyClass? = type(of: view)
                while let current = cls, current != NSView.self {
                    expectedTypes.remove(String(describing: current))
                    cls = class_getSuperclass(current)
                }
            }

            let slots = themed.flatMap(ownedColorSlots(of:)) + extraSlots(in: probe.view)
            guard !slots.isEmpty else {
                throw fail("\(surface.id): TokenThemed views own no layer colours — nothing to re-apply")
            }
            let before = slots.map { ($0.label, hex($0.color)) }
            for slot in slots { slot.write(sentinel) }

            try flip(probe, to: .darkAqua)

            var survivors: [String] = []
            var changed = 0
            for (index, slot) in slots.enumerated() {
                let now = hex(slot.color)
                if now == hex(sentinel) { survivors.append(slot.label) }
                if now != before[index].1 { changed += 1 }
                if slot.label == "WorkspaceSidebarView.background" || slot.label == "WorkspaceTopBarView.background" {
                    appearanceDependent[slot.label] = (before[index].1, now)
                }
            }
            guard survivors.isEmpty else {
                throw fail("\(surface.id): \(survivors.count) layer colour(s) kept the sentinel across an appearance flip — assigned outside applyTokens(): \(survivors.sorted().joined(separator: ", "))")
            }
            totalViews += themed.count
            totalSlots += slots.count
            totalChanged += changed
            restoreAppPin()
        }

        guard expectedTypes.isEmpty else {
            throw fail("TokenThemed types declared in the source but never swept: \(expectedTypes.sorted().joined(separator: ", ")) — render them here or they can keep a stale CGColor unobserved")
        }
        guard totalViews >= minimumThemedViews else {
            throw fail("swept \(totalViews) TokenThemed views, floor is \(minimumThemedViews)")
        }
        guard totalSlots >= minimumSentineledSlots else {
            throw fail("sentinelled \(totalSlots) layer colours, floor is \(minimumSentineledSlots)")
        }
        // 2 · a system fill must really re-resolve. Without this the sweep above is
        // satisfied by re-assigning the same wrong colour.
        for label in ["WorkspaceSidebarView.background", "WorkspaceTopBarView.background"] {
            guard let pair = appearanceDependent[label] else {
                throw fail("\(label) was not swept — the chrome fill is no longer a layer background this gate can see")
            }
            guard pair.before != pair.after else {
                throw fail("\(label) resolved to \(pair.before) in .aqua and \(pair.after) in .darkAqua — a system colour that does not move is a snapshotted CGColor")
            }
        }
        return (totalViews, totalSlots, totalChanged)
    }

    // MARK: - 1b · Every conformer in the source must be swept

    /// From the cross-review: the sweep can only assert about views it renders, so a
    /// NEW `TokenThemed` view that this gate never renders could keep stale colours
    /// and nothing would say so. Closed by reading the source: every type declared
    /// `TokenThemed` under `Sources/ContinuumRevived` must have turned up in the
    /// sweep. Adding a conformer therefore forces adding it to the rendered set.
    ///
    /// Source-scanned rather than reflected because Swift cannot enumerate the
    /// conformers of a protocol at runtime; the same repo-relative convention
    /// `UIProbeBaseline` uses for its committed PNGs (the matrix runs from the repo
    /// root, and a missing directory is a loud failure, not a silent pass).
    private static let conformanceScanRoot = "Sources/ContinuumRevived"

    private static func declaredConformers() throws -> Set<String> {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let root = cwd.appendingPathComponent(conformanceScanRoot, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw fail("no \(conformanceScanRoot) directory at \(root.path) (working directory \(cwd.path)) — run this check from the repo root")
        }
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw fail("could not enumerate \(root.path)")
        }
        // `final class X: NSView, TokenThemed {` / `class X: TileNSView, TokenThemed {`
        let pattern = try NSRegularExpression(pattern: "\\bclass\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*:[^{\\n]*\\bTokenThemed\\b")
        var names: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            // This file declares the fixtures, which are conformers on purpose.
            guard url.lastPathComponent != "UIProbeAppearance.swift" else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                guard let range = Range(match.range(at: 1), in: source) else { continue }
                names.insert(String(source[range]))
            }
        }
        guard !names.isEmpty else {
            throw fail("found no `: … TokenThemed` declaration under \(conformanceScanRoot) — the scan is looking in the wrong place, or the protocol has no production conformers")
        }
        return names
    }

    // MARK: - 2b · `applyTokens()` must not read NSAppearance.current

    /// Found by running the negative test: flipping the appearance does NOT
    /// distinguish `appResolvedCGColor` from a plain `.cgColor`, because AppKit
    /// makes the view's new appearance current while it delivers
    /// `viewDidChangeEffectiveAppearance` — so a snapshotting sidebar passed the
    /// sweep. The distinction only shows up when `applyTokens()` runs OUTSIDE such a
    /// context (from `init`, from a timer, from a reload), which is exactly where
    /// the original white-on-white bug lived.
    ///
    /// So: host in `.aqua`, then call `applyTokens()` directly from inside a
    /// `.darkAqua` drawing block and again from inside an `.aqua` one. A view that
    /// resolves against its own/the app's appearance produces the same colour all
    /// three times; one that reads `NSAppearance.current` produces two different
    /// ones. Not vacuous: the sweep above independently proves these two fills DO
    /// move between appearances.
    ///
    /// The tile is deliberately still not a subject after P1.10. Its adopted surfaces
    /// go through `TokenColor.cgColor(for:)`, which takes the theme as an ARGUMENT and
    /// never reads `NSAppearance.current`, so this check could only pass trivially on
    /// them. What covers token consumers instead is check 4, which asserts the exact
    /// per-theme leaf on the real tree.
    private static func runHostileCurrentAppearanceCheck() throws -> Int {
        // P1.11 moved the sidebar and the top bar off `windowBackgroundColor` onto
        // `SurfaceToken.panel`, which takes the theme as an argument and therefore
        // cannot read `NSAppearance.current` at all — so on those two this check
        // would now pass trivially, exactly as it does on the tile. Rather than let
        // it decay into a tautology, the SYSTEM-colour subject is a fixture that
        // paints `appResolvedCGColor` the way production still does in
        // `CanvasNSView`'s focus border and selection chrome. Both spellings of the
        // bug (`.cgColor`, and `withAlphaComponent(_:).appResolvedCGColor`) are
        // still red against it — see negative test 4.
        let subjects: [(id: String, size: NSSize, make: () -> NSView)] = [
            ("appearance.systemFill.hostile", NSSize(width: 200, height: 80), { SystemFillFixtureView() }),
            ("appearance.sidebar.hostile", NSSize(width: 280, height: 520), { WorkspaceSidebarView(frame: .zero) }),
            ("appearance.topBar.hostile", NSSize(width: 900, height: 44), { WorkspaceTopBarView(frame: .zero) })
        ]
        var asserted = 0
        for subject in subjects {
            let probe = try UIProbe.render(
                UIProbe.Spec(id: subject.id, size: subject.size, appearance: .aqua), make: subject.make
            )
            guard let themed = probe.view as? TokenThemed else {
                throw fail("\(subject.id): \(describe(probe.view)) is not TokenThemed")
            }
            NSApp?.appearance = NSAppearance(named: .aqua)
            let hosted = hex(probe.view.layer?.backgroundColor)
            for name in [NSAppearance.Name.darkAqua, .aqua] {
                guard let appearance = NSAppearance(named: name) else {
                    throw fail("no NSAppearance named '\(name.rawValue)'")
                }
                appearance.performAsCurrentDrawingAppearance { themed.applyTokens() }
                let after = hex(probe.view.layer?.backgroundColor)
                guard after == hosted else {
                    throw fail("\(subject.id): applyTokens() called with '\(name.rawValue)' current painted \(after), but the view is drawing in .aqua and was holding \(hosted) — the colour was resolved against NSAppearance.current instead of the app's appearance (use appResolvedCGColor)")
                }
                asserted += 1
            }
            restoreAppPin()
        }
        return asserted
    }

    // MARK: - 3 · Token fixture and its regression witness

    /// P1.11: a view whose fill is a genuine system colour routed through
    /// `appResolvedCGColor`, so check 2b keeps a subject the check can actually fail.
    /// This is the shape the app still uses wherever the colour is the USER's — the
    /// focus border, the selection ring, the marquee.
    private final class SystemFillFixtureView: NSView, TokenThemed {
        init() {
            super.init(frame: .zero)
            wantsLayer = true
            applyTokens()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func applyTokens() {
            layer?.backgroundColor = NSColor.windowBackgroundColor.appResolvedCGColor
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyTokens()
        }
    }

    /// A token-consuming view, built the way P1.10/P1.11 will build theirs.
    private final class TokenFixtureView: NSView, TokenThemed {
        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.borderWidth = 1
            applyTokens()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func applyTokens() {
            layer?.backgroundColor = SurfaceToken.tileBody.color.cgColor(in: self)
            layer?.borderColor = LineToken.border.color.cgColor(in: self)
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyTokens()
        }
    }

    /// The same view minus the ticket: it resolves its tokens once, in `init`. This
    /// is what every view in the app did before P1.9, and the assertion below must
    /// reject it — otherwise the assertion proves nothing.
    private final class StaleFixtureView: NSView {
        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.borderWidth = 1
            layer?.backgroundColor = SurfaceToken.tileBody.color.cgColor(in: self)
            layer?.borderColor = LineToken.border.color.cgColor(in: self)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }

    /// Asserts a fixture holds the exact token leaf for the appearance it is in,
    /// before and after a flip. Exact values, not "something changed": a view that
    /// re-applied the WRONG leaf would satisfy inequality.
    private static func expectTokenFollowsAppearance(id: String, make: @escaping () -> NSView) throws {
        let probe = try UIProbe.render(
            UIProbe.Spec(id: id, size: NSSize(width: 120, height: 80), appearance: .aqua), make: make
        )
        func expect(_ theme: TokenTheme, _ phase: String) throws {
            let wantFill = hex(SurfaceToken.tileBody.color.cgColor(for: theme))
            let wantLine = hex(LineToken.border.color.cgColor(for: theme))
            let gotFill = hex(probe.view.layer?.backgroundColor)
            let gotLine = hex(probe.view.layer?.borderColor)
            guard gotFill == wantFill, gotLine == wantLine else {
                throw fail("\(id) \(phase): layer holds fill \(gotFill) / border \(gotLine), the \(theme.rawValue) leaves are \(wantFill) / \(wantLine) — a CGColor assigned once at init does not follow the appearance")
            }
        }
        try expect(.light, "in .aqua")
        try flip(probe, to: .darkAqua)
        try expect(.dark, "after flip to .darkAqua")
        restoreAppPin()
    }

    private static func runTokenFixtureCheck() throws -> String {
        try expectTokenFollowsAppearance(id: "appearance.tokenFixture") { TokenFixtureView() }

        // The witness: the same assertion, applied to the pre-ticket pattern.
        var witnessMessage: String?
        do {
            try expectTokenFollowsAppearance(id: "appearance.staleFixture") { StaleFixtureView() }
        } catch let error as AppearanceError {
            witnessMessage = error.message
        }
        restoreAppPin()
        guard let witnessMessage, witnessMessage.contains("after flip to .darkAqua") else {
            throw fail("regression witness did not fail: a view that snapshots its token CGColor in init passed the follows-appearance assertion (\(witnessMessage ?? "no failure at all")) — the assertion is not discriminating")
        }
        return witnessMessage
    }

    // MARK: - 4 · The adopted surfaces really hold token VALUES (P1.10)
    //
    // The sweep above proves a colour is re-applied from `applyTokens()`; the fixture
    // proves the mechanism resolves the right leaf. Neither says the app is painting
    // *the palette* — a view could re-apply a hand-rolled literal on every flip and
    // satisfy both. This is the assertion P1.10's "no raw colour literals remain in
    // these four files" turns into a number: over the real managed-agent tile, in
    // both appearances, every layer colour painted by an adopted view must be a value
    // `DesignTokens` can produce for that theme.
    //
    // It is a whitelist of ADOPTERS, not a blanket sweep, because `TileNSView` and
    // its two private chrome views are still on literals by design — that is P1.11's
    // file. Their labels are enumerated below with the owning ticket, and an owner
    // that is neither adopted nor listed is a failure, so the hole is visible and can
    // only shrink.

    /// The views P1.10 and P1.11 put on tokens.
    private static let tokenAdoptedOwners: Set<String> = [
        "ManagedAgentTileNSView.contentBackdrop",
        "ManagedAgentTileNSView.header",
        "ManagedAgentTileNSView.composeBackdrop",
        // Queue 91/P3: the host-local Home/Where/What band uses the same
        // `tileChrome` surface as the header it extends; its external markers and
        // text use the existing primary/secondary text tokens.
        "AgentLocationStatusView",
        // Queue 91 live managed-agent composition: the compact row owns the
        // single visible Home/Where/What surface and paints its tile-chrome fill.
        "AgentCompactStatusRowView",
        // P5.5 acceptance: the legacy TranscriptCardView/TranscriptProseView owners
        // were deleted with the compatibility path; the v2 tiles the Lab now vends
        // paint the composer shell on every managed-agent surface, so the composer
        // enters the adopted census here (its repaint path was already gated by
        // the isolated composer sentinel fixtures).
        "AgentComposerView",
        // The composer's primary action: quiet composer fill when unavailable, an
        // accent fill when an operation is offered, accents as glyph/label
        // foregrounds — all named tokens, gated since P4.6 on the isolated
        // fixture and now on every managed-agent surface the Lab vends.
        "ComposerActionButton",
        // 91/P4.8: P4.7 made this custom control token-painted and the isolated
        // sentinel fixture covers its repaint path. P4.8 installs it in the real
        // managed-agent tile, so its fill and interactive boundary now also enter
        // the adopted-surface value/role gate.
        "ChoiceButton",
        // Provider>model picker (t3 port): the composer's model trigger is a
        // ChoiceButton subclass painting the identical composer/hover family;
        // the two-pane surface paints the composer fill with hairline divider
        // and focus-ring indicator bars; rail buttons paint the row
        // hover/selected ladder. All named tokens, gated by
        // `--provider-model-picker-check`'s render pass.
        "ProviderModelButton",
        "ProviderModelPickerView",
        "ProviderRailButton",
        // The picker embeds the P4.7 choice list as its model pane, which puts
        // the list (SurfaceToken.overlay fill) and its rows (the same
        // hover/selected ladder as the rail) under this census for the first
        // time — they always painted these tokens; only the gate's reach grew.
        "ChoiceListView",
        "ChoiceRowView",
        // P2C.4's branch chip, born on tokens: `SurfaceToken.overlay` fill with a
        // `LineToken.border` outline that becomes `AccentToken.accentApproval` when
        // the agent is off the branch it was given.
        "BranchChipNSView",
        // P1.11. `ManagedAgentTileNSView`'s own layer is `TileNSView`'s fill and
        // outline, inherited through `super.applyTokens()` — so listing it here is
        // what puts the tile's `tileBody` fill and its `borderStrong` edge under
        // this gate. `TitleBarView` and `CornerOverlayView` are the tile's two
        // private chrome views.
        "ManagedAgentTileNSView",
        "TitleBarView",
        "CornerOverlayView",
        "DescriptorTileNSView",
        "DescriptorTileNSView.body",
        "NoteTileNSView",
        "FileTileNSView",
        "RunArtifactsTileNSView",
        "DiffReviewTileNSView",
        "FileTreeTileNSView",
        "CanvasNSView",
        "WorkspaceSidebarView",
        "WorkspaceTopBarView",
        // P3.6. The list's own `panel` fill, and the row card. 94/P1.1 took the
        // card's outline away and 94/P1.2 replaced its one-fill-in-every-state
        // `tileBody` with the `SidebarSurfaceRole` ladder, so what this owner
        // paints now is: NOTHING at rest (a resting card owns no colour slot at
        // all, which is why `adoptedSurfaces` selects a row — see there), and one
        // of the three sidebar fills otherwise.
        "AgentInboxView",
        "AgentInboxCardView",
        // 94/P1.4. The row's keyboard focus ring: a hairline `AgentLineRole.focusRing`
        // border on a view of its own, hidden unless the row has the keyboard. It
        // reaches this gate whether or not it is on screen, for the reason
        // `InboxUndoToast` below records — the walk reads the layer colours a view
        // painted in `init`.
        "InboxRowFocusRingView",
        // P3.10. The ⌘-hold hint pill: `SurfaceToken.overlay` fill with a
        // `LineToken.border` outline. It only paints while the modifier is held, so
        // what puts it under this gate is the `chrome.agentInbox.jumpHints` Lab card
        // — the one probed surface that renders the pills visible.
        "InboxJumpHintView",
        // Program 96's hover card: `SurfaceToken.overlay` fill with an
        // `AgentLineRole.controlBoundary` outline — the same pair as the pill
        // above. It lives in the WINDOW's content view rather than in the sidebar,
        // and it only paints while a row is hovered with the preview flag on, so
        // no probed surface renders it today; it is listed here so that the first
        // surface which does cannot arrive unregistered.
        "InboxHoverCardView",
        // P3.11. The bulk-action bar, the same pair as the pill above it:
        // `SurfaceToken.overlay` fill with a `LineToken.border` outline. It paints only
        // while two or more rows are selected, so what puts it under this gate is the
        // `chrome.agentInbox.bulk` Lab card.
        "InboxBulkActionBar",
        // P4.11. The undo toast, the third card in that same family and the same pair:
        // `SurfaceToken.overlay` fill with a `LineToken.border` outline. It is HIDDEN in
        // every probed surface — an action cannot be performed inside a static render —
        // and it still reaches this gate, because the walk reads the layer colours a
        // view painted in `init` whether or not it is on screen. So the fill and the
        // outline are held to the palette from the first frame; the WORDS on it are
        // covered by section K of `--agent-inbox-check` rather than by a pixel.
        "InboxUndoToast"
    ]

    /// Still painting literals, each with the ticket that retires them.
    ///
    /// The image attachment rail owns a deliberately transparent layer so its
    /// collection view can coordinate appearance updates for visible cells. It
    /// is not a visible palette surface; keep it explicit until the image rail
    /// receives a dedicated transparent token.
    private static let literalOwnersPendingAdoption: [String: String] = [
        "ComposerImageAttachmentRailView": "Queue 91 image attachment rail — plan-managed-agent-tile-polish.md §6"
    ]

    /// The values legal for a given KIND of layer colour in `theme`, in this gate's
    /// hex spelling. Scoped by kind rather than "any token", which says more: a fill
    /// must be a SURFACE (a card painting itself in a text colour is wrong even
    /// though a text colour is a token), and an outline must be a line or an accent.
    ///
    /// It also makes the wrong-theme check below hold. Over the whole palette the two
    /// themes are NOT disjoint — `#14171C` is `SurfaceToken.tileBody` dark and
    /// `TextToken.textPrimary` light, measured by the first version of this gate —
    /// so an unscoped "is it a token?" test would wave a fill pinned to `.dark`
    /// straight through under Aqua, which is the shipped black-on-dark bug.
    private static func legalValues(for kind: ColorSlot.Kind, theme: TokenTheme) -> Set<String> {
        var values: Set<String> = []
        func add<T>(_ tokens: [T], _ color: (T) -> TokenColor) {
            for token in tokens { values.insert(hex(color(token).cgColor(for: theme))) }
        }
        switch kind {
        case .background, .fill:
            add(SurfaceToken.allCases) { $0.color }
        case .border, .stroke:
            add(LineToken.allCases) { $0.color }
            add(AccentToken.allCases) { $0.color }
        }
        return values
    }

    /// P0.3's agent-tile roles are additive to the older palette. Keep their
    /// admission owner-scoped until the full v2 tile migrates: only the P4.8
    /// `ChoiceButton` may paint the composer/hover surface family here, while every
    /// older adopter remains constrained to the original `SurfaceToken` set.
    private static func legalValues(
        forOwner owner: String,
        kind: ColorSlot.Kind,
        theme: TokenTheme
    ) -> Set<String> {
        var values = legalValues(for: kind, theme: theme)
        guard kind == .background || kind == .fill else { return values }
        switch owner {
        case "ChoiceButton", "ProviderModelButton":
            // The picker trigger is a ChoiceButton subclass painting the same
            // composer/hover family through the inherited applyTokens.
            for role in [AgentSurfaceRole.composer, .rowHover] {
                values.insert(hex(role.color.cgColor(for: theme)))
            }
        case "ProviderModelPickerView":
            // The two-pane surface: composer fill; its selected-provider
            // indicator bar and rail divider are FILLS of line roles by
            // design (a 2.5pt bar and a 1pt divider are drawn as views).
            values.insert(hex(AgentSurfaceRole.composer.color.cgColor(for: theme)))
            values.insert(hex(AgentLineRole.focusRing.color.cgColor(for: theme)))
            values.insert(hex(AgentLineRole.decorativeHairline.color.cgColor(for: theme)))
        case "ProviderRailButton", "ChoiceRowView":
            // The rail's interaction ladder mirrors choice rows; the rows are
            // the original owners of it (P4.7). Resting state paints nothing.
            for role in [AgentSurfaceRole.rowHover, .rowSelected] {
                values.insert(hex(role.color.cgColor(for: theme)))
            }
        case "AgentComposerView":
            // The shell's one fill is the composer surface role (P4.1).
            values.insert(hex(AgentSurfaceRole.composer.color.cgColor(for: theme)))
        case "ComposerActionButton":
            // Quiet composer fill when no operation is offered; exactly the two
            // production accents otherwise (send/stop — P4.6's resolver).
            values.insert(hex(AgentSurfaceRole.composer.color.cgColor(for: theme)))
            values.insert(hex(AccentToken.accentInput.color.cgColor(for: theme)))
            values.insert(hex(AccentToken.accentFailed.color.cgColor(for: theme)))
        case "AgentInboxCardView":
            // 94/P1.2: the sidebar's interaction ladder, owner-scoped exactly like
            // the roles above. The THREE emphases only — `resting` is deliberately
            // absent, because a resting row paints no fill at all and therefore
            // owns no slot for this gate to check. Admitting it here would let an
            // opaque resting card back in under the name of the role that means
            // "unfilled".
            for role in SidebarSurfaceRole.rowEmphases {
                values.insert(hex(role.color.cgColor(for: theme)))
            }
        default:
            break
        }
        return values
    }

    /// The values legal for a foreground colour — a `textColor`, a `contentTintColor`,
    /// a glyph tint. Text tokens plus accents: a status glyph is an accent by design
    /// (P1.3 holds accents to the 4.5 text floor for exactly that reason), so both
    /// families are legal, but a SURFACE as a text colour is not.
    ///
    /// P1.11 needs this because most of what the chrome and the content tiles paint
    /// is not a layer colour: `NSTextView.textColor`, `NSOutlineView.backgroundColor`,
    /// `NSTextField.textColor`, `NSButton.contentTintColor`,
    /// `NSImageView.contentTintColor`. Check 4 could not see
    /// any of them, which was its recorded honest limit.
    private static func legalForegroundValues(theme: TokenTheme) -> Set<String> {
        var values: Set<String> = []
        for token in TextToken.allCases { values.insert(hex(token.color.cgColor(for: theme))) }
        for token in AccentToken.allCases { values.insert(hex(token.color.cgColor(for: theme))) }
        return values
    }

    /// One non-layer AppKit colour, with which family it has to come from.
    private struct ForegroundSlot {
        let label: String
        let color: NSColor?
        /// `true` for a fill-ish property (`NSTextView.backgroundColor`), which must
        /// be a surface rather than a foreground.
        let isSurface: Bool
        /// The view the slot belongs to, so a fully transparent FILL can be checked
        /// against whatever surface shows through it.
        let view: NSView
    }

    /// A transparent fill is the absence of a colour, not a wrong one — the sidebar's
    /// outline view is `.clear` on purpose so the panel shows through. But waving
    /// alpha 0 past the gate would let a surface be hidden rather than fixed, so it
    /// is only legal when the nearest ancestor that DOES paint a fill paints a token
    /// surface for this theme. Transparency then means "inherits the palette", which
    /// is the only reason to use it.
    private static func inheritedSurfaceIsLegal(from view: NSView, theme: TokenTheme) -> String? {
        let legal = legalValues(for: .background, theme: theme)
        var current: NSView? = view.superview
        while let node = current {
            if let fill = node.layer?.backgroundColor, (NSColor(cgColor: fill)?.alphaComponent ?? 0) > 0 {
                let value = hex(fill)
                return legal.contains(value) ? nil
                    : "shows through to \(describe(node))'s \(value), which is not a DesignTokens surface for \(theme.rawValue)"
            }
            current = node.superview
        }
        return "has no ancestor painting a fill, so nothing defines what shows through it"
    }

    /// Every non-layer colour the P1.11 surfaces paint, discovered by walking the
    /// tree rather than listed here — so a new label in an adopted view is covered
    /// the moment it exists, and a label that stops being painted cannot hide.
    ///
    /// HONEST LIMIT, and it is a scoping decision rather than an omission:
    /// `NSTextField.textColor` is non-nil on every label AppKit builds, so a naive
    /// walk sweeps up the internals of a bezelled control. An `NSSearchField`, an
    /// `NSPopUpButton` and a bezelled `NSButton` draw their whole chrome — bezel,
    /// focus ring, text — from AppKit's own internally-consistent, appearance-correct
    /// palette. Overriding just the text on one of those IS the black-on-dark trap in
    /// miniature, so P1.3 declares no token for it and this check does not demand
    /// one. What IS read on a control is a tint we assigned ourselves
    /// (`contentTintColor` is nil until somebody sets it).
    ///
    /// Concretely: a control's own default colours are skipped; everything we build
    /// and paint — labels, text views, outline/table fills — is read.
    private static func foregroundSlots(in root: NSView) -> [ForegroundSlot] {
        var slots: [ForegroundSlot] = []
        /// The bezelled controls whose text belongs to AppKit, self included.
        func isAppKitControlChrome(_ view: NSView) -> Bool {
            var current: NSView? = view
            while let node = current {
                if node is NSSearchField || node is NSPopUpButton
                    || node is NSProgressIndicator || node is NSScroller { return true }
                current = node.superview
            }
            // A button's own tint is ours; the cell views inside it are not.
            var parent = view.superview
            while let node = parent {
                if node is NSButton { return true }
                parent = node.superview
            }
            return false
        }
        func visit(_ view: NSView) {
            // A hidden view paints nothing, so it has no colour to be right or wrong
            // about — and its whole subtree is hidden with it. Found by the negative
            // test: a file-tree row with no git status hides its badge and leaves the
            // label `.clear`, which is correct and which the gate would have called a
            // non-token colour.
            guard !view.isHidden else { return }
            defer { view.subviews.forEach(visit) }
            guard !isAppKitControlChrome(view) else { return }
            let owner = describe(view)
            switch view {
            case let textView as NSTextView:
                slots.append(ForegroundSlot(label: "\(owner).textColor", color: textView.textColor, isSurface: false, view: view))
                if textView.drawsBackground {
                    slots.append(ForegroundSlot(label: "\(owner).backgroundColor", color: textView.backgroundColor, isSurface: true, view: view))
                }
                // Every DISTINCT `.foregroundColor` in the text storage. Found by the
                // negative test: the diff renderer's six accents live in attributed
                // runs, not in `textColor`, so putting `NSColor.systemGreen` back on
                // additions left the gate green. `.backgroundColor` attributes are
                // deliberately NOT read — the 10% wash behind a changed line is an
                // alpha composite over an already-gated surface, which is the same
                // reasoning the status pill's tint gets.
                if let storage = textView.textStorage, storage.length > 0 {
                    var seen: Set<String> = []
                    storage.enumerateAttribute(
                        .foregroundColor, in: NSRange(location: 0, length: storage.length)
                    ) { value, range, _ in
                        guard let color = value as? NSColor else { return }
                        let key = color.description
                        guard seen.insert(key).inserted else { return }
                        slots.append(ForegroundSlot(
                            label: "\(owner).attributedRun@\(range.location)",
                            color: color, isSurface: false, view: view))
                    }
                }
            case let outline as NSTableView:
                slots.append(ForegroundSlot(label: "\(owner).backgroundColor", color: outline.backgroundColor, isSurface: true, view: view))
            case let button as NSButton:
                // Only the tint we assign; a nil tint is AppKit's own and not ours.
                if let tint = button.contentTintColor {
                    slots.append(ForegroundSlot(label: "\(owner).contentTintColor", color: tint, isSurface: false, view: view))
                }
            case let imageView as NSImageView:
                // Template bitmap symbols still take their live colour from the
                // image view. Census the images this freeze owns (bitmap-only
                // templates) so the new witness does not widen P1.11 onto
                // unrelated vector/image surfaces in the same tree.
                if CanvasSymbolImage.owns(imageView.image),
                   let tint = imageView.contentTintColor {
                    slots.append(ForegroundSlot(label: "\(owner).contentTintColor", color: tint, isSurface: false, view: view))
                }
            case let field as NSTextField:
                slots.append(ForegroundSlot(label: "\(owner).textColor", color: field.textColor, isSurface: false, view: view))
                // A BEZELLED field's fill comes with its bezel — one AppKit unit, in
                // AppKit's own `textBackgroundColor`, exactly like the search field
                // above. Its `textColor` is still ours and still checked. A label
                // (`isBezeled == false`) that draws a background painted it itself, so
                // that fill IS ours.
                if field.drawsBackground, !field.isBezeled {
                    slots.append(ForegroundSlot(label: "\(owner).backgroundColor", color: field.backgroundColor, isSurface: true, view: view))
                }
            default:
                break
            }
        }
        visit(root)
        return slots
    }

    private static func runAdoptedTokenValueCheck() throws -> (assertions: Int, owners: Int, foregrounds: Int) {
        // What makes this gate catch a token pinned to the WRONG theme: within one
        // kind, no value legal in light is also legal in dark. True of today's tokens
        // but not guaranteed by construction, so it is asserted every run rather than
        // assumed — if a future palette breaks it, the wrong-theme detection silently
        // stops working and this says so.
        for kind in ColorSlot.Kind.allKinds {
            let overlap = legalValues(for: kind, theme: .light)
                .intersection(legalValues(for: kind, theme: .dark))
            guard overlap.isEmpty else {
                throw fail("the light and dark palettes share \(overlap.count) legal \(kind.rawValue) value(s) (\(overlap.sorted().joined(separator: ", "))) — a token resolved for the wrong theme would pass this gate")
            }
        }
        // The per-owner exceptions are exact: background/fill values grow only
        // for the named custom owners, by exactly their production leaves (P4.8
        // precedent, extended at P5.5 when the v2 tile became the only tile). A
        // missing owner predicate or admission of another role would weaken the
        // gate.
        for theme in TokenTheme.allCases {
            let composerFill = hex(AgentSurfaceRole.composer.color.cgColor(for: theme))
            let choiceValues: Set<String> = [composerFill, hex(AgentSurfaceRole.rowHover.color.cgColor(for: theme))]
            let actionValues: Set<String> = [
                composerFill,
                hex(AccentToken.accentInput.color.cgColor(for: theme)),
                hex(AccentToken.accentFailed.color.cgColor(for: theme)),
            ]
            // 94/P1.2: the row card's admission is the sidebar ladder's three
            // EMPHASES and nothing else — pinned here so a later packet cannot
            // quietly widen it to `resting` (which would re-admit an opaque
            // resting card) or to a tile role.
            let sidebarValues = Set(SidebarSurfaceRole.rowEmphases.map {
                hex($0.color.cgColor(for: theme))
            })
            for kind in [ColorSlot.Kind.background, .fill] {
                let base = legalValues(for: kind, theme: theme)
                guard legalValues(forOwner: "ChoiceButton", kind: kind, theme: theme)
                        == base.union(choiceValues),
                      legalValues(forOwner: "AgentComposerView", kind: kind, theme: theme)
                        == base.union([composerFill]),
                      legalValues(forOwner: "ComposerActionButton", kind: kind, theme: theme)
                        == base.union(actionValues),
                      legalValues(forOwner: "AgentInboxCardView", kind: kind, theme: theme)
                        == base.union(sidebarValues),
                      legalValues(forOwner: "ManagedAgentTileNSView", kind: kind, theme: theme)
                        == base else {
                    throw fail("per-owner role admission widened another owner or admitted the wrong \(kind.rawValue) set in \(theme.rawValue)")
                }
            }
        }

        // P1.11: the same disjointness, on the foreground families. Without it a
        // `textPrimary` pinned to `.dark` (`#F2F4F8`) could coincide with some light
        // accent and the wrong-theme detection would stop working for text.
        let foregroundOverlap = legalForegroundValues(theme: .light)
            .intersection(legalForegroundValues(theme: .dark))
        guard foregroundOverlap.isEmpty else {
            throw fail("the light and dark palettes share \(foregroundOverlap.count) legal foreground value(s) (\(foregroundOverlap.sorted().joined(separator: ", "))) — a text token resolved for the wrong theme would pass this gate")
        }

        var asserted = 0
        var foregroundsAsserted = 0
        var seenAdopted: Set<String> = []
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let theme: TokenTheme = appearanceName == .darkAqua ? .dark : .light
            for surface in try adoptedSurfaces() {
                let probe = try UIProbe.render(
                    UIProbe.Spec(
                        id: "appearance.tokenValues.\(surface.id).\(appearanceName.rawValue)",
                        size: surface.size, appearance: appearanceName
                    ),
                    make: surface.make
                )
                surface.prepare(probe.view)
                probe.host.layoutSubtreeIfNeeded()
                guard probe.view.effectiveTokenTheme == theme else {
                    throw fail("appearance.tokenValues.\(surface.id): probe hosted in '\(appearanceName.rawValue)' resolves to \(probe.view.effectiveTokenTheme.rawValue)")
                }

                let slots = tokenThemedViews(in: probe.view).flatMap(ownedColorSlots(of:)) + extraSlots(in: probe.view)
                guard !slots.isEmpty else { throw fail("appearance.tokenValues.\(surface.id): no painted layer colours to check") }
                for slot in slots {
                    // `ownerLabel` carries the view's identifier for a transcript card
                    // (`TranscriptCardView#managedAgent.card.assistant-1`); the whitelist
                    // is by type, so compare on the type half.
                    let owner = slot.ownerLabel.split(separator: "#").first.map(String.init) ?? slot.ownerLabel
                    guard tokenAdoptedOwners.contains(owner) else {
                        guard literalOwnersPendingAdoption[owner] != nil else {
                            throw fail("\(slot.label) paints a layer colour in \(theme.rawValue) but is neither in tokenAdoptedOwners nor recorded in literalOwnersPendingAdoption — name it and its owning ticket, or put it on DesignTokens")
                        }
                        continue
                    }
                    seenAdopted.insert(owner)
                    let value = hex(slot.color)
                    guard legalValues(forOwner: owner, kind: slot.kind, theme: theme).contains(value) else {
                        throw fail("\(slot.label) painted \(value) in \(theme.rawValue), which is not a registered \(slot.kind.rawValue) token for that owner and theme — an adopted surface is back on a literal, an unowned role, or a token resolved for the wrong appearance")
                    }
                    asserted += 1
                }

                // P1.11's own half: the colours that are not layer colours.
                //
                // Read INSIDE the probe's drawing appearance, which is what AppKit
                // does at draw time. This gate's first run found why that matters:
                // `StatusChipNSView.dynamicNSColor` hands a label a genuinely dynamic
                // `NSColor`, and `.cgColor` on a dynamic colour resolves against
                // `NSAppearance.current` — the SYSTEM appearance outside a draw cycle.
                // So a correct dark-leaf-in-dark label read back as `#FFB347` while
                // hosted in `.aqua`. Measuring outside the drawing appearance would
                // have failed every dynamic colour in the app and passed a snapshotted
                // one, which is the assertion inverted.
                let drawingAppearance = probe.view.effectiveAppearance
                for slot in foregroundSlots(in: probe.view) {
                    var value = "nil"
                    var alpha: CGFloat = 1
                    drawingAppearance.performAsCurrentDrawingAppearance {
                        value = hex(slot.color?.cgColor)
                        alpha = slot.color?.usingColorSpace(.sRGB)?.alphaComponent ?? 1
                    }
                    if slot.isSurface, alpha == 0 {
                        if let problem = inheritedSurfaceIsLegal(from: slot.view, theme: theme) {
                            throw fail("\(surface.id): \(slot.label) is transparent and \(problem)")
                        }
                        foregroundsAsserted += 1
                        continue
                    }
                    var legal = slot.isSurface
                        ? legalValues(for: .background, theme: theme)
                        : legalForegroundValues(theme: theme)
                    // Choice-row checkmarks deliberately use the same focus-ring
                    // line token as the selected row. Image-view tint was outside
                    // this census before the bitmap freeze; admit that one owned
                    // semantic without making line colours legal for prose/labels.
                    if let imageView = slot.view as? NSImageView,
                       CanvasSymbolImage.owns(imageView.image) {
                        legal.insert(hex(AgentLineRole.focusRing.color.cgColor(for: theme)))
                    }
                    guard legal.contains(value) else {
                        throw fail("\(surface.id): \(slot.label) is \(value) in \(theme.rawValue), which is not a DesignTokens \(slot.isSurface ? "surface" : "text/accent") value for that theme — an AppKit colour property still holds a literal, an Apple semantic colour, or a token resolved for the wrong appearance")
                    }
                    foregroundsAsserted += 1
                }
                restoreAppPin()
            }
        }

        let missing = tokenAdoptedOwners.subtracting(seenAdopted)
        guard missing.isEmpty else {
            throw fail("adopted owners that painted nothing in the probed surfaces: \(missing.sorted().joined(separator: ", ")) — either the surface stopped painting or it left the tree, and this gate would silently cover less")
        }
        guard foregroundsAsserted >= minimumForegroundSlots else {
            throw fail("read back \(foregroundsAsserted) non-layer colours across both appearances, floor is \(minimumForegroundSlots) — a text colour dropped out of the walk")
        }
        return (asserted, seenAdopted.count, foregroundsAsserted)
    }

    // MARK: - The surfaces P1.10 and P1.11 adopted
    //
    // Every one is rendered in BOTH appearances by check 4. The content tiles have
    // no Lab card of their own (the Lab hosts them through a live canvas sandbox),
    // so they are constructed here from canned state — deliberately through the
    // constructors that touch no filesystem and no git, so the check is offline.

    /// Floor for the non-layer colours check 4 reads back, across both appearances.
    /// Measured on this tree and printed every run; a floor rather than an equality
    /// so an extra label is not a failure, but a whole surface dropping out is.
    /// Re-measured at P5.5: deleting the legacy dock/user-input surfaces removed
    /// two of the walked foreground slots (168 → 166).
    private static let minimumForegroundSlots = 166

    private struct AdoptedSurface {
        let id: String
        let size: NSSize
        let make: () -> NSView
        /// Put the surface into the state a user actually sees (open a request, show
        /// a diff). Runs after `UIProbe.render` so the view is already hosted.
        var prepare: (NSView) -> Void = { _ in }
    }

    private static func canned(kind: TileKind, title: String, metadata: TileMetadata = TileMetadata()) -> Tile {
        Tile(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000011\(String(format: "%02d", abs(kind.rawValue.hashValue % 100)))")
                ?? UUID(uuidString: "00000000-0000-0000-0000-000000001100")!,
            kind: kind, title: title,
            frame: TileFrame(x: 0, y: 0, width: 480, height: 320),
            zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: metadata
        )
    }

    /// A flat tree covering EVERY `FileTreeGitStatus` plus an ignored path, so every
    /// badge accent and both row-text tokens are painted and read back.
    private static func cannedFileTree() -> FileTreeSnapshot {
        func node(_ name: String, _ status: FileTreeGitStatus?, ignored: Bool = false) -> FileTreeNode {
            FileTreeNode(
                relativePath: name, displayName: name, isDirectory: false,
                childCount: 0, isIgnored: ignored, gitStatus: status)
        }
        // `FileTreeGitStatus` is not `CaseIterable`, so the six are listed. Making it
        // conform is a Core change this packet does not own; the badge switch in
        // `FileTreeTileNSView` is exhaustive, so a seventh status would fail to
        // compile there before it could go unrendered here.
        let statuses: [FileTreeGitStatus] = [.untracked, .modified, .added, .deleted, .renamed, .conflicted]
        var nodes = statuses.map { node("\($0.rawValue).swift", $0) }
        nodes.append(node("node_modules", nil, ignored: true))
        nodes.append(node("README.md", nil))
        return FileTreeSnapshot(root: URL(fileURLWithPath: "/nonexistent-p111-probe-root"), nodes: nodes)
    }

    /// A two-file diff covering EVERY `GitDiffLine.Kind` plus a binary file, so all
    /// six of the renderer's colours are actually painted and read back.
    private static func cannedDiff() -> GitDiffModel {
        GitDiffModel(files: [
            GitDiffFile(
                oldPath: "Sources/A.swift", newPath: "Sources/A.swift", change: .modified,
                hunks: [GitDiffHunk(
                    oldStart: 1, oldCount: 3, newStart: 1, newCount: 3,
                    header: "@@ -1,3 +1,3 @@ func a()",
                    lines: [
                        GitDiffLine(kind: .context, text: "let x = 1", oldLine: 1, newLine: 1),
                        GitDiffLine(kind: .deletion, text: "let y = 2", oldLine: 2, newLine: nil),
                        GitDiffLine(kind: .addition, text: "let y = 3", oldLine: nil, newLine: 2),
                        GitDiffLine(kind: .metadata, text: "\\ No newline at end of file", oldLine: nil, newLine: nil)
                    ]
                )]
            ),
            GitDiffFile(oldPath: nil, newPath: "Assets/icon.png", change: .added, hunks: [], isBinary: true)
        ])
    }

    private static func adoptedSurfaces() throws -> [AdoptedSurface] {
        let entries = LabCatalog.entries(env: LabEnvironment(ghostty: nil, browserEngine: nil))
        guard let entry = entries.first(where: { $0.id == "tiles.managedAgent" }),
              case let .staticCard(_, makeTile) = entry.content else {
            throw fail("missing tiles.managedAgent card")
        }
        let treeState = FileTreeTile(
            tileId: UUID(uuidString: "00000000-0000-0000-0000-000000001199")!,
            rootPath: "/nonexistent-p111-probe-root", expandedPaths: [], selectedPath: nil,
            searchQuery: "", ignoredNames: [], gitBadges: .off
        )
        return [
            AdoptedSurface(
                id: "managedAgentTile", size: NSSize(width: 640, height: 560), make: makeTile,
                prepare: { root in
                    openUserInputRequest(in: root)
                    // P5.5: the request arrives the way production delivers it —
                    // the reducer-projected block, not the deleted legacy dock.
                    guard let tile = firstDescendant(ManagedAgentTileNSView.self, in: root) else { return }
                    tile.ingest(.requestOpened(
                        threadId: tile.wiringThreadId, requestId: "token-values", kind: .commandExecutionApproval
                    ))
                    tile.layoutSubtreeIfNeeded()
                }
            ),
            AdoptedSurface(id: "descriptorTile", size: NSSize(width: 480, height: 320), make: {
                DescriptorTileNSView(tile: canned(kind: .browser, title: "example.com"))
            }),
            // Program 96's hover card, built standalone with content: hover is a
            // live pointer state no static probe can hold, and what this sweep
            // needs is the card's own fill and boundary resolving per theme, which
            // it paints from its content alone. Same fixture as
            // `appearance.inboxHoverCard`, including the mismatch line, so both
            // halves of the census see the same card.
            AdoptedSurface(id: "inboxHoverCard", size: NSSize(width: 360, height: 220), make: {
                let card = InboxHoverCardView(frame: .zero)
                card.apply(
                    title: "Stop the camera resizing every tile view",
                    lines: [
                        .init(symbol: "folder", text: "Array"),
                        .init(symbol: "square.grid.2x2", text: "Sidebar"),
                        .init(symbol: "desktopcomputer", text: "This Mac"),
                        .init(symbol: "arrow.triangle.branch", text: "agent/retained-world-plane"),
                        .init(symbol: "exclamationmark.triangle.fill",
                              text: "Checked out on main", isWarning: true),
                        .init(symbol: "terminal", text: "Claude Code"),
                        .init(symbol: "cpu", text: "openai-codex/gpt-5.6-sol"),
                    ])
                return card
            }),
            AdoptedSurface(id: "noteTile", size: NSSize(width: 480, height: 320), make: {
                NoteTileNSView(
                    tile: canned(kind: .note, title: "release notes"),
                    noteId: UUID(uuidString: "00000000-0000-0000-0000-0000000011A1")!,
                    initialBody: "ship the palette")
            }),
            // No `filePath`, so `loadFile` takes the unavailable branch and the
            // lazily-built placeholder is in the tree — the one surface a token
            // adoption is easiest to forget.
            AdoptedSurface(id: "fileTile", size: NSSize(width: 480, height: 320), make: {
                FileTileNSView(tile: canned(kind: .file, title: "Package.swift"))
            }),
            AdoptedSurface(id: "runArtifactsTile", size: NSSize(width: 480, height: 320), make: {
                RunArtifactsTileNSView(tile: canned(kind: .runArtifacts, title: "run-1"))
            }),
            AdoptedSurface(id: "diffReviewTile", size: NSSize(width: 640, height: 360), make: {
                DiffReviewTileNSView(tile: canned(kind: .diffReview, title: "working tree"), model: cannedDiff())
            }),
            // The `recoverableErrorMessage` constructor: builds the whole tree
            // (search field, banner, outline, state container) and starts no
            // filesystem watcher.
            // Real ROWS, one per `FileTreeGitStatus` plus an ignored path, so
            // `outlineView(_:viewFor:)`'s row text and all six badge accents are
            // actually painted. The negative test proved this matters: with the
            // error-state fixture alone, putting the row text back on
            // `secondaryLabelColor` did not turn the gate red.
            AdoptedSurface(id: "fileTreeTile", size: NSSize(width: 480, height: 420), make: {
                let view = FileTreeTileNSView(
                    tile: canned(kind: .fileTree, title: "continuum"), fileTreeTile: treeState,
                    recoverableErrorMessage: "root is not readable")
                view.applySnapshotForQA(cannedFileTree())
                return view
            }),
            // Provider>model picker (t3 port): the two-pane surface with a
            // selected provider, so the container (composer fill + hairline
            // divider + focus-ring indicator) and a rail button's rowSelected
            // fill all actually paint under this gate.
            AdoptedSurface(id: "providerModelPicker", size: NSSize(width: 320, height: 200), make: {
                ProviderModelPickerView(
                    items: [
                        ChoiceItem(id: "openai-codex/gpt-a", title: "gpt-a"),
                        ChoiceItem(id: "anthropic/claude-x", title: "claude-x"),
                    ],
                    selectedID: "anthropic/claude-x")
            }),
            AdoptedSurface(id: "canvas", size: NSSize(width: 700, height: 480), make: {
                CanvasNSView(canvasState: CanvasState(
                    viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                    tiles: [], groups: [], lastActiveTileId: nil))
            }),
            AdoptedSurface(
                id: "sidebar", size: NSSize(width: 280, height: 520),
                make: {
                    let view = WorkspaceSidebarView(frame: .zero)
                    view.reload(tree: LabFixtures.sidebarTree(), currentWorkspaceId: LabFixtures.workspaceId)
                    // P3.6: the sidebar's content is the inbox, and an EMPTY inbox owns
                    // no row cards — so `AgentInboxCardView` would be an adopted owner
                    // this gate never sees paint, which it is right to call out.
                    view.reloadInbox(rows: LabFixtures.inboxRows())
                    return view
                },
                // 94/P1.2 extends P3.6's reason one step. A row at REST now paints
                // no fill at all, so rows alone are no longer enough: with none of
                // them selected, `AgentInboxCardView` owns no colour slot and the
                // adopted-owner census reports it as "painted nothing in the probed
                // surfaces". Selecting one row is what puts the ladder's fill under
                // this gate — and it is the same state `appearance.agentInbox`
                // renders in the sentinel sweep, for the same reason.
                prepare: { root in
                    guard let sidebar = root as? WorkspaceSidebarView,
                          let id = LabFixtures.inboxRows().first?.id else { return }
                    _ = sidebar.inboxForQA.selectRowForQA(id: id)
                    root.layoutSubtreeIfNeeded()
                }
            ),
            AdoptedSurface(id: "topBar", size: NSSize(width: 900, height: 44), make: {
                let view = WorkspaceTopBarView(frame: .zero)
                view.reload(LabFixtures.topBarModel(save: .saveFailed, message: "disk full"))
                return view
            })
        ]
    }

    // MARK: - 5 · The ticket's Goal, as a number
    //
    // "Tile edges are visibly distinct from the canvas (≥3:1, asserted)."
    //
    // Measured off the REAL rendered views — the tile's `layer.borderColor` and the
    // canvas's `layer.backgroundColor` — not off the token declarations, which
    // `DesignTokenChecks` already covers. That distinction is the point: this is
    // what catches the edge being painted from somewhere other than the palette,
    // or the canvas and the tile disagreeing about which theme they are in.
    //
    // The witness is the defect itself: white@0.25 on white@0.10, the pair the
    // ticket opens with, must FAIL the same assertion at the 1.68:1 it was measured
    // at. So the assertion cannot rot into something the old code would have passed.
    private static func runTileEdgeContrastCheck() throws -> [String] {
        func chip(_ color: CGColor?) throws -> ChipColor {
            guard let color, let srgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else {
                throw fail("tile-edge contrast: a probed layer colour was nil or not convertible to sRGB")
            }
            return ChipColor(r: srgb.redComponent, g: srgb.greenComponent, b: srgb.blueComponent)
        }

        var measurements: [String] = []
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let theme: TokenTheme = appearanceName == .darkAqua ? .dark : .light
            let tile = canned(kind: .note, title: "edge contrast")
            let probe = try UIProbe.render(
                UIProbe.Spec(
                    id: "appearance.tileEdge.\(appearanceName.rawValue)",
                    size: NSSize(width: 700, height: 480), appearance: appearanceName
                ),
                make: {
                    let canvas = CanvasNSView(canvasState: CanvasState(
                        viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
                        tiles: [tile], groups: [], lastActiveTileId: nil))
                    canvas.install(
                        tileView: NoteTileNSView(
                            tile: tile,
                            noteId: UUID(uuidString: "00000000-0000-0000-0000-0000000011B1")!,
                            initialBody: "body"),
                        for: tile)
                    return canvas
                }
            )
            probe.host.layoutSubtreeIfNeeded()
            guard let tileView = firstDescendant(NoteTileNSView.self, in: probe.view) else {
                throw fail("tile-edge contrast: the installed tile is not in the rendered canvas")
            }
            guard (tileView.layer?.borderWidth ?? 0) > 0 else {
                throw fail("tile-edge contrast: the tile's borderWidth is 0, so it paints no edge at all — the 1.68:1 defect became a 0-pixel one")
            }
            let edge = try chip(tileView.layer?.borderColor)
            let canvasFill = try chip(probe.view.layer?.backgroundColor)
            let ratio = WCAGContrast.ratio(edge, canvasFill)
            guard ratio >= DesignTokens.lineFloor else {
                throw fail(String(format: "tile-edge contrast: the tile's outline measures %.2f:1 against the canvas in %@, floor is %.2f — this IS the \"canvas looks like mush\" defect", ratio, theme.rawValue, DesignTokens.lineFloor))
            }
            // The edge must be the palette's, not merely contrasty.
            let want = hex(LineToken.borderStrong.color.cgColor(for: theme))
            let got = hex(tileView.layer?.borderColor)
            guard got == want else {
                throw fail("tile-edge contrast: the tile's outline is \(got) in \(theme.rawValue), borderStrong's leaf is \(want)")
            }
            measurements.append(String(format: "%@ %.2f:1", theme.rawValue, ratio))
            restoreAppPin()
        }

        // The witness, executed rather than described.
        let shippedEdge = ChipColor(r: 0.25, g: 0.25, b: 0.25)
        let shippedBody = ChipColor(r: 0.10, g: 0.10, b: 0.10)
        let shippedRatio = WCAGContrast.ratio(shippedEdge, shippedBody)
        guard shippedRatio < DesignTokens.lineFloor else {
            throw fail(String(format: "the pre-ticket white@0.25-on-white@0.10 edge measures %.2f:1, which clears the %.2f floor — the assertion above cannot be discriminating", shippedRatio, DesignTokens.lineFloor))
        }
        guard shippedRatio > 1.60, shippedRatio < 1.75 else {
            throw fail(String(format: "the pre-ticket edge pair measures %.2f:1; the ticket and P1.3's provenance both record 1.68:1 — one of them is now wrong", shippedRatio))
        }
        measurements.append(String(format: "witness (pre-ticket white@0.25 on white@0.10) %.2f:1 < %.2f", shippedRatio, DesignTokens.lineFloor))
        return measurements
    }

    // MARK: - 5b · The descriptor tile's eleven fills (P1.11's one deviation)
    //
    // The packet asked to "keep the eleven descriptor fills semantically distinct but
    // derive them from the token set". Those two cannot both hold: the palette
    // declares eleven surfaces, but only `tileBody`/`tileChrome` are legal as a tile
    // BODY, and painting a tile in `canvas` or in a transcript-card tint gives it a
    // fill whose documented pairs it does not honour. So the fill became `tileBody`
    // for every kind and the per-kind distinction moved onto TYPE.
    //
    // The cross-review's objection is fair — a specified channel was removed — so it
    // is not left to prose. This check asserts, every run:
    //
    //   a · The evidence that the fill channel was never carrying the distinction:
    //       the WIDEST of the 55 pairwise ratios among the eleven retired literals is
    //       1.13:1, and 46 of the 55 are under 1.10:1. (1.13:1 is roughly the
    //       difference between two shades of the same near-black; 3.0 is the floor
    //       the palette holds a mere OUTLINE to.)
    //   b · The reason they could not simply be tokenised in place: every one of the
    //       eleven has a relative luminance under 0.2, i.e. they are dark-only, so
    //       under Aqua all eleven were the black-on-dark defect.
    //   c · That the channel the distinction moved TO actually carries it: the eleven
    //       `TileKind.displayName`s are pairwise distinct, and the title bar gives
    //       that text real room at a normal tile width.
    //   d · That all ELEVEN kinds — not one sampled kind — paint a legal token fill
    //       in both appearances.
    //
    // If a future palette grows a family of legal tile-body tints, (a) and (b) are
    // the measurements that say what the replacement has to beat.

    /// The eleven retired per-`TileKind` literals, in the order they were declared.
    /// Raw on purpose: this is a witness surface, and a value here is diffable
    /// against the deleted line it came from.
    private static let retiredDescriptorFills: [(kind: TileKind, color: ChipColor)] = [
        (.terminal, ChipColor(r: 0.10, g: 0.13, b: 0.18)),
        (.browser, ChipColor(r: 0.13, g: 0.17, b: 0.20)),
        (.browserInspector, ChipColor(r: 0.10, g: 0.16, b: 0.19)),
        (.note, ChipColor(r: 0.18, g: 0.16, b: 0.10)),
        (.file, ChipColor(r: 0.12, g: 0.18, b: 0.13)),
        (.fileTree, ChipColor(r: 0.15, g: 0.13, b: 0.20)),
        (.ticketQueue, ChipColor(r: 0.11, g: 0.15, b: 0.22)),
        (.conductorQueue, ChipColor(r: 0.10, g: 0.14, b: 0.18)),
        (.diffReview, ChipColor(r: 0.16, g: 0.12, b: 0.18)),
        (.runArtifacts, ChipColor(r: 0.12, g: 0.15, b: 0.18)),
        (.managedAgent, ChipColor(r: 0.10, g: 0.13, b: 0.17))
    ]

    private static func runDescriptorTileFillCheck() throws -> String {
        // Every kind must be accounted for, so shrinking `TileKind` cannot leave the
        // evidence table silently partial.
        let covered = Set(retiredDescriptorFills.map(\.kind))
        guard covered == Set(TileKind.allCases) else {
            throw fail("the retired-descriptor-fill table covers \(covered.count) of \(TileKind.allCases.count) TileKinds — add the missing kind(s) with the literal that was deleted, or this evidence is partial")
        }

        // a · the fill channel was never distinguishing anything.
        var ratios: [Double] = []
        for i in retiredDescriptorFills.indices {
            for j in retiredDescriptorFills.indices where j > i {
                ratios.append(WCAGContrast.ratio(retiredDescriptorFills[i].color, retiredDescriptorFills[j].color))
            }
        }
        guard ratios.count == 55 else { throw fail("expected 55 pairwise ratios over 11 fills, computed \(ratios.count)") }
        guard let worst = ratios.max(), worst < 1.20 else {
            throw fail(String(format: "the widest pairwise ratio among the retired descriptor fills is %.2f:1, which is at or above 1.20 — the fills WERE distinguishable and collapsing them onto one surface lost real information", ratios.max() ?? 0))
        }
        _ = worst
        let nearIdentical = ratios.filter { $0 < 1.10 }.count
        guard nearIdentical >= 46 else {
            throw fail("only \(nearIdentical) of 55 retired-fill pairs are under 1.10:1; the measurement recorded with this ticket is 46 — re-measure before trusting the deviation")
        }

        // b · and they were dark-only, so they could not be kept as-is.
        for entry in retiredDescriptorFills {
            let luminance = WCAGContrast.relativeLuminance(entry.color)
            guard luminance < 0.2 else {
                throw fail(String(format: "retired fill for '%@' has luminance %.3f — it is not dark-only, so 'all eleven were black-on-dark under Aqua' is no longer true", entry.kind.rawValue, luminance))
            }
        }

        // c · the channel the distinction moved to.
        let names = TileKind.allCases.map(\.displayName)
        guard Set(names).count == names.count else {
            throw fail("TileKind.displayName is not pairwise distinct (\(names.joined(separator: ", "))) — the descriptor tile now carries its kind in TEXT, so two kinds sharing a name means the distinction is gone for real")
        }

        // d · all eleven kinds paint a legal token fill, both appearances.
        var fills = 0
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let theme: TokenTheme = appearanceName == .darkAqua ? .dark : .light
            let legal = legalValues(for: .background, theme: theme)
            for kind in TileKind.allCases {
                let probe = try UIProbe.render(
                    UIProbe.Spec(
                        id: "appearance.descriptorFill.\(kind.rawValue).\(appearanceName.rawValue)",
                        size: NSSize(width: 420, height: 260), appearance: appearanceName
                    ),
                    make: { DescriptorTileNSView(tile: canned(kind: kind, title: "placeholder")) }
                )
                probe.host.layoutSubtreeIfNeeded()
                guard let tile = firstDescendant(DescriptorTileNSView.self, in: probe.view) else {
                    throw fail("descriptor fill: the tile for '\(kind.rawValue)' is not in the rendered tree")
                }
                guard let body = tile.qaTokenPaintedLayers.first else {
                    throw fail("descriptor fill: the tile for '\(kind.rawValue)' hands over no painted layer")
                }
                let value = hex(body.layer.backgroundColor)
                guard legal.contains(value) else {
                    throw fail("descriptor fill: '\(kind.rawValue)' painted \(value) in \(theme.rawValue), which is not a DesignTokens surface for that theme")
                }
                // The kind still has somewhere to be read from.
                guard let title = tile.qaTitleRect, title.width > 0 else {
                    throw fail("descriptor fill: '\(kind.rawValue)' has no room for its title, which is now the ONLY channel carrying the kind")
                }
                fills += 1
                restoreAppPin()
            }
        }
        return String(format: "11 descriptor kinds x 2 appearances = %d token fills; retired literals' widest pairwise ratio %.2f:1 (%d of 55 under 1.10:1), all 11 dark-only", fills, ratios.max() ?? 0, nearIdentical)
    }

    // MARK: - 6 · The title bar's status pill must clear the drag handle
    //
    // The `-58` this ticket replaced was an undocumented dependency on the close
    // button plus the drag-dot cluster: a static inset against two values that both
    // scale with zoom. P1.10 recorded the visible consequence (the pill overlapping
    // at 320pt). Now that the inset is DERIVED from both live terms, this asserts the
    // property the derivation exists for, across the widths and chrome scales a tile
    // really reaches — including the `TileGeometry` minimum and a zoomed-out bar.
    /// Driven through a real `CanvasNSView` at a real viewport zoom rather than by
    /// resizing the bar by hand — the close button's world size AND the bar's height
    /// are both `max(constant, screenFloor / zoom)` read off `canvas?.viewport.zoom`,
    /// so only the production path produces the low-zoom geometry the derivation
    /// exists for. The first version of this check set the bar's frame directly; at
    /// chrome scale 1 the old literal `58` still cleared the dots, so it could not
    /// tell the derived inset from the magic number. At zoom 0.35 it can.
    private static func runTitleBarPillLayoutCheck() throws -> (asserted: Int, suppressed: Int) {
        var asserted = 0
        var suppressed = 0
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            // 1.0 is the identity case; 0.35 is the low end of the zoom range, where
            // the close button's 22px screen floor makes it 63 world points wide and
            // the drag-dot cluster moves a long way left.
            for zoom in [1.0, 0.6, 0.35] {
                // 180 is the width of the descriptor tiles inside a zone card — the
                // ones whose baseline showed the pill printed over the title. It is
                // narrower than any `TileGeometry` minimum, so it has to be listed.
                for width in [180.0, Double(TileGeometry.minimumSize(for: .managedAgent).width), 480, 900] {
                    let tile = Tile(
                        id: UUID(uuidString: "00000000-0000-0000-0000-0000000011C1")!,
                        kind: .managedAgent, title: "a fairly long agent tile title",
                        frame: TileFrame(x: 0, y: 0, width: width, height: 320),
                        zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata()
                    )
                    let tileView = DescriptorTileNSView(tile: tile)
                    let probe = try UIProbe.render(
                        UIProbe.Spec(
                            id: "appearance.pillLayout.\(Int(width)).z\(Int(zoom * 100)).\(appearanceName.rawValue)",
                            size: NSSize(width: 1000, height: 700), appearance: appearanceName
                        ),
                        make: {
                            let canvas = CanvasNSView(canvasState: CanvasState(
                                viewport: CanvasViewport(x: 0, y: 0, zoom: zoom),
                                tiles: [tile], groups: [], lastActiveTileId: nil))
                            canvas.install(tileView: tileView, for: tile)
                            return canvas
                        }
                    )
                    for status in AgentStatus.allCases {
                        // Set the status BEFORE laying out: the title's available width
                        // is a function of where the pill lands.
                        tileView.agentStatus = status
                        probe.host.layoutSubtreeIfNeeded()
                        tileView.layoutSubtreeIfNeeded()
                        guard let dots = tileView.qaDragHandleLeadingX,
                              let title = tileView.qaTitleRect else {
                            throw fail("pill layout: the tile has no title bar")
                        }
                        // `nil` means the pill was SUPPRESSED because it could not fit
                        // — the intended low-zoom outcome. Assert that the title then
                        // gets the room instead, so suppression cannot become a way to
                        // pass this check by drawing nothing at all.
                        guard let pill = tileView.qaStatusPillRect(for: status) else {
                            suppressed += 1
                            guard title.maxX <= dots else {
                                throw fail("pill layout: at width \(Int(width)), zoom \(zoom), status '\(status.rawValue)' the pill is suppressed but the title still runs to x=\(String(format: "%.1f", title.maxX)) past the drag dots at x=\(String(format: "%.1f", dots))")
                            }
                            continue
                        }
                        let context = String(format: "width %.0f, zoom %.2f, status '%@'", width, zoom, status.rawValue)
                        guard pill.maxX <= dots else {
                            throw fail("pill layout: at \(context) the pill ends at x=\(String(format: "%.1f", pill.maxX)) but the drag dots start at x=\(String(format: "%.1f", dots)) — the pill is under the handle")
                        }
                        guard pill.minX >= 0, pill.minY >= 0 else {
                            throw fail("pill layout: at \(context) the pill rect \(pill) leaves the bar")
                        }
                        // The defect the P0.6 baselines caught on the ~180pt tiles
                        // inside a zone card: the title drew straight under the pill.
                        //
                        // A ZERO-width title rect is exempt because it paints no
                        // glyphs. That case is real and is the intended outcome: on a
                        // 180pt tile at zoom 0.6 the pill alone needs ~96 world points
                        // and clamps to the leading inset, so there is no room for a
                        // name at all. The status wins there — which is right, and is
                        // strictly better than the two overprinting each other.
                        guard title.width == 0 || title.maxX <= pill.minX else {
                            throw fail("pill layout: at \(context) the title runs to x=\(String(format: "%.1f", title.maxX)) but the pill starts at x=\(String(format: "%.1f", pill.minX)) — the pill is drawn over the tile title")
                        }
                        asserted += 1
                    }
                    restoreAppPin()
                }
            }
        }
        // Both outcomes have to actually occur, or one branch is untested.
        guard asserted > 0, suppressed > 0 else {
            throw fail("pill layout: \(asserted) drawn and \(suppressed) suppressed placements — both branches must be exercised, so the width/zoom sweep no longer covers one of them")
        }
        return (asserted, suppressed)
    }

    // MARK: - Entry point

    /// P3.3: assistant prose inherits tileBody instead of painting a card. The
    /// same real renderer view is updated across both themes so stale text color
    /// and accidental layer decoration are both observable.
    private static func runAssistantProseAppearanceCheck() throws -> Int {
        let block = AgentBlock(
            id: AgentNodeID(rawValue: "appearance-assistant-prose")!, revision: 1, kind: .paragraph,
            payload: .paragraph([.text("A quiet selectable assistant response")])
        )
        let renderer = AssistantProseRenderer(kind: .paragraph)
        guard let view = renderer.makeView() as? AssistantProseView else {
            throw fail("assistant prose renderer did not vend AssistantProseView")
        }
        var assertions = 0
        for theme in [TokenTheme.light, .dark] {
            let context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: theme)
            renderer.update(view: view, block: block, context: context)
            renderer.updateAccessibility(view: view, block: block, context: context)
            guard view.layer == nil, !view.wantsLayer else {
                throw fail("assistant prose paints a layer instead of inheriting tileBody in \(theme)")
            }
            guard view.textFields.count == 1, let field = view.textFields.first,
                  field.isSelectable, !field.isBordered, !field.drawsBackground else {
                throw fail("assistant prose added title/card chrome or lost selectable text in \(theme)")
            }
            let actual = field.textColor?.usingColorSpace(.sRGB)
            let expected = TextToken.textPrimary.color.nsColor(for: theme).usingColorSpace(.sRGB)
            guard actual == expected else {
                throw fail("assistant prose primary text token mismatch in \(theme)")
            }
            assertions += 3
        }
        return assertions
    }

    /// P3.5: semantic inline runs resolve into one native selectable text layout.
    /// This checks nested traits, safe/display-only links, theme repainting, and
    /// both pasteboard representations without involving a Markdown parser.
    private static func runRichInlineTextCheck() throws -> Int {
        let blockID = AgentNodeID(rawValue: "appearance-rich-inline")!
        let runs: [AgentInline] = [
            .text("plain "),
            .strong([.text("bold "), .emphasis([.text("italic")])]),
            .text(" "), .code("code"), .text(" "),
            .link(destination: "https://example.com/docs", title: "Docs", children: [.text("safe")]),
            .text(" "),
            .link(destination: "file:///Users/example/private.txt", title: nil, children: [.text("local")]),
            .hardBreak, .text("next"), .softBreak, .text("soft")
        ]
        var activated: [URL] = []
        var localFiles: [String] = []
        let actions = AgentRenderActions { action in
            if case let .activateLink(_, url) = action { activated.append(url) }
            if case let .openLocalFile(_, destination) = action { localFiles.append(destination) }
        }
        let lightContext = AgentRenderContext(actions: actions, tokens: .transcript, appearance: .light)
        let view = RichInlineTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 100))
        view.apply(runs: runs, blockID: blockID, context: lightContext)

        guard view.isSelectable, !view.isEditable, !view.drawsBackground,
              view.string == "plain bold italic code safe local\nnext soft" else {
            throw fail("rich inline text lost native selection or semantic visible text")
        }
        let attributed = view.textStorage!
        let boldIndex = (view.string as NSString).range(of: "bold").location
        let italicIndex = (view.string as NSString).range(of: "italic").location
        let codeIndex = (view.string as NSString).range(of: "code").location
        guard let boldFont = attributed.attribute(.font, at: boldIndex, effectiveRange: nil) as? NSFont,
              boldFont.fontDescriptor.symbolicTraits.contains(.bold),
              let italicFont = attributed.attribute(.font, at: italicIndex, effectiveRange: nil) as? NSFont,
              italicFont.fontDescriptor.symbolicTraits.contains([.bold, .italic]),
              let codeFont = attributed.attribute(.font, at: codeIndex, effectiveRange: nil) as? NSFont,
              codeFont.isFixedPitch,
              attributed.attribute(.backgroundColor, at: codeIndex, effectiveRange: nil) != nil else {
            throw fail("rich inline nested strong/emphasis/code traits did not compose")
        }
        guard view.linkRanges.count == 2,
              view.linkRanges[0].disposition == .openExternally,
              view.linkRanges[1].disposition == .openLocalFile,
              view.activateLink(at: view.linkRanges[0].range.location),
              view.activateLink(at: view.linkRanges[1].range.location),
              activated.map(\URL.absoluteString) == ["https://example.com/docs"],
              localFiles == ["file:///Users/example/private.txt"] else {
            throw fail("rich inline link witness: a local file must request host resolution with its raw destination and never become a URL action, and an https link must stay a URL action")
        }

        let lightColor = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let originalRanges = view.linkRanges
        view.applyTheme(.dark)
        let darkColor = view.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        guard lightColor?.usingColorSpace(.sRGB) != darkColor?.usingColorSpace(.sRGB),
              view.linkRanges == originalRanges,
              view.string == "plain bold italic code safe local\nnext soft" else {
            throw fail("rich inline theme repaint changed semantic output or retained stale colors")
        }

        let fullMarkdown = "plain **bold *italic*** `code` [safe](https://example.com/docs \"Docs\") [local](file:///Users/example/private.txt)  \nnext\nsoft"
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        view.copy(nil)
        guard NSPasteboard.general.string(forType: .string) == fullMarkdown,
              NSPasteboard.general.string(forType: RichInlineTextView.markdownPasteboardType) == fullMarkdown else {
            throw fail("rich inline copy did not put normalized Markdown on both pasteboard string types")
        }

        let partial = (view.string as NSString).range(of: "old italic code sa")
        view.setSelectedRange(partial)
        view.copy(nil)
        guard NSPasteboard.general.string(forType: .string) == "**old *italic*** `code` [sa](https://example.com/docs \"Docs\")",
              NSPasteboard.general.string(forType: RichInlineTextView.markdownPasteboardType) ==
                "**old *italic*** `code` [sa](https://example.com/docs \"Docs\")" else {
            throw fail("rich inline partial selection lost Markdown on public string pasteboard type")
        }
        view.stringPasteboardStyle = .plainText
        view.copy(nil)
        guard NSPasteboard.general.string(forType: .string) == "old italic code sa",
              NSPasteboard.general.string(forType: RichInlineTextView.markdownPasteboardType) ==
                "**old *italic*** `code` [sa](https://example.com/docs \"Docs\")" else {
            throw fail("rich inline explicit plain-text copy path did not remain available")
        }
        return 10
    }

    /// P3.4: the user role is a quiet Continuum surface, with authorship in the
    /// accessibility tree rather than a permanent visual metadata row.
    private static func runUserPromptAppearanceCheck() throws -> Int {
        let block = AgentBlock(
            id: AgentNodeID(rawValue: "appearance-user-prompt")!, revision: 1, kind: .paragraph,
            payload: .paragraph([.text("A selectable user prompt without a speaker caption")])
        )
        let renderer = UserPromptRenderer(kind: .paragraph)
        guard let view = renderer.makeView() as? UserPromptView else {
            throw fail("user prompt renderer did not vend UserPromptView")
        }
        let assistant = AssistantProseRenderer(kind: .paragraph).makeView()
        var assertions = 0
        for theme in [TokenTheme.light, .dark] {
            let context = AgentRenderContext(actions: .disabled, tokens: .transcript, appearance: theme)
            renderer.update(view: view, block: block, context: context)
            renderer.updateAccessibility(view: view, block: block, context: context)

            let actualFill = view.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB)
            let expectedFill = UserPromptView.fillToken.color.nsColor(for: theme).usingColorSpace(.sRGB)
            guard actualFill == expectedFill, view.layer?.borderWidth == 0 else {
                throw fail("user prompt quiet fill/outline mismatch in \(theme)")
            }
            guard view.layer?.cornerRadius == UserPromptView.cornerRadius,
                  UserPromptView.cornerRadius == CGFloat(AgentTileRadius.artifact) else {
                throw fail("user prompt did not use the semantic artifact radius role")
            }
            guard view.accessibilityRole() == .group, view.accessibilityLabel() == "You",
                  assistant.accessibilityLabel() == nil else {
                throw fail("user and assistant entries are not distinguishable without color in \(theme)")
            }
            guard view.proseView.textFields.count == 1, let field = view.proseView.textFields.first,
                  field.isSelectable, !field.isBordered, !field.drawsBackground,
                  field.stringValue == "A selectable user prompt without a speaker caption" else {
                throw fail("user prompt added visual title/status chrome or lost selectable semantic text in \(theme)")
            }
            let actualText = field.textColor?.usingColorSpace(.sRGB)
            let expectedText = TextToken.textPrimary.color.nsColor(for: theme).usingColorSpace(.sRGB)
            guard actualText == expectedText else {
                throw fail("user prompt primary text token mismatch in \(theme)")
            }
            assertions += 5
        }
        return assertions
    }

    /// P3.12: the complete review surface must actually carry light/dark tokens
    /// through the production transcript host, not only through isolated renderers.
    private static func runTranscriptReviewAppearanceCheck() throws -> Int {
        func descendants(in view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        var digests: [String] = []
        var assertions = 0
        for (appearance, theme) in [
            (NSAppearance.Name.aqua, TokenTheme.light),
            (.darkAqua, .dark),
        ] {
            let size = NSSize(width: 480, height: 720)
            let label = "semantic-transcript-review-\(UITourCheck.shortName(appearance))"
            let probe = try UIProbe.render(
                UIProbe.Spec(id: label, size: size, appearance: appearance)
            ) {
                LabCatalog.makeTranscriptReviewSurface(state: .mixed, size: size, theme: theme)
            }
            guard let surface = probe.view as? AgentTranscriptReviewSurface else {
                throw fail("\(label) did not vend AgentTranscriptReviewSurface")
            }
            let views = descendants(in: surface)
            let expectedBackground = SurfaceToken.tileBody.color.nsColor(for: theme).usingColorSpace(.sRGB)
            let actualBackground = surface.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB)
            let contrast = try UIProbeContrast.evaluate(probe)
            guard surface.renderError == nil,
                  surface.effectiveAppearance.name == appearance,
                  actualBackground == expectedBackground,
                  views.contains(where: { $0 is UserPromptView }),
                  views.contains(where: { $0 is AssistantProseView }),
                  !views.contains(where: { $0 is NSPopUpButton }),
                  contrast.measured > 0,
                  contrast.failures.isEmpty else {
                throw fail(
                    "\(label) lost theme, semantic prose roles, custom-only controls, or contrast: "
                        + contrast.failures.joined(separator: "; ")
                )
            }
            let assistant = views.compactMap { $0 as? AssistantProseView }.first
            let user = views.compactMap { $0 as? UserPromptView }.first
            guard assistant?.wantsLayer == false,
                  assistant?.layer?.backgroundColor == nil,
                  assistant?.layer?.borderWidth == 0,
                  user?.layer?.borderWidth == 0,
                  user?.accessibilityLabel() == "You" else {
                throw fail(
                    "\(label) quiet hierarchy mismatch: assistant layer \(String(describing: assistant?.layer)), "
                        + "wantsLayer \(String(describing: assistant?.wantsLayer)), user border "
                        + "\(String(describing: user?.layer?.borderWidth)), label \(String(describing: user?.accessibilityLabel()))"
                )
            }
            digests.append(probe.hostDigest)
            assertions += 11
        }
        guard Set(digests).count == 2 else {
            throw fail("semantic transcript review surface rendered identical light/dark pixels")
        }
        return assertions
    }

    /// P4.1: the composer keeps native NSTextView behavior under custom chrome,
    /// binds editing state through a draft value, and exposes distinct empty,
    /// focused, and selected-text states in both appearances.
    private static func runComposerShellAppearanceCheck() throws -> Int {
        func descendants(in view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        func expectCustomChrome(_ composer: AgentComposerView, label: String) throws {
            guard composer.scrollView.borderType == .noBorder,
                  !composer.scrollView.drawsBackground,
                  !composer.textView.drawsBackground,
                  !descendants(in: composer).contains(where: { $0 is NSPopUpButton }),
                  descendants(in: composer).compactMap({ $0 as? NSTextField }).allSatisfy({ !$0.isBezeled }) else {
                throw fail("\(label) exposed stock scroll, popup, or bezel chrome")
            }
        }
        var assertions = 0
        for (appearance, theme) in [
            (NSAppearance.Name.aqua, TokenTheme.light),
            (.darkAqua, .dark),
        ] {
            let label = "composer-shell-\(UITourCheck.shortName(appearance))"
            let probe = try UIProbe.render(
                UIProbe.Spec(id: label, size: NSSize(width: 480, height: 72), appearance: appearance)
            ) {
                AgentComposerView(frame: NSRect(x: 0, y: 0, width: 480, height: 72))
            }
            guard let composer = probe.view as? AgentComposerView else {
                throw fail("\(label) did not vend AgentComposerView")
            }
            probe.host.layoutSubtreeIfNeeded()

            try expectCustomChrome(composer, label: label)
            guard composer.qaPlaceholderVisible,
                  composer.textView.isEditable,
                  composer.textView.isSelectable,
                  composer.textView.allowsUndo,
                  composer.textView.accessibilityRole() == .textArea,
                  composer.textView.accessibilityLabel() == "Agent prompt",
                  !composer.scrollView.hasVerticalScroller,
                  composer.textView.frame.width > 0,
                  composer.textView.frame.height >= composer.scrollView.contentSize.height,
                  composer.layer?.cornerRadius == AgentComposerView.cornerRadius,
                  composer.layer?.borderWidth == AgentComposerView.idleBorderWidth,
                  composer.layer?.backgroundColor == AgentSurfaceRole.composer.color.cgColor(for: theme),
                  composer.layer?.borderColor == AgentLineRole.decorativeHairline.color.cgColor(for: theme) else {
                throw fail("\(label) lost the empty custom shell, native text area, or quiet token surface")
            }
            assertions += 18

            // Required negative witness: mutate the final composer instance back to
            // stock scroll chrome and prove the same production assertion turns red.
            composer.scrollView.borderType = .bezelBorder
            var stockChromeWitness: String?
            do {
                try expectCustomChrome(composer, label: "\(label).stockChromeWitness")
            } catch let error as AppearanceError {
                stockChromeWitness = error.message
            }
            composer.scrollView.borderType = .noBorder
            guard let stockChromeWitness, stockChromeWitness.contains("exposed stock scroll") else {
                throw fail("\(label) stock-scroll negative witness did not fail the custom-chrome assertion")
            }
            assertions += 1

            var observed: [AgentComposerDraft] = []
            composer.onDraftChange = { observed.append($0) }
            composer.apply(AgentComposerDraft(
                text: "Select this prompt", selection: NSRange(location: 7, length: 4), revision: 40
            ))
            guard !composer.qaPlaceholderVisible,
                  composer.textView.string == "Select this prompt",
                  composer.textView.selectedRange() == NSRange(location: 7, length: 4),
                  observed.isEmpty,
                  composer.draft.revision == 40,
                  composer.textView.selectedTextAttributes[.backgroundColor] as? NSColor
                    == AgentSurfaceRole.rowSelected.color.nsColor(for: theme) else {
                throw fail("\(label) draft binding or selected-text state did not survive model application")
            }
            assertions += 6

            guard probe.window.makeFirstResponder(composer.textView), composer.isEditorFocused,
                  composer.layer?.borderWidth == AgentComposerView.focusedBorderWidth,
                  composer.layer?.borderColor == AgentLineRole.focusRing.color.cgColor(for: theme) else {
                throw fail("\(label) custom focus ring did not replace the quiet decorative boundary")
            }
            assertions += 3

            composer.textView.insertText("edited", replacementRange: composer.textView.selectedRange())
            guard observed.last?.text == "Select edited prompt",
                  observed.last?.selection == composer.textView.selectedRange(),
                  observed.last?.revision == 41 else {
                throw fail("\(label) editing bypassed the draft text/selection/revision binding")
            }
            assertions += 3

            // The probe drives NSTextView synchronously, without the AppKit event
            // boundary that normally closes the preceding typing undo group. Start
            // the paste assertion from the already-verified edited draft so one
            // undo deterministically exercises only the paste operation.
            composer.textView.undoManager?.removeAllActions()
            composer.textView.breakUndoCoalescing()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(" pasted", forType: .string)
            composer.textView.paste(nil)
            guard composer.textView.string == "Select edited pasted prompt",
                  composer.textView.undoManager != nil else {
                throw fail("\(label) native paste or undo manager is unavailable")
            }
            composer.textView.undoManager?.undo()
            guard composer.textView.string == "Select edited prompt" else {
                throw fail("\(label) native undo did not remove only the pasted edit — got '\(composer.textView.string)'")
            }
            assertions += 3

            let manyLines = (1...12).map { "line \($0)" }.joined(separator: "\n")
            composer.apply(AgentComposerDraft(
                text: manyLines, selection: NSRange(location: (manyLines as NSString).length, length: 0), revision: 50
            ))
            let lineHeight = composer.textView.layoutManager?.defaultLineHeight(
                for: composer.textView.font ?? .token(.body)
            ) ?? 17
            guard composer.scrollView.hasVerticalScroller,
                  composer.textView.frame.height > composer.scrollView.contentSize.height,
                  composer.intrinsicContentSize.height <= lineHeight * CGFloat(AgentComposerView.maximumVisibleLines)
                    + (AgentComposerView.internalPadding * 2) else {
                throw fail("\(label) multiline editor did not grow its document or cap the shell at eight visible lines")
            }
            assertions += 2
        }
        return assertions
    }

    /// Called from `UIProbe.runUIProbeChecks` (`--ui-probe-check`).
    static func runAppearanceChecks() throws {
        guard CanvasSymbolImage.qaBitmapContractHolds() else {
            throw fail("canvas SF Symbol freeze lost its shared bitmap-only template contract")
        }
        let composerAssertions = try runComposerShellAppearanceCheck()
        let transcriptReviewAssertions = try runTranscriptReviewAppearanceCheck()
        let proseAssertions = try runAssistantProseAppearanceCheck()
        let richInlineAssertions = try runRichInlineTextCheck()
        let userAssertions = try runUserPromptAppearanceCheck()
        let sweep = try runProductionSweep()
        let hostile = try runHostileCurrentAppearanceCheck()
        let witness = try runTokenFixtureCheck()
        let adoption = try runAdoptedTokenValueCheck()
        print("UIProbeAppearance: \(adoption.assertions) layer colours + \(adoption.foregrounds) non-layer colours across \(adoption.owners) adopted owners hold a DesignTokens value in both appearances (P1.10/P1.11)")
        print("UIProbeAppearance: canvas SF Symbols are shared bitmap-only template images; NSImageView tint is included in the appearance census")
        let edges = try runTileEdgeContrastCheck()
        print("UIProbeAppearance: tile outline vs canvas — \(edges.joined(separator: "; ")) (P1.11 goal)")
        let descriptorFills = try runDescriptorTileFillCheck()
        print("UIProbeAppearance: \(descriptorFills) (P1.11 deviation, evidence pinned)")
        let pills = try runTitleBarPillLayoutCheck()
        print("UIProbeAppearance: \(pills.asserted) title-bar status-pill placements clear the drag handle and the tile title; \(pills.suppressed) suppressed for want of room, title given the space instead (P1.11)")
        guard NSApp?.appearance?.name == .darkAqua else {
            throw fail("appearance checks leaked '\(NSApp?.appearance?.name.rawValue ?? "nil")' onto NSApp")
        }
        print("UIProbeAppearance: \(composerAssertions) custom-composer assertions hold native editing, draft binding, empty/focus/selection states, paste/undo, accessibility, and light/dark tokens; stock-scroll-border mutation was rejected by the final custom-chrome assertion")
        print("UIProbeAppearance: \(transcriptReviewAssertions) semantic-transcript review assertions hold real light/dark propagation, quiet prose hierarchy, accessibility authorship, and custom-only controls")
        print("UIProbeAppearance: \(proseAssertions) assistant-prose assertions hold tileBody inheritance, primary text, selection, and no card chrome in both appearances")
        print("UIProbeAppearance: \(richInlineAssertions) rich-inline assertions hold nested native styles, link policy, theme repaint, and dual-format copy; unsafe-link negative witness remained inactive")
        print("UIProbeAppearance: \(userAssertions) user-prompt assertions hold quiet fill, semantic radius, primary text, selection, no visual metadata, and non-color accessibility authorship in both appearances")
        print("UIProbeAppearance: \(sweep.views) TokenThemed views, \(sweep.slots) layer colours sentinelled and re-applied across a live flip (\(sweep.changed) re-resolved to a different value); \(hostile) hostile-current-appearance assertions held; token fixture holds both leaves; stale-fixture witness failed as required")
        print("UIProbeAppearance: witness message — \(witness)")
    }

    // MARK: - Negative tests observed red with this code (P1.9)
    //
    // 1 · Drop the hook. Delete `viewDidChangeEffectiveAppearance` from
    //     `TranscriptCardView`:
    //       → "appearance.managedAgentTile: 6 layer colour(s) kept the sentinel
    //          across an appearance flip — assigned outside applyTokens():
    //          TranscriptCardView#managedAgent.card.assistant-1.background, …"
    // 2 · Assign outside `applyTokens()`. In `TileNSView.init`, set
    //     `layer?.borderColor` after the `applyTokens()` call instead of inside it:
    //       → the same failure, naming `ManagedAgentTileNSView.border`.
    // 3 · Drop the conformance. `final class TranscriptCardView: NSView` (colours
    //     still re-applied, just no longer enumerable):
    //       → "TokenThemed views never appeared in the sweep: TranscriptCardView"
    // 4 · Resolve against the wrong appearance, either spelling — plain `.cgColor`,
    //     or the `withAlphaComponent(0.92).appResolvedCGColor` form this ticket
    //     found to be broken — in `WorkspaceSidebarView.applyTokens()`:
    //       → "appearance.sidebar.hostile: applyTokens() called with
    //          'NSAppearanceNameDarkAqua' current painted #1E1E1EEB, but the view is
    //          drawing in .aqua and was holding #FFFFFFEB …"
    // 5 · The witness itself: `StaleFixtureView` is asserted to FAIL every run, so
    //     the fixture assertion cannot rot into a tautology.
    //
    // Recorded because the negative test found it: flipping the appearance alone does
    // NOT catch test 4 — AppKit makes the new appearance current while it delivers
    // `viewDidChangeEffectiveAppearance`, so a snapshotting view re-resolves
    // correctly *at that moment*. Check 2b is what makes that case red.

    // MARK: - Negative tests observed red with this code (P1.10)
    //
    // 1 · A literal comes back. In `TranscriptCardView.applyTokens()`:
    //         layer?.backgroundColor = NSColor(red: 0.13, green: 0.15, blue: 0.18, alpha: 1).cgColor
    //     → "TranscriptCardView#managedAgent.card.assistant-1.background painted
    //        #21262EFF in light, which is not a DesignTokens background value for that
    //        theme …"  (and `check-color-hygiene.sh` names the same line
    //        independently — two gates, one defect.)
    // 2 · A real token, pinned to the wrong theme — the shipped black-on-dark bug
    //     shape: `.cgColor(for: .dark)` instead of `.cgColor(in: self)`:
    //     → "… painted #212630FF in light …". This case is why `legalValues` is
    //        scoped by slot KIND: unscoped, `#14171C` is `tileBody` dark *and*
    //        `textPrimary` light, so a pinned fill would have passed.
    // 3 · A real token of the wrong FAMILY — `TextToken.textSecondary` as a card
    //     fill: → "… painted #54585FFF in light …".
    // 4 · The tile's backdrop hand-off shrinks. Drop `composeBackdrop` from
    //     `qaTokenPaintedLayers`: → "sentinelled 25 layer colours, floor is 26".
    // 5 · Drop `viewDidChangeEffectiveAppearance` from `UserInputCardView`:
    //     → "appearance.managedAgentTile: 2 layer colour(s) kept the sentinel across
    //        an appearance flip — assigned outside applyTokens():
    //        UserInputCardView.background, UserInputCardView.border".
    // 6 · An adopted owner leaves the probed tree. Remove the
    //     `openUserInputRequest(in:)` call from check 4:
    //     → "adopted owners that painted nothing in the probed tile:
    //        UserInputCardView — either the surface stopped painting or it left the
    //        tree, and this gate would silently cover less".
    //
    // P1.10's HONEST LIMIT — "it gates layer colours, so a TEXT colour reverting to
    // `.labelColor` is `check-color-hygiene.sh`'s catch, not this gate's" — is CLOSED
    // by P1.11: `foregroundSlots(in:)` reads `NSTextView`/`NSTextField.textColor`,
    // `NSTableView.backgroundColor`, `NSButton.contentTintColor` and every distinct
    // `.foregroundColor` in a text storage, and holds each to the palette.

    // MARK: - Negative tests observed red with this code (P1.11)
    //
    // Every one was run against the FINAL code, reverted, and the tree left green.
    //
    //  1 · The tile edge back to the shipped literal. `TileNSView.applyTokens()`:
    //      `layer?.borderColor = NSColor(white: 0.25, alpha: 1.0).cgColor`
    //      → "ManagedAgentTileNSView.border painted #404040FF in light, which is not a
    //         DesignTokens border value for that theme"
    //  2 · File-tree row text back to Apple's semantic colour:
    //      `view.textField?.textColor = NSColor.secondaryLabelColor`
    //      → "fileTreeTile: NSTextField.textColor is #0000007F in light, which is not a
    //         DesignTokens text/accent value for that theme"
    //      This one is why the file-tree fixture ingests a canned SNAPSHOT: with the
    //      recoverable-error fixture alone the outline has no rows, `viewFor` never
    //      runs, and this edit left the gate GREEN.
    //  3 · A git badge back to its `calibratedRed:` literal
    //      → "… NSTextField.textColor is #5FCE86FF in light …" (and note the value:
    //         calibrated 0.32/0.78/0.45 renders as sRGB #5FCE86, which is the drift
    //         the packet's watch-out #1 is about).
    //  4 · Sidebar tile rows back to `tertiaryLabelColor`
    //      → "sidebar: NSTextField.textColor is #00000042 in light …"
    //  5 · The diff renderer back to `NSColor.systemGreen` for additions
    //      → "diffReviewTile: NSTextView.attributedRun@82 is #34C759FF in light …"
    //      Also a coverage fix found by running it: the diff's six accents live in
    //      ATTRIBUTED RUNS, not in `textColor`, so before the storage walk existed
    //      this edit left the gate green.
    //  6 · The canvas back to `black@0.92`
    //      → "CanvasNSView.background painted #000000EB in light …"
    //  7 · Drop the title's truncation bound (`blockedFrom = bounds.width`)
    //      → "pill layout: at width 180, zoom 0.60, status 'needsAttention' the title
    //         runs to x=176.0 but the pill starts at x=61.0 — the pill is drawn over
    //         the tile title"
    //  8 · `statusPillTrailingInset` back to the bare literal `58`
    //      → "pill layout: at width 180, zoom 0.60, status 'configuring' the pill ends
    //         at x=122.0 but the drag dots start at x=99.3"
    //      Recorded because the FIRST version of the check could not catch this: it
    //      set the bar's frame by hand, and at chrome scale 1 `58` is larger than the
    //      derived inset, so it still cleared. Only driving a real `CanvasNSView` at
    //      zoom 0.6/0.35 — where the close button's 22px screen floor makes it 37/63
    //      world points wide — makes the two distinguishable.
    //  9 · The title bar's fill back to `white:0.16`
    //      → "TitleBarView.background painted #292929FF in light …"
    // 10 · Corner brackets pinned to `.dark` (`cgColor(for: .dark)`)
    //      → "CornerOverlayView.stroke painted #A8B0BDFF in light …"
    // 11 · Drop one `TileKind` from the retired-fill evidence table
    //      → "the retired-descriptor-fill table covers 10 of 11 TileKinds …"
    // 12 · The descriptor body back to a per-kind dark literal
    //      → "DescriptorTileNSView.body.background painted #212B33FF in light …"
    // 13 · The sidebar panel back to `windowBackgroundColor@0.92`
    //      → "WorkspaceSidebarView.background painted #FFFFFFEB in light …"
    //
    // NOT DISCRIMINATING, and recorded so nobody mistakes them for coverage: swapping
    // one legal token for another legal token of the same FAMILY (`accentDone` →
    // `textSecondary` on a git badge) passes. This gate answers "is every painted
    // colour in the palette, resolved for the right theme?" — not "is it the right
    // token?". The latter is what the committed PNG baselines and a human's eye are
    // for, and it is why P1.11's 18 baseline moves were all inspected before blessing.
    //
    // Sizes and paddings are still not covered here — the baselines are what make a
    // re-hardcoded padding or height red, which is exactly how the title-overprint
    // defect in test 7 was found in the first place.
}

private extension UIProbeAppearance.ColorSlot.Kind {
    static var allKinds: [UIProbeAppearance.ColorSlot.Kind] { [.background, .border, .stroke, .fill] }
}
