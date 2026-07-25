import AppKit
import ContinuumRevivedAgentUI

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

    /// Measured on the tree this renders, and printed every run: 8 conforming views
    /// (the tile, its title bar, its corner overlay, 3 transcript cards, the sidebar,
    /// the top bar) owning 19 painted layer colours. Floors rather than equalities,
    /// so a new themed view or an extra card is not a failure — but a view or a
    /// whole surface silently dropping out of the sweep is.
    private static let minimumThemedViews = 8
    private static let minimumSentineledSlots = 19

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
            ("appearance.sidebar", NSSize(width: 280, height: 520), { WorkspaceSidebarView(frame: .zero) }),
            ("appearance.topBar", NSSize(width: 900, height: 44), { WorkspaceTopBarView(frame: .zero) })
        ]
        // Read out of the source, not typed here: every declared conformer must show
        // up in this sweep, so a conformance quietly dropped is red AND a new
        // conformer that nothing renders here is red too.
        var expectedTypes = try declaredConformers()
        var totalViews = 0
        var totalSlots = 0
        var totalChanged = 0
        // The two views whose fill is a system colour: their resolved value has to
        // MOVE with the appearance, not merely be re-assigned.
        var appearanceDependent: [String: (before: String, after: String)] = [:]

        for surface in surfaces {
            let probe = try UIProbe.render(
                UIProbe.Spec(id: surface.id, size: surface.size, appearance: .aqua), make: surface.make
            )
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

            let slots = themed.flatMap(ownedColorSlots(of:))
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
    /// move between appearances. The tile's own literals are appearance-invariant by
    /// construction, so they are not subjects here — P1.10 puts them on tokens.
    private static func runHostileCurrentAppearanceCheck() throws -> Int {
        let subjects: [(id: String, size: NSSize, make: () -> NSView)] = [
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

    // MARK: - Entry point

    /// Called from `UIProbe.runUIProbeChecks` (`--ui-probe-check`).
    static func runAppearanceChecks() throws {
        let sweep = try runProductionSweep()
        let hostile = try runHostileCurrentAppearanceCheck()
        let witness = try runTokenFixtureCheck()
        guard NSApp?.appearance?.name == .darkAqua else {
            throw fail("appearance checks leaked '\(NSApp?.appearance?.name.rawValue ?? "nil")' onto NSApp")
        }
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
}

private extension UIProbeAppearance.ColorSlot.Kind {
    static var allKinds: [UIProbeAppearance.ColorSlot.Kind] { [.background, .border, .stroke, .fill] }
}
