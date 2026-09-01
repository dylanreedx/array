import ContinuumRevivedAgentUI
import Foundation

// WS5 layer-1 witness: the pure page-zoom policy. Everything here asserts an
// OUTCOME of the shipped type — a rung, a clamp, a scaled number, a routed
// command — never that a source file contains a string.
func runAgentPageZoomChecks() {
    // MARK: The ladder itself

    expect(AgentPageZoom.steps == [80, 90, 100, 110, 125, 150],
           "page zoom ladder is the six locked steps, got \(AgentPageZoom.steps)")
    expect(AgentPageZoom.steps == AgentPageZoom.steps.sorted(),
           "page zoom ladder must be ascending")
    expect(Set(AgentPageZoom.steps).count == AgentPageZoom.steps.count,
           "page zoom ladder must have no duplicate rungs")
    expect(AgentPageZoom.default.percent == 100, "a tile starts at 100%")
    expect(AgentPageZoom.default.isDefault, "100% is the default rung")

    // MARK: Stepping walks the ladder exactly, in both directions

    var walkUp: [Int] = []
    var cursor = AgentPageZoom(percent: 80)
    walkUp.append(cursor.percent)
    for _ in 0..<10 {
        cursor = cursor.zoomedIn()
        walkUp.append(cursor.percent)
    }
    expect(Array(walkUp.prefix(6)) == [80, 90, 100, 110, 125, 150],
           "zoom-in walks the ladder rung by rung, got \(walkUp)")
    expect(walkUp.allSatisfy { $0 <= 150 }, "zoom-in never exceeds the top rung")
    expect(walkUp.suffix(5).allSatisfy { $0 == 150 },
           "zoom-in CLAMPS at 150 rather than wrapping, got \(walkUp)")

    var walkDown: [Int] = []
    cursor = AgentPageZoom(percent: 150)
    walkDown.append(cursor.percent)
    for _ in 0..<10 {
        cursor = cursor.zoomedOut()
        walkDown.append(cursor.percent)
    }
    expect(Array(walkDown.prefix(6)) == [150, 125, 110, 100, 90, 80],
           "zoom-out walks the ladder rung by rung, got \(walkDown)")
    expect(walkDown.suffix(5).allSatisfy { $0 == 80 },
           "zoom-out CLAMPS at 80 rather than wrapping, got \(walkDown)")

    // Every rung is reachable from every other rung by stepping only.
    for start in AgentPageZoom.steps {
        for target in AgentPageZoom.steps {
            var value = AgentPageZoom(percent: start)
            var guardCount = 0
            while value.percent != target, guardCount < 16 {
                value = target > value.percent ? value.zoomedIn() : value.zoomedOut()
                guardCount += 1
            }
            expect(value.percent == target,
                   "stepping from \(start) never reached \(target)")
        }
    }

    // MARK: End stops report themselves

    expect(!AgentPageZoom(percent: 150).canZoomIn, "150% cannot zoom in")
    expect(AgentPageZoom(percent: 150).canZoomOut, "150% can zoom out")
    expect(!AgentPageZoom(percent: 80).canZoomOut, "80% cannot zoom out")
    expect(AgentPageZoom(percent: 80).canZoomIn, "80% can zoom in")
    for step in AgentPageZoom.steps.dropFirst().dropLast() {
        let value = AgentPageZoom(percent: step)
        expect(value.canZoomIn && value.canZoomOut, "\(step)% is an interior rung")
    }

    // MARK: Reset

    for step in AgentPageZoom.steps {
        expect(AgentPageZoom(percent: step).reset().percent == 100,
               "reset from \(step) returns 100")
    }
    expect(!AgentPageZoomCommand.reset.isEnabled(for: .default),
           "reset is disabled at 100% — it is already there")
    for step in AgentPageZoom.steps where step != 100 {
        expect(AgentPageZoomCommand.reset.isEnabled(for: AgentPageZoom(percent: step)),
               "reset is enabled at \(step)%")
    }
    expect(!AgentPageZoomCommand.zoomIn.isEnabled(for: AgentPageZoom(percent: 150)),
           "zoom-in is a disabled end stop at 150%")
    expect(!AgentPageZoomCommand.zoomOut.isEnabled(for: AgentPageZoom(percent: 80)),
           "zoom-out is a disabled end stop at 80%")
    // A disabled command must also be inert if it is invoked anyway.
    expect(AgentPageZoomCommand.zoomIn.apply(to: AgentPageZoom(percent: 150)).percent == 150,
           "invoking a disabled zoom-in must not move the value")
    expect(AgentPageZoomCommand.zoomOut.apply(to: AgentPageZoom(percent: 80)).percent == 80,
           "invoking a disabled zoom-out must not move the value")

    // MARK: Off-ladder construction snaps to the ladder

    for raw in [-1000, 0, 1, 79, 81, 85, 95, 101, 117, 118, 137, 149, 151, 400, 10_000] {
        let snapped = AgentPageZoom(percent: raw)
        expect(AgentPageZoom.steps.contains(snapped.percent),
               "AgentPageZoom(\(raw)) landed off the ladder at \(snapped.percent)")
    }
    expect(AgentPageZoom(percent: 1).percent == 80, "far-below snaps to the floor")
    expect(AgentPageZoom(percent: 10_000).percent == 150, "far-above snaps to the ceiling")
    expect(AgentPageZoom(percent: 118).percent == 125, "118 snaps to the nearer 125")
    expect(AgentPageZoom(percent: 116).percent == 110, "116 snaps to the nearer 110")

    // MARK: Display string

    expect(AgentPageZoom(percent: 100).displayPercentage == "100%",
           "display percentage reads as an integer percent")
    expect(AgentPageZoom(percent: 125).displayPercentage == "125%",
           "display percentage tracks the rung")

    // MARK: Scaled metric arithmetic

    expect(AgentPageZoom.default.factor == 1.0, "100% is a factor of exactly 1")
    for step in AgentPageZoom.steps {
        let zoom = AgentPageZoom(percent: step)
        expect(abs(zoom.factor - Double(step) / 100) < 1e-12, "factor tracks percent at \(step)")
        // Identity at 100%: the scaled value of every shipped token is the token.
        if step == 100 {
            for value in Space.ladder {
                expect(zoom.scaled(value) == value, "100% must not move Space \(value)")
            }
            for role in TextRole.allCases {
                expect(zoom.fontSize(for: role) == Typography.style(for: role).size,
                       "100% must not move the \(role) font size")
                expect(zoom.lineHeight(for: role) == Metrics.lineHeight(for: role),
                       "100% line height must equal the shipped Metrics.lineHeight for \(role)")
            }
            expect(zoom.scaled(Inset.row) == Inset.row, "100% must not move Inset.row")
            expect(zoom.scaled(Inset.card) == Inset.card, "100% must not move Inset.card")
        }
    }

    // Monotonic in the rung, for every token: a bigger rung is never smaller.
    for role in TextRole.allCases {
        var previousSize = -1.0
        var previousLine = -1.0
        for step in AgentPageZoom.steps {
            let zoom = AgentPageZoom(percent: step)
            let size = zoom.fontSize(for: role)
            let line = zoom.lineHeight(for: role)
            expect(size > previousSize,
                   "\(role) font size must strictly grow with the rung (\(step)%: \(size) vs \(previousSize))")
            expect(line >= previousLine,
                   "\(role) line height must not shrink as the rung grows")
            expect(line >= size,
                   "\(role) line height must never be under its own font size at \(step)%")
            previousSize = size
            previousLine = line
        }
    }
    for value in Space.ladder {
        var previous = -1.0
        for step in AgentPageZoom.steps {
            let scaled = AgentPageZoom(percent: step).scaled(value)
            expect(scaled >= previous, "Space \(value) must not shrink as the rung grows")
            previous = scaled
        }
        expect(AgentPageZoom(percent: 150).scaled(value) > AgentPageZoom(percent: 80).scaled(value),
               "Space \(value) must actually differ between the two end stops")
    }

    // Every scaled length lands on a half point, at every rung.
    for step in AgentPageZoom.steps {
        let zoom = AgentPageZoom(percent: step)
        for value in Space.ladder + AgentTileRadius.ladder + [Radius.card, Radius.container, 28, 32, 36, 52] {
            let scaled = zoom.scaled(value)
            expect((scaled * 2) == (scaled * 2).rounded(),
                   "scaled(\(value)) at \(step)% must land on a half point, got \(scaled)")
            expect(scaled >= 0, "a scaled length is never negative")
        }
        // A row height is the sum of its parts, at every rung.
        let derived = zoom.rowHeight(for: .body, lines: 2, insets: Inset.row)
        let expected = zoom.lineHeight(for: .body) * 2 + zoom.scaled(Inset.row).vertical
        expect(derived == expected, "rowHeight is line height x lines + scaled insets at \(step)%")
        expect(zoom.rowHeight(for: .body, lines: 0) == zoom.rowHeight(for: .body, lines: 1),
               "a zero-line row still holds one line at \(step)%")
    }

    // Nonzero tokens never collapse to zero — an invisible gap is a layout bug.
    for step in AgentPageZoom.steps {
        let zoom = AgentPageZoom(percent: step)
        for value in Space.ladder {
            expect(zoom.scaled(value) > 0, "Space \(value) collapsed to 0 at \(step)%")
        }
    }
    // The QUANTUM itself is pinned, not just "it is on a grid". A witness that
    // only asserted "lands on a half point" is satisfied by rounding to WHOLE
    // points, which is a different — and coarser — product: at 110% a 13pt body
    // would render at 14 instead of 14.5, so the type would stop moving between
    // two adjacent rungs. These are the arithmetic, computed by hand.
    let pinnedScaled: [(Int, Double, Double)] = [
        (80, 13, 10.5),   // 10.4 -> 10.5
        (90, 13, 11.5),   // 11.7 -> 11.5
        (110, 13, 14.5),  // 14.3 -> 14.5  (whole-point rounding would give 14)
        (125, 13, 16.5),  // 16.25 -> 16.5
        (150, 13, 19.5),  // 19.5 exactly
        (110, 9, 10.0),   // 9.9 -> 10.0
        (125, 9, 11.5),   // 11.25 -> 11.5
        (80, 12, 9.5),    // 9.6 -> 9.5   (whole-point rounding would give 10)
        (110, 8, 9.0),    // 8.8 -> 9.0
        (125, 8, 10.0),   // 10.0 exactly
        (150, 2, 3.0),    // 3.0 exactly
        (110, 2, 2.0),    // 2.2 -> 2.0
        (125, 2, 2.5),    // 2.5 exactly (whole-point rounding would give 2 or 3)
        (110, 28, 31.0),  // 30.8 -> 31.0 (whole-point rounding would also give 31)
        (150, 28, 42.0)
    ]
    for (percent, input, expected) in pinnedScaled {
        let produced = AgentPageZoom(percent: percent).scaled(input)
        expect(produced == expected,
               "scaled(\(input)) at \(percent)% is \(produced), pinned at \(expected)")
    }
    // The same pin on the type ladder, through `fontSize`.
    expect(AgentPageZoom(percent: 110).fontSize(for: .body) == 14.5,
           "body at 110% must be 14.5pt, got \(AgentPageZoom(percent: 110).fontSize(for: .body))")
    expect(AgentPageZoom(percent: 80).fontSize(for: .caption) == 7.0,
           "caption at 80% must be 7.0pt, got \(AgentPageZoom(percent: 80).fontSize(for: .caption))")
    // …and a rung must actually SEPARATE adjacent steps for the body role, which
    // is what whole-point rounding would collapse.
    for step in 1..<AgentPageZoom.steps.count {
        let lower = AgentPageZoom(percent: AgentPageZoom.steps[step - 1]).fontSize(for: .body)
        let upper = AgentPageZoom(percent: AgentPageZoom.steps[step]).fontSize(for: .body)
        expect(upper - lower >= 0.5,
               "body font must move at least a half point from "
               + "\(AgentPageZoom.steps[step - 1])% to \(AgentPageZoom.steps[step])% "
               + "(\(lower) -> \(upper))")
    }

    expect(AgentPageZoom.quantize(0) == 0, "quantizing zero stays zero")
    expect(AgentPageZoom.quantize(.nan) == 0, "quantizing a non-finite value is safe")

    // MARK: Command routing (pure)

    let command: Set<AgentPageZoomModifier> = [.command]
    let commandShift: Set<AgentPageZoomModifier> = [.command, .shift]

    func route(_ characters: String?, _ ignoring: String?, _ modifiers: Set<AgentPageZoomModifier>)
        -> AgentPageZoomCommand? {
        AgentPageZoomShortcut.command(
            characters: characters, charactersIgnoringModifiers: ignoring, modifiers: modifiers)
    }

    // The three ways a user can ask to zoom IN.
    expect(route("=", "=", command) == .zoomIn, "Command-equal is zoom in")
    expect(route("+", "=", commandShift) == .zoomIn,
           "Command-Shift-equal (US layout: characters '+', unshifted '=') is zoom in")
    expect(route("+", "+", command) == .zoomIn,
           "Command-plus on a layout where + is unshifted is zoom in")
    // Normalisation must work from EITHER string alone, because layouts differ
    // in which one carries the plus.
    expect(route("+", nil, command) == .zoomIn, "the shifted character alone routes zoom in")
    expect(route(nil, "=", command) == .zoomIn, "the unshifted character alone routes zoom in")

    expect(route("-", "-", command) == .zoomOut, "Command-hyphen is zoom out")
    expect(route("\u{2013}", "-", command) == .zoomOut, "an en-dash report still zooms out")
    expect(route("0", "0", command) == .reset, "Command-zero is reset")

    // Everything else falls through. This is the half that protects the browser,
    // the canvas and every editable control from a hijack.
    expect(route("=", "=", []) == nil, "a bare equal is not a zoom chord")
    expect(route("-", "-", []) == nil, "a bare hyphen is not a zoom chord")
    expect(route("0", "0", []) == nil, "a bare zero is not a zoom chord")
    expect(route("=", "=", [.shift]) == nil, "Shift-equal alone is not a zoom chord")
    expect(route("=", "=", [.command, .option]) == nil, "Option-Command-equal is not ours")
    expect(route("-", "-", [.command, .control]) == nil, "Control-Command-hyphen is not ours")
    expect(route("0", "0", [.command, .option, .shift]) == nil, "Option-Shift-Command-zero is not ours")
    expect(route("c", "c", command) == nil, "Command-C falls through untouched")
    expect(route("v", "v", command) == nil, "Command-V falls through untouched")
    expect(route("a", "a", command) == nil, "Command-A falls through untouched")
    expect(route("1", "1", command) == nil, "Command-1 falls through untouched")
    expect(route("9", "9", command) == nil, "Command-9 falls through untouched")
    expect(route("_", "_", commandShift) == nil, "Command-Shift-underscore is not zoom out")
    expect(route(nil, nil, command) == nil, "a chord with no characters is not a zoom chord")
    expect(route("", "", command) == nil, "a chord with empty characters is not a zoom chord")

    // Every printable ASCII character that is NOT one of the four routed
    // characters must fall through under a plain Command.
    let routedCharacters: Set<Character> = ["+", "=", "-", "0"]
    for scalar in UInt8(0x20)...UInt8(0x7E) {
        let character = Character(UnicodeScalar(scalar))
        guard !routedCharacters.contains(character) else { continue }
        let text = String(character)
        expect(route(text, text, command) == nil,
               "Command-\(text) must fall through, it routed \(String(describing: route(text, text, command)))")
    }

    // Routing composes with the ladder: the command a chord resolves to is the
    // command that moves the value.
    expect(route("=", "=", command)?.apply(to: .default).percent == 110,
           "Command-equal at 100% lands on 110")
    expect(route("-", "-", command)?.apply(to: .default).percent == 90,
           "Command-hyphen at 100% lands on 90")
    expect(route("0", "0", command)?.apply(to: AgentPageZoom(percent: 150)).percent == 100,
           "Command-zero from 150% lands on 100")
}
