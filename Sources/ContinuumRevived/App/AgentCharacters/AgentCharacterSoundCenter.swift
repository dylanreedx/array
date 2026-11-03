import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

/// Character sounds (notification paths MAC-10…MAC-13): the agent's character
/// makes one sound at a few moments, Duckherd-style. Fed from
/// `AppDelegate.recordManagedActivity` beside the alert sounds, for agents with a
/// tile on this Mac only, so a shared agent's guest never hears the host's.
///
/// One sound per moment: the set's own clip (its `voices`, or its `sounds`
/// replacement) when its folder has one, else the bundled Duckherd sound. Array's
/// alert sound for the same moment wins; the character then stays quiet.
@MainActor
final class AgentCharacterSoundCenter {
    /// The character that speaks for an agent in the shown set.
    struct Speaker: Equatable {
        /// The set's folder in Array's store; nil for the built-in set.
        let themeFolder: URL?
        /// The character's name, for a set's per-character `done` clips.
        let characterName: String?
    }

    enum QuietReason: String, Equatable {
        case off, masterOff, charactersHidden, muted, alertPlayed, tooSoon, noSound
    }

    enum Outcome: Equatable {
        case played(AgentCharacterSoundMoment, AgentCharacterSoundSource)
        case quiet(AgentCharacterSoundMoment, QuietReason)
    }

    /// Two character sounds this close: the later one is dropped, unless it is a
    /// failure or a request (a fan-out of six helpers is one sound, not six).
    static let minimumGap: TimeInterval = 1.5

    private let defaults: UserDefaults
    private let player: any AgentCharacterSoundPlaying
    private var detector = AgentCharacterSoundMomentDetector()
    private var lastPlayedAt: Date?
    private var voiceCache: [URL: (stamp: Date?, voices: AgentCharacterVoices)] = [:]
    /// Who speaks for an agent; nil while characters are hidden.
    var speaker: (UUID) -> Speaker?
    var clock: () -> Date = { Date() }
    var pick: (Int) -> Int = { Int.random(in: 0..<$0) }
    var bundledURL: (AgentCharacterBaseSound) -> URL? = AgentCharacterBundled.soundURL
    /// The last 100 outcomes, newest last: what a witness reads for the quiet ones.
    private(set) var outcomes: [Outcome] = []

    init(defaults: UserDefaults = .standard, player: any AgentCharacterSoundPlaying = AgentSoundPlayer.shared,
         speaker: @escaping (UUID) -> Speaker?) {
        self.defaults = defaults
        self.player = player
        self.speaker = speaker
    }

    /// One runtime event from `agentID`'s own stream (it has a tile).
    /// `alertSounded`: Array's alert sound just played for this same event.
    @discardableResult
    func ingest(event: AgentRuntimeEvent, agentID: UUID, isHelper: Bool,
                overrides: AgentSoundOverrides?, alertSounded: Bool) -> Outcome? {
        let now = clock()
        guard let (moment, speakerID) = detector.moment(for: event, agentID: agentID, isHelper: isHelper, now: now)
        else { return nil }
        let outcome = decide(moment, speakerID: speakerID, overrides: overrides, alertSounded: alertSounded, now: now)
        outcomes.append(outcome)
        if outcomes.count > 100 { outcomes.removeFirst(outcomes.count - 100) }
        return outcome
    }

    private func decide(_ moment: AgentCharacterSoundMoment, speakerID: UUID, overrides: AgentSoundOverrides?,
                        alertSounded: Bool, now: Date) -> Outcome {
        guard AgentCharacterSoundConfig.isEnabled(defaults) else { return .quiet(moment, .off) }
        guard AgentSoundConfig.isMasterEnabled(defaults: defaults) else { return .quiet(moment, .masterOff) }
        guard let speaker = speaker(speakerID) else { return .quiet(moment, .charactersHidden) }
        if let kind = moment.alertKind, overrides?.values[kind] == .mute { return .quiet(moment, .muted) }
        if alertSounded { return .quiet(moment, .alertPlayed) }
        if !moment.isUrgent, let last = lastPlayedAt, now.timeIntervalSince(last) < Self.minimumGap {
            return .quiet(moment, .tooSoon)
        }
        let voices = speaker.themeFolder.map(voices(in:)) ?? AgentCharacterVoices()
        guard let source = AgentCharacterSoundResolver.resolve(
            moment: moment, characterName: speaker.characterName, voices: voices,
            themeFolder: speaker.themeFolder, pick: pick) else { return .quiet(moment, .noSound) }
        let url: URL
        switch source {
        case let .theme(file): url = file
        case let .bundled(base):
            guard let bundled = bundledURL(base) else { return .quiet(moment, .noSound) }
            url = bundled
        }
        player.playCharacterSound(url, priority: moment.priority,
                                  volume: AgentSoundConfig.resolvedVolume(defaults: defaults))
        lastPlayedAt = now
        return .played(moment, source)
    }

    /// The set's `voices` and `sounds`, re-read only when its file changes.
    private func voices(in folder: URL) -> AgentCharacterVoices {
        let file = folder.appendingPathComponent(AgentCharacterImports.fileName)
        let stamp = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
        if let cached = voiceCache[folder], cached.stamp == stamp { return cached.voices }
        let parsed = (try? Data(contentsOf: file)).map(AgentCharacterVoices.parse(themeData:)) ?? AgentCharacterVoices()
        voiceCache[folder] = (stamp, parsed)
        return parsed
    }
}

extension AgentCharacterSoundCenter {
    /// Production's speaker: the agent's character in the shown set, while
    /// characters show. A set written straight into the themes folder as
    /// `*.theme.json` has no folder of its own, so it speaks with the bundled sounds.
    static func productionSpeaker(records: @escaping (UUID) -> AgentRecord?) -> (UUID) -> Speaker? {
        { id in
            let characters = AgentCharacterController.shared
            guard characters.isEnabled, let theme = characters.theme else { return nil }
            let name = characters.characterIndex(for: id, name: records(id)?.characterName)
                .flatMap { $0 < theme.characters.count ? theme.characters[$0].name : nil }
            let file = theme.id == AgentCharacterBundled.themeID ? nil : characters.userThemeFileURL(id: theme.id)
            let folder = file.flatMap { $0.lastPathComponent == AgentCharacterImports.fileName ? $0.deletingLastPathComponent() : nil }
            return Speaker(themeFolder: folder, characterName: name)
        }
    }
}
