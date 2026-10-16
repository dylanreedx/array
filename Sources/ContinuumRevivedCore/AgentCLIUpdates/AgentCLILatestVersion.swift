import Foundation

public enum AgentCLILatestLookup: Equatable, Sendable {
    case found(String)
    /// No answer: offline, timeout, a malformed body, a non-200.
    case notFound
    /// HTTP 429. `retryAfter` from the response when it said.
    case rateLimited(retryAfter: TimeInterval?)
}

/// Reads the newest published version for one source. Production hits the
/// network (npm registry, pi.dev) or the keg's brew; every check injects a fake.
public protocol AgentCLILatestVersionFetching: Sendable {
    func lookup(_ source: AgentCLILatestSource) async -> AgentCLILatestLookup
}

/// The vendors' own opt-outs, honoured before any lookup: Claude Code's
/// `DISABLE_AUTOUPDATER` (and the `DISABLE_UPDATES` spelling), pi's
/// `PI_OFFLINE` / `PI_SKIP_VERSION_CHECK`.
public enum AgentCLIUpdateOptOut {
    public static func isOptedOut(_ harness: AgentHarness, environment: [String: String]) -> Bool {
        func set(_ key: String) -> Bool {
            guard let value = environment[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return false }
            return !["0", "false", "no"].contains(value.lowercased())
        }
        switch harness {
        case .claudeCode: return set("DISABLE_AUTOUPDATER") || set("DISABLE_UPDATES")
        case .pi: return set("PI_OFFLINE") || set("PI_SKIP_VERSION_CHECK")
        case .codex: return false
        }
    }
}

/// Remembers lookups so checks stay cheap and polite: a hit for an hour, a
/// miss for a minute, a 429 for as long as the server asked (15 minutes when
/// it did not say).
public final class AgentCLILatestVersionCache: @unchecked Sendable {
    public static let hitLifetime: TimeInterval = 60 * 60
    public static let missLifetime: TimeInterval = 60
    public static let rateLimitedLifetime: TimeInterval = 15 * 60

    private struct Entry {
        let version: String?
        let expires: Date
        let rateLimited: Bool
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let fetcher: AgentCLILatestVersionFetching

    public init(fetcher: AgentCLILatestVersionFetching) {
        self.fetcher = fetcher
    }

    /// The newest version for `source`. `force` skips a fresh hit or miss (an
    /// explicit "Check for CLI Updates"), but never a rate limit.
    public func latest(for source: AgentCLILatestSource, now: Date = Date(), force: Bool = false) async -> String? {
        let key = source.cacheKey
        if let entry = lock.withLock({ entries[key] }), entry.expires > now, !force || entry.rateLimited {
            return entry.version
        }
        let lookup = await fetcher.lookup(source)
        let stored = lock.withLock { () -> String? in
            let previous = entries[key]?.version
            switch lookup {
            case let .found(version):
                entries[key] = Entry(version: version, expires: now.addingTimeInterval(Self.hitLifetime), rateLimited: false)
                return version
            case .notFound:
                entries[key] = Entry(version: previous, expires: now.addingTimeInterval(Self.missLifetime), rateLimited: false)
                return previous
            case let .rateLimited(retryAfter):
                let wait = max(Self.missLifetime, retryAfter ?? Self.rateLimitedLifetime)
                entries[key] = Entry(version: previous, expires: now.addingTimeInterval(wait), rateLimited: true)
                return previous
            }
        }
        return stored
    }
}

#if os(macOS)
/// The production fetcher. npm and pi.dev over HTTPS with a 4 s timeout and no
/// cookies or credentials; Homebrew through the keg's own `brew info`, with
/// auto-update off so a lookup never mutates the user's Homebrew.
public struct AgentCLILiveLatestVersionFetcher: AgentCLILatestVersionFetching {
    public init() {}

    public func lookup(_ source: AgentCLILatestSource) async -> AgentCLILatestLookup {
        switch source {
        case let .npm(package):
            let encoded = package.replacingOccurrences(of: "/", with: "%2F")
            guard let url = URL(string: "https://registry.npmjs.org/\(encoded)/latest") else { return .notFound }
            return await fetchVersionJSON(url)
        case .piRelease:
            guard let url = URL(string: "https://pi.dev/api/latest-version") else { return .notFound }
            return await fetchVersionJSON(url)
        case let .homebrew(brew, kind, name):
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    var environment = AgentCLIProcess.environment(for: brew)
                    environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
                    let argv = [brew, "info", "--json=v2"] + (kind == .cask ? ["--cask", name] : [name])
                    let outcome = AgentCLIProcess.run(argv: argv, environment: environment,
                                                      currentDirectory: FileManager.default.temporaryDirectory,
                                                      timeout: 10, outputLimit: 256 * 1024)
                    guard outcome.exitCode == 0,
                          let version = Self.parseHomebrewInfo(Data(outcome.output.utf8), kind: kind) else {
                        continuation.resume(returning: .notFound)
                        return
                    }
                    continuation.resume(returning: .found(version))
                }
            }
        }
    }

    private func fetchVersionJSON(_ url: URL) async -> AgentCLILatestLookup {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 4
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return .notFound }
        if http.statusCode == 429 {
            return .rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        }
        guard http.statusCode == 200 else { return .notFound }
        return Self.parseVersionJSON(data).map(AgentCLILatestLookup.found) ?? .notFound
    }

    /// `{"version": "…"}` — the npm registry's `/latest` document and pi.dev's answer.
    public static func parseVersionJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? String, AgentCLIVersion(version) != nil else { return nil }
        return version
    }

    /// `brew info --json=v2`: a formula's `versions.stable`; a cask's `version`
    /// up to the first comma (`1.2.3,456`).
    public static func parseHomebrewInfo(_ data: Data, kind: AgentCLIInstallOwner.HomebrewKind) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let raw: String?
        switch kind {
        case .formula:
            raw = ((object["formulae"] as? [[String: Any]])?.first?["versions"] as? [String: Any])?["stable"] as? String
        case .cask:
            raw = ((object["casks"] as? [[String: Any]])?.first?["version"] as? String)?
                .split(separator: ",", maxSplits: 1).first.map(String.init)
        }
        return raw.flatMap(AgentCLIVersion.parse(versionOutput:))
    }
}
#endif
