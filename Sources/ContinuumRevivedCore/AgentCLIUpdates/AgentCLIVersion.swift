import Foundation

/// A CLI's version as it prints it, ordered the way semver orders releases.
///
/// `claude --version` prints `2.1.302 (Claude Code)`, `codex --version` prints
/// `codex-cli 0.159.3`, `pi --version` prints `0.85.0`. `parse(versionOutput:)`
/// takes the first dotted-triple token from any of them, so a CLI that changes
/// its banner keeps working while one that stops printing a version reads as
/// "unknown" rather than as a made-up number.
public struct AgentCLIVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let text: String
    private let numbers: [Int]
    private let prerelease: String?

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Self.firstMatch(in: trimmed), parsed.text == trimmed else { return nil }
        self = parsed
    }

    private init(text: String, numbers: [Int], prerelease: String?) {
        self.text = text
        self.numbers = numbers
        self.prerelease = prerelease
    }

    public var description: String { text }

    /// The first `x.y.z[-pre]` token in a `--version` banner, or nil.
    public static func parse(versionOutput: String) -> String? {
        firstMatch(in: versionOutput)?.text
    }

    /// True when `candidate` is a strictly later release than `installed`.
    /// Unparseable input is never "newer": no button appears on a guess.
    public static func isNewer(_ candidate: String?, than installed: String?) -> Bool {
        guard let candidate = candidate.flatMap(AgentCLIVersion.init),
              let installed = installed.flatMap(AgentCLIVersion.init) else { return false }
        return candidate > installed
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<![0-9.])(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z][0-9A-Za-z.-]*))?"#)

    private static func firstMatch(in text: String) -> AgentCLIVersion? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range),
              let whole = Range(match.range, in: text) else { return nil }
        var numbers: [Int] = []
        for index in 1...3 {
            guard let part = Range(match.range(at: index), in: text), let value = Int(text[part]) else { return nil }
            numbers.append(value)
        }
        let prerelease = Range(match.range(at: 4), in: text).map { String(text[$0]) }
        return AgentCLIVersion(text: String(text[whole]), numbers: numbers, prerelease: prerelease)
    }

    public static func < (lhs: AgentCLIVersion, rhs: AgentCLIVersion) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _?): return false
        case (_?, nil): return true
        case let (left?, right?): return left.compare(right, options: .numeric) == .orderedAscending
        }
    }

    public static func == (lhs: AgentCLIVersion, rhs: AgentCLIVersion) -> Bool {
        lhs.numbers == rhs.numbers && lhs.prerelease == rhs.prerelease
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(numbers)
        hasher.combine(prerelease)
    }
}

/// The CLI versions the repo's recorded fixtures were captured against
/// (`Sources/ContinuumRevivedCoreChecks/Fixtures/context-meter/*.meta.json`),
/// shipped as `TestedCLIVersions.json` in the Core resource bundle. Advisory:
/// the version-change notice appends "· tested with X", nothing ever blocks on
/// it. `--cli-install-owner-check` holds the file to the fixtures.
public enum AgentCLITestedVersions {
    public static let resourceName = "TestedCLIVersions.json"

    public static func decode(_ data: Data) -> [AgentHarness: String] {
        guard let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        var result: [AgentHarness: String] = [:]
        for harness in AgentHarness.allCases {
            if let version = raw[harness.rawValue], AgentCLIVersion(version) != nil { result[harness] = version }
        }
        return result
    }

    /// Same lookup as `AgentContextWindowResolver.bundledWindows`: the app copies
    /// the Core bundle into Contents/Resources, a bare binary has it alongside.
    public static func bundled() -> [AgentHarness: String] {
        let name = "continuum-revived_ContinuumRevivedCore.bundle"
        let roots = [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent()].compactMap { $0 }
        for root in roots {
            let url = root.appendingPathComponent(name).appendingPathComponent(resourceName)
            if let data = try? Data(contentsOf: url) {
                let values = decode(data)
                if !values.isEmpty { return values }
            }
        }
        return [:]
    }
}
