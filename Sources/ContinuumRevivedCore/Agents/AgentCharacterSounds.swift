#if canImport(AVFoundation)
import AVFoundation
#endif
import ContinuumRevivedAgentUI
import Foundation

// Character sounds: an agent's character makes a sound at a few moments, the way
// Duckherd's ducks do (Duckherd by Ali Alsalkhadi, MIT). Notification path IDs
// MAC-10…MAC-13 in docs/internals/notification-paths.md.

/// Settings › Notifications & Sounds › Character sounds. Off by default.
public enum AgentCharacterSoundConfig {
    public static let enabledKey = "agentCharacters.sounds"
    public static let defaultEnabled = false

    public static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }
}

/// The Duckherd base sounds Array plays, bundled under its MIT license. Duckherd's
/// snore is left out: it plays it at no moment either.
public enum AgentCharacterBaseSound: String, CaseIterable, Sendable {
    case quack, honk, chirp

    public var fileName: String { "\(rawValue).wav" }
}

/// The moments a character makes a sound. Small on purpose: Duckherd itself only
/// quacks when the lead turns back to you and chirps when something needs you.
public enum AgentCharacterSoundMoment: String, CaseIterable, Sendable {
    /// A lead delegated a helper. Only a set with spawn voices speaks here.
    case helperStarted
    /// A helper finished its turn.
    case helperFinished
    /// A top-level agent finished a turn of 30 s or more: over to you.
    case overToYou
    /// A turn failed.
    case failed
    /// The agent asked for approval or input.
    case needsYou

    /// The bundled sound when the set has nothing of its own; nil is silence.
    public var baseSound: AgentCharacterBaseSound? {
        switch self {
        case .helperStarted: return nil
        case .helperFinished, .overToYou: return .quack
        case .failed: return .honk
        case .needsYou: return .chirp
        }
    }

    /// The Array alert sound that would ring for the same moment. That sound
    /// wins: when it plays, the character stays quiet.
    public var alertKind: AgentSignalKind? {
        switch self {
        case .helperStarted: return nil
        case .helperFinished, .overToYou: return .completed
        case .failed: return .failed
        case .needsYou: return .actionRequired
        }
    }

    /// Below every alert sound, so a character never cuts one off.
    public var priority: Int {
        switch self {
        case .helperStarted: return 10
        case .helperFinished: return 20
        case .overToYou: return 30
        case .failed: return 40
        case .needsYou: return 50
        }
    }

    /// Exempt from the gap between character sounds.
    public var isUrgent: Bool { self == .failed || self == .needsYou }
}

/// A set's `voices` (per-moment clips, as Duckherd themes shared today carry them)
/// and `sounds` (Duckherd's published theme-wide replacements for the four base
/// sounds). Paths are relative to the theme file.
public struct AgentCharacterVoices: Equatable, Sendable {
    public var spawn: [String] = []
    public var doneByName: [String: [String]] = [:]
    public var done: [String] = []
    public var any: [String] = []
    public var sounds: [AgentCharacterBaseSound: String] = [:]
    /// Entries that are not a usable path: where, then the entry.
    public var problems: [String] = []

    public init() {}

    public static let maximumPathsPerList = 32

    public var isEmpty: Bool { spawn.isEmpty && doneByName.isEmpty && done.isEmpty && any.isEmpty && sounds.isEmpty }

    /// Every distinct file the set refers to, in a stable order.
    public var referencedFiles: [String] {
        var seen = Set<String>()
        let all = spawn + doneByName.keys.sorted().flatMap { doneByName[$0] ?? [] } + done + any
            + AgentCharacterBaseSound.allCases.compactMap { sounds[$0] }
        return all.filter { seen.insert($0).inserted }
    }

    /// The clips that may play for `moment`, most specific list first.
    public func candidates(for moment: AgentCharacterSoundMoment, characterName: String?) -> [[String]] {
        var lists: [[String]]
        switch moment {
        case .helperStarted:
            lists = [spawn, any]
        case .helperFinished:
            let named = characterName.flatMap { name in
                doneByName.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
            } ?? []
            lists = [named, done, any]
        case .overToYou, .failed, .needsYou:
            lists = []
        }
        if let base = moment.baseSound, let file = sounds[base] { lists.append([file]) }
        return lists.filter { !$0.isEmpty }
    }

    /// Read `voices` and `sounds` from a theme file. Lenient: a bad entry is
    /// skipped and listed, the rest still count. Unknown keys are ignored.
    public static func parse(themeData data: Data) -> AgentCharacterVoices {
        var result = AgentCharacterVoices()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return result }
        func paths(_ value: Any?, at place: String) -> [String] {
            guard let value else { return [] }
            let raw: [Any] = (value as? [Any]) ?? [value]
            var out: [String] = []
            for (n, entry) in raw.enumerated() {
                guard let path = entry as? String, isVoicePath(path) else {
                    result.problems.append("\(place)[\(n)] \(entry as? String ?? "(not text)")")
                    continue
                }
                if out.count < maximumPathsPerList, !out.contains(path) { out.append(path) }
            }
            return out
        }
        if let voices = object["voices"] as? [String: Any] {
            result.spawn = paths(voices["spawn"], at: "voices.spawn")
            result.any = paths(voices["any"], at: "voices.any")
            if let byName = voices["done"] as? [String: Any] {
                for name in byName.keys.sorted() {
                    let list = paths(byName[name], at: "voices.done.\(name)")
                    if !list.isEmpty { result.doneByName[name] = list }
                }
            } else {
                result.done = paths(voices["done"], at: "voices.done")
            }
        }
        if let sounds = object["sounds"] as? [String: Any] {
            for kind in AgentCharacterBaseSound.allCases {
                guard let file = sounds[kind.rawValue] as? String else { continue }
                if AgentCharacterThemeParser.isSoundFileName(file) {
                    result.sounds[kind] = file
                } else {
                    result.problems.append("sounds.\(kind.rawValue) \(file)")
                }
            }
        }
        return result
    }

    /// A relative path of at most two parts (`clip.mp3`, `voice/clip.mp3`), each
    /// part a Duckherd sound file name or folder name: no `..`, no absolute path.
    public static func isVoicePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), !path.hasPrefix("/"), !path.contains("..") else { return false }
        if parts.count == 2 {
            func alnum(_ s: Unicode.Scalar) -> Bool {
                ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s)
            }
            let folder = parts[0].unicodeScalars
            guard let first = folder.first, (1...64).contains(folder.count), alnum(first),
                  folder.allSatisfy({ alnum($0) || "_-".unicodeScalars.contains($0) })
            else { return false }
        }
        return AgentCharacterThemeParser.isSoundFileName(parts[parts.count - 1])
    }
}

/// Where a character sound comes from.
public enum AgentCharacterSoundSource: Equatable, Sendable {
    /// A file in the set's own folder in Array's store.
    case theme(URL)
    /// One of the bundled Duckherd sounds.
    case bundled(AgentCharacterBaseSound)
}

public enum AgentCharacterSoundResolver {
    /// The sound for `moment`: one of the set's clips that is on disk inside its
    /// folder, else the bundled base sound, else nil (silence).
    public static func resolve(
        moment: AgentCharacterSoundMoment, characterName: String?,
        voices: AgentCharacterVoices, themeFolder: URL?,
        pick: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> AgentCharacterSoundSource? {
        if let themeFolder {
            for list in voices.candidates(for: moment, characterName: characterName) {
                let present = list.compactMap { AgentCharacterAudioImport.containedFile($0, in: themeFolder) }
                    .filter { AgentCharacterAudioImport.isPlayableCopy($0) }
                if !present.isEmpty { return .theme(present[min(max(0, pick(present.count)), present.count - 1)]) }
            }
        }
        return moment.baseSound.map { .bundled($0) }
    }
}

/// Copies the audio a set refers to into Array's copy of the set, within caps.
public enum AgentCharacterAudioImport {
    public static let maximumFileBytes = 2 * 1024 * 1024
    public static let maximumTotalBytes = 16 * 1024 * 1024
    public static let maximumFiles = 64
    public static let maximumDuration: TimeInterval = 10

    public struct Report: Equatable, Sendable {
        public var copied: [String] = []
        /// Each file left behind and why, in plain words.
        public var dropped: [(file: String, reason: String)] = []
        public init() {}

        public static func == (a: Report, b: Report) -> Bool {
            a.copied == b.copied && a.dropped.map(\.file) == b.dropped.map(\.file)
                && a.dropped.map(\.reason) == b.dropped.map(\.reason)
        }
    }

    /// `relative` inside `folder`, after symlinks; nil if it would leave it.
    public static func containedFile(_ relative: String, in folder: URL) -> URL? {
        guard AgentCharacterVoices.isVoicePath(relative) else { return nil }
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let file = folder.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        return file.path.hasPrefix(root + "/") ? file : nil
    }

    /// A copy in the store still within the per-file cap (cheap: one stat).
    public static func isPlayableCopy(_ url: URL) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        else { return false }
        return size > 0 && size <= maximumFileBytes
    }

    /// The audio's length if it decodes as audio, else nil.
    public static func decodedDuration(_ url: URL) -> TimeInterval? {
        #if canImport(AVFoundation)
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        let seconds = Double(file.length) / rate
        return seconds.isFinite && seconds > 0 ? seconds : nil
        #else
        return nil
        #endif
    }

    /// Copy every file `voices` refers to from `source` into `destination`,
    /// keeping its relative path. Nothing outside `source` is read.
    public static func copy(
        _ voices: AgentCharacterVoices, from source: URL, to destination: URL,
        duration: (URL) -> TimeInterval? = decodedDuration
    ) -> Report {
        var report = Report()
        var total = 0
        let fm = FileManager.default
        for relative in voices.referencedFiles {
            func drop(_ reason: String) { report.dropped.append((relative, reason)) }
            guard report.copied.count < maximumFiles else { drop("the set already has \(maximumFiles) sound files"); continue }
            guard let file = containedFile(relative, in: source) else { drop("the path leaves the theme's folder"); continue }
            guard fm.fileExists(atPath: file.path) else { drop("there is no such file beside the theme"); continue }
            let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else { drop("the file is empty"); continue }
            guard size <= maximumFileBytes else { drop("the file is over 2 MB"); continue }
            guard total + size <= maximumTotalBytes else { drop("the set's sounds would be over 16 MB together"); continue }
            guard let seconds = duration(file) else { drop("it is not a WAV or MP3 Array can play"); continue }
            guard seconds <= maximumDuration else { drop("it is longer than 10 seconds"); continue }
            let target = destination.appendingPathComponent(relative)
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: file, to: target)
            } catch {
                drop("Array could not save its copy")
                continue
            }
            total += size
            report.copied.append(relative)
        }
        return report
    }
}

/// Which moment, if any, a runtime event is for one agent: dedupes replays and
/// times turns so a quick reply does not quack.
public struct AgentCharacterSoundMomentDetector: Sendable {
    public static let overToYouMinimumTurn: TimeInterval = 30
    private var seen: Set<String> = []
    private var turnStarts: [UUID: Date] = [:]

    public init() {}

    /// `isHelper` is whether `agentID` has a parent. The returned agent is the one
    /// whose character speaks: the child for a spawn, else `agentID`.
    public mutating func moment(
        for event: AgentRuntimeEvent, agentID: UUID, isHelper: Bool, now: Date
    ) -> (moment: AgentCharacterSoundMoment, speaker: UUID)? {
        let key: String
        let moment: AgentCharacterSoundMoment
        var speaker = agentID
        switch event {
        case .turnStarted:
            turnStarts[agentID] = now
            return nil
        case let .turnCompleted(thread, turn, outcome, _):
            let started = turnStarts.removeValue(forKey: agentID)
            switch outcome {
            case .completed:
                if isHelper {
                    moment = .helperFinished
                } else {
                    guard let started, now.timeIntervalSince(started) >= Self.overToYouMinimumTurn else { return nil }
                    moment = .overToYou
                }
            case .failed:
                moment = .failed
            case .interrupted, .cancelled:
                return nil
            }
            key = "turn:\(agentID):\(thread):\(turn):\(outcome)"
        case let .runtimeError(thread, message):
            moment = .failed
            key = "runtime:\(agentID):\(thread ?? "-"):\(message.hashValue)"
        case let .requestOpened(thread, request, _), let .userInputRequested(thread, request, _):
            moment = .needsYou
            key = "request:\(agentID):\(thread):\(request)"
        case let .childAgentSpawned(_, child, _, _, _, _, _):
            moment = .helperStarted
            speaker = child
            key = "spawn:\(child)"
        default:
            return nil
        }
        guard seen.insert(key).inserted else { return nil }
        return (moment, speaker)
    }
}
