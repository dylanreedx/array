import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

/// `.plans/116` part 8 step 1, shadow only: what the host itself saw one helper
/// do since its delegation, folded on the run ledger's queue from the runtime
/// observations its translator already emits (Claude and Codex alike, keyed by
/// the provider's call id). Nothing here is shown to any agent or person.
///
/// Memory holds a call's command only until it is classified; what is kept is
/// check names, absolute edit targets, call ids and order. The ledger stores
/// checkout-relative paths, check names, ids and order, never command text,
/// file contents or diffs.
struct HelperEvidence {
    struct FileFact: Codable, Equatable {
        var path: String
        /// `after`, `before` or `none`: the last covering check run relative to
        /// the last edit. `unknown` with a `reason` when the host could not see
        /// enough; `unmapped` when the manifest maps no check to the path.
        var status: String
        var reason: String?
        var check: String?
        var editCall: String
        var editSeq: Int
        var checkCall: String?
        var checkSeq: Int?
        /// The run's numeric exit, or `unknown` with `exitReason`.
        var exit: String?
        var exitReason: String?
    }

    private struct Run { var seq: Int; var call: String; var exit: Int?; var compound: Bool }
    private var seq = 0
    private var lastEdit: [URL: (seq: Int, call: String)] = [:]
    /// Shell calls started and not yet ended: their check names.
    private var running: [String: (names: [String], compound: Bool)] = [:]
    private var completed: [String: Run] = [:]
    private var incomplete: [String: Int] = [:]
    private var lastHiddenShell: Int?
    private var hiddenShells = 0
    private var runs = 0

    static let flag = try! NSRegularExpression(pattern: "^--[a-z0-9-]+-check$")

    /// Names a command could be running: every `--*-check` flag and every
    /// `.py`/`.sh` script it names. Which scripts are checks is the manifest's
    /// call, made at report time.
    static func candidates(_ command: String) -> [String] {
        let tokens = command.split(whereSeparator: { " \t\n;|&()<>'\"`".contains($0) }).map(String.init)
        return Array(Set(tokens.compactMap { token -> String? in
            if flag.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) != nil { return token }
            guard token.hasSuffix(".py") || token.hasSuffix(".sh") else { return nil }
            return token.hasPrefix("./") ? String(token.dropFirst(2)) : token
        })).sorted()
    }

    /// One exit can only be attributed to one simple command.
    static func isCompound(_ command: String) -> Bool {
        let text = command.replacingOccurrences(of: #"\d*>&\d+"#, with: " ", options: .regularExpression)
        return text.range(of: #"[;|&\n`]|\$\("#, options: .regularExpression) != nil
    }

    mutating func observe(_ observation: AgentRuntimeObservation) {
        switch observation {
        case let .toolActivity(call, activity) where activity.operation == .editing:
            seq += 1
            for target in [activity.targetPath].compactMap({ $0 }) + activity.otherTargets {
                lastEdit[target] = (seq, call)
            }
        case let .toolDetail(call, detail) where detail.phase == .started:
            guard AgentToolKind.resolve(toolName: detail.toolName) == .shell else { return }
            seq += 1
            guard let command = detail.fields.first(where: { $0.key == AgentToolDetailObservation.shellCommandKey })?.value else {
                // "Show shell commands in transcripts" is off, or the provider sent none.
                lastHiddenShell = seq; hiddenShells += 1; return
            }
            let names = Self.candidates(command)
            if !names.isEmpty { running[call] = (names, Self.isCompound(command)) }
        case let .toolDetail(call, detail) where detail.phase == .ended:
            guard let run = running.removeValue(forKey: call) else { return }
            seq += 1
            if detail.shellOutcome == .interrupted || detail.shellOutcome == .timedOut || detail.shellOutcome == .backgrounded {
                for name in run.names { incomplete[name] = seq }
            } else {
                runs += 1
                for name in run.names { completed[name] = Run(seq: seq, call: call, exit: detail.exitCode, compound: run.compound) }
            }
        default: break
        }
    }

    struct Manifest {
        struct Entry { var check: String; var covers: [NSRegularExpression] }
        var entries: [Entry]

        /// The gate pre-pass owns this file; it is read, never written or copied.
        static let relativePath = "scripts/check-coverage-manifest.json"

        static func load(root: URL) -> Manifest? {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(relativePath)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let checks = object["checks"] as? [[String: Any]] else { return nil }
            return Manifest(entries: checks.compactMap { entry in
                guard let invocation = entry["invocation"] as? String,
                      let check = identity(invocation),
                      let covers = entry["covers"] as? [String] else { return nil }
                return Entry(check: check, covers: covers.compactMap(glob))
            })
        }

        /// The flag a matrix leg passes, else the script it runs.
        static func identity(_ invocation: String) -> String? {
            let names = HelperEvidence.candidates(invocation)
            return names.first(where: { $0.hasPrefix("--") })
                ?? invocation.split(separator: " ").map(String.init).first(where: names.contains)
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

        func checks(covering path: String) -> [String] {
            entries.filter { $0.covers.contains { $0.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil } }
                .map(\.check)
        }
    }

    static func relative(_ url: URL, root: URL) -> String? {
        for (path, base) in [(url.path, root.path),
                             (url.resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path)] {
            let prefix = base.hasSuffix("/") ? base : base + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        return nil
    }

    /// The facts for one report. `exitProven` is false for a harness whose
    /// recorded fixtures do not show the host a numeric exit.
    func facts(root: URL, exitProven: Bool) -> (files: [FileFact], summary: [String: String]) {
        let manifest = Manifest.load(root: root)
        var outside = 0
        var files: [FileFact] = []
        for (url, edit) in lastEdit {
            guard let path = Self.relative(url, root: root) else { outside += 1; continue }
            var fact = FileFact(path: path, status: "unknown", editCall: edit.call, editSeq: edit.seq)
            guard let manifest else { fact.reason = "noManifest"; files.append(fact); continue }
            let names = manifest.checks(covering: path)
            func run(_ name: String) -> (String, Run)? {
                completed.filter { $0.key == name || $0.key.hasSuffix("/" + name) }.values
                    .max(by: { $0.seq < $1.seq }).map { (name, $0) }
            }
            let ran = names.compactMap(run)
            if names.isEmpty {
                fact.status = "unmapped"
            } else if let (name, after) = ran.filter({ $0.1.seq > edit.seq }).max(by: { $0.1.seq < $1.1.seq }) {
                fact.status = "after"; fact.check = name; fact.checkCall = after.call; fact.checkSeq = after.seq
                if !exitProven { fact.exit = "unknown"; fact.exitReason = "notReportedByHarness" }
                else if after.compound { fact.exit = "unknown"; fact.exitReason = "compoundCommand" }
                else if let code = after.exit { fact.exit = String(code) }
                else { fact.exit = "unknown"; fact.exitReason = "notReported" }
            } else if names.contains(where: { name in
                running.values.contains { $0.names.contains { $0 == name || $0.hasSuffix("/" + name) } }
                    || incomplete.contains { ($0.key == name || $0.key.hasSuffix("/" + name)) && $0.value > edit.seq }
            }) {
                fact.reason = "checkIncomplete"
            } else if let hidden = lastHiddenShell, hidden > edit.seq {
                fact.reason = "shellCommandNotObserved"
            } else if let (name, before) = ran.max(by: { $0.1.seq < $1.1.seq }) {
                fact.status = "before"; fact.check = name; fact.checkCall = before.call; fact.checkSeq = before.seq
            } else {
                fact.status = "none"
            }
            files.append(fact)
        }
        files.sort { $0.path < $1.path }
        return (files, ["manifest": manifest == nil ? "missing" : "present", "observed": "sinceDelegation",
                        "outsideCheckoutEdits": String(outside), "checkRuns": String(runs),
                        "shellCommandsNotObserved": String(hiddenShells)])
    }
}
