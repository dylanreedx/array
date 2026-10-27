import Foundation

/// Sessions from other apps the user hid from the sidebar.
///
/// Keyed by `ExternalAgentSession.id` (the provider-qualified session id), never
/// by pid, so a hidden session stays hidden across a resume in a new process.
/// Stored in the app's own defaults domain, which the channel split already
/// separates; never in a project's `.array/`.
///
/// A hidden session stays hidden while it is live. One the discovery has not
/// reported for `forgetAfter` is forgotten, so the set does not grow forever.
@MainActor
public final class ExternalSessionHiding {
    public struct Entry: Codable, Equatable, Sendable {
        public var sessionKey: String
        /// The row's title when it was hidden, for the "Hidden" list.
        public var title: String
        public var hiddenAt: Date
        public var lastSeen: Date
    }

    public static let defaultsKey = "continuum.sidebar.hiddenExternalSessions"
    public static let forgetAfter: TimeInterval = 24 * 3600

    private let defaults: UserDefaults
    public private(set) var entries: [Entry]

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        entries = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    public var hiddenKeys: Set<String> { Set(entries.map(\.sessionKey)) }

    public func isHidden(_ sessionKey: String) -> Bool {
        entries.contains { $0.sessionKey == sessionKey }
    }

    public func hide(_ sessions: [(key: String, title: String)], now: Date = Date()) {
        for session in sessions where !isHidden(session.key) {
            entries.append(Entry(sessionKey: session.key, title: session.title, hiddenAt: now, lastSeen: now))
        }
        save()
    }

    public func show(_ keys: Set<String>) {
        entries.removeAll { keys.contains($0.sessionKey) }
        save()
    }

    public func showAll() {
        entries.removeAll()
        save()
    }

    /// Record which sessions discovery reports now, and forget hidden ones it has
    /// not reported for `forgetAfter`. `present` empty means discovery has not
    /// run (or found nothing) and proves nothing ended, so nothing is forgotten.
    public func noteDiscovered(_ present: Set<String>, now: Date = Date()) {
        guard !present.isEmpty else { return }
        let before = entries
        for index in entries.indices where present.contains(entries[index].sessionKey) {
            entries[index].lastSeen = now
        }
        entries.removeAll { now.timeIntervalSince($0.lastSeen) > Self.forgetAfter }
        if entries != before { save() }
    }

    private func save() {
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
