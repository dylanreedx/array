import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import SwiftUI

// `--character-sounds-check` (notification paths MAC-10…MAC-13).
//
// 1. Import: a set whose `voices` and `sounds` name audio beside it imports through
//    Settings' own import; the good files are copied into Array's copy of the set,
//    and a non-audio, an oversized, a too-long, a missing and an escaping path are
//    each left out with their reason.
// 2. Playback, through production: events go through the supervisor's delivery
//    into `recordManagedActivity`, which feeds the alert sounds and the character
//    sounds. Both play into one recording sink, never the speakers. With the toggle
//    on, each moment plays exactly one sound from the right source (the set's clip,
//    else the bundled Duckherd sound); off, characters hidden, or the master switch
//    off, nothing plays; an enabled alert sound for the same moment plays alone.
// 3. The Settings row, light and dark, rendered offscreen.
@MainActor
enum CharacterSoundsChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    /// Every sound production asks for, in order. Nothing reaches the speakers.
    final class Sink: AgentSoundPlaying, AgentCharacterSoundPlaying {
        var plays: [String] = []
        func play(_ reference: AgentSoundReference, priority: Int, volume: Double, library: AgentSoundLibrary) {
            plays.append("alert:\(reference.rawValue)")
        }
        func playCharacterSound(_ url: URL, priority: Int, volume: Double) {
            plays.append("character:\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)")
        }
    }

    /// A 16-bit mono PCM WAV of `seconds` (a quiet tone; it is never played).
    static func wav(seconds: Double, rate: Int = 8000) -> Data {
        let samples = Int(Double(rate) * seconds)
        var data = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; data.append(Data(bytes: &x, count: 2)) }
        data.append(Data("RIFF".utf8)); u32(36 + samples * 2); data.append(Data("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        data.append(Data("data".utf8)); u32(samples * 2)
        for n in 0..<samples { u16(Int(UInt16(bitPattern: Int16(sin(Double(n) / 8) * 800)))) }
        return data
    }

    static func run() throws -> String {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("array-character-sounds-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let imports = root.appendingPathComponent("support/characters", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let voice = incoming.appendingPathComponent("voice", isDirectory: true)
        let agentsSupport = root.appendingPathComponent("agents", isDirectory: true)
        for folder in [imports, voice, agentsSupport] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }

        // The bundled Duckherd sounds ship in Core's resource bundle and decode.
        for base in AgentCharacterBaseSound.allCases {
            guard let url = AgentCharacterBundled.soundURL(base), AgentCharacterAudioImport.decodedDuration(url) != nil else {
                throw Failure(description: "the bundled \(base.rawValue) sound is missing or does not decode")
            }
        }

        // MARK: 1 · import keeps a set's sounds, within caps

        guard var json = try JSONSerialization.jsonObject(with: Data(AgentCharacterDuckherdFixture.text().utf8)) as? [String: Any],
              let helpers = json["helpers"] as? [[String: Any]] else {
            throw Failure(description: "the Duckherd-shaped fixture did not parse")
        }
        let names = helpers.compactMap { $0["name"] as? String }
        try expect(names.count >= 3, "the fixture has helpers to name")
        json["id"] = "voiced"
        json["title"] = "Voiced set"
        json["voices"] = [
            "spawn": ["voice/lead-1.wav", "voice/lead-2.wav"],
            "done": [names[0]: ["voice/first.wav"], names[1]: ["voice/not-audio.wav"]],
            "any": ["voice/any.wav", "voice/huge.wav", "voice/long.wav", "voice/missing.wav", "../escape.wav"],
        ]
        json["sounds"] = ["chirp": "own-chirp.wav"]
        let themeFile = incoming.appendingPathComponent("voiced.theme.json")
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: themeFile)
        for name in ["lead-1", "lead-2", "first", "any"] { try wav(seconds: 0.3).write(to: voice.appendingPathComponent("\(name).wav")) }
        try wav(seconds: 0.3).write(to: incoming.appendingPathComponent("own-chirp.wav"))
        try wav(seconds: 11).write(to: voice.appendingPathComponent("long.wav"))
        try Data("not audio at all".utf8).write(to: voice.appendingPathComponent("not-audio.wav"))
        fm.createFile(atPath: voice.appendingPathComponent("huge.wav").path, contents: nil)
        let huge = try FileHandle(forWritingTo: voice.appendingPathComponent("huge.wav"))
        try huge.truncate(atOffset: UInt64(AgentCharacterAudioImport.maximumFileBytes + 1))
        try huge.close()
        try wav(seconds: 0.3).write(to: root.appendingPathComponent("escape.wav"))

        let suite = "ArrayCharacterSoundsChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = AgentCharacterController.shared
        controller.reduceMotion = { true }
        controller.windowIsVisible = { _ in true }
        controller.importsDirectory = imports
        defaults.set(true, forKey: AgentCharacterConfig.enabledKey)
        controller.adopt(defaults: defaults)
        AgentCharacterSettingsModel.homeOverrideForChecks = root
        defer { AgentCharacterSettingsModel.homeOverrideForChecks = nil }
        let settingsModel = AgentCharacterSettingsModel(defaults: defaults, importsDirectory: imports, home: root)
        settingsModel.importTheme(from: themeFile)
        try expect(settingsModel.problems.isEmpty, "the voiced set imports: \(settingsModel.problems)")
        try expect(controller.theme?.id == "voiced", "importing selects the voiced set")
        let store = imports.appendingPathComponent("voiced", isDirectory: true)
        let kept = ["voice/lead-1.wav", "voice/lead-2.wav", "voice/first.wav", "voice/any.wav", "own-chirp.wav"]
        for file in kept {
            try expect(fm.contentsEqual(atPath: store.appendingPathComponent(file).path,
                                        andPath: incoming.appendingPathComponent(file).path),
                       "\(file) is copied into Array's copy of the set")
        }
        let expectedDrops = [
            "voices.any[4] ../escape.wav: not a .wav or .mp3 path inside the set's folder",
            "voice/not-audio.wav: it is not a WAV or MP3 Array can play",
            "voice/huge.wav: the file is over 2 MB",
            "voice/long.wav: it is longer than 10 seconds",
            "voice/missing.wav: there is no such file beside the theme",
        ]
        try expect(settingsModel.droppedSounds == expectedDrops,
                   "each left-out sound says why: \(settingsModel.droppedSounds)")
        try expect(settingsModel.message == "Imported Voiced set: \(names.count) characters, 5 sounds.",
                   "the import says how many sounds came: \(settingsModel.message ?? "nil")")
        for file in ["voice/not-audio.wav", "voice/huge.wav", "voice/long.wav", "escape.wav"] {
            try expect(!fm.fileExists(atPath: store.appendingPathComponent(file).path), "\(file) is not copied")
        }
        try expect(!fm.fileExists(atPath: imports.appendingPathComponent("escape.wav").path), "nothing lands outside the set's folder")

        // MARK: 2 · playback through production

        let delegate = AppDelegate()
        delegate.registryStore = RegistryStore(applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true))
        let agentStore = AgentStore(applicationSupportDirectory: agentsSupport)
        let now = Date()
        let lead = AgentID(rawValue: UUID()), first = AgentID(rawValue: UUID()), second = AgentID(rawValue: UUID())
        func record(_ id: AgentID, parent: AgentID?, character: String?) throws {
            var r = AgentRecord(id: id, displayName: "agent", model: "openai-codex/gpt-5.6-sol", thinking: "medium",
                                cwd: root.path, parentAgentID: parent, createdAt: now, lastActivityAt: now, tileId: UUID())
            r.characterName = character
            try agentStore.upsert(r)
        }
        try record(lead, parent: nil, character: nil)
        try record(first, parent: lead, character: names[0])
        try record(second, parent: lead, character: names[1])
        delegate.agentSupervisor = AgentSupervisor(
            store: agentStore, makeRunner: { _ in ScriptedAgentRunner(script: [], holdUntilStopped: true) })
        let supervisor = delegate.agentSupervisor
        supervisor.restore()
        let sink = Sink()
        let library = AgentSoundLibrary(
            bundleRoot: URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/AgentSounds", isDirectory: true),
            applicationSupportRoot: root.appendingPathComponent("support", isDirectory: true))
        delegate.agentSignalCenter = AgentSignalCenter(defaults: defaults, library: library, player: sink)
        let center = AgentCharacterSoundCenter(defaults: defaults, player: sink,
                                               speaker: AgentCharacterSoundCenter.productionSpeaker { supervisor.records[AgentID(rawValue: $0)] })
        var clock = now
        center.clock = { clock }
        center.pick = { _ in 0 }
        delegate.characterSoundCenter = center
        delegate.installAgentActivityObserver()

        var turn = 0
        /// One event through the supervisor's delivery; returns what it played.
        func deliver(_ event: AgentRuntimeEvent, to id: AgentID, after seconds: TimeInterval = 10) -> [String] {
            clock = clock.addingTimeInterval(seconds)
            let before = sink.plays.count
            supervisor.qaDeliver(event, to: id)
            return Array(sink.plays[before...])
        }
        func finishTurn(_ id: AgentID, _ outcome: TurnOutcome = .completed, lasting: TimeInterval = 5) -> [String] {
            turn += 1
            let thread = AgentSupervisor.threadId(for: id)
            _ = deliver(.turnStarted(threadId: thread, turnId: "t\(turn)"), to: id)
            return deliver(.turnCompleted(threadId: thread, turnId: "t\(turn)", outcome: outcome,
                                          errorMessage: outcome == .failed ? "boom" : nil), to: id, after: lasting)
        }
        func spawn(_ child: AgentID) -> [String] {
            deliver(.childAgentSpawned(threadId: AgentSupervisor.threadId(for: lead), childAgentID: child.rawValue,
                                       parentAgentID: lead.rawValue, displayName: "helper", sourceItemID: nil,
                                       provider: "codex", spawnedAt: clock), to: lead)
        }
        func request(_ id: AgentID) -> [String] {
            turn += 1
            return deliver(.requestOpened(threadId: AgentSupervisor.threadId(for: id), requestId: "r\(turn)",
                                          kind: .commandExecutionApproval), to: id)
        }

        // Toggle off (the default): nothing, for every moment.
        try expect(!AgentCharacterSoundConfig.isEnabled(defaults), "character sounds are off by default")
        var silent = spawn(first) + finishTurn(first) + finishTurn(lead, lasting: 40) + finishTurn(second, .failed) + request(lead)
        try expect(silent.isEmpty, "toggle off: nothing plays — played \(silent)")
        try expect(center.outcomes.suffix(5).allSatisfy { if case .quiet(_, .off) = $0 { return true }; return false },
                   "toggle off: each moment is quiet because the toggle is off: \(center.outcomes.suffix(5))")

        defaults.set(true, forKey: AgentCharacterSoundConfig.enabledKey)
        // The set's own clips, one sound per moment.
        try expect(spawn(second) == ["character:voice/lead-1.wav"], "a spawn plays the set's spawn voice")
        try expect(finishTurn(first) == ["character:voice/first.wav"], "a helper's finish plays its character's done voice")
        try expect(finishTurn(second) == ["character:voice/any.wav"],
                   "a helper whose done clip was left out falls back to the set's any voice")
        try expect(finishTurn(lead, lasting: 40) == ["character:sounds/quack.wav"],
                   "over to you after a 40 s turn quacks (the set has no quack of its own, so the bundled one)")
        try expect(finishTurn(lead, lasting: 5).isEmpty, "a quick lead reply does not quack")
        try expect(request(lead) == ["character:voiced/own-chirp.wav"], "needs-you plays the set's own chirp")
        try expect(finishTurn(first, .failed) == ["character:sounds/honk.wav"], "a failure honks with the bundled sound")
        // Replays ring once; a fan-out inside the gap is one sound.
        let replayThread = AgentSupervisor.threadId(for: first)
        _ = deliver(.turnStarted(threadId: replayThread, turnId: "replay"), to: first)
        let once = deliver(.turnCompleted(threadId: replayThread, turnId: "replay", outcome: .completed, errorMessage: nil), to: first)
        let again = deliver(.turnCompleted(threadId: replayThread, turnId: "replay", outcome: .completed, errorMessage: nil), to: first)
        try expect(once.count == 1 && again.isEmpty, "a replayed completion rings once: \(once) then \(again)")
        let third = AgentID(rawValue: UUID())
        let fanOut = spawn(third) + deliver(.childAgentSpawned(
            threadId: AgentSupervisor.threadId(for: lead), childAgentID: UUID(), parentAgentID: lead.rawValue,
            displayName: "helper", sourceItemID: nil, provider: "codex", spawnedAt: clock), to: lead, after: 0.3)
        try expect(fanOut.count == 1, "two spawns inside \(AgentCharacterSoundCenter.minimumGap) s are one sound: \(fanOut)")

        // The built-in set: Duckherd's sounds; a spawn says nothing.
        settingsModel.select(id: AgentCharacterBundled.themeID)
        try expect(controller.theme?.id == AgentCharacterBundled.themeID, "the built-in set is shown")
        try expect(finishTurn(first) == ["character:sounds/quack.wav"], "built-in set: a helper's finish quacks")
        try expect(finishTurn(lead, lasting: 31) == ["character:sounds/quack.wav"], "built-in set: over to you quacks")
        try expect(request(first) == ["character:sounds/chirp.wav"], "built-in set: needs-you chirps")
        try expect(spawn(AgentID(rawValue: UUID())).isEmpty, "built-in set: a spawn is silent")

        // Never doubled: an enabled alert sound for the same moment plays alone.
        defaults.set(true, forKey: AgentSoundConfig.enabledKey(for: .completed))
        defaults.set(true, forKey: AgentSoundConfig.enabledKey(for: .actionRequired))
        try expect(finishTurn(first) == ["alert:bloom"], "the Completed alert wins over the character's quack")
        try expect(request(lead) == ["alert:beacon"], "the Action required alert wins over the character's chirp")
        try expect(finishTurn(second, .failed) == ["character:sounds/honk.wav"],
                   "a moment with its alert off still gets the character")
        if case .quiet(_, .alertPlayed)? = center.outcomes.dropLast().last {} else {
            throw Failure(description: "the character records why it stayed quiet: \(center.outcomes.suffix(3))")
        }
        defaults.removeObject(forKey: AgentSoundConfig.enabledKey(for: .completed))
        defaults.removeObject(forKey: AgentSoundConfig.enabledKey(for: .actionRequired))
        // A per-tile mute silences the character too.
        let muted = center.ingest(event: .requestOpened(threadId: "m", requestId: "m1", kind: .commandExecutionApproval),
                                  agentID: lead.rawValue, isHelper: false,
                                  overrides: AgentSoundOverrides(values: [.actionRequired: .mute]), alertSounded: false)
        try expect(muted == .quiet(.needsYou, .muted), "a muted tile is quiet: \(String(describing: muted))")

        // Master switch off, then characters hidden: nothing.
        defaults.set(false, forKey: AgentSoundConfig.masterEnabledKey)
        silent = finishTurn(first) + request(lead)
        try expect(silent.isEmpty, "master off: nothing plays — played \(silent)")
        defaults.removeObject(forKey: AgentSoundConfig.masterEnabledKey)
        defaults.set(false, forKey: AgentCharacterConfig.enabledKey)
        controller.reload()
        silent = finishTurn(first) + request(lead)
        try expect(silent.isEmpty, "characters hidden: nothing plays — played \(silent)")
        try expect(center.outcomes.suffix(2).allSatisfy { if case .quiet(_, .charactersHidden) = $0 { return true }; return false },
                   "characters hidden: quiet for that reason")
        defaults.set(true, forKey: AgentCharacterConfig.enabledKey)
        controller.reload()

        // MARK: 3 · the Settings row, light and dark

        let settings = SettingsModel(defaults: defaults, navKeymap: .default, soundLibrary: library)
        try expect(SettingsSchema.customEntries(for: SettingsField.agentSounds(label: "Agent sounds")).contains { $0.anchor == "sounds.characters" },
                   "Settings search knows the Character sounds row")
        guard let group = settings.sections.first(where: { $0.id == "activityAndNotifications" })?.groups.first(where: { $0.id == "sounds" })
        else { throw Failure(description: "Settings has no Notifications & Sounds › Sounds group") }
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CONTINUUM_CHARACTER_SOUNDS_STILLS"]
                      ?? fm.currentDirectoryPath + "/qa-runs/character-sounds", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(rootView: Form {
                Section(group.title ?? "") {
                    ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in SettingsFieldRow(model: settings, row: row) }
                }
            }.formStyle(.grouped))
            host.frame = NSRect(x: 0, y: 0, width: 720, height: 620)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.orderFrontOffscreenForChecks()
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            try SidebarCharacterChecks.capture(window, to: out.appendingPathComponent(
                "character-sounds-\(appearance == .aqua ? "light" : "dark").png"))
        }
        return "Character sounds checks passed: import kept 5 sounds and left out 5 with reasons; toggle off silent; each moment one sound from the set's clip or the bundled Duckherd sound; replays and fan-outs ring once; alert sounds win with no double play; mute, master off and hidden characters silent; Settings row rendered light and dark in \(out.path)"
    }
}
