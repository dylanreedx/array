import Foundation

/// Witness that a check never writes or deletes chosen keys of the STANDARD
/// defaults domain — not even transiently.
///
/// Inside the PROD bundle (`check-app-bundle.sh --channel prod`) `.standard` is the
/// owner's real `dev.arrayapp.macos` domain, so a check that "saves, writes and
/// restores" still rewrites real preferences for the length of the run, and leaves
/// them rewritten when it dies first or races another run. A final before/after
/// comparison cannot see a write that was restored, so this observes EVERY
/// in-process defaults change (`didChangeNotification` is posted synchronously on
/// the writing thread) and compares the PERSISTENT domain each time. The argument
/// domain pin (`AgentCatalogQAFixture.pinAmbientSelection`) is volatile, never
/// reaches the persistent domain, and so never trips it.
public final class QAStandardDefaultsGuard {
    public static let agentSelectionKeys: Set<String> = [
        AgentHarnessConfig.key, AgentModelConfig.modelKey, AgentModelConfig.thinkingKey,
    ]

    private let defaults: UserDefaults
    private let domainName: String
    private let keys: Set<String>
    private let baseline: [String: String]
    private let lock = NSLock()
    private var divergences: [String] = []
    private var observer: NSObjectProtocol?

    /// `domainName` nil watches the standard domain; pass `UserDefaults.globalDomain`
    /// to watch the owner's global preferences instead.
    public init(keys: Set<String>, domainName: String? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.domainName = domainName ?? Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        self.keys = keys
        self.baseline = Self.snapshot(defaults, self.domainName, keys)
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.compare() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Stops observing and returns every key the persistent domain ever held at a
    /// value other than its baseline, with the first offending value seen.
    public func finish() -> [String] {
        compare()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        return lock.withLock { divergences }
    }

    private func compare() {
        let now = Self.snapshot(defaults, domainName, keys)
        lock.withLock {
            for key in keys.sorted() where now[key] != baseline[key] {
                let prefix = "\(domainName) \(key):"
                guard !divergences.contains(where: { $0.hasPrefix(prefix) }) else { continue }
                divergences.append("\(prefix) \(baseline[key] ?? "<absent>") -> \(now[key] ?? "<absent>")")
            }
        }
    }

    private static func snapshot(_ defaults: UserDefaults, _ domainName: String, _ keys: Set<String>) -> [String: String] {
        let domain = defaults.persistentDomain(forName: domainName) ?? [:]
        var values: [String: String] = [:]
        for key in keys { if let value = domain[key] { values[key] = String(describing: value) } }
        return values
    }
}

/// Pin preference values for a check, IN-PROCESS: the argument domain outranks
/// every persistent domain (and every suite) and is never written to disk, so the
/// owner's real domain — which is `.standard` inside the prod bundle — is never
/// touched. Returns the undo; undo in reverse order of pinning.
///
/// There is no in-process way to make a key ABSENT: a check that wants "never
/// configured" pins the key's default value instead. And because the pin shadows
/// every write, it is wrong for a key the code under test itself writes and reads
/// back — those need an injected suite.
public enum QADefaultsPin {
    public static func pin(_ values: [String: Any], defaults: UserDefaults = .standard) -> () -> Void {
        let prior = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(prior.merging(values) { _, pinned in pinned }, forName: UserDefaults.argumentDomain)
        return { defaults.setVolatileDomain(prior, forName: UserDefaults.argumentDomain) }
    }
}

/// A defaults suite that answers ONLY from its own persistent domain.
///
/// A plain `UserDefaults(suiteName:)` still searches the argument domain and
/// NSGlobalDomain, so a key the owner (or anything else) left in their global
/// preferences leaks into every "never configured" assertion. Checks used to scrub
/// such keys by rewriting the owner's whole global domain from a snapshot and
/// writing it back — every app's shared preferences, inside the prod bundle too.
/// Every typed getter (`string`, `bool`, `double`, …) routes through
/// `object(forKey:)`, so overriding it isolates them all; writes land in the suite.
public final class QAIsolatedDefaults: UserDefaults {
    public let suiteDomainName: String

    public init?(isolatedSuiteName name: String) {
        suiteDomainName = name
        super.init(suiteName: name)
    }

    public override func object(forKey defaultName: String) -> Any? {
        persistentDomain(forName: suiteDomainName)?[defaultName]
    }

    public override func dictionaryRepresentation() -> [String: Any] {
        persistentDomain(forName: suiteDomainName) ?? [:]
    }
}
