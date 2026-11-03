import Foundation

// Plan: .plans/110-agent-characters/README.md › "Duckherd themes as they ship".
//
// Checks only. A character set built in code with the shape of the theme files
// Duckherd users share (the Bleach set): `scale: 4`, a 151-letter palette,
// `marks`, `stuck`, 16 helpers with their own colours and every reaction set,
// lead frames stored trimmed (rows stop at their last figure pixel, trailing
// clear rows dropped, the first row often empty) at 76 to 111 rows and up to 112
// wide, `lead.shift`, a level that is another level's index, and `voices`. The
// art is plain shapes drawn here: no figure from anyone's set is copied.
public enum AgentCharacterDuckherdFixture {
    public static let id = "duckherd-shaped"
    public static let helperCount = 16
    /// The shape of the lead's frames, as the Bleach set's are.
    public static let restFrames = 4
    public static let risingFrames = 29
    public static let shiftFrames = 2
    /// Levels: 9 frames, then level 0 again by index, then 16 frames.
    public static let levelFrameCounts = [9, 16]
    /// The tallest lead frame and the widest lead row, in art pixels.
    public static let tallestLeadFrame = 111
    public static let widestLeadRow = 112

    /// 151 one-unit letters: printable ASCII without `.`, `"` and `\`, then À…û.
    public static let paletteLetters: [Character] = {
        var out: [Character] = []
        for value in 33...126 where ![46, 34, 92].contains(value) { out.append(Character(UnicodeScalar(UInt8(value)))) }
        for value in 0xC0...0xFB { out.append(Character(UnicodeScalar(value)!)) }
        return out
    }()

    static func hex(_ seed: Int) -> String {
        let value = (seed &* 2_654_435_761) & 0xFFFFFF
        return String(format: "#%06X", value)
    }

    /// A helper frame: 80 x 48, a body and a head that move with `step`.
    static func helperFrame(_ helper: Int, _ step: Int, _ letters: [Character]) -> [String] {
        var grid = Array(repeating: Array(repeating: Character("."), count: 80), count: 48)
        let dx = (step % 4) * 2 - 3, dy = step % 2
        for y in 0..<48 {
            for x in 0..<80 {
                let bx = Double(x - 40 - dx) / 22, by = Double(y - 30 - dy) / 14
                let hx = Double(x - 46 - dx) / 10, hy = Double(y - 12 - dy) / 9
                if bx * bx + by * by <= 1 { grid[y][x] = letters[(x / 8 + y / 6 + helper) % letters.count] }
                if hx * hx + hy * hy <= 1 { grid[y][x] = letters[(helper + 3) % letters.count] }
            }
        }
        return grid.map { String($0) }
    }

    /// A lead frame, trimmed as the shared sets store it: `height` rows, each
    /// ending at its last figure pixel. The figure stands on row 80 at most
    /// heights; a taller frame adds a spark field down to its last row.
    static func leadFrame(_ step: Int, height: Int, width: Int, letters: [Character]) -> [String] {
        var grid = Array(repeating: Array(repeating: Character("."), count: width), count: height)
        let ground = min(height - 1, 80)
        let left = max(0, min(width - 40, 20 + (step % 5) * 3))
        for y in 0..<height {
            for x in 0..<width {
                let figure = y >= ground - 50 && y <= ground && x >= left && x < left + 36
                    && ((x - left) * (x - left) + (y - (ground - 25)) * (y - (ground - 25)) / 2) < 420 + step
                let spark = height > 81 && (x * 7 + y * 3 + step) % 23 == 0
                if figure { grid[y][x] = letters[(y / 7 + step) % letters.count] } else if spark { grid[y][x] = letters[(x + step) % letters.count] }
            }
        }
        // Mark the last row and the last column so every frame really reaches
        // its stated height and width, as the trimmed frames do.
        grid[height - 1][left] = letters[0]
        grid[ground][width - 1] = letters[1]
        var rows = grid.map { row -> String in
            var text = String(row)
            while text.hasSuffix(".") { text.removeLast() }
            return text
        }
        rows[0] = ""
        return rows
    }

    /// The fixture's JSON text.
    public static func text(helpers count: Int = helperCount, leadLevels: [Any]? = nil,
                            leadSize: [Int]? = nil, extraLead: [String: Any] = [:]) -> String {
        let letters = paletteLetters
        var palette: [String: String] = [:]
        for (index, letter) in letters.enumerated() { palette[String(letter)] = hex(index + 1) }
        let names = (0..<count).map { "Helper\(Character(UnicodeScalar(65 + $0 % 26)!))\($0)" }
        var helpers: [[String: Any]] = []
        for index in 0..<count {
            let own = Array(letters[(index * 5)..<(index * 5 + 40)])
            var colours: [String: String] = [:]
            for (n, letter) in own.enumerated() { colours[String(letter)] = hex(1000 + index * 50 + n) }
            func set(_ frames: Int, _ base: Int) -> [[String]] { (0..<frames).map { helperFrame(index, base + $0, own) } }
            let loops = ["dabble", "read", "type", "run", "think"].enumerated().reduce(into: [String: Any]()) { out, item in
                out[item.element] = ["frameMs": [400, 500, 220, 140, 450][item.offset], "frames": set(4, item.offset * 4)]
            }
            helpers.append([
                "name": names[index], "names": [names[index], "Alt\(index)"],
                "colors": colours, "loops": loops,
                "ends": [
                    "done": helperFrame(index, 30, own), "failed": helperFrame(index, 31, own),
                    "cheer": set(2, 32), "droop": set(2, 34), "asleep": set(3, 36), "idle": set(4, 39),
                    "idleMove": set(2, 43), "flinch": set(2, 45), "wave": set(2, 47), "noticed": set(2, 49),
                ],
            ])
        }
        let leadLetters = Array(letters[100..<130])
        let risingHeights = (0..<risingFrames).map { [81, 81, 87, 111, 97, 81][$0 % 6] }
        let risingWidths = (0..<risingFrames).map { $0 % 6 == 3 ? widestLeadRow : 105 }
        var lead: [String: Any] = [
            "rest": (0..<restFrames).map { leadFrame($0, height: 81, width: 87, letters: leadLetters) },
            "rising": (0..<risingFrames).map {
                leadFrame($0, height: risingHeights[$0], width: risingWidths[$0], letters: leadLetters)
            },
            "shift": (0..<shiftFrames).map { leadFrame(40 + $0, height: 81, width: 77, letters: leadLetters) },
            "levels": leadLevels ?? [
                (0..<levelFrameCounts[0]).map { leadFrame(50 + $0, height: 81, width: 59, letters: leadLetters) },
                0,
                (0..<levelFrameCounts[1]).map {
                    leadFrame(60 + $0, height: [81, 86, 76, 99][$0 % 4], width: [77, 94, 91, 104][$0 % 4], letters: leadLetters)
                },
            ],
        ]
        for (key, value) in extraLead { lead[key] = value }
        var json: [String: Any] = [
            "duckherdTheme": 1, "id": id, "title": "Duckherd-shaped set", "scale": 4,
            "palette": palette,
            "marks": ["star": "1", "starLit": "2", "drop": "3", "dropLit": "4", "asked": "5", "told": "6"],
            "stuck": ["drop": [1, 4], "mark": 18],
            "helpers": helpers, "lead": lead,
            "voices": [
                "spawn": ["voice/lead-1.mp3", "voice/lead-2.mp3"],
                "done": Dictionary(uniqueKeysWithValues: names.map { ($0, ["voice/\($0.lowercased()).mp3"]) }),
                "any": ["voice/any.mp3"],
            ],
        ]
        if let leadSize { json["leadSize"] = leadSize }
        let data = try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
