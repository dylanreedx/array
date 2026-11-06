import Compression
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

    // 1b. The built-in symbol packs, through the lookup the app draws and speaks
    // from: each loads by id, has its characters and lead art, and every sound
    // its theme names resolves to a playable file inside its own folder.
    let packs: [(id: String, title: String, characters: Int)] = [
        ("street-sigils", "Street Sigils", 12), ("living-chords", "Living Chords", 12),
        ("ascii-morph", "ASCII morph", 14), ("signal-ghosts", "Signal Ghosts", 12),
    ]
    expect(AgentCharacterBundled.builtInIDs == ["ducks-classic"] + packs.map(\.id),
           "the built-in ids, ducks first: \(AgentCharacterBundled.builtInIDs)")
    let builtIns = AgentCharacterBundled.themes()
    expect(builtIns.map(\.id) == AgentCharacterBundled.builtInIDs,
           "every built-in set loads: \(builtIns.map(\.id))")
    expect(Set(builtIns.map { $0.title.lowercased() }).count == builtIns.count, "built-in titles are distinct")
    for pack in packs {
        guard let theme = AgentCharacterBundled.theme(id: pack.id) else {
            expect(false, "\(pack.id): the built-in pack does not load from the app's resources")
            return
        }
        expect(theme.title == pack.title, "\(pack.id): title \(theme.title)")
        expect(theme.characters.count == pack.characters, "\(pack.id): \(pack.characters) characters, got \(theme.characters.count)")
        expect(Set(theme.characters.map { $0.name.lowercased() }).count == theme.characters.count,
               "\(pack.id): character names are distinct within the set")
        expect(theme.hasLead && (theme.leadSet?.characters.isEmpty == false), "\(pack.id): carries lead art")
        guard let folder = AgentCharacterBundled.packFolderURL(id: pack.id),
              let data = try? Data(contentsOf: folder.appendingPathComponent(AgentCharacterImports.fileName)) else {
            expect(false, "\(pack.id): no pack folder with a theme.json")
            return
        }
        let voices = AgentCharacterVoices.parse(themeData: data)
        expect(!voices.spawn.isEmpty && !voices.doneByName.isEmpty, "\(pack.id): names spawn and per-character done voices")
        expect(AgentCharacterBaseSound.allCases.allSatisfy { voices.sounds[$0] != nil },
               "\(pack.id): replaces every base sound: \(voices.sounds.keys.map(\.rawValue).sorted())")
        for relative in voices.referencedFiles {
            let file = AgentCharacterAudioImport.containedFile(relative, in: folder)
            expect(file.map { FileManager.default.fileExists(atPath: $0.path) && AgentCharacterAudioImport.isPlayableCopy($0) } == true
                   && file.flatMap(AgentCharacterAudioImport.decodedDuration) != nil,
                   "\(pack.id): sound \(relative) is missing or does not decode in the app's resources")
        }
        // What the sound center plays: a pack clip, never the ducks' fallback.
        for character in theme.characters {
            let done = AgentCharacterSoundResolver.resolve(moment: .helperFinished, characterName: character.name,
                                                           voices: voices, themeFolder: folder, pick: { _ in 0 })
            guard case let .theme(url)? = done, let named = voices.doneByName.first(where: {
                $0.key.caseInsensitiveCompare(character.name) == .orderedSame })?.value.first else {
                expect(false, "\(pack.id): \(character.name) finishing has no clip of its own: \(String(describing: done))")
                return
            }
            expect(url.lastPathComponent == (named as NSString).lastPathComponent,
                   "\(pack.id): \(character.name) finishing plays \(url.lastPathComponent), not its own \(named)")
        }
        for moment in AgentCharacterSoundMoment.allCases where moment.baseSound != nil {
            let source = AgentCharacterSoundResolver.resolve(moment: moment, characterName: nil, voices: voices,
                                                             themeFolder: folder, pick: { _ in 0 })
            if case .theme? = source {} else {
                expect(false, "\(pack.id): \(moment.rawValue) falls back to \(String(describing: source))")
            }
        }
    }
    // Core, which iOS links, holds no pack.
    if let core = AgentCharacterBundled.folderURL() {
        expect(!FileManager.default.fileExists(atPath: core.appendingPathComponent("packs").path),
               "Core's resources hold no pack: the iOS app bundles them")
    }

    // A user set may not take a built-in id: import refuses it, and one written
    // straight into the themes folder is a problem there, never the built-in.
    let collision = FileManager.default.temporaryDirectory
        .appendingPathComponent("agent-character-builtin-collision-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: collision) }
    let userFolder = collision.appendingPathComponent("characters", isDirectory: true)
    try? FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
    let stolenText = String(decoding: data, as: UTF8.self)
        .replacingOccurrences(of: "\"id\":\"ducks-classic\"", with: "\"id\":\"ascii-morph\"")
        .replacingOccurrences(of: "\"title\":\"Ducks\"", with: "\"title\":\"Not ASCII\"")
    let stolen = collision.appendingPathComponent("stolen.theme.json")
    try? Data(stolenText.utf8).write(to: stolen)
    if case let .success(parsed) = AgentCharacterThemeParser.parse(data: Data(stolenText.utf8)) {
        expect(parsed.id == "ascii-morph", "control: the colliding file really takes the built-in id")
    } else {
        expect(false, "control: the colliding file parses")
    }
    if case .imported = AgentCharacterImports.importTheme(from: stolen, into: userFolder) {
        expect(false, "importing a set with a built-in pack's id is refused")
    }
    try? Data(stolenText.utf8).write(to: userFolder.appendingPathComponent("stolen.theme.json"))
    let scanned = AgentCharacterImports.scan(userFolder)
    expect(AgentCharacterImports.themes(in: scanned).isEmpty, "a folder set with a built-in id is not a user set")
    expect(scanned.contains { if case let .failure(problems) = $0.result {
        return problems.messages.contains { $0.contains("ascii-morph") && $0.contains("built-in") } }
        return false }, "the folder lists the built-in id as the file's problem")
    expect(AgentCharacterBundled.theme(id: "ascii-morph")?.title == "ASCII morph", "the built-in pack is untouched")

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
    // Where Array deliberately accepts more than the published parser (plan 110 ›
    // "Duckherd themes as they ship"): up to 16 helpers, as shared sets have,
    // so the reference's "1 to 12 entries" reads "1 to 16 entries" here.
    let widened: [String: Int] = ["bad-13-helpers.theme.json": 13]
    for item in manifest.cases {
        if let helpers = widened[item.file] {
            let text = (try? String(contentsOf: folder.appendingPathComponent(item.file), encoding: .utf8)) ?? ""
            guard case let .success(theme) = AgentCharacterThemeParser.parse(text: text) else {
                expect(false, "\(item.file): Array accepts up to 16 helpers: \(AgentCharacterThemeParser.parse(text: text))")
                return
            }
            expect(theme.characters.count == helpers, "\(item.file): \(helpers) helpers, got \(theme.characters.count)")
            accepted += 1
            continue
        }
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
            let reference = (item.errors ?? []).map { $0 == "\"helpers\": 1 to 12 entries" ? "\"helpers\": 1 to 16 entries" : $0 }
            expect(problems.messages == reference,
                   "\(item.file): messages differ\n  swift: \(problems.messages)\n  reference: \(reference)")
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
    let duckherd = runDuckherdShapedThemeChecks(expect)
    print("Agent character theme checks passed: built-in set (8 x 105 frames), \(packs.count) built-in packs with every sound resolving, built-in ids reserved, \(accepted) accepted + \(rejected) rejected corpus files match the reference (1 widened to 16 helpers), \(atlasChecks) atlas pixels; \(duckherd)")
}

/// Plan 110 › "Duckherd themes as they ship": a set shaped like the ones Duckherd
/// users share (the Bleach set) imports, its trimmed lead frames are padded into
/// one lead box, and the limits a bad file hits name the real numbers.
func runDuckherdShapedThemeChecks(_ expect: (@autoclosure () -> Bool, String) -> Void) -> String {
    typealias Fixture = AgentCharacterDuckherdFixture
    func problems(_ text: String) -> [String] {
        if case let .failure(found) = AgentCharacterThemeParser.parse(text: text) { return found.messages }
        return []
    }
    let text = Fixture.text()
    guard case let .success(theme) = AgentCharacterThemeParser.parse(text: text) else {
        expect(false, "the Duckherd-shaped set is refused: \(problems(text))")
        return ""
    }
    expect(theme.id == Fixture.id && theme.scale == 4, "id and scale 4")
    expect(theme.characters.count == Fixture.helperCount, "16 helpers, got \(theme.characters.count)")
    expect(theme.frameWidth == 80 && theme.frameHeight == 48, "helpers stay 80 x 48 at scale 4")
    expect(theme.palette.count == 151, "the 151-letter palette, got \(theme.palette.count)")
    expect(theme.characters.allSatisfy { $0.clips[.idleMove] != nil }, "every helper keeps idleMove")
    guard let lead = theme.lead else {
        expect(false, "the lead art is kept")
        return ""
    }
    // The tallest frame is 111 rows: the box is the next whole cell (16 rows at
    // scale 4), 112; the widest row is 112, already whole cells.
    expect(lead.width == 112 && lead.height == 112, "the lead box grows to the largest frame: \(lead.width) x \(lead.height)")
    let all = lead.rest + lead.rising + lead.levels.joined() + (lead.shift ?? [])
    expect(all.allSatisfy { $0.count == lead.height && $0.allSatisfy { $0.utf16.count == lead.width } },
           "every lead frame is padded to the box")
    expect(lead.rest.count == Fixture.restFrames && lead.rising.count == Fixture.risingFrames
           && lead.shift?.count == Fixture.shiftFrames, "rest 4, rising 29, shift 2")
    expect(lead.levels.map(\.count) == [9, 9, 16] && lead.levels[1] == lead.levels[0],
           "levels: 9 frames, level 0 again by index, 16 frames (\(lead.levels.map(\.count)))")
    // Padding is clear and anchored top-left: the stored rows come back unchanged at their start.
    let raw = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    let rawRest = ((raw?["lead"] as? [String: Any])?["rest"] as? [[String]])?.first ?? []
    expect(!rawRest.isEmpty && rawRest[0].isEmpty && rawRest.count == 81, "the fixture's rest frame is trimmed as shared sets are")
    expect(zip(rawRest, lead.rest[0]).allSatisfy { stored, padded in padded.hasPrefix(stored)
        && padded.dropFirst(stored.count).allSatisfy { $0 == "." } }
        && lead.rest[0].dropFirst(rawRest.count).allSatisfy { $0.allSatisfy { $0 == "." } },
           "trimmed rows and rows past the end are clear, top-left anchored")
    guard let leadSet = theme.leadSet else {
        expect(false, "the lead set is built")
        return ""
    }
    expect(leadSet.characters.count == 3 && leadSet.frameWidth == 112 && leadSet.frameHeight == 112, "3 lead levels at the lead box")
    var atlases = 0
    for (set, index) in [(leadSet, 0), (leadSet, 2), (theme, 0), (theme, 15)] {
        for appearance in AgentCharacterAtlas.Appearance.allCases {
            let atlas = AgentCharacterAtlas(theme: set, character: index, appearance: appearance)
            expect(atlas.frameWidth == set.frameWidth && atlas.frameHeight == set.frameHeight && atlas.width <= 4096,
                   "atlas \(index) keeps its frame size")
            // An art pixel of the first rest/done frame is its palette colour.
            let character = set.characters[index]
            let frame = character.frame(of: .done)
            let rect = atlas.frames[atlas.frameIndex(of: .done)]
            guard let (y, row) = frame.enumerated().first(where: { $0.element.contains { $0 != "." } }),
                  let x = Array(row.unicodeScalars).firstIndex(where: { $0 != "." }),
                  let colour = set.colour(of: Character(Array(row.unicodeScalars)[x]), in: character) else {
                expect(false, "frame has art"); return ""
            }
            let pixel = atlas.pixel(x: rect.x + x, y: rect.y + y)
            expect(pixel == (colour.red, colour.green, colour.blue, 255), "atlas \(index) draws its palette colour")
            atlases += 1
        }
    }
    // The validator a guest uses accepts it too.
    expect((try? AgentCharacterValidator.validate(data: Data(text.utf8)).get()) == theme, "the shared-set validator accepts it")
    // A shared agent's guest: a set like this deflates past the 32 KiB one op may
    // carry, so it travels in parts after a checkpoint (`--shared-agent-chrome-check`
    // drives that through the publisher and the guest tile). The parts are bounded
    // and in order; anything else drops the set in flight, never the frame.
    typealias WireTheme = SharedAgentTranscriptWire.CharacterTheme
    guard let wire = WireTheme(file: Data(text.utf8)) else {
        expect(false, "a Duckherd-sized set can be shared (\(WireTheme.maximumSharedDeflatedBytes) bytes deflated at most)")
        return ""
    }
    let parts = wire.parts()
    expect(!wire.isInline && parts.count > 1 && parts.count <= WireTheme.maximumSharedDeflatedBytes / WireTheme.partBytes,
           "the set is not inline and travels in \(parts.count) parts")
    let partFrames = parts.map { (try? SharedAgentTranscriptWire.encode(SharedAgentTranscriptWire.Patch(ops: [.characterThemePart($0)])).count) ?? .max }
    expect(partFrames.allSatisfy { $0 <= 48 * 1024 }, "every part frame fits a 48 KiB lane frame (largest \(partFrames.max() ?? 0))")
    var assembly = WireTheme.Assembly()
    var assembled: WireTheme?
    for part in parts { assembled = assembly.receive(part) ?? assembled }
    expect(assembled == wire && assembled?.file() == Data(text.utf8), "the parts reassemble the file, hash checked")
    var skipping = WireTheme.Assembly()
    let noStart = parts.dropFirst().compactMap { skipping.receive($0) }.isEmpty
    var gap = WireTheme.Assembly()
    let gapped = parts.count > 2 && gap.receive(parts[0]) == nil && gap.receive(parts[2]) == nil
        && parts.dropFirst().compactMap { gap.receive($0) }.isEmpty
    expect(noStart && gapped, "parts without their start, or with a gap, assemble nothing")
    var oversized = WireTheme.Assembly()
    let huge = WireTheme.Part(hash: wire.hash, total: WireTheme.maximumSharedDeflatedBytes + 1, offset: 0, bytes: Data([1]))
    let fat = WireTheme.Part(hash: wire.hash, total: 64 * 1024, offset: 0, bytes: Data(count: WireTheme.partBytes + 1))
    expect(oversized.receive(huge) == nil && oversized.receive(fat) == nil, "a part past the limits is refused before it is kept")
    var tampered = WireTheme.Assembly()
    var forged: WireTheme?
    for part in parts {
        let bytes = part.offset == 0 ? Data(part.bytes.reversed()) : part.bytes
        forged = tampered.receive(.init(hash: part.hash, total: part.total, offset: part.offset, bytes: bytes)) ?? forged
    }
    expect(forged != nil && forged?.file() == nil, "a set whose bytes do not match its hash never reaches the validator")
    // An op this build does not know decodes as skipped: how a 0.7.40 guest reads a part.
    let renamed = String(decoding: (try? SharedAgentTranscriptWire.encode(SharedAgentTranscriptWire.Patch(ops: [.characterThemePart(parts[0])]))) ?? Data(),
                         as: UTF8.self).replacingOccurrences(of: "characterThemePart", with: "characterThemePartFromTheFuture")
    let skipped = try? JSONDecoder().decode(SharedAgentTranscriptWire.Patch.self, from: Data(renamed.utf8))
    expect(skipped?.ops == [.unknown("characterThemePartFromTheFuture")], "an unknown op is skipped, not a failed frame")

    // Bad metadata clears the in-flight set, and a subsequent good start recovers.
    let malformed: [WireTheme.Part] = [
        .init(hash: wire.hash, total: wire.deflated.count, offset: 0, bytes: Data([1])),
        .init(hash: "bad", total: wire.deflated.count, offset: 0, bytes: Data([1])),
        .init(hash: wire.hash, total: 0, offset: 0, bytes: Data([1])),
        .init(hash: wire.hash, total: wire.deflated.count, offset: -1, bytes: Data([1])),
        .init(hash: wire.hash, total: wire.deflated.count, offset: Int.max, bytes: Data([1])),
        .init(hash: wire.hash, total: wire.deflated.count, offset: 0, bytes: Data()),
        .init(hash: String(repeating: "b", count: 64), total: wire.deflated.count, offset: parts[1].offset, bytes: parts[1].bytes),
        .init(hash: wire.hash, total: wire.deflated.count + 1, offset: parts[1].offset, bytes: parts[1].bytes),
    ]
    for bad in malformed {
        var receiver = WireTheme.Assembly()
        _ = receiver.receive(parts[0]); _ = receiver.receive(bad)
        expect(parts.dropFirst().compactMap { receiver.receive($0) }.isEmpty, "bad part metadata clears the pending set")
        expect(parts.compactMap { receiver.receive($0) }.last == wire, "a fresh start recovers after bad metadata")
    }
    var replaced = WireTheme.Assembly()
    _ = replaced.receive(parts[0])
    let otherHash = String(repeating: "b", count: 64)
    let replacement = parts.map { WireTheme.Part(hash: otherHash, total: $0.total, offset: $0.offset, bytes: $0.bytes) }
    expect(replacement.compactMap { replaced.receive($0) }.last?.hash == otherHash,
           "a new start replaces the single in-flight set")
    do {
        var mirror = SharedAgentTranscriptWire.Mirror()
        _ = try mirror.install(.init(entries: [], omittedEntries: 0))
        _ = try mirror.apply(.init(ops: [.characterThemePart(parts[0])]))
        let malformedFrame = Data("{\"schema\":1,\"ops\":[{\"op\":\"characterThemePart\",\"part\":{\"offset\":\"bad\"}}]}".utf8)
        let decoded = try JSONDecoder().decode(SharedAgentTranscriptWire.Patch.self, from: malformedFrame)
        _ = try mirror.apply(decoded)
        for part in parts.dropFirst() { _ = try mirror.apply(.init(ops: [.characterThemePart(part)])) }
        expect(mirror.characterThemes.isEmpty && mirror.document.entries.isEmpty,
               "malformed part schema preserves the transcript and clears the pending assembly")
        for part in parts { _ = try mirror.apply(.init(ops: [.characterThemePart(part)])) }
        expect(mirror.characterThemes[wire.hash] == wire, "production mirror recovers on a fresh ordered set")
    } catch { expect(false, "part presentation never fails the transcript frame: \(error)") }
    // Prove the upper frame budget at its exact boundary, without private art.
    let cap = WireTheme(hash: wire.hash, deflated: Data(count: WireTheme.maximumSharedDeflatedBytes))
    expect(cap.parts().count == 16 && cap.parts().allSatisfy {
        ((try? SharedAgentTranscriptWire.encode(SharedAgentTranscriptWire.Patch(ops: [.characterThemePart($0)])).count) ?? .max) <= 48 * 1024
    }, "the exact compressed limit fits in sixteen bounded frames")
    let overFile = Data(repeating: 65, count: AgentCharacterThemeParser.maximumFileBytes + 1)
    var compressed = Data(count: overFile.count + 1024)
    let compressedCount = compressed.withUnsafeMutableBytes { dst in
        overFile.withUnsafeBytes { src in
            compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                                      src.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
        }
    }
    expect(compressedCount > 0, "inflate-limit control compressed successfully")
    let bomb = WireTheme(hash: WireTheme.hash(overFile), deflated: compressed.prefix(compressedCount))
    expect(bomb.deflated.count < WireTheme.maximumDeflatedBytes && bomb.file() == nil,
           "bounded inflate rejects a small compressed file that expands past the file limit")
    expect(WireTheme(file: overFile) == nil, "publisher rejects files above the inflated-file limit")

    // The limits, named.
    // 17 helpers at this size would pass the 3 MB text cap first; the count is
    // judged before any helper's content, so 17 empty helpers show it alone.
    var seventeen = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    seventeen["helpers"] = Array(repeating: [String: Any](), count: 17)
    let seventeenText = String(decoding: (try? JSONSerialization.data(withJSONObject: seventeen)) ?? Data(), as: UTF8.self)
    expect(problems(seventeenText) == ["\"helpers\": 1 to 16 entries"], "17 helpers: \(problems(seventeenText))")
    let tall = Array(repeating: "A", count: 129)
    expect(problems(Fixture.text(extraLead: ["rest": [tall]])) == ["lead.rest[0]: a lead frame is 1 to 128 rows of text"],
           "a 129-row lead frame: \(problems(Fixture.text(extraLead: ["rest": [tall]])))")
    let wide = [String(repeating: "A", count: 321)]
    expect(problems(Fixture.text(extraLead: ["rest": [wide]])) == ["lead.rest[0]: lead rows are at most 320 wide"],
           "a 321-wide lead row: \(problems(Fixture.text(extraLead: ["rest": [wide]])))")
    let boxed = problems(Fixture.text(leadSize: [112, 64]))
    expect(boxed.first == "lead.rest[0]: a lead frame is 1 to 64 rows of text", "a set leadSize bounds the frames: \(boxed)")
    expect(problems(Fixture.text(leadLevels: [[["A"]], 1])) == ["lead.levels[1]: a set of frames, or the index of another level's frames"],
           "a level naming itself: \(problems(Fixture.text(leadLevels: [[["A"]], 1])))")
    expect(problems(Fixture.text(extraLead: ["shift": []])) == ["lead.shift: 1 to 64 frames"], "an empty shift")
    return "Duckherd-shaped set: 16 helpers, 151 colours, lead box 112 x 112 from trimmed frames, levels by index, shift kept, \(atlases) atlases, 6 limits named, shared to guests in \(parts.count) bounded parts"
}
