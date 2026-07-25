import AppKit
import CryptoKit

/// Builds a real view at an **explicit** size, in an **explicit** `NSAppearance`,
/// from an explicit fixture, and hands back both the live view tree (for geometry
/// and contrast assertions) and its bitmap (for pixel probes). Every later gate in
/// phase 0 is a thin layer on this.
///
/// Why it exists: the Component Lab check rendered every card at a default size in
/// whatever appearance the process happened to resolve. `ContinuumApp` pins
/// `NSApp.appearance` to `.darkAqua` at launch, so an unpinned "light" render
/// silently came back dark — which is how three supposedly different appearance
/// renders came back byte-identical and a white-on-white bug shipped anyway.
///
/// AppKit-only by design: this is app chrome, not Core.
@MainActor
struct UIProbe {
    struct Spec {
        var id: String
        var size: NSSize
        var appearance: NSAppearance.Name
    }

    /// One rendered probe. `window`/`host` are retained because a view's
    /// `effectiveAppearance` and its layout both depend on staying hosted — a
    /// caller interrogating geometry after `render` returns needs them alive.
    struct Probed {
        let spec: Spec
        let appearance: NSAppearance
        let window: NSWindow
        let host: NSView
        /// The view the fixture vended, laid out to fill `host`.
        let view: NSView
        /// The composed render of `host` at `spec.size` — what pixel and baseline
        /// gates read.
        let hostRep: NSBitmapImageRep
        /// The component's own render, with none of our backdrop mixed in — the
        /// appearance-sensitivity witness.
        let contentRep: NSBitmapImageRep

        var hostDigest: String { UIProbe.digest(of: hostRep) }
        var contentDigest: String { UIProbe.digest(of: contentRep) }
    }

    enum ProbeError: Error, CustomStringConvertible {
        case message(String)
        var description: String { if case let .message(m) = self { return m }; return "unknown" }
        var localizedDescription: String { description }
    }

    private static func fail(_ message: String) -> ProbeError { .message(message) }

    /// Renders `make()` at `spec.size` in `spec.appearance`.
    static func render(_ spec: Spec, make: () -> NSView) throws -> Probed {
        guard let appearance = NSAppearance(named: spec.appearance) else {
            throw fail("\(spec.id): no NSAppearance named '\(spec.appearance.rawValue)'")
        }
        guard spec.size.width > 0, spec.size.height > 0 else {
            throw fail("\(spec.id): degenerate probe size \(spec.size.width)x\(spec.size.height)")
        }

        let host = NSView(frame: NSRect(origin: .zero, size: spec.size))
        host.wantsLayer = true
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        // Before layout, and before any `.cgColor` conversion: the window is what
        // gives the whole subtree its `effectiveAppearance`.
        window.appearance = appearance
        window.contentView = host

        // `NSColor.cgColor` resolves against `NSAppearance.current`, not against the
        // view — so the whole build+layout+render runs inside the drawing appearance.
        //
        // The app-level appearance moves too, and must: `NSColor.appResolvedCGColor`
        // (AppearanceSupport.swift — how this codebase sets every layer color)
        // resolves against `NSApp?.effectiveAppearance` in preference to the current
        // drawing appearance. Without this, a `.aqua` probe of a layer-backed card
        // would paint dark chrome while `effectiveAppearance` still read `.aqua` —
        // a passing light probe with dark pixels. Restored unconditionally.
        var built: Result<(NSView, NSBitmapImageRep, NSBitmapImageRep), Error>?
        let appAppearance = NSApp?.appearance
        NSApp?.appearance = appearance
        defer { NSApp?.appearance = appAppearance }
        appearance.performAsCurrentDrawingAppearance {
            do {
                let view = make()
                ComponentLabPanel.place(view, in: host, preferredSize: spec.size)
                // An opaque, appearance-resolved backdrop: a light probe must
                // actually look light, or the light pass is theatre.
                host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                host.layoutSubtreeIfNeeded()
                built = .success((view, try bitmap(of: host, id: spec.id), try bitmap(of: view, id: "\(spec.id).content")))
            } catch {
                built = .failure(error)
            }
        }
        switch built {
        case let .success((view, hostRep, contentRep)):
            return Probed(
                spec: spec, appearance: appearance, window: window, host: host, view: view,
                hostRep: hostRep, contentRep: contentRep
            )
        case let .failure(error):
            throw error
        case nil:
            throw fail("\(spec.id): drawing-appearance block never ran")
        }
    }

    private static func bitmap(of view: NSView, id: String) throws -> NSBitmapImageRep {
        guard view.bounds.width > 0, view.bounds.height > 0 else {
            throw fail("\(id): view laid out to \(view.bounds.width)x\(view.bounds.height)")
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw fail("\(id): could not allocate bitmap")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// MD5 over the bitmap's pixel bytes, excluding each row's trailing padding —
    /// padding is not guaranteed initialized, and a digest that hashed it could
    /// report two identical renders as different.
    nonisolated static func digest(of rep: NSBitmapImageRep) -> String {
        var hasher = Insecure.MD5()
        if let base = rep.bitmapData {
            let rowBytes = rep.pixelsWide * (rep.bitsPerPixel / 8)
            for row in 0..<rep.pixelsHigh {
                hasher.update(data: Data(bytes: base + row * rep.bytesPerRow, count: rowBytes))
            }
        } else {
            hasher.update(data: rep.tiffRepresentation ?? Data())
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Self-check

    /// Cards whose chrome is built from dynamic system colors (`.labelColor` and
    /// friends), so `.aqua` and `.darkAqua` MUST paint different pixels. This list
    /// is the regression witness for the bug where every "different appearance"
    /// render came back byte-identical.
    ///
    /// Deliberately an explicit list, not every static card: several cards paint
    /// only fixed tokens (`.systemBlue`, `.systemOrange`) that do not flip with
    /// appearance, so a blanket "all cards must differ" gate would be false. Auditing
    /// each card's theming is the appearance-contrast gate's job (P0.4); this check
    /// only has to prove the *harness* delivers the appearance it was asked for.
    static let appearanceSensitiveEntryIds = ["agent.statusChip", "session.naming", "chrome.sidebar"]

    /// A card that paints a layer background through `NSColor.appResolvedCGColor`
    /// (`makePairingTokenView` → `controlBackgroundColor`). That helper resolves
    /// against `NSApp.effectiveAppearance`, so it is the one witness that catches a
    /// probe which sets only the *window* appearance: text would flip while the layer
    /// stayed dark. Asserted on a corner pixel, which the card's opaque stack fills.
    static let layerBackedWitnessEntryId = "auth.pairingToken"

    /// Asserts the probe delivers what it promises: the requested appearance
    /// actually reaches the view, the requested size actually holds, and two
    /// appearances of the same component actually differ.
    static func runUIProbeChecks() throws {
        _ = NSApplication.shared
        // Reproduce production's app-level pin (`ContinuumApp` sets this at launch).
        // A probe that forgot to set its own appearance would inherit dark here, so
        // the `.aqua` assertions below can only pass if the probe really works.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let entries = LabCatalog.entries(env: LabEnvironment(ghostty: nil, browserEngine: nil))
        let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]
        var probed = 0

        for entry in entries {
            guard case let .staticCard(preferredSize, make) = entry.content else { continue }
            let size = preferredSize ?? NSSize(width: 560, height: 640)
            for name in appearances {
                let result = try render(Spec(id: entry.id, size: size, appearance: name), make: make)

                guard result.host.effectiveAppearance.name == name else {
                    throw fail("\(entry.id): host effectiveAppearance is '\(result.host.effectiveAppearance.name.rawValue)', requested '\(name.rawValue)'")
                }
                guard result.view.effectiveAppearance.name == name else {
                    throw fail("\(entry.id): component effectiveAppearance is '\(result.view.effectiveAppearance.name.rawValue)', requested '\(name.rawValue)'")
                }
                guard result.host.bounds.size == size, result.view.bounds.size == size else {
                    throw fail("\(entry.id): laid out host \(result.host.bounds.size) / view \(result.view.bounds.size), requested \(size)")
                }
                let scale = result.window.backingScaleFactor
                let wantWide = Int((size.width * scale).rounded())
                let wantHigh = Int((size.height * scale).rounded())
                guard result.hostRep.pixelsWide == wantWide, result.hostRep.pixelsHigh == wantHigh else {
                    throw fail("\(entry.id): bitmap is \(result.hostRep.pixelsWide)x\(result.hostRep.pixelsHigh)px, requested \(size) at scale \(scale) (\(wantWide)x\(wantHigh))")
                }
                probed += 1
            }
        }
        guard probed > 0 else { throw fail("no static cards were probed") }

        for id in appearanceSensitiveEntryIds {
            guard let entry = entries.first(where: { $0.id == id }),
                  case let .staticCard(preferredSize, make) = entry.content else {
                throw fail("missing appearance-sensitive static card '\(id)'")
            }
            let size = preferredSize ?? NSSize(width: 560, height: 640)
            let light = try render(Spec(id: id, size: size, appearance: .aqua), make: make)
            let dark = try render(Spec(id: id, size: size, appearance: .darkAqua), make: make)

            guard light.contentDigest != dark.contentDigest else {
                throw fail("\(id): .aqua and .darkAqua component renders are byte-identical (\(light.contentDigest)) — the requested appearance is not reaching the view")
            }
            guard light.hostDigest != dark.hostDigest else {
                throw fail("\(id): .aqua and .darkAqua composed renders are byte-identical (\(light.hostDigest))")
            }
        }

        // Layer-backed witness: the pixel a `.appResolvedCGColor` layer painted must
        // itself flip. Digest inequality alone can be satisfied by text colour only.
        guard let layerEntry = entries.first(where: { $0.id == layerBackedWitnessEntryId }),
              case let .staticCard(layerSize, makeLayerView) = layerEntry.content else {
            throw fail("missing layer-backed witness card '\(layerBackedWitnessEntryId)'")
        }
        let layerProbeSize = layerSize ?? NSSize(width: 560, height: 640)
        let spec = { (name: NSAppearance.Name) in Spec(id: layerBackedWitnessEntryId, size: layerProbeSize, appearance: name) }
        let lightLayer = try render(spec(.aqua), make: makeLayerView)
        let darkLayer = try render(spec(.darkAqua), make: makeLayerView)
        func cornerLuminance(_ probe: Probed) throws -> Double {
            guard let color = probe.contentRep.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB) else {
                throw fail("\(layerBackedWitnessEntryId): could not read corner pixel of \(probe.spec.appearance.rawValue) render")
            }
            return 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
        }
        let lightLuminance = try cornerLuminance(lightLayer)
        let darkLuminance = try cornerLuminance(darkLayer)
        guard lightLuminance > darkLuminance + 0.25 else {
            throw fail("\(layerBackedWitnessEntryId): appResolvedCGColor layer did not follow the probe appearance — .aqua corner luminance \(lightLuminance) is not clearly brighter than .darkAqua's \(darkLuminance)")
        }

        // The probe must not leak its appearance onto the app.
        guard NSApp.appearance?.name == .darkAqua else {
            throw fail("probing mutated NSApp.appearance to '\(NSApp.appearance?.name.rawValue ?? "nil")'")
        }
        print("UIProbe: probed \(probed) card/appearance pairs; \(appearanceSensitiveEntryIds.count) appearance-difference witnesses held; layer witness luminance aqua=\(String(format: "%.3f", lightLuminance)) darkAqua=\(String(format: "%.3f", darkLuminance))")
    }
}
