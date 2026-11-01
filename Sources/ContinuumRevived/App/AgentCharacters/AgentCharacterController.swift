import AppKit
import ContinuumRevivedAgentUI
import ContinuumRevivedCore

// Plan: .plans/110-agent-characters/README.md
/// One character's atlas as an image every sprite of that character shares.
///
/// A class so a sprite can tell "the same picture" by identity: the render server
/// uploads one `CGImage` once, however many layers point at it.
final class AgentCharacterSpriteAtlas {
    let atlas: AgentCharacterAtlas
    let image: CGImage
    /// Seconds per frame of each loop, at the theme's own pace, never faster than 12 fps.
    let loopFrameDuration: [AgentCharacterLoop: CFTimeInterval]

    init?(theme: AgentCharacterTheme, character: Int, appearance: AgentCharacterAtlas.Appearance) {
        let atlas = AgentCharacterAtlas(theme: theme, character: character, appearance: appearance)
        let data = Data(atlas.pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: atlas.width, height: atlas.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: atlas.width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        self.atlas = atlas
        self.image = image
        var durations: [AgentCharacterLoop: CFTimeInterval] = [:]
        let loops = theme.characters[character].loops
        for loop in AgentCharacterLoop.allCases {
            durations[loop] = max(Self.minimumFrameDuration, (loops[loop]?.frameMs ?? 300) / 1000)
        }
        loopFrameDuration = durations
    }

    /// 12 fps: the fastest any character steps (plan 110 §5.2 rule 6).
    static let minimumFrameDuration: CFTimeInterval = 1.0 / 12
}

/// A surface whose character may change with time alone.
@MainActor
protocol AgentCharacterRevisiting: AnyObject {
    func revisitCharacter(now: Date)
}

/// The app's one owner of agent characters: whether they show, which set, how
/// they move, and each character's atlas, built once and shared.
@MainActor
final class AgentCharacterController {
    static let shared = AgentCharacterController()
    /// Posted when characters turn on or off, the set changes, or motion changes.
    /// Surfaces re-apply their sprites; nothing per frame listens.
    static let didChangeNotification = Notification.Name("array.agentCharacters.changed")

    private(set) var defaults: UserDefaults = .standard
    private(set) var isEnabled = false
    private(set) var motion = AgentCharacterConfig.defaultMotion
    private(set) var theme: AgentCharacterTheme?
    /// Where imported sets are copied (`<app support>/characters`). Injected by checks.
    var importsDirectory: URL = WorkspaceStore.defaultApplicationSupportDirectory()
        .appendingPathComponent("characters", isDirectory: true)
    /// The system's Reduce Motion, injectable so a check can drive both branches.
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Whether a window's characters may move: on the active space, not fully
    /// covered, and the app not hidden. Injectable because an offscreen check
    /// window is never `.visible`.
    var windowIsVisible: (NSWindow) -> Bool = { window in
        window.occlusionState.contains(.visible) && !NSApp.isHidden
    }
    /// Posted when a window's occlusion or the app's hidden state changes:
    /// surfaces re-check whether their sprites may move. Never per frame.
    static let visibilityDidChangeNotification = Notification.Name("array.agentCharacters.visibility")

    private struct AtlasKey: Hashable {
        let themeID: String
        let character: Int
        let appearance: AgentCharacterAtlas.Appearance
    }
    private var atlases: [AtlasKey: AgentCharacterSpriteAtlas] = [:]
    private var observers: [NSObjectProtocol] = []
    /// How many atlases have been built: a witness that sprites share them.
    private(set) var atlasBuilds = 0

    /// Read the settings and keep following them.
    func adopt(defaults: UserDefaults) {
        self.defaults = defaults
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = [AgentCharacterConfig.enabledKey, AgentCharacterConfig.motionKey, AgentCharacterConfig.themeKey].map { key in
            NotificationCenter.default.addObserver(
                forName: SettingChangeEvent.name(for: SettingID(rawValue: key)), object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { AgentCharacterController.shared.reload() } }
        }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard AgentCharacterController.shared.isEnabled else { return }
                    NotificationCenter.default.post(name: AgentCharacterController.visibilityDidChangeNotification, object: nil)
                }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { AgentCharacterController.shared.reload(force: true) } })
        reload(force: true)
    }

    /// Re-read the settings; post a change only when something a sprite shows changed.
    func reload(force: Bool = false) {
        let enabled = AgentCharacterConfig.isEnabled(defaults)
        let motion = AgentCharacterConfig.motion(defaults)
        let selected = defaults.string(forKey: AgentCharacterConfig.themeKey)
        // Off means nothing resident: no theme, no atlases.
        let theme = enabled ? resolveTheme(id: selected) : nil
        let changed = force || enabled != isEnabled || motion != self.motion || theme?.id != self.theme?.id
        if theme?.id != self.theme?.id || theme == nil { atlases.removeAll() }
        isEnabled = enabled
        self.motion = motion
        self.theme = theme
        if changed { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }
    }

    /// The selected set: an imported one by id, else the built-in ducks.
    private func resolveTheme(id: String?) -> AgentCharacterTheme? {
        if let id, id != AgentCharacterBundled.themeID,
           let imported = AgentCharacterImports.load(id: id, in: importsDirectory) {
            return imported
        }
        return AgentCharacterBundled.theme()
    }

    /// Whether characters may move now: the motion setting and the system's Reduce Motion.
    var allowsMotion: Bool { motion == .working && !reduceMotion() }

    /// Where in its loop `agentID`'s character is (0..<1).
    func phase(for agentID: UUID) -> Double { AgentCharacterConfig.phase(for: agentID) }

    /// `agentID`'s character in the shown set: the one named `name` when the
    /// set has it (case-insensitive), else the pick hashed from the id.
    func characterIndex(for agentID: UUID, name: String? = nil) -> Int? {
        guard let theme, !theme.characters.isEmpty else { return nil }
        if let name, let index = Self.index(of: name, in: theme) { return index }
        return AgentCharacterConfig.characterIndex(for: agentID, count: theme.characters.count)
    }

    static func index(of name: String, in theme: AgentCharacterTheme) -> Int? {
        theme.characters.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The selected set, whether or not characters are showing: what a per-agent
    /// pick is chosen from and validated against.
    var selectedTheme: AgentCharacterTheme? { theme ?? resolveTheme(id: defaults.string(forKey: AgentCharacterConfig.themeKey)) }

    /// The shared atlas for `agentID`'s character in `appearance`; nil when off.
    func atlas(for agentID: UUID, appearance: AgentCharacterAtlas.Appearance, name: String? = nil) -> AgentCharacterSpriteAtlas? {
        guard isEnabled, let theme, let index = characterIndex(for: agentID, name: name) else { return nil }
        return atlas(theme: theme, character: index, appearance: appearance)
    }

    func atlas(theme: AgentCharacterTheme, character: Int, appearance: AgentCharacterAtlas.Appearance) -> AgentCharacterSpriteAtlas? {
        let key = AtlasKey(themeID: theme.id, character: character, appearance: appearance)
        if let built = atlases[key] { return built }
        guard let built = AgentCharacterSpriteAtlas(theme: theme, character: character, appearance: appearance) else { return nil }
        atlasBuilds += 1
        // Only the selected set's atlases are kept; a preview of another set is not.
        if theme.id == self.theme?.id { atlases[key] = built }
        return built
    }

    /// The plan for one agent now, honouring motion settings.
    func plan(for snapshot: AgentCharacterSnapshot, now: Date) -> AgentCharacterPlan {
        var snapshot = snapshot
        snapshot.allowsMotion = snapshot.allowsMotion && allowsMotion
        return AgentCharacterPose.resolve(snapshot, now: now)
    }

    // MARK: Time alone (slowing at 40 s, dozing at 180 s)

    /// One shared one-shot timer for every surface whose plan changes by time
    /// alone, set for the earliest deadline. Not a timer per sprite and nothing per
    /// frame: it fires at most twice per quiet spell per agent.
    private final class Revisit {
        weak var owner: AgentCharacterRevisiting?
        var at: Date
        init(owner: AgentCharacterRevisiting, at: Date) { self.owner = owner; self.at = at }
    }
    private var revisits: [ObjectIdentifier: Revisit] = [:]
    private var revisitTimer: Timer?
    private var revisitFireAt: Date?
    var pendingRevisitsForQA: Int { revisits.count }

    func scheduleRevisit(for owner: AgentCharacterRevisiting, at date: Date?) {
        let key = ObjectIdentifier(owner)
        guard let date else { revisits[key] = nil; return }
        if let existing = revisits[key] { existing.at = date } else { revisits[key] = Revisit(owner: owner, at: date) }
        if revisitFireAt.map({ date < $0 }) ?? true { armRevisitTimer(at: date) }
    }

    private func armRevisitTimer(at date: Date) {
        revisitTimer?.invalidate()
        revisitFireAt = date
        let timer = Timer(fire: date, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { AgentCharacterController.shared.fireRevisits() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        revisitTimer = timer
    }

    func fireRevisits(now: Date = Date()) {
        revisitTimer = nil
        revisitFireAt = nil
        var due: [AgentCharacterRevisiting] = []
        for (key, entry) in revisits {
            guard let owner = entry.owner else { revisits[key] = nil; continue }
            if entry.at <= now.addingTimeInterval(0.5) {
                revisits[key] = nil
                due.append(owner)
            }
        }
        // Each owner re-resolves and schedules its next deadline, if any.
        for owner in due { owner.revisitCharacter(now: now) }
        if let next = revisits.values.map(\.at).min() { armRevisitTimer(at: next) }
    }

    static func appearance(of view: NSView) -> AgentCharacterAtlas.Appearance {
        view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}
