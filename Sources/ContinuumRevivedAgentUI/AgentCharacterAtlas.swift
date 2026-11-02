import Foundation

// Plan: .plans/110-agent-characters/README.md (slice 1, §5.2 rule 1)
/// One character's every distinct frame, packed into one RGBA grid at one pixel
/// per art pixel.
///
/// Every sprite showing this character points at the same image and steps through
/// it by changing `contentsRect`, so the image is decoded and uploaded once however
/// many rows and tiles show it. A grid rather than one row, because a `scale: 4`
/// character can be wider than a GPU texture as a single strip.
///
/// Platform-neutral bytes; the app wraps them in one `CGImage`.
public struct AgentCharacterAtlas: Equatable, Sendable {
    public enum Appearance: String, CaseIterable, Equatable, Hashable, Sendable {
        case dark
        /// Adds a 1 px tonal outline on clear pixels touching the figure, so pale
        /// characters stay visible on a light row. No art pixel changes.
        case light
    }

    /// A rectangle in the atlas, in pixels, origin top-left.
    public struct PixelRect: Equatable, Hashable, Sendable {
        public let x: Int, y: Int, width: Int, height: Int
    }

    public let appearance: Appearance
    public let width: Int
    public let height: Int
    /// Premultiplied RGBA, 8 bits a channel, rows top-down.
    public let pixels: [UInt8]
    public let frameWidth: Int
    public let frameHeight: Int
    /// Where each distinct frame sits.
    public let frames: [PixelRect]
    private let loopFrames: [AgentCharacterLoop: [Int]]
    private let clipFrames: [AgentCharacterClip: [Int]]
    private let doneFrame: Int
    private let failedFrame: Int

    /// Frames are 1 px apart, so a sampler at a frame's edge can never reach its neighbour.
    static let gutter = 1
    /// Width the grid is kept under.
    static let maximumWidth = 4096

    public func frameIndices(of loop: AgentCharacterLoop) -> [Int] { loopFrames[loop] ?? [doneFrame] }
    public func frameIndices(of clip: AgentCharacterClip) -> [Int] { clipFrames[clip] ?? [doneFrame] }
    public func frameIndex(of still: AgentCharacterStill) -> Int {
        switch still {
        case .done: return doneFrame
        case .failed: return failedFrame
        case let .loop(loop): return frameIndices(of: loop)[0]
        case let .clip(clip): return frameIndices(of: clip)[0]
        }
    }

    /// `frame` as a unit rectangle, origin top-left.
    public func unitRect(of frame: Int) -> (x: Double, y: Double, width: Double, height: Double) {
        let rect = frames[frame]
        return (Double(rect.x) / Double(width), Double(rect.y) / Double(height),
                Double(rect.width) / Double(width), Double(rect.height) / Double(height))
    }

    /// The premultiplied RGBA of the atlas pixel at (`x`, `y`).
    public func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }

    public init(theme: AgentCharacterTheme, character index: Int, appearance: Appearance) {
        let character = theme.characters[index]
        let fw = theme.frameWidth, fh = theme.frameHeight
        var unique: [AgentCharacterFrame] = []
        var lookup: [AgentCharacterFrame: Int] = [:]
        func intern(_ frame: AgentCharacterFrame) -> Int {
            if let known = lookup[frame] { return known }
            unique.append(frame)
            lookup[frame] = unique.count - 1
            return unique.count - 1
        }
        doneFrame = intern(character.done)
        failedFrame = intern(character.failed)
        var loops: [AgentCharacterLoop: [Int]] = [:]
        for loop in AgentCharacterLoop.allCases { loops[loop] = character.frames(of: loop).map(intern) }
        var clips: [AgentCharacterClip: [Int]] = [:]
        for clip in AgentCharacterClip.allCases where character.clips[clip] != nil {
            clips[clip] = character.frames(of: clip).map(intern)
        }
        loopFrames = loops
        clipFrames = clips

        let pitchX = fw + Self.gutter, pitchY = fh + Self.gutter
        let square = Int(Double(unique.count).squareRoot().rounded(.up))
        let columns = max(1, min(unique.count, square, Self.maximumWidth / pitchX))
        let rows = (unique.count + columns - 1) / columns
        width = columns * pitchX - Self.gutter
        height = rows * pitchY - Self.gutter
        frameWidth = fw
        frameHeight = fh
        self.appearance = appearance
        frames = unique.indices.map { PixelRect(x: ($0 % columns) * pitchX, y: ($0 / columns) * pitchY, width: fw, height: fh) }

        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        // Resolve each letter once: the character's own colours win.
        var colours: [Character: AgentCharacterColour] = theme.palette
        for (letter, colour) in character.colours { colours[letter] = colour }
        for (n, frame) in unique.enumerated() {
            let origin = frames[n]
            var grid = [AgentCharacterColour?](repeating: nil, count: fw * fh)
            for (y, row) in frame.enumerated() {
                // Scalars, not Characters: every letter is one scalar, and a combining
                // letter must not merge with its neighbour into one grapheme.
                for (x, scalar) in row.unicodeScalars.enumerated() where scalar != "." && x < fw {
                    grid[y * fw + x] = colours[Character(scalar)]
                }
            }
            for y in 0..<fh {
                for x in 0..<fw {
                    let at = ((origin.y + y) * width + origin.x + x) * 4
                    if let colour = grid[y * fw + x] {
                        buffer[at] = colour.red
                        buffer[at + 1] = colour.green
                        buffer[at + 2] = colour.blue
                        buffer[at + 3] = 255
                    } else if appearance == .light,
                              let tone = Self.outlineTone(grid: grid, x: x, y: y, width: fw, height: fh) {
                        buffer[at] = tone.r
                        buffer[at + 1] = tone.g
                        buffer[at + 2] = tone.b
                        buffer[at + 3] = tone.a
                    }
                }
            }
        }
        pixels = buffer
    }

    /// Alpha of the light outline.
    public static let outlineAlpha: UInt8 = 150

    /// The outline for a clear pixel: its edge-sharing figure neighbours' colour,
    /// darkened to half, at `outlineAlpha`, premultiplied. nil when no neighbour is figure.
    static func outlineTone(grid: [AgentCharacterColour?], x: Int, y: Int, width: Int, height: Int)
        -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        var sum = (r: 0, g: 0, b: 0), count = 0
        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
            let nx = x + dx, ny = y + dy
            guard nx >= 0, ny >= 0, nx < width, ny < height, let colour = grid[ny * width + nx] else { continue }
            sum.r += Int(colour.red)
            sum.g += Int(colour.green)
            sum.b += Int(colour.blue)
            count += 1
        }
        guard count > 0 else { return nil }
        let alpha = Int(outlineAlpha)
        // Half the neighbours' tone, then premultiplied by the outline's alpha.
        func channel(_ total: Int) -> UInt8 { UInt8((total / count / 2) * alpha / 255) }
        return (channel(sum.r), channel(sum.g), channel(sum.b), outlineAlpha)
    }
}
