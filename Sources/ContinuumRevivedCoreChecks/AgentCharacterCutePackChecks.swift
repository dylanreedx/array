import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// The two cute built-in packs, Burrow Buddies and Lunchbox Pals, drawn by
// scripts/make-cute-character-packs.py. Through the atlas the app uploads, in
// both appearances:
// - every loop, end clip, done and failed frame of every character exists and
//   has the figure on it (no blank or lost frame);
// - every working loop moves (its frames are not all one picture);
// - at the smallest size Array draws a character, the sidebar's 20 x 12 points
//   on a 1x display (4 x 4 art pixels to a device pixel), each character still
//   covers a readable figure, and any two characters of a pack differ by body
//   colour or by silhouette: what makes them tell-apart at a glance.
func runAgentCharacterCutePackChecks() {
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL agent character cute packs: \(message)\n", stderr)
            exit(1)
        }
    }

    for id in ["burrow-buddies", "lunchbox-pals"] {
        guard let theme = AgentCharacterBundled.theme(id: id) else {
            expect(false, "\(id): the pack does not load from the app's resources")
            return
        }
        expect(theme.characters.count >= 12, "\(id): at least 12 characters, got \(theme.characters.count)")
        expect(theme.scale == 4 && theme.frameWidth == 80 && theme.frameHeight == 48, "\(id): 80 x 48 frames at scale 4")

        // The smallest size: each idle frame box-filtered to 20 x 12.
        var masks: [Set<Int>] = []
        var colours: [(Double, Double, Double)] = []
        for appearance in AgentCharacterAtlas.Appearance.allCases {
            for (index, character) in theme.characters.enumerated() {
                let atlas = AgentCharacterAtlas(theme: theme, character: index, appearance: appearance)
                func ink(_ frame: Int) -> Int {
                    let rect = atlas.frames[frame]
                    var count = 0
                    for y in rect.y..<(rect.y + rect.height) {
                        for x in rect.x..<(rect.x + rect.width) where atlas.pixel(x: x, y: y).a == 255 { count += 1 }
                    }
                    return count
                }
                let name = "\(id) \(character.name) (\(appearance.rawValue))"
                for loop in AgentCharacterLoop.allCases {
                    let frames = atlas.frameIndices(of: loop)
                    expect(frames.count == character.frames(of: loop).count && frames.count >= 4,
                           "\(name): \(loop.rawValue) has \(frames.count) frames")
                    expect(Set(frames).count > 1, "\(name): \(loop.rawValue) does not move")
                    for frame in frames { expect(ink(frame) >= 600, "\(name): a \(loop.rawValue) frame is nearly empty") }
                }
                for clip in AgentCharacterClip.allCases {
                    let frames = atlas.frameIndices(of: clip)
                    expect(!frames.isEmpty && frames.count == (character.clips[clip]?.count ?? 0),
                           "\(name): \(clip.rawValue) has \(frames.count) frames")
                    for frame in frames { expect(ink(frame) >= 600, "\(name): a \(clip.rawValue) frame is nearly empty") }
                }
                for still in [AgentCharacterStill.done, .failed] {
                    expect(ink(atlas.frameIndex(of: still)) >= 600, "\(name): \(still) is nearly empty")
                }

                guard appearance == .dark else { continue }
                let idle = atlas.frames[atlas.frameIndex(of: .clip(.idle))]
                var mask = Set<Int>()
                var sum = (0.0, 0.0, 0.0), opaque = 0.0
                for cy in 0..<12 {
                    for cx in 0..<20 {
                        var covered = 0
                        for dy in 0..<4 {
                            for dx in 0..<4 {
                                let p = atlas.pixel(x: idle.x + cx * 4 + dx, y: idle.y + cy * 4 + dy)
                                guard p.a == 255 else { continue }
                                covered += 1
                                sum.0 += Double(p.r); sum.1 += Double(p.g); sum.2 += Double(p.b); opaque += 1
                            }
                        }
                        if covered >= 8 { mask.insert(cy * 20 + cx) }
                    }
                }
                expect(mask.count >= 40, "\(name): at 20 x 12 the figure covers only \(mask.count) device pixels")
                masks.append(mask)
                colours.append((sum.0 / opaque, sum.1 / opaque, sum.2 / opaque))
            }
        }
        for i in masks.indices {
            for j in masks.indices where j > i {
                let silhouette = masks[i].symmetricDifference(masks[j]).count
                let (a, b) = (colours[i], colours[j])
                let colour = ((a.0 - b.0) * (a.0 - b.0) + (a.1 - b.1) * (a.1 - b.1) + (a.2 - b.2) * (a.2 - b.2)).squareRoot()
                expect(silhouette >= 8 || colour >= 40,
                       "\(id): \(theme.characters[i].name) and \(theme.characters[j].name) look alike at 20 x 12 (silhouette \(silhouette) px apart, colour \(Int(colour)) apart)")
            }
        }
    }
    print("agent character cute packs: burrow-buddies and lunchbox-pals load every frame in both appearances, every working loop moves, and every character is legible and distinct at 20 x 12")
}
