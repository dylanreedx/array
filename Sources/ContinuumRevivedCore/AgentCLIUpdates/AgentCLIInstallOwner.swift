import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Who installed the CLI binary Array actually spawns — decided from the binary's
/// REAL path (symlinks followed), never from what is first on PATH. The owner
/// decides the only update command Array may offer, after T3 Code's
/// `maintenanceResolver.ts`.
public enum AgentCLIInstallOwner: Equatable, Sendable {
    public enum HomebrewKind: String, Equatable, Sendable {
        case formula
        case cask
    }

    /// Claude Code's native installer: `~/.local/share/claude/versions/<v>`.
    case nativeClaude
    /// Codex's standalone install (a path through `/packages/standalone/`).
    case codexStandalone
    /// A global npm install under `prefix` (`<prefix>/lib/node_modules/<package>`).
    case npm(prefix: String, package: String)
    case homebrew(kind: HomebrewKind, name: String, prefix: String)
    /// mise pins versions in its own config; updating means editing that.
    case mise
    case unknown

    public var label: String {
        switch self {
        case .nativeClaude: return "native installer"
        case .codexStandalone: return "standalone installer"
        case .npm: return "npm"
        case let .homebrew(kind, _, _): return kind == .cask ? "Homebrew cask" : "Homebrew"
        case .mise: return "mise"
        case .unknown: return "unknown"
        }
    }
}

/// Where the newest published version is read from, by owner.
public enum AgentCLILatestSource: Equatable, Hashable, Sendable {
    /// `https://registry.npmjs.org/<package>/latest`.
    case npm(package: String)
    /// `https://pi.dev/api/latest-version`, the endpoint pi's own check uses.
    case piRelease
    /// `brew info --json=v2 [--cask] <name>` from the keg's own brew.
    case homebrew(brew: String, kind: AgentCLIInstallOwner.HomebrewKind, name: String)

    public var cacheKey: String {
        switch self {
        case let .npm(package): return "npm:\(package)"
        case .piRelease: return "pi-release"
        case let .homebrew(brew, kind, name): return "brew:\(brew):\(kind.rawValue):\(name)"
        }
    }
}

/// Everything Array knows about updating one CLI, decided once per check and
/// re-decided immediately before a run (`AgentCLIUpdateRunner` aborts on drift).
public struct AgentCLIUpdatePlan: Equatable, Sendable {
    public let harness: AgentHarness
    /// The absolute path Array spawns (`liveResolvedCommand().executable`).
    public let resolvedPath: String
    /// `resolvedPath` with every symlink followed.
    public let realPath: String
    public let owner: AgentCLIInstallOwner
    /// The exact argv Array runs, executable first. Nil means Array will not run
    /// anything for this install — unknown, mise or unwritable — and the row
    /// shows `manualCommand` and `guidance` instead of a button.
    public let argv: [String]?
    /// The command a person could run themselves, shell-quoted. Nil when there
    /// is no command Array can vouch for (unknown, mise).
    public let manualCommand: String?
    public let guidance: String?
    /// One lock per installer: two updates through one npm prefix, one Homebrew
    /// or one native installer never overlap.
    public let lockKey: String
    public let latestSource: AgentCLILatestSource

    public init(harness: AgentHarness, resolvedPath: String, realPath: String, owner: AgentCLIInstallOwner,
                argv: [String]?, manualCommand: String?, guidance: String?, lockKey: String,
                latestSource: AgentCLILatestSource) {
        self.harness = harness
        self.resolvedPath = resolvedPath
        self.realPath = realPath
        self.owner = owner
        self.argv = argv
        self.manualCommand = manualCommand
        self.guidance = guidance
        self.lockKey = lockKey
        self.latestSource = latestSource
    }

    public var isRunnable: Bool { argv != nil }

    /// npm deletes the old package directory under a live process, so an
    /// npm-owned update is refused while that harness has a turn in flight.
    public var replacesRunningBinary: Bool {
        if case .npm = owner { return true }
        return false
    }
}

/// The filesystem facts the classifier reads, injectable so the witness can
/// build fake layouts and so classification never spawns a process.
public struct AgentCLIFileSystem: Sendable {
    public var realPath: @Sendable (String) -> String
    public var isExecutable: @Sendable (String) -> Bool
    public var isWritable: @Sendable (String) -> Bool
    /// The file's contents when it is at most `limit` bytes, else nil.
    public var smallFileContents: @Sendable (_ path: String, _ limit: Int) -> String?

    public init(realPath: @escaping @Sendable (String) -> String,
                isExecutable: @escaping @Sendable (String) -> Bool,
                isWritable: @escaping @Sendable (String) -> Bool,
                smallFileContents: @escaping @Sendable (String, Int) -> String?) {
        self.realPath = realPath
        self.isExecutable = isExecutable
        self.isWritable = isWritable
        self.smallFileContents = smallFileContents
    }

    public static let live = AgentCLIFileSystem(
        realPath: { path in
            guard let resolved = Darwin.realpath(path, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        },
        isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
        isWritable: { Darwin.access($0, W_OK) == 0 },
        smallFileContents: { path, limit in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber, size.intValue <= limit,
                  let data = FileManager.default.contents(atPath: path) else { return nil }
            return String(decoding: data, as: UTF8.self)
        })
}

public enum AgentCLIInstallOwnerResolver {
    /// The npm package that ships each CLI.
    public static func npmPackage(for harness: AgentHarness) -> String {
        switch harness {
        case .claudeCode: return "@anthropic-ai/claude-code"
        case .codex: return "@openai/codex"
        case .pi: return "@earendil-works/pi-coding-agent"
        }
    }

    /// The plan for the binary at `resolvedPath`, or nil when Array found no
    /// absolute binary (`/usr/bin/env <name>` is not an install anyone owns).
    public static func plan(harness: AgentHarness, resolvedPath: String?,
                            fileSystem: AgentCLIFileSystem = .live) -> AgentCLIUpdatePlan? {
        guard let resolvedPath, resolvedPath.hasPrefix("/") else { return nil }
        let realPath = fileSystem.realPath(resolvedPath)
        let normalized = realPath.lowercased()
        let package = npmPackage(for: harness)
        let defaultSource: AgentCLILatestSource = harness == .pi ? .piRelease : .npm(package: package)

        func make(_ owner: AgentCLIInstallOwner, argv: [String]?, writableDirs: [String], lockKey: String,
                  source: AgentCLILatestSource = defaultSource) -> AgentCLIUpdatePlan {
            guard let argv else {
                return AgentCLIUpdatePlan(harness: harness, resolvedPath: resolvedPath, realPath: realPath, owner: owner,
                                          argv: nil, manualCommand: nil, guidance: manualGuidance(owner, realPath: realPath),
                                          lockKey: lockKey, latestSource: source)
            }
            // Array never escalates. A target it cannot write is the user's to update,
            // in a terminal, with whatever rights that install needs.
            if let blocked = writableDirs.first(where: { !fileSystem.isWritable($0) }) {
                return AgentCLIUpdatePlan(
                    harness: harness, resolvedPath: resolvedPath, realPath: realPath, owner: owner,
                    argv: nil, manualCommand: shellQuoted(argv),
                    guidance: "Array can't write to \(blocked), and it never uses sudo. To update, run this in a terminal.",
                    lockKey: lockKey, latestSource: source)
            }
            return AgentCLIUpdatePlan(harness: harness, resolvedPath: resolvedPath, realPath: realPath, owner: owner,
                                      argv: argv, manualCommand: shellQuoted(argv), guidance: nil,
                                      lockKey: lockKey, latestSource: source)
        }

        // Claude Code's native installer keeps every version under
        // ~/.local/share/claude/versions and repoints ~/.local/bin/claude.
        if harness == .claudeCode, let range = normalized.range(of: "/.local/share/claude/") {
            let root = String(realPath[..<range.upperBound].dropLast())
            return make(.nativeClaude, argv: [resolvedPath, "update"],
                        writableDirs: [root, (resolvedPath as NSString).deletingLastPathComponent],
                        lockKey: "claude-native")
        }
        // `codex update` replaces the standalone tree it was installed into.
        if harness == .codex, let range = normalized.range(of: "/packages/standalone/") {
            let root = String(realPath[..<range.upperBound].dropLast())
            return make(.codexStandalone, argv: [resolvedPath, "update"], writableDirs: [root],
                        lockKey: "codex-standalone")
        }
        // npm's proof names the package, so it outranks a keg the path passes
        // through (a Homebrew node keeps its globals under Cellar/node/…).
        if let prefix = npmGlobalPrefix(realPath: realPath, package: package) {
            let owner = AgentCLIInstallOwner.npm(prefix: prefix, package: package)
            let writable = [prefix + "/lib/node_modules", prefix + "/bin"]
            let lockKey = "npm:\(prefix)"
            if harness == .pi {
                // pi's own updater knows its npm install and its extensions; it runs
                // the prefix's npm from the PATH Array hands it.
                return make(owner, argv: [resolvedPath, "update", "--self"], writableDirs: writable, lockKey: lockKey)
            }
            let npm = prefix + "/bin/npm"
            guard fileSystem.isExecutable(npm) else {
                return AgentCLIUpdatePlan(
                    harness: harness, resolvedPath: resolvedPath, realPath: realPath, owner: owner, argv: nil,
                    manualCommand: nil,
                    guidance: "Installed with npm under \(prefix), but that prefix has no npm of its own. Update it with the npm that installed it.",
                    lockKey: lockKey, latestSource: defaultSource)
            }
            // `--allow-scripts`: npm 12 skips install scripts by default and still exits
            // 0, which leaves claude's native binary uninstalled. Older npm warns about
            // the unknown config and continues (T3 Code ships the same argv).
            return make(owner, argv: [npm, "install", "-g", "--prefix", prefix, "--allow-scripts=\(package)", "\(package)@latest"],
                        writableDirs: writable, lockKey: lockKey)
        }
        if isMise(resolvedPath: resolvedPath, realPath: realPath, fileSystem: fileSystem) {
            return make(.mise, argv: nil, writableDirs: [], lockKey: "mise")
        }
        if let keg = homebrewKeg(realPath: realPath), !(keg.kind == .formula && keg.name.lowercased() == "mise") {
            let owner = AgentCLIInstallOwner.homebrew(kind: keg.kind, name: keg.name, prefix: keg.prefix)
            // The keg's OWN brew, never another Homebrew on PATH: a second prefix
            // would upgrade (or refuse) a different install than the one Array runs.
            let brew = keg.prefix + "/bin/brew"
            let brewReal = fileSystem.realPath(brew)
            guard fileSystem.isExecutable(brew), brewReal.lowercased().hasPrefix(keg.prefix.lowercased() + "/") else {
                return AgentCLIUpdatePlan(
                    harness: harness, resolvedPath: resolvedPath, realPath: realPath, owner: .unknown, argv: nil,
                    manualCommand: nil,
                    guidance: "Installed by Homebrew under \(keg.prefix), but Array can't find that Homebrew's brew. Update it with brew in a terminal.",
                    lockKey: "homebrew:\(keg.prefix)", latestSource: defaultSource)
            }
            let argv = keg.kind == .cask ? [brew, "upgrade", "--cask", keg.name] : [brew, "upgrade", keg.name]
            return make(owner, argv: argv,
                        writableDirs: [keg.prefix + "/" + (keg.kind == .cask ? "Caskroom" : "Cellar")],
                        lockKey: "homebrew:\(keg.prefix)",
                        source: .homebrew(brew: brew, kind: keg.kind, name: keg.name))
        }
        return make(.unknown, argv: nil, writableDirs: [], lockKey: "unknown:\(realPath)")
    }

    private static func manualGuidance(_ owner: AgentCLIInstallOwner, realPath: String) -> String {
        switch owner {
        case .mise:
            return "Installed with mise, which pins the version in its own config. Update it with mise."
        default:
            return "Array can't tell what installed \(realPath), so it won't update it. Update it the way you installed it."
        }
    }

    /// `<prefix>/lib/node_modules/<package>/…` with no `node_modules` above it
    /// (a nested one is a package's dependency, not a global install), and not
    /// mise's npm backend, which borrows the same layout inside a tool version.
    static func npmGlobalPrefix(realPath: String, package: String) -> String? {
        let normalized = realPath.lowercased()
        let segment = "/lib/node_modules/\(package.lowercased())/"
        guard let range = normalized.range(of: segment, options: .backwards) else { return nil }
        let head = String(normalized[..<range.lowerBound])
        guard !head.contains("/node_modules/") else { return nil }
        if let tool = head.range(of: #"/mise/installs/([^/]+)/[^/]+$"#, options: .regularExpression)
            .map({ String(head[$0]).split(separator: "/")[2] }), tool != "node" {
            return nil
        }
        let offset = normalized.distance(from: normalized.startIndex, to: range.lowerBound)
        let prefix = String(realPath.prefix(offset))
        return prefix.isEmpty ? "/" : prefix
    }

    static func homebrewKeg(realPath: String) -> (kind: AgentCLIInstallOwner.HomebrewKind, name: String, prefix: String)? {
        let pattern = try! NSRegularExpression(pattern: #"^(.*)/(cellar|caskroom)/([^/]+)/[^/]+/"#, options: [.caseInsensitive])
        let range = NSRange(realPath.startIndex..., in: realPath)
        guard let match = pattern.firstMatch(in: realPath, range: range),
              let prefix = Range(match.range(at: 1), in: realPath),
              let kind = Range(match.range(at: 2), in: realPath),
              let name = Range(match.range(at: 3), in: realPath) else { return nil }
        return (realPath[kind].lowercased() == "cellar" ? .formula : .cask, String(realPath[name]), String(realPath[prefix]))
    }

    static func isMise(resolvedPath: String, realPath: String, fileSystem: AgentCLIFileSystem) -> Bool {
        for path in [resolvedPath, realPath] {
            let normalized = path.lowercased()
            if normalized.contains("/mise/installs/") || normalized.contains("/mise/shims/") { return true }
        }
        // A wrapper script that re-enters mise (`mise x …` / `mise exec …`).
        guard let script = fileSystem.smallFileContents(realPath, 16 * 1024), script.hasPrefix("#!") else { return false }
        return script.range(of: #"\bmise\s+(x|exec)\b"#, options: .regularExpression) != nil
    }

    /// One shell word, quoted only when it has to be.
    public static func shellQuoted(_ argv: [String]) -> String {
        argv.map { word in
            let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./-_")
            if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
            return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
