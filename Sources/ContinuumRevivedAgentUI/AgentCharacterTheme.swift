import Foundation

// Plan: .plans/110-agent-characters/README.md (slice 1, §2)
//
// Agent characters: small pixel figures beside an agent's provider mark that act
// out what the agent is doing. A set of characters is one JSON "theme" file in the
// v1 format published with an MIT-licensed Claude Code plugin; Array reads that
// format so the files people already have work unchanged. The format's rules and
// its problem messages are the reference parser's, word for word, so a file is
// accepted or refused here exactly as it is there (CoreChecks
// `--agent-character-theme-check` holds a corpus recorded against it).
//
// Platform-neutral on purpose: the iOS companion can draw the same characters.

/// One of the five work loops every character has.
public enum AgentCharacterLoop: String, CaseIterable, Equatable, Hashable, Sendable {
    /// Searching: splashing about in water.
    case dabble
    case read
    /// Editing: pecking at a laptop.
    case type
    /// Running a command: running with a stopwatch.
    case run
    case think
}

/// The reaction sets: one-shot clips and act-now loops.
public enum AgentCharacterClip: String, CaseIterable, Equatable, Hashable, Sendable {
    case cheer, droop, asleep, idle, idleMove, flinch, wave, noticed
}

/// A held pose: what a still character shows.
public enum AgentCharacterStill: Equatable, Hashable, Sendable {
    case done
    case failed
    /// The first frame of a loop.
    case loop(AgentCharacterLoop)
    /// The first frame of a clip.
    case clip(AgentCharacterClip)
}

/// A frame: `height` rows of `width` palette letters, `.` for clear.
public typealias AgentCharacterFrame = [String]

/// An sRGB colour from a `#rrggbb` palette entry.
public struct AgentCharacterColour: Equatable, Hashable, Sendable {
    public let red: UInt8, green: UInt8, blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `#rrggbb`, exactly: seven characters, hex digits in either case.
    public init?(hex: String) {
        let scalars = Array(hex.unicodeScalars)
        guard scalars.count == 7, scalars[0] == "#",
              scalars.dropFirst().allSatisfy(\.properties.isASCIIHexDigit),
              let value = UInt32(String(hex.dropFirst()), radix: 16) else { return nil }
        red = UInt8((value >> 16) & 0xFF)
        green = UInt8((value >> 8) & 0xFF)
        blue = UInt8(value & 0xFF)
    }
}

/// One character of a theme.
public struct AgentCharacter: Equatable, Sendable {
    public struct Loop: Equatable, Sendable {
        /// The theme's own pace, 50…5000 ms per frame.
        public let frameMs: Double
        public let frames: [AgentCharacterFrame]
    }

    public let name: String
    /// Agent-type names the theme gives this character. Array assigns characters
    /// by a hash of the agent id instead, so these are read and kept, not used.
    public let names: [String]
    /// Extra palette letters for this character only; they override the theme's.
    public let colours: [Character: AgentCharacterColour]
    public let loops: [AgentCharacterLoop: Loop]
    public let done: AgentCharacterFrame
    public let failed: AgentCharacterFrame
    /// Every reaction set; `idleMove` is optional in the format and absent here
    /// when the file has none.
    public let clips: [AgentCharacterClip: [AgentCharacterFrame]]

    public func frames(of loop: AgentCharacterLoop) -> [AgentCharacterFrame] { loops[loop]?.frames ?? [done] }
    public func frames(of clip: AgentCharacterClip) -> [AgentCharacterFrame] { clips[clip] ?? [done] }

    /// The frame a still character in `pose` shows.
    public func frame(of still: AgentCharacterStill) -> AgentCharacterFrame {
        switch still {
        case .done: return done
        case .failed: return failed
        case let .loop(loop): return frames(of: loop)[0]
        case let .clip(clip): return frames(of: clip)[0]
        }
    }
}

/// A parsed, valid theme.
public struct AgentCharacterTheme: Equatable, Sendable {
    public let id: String
    public let title: String
    /// 1, or 4 for art drawn at four times the size into the same space.
    public let scale: Int
    /// A character frame's size in art pixels.
    public let frameWidth: Int
    public let frameHeight: Int
    public let palette: [Character: AgentCharacterColour]
    public let characters: [AgentCharacter]
    /// Whether the file has art for an orchestrating lead. Read and validated;
    /// Array does not draw a lead yet.
    public let hasLead: Bool

    /// The colour of `letter` for `character`: its own colours first.
    public func colour(of letter: Character, in character: AgentCharacter) -> AgentCharacterColour? {
        character.colours[letter] ?? palette[letter]
    }
}

/// Why a file is not a theme: the first eight problems, each saying where.
public struct AgentCharacterThemeProblems: Error, Equatable, Sendable {
    public let messages: [String]
    public init(messages: [String]) { self.messages = messages }
}

public enum AgentCharacterThemeParser {
    /// The reference parser's text cap, in UTF-16 code units.
    public static let maximumTextLength = 3_000_000
    /// The reference runtime's read cap; a larger file is refused unread.
    public static let maximumFileBytes = 4 * 1024 * 1024
    public static let maximumProblems = 8
    public static let reservedID = "ducks"

    private static let actions = AgentCharacterLoop.allCases
    private static let frameSets: [AgentCharacterClip] = [.cheer, .droop, .asleep, .idle, .flinch, .wave, .noticed]
    private static let soundKinds = ["quack", "honk", "chirp", "snore"]

    public static func parse(data: Data) -> Result<AgentCharacterTheme, AgentCharacterThemeProblems> {
        guard data.count <= maximumFileBytes else {
            return .failure(.init(messages: ["the file is over 3 MB"]))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(.init(messages: ["not valid JSON"]))
        }
        return parse(text: text)
    }

    // The order of every check below is the reference parser's: the first eight
    // problems are what a person sees, so the order is part of the contract.
    public static func parse(text: String) -> Result<AgentCharacterTheme, AgentCharacterThemeProblems> {
        var errors: [String] = []
        func bad(_ message: String) {
            if errors.count < maximumProblems { errors.append(message) }
        }
        if text.utf16.count > maximumTextLength { return .failure(.init(messages: ["the file is over 3 MB"])) }
        let raw: AgentCharacterJSON
        do { raw = try AgentCharacterJSON.parse(text) } catch {
            return .failure(.init(messages: ["not valid JSON"]))
        }
        guard raw.isObject else { return .failure(.init(messages: ["the file is not a JSON object"])) }

        if raw["duckherdTheme"]?.numberValue != 1 { bad("\"duckherdTheme\": 1 is missing") }
        let id = raw["id"]?.stringValue ?? ""
        if !isThemeID(id) || id == reservedID {
            bad("\"id\" must be lowercase letters, digits and dashes, and not \"ducks\"")
        }
        let scaleValue = raw["scale"] ?? .number(1)
        if scaleValue != .number(1) && scaleValue != .number(4) { bad("\"scale\" must be 1 or 4") }
        let px = scaleValue == .number(4) ? 4 : 1

        func size(_ key: String, width defaultWidth: Int, height defaultHeight: Int) -> (w: Int, h: Int) {
            guard let value = raw[key] else { return (defaultWidth * px, defaultHeight * px) }
            let pair = value.arrayValue.flatMap { $0.count == 2 ? $0 : nil }
            let cellW = 2 * px, cellH = 4 * px
            if let w = pair?[0].integerValue, let h = pair?[1].integerValue, w > 0, h > 0,
               w % cellW == 0, h % cellH == 0, w / cellW <= 40, h / cellH <= 8 {
                return (w, h)
            }
            bad("\"\(key)\" is [width, height] in pixels: whole cells, a multiple of \(cellW) wide (at most \(40 * cellW)) and of \(cellH) tall (at most \(8 * cellH)) at scale \(px)")
            return (defaultWidth * px, defaultHeight * px)
        }
        let helperSize = size("helperSize", width: 20, height: 12)
        let leadSize = size("leadSize", width: 28, height: 16)

        var palette: [Character: AgentCharacterColour] = [:]
        if case let .object(entries)? = raw["palette"] {
            for (key, value) in entries {
                if !isOneLetter(key) || key == "." {
                    bad("palette key \(jsonQuoted(key)): one character, not \".\"")
                } else if let hex = value.stringValue, let colour = AgentCharacterColour(hex: hex) {
                    palette[Character(key)] = colour
                } else {
                    bad("palette \(key): a #rrggbb colour")
                }
            }
        } else {
            bad("\"palette\" is missing")
        }

        func frame(_ value: AgentCharacterJSON?, _ size: (w: Int, h: Int), _ at: String,
                   _ known: Set<Character>) -> AgentCharacterFrame? {
            guard let rows = value?.arrayValue, rows.count == size.h,
                  let strings = Optional(rows.compactMap(\.stringValue)), strings.count == rows.count else {
                bad("\(at): a frame is \(size.h) rows of text")
                return nil
            }
            for row in strings {
                if row.utf16.count != size.w {
                    bad("\(at): rows are \(size.w) wide")
                    return nil
                }
                for scalar in row.unicodeScalars where scalar != "." {
                    // Every known letter is one UTF-16 unit, so a scalar that is
                    // not one can never be known.
                    if !known.contains(Character(scalar)) {
                        bad("\(at): the letter \(jsonQuoted(String(scalar))) is not in the palette")
                        return nil
                    }
                }
            }
            return strings
        }
        func frames(_ value: AgentCharacterJSON?, _ size: (w: Int, h: Int), _ at: String,
                    _ known: Set<Character>) -> [AgentCharacterFrame]? {
            guard let items = value?.arrayValue, !items.isEmpty, items.count <= 64 else {
                bad("\(at): 1 to 64 frames")
                return nil
            }
            // Every frame is checked, so each problem is reported, before any verdict.
            let out = items.enumerated().map { frame($0.element, size, "\(at)[\($0.offset)]", known) }
            return out.contains(where: { $0 == nil }) ? nil : out.compactMap { $0 }
        }
        let baseKnown = Set(palette.keys)

        if let marks = raw["marks"] {
            let keys = ["star", "starLit", "drop", "dropLit", "asked", "told"]
            let complete = marks.isObject && keys.allSatisfy { key in
                guard let letter = marks[key]?.stringValue else { return false }
                return isOneLetter(letter) && baseKnown.contains(Character(letter))
            }
            if !complete { bad("\"marks\" needs star, starLit, drop, dropLit, asked and told, each a palette letter") }
        }
        if let opus = raw["opusMark"] {
            if case .bool = opus {} else { bad("\"opusMark\" must be true or false") }
        }
        if let stuck = raw["stuck"] {
            let drop = stuck["drop"]?.arrayValue
            let row = drop.flatMap { $0.count == 2 ? $0[0].integerValue : nil }
            let col = drop.flatMap { $0.count == 2 ? $0[1].integerValue : nil }
            let mark = stuck["mark"]?.integerValue
            let valid = row != nil && col != nil && mark != nil
                && row! >= 0 && col! >= 0 && row! < helperSize.h / px && col! < helperSize.w / px
                && mark! >= 0 && mark! < helperSize.w / px
            if !valid { bad("\"stuck\" is {\"drop\": [row, col], \"mark\": col}") }
        }

        var characters: [AgentCharacter] = []
        var taken = Set<String>()
        if let helpers = raw["helpers"]?.arrayValue, (1...12).contains(helpers.count) {
            for (index, helper) in helpers.enumerated() {
                let at = "helpers[\(index)]"
                guard helper.isObject else { bad("\(at): not an object"); continue }
                let name = helper["name"]?.stringValue.map(jsTrim).flatMap { $0.isEmpty ? nil : utf16Prefix($0, 30) } ?? ""
                if name.isEmpty { bad("\(at): \"name\" is missing"); continue }
                var own: [Character: AgentCharacterColour] = [:]
                if let colours = helper["colors"] {
                    if case let .object(entries) = colours {
                        for (key, value) in entries {
                            if isOneLetter(key), key != ".",
                               let colour = value.stringValue.flatMap(AgentCharacterColour.init(hex:)) {
                                own[Character(key)] = colour
                            } else {
                                bad("\(at).colors \(jsonQuoted(key)): one character and a #rrggbb colour")
                            }
                        }
                    } else {
                        bad("\(at).colors: an object")
                    }
                }
                let known = baseKnown.union(own.keys)
                if let blink = helper["blink"] {
                    let pair = blink.arrayValue
                    let valid = pair?.count == 2 && pair!.allSatisfy { $0.stringValue.map(isOneLetter) ?? false }
                    if !valid { bad("\(at).blink: two single letters") }
                }
                var loops: [AgentCharacterLoop: AgentCharacter.Loop] = [:]
                for action in actions {
                    let loop = helper["loops"].flatMap { $0.isObject ? $0[action.rawValue] : nil }
                    guard let loop, loop.isObject, let ms = loop["frameMs"]?.numberValue, ms >= 50, ms <= 5000 else {
                        bad("\(at).loops.\(action.rawValue): {\"frameMs\": 50 to 5000, \"frames\": [...]}")
                        continue
                    }
                    if let list = frames(loop["frames"], helperSize, "\(at).loops.\(action.rawValue)", known) {
                        loops[action] = .init(frameMs: ms, frames: list)
                    }
                }
                let ends = helper["ends"].flatMap { $0.isObject ? $0 : nil }
                let done = frame(ends?["done"], helperSize, "\(at).ends.done", known)
                let failed = frame(ends?["failed"], helperSize, "\(at).ends.failed", known)
                var clips: [AgentCharacterClip: [AgentCharacterFrame]] = [:]
                for clip in frameSets {
                    if let list = frames(ends?[clip.rawValue], helperSize, "\(at).ends.\(clip.rawValue)", known) {
                        clips[clip] = list
                    }
                }
                if let idleMove = ends?["idleMove"],
                   let list = frames(idleMove, helperSize, "\(at).ends.idleMove", known) {
                    clips[.idleMove] = list
                }
                let list = helper["names"]?.arrayValue ?? [.string(name)]
                var mine: [String] = []
                for item in list.prefix(10) {
                    let trimmed = item.stringValue.map(jsTrim)
                    if trimmed == nil || !isAgentTypeName(trimmed!) {
                        bad("\(at).names: letters and digits, up to 20 characters")
                    } else if taken.contains(trimmed!.lowercased()) {
                        bad("\(at).names: \(trimmed!) is used twice")
                    } else {
                        taken.insert(trimmed!.lowercased())
                        mine.append(trimmed!)
                    }
                }
                if loops.count == actions.count, let done, let failed,
                   frameSets.allSatisfy({ clips[$0] != nil }) {
                    characters.append(AgentCharacter(
                        name: name, names: mine, colours: own, loops: loops,
                        done: done, failed: failed, clips: clips))
                }
            }
        } else {
            bad("\"helpers\": 1 to 12 entries")
        }

        var hasLead = false
        if let lead = raw["lead"] {
            let rest = frames(lead.isObject ? lead["rest"] : nil, leadSize, "lead.rest", baseKnown)
            let rising = frames(lead.isObject ? lead["rising"] : nil, leadSize, "lead.rising", baseKnown)
            var levelsValid = false
            if let levels = lead.isObject ? lead["levels"]?.arrayValue : nil, (1...4).contains(levels.count) {
                let sets = levels.enumerated().map { frames($0.element, leadSize, "lead.levels[\($0.offset)]", baseKnown) }
                levelsValid = !sets.contains(where: { $0 == nil })
            } else {
                bad("lead.levels: 1 to 4 sets of frames")
            }
            if let flare = lead.isObject ? lead["flare"] : nil {
                func cells(_ value: AgentCharacterJSON?) -> Bool {
                    guard let steps = value?.arrayValue, steps.count <= 8 else { return false }
                    return steps.allSatisfy { step in
                        guard let list = step.arrayValue, list.count <= 64 else { return false }
                        return list.allSatisfy { cell in
                            guard let c = cell.arrayValue, c.count == 3, c[0].integerValue != nil,
                                  c[1].integerValue != nil, let letter = c[2].stringValue else { return false }
                            return letter.count == 1 && baseKnown.contains(Character(letter))
                        }
                    }
                }
                let object = flare.isObject ? flare : .object([])
                if !(cells(object["small"]) && cells(object["big"])) {
                    bad("lead.flare: {\"small\": [[[row, col, letter], ...]], \"big\": ...}, each letter in the palette")
                }
            }
            hasLead = rest != nil && rising != nil && levelsValid
        }

        // Sounds are validated, never played: a sound on an agent event would be a
        // new notification path (non-negotiable #6).
        if let sounds = raw["sounds"] {
            for kind in soundKinds {
                guard let value = sounds.isObject ? sounds[kind] : nil else { continue }
                if let file = value.stringValue, isSoundFileName(file) { continue }
                bad("sounds.\(kind): a .wav or .mp3 file name beside the theme file, no folders")
            }
        }

        if !errors.isEmpty { return .failure(.init(messages: errors)) }
        let titleText = raw["title"]?.stringValue.map(jsTrim) ?? ""
        let title = titleText.isEmpty ? id : utf16Prefix(titleText, 60)
        return .success(AgentCharacterTheme(
            id: id, title: title, scale: px, frameWidth: helperSize.w, frameHeight: helperSize.h,
            palette: palette, characters: characters, hasLead: hasLead))
    }

    // MARK: - The format's small grammars, written out rather than as regular
    // expressions: ICU's `$` also matches before a final newline, JavaScript's does not.

    /// `^[a-z0-9][a-z0-9-]{0,30}$`
    public static func isThemeID(_ id: String) -> Bool {
        let scalars = Array(id.unicodeScalars)
        guard (1...31).contains(scalars.count) else { return false }
        func lowerOrDigit(_ s: Unicode.Scalar) -> Bool { ("a"..."z").contains(s) || ("0"..."9").contains(s) }
        return lowerOrDigit(scalars[0]) && scalars.dropFirst().allSatisfy { lowerOrDigit($0) || $0 == "-" }
    }

    /// `^[A-Za-z][A-Za-z0-9]{0,19}$`
    static func isAgentTypeName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard (1...20).contains(scalars.count) else { return false }
        func letter(_ s: Unicode.Scalar) -> Bool { ("a"..."z").contains(s) || ("A"..."Z").contains(s) }
        return letter(scalars[0]) && scalars.dropFirst().allSatisfy { letter($0) || ("0"..."9").contains($0) }
    }

    /// `^[A-Za-z0-9][A-Za-z0-9 _.-]{0,80}\.(wav|mp3)$`, and never `..`.
    static func isSoundFileName(_ file: String) -> Bool {
        guard !file.contains(".."), file.hasSuffix(".wav") || file.hasSuffix(".mp3") else { return false }
        let stem = Array(file.unicodeScalars.dropLast(4))
        guard (1...81).contains(stem.count) else { return false }
        func alnum(_ s: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s)
        }
        return alnum(stem[0]) && stem.dropFirst().allSatisfy { alnum($0) || " _.-".unicodeScalars.contains($0) }
    }

    /// One character that is one UTF-16 unit.
    static func isOneLetter(_ text: String) -> Bool { text.utf16.count == 1 }

    /// `JSON.stringify` of a short string, as the reference messages quote keys.
    static func jsonQuoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }

    /// `String.prototype.trim`.
    static func jsTrim(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
    }

    /// `slice(0, n)` in UTF-16 units, never splitting a surrogate pair.
    static func utf16Prefix(_ text: String, _ count: Int) -> String {
        guard text.utf16.count > count else { return text }
        var out = ""
        for character in text {
            if out.utf16.count + character.utf16.count > count { break }
            out.append(character)
        }
        return out
    }
}
