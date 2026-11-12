import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// `.plans/116` part 8 step 1, shadow only: what the host itself saw one helper
/// do since its delegation, folded on the run ledger's queue from the runtime
/// observations its translator already emits (Claude and Codex alike, keyed by
/// the provider's call id), checked at report time against what git says
/// changed since the delegation's baseline. Nothing here is shown to anyone.
///
/// The governing rule: a pass that rests on something the host did not see is
/// never recorded as `after`. When the host cannot know, it records `unknown`
/// and every reason why.
///
/// Memory holds a shell command only while it is classified. The ledger stores
/// checkout-relative paths, manifest invocations, call ids, order and fixed
/// words; never command text, output, file contents or diffs.
struct HelperEvidence {
    struct FileFact: Codable, Equatable {
        var path: String
        /// after, before, none, orderUnknown, unknown, unmapped, unchanged, editNotObserved.
        var status: String
        var reasons: [String]?
        /// The covering check's manifest invocation (never the command run).
        var check: String?
        var editCall: String?
        var editStart: Int?
        var editEnd: Int?
        var checkCall: String?
        var checkStart: Int?
        var checkEnd: Int?
        /// The exit the harness reported for that run, or `unknown`.
        var exit: String?
        /// The helper changed one of the covering check's own files.
        var checkFilesChanged: Bool?
    }

    /// What the supervisor hands the ledger for one observation: ids, a command
    /// to classify, edit targets and an exit. No output, preview or diff.
    struct Sighting: Sendable {
        enum Kind: Sendable {
            case edit([URL])
            case shell(String?)
            case delegate
            case report
            case ended(exit: Int?, incomplete: Bool, backgrounded: Bool)
        }
        var call: String
        var kind: Kind

        init?(_ observation: AgentRuntimeObservation) {
            switch observation {
            case let .toolActivity(call, activity) where activity.operation == .editing:
                self.call = call
                kind = .edit([activity.targetPath].compactMap { $0 } + activity.otherTargets)
            case let .toolDetail(call, detail) where detail.phase == .started:
                self.call = call
                if ArrayWorkspaceTool(toolName: detail.toolName) == .report { kind = .report; return }
                switch AgentToolKind.resolve(toolName: detail.toolName) {
                case .shell: kind = .shell(detail.fields.first { $0.key == AgentToolDetailObservation.shellCommandKey }?.value)
                case .delegate: kind = .delegate
                default: return nil
                }
            case let .toolDetail(call, detail) where detail.phase == .ended:
                self.call = call
                kind = .ended(exit: detail.exitCode, incomplete: [.interrupted, .timedOut, .backgrounded].contains(detail.shellOutcome),
                              backgrounded: detail.shellOutcome == .backgrounded)
            default: return nil
            }
        }
    }

    struct Manifest {
        struct Entry {
            var invocation: String
            var executable: String
            var options: [String]
            var mention: String
            var covers: [NSRegularExpression]
            var checkFiles: [NSRegularExpression]
            var binary: Bool { executable.hasPrefix(".build/") }
        }
        var entries: [Entry] = []
        /// Globs of entries whose invocation could not be read: their paths are a
        /// parse problem, not unmapped. `unreadable` when even those are unknown.
        var unparsedCovers: [NSRegularExpression] = []
        var unparsed = 0
        var unreadable = false

        /// The gate pre-pass owns this file. It is read from the delegation's
        /// baseline commit, so a helper cannot remap its own edits.
        static let relativePath = "scripts/check-coverage-manifest.json"
        static let interpreters: Set<String> = ["python3", "python", "bash", "sh", "zsh"]

        init(json data: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let checks = object["checks"] as? [[String: Any]] else { unreadable = true; return }
            for entry in checks {
                let covers = (entry["covers"] as? [String])?.map(Self.glob)
                let words = (entry["invocation"] as? String).map(HelperEvidence.words) ?? []
                let script = words.count > 1 && Self.interpreters.contains(words[0])
                let executable = script ? words[1] : words.first
                guard let covers, !covers.contains(where: { $0 == nil }), let executable,
                      executable.contains("/"), let invocation = entry["invocation"] as? String else {
                    unparsed += 1
                    if let covers, !covers.contains(where: { $0 == nil }) { unparsedCovers += covers.compactMap { $0 } }
                    else { unreadable = true }
                    continue
                }
                let options = words.filter { $0.hasPrefix("-") }
                entries.append(Entry(invocation: invocation, executable: executable, options: options,
                                     mention: options.first { $0.hasSuffix("-check") } ?? executable,
                                     covers: covers.compactMap { $0 },
                                     checkFiles: ((entry["checkFiles"] as? [String]) ?? []).compactMap(Self.glob)))
            }
        }

        /// `**` spans directories; `*` and `?` stay inside one.
        static func glob(_ pattern: String) -> NSRegularExpression? {
            var regex = "^"
            var rest = Substring(pattern)
            while let c = rest.first {
                if rest.hasPrefix("**/") { regex += "(?:.*/)?"; rest = rest.dropFirst(3) }
                else if rest.hasPrefix("**") { regex += ".*"; rest = rest.dropFirst(2) }
                else if c == "*" { regex += "[^/]*"; rest = rest.dropFirst() }
                else if c == "?" { regex += "[^/]"; rest = rest.dropFirst() }
                else { regex += NSRegularExpression.escapedPattern(for: String(c)); rest = rest.dropFirst() }
            }
            return try? NSRegularExpression(pattern: regex + "$")
        }
    }

    static func matches(_ globs: [NSRegularExpression], _ path: String) -> Bool {
        globs.contains { $0.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil }
    }

    /// Whitespace-separated words, one layer of quotes removed.
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { word in
            var word = String(word)
            if word.count >= 2, let first = word.first, first == word.last, first == "'" || first == "\"" {
                word = String(word.dropFirst().dropLast())
            }
            return word
        }
    }

    /// Anything a shell could run more than one way: lists, pipes, conditions,
    /// background jobs, substitutions, newlines. Plain redirections are fine.
    static func isCompound(_ command: String) -> Bool {
        let text = command.replacingOccurrences(of: #"\d*>&\d+|\d*>>?\s*[^\s;|&<>]+|\d*<\s*[^\s;|&<>]+"#,
                                                with: " ", options: .regularExpression)
        return text.range(of: #"[;|&\n`]|\$\(|<\("#, options: .regularExpression) != nil
    }

    /// A lone `&` (not `&&`, `>&` or `&>`), or a word that detaches a job.
    static func startsBackgroundJob(_ command: String) -> Bool {
        let text = command.replacingOccurrences(of: #"\d*>&\d+|&>>?|>&"#, with: " ", options: .regularExpression)
        if text.range(of: #"(^|[^&])&($|[^&])"#, options: .regularExpression) != nil { return true }
        return words(text).contains { ["nohup", "disown", "setsid"].contains($0) }
    }

    /// A `swift build` the host saw: which product (nil = all) in which configuration.
    private struct Build { var product: String?; var configuration: String }
    /// `background`: the command leaves a job running after the call ends.
    private struct Shell { var runs: [Int] = []; var possible: [Int] = []; var build: Build?; var hidden = false; var background = false }
    private enum Kind { case edit([URL]), shell(Shell), delegate, report }
    private struct Call { var id: String; var kind: Kind; var start: Int; var end: Int?; var exit: Int?; var incomplete = false; var backgrounded = false }

    let root: URL
    let base: String?
    let shared: Bool
    private(set) var manifest: Manifest?
    private var manifestProblem: String?
    private var seq = 0
    private var calls: [Call] = []
    private var index: [String: Int] = [:]
    private var reportSeen = false

    init(root: URL, base: String?, shared: Bool) {
        self.root = root; self.base = base; self.shared = shared
        guard let base else { manifestProblem = "noBaseline"; return }
        guard let data = try? Self.git(["show", "\(base):\(Manifest.relativePath)"], root) else {
            manifestProblem = "manifestMissing"; return
        }
        manifest = Manifest(json: data)
        if manifest?.unreadable == true && manifest?.entries.isEmpty == true { manifestProblem = "manifestUnreadable" }
    }

    static func git(_ arguments: [String], _ root: URL) throws -> Data {
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
        return data
    }

    private func classify(_ command: String?) -> Shell {
        guard let command else { return Shell(hidden: true) }
        var shell = Shell()
        let simple = !Self.isCompound(command)
        shell.background = Self.startsBackgroundJob(command)
        var words = Self.words(command.replacingOccurrences(
            of: #"\d*>&\d+|\d*>>?\s*[^\s;|&<>]+|\d*<\s*[^\s;|&<>]+"#, with: " ", options: .regularExpression))
        while let first = words.first, first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil {
            words.removeFirst()
        }
        func isPath(_ word: String?, _ relative: String) -> Bool {
            guard let word else { return false }
            return word == relative || word == "./" + relative || word == root.appendingPathComponent(relative).path
        }
        for (i, entry) in (manifest?.entries ?? []).enumerated() {
            let invoked = isPath(words.first, entry.executable)
                || (!entry.binary && Manifest.interpreters.contains(words.first ?? "") && isPath(words.dropFirst().first, entry.executable))
            if simple, invoked, Set(entry.options).isSubset(of: Set(words)) { shell.runs.append(i) }
            else if command.contains(entry.mention) { shell.possible.append(i) }
        }
        if simple, words.count >= 2, words[0] == "swift", words[1] == "build" {
            var build = Build(product: nil, configuration: "debug")
            var rest = words.dropFirst(2)
            while let word = rest.popFirst() {
                switch word {
                case "--product": build.product = rest.popFirst() ?? ""
                case "--target": build.product = ""  // compiles a target, links no binary
                case "-c", "--configuration": build.configuration = rest.popFirst() ?? ""
                default: break
                }
            }
            shell.build = build
        }
        return shell
    }

    mutating func observe(_ sighting: Sighting) {
        seq += 1
        switch sighting.kind {
        case let .ended(exit, incomplete, backgrounded):
            guard let i = index[sighting.call] else { return }
            calls[i].end = seq; calls[i].exit = exit; calls[i].incomplete = incomplete; calls[i].backgrounded = backgrounded
        case let .edit(targets):
            if let i = index[sighting.call], case let .edit(old) = calls[i].kind { calls[i].kind = .edit(old + targets); return }
            add(sighting.call, .edit(targets))
        case let .shell(command): add(sighting.call, .shell(classify(command)))
        case .delegate: add(sighting.call, .delegate)
        case .report: reportSeen = true; add(sighting.call, .report)
        }
    }

    private mutating func add(_ id: String, _ kind: Kind) {
        // A call's start is its first observation (Codex and Claude both report
        // an edit's target before its start detail).
        if index[id] != nil { return }
        index[id] = calls.count
        calls.append(Call(id: id, kind: kind, start: seq))
    }

    static func relative(_ url: URL, root: URL) -> String? {
        for (path, base) in [(url.path, root.path),
                             (url.resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path)] {
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        return nil
    }

    /// The facts for one report. Runs git for names only; called on the ledger queue.
    mutating func facts() -> (files: [FileFact], summary: [String: String]) {
        defer { reportSeen = false }
        var summary: [String: String] = ["observed": "sinceDelegation", "checkout": shared ? "shared" : "own",
                                         "reportCallObserved": String(reportSeen)]
        var changed: Set<String>?
        if let base, let names = try? WorktreeManager().changedFiles(repo: root, since: base) {
            changed = Set(names); summary["changes"] = "git"
        } else {
            summary["changes"] = "unavailable"; summary["changesReason"] = base == nil ? "noBaseline" : "gitFailed"
        }
        if let manifestProblem { summary["manifest"] = manifestProblem }
        else {
            summary["manifest"] = "baseline"
            if let manifest, manifest.unparsed > 0 { summary["manifestUnparsedEntries"] = String(manifest.unparsed) }
        }
        summary["manifestChanged"] = changed.map { String($0.contains(Manifest.relativePath)) } ?? "unknown"

        var edits: [String: [Call]] = [:]
        var outside = 0
        for call in calls {
            guard case let .edit(targets) = call.kind else { continue }
            for target in targets {
                if let path = Self.relative(target, root: root) { edits[path, default: []].append(call) } else { outside += 1 }
            }
        }
        summary["outsideCheckoutEdits"] = String(outside)
        let touched = Set(edits.keys).union(changed ?? [])
        let files = touched.sorted().map { path in fact(path, edits: edits[path] ?? [], changed: changed, touched: touched) }
        return (files, summary)
    }

    private func shellOf(_ call: Call) -> Shell? { if case let .shell(shell) = call.kind { return shell }; return nil }

    private func fact(_ path: String, edits: [Call], changed: Set<String>?, touched: Set<String>) -> FileFact {
        var fact = FileFact(path: path, status: "unknown")
        guard let last = edits.max(by: { $0.start < $1.start }) else {
            fact.status = "editNotObserved"
            if shared { fact.reasons = ["sharedCheckout"] }
            return fact
        }
        fact.editCall = last.id; fact.editStart = last.start; fact.editEnd = last.end
        if let changed, !changed.contains(path) { fact.status = "unchanged"; return fact }
        guard let manifest = manifest, manifestProblem == nil else { fact.reasons = [manifestProblem ?? "noManifest"]; return fact }
        // A check's own files are covered by that check: editing one is an edit
        // the check has to be run after, and is recorded as such.
        let covering = manifest.entries.indices.filter {
            Self.matches(manifest.entries[$0].covers, path) || Self.matches(manifest.entries[$0].checkFiles, path)
        }
        if covering.isEmpty {
            if manifest.unreadable || Self.matches(manifest.unparsedCovers, path) { fact.reasons = ["manifestUnparsed"] }
            else { fact.status = "unmapped" }
            return fact
        }
        fact.checkFilesChanged = covering.contains { i in touched.contains { Self.matches(manifest.entries[i].checkFiles, $0) } }
        let editsEnd: Int? = edits.contains { $0.end == nil } ? nil : edits.compactMap(\.end).max()
        func covers(_ shell: Shell, _ list: KeyPath<Shell, [Int]>) -> Bool { !Set(shell[keyPath: list]).isDisjoint(with: covering) }
        // A run is a provable invocation that ended, completed, and started.
        let runs = calls.filter { call in
            guard let shell = shellOf(call), covers(shell, \.runs), call.end != nil, !call.incomplete else { return false }
            return call.exit != 126 && call.exit != 127
        }
        func record(_ run: Call) {
            fact.check = shellOf(run)!.runs.first(where: covering.contains).map { manifest.entries[$0].invocation }
            fact.checkCall = run.id; fact.checkStart = run.start; fact.checkEnd = run.end
            fact.exit = run.exit.map(String.init) ?? "unknown"
        }
        if let editsEnd, let run = runs.filter({ $0.start > editsEnd }).max(by: { $0.start < $1.start }) {
            record(run)
            var reasons: [String] = []
            if changed == nil { reasons.append("changesUnverifiable") }
            if shared { reasons.append("sharedCheckout") }
            if !reportSeen { reasons.append("observationsInFlight") }
            reasons += activity(after: run.start, excluding: run.id, path: path)
            if calls.contains(where: { $0.end == nil && $0.id != run.id && !isReport($0) }) { reasons.append("callStillRunning") }
            // A job it left running can write after the check, unseen.
            if calls.contains(where: { call in
                call.start < run.start && (call.backgrounded || shellOf(call)?.background == true)
            }) { reasons.append("backgroundJobBeforeCheck") }
            let entry = shellOf(run)!.runs.first(where: covering.contains)!
            if manifest.entries[entry].binary && !fresh(manifest.entries[entry].executable, before: run) { reasons.append("buildFreshnessUnknown") }
            if reasons.isEmpty { fact.status = "after" } else { fact.reasons = Array(Set(reasons)).sorted() }
            return fact
        }
        // A run that overlaps an edit to this file has no provable order.
        if let run = runs.last(where: { run in edits.contains { run.start < ($0.end ?? Int.max) && (run.end ?? Int.max) > $0.start } }) {
            record(run); fact.status = "orderUnknown"; return fact
        }
        var reasons: [String] = []
        for call in calls where call.start > last.start {
            guard let shell = shellOf(call) else {
                if case .delegate = call.kind { reasons.append("subagentAfterEdit") }
                continue
            }
            if shell.hidden { reasons.append("hiddenShellAfterEdit") }
            if covers(shell, \.possible) { reasons.append("possibleRun") }
            if covers(shell, \.runs), call.end == nil || call.incomplete { reasons.append("checkIncomplete") }
        }
        if !reasons.isEmpty { fact.reasons = Array(Set(reasons)).sorted(); return fact }
        if let run = runs.filter({ ($0.end ?? Int.max) < last.start }).max(by: { $0.start < $1.start }) {
            record(run); fact.status = "before"
        } else {
            fact.status = "none"
        }
        return fact
    }

    private func isReport(_ call: Call) -> Bool { if case .report = call.kind { return true }; return false }

    /// Anything after a check that could have changed `path` without the host seeing it.
    private func activity(after start: Int, excluding id: String, path: String) -> [String] {
        calls.filter { $0.start > start && $0.id != id }.compactMap { call in
            switch call.kind {
            case .report, .edit: return nil  // an edit to this path would make the run not after it
            case .delegate: return "subagentAfterCheck"
            case let .shell(shell):
                if shell.hidden { return "hiddenShellAfterCheck" }
                return shell.runs.isEmpty && shell.build == nil ? "shellAfterCheck" : nil
            }
        }
    }

    /// A binary check is fresh only after a rebuild of that binary's product and
    /// configuration that the harness reported exit 0 for, which started after
    /// every observed edit ended, with nothing that could write in between.
    private func fresh(_ executable: String, before run: Call) -> Bool {
        calls.contains { build in
            guard let made = shellOf(build)?.build, build.exit == 0, let end = build.end, end < run.start,
                  executable.hasPrefix(".build/\(made.configuration)/"),
                  made.product.map({ $0 == (executable as NSString).lastPathComponent }) ?? true else { return false }
            return !calls.contains { call in
                guard call.id != build.id, call.id != run.id else { return false }
                switch call.kind {
                case .edit: return (call.end ?? Int.max) > build.start && call.start < run.start
                case .delegate: return call.start > build.start && call.start < run.start
                case let .shell(s): return call.start > build.start && call.start < run.start && s.runs.isEmpty && s.build == nil
                case .report: return false
                }
            }
        }
    }
}
