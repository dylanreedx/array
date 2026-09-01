import ContinuumRevivedCore
import CoreGraphics
import Foundation

// WS7 — the pure half of the canvas background witness.
//
// The renderer owns no arithmetic (see `CanvasBackgroundGeometry`), so almost
// everything worth breaking can be broken here, exhaustively, offline, with no
// window: the negative-coordinate phase, the stride hysteresis, the Fill/Fit
// rect, the malformed-input corpus, the inherit/override truth table, the
// managed asset contract and the schema round trips.
//
// The app leg `--canvas-background-render-check` proves the RENDERER actually
// uses these answers, in pixels. Neither half is sufficient alone: this one
// could pass against a renderer that ignores it, and that one can only afford a
// handful of camera states.
func runCanvasBackgroundChecks() {
    runCanvasBackgroundColorModelChecks()
    runCanvasBackgroundConfigurationCorpusChecks()
    runCanvasBackgroundPrecedenceChecks()
    runCanvasBackgroundModuloChecks()
    runCanvasBackgroundGridPhaseChecks()
    runCanvasBackgroundStrideHysteresisChecks()
    runCanvasBackgroundImageGeometryChecks()
    runCanvasBackgroundAssetStoreChecks()
    runCanvasBackgroundPersistenceChecks()
}

// MARK: - Colour

private func runCanvasBackgroundColorModelChecks() {
    // Every representable invalid component is refused, rather than clamped into
    // something the user never picked.
    let invalid: [(Double, Double, Double, Double, String)] = [
        (.nan, 0, 0, 1, "NaN red"),
        (0, .infinity, 0, 1, "+Inf green"),
        (0, 0, -.infinity, 1, "-Inf blue"),
        (-0.001, 0, 0, 1, "red below range"),
        (0, 1.001, 0, 1, "green above range"),
        (0, 0, 0, .nan, "NaN alpha"),
        (0, 0, 0, 1.5, "alpha above range"),
    ]
    for (r, g, b, a, label) in invalid {
        expect(CanvasBackgroundRGBA(red: r, green: g, blue: b, alpha: a) == nil,
               "CanvasBackgroundRGBA accepted \(label)")
    }
    expect(CanvasBackgroundRGBA(red: 0, green: 0, blue: 0, alpha: 0) != nil, "0,0,0,0 must be legal")
    expect(CanvasBackgroundRGBA(red: 1, green: 1, blue: 1, alpha: 1) != nil, "1,1,1,1 must be legal")
    expect(CanvasBackgroundRGBA(red: 0.5, green: 0.5, blue: 0.5, alpha: 1, version: 2) == nil,
           "a future colour version must be refused, not silently read as v1")

    // EXACTNESS: the bytes survive an encode/decode round trip untouched. A
    // palette quantiser or a contrast pass would move them.
    let exact = CanvasBackgroundRGBA(red: 0.123456789, green: 0.987654321, blue: 0.5, alpha: 0.75)!
    let data = try! JSONCodec.makeEncoder().encode(exact)
    let back = try! JSONCodec.makeCanvasDecoder().decode(CanvasBackgroundRGBA.self, from: data)
    expect(back == exact, "an exact colour did not survive a round trip: \(back)")

    // A nonfinite component that the JSON layer CAN represent must fail the
    // decode, not produce a colour.
    let nanJSON = #"{"version":1,"red":"NaN","green":0,"blue":0,"alpha":1}"#.data(using: .utf8)!
    expect((try? JSONCodec.makeCanvasDecoder().decode(CanvasBackgroundRGBA.self, from: nanJSON)) == nil,
           "a NaN component decoded into a colour")

    // The asset id is derived and validated; nothing path-shaped can become one.
    expect(CanvasBackgroundAssetID(digest: String(repeating: "a", count: 64), fileExtension: "png") != nil,
           "a well-formed asset id was refused")
    let badIDs: [(String, String)] = [
        (String(repeating: "a", count: 63), "png"),
        (String(repeating: "a", count: 64), "exe"),
        (String(repeating: "A", count: 64), "png"),   // upper-case normalises, then is legal
        ("../../etc/passwd", "png"),
        (String(repeating: "z", count: 64), "png"),
    ]
    expect(CanvasBackgroundAssetID(digest: badIDs[0].0, fileExtension: badIDs[0].1) == nil, "short digest accepted")
    expect(CanvasBackgroundAssetID(digest: badIDs[1].0, fileExtension: badIDs[1].1) == nil, "disallowed extension accepted")
    expect(CanvasBackgroundAssetID(digest: badIDs[2].0, fileExtension: badIDs[2].1)?.digest
           == String(repeating: "a", count: 64), "an upper-case digest must normalise, not be rejected")
    expect(CanvasBackgroundAssetID(digest: badIDs[3].0, fileExtension: badIDs[3].1) == nil, "a path became an asset id")
    expect(CanvasBackgroundAssetID(digest: badIDs[4].0, fileExtension: badIDs[4].1) == nil, "a non-hex digest accepted")
    let id = CanvasBackgroundAssetID(digest: String(repeating: "b", count: 64), fileExtension: "png")!
    expect(!id.fileName.contains("/") && !id.fileName.contains(".."),
           "an asset file name must contain no path separator")
    expect(!id.shortDescription.contains("/"), "the warning form must be path-free")

    // Opacity is a closed set: there is no representable out-of-range value.
    expect(CanvasBackgroundImageOpacity.allCases.map(\.value) == [0, 0.35, 1],
           "the shipped opacities changed: \(CanvasBackgroundImageOpacity.allCases.map(\.value))")
    expect(CanvasBackgroundImageOpacity.nearest(to: -5) == .hidden, "nearest(-5) must clamp to 0")
    expect(CanvasBackgroundImageOpacity.nearest(to: 99) == .full, "nearest(99) must clamp to 1")
    expect(CanvasBackgroundImageOpacity.nearest(to: .nan) == .full, "nearest(NaN) must be total, not a crash")
}

// MARK: - Configuration corpus

private func runCanvasBackgroundConfigurationCorpusChecks() {
    let decoder = JSONCodec.makeCanvasDecoder()

    func decode(_ json: String) -> CanvasBackgroundConfiguration? {
        try? decoder.decode(CanvasBackgroundConfiguration.self, from: json.data(using: .utf8)!)
    }

    // Absent everything: the typed default, not a crash and not an empty shell.
    let empty = decode("{}")
    expect(empty == CanvasBackgroundConfiguration.systemDefault,
           "an empty configuration object must decode to the system default, got \(String(describing: empty))")

    // A FUTURE schema is an error. Silently downgrading would let a newer Array
    // write a configuration this one then overwrites with a lossy version.
    expect(decode(#"{"schemaVersion":99}"#) == nil, "a future configuration schema decoded instead of failing")

    // Per-field tolerance: one bad field must not cost the siblings.
    let mixed = decode("""
    {"schemaVersion":1,
     "pattern":"hexagons",
     "spacing":"not a number",
     "base":{"kind":"custom","color":{"red":0.25,"green":0.5,"blue":0.75,"alpha":1}}}
    """)
    expect(mixed?.pattern == .solid, "an unknown pattern must fall back to solid, got \(String(describing: mixed?.pattern))")
    expect(mixed?.spacing == CanvasBackgroundConfiguration.defaultSpacing,
           "a malformed spacing must fall back to the default, got \(String(describing: mixed?.spacing))")
    expect(mixed?.base.customColor?.red == 0.25,
           "a VALID sibling field was lost because another field was malformed")

    // An out-of-range colour inside an otherwise valid configuration degrades
    // that field only.
    let badColor = decode(#"{"base":{"kind":"custom","color":{"red":5,"green":0,"blue":0,"alpha":1}},"pattern":"dots"}"#)
    expect(badColor?.base == .systemDefault, "an out-of-range base colour must fall back to the system default")
    expect(badColor?.pattern == .dots, "the pattern was lost with the bad colour")

    // Spacing is BOUNDED, both directions, including through the initialiser.
    expect(CanvasBackgroundConfiguration(spacing: 0).spacing == CanvasBackgroundConfiguration.spacingRange.lowerBound,
           "spacing 0 must clamp to the lower bound")
    expect(CanvasBackgroundConfiguration(spacing: -100).spacing == CanvasBackgroundConfiguration.spacingRange.lowerBound,
           "a negative spacing must clamp to the lower bound")
    expect(CanvasBackgroundConfiguration(spacing: 100_000).spacing == CanvasBackgroundConfiguration.spacingRange.upperBound,
           "a huge spacing must clamp to the upper bound")
    expect(CanvasBackgroundConfiguration(spacing: .nan).spacing == CanvasBackgroundConfiguration.defaultSpacing,
           "NaN spacing must fall back to the default")
    expect(CanvasBackgroundConfiguration(spacing: .infinity).spacing == CanvasBackgroundConfiguration.defaultSpacing,
           "infinite spacing must fall back to the default")

    // Round trip of a fully populated value, INCLUDING the image reference.
    let assetID = CanvasBackgroundAssetID(digest: String(repeating: "c", count: 64), fileExtension: "png")!
    let full = CanvasBackgroundConfiguration(
        base: .custom(CanvasBackgroundRGBA(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)!),
        pattern: .lines,
        patternColor: .custom(CanvasBackgroundRGBA(red: 0.9, green: 0.8, blue: 0.7, alpha: 0.5)!),
        spacing: 96,
        image: CanvasBackgroundImageSpec(assetID: assetID, opacity: .muted, mode: .fit))
    let encoded = try! JSONCodec.makeEncoder().encode(full)
    let decoded = try! decoder.decode(CanvasBackgroundConfiguration.self, from: encoded)
    expect(decoded == full, "a full configuration did not survive a round trip")

    // NO PATH, EVER. The encoded form is inspected as text.
    let text = String(data: encoded, encoding: .utf8)!
    for forbidden in ["/Users", "file://", "bookmark", ".jpg\\/", "Volumes"] {
        expect(!text.contains(forbidden), "the encoded configuration contains '\(forbidden)': \(text)")
    }
    expect(text.contains(assetID.fileName), "the encoded configuration lost its asset reference")
    expect(text.filter { $0 == "/" }.isEmpty, "the encoded configuration contains a path separator: \(text)")
}

// MARK: - Precedence

private func runCanvasBackgroundPrecedenceChecks() {
    let globalA = CanvasBackgroundConfiguration(pattern: .lines, spacing: 40)
    let globalB = CanvasBackgroundConfiguration(pattern: .dots, spacing: 80)
    let localConfig = CanvasBackgroundConfiguration(pattern: .solid, spacing: 120)

    // The full truth table: two workspace states × two global values.
    expect(CanvasBackgroundResolver.effective(workspace: .inherit, global: globalA) == globalA,
           "inherit must resolve to the global")
    expect(CanvasBackgroundResolver.effective(workspace: .inherit, global: globalB) == globalB,
           "inherit must FOLLOW a later global change — it is not a snapshot")
    expect(CanvasBackgroundResolver.effective(workspace: .override(localConfig), global: globalA) == localConfig,
           "an override must win over the global")
    expect(CanvasBackgroundResolver.effective(workspace: .override(localConfig), global: globalB) == localConfig,
           "a global change must not reach an overriding workspace")

    // Source attribution: an inherit that HAPPENS to equal the global is still
    // an inherit. Without this, "override" could be claimed by coincidence.
    expect(CanvasBackgroundResolver.source(for: .inherit) == .global, "inherit must attribute to global")
    expect(CanvasBackgroundResolver.source(for: .override(globalA)) == .workspaceOverride,
           "an override equal to the global must still attribute to the workspace")
    expect(CanvasBackgroundResolver.effective(workspace: .override(globalA), global: globalB) == globalA,
           "an override that equals one global must not follow the other")

    // Encoded scope survives, and inherit is never materialised into a copy.
    let inheritData = try! JSONCodec.makeEncoder().encode(WorkspaceCanvasBackground.inherit)
    let inheritText = String(data: inheritData, encoding: .utf8)!
    expect(inheritText.contains("inherit"), "inherit must encode its scope explicitly: \(inheritText)")
    expect(!inheritText.contains("spacing"), "inherit encoded a configuration — it was materialised: \(inheritText)")
    let backInherit = try! JSONCodec.makeCanvasDecoder().decode(WorkspaceCanvasBackground.self, from: inheritData)
    expect(backInherit == .inherit, "inherit did not survive a round trip")

    let overrideData = try! JSONCodec.makeEncoder().encode(WorkspaceCanvasBackground.override(localConfig))
    let backOverride = try! JSONCodec.makeCanvasDecoder().decode(WorkspaceCanvasBackground.self, from: overrideData)
    expect(backOverride == .override(localConfig), "an override did not survive a round trip")

    // A structurally broken override keeps its SCOPE. Falling back to inherit
    // here would silently hand the workspace the global.
    let brokenOverride = #"{"scope":"override","configuration":{"schemaVersion":99}}"#.data(using: .utf8)!
    let recovered = try! JSONCodec.makeCanvasDecoder().decode(WorkspaceCanvasBackground.self, from: brokenOverride)
    expect(recovered.isOverride, "a broken override collapsed into inherit — the user's scope decision was lost")

    // An unknown scope reads as inherit, which is the safe default for a value
    // written by a future version.
    let unknownScope = #"{"scope":"someFutureScope"}"#.data(using: .utf8)!
    expect((try! JSONCodec.makeCanvasDecoder().decode(WorkspaceCanvasBackground.self, from: unknownScope)) == .inherit,
           "an unknown scope must read as inherit")

    // The GLOBAL store is one atomic value in a real (isolated) defaults suite.
    let suiteName = "dev.arrayapp.ws7.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    expect(CanvasBackgroundGlobalStore.load(defaults: defaults) == .systemDefault,
           "an empty store must read as the system default")
    expect(CanvasBackgroundGlobalStore.save(globalB, defaults: defaults), "the global store failed to save")
    expect(CanvasBackgroundGlobalStore.load(defaults: defaults) == globalB, "the global store did not round trip")
    expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("continuum.canvasBackground") }.count == 1,
           "the global configuration must be ONE key; independent keys tear")
    // A corrupt stored value degrades to the default rather than crashing.
    defaults.set(Data([0x00, 0x01, 0x02]), forKey: CanvasBackgroundGlobalStore.key)
    expect(CanvasBackgroundGlobalStore.load(defaults: defaults) == .systemDefault,
           "a corrupt global value must read as the system default")
    CanvasBackgroundGlobalStore.reset(defaults: defaults)
    expect(defaults.data(forKey: CanvasBackgroundGlobalStore.key) == nil, "reset must remove the key")
}

// MARK: - Modulo

private func runCanvasBackgroundModuloChecks() {
    // The property the whole grid rests on: the result is always in [0, m), for
    // negative dividends too. `truncatingRemainder` is negative there, which is
    // the stutter this replaces — so the check also proves the two DIFFER.
    var sawDisagreement = false
    for raw in stride(from: -1000.0, through: 1000.0, by: 0.37) {
        for m in [1.0, 7.5, 64.0, 128.0] {
            let value = CanvasBackgroundGeometry.positiveMod(raw, m)
            expect(value >= 0 && value < m, "positiveMod(\(raw), \(m)) = \(value) is outside [0, \(m))")
            let signed = raw.truncatingRemainder(dividingBy: m)
            if signed < 0 { sawDisagreement = true }
            if signed >= 0 {
                expect(abs(signed - value) < 1e-9,
                       "positiveMod disagrees with the signed remainder where both are non-negative: \(raw) % \(m)")
            }
        }
    }
    // Positive control: if the corpus never exercised a negative remainder, the
    // agreement assertions above would be vacuous.
    expect(sawDisagreement, "the modulo corpus never produced a negative signed remainder — it proves nothing")
    expect(CanvasBackgroundGeometry.positiveMod(0, 64) == 0, "positiveMod(0, 64) must be 0")
    expect(CanvasBackgroundGeometry.positiveMod(-64, 64) == 0, "positiveMod(-64, 64) must be 0")
    expect(CanvasBackgroundGeometry.positiveMod(.nan, 64) == 0, "positiveMod(NaN) must be 0, not NaN")
    expect(CanvasBackgroundGeometry.positiveMod(5, 0) == 0, "positiveMod with a zero modulus must be 0")
}

// MARK: - Grid phase

private func runCanvasBackgroundGridPhaseChecks() {
    let size = CGSize(width: 800, height: 600)
    let spacing = 64.0

    // Continuity across the world origin. A signed remainder makes the phase
    // jump a whole stride at x = 0; the assertion is that consecutive camera
    // steps move it by the step, wrapping smoothly.
    var previous: CanvasBackgroundGeometry.GridPhase?
    var sawNegativeWorld = false
    var sawWrap = false
    for step in stride(from: -300.0, through: 300.0, by: 1.0) {
        let viewport = CanvasViewport(x: step, y: step * 0.5, zoom: 1)
        if step < 0 { sawNegativeWorld = true }
        let phase = CanvasBackgroundGeometry.gridPhase(
            viewport: viewport, viewportSize: size, spacingWorld: spacing, multiplier: 1)
        expect(phase.phaseX >= 0 && phase.phaseX < phase.strideScreen,
               "phaseX \(phase.phaseX) outside [0, \(phase.strideScreen)) at x=\(step)")
        expect(phase.phaseY >= 0 && phase.phaseY < phase.strideScreen,
               "phaseY \(phase.phaseY) outside [0, \(phase.strideScreen)) at y=\(step * 0.5)")

        // The phase must be the screen position of a REAL world line.
        let expectedScreenX = (phase.firstWorldX - viewport.x) * viewport.zoom
        expect(abs(expectedScreenX - phase.phaseX) < 1e-6,
               "phaseX \(phase.phaseX) is not the screen position of world line \(phase.firstWorldX) at x=\(step)")
        let expectedScreenY = (phase.firstWorldY - viewport.y) * viewport.zoom
        expect(abs(expectedScreenY - phase.phaseY) < 1e-6,
               "phaseY \(phase.phaseY) is not the screen position of world line \(phase.firstWorldY) at y=\(step * 0.5)")

        if let previous {
            // A 1-unit pan at zoom 1 moves the phase by exactly 1, modulo the
            // stride. Anything else is the discontinuity.
            // Panning right by 1 world unit at zoom 1 moves the first visible
            // line 1 point LEFT, so the phase falls by 1 — or, when the old
            // first line leaves the screen, wraps up to `stride - 1`. Those two
            // values are the only legal deltas; anything else is the whole-stride
            // jump a signed remainder produces at the world origin.
            let delta = phase.phaseX - previous.phaseX
            let wrapped = abs(delta - (phase.strideScreen - 1)) < 1e-6
            if wrapped { sawWrap = true }
            expect(abs(delta + 1) < 1e-6 || wrapped,
                   "phaseX moved by \(delta) for a 1-unit pan at x=\(step) — legal deltas are -1 and \(phase.strideScreen - 1)")
        }
        previous = phase
    }
    expect(sawNegativeWorld, "the pan corpus never visited a negative world coordinate")
    expect(sawWrap, "the pan corpus never wrapped the phase — it never crossed a grid line")

    // The phase is anchored to the WORLD: two cameras a whole stride apart show
    // the identical phase, and the world line they name differs by that stride.
    let a = CanvasBackgroundGeometry.gridPhase(
        viewport: CanvasViewport(x: -1000, y: -1000, zoom: 1), viewportSize: size,
        spacingWorld: spacing, multiplier: 1)
    let b = CanvasBackgroundGeometry.gridPhase(
        viewport: CanvasViewport(x: -1000 + spacing, y: -1000 + spacing, zoom: 1), viewportSize: size,
        spacingWorld: spacing, multiplier: 1)
    expect(abs(a.phaseX - b.phaseX) < 1e-9, "a whole-stride pan changed the phase")
    expect(abs((b.firstWorldX - a.firstWorldX) - spacing) < 1e-9,
           "a whole-stride pan did not advance the anchored world line")

    // Determinism: the same camera state always produces the same record.
    for _ in 0..<5 {
        let repeated = CanvasBackgroundGeometry.gridPhase(
            viewport: CanvasViewport(x: -1000, y: -1000, zoom: 1), viewportSize: size,
            spacingWorld: spacing, multiplier: 1)
        expect(repeated == a, "the same camera state produced a different grid record")
    }

    // Primitive counts are viewport-bounded, at extreme world coordinates too.
    for origin in [-1e9, -12345.678, 0, 12345.678, 1e9] {
        for zoom in [0.05, 0.25, 1.0, 4.0, 16.0] {
            let viewport = CanvasViewport(x: origin, y: origin, zoom: zoom)
            let multiplier = CanvasBackgroundGeometry.canonicalStrideMultiplier(spacingWorld: spacing, zoom: zoom)
            let phase = CanvasBackgroundGeometry.gridPhase(
                viewport: viewport, viewportSize: size, spacingWorld: spacing, multiplier: multiplier)
            let ceiling = CanvasBackgroundGeometry.maximumPrimitiveCount(
                viewportSize: size, strideScreen: phase.strideScreen)
            expect(phase.verticalCount + phase.horizontalCount <= ceiling,
                   "primitive count \(phase.verticalCount + phase.horizontalCount) exceeds the analytic ceiling \(ceiling) at origin \(origin) zoom \(zoom)")
            // Every emitted position is on screen.
            for x in phase.verticalPositions() {
                expect(x >= 0 && x <= size.width, "vertical line at \(x) is off screen (width \(size.width))")
            }
            for y in phase.horizontalPositions() {
                expect(y >= 0 && y <= size.height, "horizontal line at \(y) is off screen (height \(size.height))")
            }
            // And the LAST possible line is genuinely covered: one more stride
            // would leave the viewport.
            if let last = phase.verticalPositions().last {
                expect(last + phase.strideScreen > size.width,
                       "the grid stops short: another line at \(last + phase.strideScreen) would still be on screen")
            }
        }
    }

    // Degenerate inputs produce an empty, finite record rather than a hang.
    let degenerate = CanvasBackgroundGeometry.gridPhase(
        viewport: CanvasViewport(x: .nan, y: .nan, zoom: 0), viewportSize: .zero,
        spacingWorld: 64, multiplier: 1)
    expect(degenerate.verticalCount == 0 && degenerate.horizontalCount == 0,
           "a degenerate camera produced primitives")

    // Device alignment is reported separately and is a pure function.
    let aligned = CanvasBackgroundGeometry.alignedPosition(10.3, backingScale: 2, lineWidthDevice: 1)
    expect(abs(aligned - 10.25) < 1e-9, "alignedPosition(10.3, @2x, 1px) = \(aligned), expected 10.25")
    expect(abs(aligned - 10.3) < 0.5, "alignment moved a position by more than half a point")
}

// MARK: - Stride hysteresis

private func runCanvasBackgroundStrideHysteresisChecks() {
    let spacing = 64.0
    let lower = CanvasBackgroundGeometry.minimumScreenStride
    let upper = CanvasBackgroundGeometry.maximumScreenStride
    expect(upper > 2 * lower,
           "the hysteresis band \(lower)...\(upper) has upper <= 2 * lower, so a double lands where a halve fires — it cannot have hysteresis")

    // 1. The canonical answer is always inside or above the band.
    for zoom in stride(from: 0.01, through: 40.0, by: 0.01) {
        let m = CanvasBackgroundGeometry.canonicalStrideMultiplier(spacingWorld: spacing, zoom: zoom)
        expect(m >= 1 && (m & (m - 1)) == 0, "canonical multiplier \(m) is not a power of two at zoom \(zoom)")
        expect(Double(m) * spacing * zoom >= lower - 1e-9,
               "canonical stride \(Double(m) * spacing * zoom) is below the floor at zoom \(zoom)")
    }

    // 2. NO OSCILLATION. Walk the zoom down and back up in tiny steps, carrying
    //    the state, and count direction changes in the multiplier. A memoryless
    //    threshold flips repeatedly around each boundary; hysteresis must produce
    //    a monotone run down and a monotone run up.
    var state: Int? = nil
    var downSequence: [Int] = []
    for zoom in stride(from: 4.0, through: 0.02, by: -0.001) {
        state = CanvasBackgroundGeometry.strideMultiplier(spacingWorld: spacing, zoom: zoom, previous: state)
        downSequence.append(state!)
    }
    var upSequence: [Int] = []
    for zoom in stride(from: 0.02, through: 4.0, by: 0.001) {
        state = CanvasBackgroundGeometry.strideMultiplier(spacingWorld: spacing, zoom: zoom, previous: state)
        upSequence.append(state!)
    }
    func directionChanges(_ values: [Int]) -> Int {
        var changes = 0
        var lastDirection = 0
        for (previous, next) in zip(values, values.dropFirst()) where next != previous {
            let direction = next > previous ? 1 : -1
            if lastDirection != 0, direction != lastDirection { changes += 1 }
            lastDirection = direction
        }
        return changes
    }
    expect(directionChanges(downSequence) == 0,
           "zooming out reversed the stride \(directionChanges(downSequence)) time(s) — that is oscillation")
    expect(directionChanges(upSequence) == 0,
           "zooming in reversed the stride \(directionChanges(upSequence)) time(s) — that is oscillation")
    expect(Set(downSequence).count > 3,
           "the zoom sweep only produced \(Set(downSequence).count) distinct multipliers — it never crossed a threshold")

    // 3. The band actually holds: with state carried, the effective screen
    //    stride stays inside [lower, upper] wherever it can.
    state = nil
    for zoom in stride(from: 0.05, through: 8.0, by: 0.005) {
        state = CanvasBackgroundGeometry.strideMultiplier(spacingWorld: spacing, zoom: zoom, previous: state)
        let screen = Double(state!) * spacing * zoom
        expect(screen >= lower - 1e-9, "screen stride \(screen) fell below the floor at zoom \(zoom)")
        // The ceiling can only be exceeded at multiplier 1, where there is no
        // coarser grid to halve to.
        expect(screen <= upper + 1e-9 || state! == 1,
               "screen stride \(screen) exceeded the ceiling at zoom \(zoom) with multiplier \(state!)")
    }

    // 4. Hysteresis is REAL: at a zoom inside the band, the answer depends on
    //    where you came from. This is the assertion a memoryless implementation
    //    cannot satisfy.
    var foundStatefulDisagreement = false
    for zoom in stride(from: 0.05, through: 2.0, by: 0.001) {
        let fromFine = CanvasBackgroundGeometry.strideMultiplier(spacingWorld: spacing, zoom: zoom, previous: 1)
        let fromCoarse = CanvasBackgroundGeometry.strideMultiplier(spacingWorld: spacing, zoom: zoom, previous: 16)
        if fromFine != fromCoarse { foundStatefulDisagreement = true; break }
    }
    expect(foundStatefulDisagreement,
           "no zoom exists where the previous multiplier changes the answer — the stride has no hysteresis at all")

    // 5. A direct jump with no history is canonical, so a relaunch and a cold
    //    start agree.
    for zoom in [0.1, 0.5, 1.0, 3.0] {
        expect(CanvasBackgroundGeometry.strideMultiplier(spacingWorld: spacing, zoom: zoom, previous: nil)
               == CanvasBackgroundGeometry.canonicalStrideMultiplier(spacingWorld: spacing, zoom: zoom),
               "a stateless call disagreed with the canonical multiplier at zoom \(zoom)")
    }
    // A corrupt previous value (not a power of two, out of range) is repaired.
    expect(CanvasBackgroundGeometry.strideMultiplier(spacingWorld: spacing, zoom: 1, previous: 7)
           == CanvasBackgroundGeometry.canonicalStrideMultiplier(spacingWorld: spacing, zoom: 1),
           "a non-power-of-two previous multiplier was carried instead of repaired")
    expect(CanvasBackgroundGeometry.strideMultiplier(spacingWorld: spacing, zoom: 0, previous: 4) == 1,
           "a zero zoom must produce multiplier 1, not a loop")
}

// MARK: - Image geometry

private func runCanvasBackgroundImageGeometryChecks() {
    let viewport = CGSize(width: 800, height: 600)

    // FILL covers the viewport completely and crops on the long axis.
    let fillWide = CanvasBackgroundGeometry.imageRect(
        imageSize: CGSize(width: 1600, height: 400), viewportSize: viewport, mode: .fill)
    expect(fillWide.width >= viewport.width - 1e-9 && fillWide.height >= viewport.height - 1e-9,
           "fill left a gap: \(fillWide) inside \(viewport)")
    expect(abs(fillWide.width / fillWide.height - 4) < 1e-9, "fill did not preserve the aspect ratio")
    expect(abs(fillWide.midX - viewport.width / 2) < 1e-9 && abs(fillWide.midY - viewport.height / 2) < 1e-9,
           "fill is not centred: \(fillWide)")

    // FIT is contained by the viewport and touches exactly one pair of edges.
    let fitWide = CanvasBackgroundGeometry.imageRect(
        imageSize: CGSize(width: 1600, height: 400), viewportSize: viewport, mode: .fit)
    expect(fitWide.width <= viewport.width + 1e-9 && fitWide.height <= viewport.height + 1e-9,
           "fit overflowed: \(fitWide)")
    expect(abs(fitWide.width - viewport.width) < 1e-9, "a wide image fitted must touch the left and right edges")
    expect(fitWide.height < viewport.height, "a wide image fitted must letterbox vertically")

    // Fill and Fit genuinely differ for a non-matching aspect ratio.
    expect(fillWide != fitWide, "fill and fit produced the same rect for a 4:1 image in a 4:3 viewport")

    // A matching aspect ratio makes them agree — the degenerate case that would
    // hide a swapped min/max if it were the only case tested.
    let match = CGSize(width: 400, height: 300)
    expect(CanvasBackgroundGeometry.imageRect(imageSize: match, viewportSize: viewport, mode: .fill)
           == CanvasBackgroundGeometry.imageRect(imageSize: match, viewportSize: viewport, mode: .fit),
           "fill and fit disagreed for an image with the viewport's own aspect ratio")

    // SCREEN-FIXED: the rect is a function of the viewport SIZE only. Neither
    // pan nor zoom is an input, which is the mechanical form of the contract.
    let tall = CGSize(width: 300, height: 900)
    for mode in CanvasBackgroundImageMode.allCases {
        let reference = CanvasBackgroundGeometry.imageRect(imageSize: tall, viewportSize: viewport, mode: mode)
        for size in [viewport, CGSize(width: 800, height: 600)] {
            expect(CanvasBackgroundGeometry.imageRect(imageSize: tall, viewportSize: size, mode: mode) == reference,
                   "the image rect changed for an identical viewport size")
        }
    }

    // Degenerate sizes are empty, not NaN.
    for bad in [CGSize.zero, CGSize(width: -10, height: 10), CGSize(width: CGFloat.nan, height: 10)] {
        expect(CanvasBackgroundGeometry.imageRect(imageSize: bad, viewportSize: viewport, mode: .fill) == .zero,
               "a degenerate image size \(bad) produced a rect")
        expect(CanvasBackgroundGeometry.imageRect(imageSize: tall, viewportSize: bad, mode: .fill) == .zero,
               "a degenerate viewport size \(bad) produced a rect")
    }

    // Decode targets are bucketed and hard-capped.
    let small = CanvasBackgroundGeometry.decodeTargetPixels(viewportSize: CGSize(width: 800, height: 600), backingScale: 2)
    expect(small % CanvasBackgroundGeometry.decodeBucketPixels == 0, "the decode target is not bucketed: \(small)")
    expect(small >= 1600, "the decode target \(small) is below the viewport's own pixel size")
    let huge = CanvasBackgroundGeometry.decodeTargetPixels(viewportSize: CGSize(width: 100_000, height: 100_000), backingScale: 3)
    expect(huge == CanvasBackgroundGeometry.maximumDecodePixelDimension,
           "the decode target is not capped: \(huge)")
    // A PAN cannot change it, because it is not an input.
    expect(CanvasBackgroundGeometry.decodeTargetPixels(viewportSize: CGSize(width: 800, height: 600), backingScale: 2) == small,
           "the decode target is not stable for a fixed viewport size")
}

// MARK: - Managed asset store

private func runCanvasBackgroundAssetStoreChecks() {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ws7-assets-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = CanvasBackgroundAssetStore(applicationSupportDirectory: root)

    expect(store.directory.path.hasPrefix(root.path),
           "the managed directory escaped the application support root: \(store.directory.path)")

    let source = root.appendingPathComponent("wallpaper.png")
    let bytes = Data((0..<4096).map { UInt8($0 % 251) })
    try! bytes.write(to: source)

    let id = try! store.importImage(at: source)
    expect(store.exists(id), "the imported asset is not in the managed directory")
    expect(store.url(for: id).deletingLastPathComponent().path == store.directory.path,
           "the managed URL is not inside the managed directory")
    expect(try! Data(contentsOf: store.url(for: id)) == bytes, "the imported bytes differ from the source")

    // DETERMINISTIC and DEDUPLICATING: the same bytes always produce the same
    // id, whatever the source file was called.
    let renamed = root.appendingPathComponent("something-else.png")
    try! bytes.write(to: renamed)
    let again = try! store.importImage(at: renamed)
    expect(again == id, "the same bytes produced two different asset ids: \(id) vs \(again)")
    let managedCount = try! FileManager.default.contentsOfDirectory(atPath: store.directory.path).count
    expect(managedCount == 1, "re-importing identical bytes stored \(managedCount) copies")

    // Different bytes -> a different id.
    let other = root.appendingPathComponent("other.png")
    try! Data(repeating: 7, count: 2048).write(to: other)
    let otherID = try! store.importImage(at: other)
    expect(otherID != id, "different bytes produced the same asset id")

    // Nothing about the source path survives.
    expect(!id.fileName.contains("wallpaper"), "the user's filename leaked into the asset id")

    // Refusals.
    let badExt = root.appendingPathComponent("payload.exe")
    try! Data([1, 2, 3]).write(to: badExt)
    expect((try? store.importImage(at: badExt)) == nil, "a disallowed extension was imported")
    let emptyFile = root.appendingPathComponent("empty.png")
    try! Data().write(to: emptyFile)
    expect((try? store.importImage(at: emptyFile)) == nil, "an empty file was imported")
    expect((try? store.importImage(at: root.appendingPathComponent("missing.png"))) == nil,
           "a missing file was imported")
    expect((try? store.importImage(at: root)) == nil, "a directory was imported")

    // No temp file survived a successful import.
    let leftovers = try! FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        .filter { $0.hasPrefix(".import-") || $0.hasSuffix(".tmp") }
    expect(leftovers.isEmpty, "the import left temp files behind: \(leftovers)")

    // REFERENCE-AWARE, DEFERRED cleanup.
    var result = store.cleanup(referencedIDs: [id, otherID], now: Date(), grace: 0)
    expect(result.deleted.isEmpty, "cleanup deleted a REFERENCED asset: \(result.deleted)")
    expect(result.referenced == 2, "cleanup did not recognise both references")

    result = store.cleanup(referencedIDs: [id], now: Date(), grace: CanvasBackgroundAssetStore.cleanupGrace)
    expect(result.deleted.isEmpty, "cleanup deleted an unreferenced asset before its grace period elapsed")
    expect(result.withheldForGrace == [otherID.fileName],
           "cleanup did not withhold the freshly unreferenced asset: \(result.withheldForGrace)")
    expect(store.exists(otherID), "the withheld asset was removed anyway")

    result = store.cleanup(referencedIDs: [id], now: Date(), grace: 0)
    expect(result.deleted == [otherID.fileName], "cleanup did not delete the aged, unreferenced asset")
    expect(!store.exists(otherID), "the deleted asset is still present")
    expect(store.exists(id), "cleanup deleted the still-referenced asset")

    // A symlink in the managed directory is never followed and never deleted.
    let target = root.appendingPathComponent("outside.png")
    try! Data(repeating: 9, count: 16).write(to: target)
    let link = store.directory.appendingPathComponent("\(String(repeating: "d", count: 64)).png")
    try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    result = store.cleanup(referencedIDs: [], now: Date(), grace: 0)
    expect(FileManager.default.fileExists(atPath: target.path), "cleanup followed a symlink and deleted its target")
    expect(result.skippedNonRegular.contains(link.lastPathComponent),
           "cleanup did not record the symlink as skipped: \(result.skippedNonRegular)")
}

// MARK: - Persistence

private func runCanvasBackgroundPersistenceChecks() {
    let encoder = JSONCodec.makeEncoder()
    let decoder = JSONCodec.makeCanvasDecoder()

    let base = WorkspaceDocument(
        viewport: CanvasViewport(x: 10, y: 20, zoom: 1.5),
        zones: [],
        lastActiveZoneId: nil)
    expect(base.canvasBackground == .inherit, "a new workspace document must default to inherit")
    expect(WorkspaceDocument.currentSchemaVersion == 9,
           "the workspace schema must be v9 for the background field, is \(WorkspaceDocument.currentSchemaVersion)")

    // Round trip of an override, through the real Codable path.
    let override = CanvasBackgroundConfiguration(
        base: .custom(CanvasBackgroundRGBA(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)!),
        pattern: .dots, spacing: 48)
    var withOverride = base
    withOverride.canvasBackground = .override(override)
    let restored = try! decoder.decode(WorkspaceDocument.self, from: try! encoder.encode(withOverride))
    expect(restored.canvasBackground == .override(override),
           "a workspace override did not survive a document round trip: \(restored.canvasBackground)")
    expect(restored.viewport == withOverride.viewport, "the round trip disturbed the viewport")

    // A pre-v9 document has no key at all and must read as inherit.
    let legacy = #"""
    {"schemaVersion":8,"viewport":{"x":0,"y":0,"zoom":1},"zones":[],"ambientTiles":[],"documentLinks":[]}
    """#.data(using: .utf8)!
    let migrated = try! decoder.decode(WorkspaceDocument.self, from: legacy)
    expect(migrated.canvasBackground == .inherit, "a pre-v9 document did not migrate to inherit")
    expect(migrated.schemaVersion == 9, "a pre-v9 document was not stamped forward")

    // A structurally broken background must not cost the document its zones.
    let broken = #"""
    {"schemaVersion":9,"viewport":{"x":0,"y":0,"zoom":1},"zones":[],"ambientTiles":[],
     "documentLinks":[],"canvasBackground":"this is not an object"}
    """#.data(using: .utf8)!
    let survived = try! decoder.decode(WorkspaceDocument.self, from: broken)
    expect(survived.canvasBackground == .inherit, "a broken background field did not degrade to inherit")

    // Every save re-stamps the current version, so a v9 field can never be
    // written under a v8 stamp.
    var stale = base
    stale.canvasBackground = .override(override)
    let text = String(data: try! encoder.encode(stale), encoding: .utf8)!
    expect(text.contains("\"schemaVersion\":9"), "the encoded document is not stamped v9: \(text.prefix(120))")

    // A FUTURE document still trips validateSchema rather than downgrading.
    let future = #"""
    {"schemaVersion":99,"viewport":{"x":0,"y":0,"zoom":1},"zones":[],"ambientTiles":[],"documentLinks":[]}
    """#.data(using: .utf8)!
    let futureDocument = try! decoder.decode(WorkspaceDocument.self, from: future)
    var rejected = false
    do { try futureDocument.validateSchema(at: URL(fileURLWithPath: "/tmp/ws7")) } catch { rejected = true }
    expect(rejected, "a future workspace document was accepted")
}
