import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// Plan: .plans/110-agent-characters/README.md, slice 1.
//
// The theme format, the built-in set and the atlas. The parity corpus in
// Fixtures/agent-character-themes was recorded by `make-corpus.ts` against the
// reference parser: each file's verdict and its exact problem messages, in order.
// The Swift parser must agree on every one.
func runAgentCharacterThemeChecks() {
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL agent character theme: \(message)\n", stderr)
            exit(1)
        }
    }

    // 1. The built-in set, from the resource the app ships.
    guard let url = AgentCharacterBundled.themeURL, let data = try? Data(contentsOf: url) else {
        expect(false, "the bundled ducks.theme.json is missing beside the binary")
        return
    }
    guard case let .success(ducks) = AgentCharacterThemeParser.parse(data: data) else {
        expect(false, "the bundled theme does not parse: \(AgentCharacterThemeParser.parse(data: data))")
        return
    }
    expect(ducks.id == "ducks-classic" && ducks.title == "Ducks", "bundled id/title \(ducks.id) \(ducks.title)")
    expect(ducks.characters.count == 8, "8 built-in characters, got \(ducks.characters.count)")
    expect(ducks.hasLead, "the built-in set carries lead art")
    expect(ducks.frameWidth == 20 && ducks.frameHeight == 12, "20 x 12 frames")
    for character in ducks.characters {
        let frames = AgentCharacterLoop.allCases.reduce(0) { $0 + character.frames(of: $1).count }
            + 2 + AgentCharacterClip.allCases.reduce(0) { $0 + (character.clips[$1]?.count ?? 0) }
        expect(frames == 105, "\(character.name) has 105 frames, got \(frames)")
    }
    expect(!ducks.title.lowercased().contains("duckherd") && !ducks.characters.contains { $0.name.lowercased().contains("duckherd") },
           "no third-party product name in what the UI shows")
    let license = AgentCharacterBundled.licenseURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    expect(license.contains("Copyright (c) 2026 Ali Alsalkhadi") && license.contains("Permission is hereby granted"),
           "the MIT notice ships beside the built-in characters")

    // 2. Parity with the reference parser over the recorded corpus.
    let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/agent-character-themes", isDirectory: true)
    struct Manifest: Decodable {
        struct Case: Decodable {
            let file: String
            let accepted: Bool
            let errors: [String]?
            let id: String?
            let title: String?
            let helpers: [String]?
            let hasLead: Bool?
            let scale: Int?
        }
        let cases: [Case]
    }
    guard let manifestData = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
          let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData) else {
        expect(false, "corpus manifest unreadable at \(folder.path)")
        return
    }
    expect(manifest.cases.count >= 50, "the corpus has its cases (\(manifest.cases.count))")
    var accepted = 0, rejected = 0
    for item in manifest.cases {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(item.file), encoding: .utf8) else {
            expect(false, "corpus file \(item.file) unreadable")
            return
        }
        switch AgentCharacterThemeParser.parse(text: text) {
        case let .success(theme):
            expect(item.accepted, "\(item.file): the reference REJECTED it (\(item.errors ?? [])), Swift accepted")
            expect(theme.id == item.id && theme.title == item.title, "\(item.file): id/title \(theme.id)/\(theme.title) vs \(item.id ?? "")/\(item.title ?? "")")
            expect(theme.characters.map(\.name) == item.helpers ?? [], "\(item.file): helper names \(theme.characters.map(\.name))")
            expect(theme.hasLead == item.hasLead && theme.scale == item.scale, "\(item.file): lead/scale")
            accepted += 1
        case let .failure(problems):
            expect(!item.accepted, "\(item.file): the reference ACCEPTED it, Swift rejected: \(problems.messages)")
            expect(problems.messages == item.errors ?? [],
                   "\(item.file): messages differ\n  swift: \(problems.messages)\n  reference: \(item.errors ?? [])")
            rejected += 1
        }
    }
    // The text cap is checked before parsing, so it needs no 3 MB fixture.
    if case let .failure(problems) = AgentCharacterThemeParser.parse(text: String(repeating: "x", count: 3_000_001)) {
        expect(problems.messages == ["the file is over 3 MB"], "the 3 MB cap message")
    } else {
        expect(false, "a 3 MB file is refused")
    }

    // 3. The atlas: art pixels are the palette's colours, `.` is clear, and the
    // light outline only ever fills a clear pixel touching the figure.
    var atlasChecks = 0
    let corpusTheme: AgentCharacterTheme? = {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("good-own-colours.theme.json"), encoding: .utf8),
              case let .success(theme) = AgentCharacterThemeParser.parse(text: text) else { return nil }
        return theme
    }()
    for theme in [ducks, corpusTheme].compactMap({ $0 }) {
        for (index, character) in theme.characters.enumerated() {
            let dark = AgentCharacterAtlas(theme: theme, character: index, appearance: .dark)
            let light = AgentCharacterAtlas(theme: theme, character: index, appearance: .light)
            expect(dark.width == light.width && dark.frames == light.frames, "light and dark share one layout")
            expect(dark.width <= 4096, "atlas width bounded")
            let samples: [(AgentCharacterFrame, Int)] = [
                (character.frame(of: .loop(.type)), dark.frameIndex(of: .loop(.type))),
                (character.frame(of: .done), dark.frameIndex(of: .done)),
                (character.frame(of: .failed), dark.frameIndex(of: .failed)),
                (character.frames(of: .think).last!, dark.frameIndices(of: .think).last!),
            ]
            for (frame, at) in samples {
                let rect = dark.frames[at]
                for (y, row) in frame.enumerated() {
                    for (x, scalar) in row.unicodeScalars.enumerated() {
                        let d = dark.pixel(x: rect.x + x, y: rect.y + y)
                        let l = light.pixel(x: rect.x + x, y: rect.y + y)
                        if scalar == "." {
                            expect(d.a == 0, "\(character.name): a clear pixel is transparent in the dark atlas")
                            if l.a != 0 {
                                // An outline pixel: one of its four neighbours is figure.
                                let touches = [(-1, 0), (1, 0), (0, -1), (0, 1)].contains { dx, dy in
                                    let nx = x + dx, ny = y + dy
                                    guard ny >= 0, ny < frame.count, nx >= 0, nx < theme.frameWidth else { return false }
                                    return Array(frame[ny].unicodeScalars)[nx] != "."
                                }
                                expect(touches && l.a == AgentCharacterAtlas.outlineAlpha,
                                       "\(character.name): the light outline only touches the figure (\(x),\(y))")
                            }
                        } else {
                            guard let colour = theme.colour(of: Character(scalar), in: character) else {
                                expect(false, "letter without a colour"); return
                            }
                            expect(d == (colour.red, colour.green, colour.blue, 255),
                                   "\(character.name): pixel (\(x),\(y)) is its palette colour")
                            expect(l == d, "\(character.name): the light atlas leaves every art pixel unchanged")
                        }
                        atlasChecks += 1
                    }
                }
            }
        }
    }
    // The pale Pekin is why the outline exists: the light atlas must add some.
    if let pekin = ducks.characters.firstIndex(where: { $0.name.lowercased().contains("pekin") }) {
        let dark = AgentCharacterAtlas(theme: ducks, character: pekin, appearance: .dark)
        let light = AgentCharacterAtlas(theme: ducks, character: pekin, appearance: .light)
        var added = 0
        for alpha in stride(from: 3, to: dark.pixels.count, by: 4) where dark.pixels[alpha] == 0 && light.pixels[alpha] > 0 {
            added += 1
        }
        expect(added > 0, "the light atlas outlines the Pekin")
    } else {
        expect(false, "the built-in set has a Pekin")
    }
    print("Agent character theme checks passed: built-in set (8 x 105 frames), \(accepted) accepted + \(rejected) rejected corpus files match the reference, \(atlasChecks) atlas pixels")
}
