import ContinuumRevivedAgentUI
import CryptoKit
import Foundation

// Plan: .plans/110-agent-characters/README.md
/// Where the built-in agent characters ship, and their parsed theme.
public enum AgentCharacterBundled {
    public static let themeFileName = "ducks.theme.json"
    /// The built-in set's theme id.
    public static let themeID = "ducks-classic"
    public static let licenseFileName = "LICENSE.txt"
    static let folder = "AgentCharacters"
    static let resourceBundleName = "continuum-revived_ContinuumRevivedCore.bundle"

    /// The built-in set's folder: inside the app at Contents/Resources, or beside
    /// a bare binary (checks), as `make-app-bundle.sh` lays Core's resources out.
    public static func folderURL() -> URL? {
        let roots = [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        for root in roots {
            let url = root.appendingPathComponent(resourceBundleName).appendingPathComponent(folder)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(themeFileName).path) { return url }
        }
        return nil
    }

    public static var themeURL: URL? { folderURL()?.appendingPathComponent(themeFileName) }
    public static var licenseURL: URL? { folderURL()?.appendingPathComponent(licenseFileName) }
    /// A bundled character sound (Duckherd's, MIT): `<folder>/sounds/<name>.wav`.
    public static func soundURL(_ sound: AgentCharacterBaseSound) -> URL? {
        guard let url = folderURL()?.appendingPathComponent("sounds").appendingPathComponent(sound.fileName),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// The other built-in sets, in the picker's order. Each ships as
    /// `<packs>/<id>/theme.json` with its sounds beside it: the layout of an
    /// imported user set, read by the same parser and the same sound resolver.
    public static let packIDs = ["street-sigils", "living-chords", "ascii-morph", "signal-ghosts"]
    /// Mac only: the iOS app links Core but not this bundle, so there every pack
    /// lookup is nil and only the ducks exist.
    static let packsBundleName = "continuum-revived_ContinuumRevivedCharacterPacks.bundle"
    static let packsFolder = "packs"
    static let manifestFileName = "manifest.json"
    /// A pack's small cut of itself: a valid theme holding only what a preview
    /// card draws. `scripts/make-character-pack-cards.py` writes it.
    static let cardFileName = "card.json"

    /// Every built-in id, the ducks first. No user set may take one.
    public static var builtInIDs: [String] { [themeID] + packIDs }

    public static func isBuiltIn(_ id: String) -> Bool { id == themeID || packIDs.contains(id) }

    /// The packs' folder, found the way `folderURL()` finds Core's.
    public static func packsFolderURL() -> URL? {
        let roots = [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        for root in roots {
            let url = root.appendingPathComponent(packsBundleName).appendingPathComponent(packsFolder, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(manifestFileName).path) { return url }
        }
        return nil
    }

    /// A built-in pack's folder (holding its `theme.json` and sounds); nil for the
    /// ducks, whose sounds are the base ones, and for a pack that is missing.
    public static func packFolderURL(id: String) -> URL? {
        guard packIDs.contains(id),
              let url = packsFolderURL()?.appendingPathComponent(id, isDirectory: true),
              FileManager.default.fileExists(atPath: url.appendingPathComponent(AgentCharacterImports.fileName).path)
        else { return nil }
        return url
    }

    /// What a picker says about a built-in set, known without parsing it.
    public struct Summary: Codable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let characters: Int
    }

    nonisolated(unsafe) private static var cachedSummaries: [Summary]?

    /// Every built-in set's summary, from one small file, read once. Only ids
    /// that are built in, in the picker's order; empty where the packs do not ship.
    public static func summaries() -> [Summary] {
        lock.lock()
        defer { lock.unlock() }
        if let cachedSummaries { return cachedSummaries }
        let file = packsFolderURL()?.appendingPathComponent(manifestFileName)
        let listed = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([Summary].self, from: $0) } ?? []
        let ordered = builtInIDs.compactMap { id in listed.first { $0.id == id } }
        cachedSummaries = ordered
        return ordered
    }

    nonisolated(unsafe) private static var cached: [String: AgentCharacterTheme] = [:]
    private static let lock = NSLock()
    /// Whole built-in sets parsed so far, and how many of those on the main
    /// thread: what a witness reads.
    nonisolated(unsafe) private static var parses = (all: 0, onMain: 0)
    public static var parseCount: (all: Int, onMain: Int) {
        lock.lock()
        defer { lock.unlock() }
        return parses
    }

    /// The ducks, parsed once per process. nil only when the resource is
    /// missing or broken, which the bundle checks catch before a release.
    public static func theme() -> AgentCharacterTheme? { theme(id: themeID) }

    /// The built-in set `id` if it has been parsed; never reads a file.
    public static func cachedTheme(id: String) -> AgentCharacterTheme? {
        lock.lock()
        defer { lock.unlock() }
        return cached[id]
    }

    /// The built-in set `id`, parsed once per process; nil when `id` is not a
    /// built-in id or its resource is missing or broken. A pack is megabytes of
    /// JSON: anything that can wait should use `loadTheme(id:)`.
    public static func theme(id: String) -> AgentCharacterTheme? {
        if let theme = cachedTheme(id: id) { return theme }
        let url = id == themeID ? themeURL : packFolderURL(id: id)?.appendingPathComponent(AgentCharacterImports.fileName)
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        // Outside the lock: a parse must not stall a reader of another set.
        let parsed = AgentCharacterThemeParser.parse(data: data)
        guard case let .success(theme) = parsed, theme.id == id else { return nil }
        let onMain = Thread.isMainThread
        lock.lock()
        defer { lock.unlock() }
        parses.all += 1
        if onMain { parses.onMain += 1 }
        cached[id] = theme
        return theme
    }

    /// `theme(id:)` off the main thread.
    public static func loadTheme(id: String) async -> AgentCharacterTheme? {
        if let theme = cachedTheme(id: id) { return theme }
        return await Task.detached(priority: .userInitiated) { theme(id: id) }.value
    }

    /// What a preview card draws for the built-in set `id`: a pack's small cut,
    /// or the ducks, whose whole file is that small. Not cached: its owner keeps
    /// the pictures it builds from this, not the frames.
    public static func cardTheme(id: String) -> AgentCharacterTheme? {
        let url = id == themeID ? themeURL : packFolderURL(id: id)?.appendingPathComponent(cardFileName)
        guard let url, let data = try? Data(contentsOf: url),
              case let .success(theme) = AgentCharacterThemeParser.parse(data: data), theme.id == id else { return nil }
        return theme
    }
}

/// The words the app shows for this feature, in one place so renaming it is one
/// edit. Keys, ids, wire fields, tool arguments and file names are not here: those
/// never change with the word.
public enum AgentCharacterCopy {
    /// The Settings page and its sidebar entry.
    public static let feature = "Agent Icons"
    public static let show = "Show agent icons"
    public static let one = "icon"
    public static let many = "icons"
    /// `one` with its article, for a sentence.
    public static let anOne = "an icon"
    /// The tile's menu.
    public static let menu = "Icon"
    /// The sets: as a heading, and in a sentence.
    public static let set = "Agent Icon Packs"
    public static let pack = "agent icon pack"
    public static let aPack = "an agent icon pack"
    public static let packs = "agent icon packs"
    public static let size = "Icon size"
    public static let sounds = "Icon sounds"

    public static func count(_ count: Int) -> String { "\(count) \(count == 1 ? one : many)" }
}

/// Settings › Agent Icons. Off by default.
public enum AgentCharacterConfig {
    public static let enabledKey = "agentCharacters.enabled"
    public static let defaultEnabled = false
    public static let motionKey = "agentCharacters.motion"
    /// The selected set's id; the built-in set's when absent.
    public static let themeKey = "agentCharacters.theme"

    public enum Motion: String, CaseIterable, Sendable {
        /// Agents in motion animate; everything at rest holds still.
        case working
        /// Every character holds its state's still frame.
        case never

        public var title: String {
            switch self {
            case .working: return "Working agents only"
            case .never: return "Never (still poses)"
            }
        }
    }

    public static let defaultMotion = Motion.working

    /// How big characters are, and with them the line that holds each one: the
    /// sidebar row's second line and the agent tile's title bar.
    public static let sizeKey = "agentCharacters.size"

    public enum Size: String, CaseIterable, Sendable {
        /// The original size: one point per art pixel, a 24 pt title bar.
        case small
        case medium
        case large

        /// How much the character's slot and its surroundings grow.
        public var factor: Double {
            switch self {
            case .small: return 1
            case .medium: return 1.5
            case .large: return 2.25
            }
        }

        public var title: String {
            switch self {
            case .small: return "Small"
            case .medium: return "Medium"
            case .large: return "Large"
            }
        }

        /// Device pixels per art pixel on a display of `backingScale`: the nearest
        /// whole number to `factor × backingScale`, halves rounding up, so a
        /// pixel-art character is never resampled to a fraction and every size
        /// is bigger than Small on every display (2/3/5 on Retina, 1/2/2 at 1x).
        public func devicePixelsPerArtPixel(backingScale: Double) -> Int {
            let scale = backingScale.isFinite && backingScale > 0 ? backingScale : 2
            return max(1, Int((factor * scale).rounded(.toNearestOrAwayFromZero)))
        }

        /// Points per art pixel: `devicePixelsPerArtPixel / backingScale`.
        public func pointsPerArtPixel(backingScale: Double) -> Double {
            let scale = backingScale.isFinite && backingScale > 0 ? backingScale : 2
            return Double(devicePixelsPerArtPixel(backingScale: scale)) / scale
        }
    }

    public static let defaultSize = Size.small

    public static func size(_ defaults: UserDefaults) -> Size {
        defaults.string(forKey: sizeKey).flatMap(Size.init(rawValue:)) ?? defaultSize
    }

    public static func isEnabled(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    public static func motion(_ defaults: UserDefaults) -> Motion {
        defaults.string(forKey: motionKey).flatMap(Motion.init(rawValue:)) ?? defaultMotion
    }

    /// FNV-1a over the agent id's 16 bytes: the same agent gets the same character
    /// on every launch, surface and device, with nothing stored.
    public static func stableHash(_ id: UUID) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        withUnsafeBytes(of: id.uuid) { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
        }
        return hash
    }

    public static func characterIndex(for id: UUID, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return Int(stableHash(id) % UInt64(count))
    }

    /// 0..<1: where in its loop this agent's character is, so two agents doing the
    /// same thing do not move in step.
    public static func phase(for id: UUID) -> Double {
        Double((stableHash(id) >> 20) % 10_000) / 10_000
    }
}

/// Plan 110 › lead: who leads and who helps, from the host's agent records.
///
/// The rule, kept simple on purpose:
/// - A **lead** is the root of a delegation tree (no parent, or its parent is
///   gone) that has delegated helpers right now. Only a root can lead, so a pack
///   has exactly one lead: a helper that delegates further is still a helper.
/// - A **helper** is a lead's direct child. Its place in the pack is its
///   delegation ordinal (`AgentRecord.parentRelativeOrdinal`), which is assigned
///   at spawn, persisted, and never reused when a sibling is archived, so a
///   helper keeps its character across relaunches and archives.
/// - A helper's own helpers (depth 2 and below) keep the hashed pick: they have
///   no stable place in the lead's sequence, and inventing one would reshuffle
///   characters as the tree grows.
public enum AgentCharacterPacks {
    public struct Member: Equatable, Sendable {
        public let id: UUID
        public let parentID: UUID?
        /// 1-based delegation ordinal under the parent; nil for legacy records.
        public let ordinal: Int?
        /// The agent's manual pick (`AgentRecord.characterName`).
        public let characterName: String?

        public init(id: UUID, parentID: UUID?, ordinal: Int?, characterName: String?) {
            self.id = id
            self.parentID = parentID
            self.ordinal = ordinal
            self.characterName = characterName
        }
    }

    public enum Role: Equatable, Sendable {
        case lead(helpers: Int)
        /// `slot` is 0-based delegation order; the lead's pick decides where a
        /// set with no lead art starts counting.
        case helper(slot: Int, lead: UUID, leadCharacterName: String?)
    }

    public static func roles(_ members: [Member]) -> [UUID: Role] {
        let byID = Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func isRoot(_ member: Member) -> Bool { member.parentID.map { byID[$0] == nil } ?? true }
        var roles: [UUID: Role] = [:]
        var helpers: [UUID: Int] = [:]
        for member in members {
            guard let parentID = member.parentID, let lead = byID[parentID], isRoot(lead) else { continue }
            helpers[parentID, default: 0] += 1
            if let ordinal = member.ordinal, ordinal >= 1 {
                roles[member.id] = .helper(slot: ordinal - 1, lead: parentID, leadCharacterName: lead.characterName)
            }
        }
        for (lead, count) in helpers { roles[lead] = .lead(helpers: count) }
        return roles
    }
}

/// The character one agent draws: a fact the host computes from its records and
/// ships to a guest, which draws it as given and never re-derives it.
public struct AgentCharacterAssignment: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// `index` is into the set's characters.
        case helper
        /// `index` is the power level, into the set's `leadSet` characters.
        case lead
    }

    public let kind: Kind
    public let index: Int

    public init(kind: Kind, index: Int) {
        self.kind = kind
        self.index = index
    }

    /// The precedence: a manual pick the set has, then lead art for a lead (when
    /// the set has some), then the helper's place in its lead's pack, then the hash.
    ///
    /// Helpers take the set's characters in delegation order and wrap only once
    /// they run out. In a set with no lead art the lead keeps a helper character,
    /// so its helpers start just after it and the lead is never doubled before the
    /// set is exhausted.
    public static func resolve(agentID: UUID, name: String?, role: AgentCharacterPacks.Role?,
                               theme: AgentCharacterTheme) -> AgentCharacterAssignment? {
        let count = theme.characters.count
        guard count > 0 else { return nil }
        func named(_ name: String?) -> Int? {
            guard let name else { return nil }
            return theme.characters.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        if let index = named(name) { return .init(kind: .helper, index: index) }
        switch role {
        case let .lead(helpers)?:
            if let levels = theme.leadSet?.characters.count, helpers > 0 {
                return .init(kind: .lead, index: min(helpers, levels) - 1)
            }
        case let .helper(slot, lead, leadName)?:
            if theme.hasLead { return .init(kind: .helper, index: slot % count) }
            let leadIndex = named(leadName) ?? AgentCharacterConfig.characterIndex(for: lead, count: count)
            return .init(kind: .helper, index: (leadIndex + 1 + slot) % count)
        case nil:
            break
        }
        return .init(kind: .helper, index: AgentCharacterConfig.characterIndex(for: agentID, count: count))
    }
}

/// Sets the person imported: each a copy of one theme file in
/// `<app support>/characters/<id>/theme.json`. Read only, never redistributed,
/// and never written back to where it came from.
public enum AgentCharacterImports {
    public static let fileName = "theme.json"
    /// The format's per-folder file name and the file suffix a theme folder holds.
    public static let folderThemeName = "duckherd-theme.json"
    public static let themeSuffix = ".theme.json"
    /// The format reads at most this many candidate files from one folder.
    public static let maximumCandidates = 40

    /// One file in the user themes folder: its theme, or why not.
    public struct UserThemeFile: Equatable, Sendable {
        public let url: URL
        public let result: Result<AgentCharacterTheme, AgentCharacterThemeProblems>
    }

    /// Every theme file in the user themes folder, sorted by path: imported copies
    /// (`<id>/theme.json`) and files written straight into it (`*.theme.json`),
    /// the way an agent making a set saves one. Each is judged as the validator
    /// judges it; a bad one, or one taking a built-in set's id, carries its problems.
    public static func scan(_ directory: URL) -> [UserThemeFile] {
        let fm = FileManager.default
        var files: [URL] = []
        for name in ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).sorted() where !name.hasPrefix(".") {
            let url = directory.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            if isFolder.boolValue {
                let copy = url.appendingPathComponent(fileName)
                if fm.fileExists(atPath: copy.path) { files.append(copy) }
            } else if name.hasSuffix(themeSuffix) {
                files.append(url)
            }
        }
        return files.prefix(maximumCandidates * 2).map { url in
            guard let data = try? Data(contentsOf: url) else {
                return UserThemeFile(url: url, result: .failure(.init(messages: ["the file could not be read"])))
            }
            return UserThemeFile(url: url, result: AgentCharacterValidator.validate(data: data))
        }
    }

    /// The valid sets in the folder, one per id (the first file by path wins),
    /// never a built-in id.
    public static func themes(in scan: [UserThemeFile]) -> [AgentCharacterTheme] {
        var seen = Set<String>(AgentCharacterBundled.builtInIDs)
        return scan.compactMap { file in
            guard case let .success(theme) = file.result, seen.insert(theme.id).inserted else { return nil }
            return theme
        }
    }

    public static func load(id: String, in directory: URL) -> AgentCharacterTheme? {
        themes(in: scan(directory)).first { $0.id == id }
    }

    /// Every user set, by title.
    public static func list(in directory: URL) -> [AgentCharacterTheme] {
        themes(in: scan(directory)).sorted { $0.title < $1.title }
    }

    public enum ImportResult: Equatable, Sendable {
        /// `audio`: the set's voices and sounds copied beside it, and those left out.
        case imported(AgentCharacterTheme, audio: AgentCharacterAudioImport.Report)
        /// The file is not a valid theme: its first problems, each saying where.
        case invalid(file: URL, problems: [String])
        case unreadable(file: URL, reason: String)
    }

    /// Validate `file` and copy it into `directory/<id>/theme.json`, with the
    /// audio its `voices` and `sounds` name from beside it (within caps; see
    /// `AgentCharacterAudioImport`). Nothing is written when the file has a problem.
    public static func importTheme(
        from file: URL, into directory: URL,
        audioDuration: (URL) -> TimeInterval? = AgentCharacterAudioImport.decodedDuration
    ) -> ImportResult {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= AgentCharacterThemeParser.maximumFileBytes else {
            return .invalid(file: file, problems: ["the file is over 3 MB"])
        }
        guard let data = try? Data(contentsOf: file) else {
            return .unreadable(file: file, reason: "Array could not read this file.")
        }
        switch AgentCharacterThemeParser.parse(data: data) {
        case let .failure(problems):
            return .invalid(file: file, problems: problems.messages)
        case let .success(theme):
            guard !AgentCharacterBundled.isBuiltIn(theme.id) else {
                return .invalid(file: file, problems: ["\"id\" \(theme.id) is a built-in set's; give the set its own id"])
            }
            let folder = directory.appendingPathComponent(theme.id, isDirectory: true)
            let source = file.deletingLastPathComponent()
            // Re-importing Array's own copy keeps the audio already beside it.
            let reimport = source.standardizedFileURL.resolvingSymlinksInPath()
                == folder.standardizedFileURL.resolvingSymlinksInPath()
            do {
                if !reimport, FileManager.default.fileExists(atPath: folder.path) {
                    try FileManager.default.removeItem(at: folder)
                }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: folder.appendingPathComponent(fileName), options: .atomic)
            } catch {
                return .unreadable(file: file, reason: "Array could not save its copy: \(error.localizedDescription)")
            }
            let voices = AgentCharacterVoices.parse(themeData: data)
            var audio = reimport ? AgentCharacterAudioImport.Report()
                : AgentCharacterAudioImport.copy(voices, from: source, to: folder, duration: audioDuration)
            audio.dropped = voices.problems.map {
                (file: $0, reason: "not a .wav or .mp3 path inside the set's folder")
            } + audio.dropped
            return .imported(theme, audio: audio)
        }
    }

    /// Import every candidate in a folder (scanned the way the format scans its
    /// themes folder), or the file itself.
    public static func importAll(
        from url: URL, into directory: URL,
        audioDuration: (URL) -> TimeInterval? = AgentCharacterAudioImport.decodedDuration
    ) -> [ImportResult] {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
            return [.unreadable(file: url, reason: "The file is gone.")]
        }
        guard isFolder.boolValue else { return [importTheme(from: url, into: directory, audioDuration: audioDuration)] }
        return candidates(inFolder: url).map { importTheme(from: $0, into: directory, audioDuration: audioDuration) }
    }

    /// Remove a user set: its imported copy's folder, or the file it was written as.
    public static func remove(id: String, from directory: URL) {
        guard AgentCharacterThemeParser.isThemeID(id) else { return }
        for file in scan(directory) {
            guard case let .success(theme) = file.result, theme.id == id else { continue }
            let target = file.url.lastPathComponent == fileName ? file.url.deletingLastPathComponent() : file.url
            try? FileManager.default.removeItem(at: target)
        }
    }

    /// `<folder>/*.theme.json` and `<folder>/<sub>/duckherd-theme.json`, sorted,
    /// at most 40. Lists names only; nothing is read.
    public static func candidates(inFolder folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var out: [URL] = []
        for name in names.sorted() {
            let url = folder.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            if isFolder.boolValue {
                let nested = url.appendingPathComponent(folderThemeName)
                if FileManager.default.fileExists(atPath: nested.path) { out.append(nested) }
            } else if name.hasSuffix(themeSuffix) {
                out.append(url)
            }
        }
        return Array(out.prefix(maximumCandidates))
    }

    /// The Claude Code plugin a found theme file came with: its manifest's name
    /// and version, or, without a manifest, its `name@marketplace` key's name.
    public struct PluginSource: Equatable, Sendable {
        public let name: String
        public let version: String?
        public var label: String { version.map { "\(name) \($0)" } ?? name }
    }

    /// A theme file a plugin points at, and that plugin.
    public struct FoundFile: Equatable, Sendable {
        public let url: URL
        public let source: PluginSource?
    }

    /// Theme files Claude Code's plugins point at, found on this Mac WITHOUT
    /// reading any theme: the `themesDir` a plugin's settings name in
    /// `<home>/.claude/settings.json` (`pluginConfigs`), and the theme file at the
    /// root of each installed plugin (`installed_plugins.json`), each with the
    /// plugin it came with. `home` is passed in so a check can point it at a
    /// fixture, never at the real one.
    public static func discover(home: URL) -> [FoundFile] {
        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        var installs: [(key: String, path: URL, source: PluginSource)] = []
        if let data = try? Data(contentsOf: claude.appendingPathComponent("plugins/installed_plugins.json")),
           let installed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let plugins = installed["plugins"] as? [String: Any] {
            for key in plugins.keys.sorted() {
                for entry in (plugins[key] as? [[String: Any]]) ?? [] {
                    guard let path = entry["installPath"] as? String, !path.isEmpty else { continue }
                    let root = URL(fileURLWithPath: path, isDirectory: true)
                    installs.append((key, root, pluginSource(key: key, root: root, version: entry["version"] as? String)))
                }
            }
        }
        var found: [FoundFile] = []
        if let data = try? Data(contentsOf: claude.appendingPathComponent("settings.json")),
           let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let configs = settings["pluginConfigs"] as? [String: Any] {
            for key in configs.keys.sorted() {
                guard let config = configs[key] as? [String: Any] else { continue }
                // A plugin's settings may sit directly or under an `options` object.
                let raw = (config["themesDir"] as? String) ?? ((config["options"] as? [String: Any])?["themesDir"] as? String)
                guard let raw, !raw.isEmpty else { continue }
                let path = raw.hasPrefix("~/") ? home.appendingPathComponent(String(raw.dropFirst(2))).path : raw
                let source = installs.first { $0.key == key }?.source ?? pluginSource(key: key, root: nil, version: nil)
                found += candidates(inFolder: URL(fileURLWithPath: path, isDirectory: true))
                    .map { FoundFile(url: $0, source: source) }
            }
        }
        for install in installs {
            let file = install.path.appendingPathComponent(folderThemeName)
            if FileManager.default.fileExists(atPath: file.path) { found.append(FoundFile(url: file, source: install.source)) }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
    }

    /// `<root>/.claude-plugin/plugin.json`'s name and version, else the key's.
    static func pluginSource(key: String, root: URL?, version: String?) -> PluginSource {
        let fallback = String(key.split(separator: "@").first ?? Substring(key))
        guard let root,
              let data = try? Data(contentsOf: root.appendingPathComponent(".claude-plugin/plugin.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return PluginSource(name: fallback, version: version)
        }
        let name = (manifest["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        return PluginSource(name: name, version: (manifest["version"] as? String) ?? version)
    }

    /// One row of "Found on this Mac": a theme's bytes, wherever they sit.
    public struct FoundTheme: Equatable, Sendable {
        public enum State: Equatable, Sendable {
            /// Not imported: Import.
            case new
            /// Byte-identical to an imported set: nothing to do.
            case imported
            /// Its id is imported with other content: Update replaces that copy.
            case update
            /// Not a valid set: the validator's first problem.
            case invalid(String)
        }

        /// The first path holding these bytes, and every path that does.
        public let url: URL
        public let paths: [URL]
        public let source: PluginSource?
        /// SHA-256 of the file's bytes, hex.
        public let hash: String
        /// The file's own title, else its id, else its file name.
        public let title: String
        public let theme: AgentCharacterTheme?
        public let state: State

        /// "Lead + 16 helpers · from pond-pals 1.2.0".
        public var detail: String {
            var parts: [String] = []
            if let theme {
                let helpers = theme.characters.count
                parts.append(theme.hasLead
                    ? "Lead + \(helpers) helper\(helpers == 1 ? "" : "s")"
                    : AgentCharacterCopy.count(helpers))
            }
            if let source { parts.append("from \(source.label)") }
            return parts.joined(separator: " · ")
        }
    }

    /// Read, validate and hash each found file, one row per distinct content (the
    /// first path wins), each stated against what `importsDirectory` holds:
    /// byte-identical there is `imported`, the same id with other bytes is
    /// `update`. Theme files are read here, never written.
    public static func describe(_ found: [FoundFile], importsDirectory: URL) -> [FoundTheme] {
        var importedHashes = Set<String>()
        var importedIDs = Set<String>()
        for file in scan(importsDirectory) {
            guard let data = try? Data(contentsOf: file.url) else { continue }
            importedHashes.insert(sha256(data))
            if case let .success(theme) = file.result { importedIDs.insert(theme.id) }
        }
        var rows: [FoundTheme] = []
        var index: [String: Int] = [:]
        for file in found {
            let size = (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber)?.intValue ?? 0
            let data = size > AgentCharacterThemeParser.maximumFileBytes ? nil : try? Data(contentsOf: file.url)
            let hash = data.map(sha256) ?? "unreadable:" + file.url.path
            if let at = index[hash] {
                let row = rows[at]
                rows[at] = FoundTheme(url: row.url, paths: row.paths + [file.url], source: row.source, hash: hash,
                                      title: row.title, theme: row.theme, state: row.state)
                continue
            }
            let result: Result<AgentCharacterTheme, AgentCharacterThemeProblems> = data.map { validated($0, hash: hash) }
                ?? .failure(.init(messages: [size > AgentCharacterThemeParser.maximumFileBytes
                    ? AgentCharacterValidator.oversizedProblem : "the file could not be read"]))
            let row: FoundTheme
            switch result {
            case let .success(theme):
                let state: FoundTheme.State = importedHashes.contains(hash) ? .imported
                    : importedIDs.contains(theme.id) ? .update : .new
                row = FoundTheme(url: file.url, paths: [file.url], source: file.source, hash: hash,
                                 title: theme.title, theme: theme, state: state)
            case let .failure(problems):
                row = FoundTheme(url: file.url, paths: [file.url], source: file.source, hash: hash,
                                 title: rawTitle(data, file: file), theme: nil,
                                 state: .invalid(problems.messages.first ?? "not \(AgentCharacterCopy.aPack)"))
            }
            index[hash] = rows.count
            rows.append(row)
        }
        return rows
    }

    /// An invalid file's name for itself: its "title", else its "id", else its
    /// file name. The format's fixed per-folder name is another product's, so a
    /// file with that name is called by its plugin instead.
    static func rawTitle(_ data: Data?, file: FoundFile) -> String {
        let raw = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        for key in ["title", "id"] {
            if let text = (raw?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text
            }
        }
        if file.url.lastPathComponent == folderThemeName {
            return file.source?.name ?? file.url.deletingLastPathComponent().lastPathComponent
        }
        return file.url.lastPathComponent
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Validation by content: Settings rebuilds its model on every settings
    /// change, and a shipped set is a few MB of frames, so one parse per distinct
    /// file content is kept.
    private static let parseLock = NSLock()
    nonisolated(unsafe) private static var parsed: [String: Result<AgentCharacterTheme, AgentCharacterThemeProblems>] = [:]

    static func validated(_ data: Data, hash: String) -> Result<AgentCharacterTheme, AgentCharacterThemeProblems> {
        parseLock.lock()
        let cached = parsed[hash]
        parseLock.unlock()
        if let cached { return cached }
        let result = AgentCharacterValidator.validate(data: data)
        parseLock.lock()
        if parsed.count >= 32 { parsed.removeAll() }
        parsed[hash] = result
        parseLock.unlock()
        return result
    }
}

/// The validator agents call while making a set:
/// `Array --validate-agent-character-theme <file or folder>`. Prints one JSON
/// report and exits 0 when every file is a valid set, 1 when any is not.
public enum AgentCharacterValidator {
    public static let flag = "--validate-agent-character-theme"

    static let oversizedProblem = "the file is over 3 MB"

    /// What makes a set that parses still not a user set: today, only taking
    /// a built-in set's id.
    static func problems(of theme: AgentCharacterTheme) -> [String] {
        AgentCharacterBundled.isBuiltIn(theme.id)
            ? ["\"id\" \(theme.id) is a built-in set's; give your set its own id"] : []
    }

    /// One theme file's bytes, judged exactly as the report judges a file: the
    /// size limit, the parser, then the user-set rules. A shared agent's guest
    /// validates the host's set with this before drawing it.
    public static func validate(data: Data) -> Result<AgentCharacterTheme, AgentCharacterThemeProblems> {
        guard data.count <= AgentCharacterThemeParser.maximumFileBytes else {
            return .failure(.init(messages: [oversizedProblem]))
        }
        switch AgentCharacterThemeParser.parse(data: data) {
        case let .success(theme):
            let problems = problems(of: theme)
            return problems.isEmpty ? .success(theme) : .failure(.init(messages: problems))
        case let .failure(problems):
            return .failure(problems)
        }
    }

    /// The report for `paths` (files, or folders scanned like the themes folder).
    public static func report(paths: [String], themesFolder: URL) -> (json: String, valid: Bool) {
        var entries: [[String: Any]] = []
        var allValid = !paths.isEmpty
        for path in paths {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
                entries.append(["file": url.path, "valid": false, "problems": ["no such file"]])
                allValid = false
                continue
            }
            let files = isFolder.boolValue ? AgentCharacterImports.scan(url).map(\.url) : [url]
            if files.isEmpty {
                entries.append(["file": url.path, "valid": false,
                                "problems": ["no *.theme.json or <id>/theme.json files in this folder"]])
                allValid = false
            }
            for file in files {
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
                let result: Result<AgentCharacterTheme, AgentCharacterThemeProblems> =
                    size > AgentCharacterThemeParser.maximumFileBytes
                    ? .failure(.init(messages: [Self.oversizedProblem]))
                    : (try? Data(contentsOf: file)).map(AgentCharacterThemeParser.parse(data:))
                        ?? .failure(.init(messages: ["the file could not be read"]))
                switch result {
                case let .success(theme):
                    let problems = Self.problems(of: theme)
                    entries.append([
                        "file": file.path, "valid": problems.isEmpty, "id": theme.id, "title": theme.title,
                        "scale": theme.scale, "frameSize": [theme.frameWidth, theme.frameHeight],
                        "characters": theme.characters.map { character -> [String: Any] in
                            let frames = AgentCharacterLoop.allCases.reduce(0) { $0 + character.frames(of: $1).count }
                                + 2 + AgentCharacterClip.allCases.reduce(0) { $0 + (character.clips[$1]?.count ?? 0) }
                            return ["name": character.name, "frames": frames]
                        },
                        "problems": problems,
                    ])
                    if !problems.isEmpty { allValid = false }
                case let .failure(problems):
                    entries.append(["file": file.path, "valid": false, "problems": problems.messages])
                    allValid = false
                }
            }
        }
        let object: [String: Any] = [
            "valid": allValid, "themesFolder": themesFolder.path, "files": entries,
            "note": "Array shows a valid set from the themes folder as soon as it is saved there. Problems list at most the first 8, each saying where.",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return (String(decoding: data, as: UTF8.self), allValid)
    }
}
