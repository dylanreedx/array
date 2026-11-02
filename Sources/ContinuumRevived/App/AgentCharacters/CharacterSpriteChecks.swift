import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Darwin

// Plan: .plans/110-agent-characters/README.md, slice 3.
//
// `--character-sprite-check`: 100 real sprites in an offscreen fixture window for
// ten seconds. Counts, not times (docs/internals/performance.md): no layout or
// display caused by sprites, one animation install per plan change and none for a
// re-applied plan, one shared picture per character, pause and resume, and the
// model frame's pixels against the parser's letters.
@MainActor
enum CharacterSpriteChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// A host that counts every layout and display pass it is asked for.
    final class CountingHost: NSView {
        var layouts = 0
        var draws = 0
        override var isFlipped: Bool { true }
        override func layout() { layouts += 1; super.layout() }
        override func draw(_ dirtyRect: NSRect) { draws += 1 }
    }

    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static func run(seconds: TimeInterval = 10) throws {
        let suite = "ArrayCharacterSpriteChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AgentCharacterController.shared
        controller.reduceMotion = { false }
        defaults.set(true, forKey: AgentCharacterConfig.enabledKey)
        controller.adopt(defaults: defaults)
        guard let theme = controller.theme else { throw Failure(description: "the built-in set did not load") }

        // 1. Pixels: the model frame, rendered by Core Animation, is the parser's frame.
        try checkPixels(theme: theme, controller: controller)

        // 2. 100 sprites in a real window.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = CountingHost(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        host.wantsLayer = true
        window.contentView = host
        window.orderFrontOffscreenForChecks()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        try checkWindowPixels(theme: theme, controller: controller, window: window, host: host)

        let now = Date()
        let ids = (0..<100).map { _ in UUID() }
        var sprites: [CharacterSpriteLayer] = []
        let loops = AgentCharacterLoop.allCases
        for (n, id) in ids.enumerated() {
            let sprite = CharacterSpriteLayer()
            sprite.frame = CGRect(x: CGFloat(n % 20) * 24, y: CGFloat(n / 20) * 16, width: 20, height: 12)
            host.layer?.addSublayer(sprite)
            sprites.append(sprite)
            let snapshot = AgentCharacterSnapshot(
                state: .working, activity: .init(action: loops[n % loops.count], lastOutputAt: now))
            guard let atlas = controller.atlas(for: id, appearance: .dark) else { throw Failure(description: "no atlas") }
            sprite.show(controller.plan(for: snapshot, now: now), sprite: atlas,
                        phase: AgentCharacterConfig.phase(for: id), now: now)
        }
        CATransaction.flush()
        let installsAfterShow = CharacterSpriteLayer.installCount
        try expect(sprites.allSatisfy(\.isAnimating), "every working sprite animates")
        // One shared picture per character: at most 8 atlases for 100 sprites, and
        // two sprites of one character hold the identical image object.
        try expect(controller.atlasBuilds <= theme.characters.count,
                   "atlases are built once per character (\(controller.atlasBuilds) for 100 sprites)")
        var byCharacter: [Int: CharacterSpriteLayer] = [:]
        var shared = 0
        for (n, id) in ids.enumerated() {
            let index = controller.characterIndex(for: id)!
            if let first = byCharacter[index] {
                try expect((first.contents as AnyObject) === (sprites[n].contents as AnyObject),
                           "two sprites of character \(index) share one contents object")
                shared += 1
            } else {
                byCharacter[index] = sprites[n]
            }
        }
        try expect(shared > 0, "the fixture has two sprites of one character")

        // Re-applying the same plan installs nothing.
        for (n, id) in ids.enumerated() {
            let snapshot = AgentCharacterSnapshot(
                state: .working, activity: .init(action: loops[n % loops.count], lastOutputAt: now))
            sprites[n].show(controller.plan(for: snapshot, now: now.addingTimeInterval(1)),
                            sprite: controller.atlas(for: id, appearance: .dark)!, phase: AgentCharacterConfig.phase(for: id),
                            now: now.addingTimeInterval(1))
        }
        try expect(CharacterSpriteLayer.installCount == installsAfterShow, "a re-applied plan installs nothing")

        // Ten seconds of animation: count host layouts, draws and main-thread CPU.
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
        let layoutsBefore = host.layouts, drawsBefore = host.draws
        let cpuBefore = threadCPU()
        var seen = Set<String>()
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if let rect = sprites[0].presentation()?.contentsRect { seen.insert("\(rect)") }
        }
        let cpu = threadCPU() - cpuBefore
        try expect(host.layouts == layoutsBefore, "sprites caused \(host.layouts - layoutsBefore) layout passes")
        try expect(host.draws == drawsBefore, "sprites caused \(host.draws - drawsBefore) draws")
        try expect(CharacterSpriteLayer.installCount == installsAfterShow, "animation is installed once, not per frame")
        try expect(seen.count >= 4, "sprite 0 really moved (\(seen.count) distinct frames)")

        // A state change: exactly one install per changed sprite.
        for n in 0..<10 {
            let snapshot = AgentCharacterSnapshot(state: .approval)
            sprites[n].show(controller.plan(for: snapshot, now: Date()),
                            sprite: controller.atlas(for: ids[n], appearance: .dark)!, phase: 0)
        }
        try expect(CharacterSpriteLayer.installCount == installsAfterShow + 10, "ten state changes, ten installs")

        // Pause keeps the still frame and removes the animation; resume restores it.
        let paused = sprites[20]
        let stillRect = paused.contentsRect
        paused.setPaused(true)
        try expect(!paused.isAnimating && paused.contentsRect == stillRect, "a paused sprite holds its still frame")
        paused.setPaused(false)
        try expect(paused.isAnimating, "resuming restores the animation")
        // A resting state holds still with no animation at all.
        sprites[21].show(controller.plan(for: AgentCharacterSnapshot(state: .ready, activity: .init(outcome: .succeeded)), now: Date()),
                         sprite: controller.atlas(for: ids[21], appearance: .dark)!, phase: 0)
        try expect(!sprites[21].isAnimating, "a resting agent holds still")
        // Reduce Motion: every state still.
        controller.reduceMotion = { true }
        sprites[22].show(controller.plan(for: AgentCharacterSnapshot(state: .working, activity: .init(action: .type)), now: Date()),
                         sprite: controller.atlas(for: ids[22], appearance: .dark)!, phase: 0)
        try expect(!sprites[22].isAnimating, "Reduce Motion holds a working agent still")
        controller.reduceMotion = { false }
        // Off: nothing resident.
        defaults.set(false, forKey: AgentCharacterConfig.enabledKey)
        controller.reload()
        try expect(controller.theme == nil && controller.atlas(for: ids[0], appearance: .dark) == nil,
                   "off keeps no theme and builds no atlas")

        let percent = cpu / seconds * 100
        print("Character sprite checks passed: 100 sprites x \(Int(seconds)) s, 0 layouts, 0 draws, \(installsAfterShow) installs for 100 plans and 0 while animating, \(controller.atlasBuilds) shared atlases, sprite 0 showed \(seen.count) frames, main-thread CPU \(String(format: "%.2f", percent))% (fixture's own 50 ms run-loop polling included)")
    }

    /// Render the model layer with Core Animation at 1 px per art pixel and compare
    /// every pixel with the parser's frame. (A geometry-flipped ROOT renders mirrored
    /// into a bare bitmap, so the flipped case is witnessed in a real window below.)
    private static func checkPixels(theme: AgentCharacterTheme, controller: AgentCharacterController) throws {
        let character = 3
        guard let sprite = controller.atlas(theme: theme, character: character, appearance: .dark) else {
            throw Failure(description: "no atlas")
        }
        let w = theme.frameWidth, h = theme.frameHeight
        for flippedHost in [false] {
            for still in [AgentCharacterStill.done, .failed, .loop(.type), .clip(.wave)] {
                let parent = CALayer()
                parent.isGeometryFlipped = flippedHost
                parent.frame = CGRect(x: 0, y: 0, width: w, height: h)
                let layer = CharacterSpriteLayer()
                parent.addSublayer(layer)
                layer.frame = parent.bounds
                layer.show(.still(still), sprite: sprite, phase: 0)
                var out = [UInt8](repeating: 0, count: w * h * 4)
                guard let context = CGContext(data: &out, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                parent.render(in: context)
                let frame = theme.characters[character].frame(of: still)
                for (y, row) in frame.enumerated() {
                    for (x, scalar) in row.unicodeScalars.enumerated() {
                        let i = (y * w + x) * 4
                        if scalar == "." {
                            try expect(out[i + 3] == 0, "\(still) (\(x),\(y)) is clear (flipped host \(flippedHost))")
                        } else {
                            let colour = theme.colour(of: Character(scalar), in: theme.characters[character])!
                            try expect(out[i + 3] == 255 && abs(Int(out[i]) - Int(colour.red)) <= 1
                                       && abs(Int(out[i + 1]) - Int(colour.green)) <= 1
                                       && abs(Int(out[i + 2]) - Int(colour.blue)) <= 1,
                                       "\(still) (\(x),\(y)) draws its palette colour (flipped host \(flippedHost))")
                        }
                    }
                }
            }
        }
    }

    /// The flipped case through the window server: a sprite in the real flipped
    /// host beside a REFERENCE layer that shows the parser's frame as a plain image
    /// (no atlas, no contentsRect). Both go through the same colour pipeline, so
    /// the two captured regions must match pixel for pixel.
    private static func checkWindowPixels(theme: AgentCharacterTheme, controller: AgentCharacterController,
                                          window: NSWindow, host: NSView) throws {
        let character = 5
        guard let sprite = controller.atlas(theme: theme, character: character, appearance: .dark) else {
            throw Failure(description: "no atlas")
        }
        let w = theme.frameWidth, h = theme.frameHeight
        let pt: CGFloat = 4
        let layer = CharacterSpriteLayer()
        let reference = CALayer()
        reference.magnificationFilter = .nearest
        reference.contentsGravity = .resize
        for (l, x) in [(layer as CALayer, CGFloat(300)), (reference, CGFloat(300 + CGFloat(w) * pt + 20))] {
            l.frame = CGRect(x: x, y: 300, width: CGFloat(w) * pt, height: CGFloat(h) * pt)
            host.layer?.addSublayer(l)
        }
        defer { layer.removeFromSuperlayer(); reference.removeFromSuperlayer() }
        for still in [AgentCharacterStill.done, .loop(.read), .clip(.wave)] {
            let frame = theme.characters[character].frame(of: still)
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            for (y, row) in frame.enumerated() {
                for (x, scalar) in row.unicodeScalars.enumerated() where scalar != "." {
                    let c = theme.colour(of: Character(scalar), in: theme.characters[character])!
                    pixels.replaceSubrange((y * w + x) * 4..<(y * w + x) * 4 + 4, with: [c.red, c.green, c.blue, 255])
                }
            }
            let provider = CGDataProvider(data: Data(pixels) as CFData)!
            reference.contents = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            layer.show(.still(still), sprite: sprite, phase: 0)
            CATransaction.flush()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                                      [.boundsIgnoreFraming, .bestResolution]) else {
                throw Failure(description: "own-window capture unavailable")
            }
            let rep = NSBitmapImageRep(cgImage: image)
            let scale = CGFloat(rep.pixelsWide) / window.frame.width
            var mismatches: [String] = []
            var distinct = Set<String>()
            for y in 0..<h {
                for x in 0..<w {
                    let py = Int(((300 + (CGFloat(y) + 0.5) * pt) * scale).rounded(.down))
                    let spriteX = Int(((300 + (CGFloat(x) + 0.5) * pt) * scale).rounded(.down))
                    let refX = Int(((300 + CGFloat(w) * pt + 20 + (CGFloat(x) + 0.5) * pt) * scale).rounded(.down))
                    let a = rep.colorAt(x: spriteX, y: py), b = rep.colorAt(x: refX, y: py)
                    if a != b { mismatches.append("(\(x),\(y))") }
                    distinct.insert(a.map { "\($0)" } ?? "nil")
                }
            }
            try expect(distinct.count >= 3, "\(still): the capture saw the figure (\(distinct.count) colours)")
            try expect(mismatches.isEmpty,
                       "\(still) in a flipped window differs from the parser's frame at \(mismatches.count) pixels, e.g. \(mismatches.prefix(4))")
        }
    }

    /// This thread's user + system CPU seconds.
    private static func threadCPU() -> TimeInterval {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return TimeInterval(info.user_time.seconds) + TimeInterval(info.user_time.microseconds) / 1e6
            + TimeInterval(info.system_time.seconds) + TimeInterval(info.system_time.microseconds) / 1e6
    }
}
