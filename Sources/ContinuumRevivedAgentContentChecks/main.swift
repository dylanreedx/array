import ContinuumRevivedAgentContent
import Foundation

// Ticket: docs/38-tickets/91-agent-tile-ux/P0.2-agent-content-target.md
//
// The fast semantic-content leg. Its only dependency is
// ContinuumRevivedAgentContent — that is half the gate: a semantic type that
// reaches back into Core, Sync, AgentUI or GhosttyKit stops this executable
// from compiling. The other half is below, because a compile gate only catches
// what the CHECKS target links: AgentContent itself could still grow an
// `import AppKit` or a package-manifest dependency and compile perfectly well
// on its own. So the module's sources and its two manifest target blocks are
// read and held to a declared ALLOWLIST — not a blocklist, because the coupling
// nobody thought to ban is exactly the one that gets in.
//
// Three rounds of independent review each walked past a line-oriented scanner:
// prose about an import, a block-commented decoy target, `import\tAppKit`,
// `import AppKit; import Foundation`, `internal import AppKit`,
// `import/**/AppKit`, an import split across two lines, a raw-string decoy, a
// dependency named by a variable, `dependencies :` with a space. Patching each
// hole was losing to the next one, so the text scan is gone: `tokenize` below
// is a small Swift lexer (comments, escapes, multiline and raw strings,
// backtick identifiers), and both scans run on its token stream, at declaration
// depth, and FAIL CLOSED — a construct the lexer cannot read is an error
// telling the next worker to extend it, never a silent pass.
//
// `expect` is the same shape as every other checks target's (see
// ContinuumRevivedAgentUIChecks/main.swift): fail loud on stderr, exit 1 on the
// first failure.
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        Foundation.exit(1)
    }
}

func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    Foundation.exit(1)
}

/// Repository root, derived from this file rather than the working directory so
/// the scans below cannot be silently defeated by running from elsewhere.
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()          // ContinuumRevivedAgentContentChecks
    .deletingLastPathComponent()          // Sources
    .deletingLastPathComponent()          // <repo>

// MARK: - A small Swift lexer

enum Token: Equatable {
    /// An identifier or keyword. A backtick-escaped identifier keeps its
    /// backticks, so `` `import` `` (a legal variable name) can never compare
    /// equal to the `import` keyword.
    case identifier(String)
    /// A string literal's contents. Single-line, multiline and raw literals all
    /// arrive here as one token, so nothing inside one is ever read as code.
    case string(String)
    /// A numeric literal. Kept as a distinct token so it is neither an
    /// identifier nor punctuation to the scans below.
    case number
    case punctuation(Character)
}

/// Keywords that cannot end an expression, and so may be followed by a regex
/// literal rather than a division operator. Used only by that one disambiguation.
let swiftKeywords: Set<String> = [
    "return", "case", "in", "where", "if", "guard", "while", "for", "else", "try", "as", "is",
    "await", "throw", "let", "var", "switch", "default", "do", "catch", "yield", "repeat"
]

/// Lexes Swift well enough for the two scans below: comments (nesting block
/// comments included) disappear, every literal form collapses to one token, and
/// everything else becomes an identifier, a number, or a punctuation character.
func tokenize(_ source: String) -> [Token] {
    let characters = Array(source)
    var tokens: [Token] = []
    var index = 0

    func matches(_ literal: String, at position: Int) -> Bool {
        let pattern = Array(literal)
        guard position + pattern.count <= characters.count else { return false }
        for offset in 0..<pattern.count where characters[position + offset] != pattern[offset] {
            return false
        }
        return true
    }

    /// Number of raw-string `#` delimiters immediately before the quote at
    /// `position`, or nil when no string literal starts there.
    func stringLiteralPounds(at position: Int) -> Int? {
        var pounds = 0
        var cursor = position
        while cursor < characters.count && characters[cursor] == "#" {
            pounds += 1
            cursor += 1
        }
        guard cursor < characters.count, characters[cursor] == "\"" else { return nil }
        return pounds
    }

    /// Reads a string literal whose opening quote is at `start`, preceded by
    /// `pounds` raw-string delimiters. Returns the contents and the index just
    /// past the closing delimiter.
    ///
    /// Interpolations are skipped as balanced code, recursing through any
    /// literal nested inside them. Treating `\(` as a plain escape would let the
    /// nested literal's opening quote close the outer one and spill the rest of
    /// the file into "code" — `"\(String(describing: "…"))"` is ordinary Swift.
    func readString(from start: Int, pounds: Int) -> (String, Int) {
        let fence = String(repeating: "#", count: pounds)
        let isMultiline = matches("\"\"\"", at: start)
        let opening = isMultiline ? 3 : 1
        let closing = (isMultiline ? "\"\"\"" : "\"") + fence
        var cursor = start + opening
        var contents = ""
        while cursor < characters.count && !matches(closing, at: cursor) {
            if matches("\\" + fence + "(", at: cursor) {
                cursor += 1 + pounds + 1
                var depth = 1
                while cursor < characters.count && depth > 0 {
                    // Comments inside the interpolation are skipped too: a quote
                    // inside one is not a nested literal's delimiter.
                    if matches("//", at: cursor) {
                        while cursor < characters.count && characters[cursor] != "\n" { cursor += 1 }
                        continue
                    }
                    if matches("/*", at: cursor) {
                        var commentDepth = 0
                        while cursor < characters.count {
                            if matches("/*", at: cursor) { commentDepth += 1; cursor += 2; continue }
                            if matches("*/", at: cursor) {
                                commentDepth -= 1
                                cursor += 2
                                if commentDepth == 0 { break }
                                continue
                            }
                            cursor += 1
                        }
                        continue
                    }
                    if let nestedPounds = stringLiteralPounds(at: cursor) {
                        (_, cursor) = readString(from: cursor + nestedPounds, pounds: nestedPounds)
                        continue
                    }
                    if characters[cursor] == "(" { depth += 1 }
                    if characters[cursor] == ")" { depth -= 1 }
                    cursor += 1
                }
                continue
            }
            // In a raw string the escape is `\` followed by the same number of
            // pounds; with no pounds it is a bare backslash.
            if characters[cursor] == "\\" && matches("\\" + fence, at: cursor) {
                cursor += 1 + pounds
                if cursor < characters.count {
                    contents.append(characters[cursor])
                    cursor += 1
                }
                continue
            }
            contents.append(characters[cursor])
            cursor += 1
        }
        guard cursor < characters.count else {
            fail("unterminated string literal while lexing — the AgentContent scans must be extended, not bypassed")
        }
        return (contents, cursor + closing.count)
    }

    while index < characters.count {
        let character = characters[index]

        if character.isWhitespace { index += 1; continue }

        if matches("//", at: index) {
            while index < characters.count && characters[index] != "\n" { index += 1 }
            continue
        }

        if matches("/*", at: index) {
            var depth = 0
            while index < characters.count {
                if matches("/*", at: index) { depth += 1; index += 2; continue }
                if matches("*/", at: index) {
                    depth -= 1
                    index += 2
                    if depth == 0 { break }
                    continue
                }
                index += 1
            }
            continue
        }

        // Raw string (`#"…"#`, `##"""…"""##`) — or a `#if`/`#available`
        // directive, which is just punctuation to these scans.
        if character == "#" {
            var pounds = 0
            var cursor = index
            while cursor < characters.count && characters[cursor] == "#" {
                pounds += 1
                cursor += 1
            }
            if cursor < characters.count && characters[cursor] == "\"" {
                let (contents, next) = readString(from: cursor, pounds: pounds)
                tokens.append(.string(contents))
                index = next
                continue
            }
            tokens.append(.punctuation("#"))
            index += 1
            continue
        }

        if character == "\"" {
            let (contents, next) = readString(from: index, pounds: 0)
            tokens.append(.string(contents))
            index = next
            continue
        }

        if character == "`" {
            var name = "`"
            var cursor = index + 1
            while cursor < characters.count && characters[cursor] != "`" {
                name.append(characters[cursor])
                cursor += 1
            }
            guard cursor < characters.count else {
                fail("unterminated backtick identifier while lexing — the AgentContent scans must be extended, not bypassed")
            }
            name.append("`")
            tokens.append(.identifier(name))
            index = cursor + 1
            continue
        }

        if character.isLetter || character == "_" {
            var name = ""
            while index < characters.count,
                  characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
                name.append(characters[index])
                index += 1
            }
            tokens.append(.identifier(name))
            continue
        }

        if character.isNumber {
            while index < characters.count,
                  characters[index].isHexDigit || characters[index] == "_" || characters[index] == "." {
                index += 1
            }
            tokens.append(.number)
            continue
        }

        // A bare regex literal (`/import AppKit/`) is code to the compiler and
        // opaque here: one containing a quote would desynchronise the lexer and
        // swallow real declarations. Regex-vs-division is genuinely ambiguous
        // without a full parser, so this refuses instead of guessing. Division
        // after something that can END an expression is unambiguous and stays a
        // plain operator; anything else is a candidate literal and fails closed.
        if character == "/" {
            let endsAnExpression: Bool
            switch tokens.last {
            // `)`/`]` close a call or subscript; `>` closes a generic argument
            // list. All end an expression, so `f(x) / 2` is division.
            case .string, .number,
                 .punctuation(")"), .punctuation("]"), .punctuation(">"):
                endsAnExpression = true
            case .punctuation("!"), .punctuation("?"):
                // Postfix force-unwrap and optional chaining end an expression —
                // but the same characters are PREFIX in `try!`/`try?`, and the
                // second `?` of `??` is part of a binary operator. In those
                // positions a `/` opens a regex (`try! /"/`, `fallback ?? /"/`),
                // so they fall through to the refusal below.
                switch tokens.dropLast().last {
                case .punctuation("?"):
                    endsAnExpression = false
                case let .identifier(previous):
                    endsAnExpression = !swiftKeywords.contains(previous)
                case .none:
                    endsAnExpression = false
                default:
                    endsAnExpression = true
                }
            case let .identifier(previous):
                endsAnExpression = !swiftKeywords.contains(previous)
            default:
                endsAnExpression = false
            }
            guard endsAnExpression else {
                fail("a `/` that may open a regex literal — this scan does not lex regex literals and will not guess; extend it, do not bypass it")
            }
        }

        tokens.append(.punctuation(character))
        index += 1
    }

    return tokens
}

func runAgentContentModuleChecks() {
    // The module is reachable and names itself the same thing the manifest
    // does. Trivial, but it is what makes the `import` above — and therefore
    // the whole compile gate — non-vacuous.
    expect(AgentContentModule.name == "ContinuumRevivedAgentContent",
           "AgentContentModule.name is \"\(AgentContentModule.name)\", not the declared target name")

    let moduleDirectory = repoRoot.appendingPathComponent("Sources/ContinuumRevivedAgentContent", isDirectory: true)
    var isDirectory: ObjCBool = false
    expect(FileManager.default.fileExists(atPath: moduleDirectory.path, isDirectory: &isDirectory) && isDirectory.boolValue,
           "the AgentContent source directory is missing at \(moduleDirectory.path)")

    print("AgentContent module checks passed: \(AgentContentModule.name) is linked and platform-neutral by construction")
}

func runAgentContentPlatformNeutralityChecks() {
    // MARK: 1 · no forbidden import in the module's own sources
    //
    // Foundation and nothing else, which is what P0.2 stands up. P2.1 adds
    // Apple's swift-markdown for the parser seam; extending this set is that
    // ticket's job and a visible, reviewed diff. It is deliberately NOT
    // pre-authorised here — a gate that already permits a dependency nobody has
    // reviewed is not a gate.
    let allowedImports: Set<String> = ["Foundation"]

    // `import struct Foundation.Data` — the kind specifier sits between the
    // keyword and the module path.
    let importKinds: Set<String> = [
        "struct", "class", "enum", "protocol", "typealias", "func", "var", "let", "actor"
    ]

    let moduleDirectory = repoRoot.appendingPathComponent("Sources/ContinuumRevivedAgentContent", isDirectory: true)
    var scannedFiles = 0
    var scannedImports = 0
    var offendingImports: [String] = []

    if let walker = FileManager.default.enumerator(at: moduleDirectory, includingPropertiesForKeys: nil) {
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                fail("AgentContent import scan cannot read \(url.path)")
            }
            scannedFiles += 1
            let tokens = tokenize(text)
            // `import` is a reserved word: outside a comment or literal — both
            // of which the lexer already consumed — a bare `import` token can
            // only be an import declaration. Newlines, tabs, semicolons,
            // attributes, access levels and `/**/` between the keyword and the
            // module are all invisible at this level.
            for (position, token) in tokens.enumerated() where token == .identifier("import") {
                scannedImports += 1
                var cursor = position + 1
                var path: [String] = []
                while cursor < tokens.count {
                    if case let .identifier(name) = tokens[cursor] {
                        path.append(name)
                        cursor += 1
                        if cursor < tokens.count, tokens[cursor] == .punctuation(".") {
                            cursor += 1
                            continue
                        }
                        // A kind specifier is followed by the module path
                        // rather than by a dot.
                        if path.count == 1, importKinds.contains(name) { continue }
                    }
                    break
                }
                if path.count >= 2, importKinds.contains(path[0]) { path.removeFirst() }
                guard let module = path.first else {
                    fail("an `import` in \(url.lastPathComponent) is followed by something this scan cannot read — extend it, do not bypass it")
                }
                guard !allowedImports.contains(module) else { continue }
                offendingImports.append("\(url.lastPathComponent): import \(path.joined(separator: "."))")
            }
        }
    }

    // A scan that read nothing would pass every assertion below in silence.
    expect(scannedFiles > 0, "the AgentContent import scan read no Swift files — it is looking in the wrong place")
    expect(scannedImports > 0, "the AgentContent import scan found no `import` at all — the lexer or the token match is broken")
    expect(offendingImports.isEmpty,
           "AgentContent must stay platform-neutral (allowed: \(allowedImports.sorted().joined(separator: ", "))) — forbidden import(s): \(offendingImports)")

    print("AgentContent import checks passed: \(scannedImports) import(s) across \(scannedFiles) source file(s) are within {\(allowedImports.sorted().joined(separator: ", "))}")
}

func runAgentContentManifestChecks() {
    // The import scan cannot see a dependency that is declared but not yet
    // imported, and that declaration is the door the coupling walks through.
    // SwiftPM compiles a declared dependency transitively, so "it still builds"
    // proves nothing here either.
    //
    // This does NOT read Package.swift. A manifest is a Swift PROGRAM: it can
    // name a target with a constant, append to `target.dependencies` after
    // constructing it, attach `linkerSettings: [.linkedFramework("AppKit")]`,
    // or leave a clean decoy declaration lying around unused. Every one of
    // those was found by review against a static parse of the file, and no
    // static parse of a Turing-complete program can close that class. So the
    // question is put to SwiftPM instead: `swift package dump-package` emits
    // the EVALUATED manifest, after every mutation, and that JSON is the
    // ground truth checked here.
    //
    // Known limit, deliberately not chased: this is a second evaluation of the
    // manifest, so a manifest written to answer `dump-package` differently from
    // the build that launched this check could still lie to it. Closing that
    // would require the gate to be the build system. These gates exist to stop a
    // future ticket from coupling this module BY MISTAKE, and to make the
    // architecture legible; an author deliberately gaslighting a probe they
    // could equally delete is outside what any in-repo check can hold. What is
    // covered without trusting the manifest at all is the consequence:
    // `runAgentContentBuiltModuleChecks()` reads what the compiler actually
    // consumed.
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("continuum-agentcontent-manifest", isDirectory: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    // A private scratch path: this runs from inside `swift run`, and must not
    // contend with the build that launched it for the package's own .build lock.
    process.arguments = ["swift", "package", "--scratch-path", scratch.path, "dump-package"]
    process.currentDirectoryURL = repoRoot
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    do {
        try process.run()
    } catch {
        fail("cannot run `swift package dump-package`: \(error) — the manifest gate must run, not be skipped")
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let errorText = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fail("`swift package dump-package` exited \(process.terminationStatus): \(errorText)")
    }
    guard let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let targets = manifest["targets"] as? [[String: Any]]
    else {
        fail("`swift package dump-package` produced no decodable target list — the manifest gate must be repaired, not bypassed")
    }

    /// Asserts a target's evaluated description is EXACTLY `expected`. Every key
    /// is compared, and an unexpected key is a failure rather than something to
    /// ignore: `path`, `sources`, `publicHeadersPath` and `pluginUsages` are all
    /// absent from a clean target and all of them can relocate or extend it.
    func expectTarget(_ name: String, matches expected: [String: Any]) {
        let matching = targets.filter { $0["name"] as? String == name }
        guard matching.count == 1 else {
            fail("the evaluated package declares \(matching.count) targets named \(name) — expected exactly one")
        }
        let target = matching[0]
        let unexpected = Set(target.keys).subtracting(expected.keys).sorted()
        expect(unexpected.isEmpty,
               "the evaluated \(name) target carries \(unexpected) — any of those can couple, relocate or extend it (linkerSettings links a framework, plugins generate unscanned sources, path/sources repoint it). Extend this expectation deliberately in the ticket that needs it")
        for (key, value) in expected {
            let actual = target[key]
            let equal = NSDictionary(dictionary: [key: actual ?? NSNull()])
                .isEqual(to: [key: value])
            expect(equal,
                   "the evaluated \(name) target has \(key) = \(actual ?? "nil"), expected \(value) — this is SwiftPM's own view of the manifest, so the declaration really is coupled")
        }
    }

    // AgentContent depends on NOTHING and configures nothing. P2.1 may add
    // Apple's swift-markdown — deliberately, in that ticket, by extending this
    // expectation under review.
    expectTarget("ContinuumRevivedAgentContent", matches: [
        "name": "ContinuumRevivedAgentContent",
        "type": "regular",
        "dependencies": [],
        "settings": [],
        "exclude": [],
        "resources": [],
        "packageAccess": true
    ])

    // …and the check leg links AgentContent ALONE, which is what makes "it
    // compiles" mean "the semantic tree needs nothing else".
    expectTarget("ContinuumRevivedAgentContentChecks", matches: [
        "name": "ContinuumRevivedAgentContentChecks",
        "type": "executable",
        "dependencies": [["byName": ["ContinuumRevivedAgentContent", NSNull()]]],
        "settings": [],
        "exclude": [],
        "resources": [],
        "packageAccess": true
    ])

    try? FileManager.default.removeItem(at: scratch)
    print("AgentContent manifest checks passed: SwiftPM's evaluated package has AgentContent depending on nothing and its check leg on AgentContent alone, across \(targets.count) targets")
}

func runAgentContentBuiltModuleChecks() {
    // The source scan reads text and the manifest scan asks SwiftPM about a
    // re-evaluated manifest. Neither is the built artifact. This leg reads what
    // the COMPILER recorded while producing the module that this very executable
    // is linked against: SwiftPM writes a `.d` dependency file per source file,
    // listing every `.swiftinterface`/`.swiftmodule`/framework header it
    // consumed. A UI framework cannot reach the built module by any route — a
    // source import the lexer misread, a transitive dependency, a
    // plugin-generated source, a manifest that answers `dump-package`
    // differently — without appearing here.
    //
    // The checks target depends on AgentContent, so `swift run` has just rebuilt
    // it: these files describe the current sources, and the freshness assertion
    // below proves it rather than assuming it.
    // Scoped to the directory holding THIS running executable, not to every
    // `.d` under `.build`: that is exactly one build configuration and one
    // destination — the one that produced the AgentContent module this process
    // is linked against. A stale release or other-architecture record can
    // neither fail this leg nor satisfy it.
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
        fail("cannot resolve this executable's own path — the built-module gate must read the build that produced it")
    }
    let buildDirectory = executable
        .deletingLastPathComponent()
        .appendingPathComponent("ContinuumRevivedAgentContent.build", isDirectory: true)
    let dependencyFiles = ((try? FileManager.default.contentsOfDirectory(at: buildDirectory, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "d" }
        .sorted { $0.path < $1.path }
    guard !dependencyFiles.isEmpty else {
        fail("no *.d dependency file in \(buildDirectory.path) — this gate reads what the compiler consumed while building the module this executable links, and must not be skipped")
    }

    var consumed = ""
    for url in dependencyFiles {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            fail("cannot read \(url.path) — the built-module gate is looking in the wrong place")
        }
        consumed += text
    }

    // Freshness: every source file in the module must appear in what the
    // compiler recorded. A stale or partial build would otherwise let this leg
    // pass by describing code that is no longer there.
    let moduleDirectory = repoRoot.appendingPathComponent("Sources/ContinuumRevivedAgentContent", isDirectory: true)
    var sourceNames: [String] = []
    if let walker = FileManager.default.enumerator(at: moduleDirectory, includingPropertiesForKeys: nil) {
        for case let url as URL in walker where url.pathExtension == "swift" {
            sourceNames.append(url.lastPathComponent)
        }
    }
    expect(!sourceNames.isEmpty, "the built-module gate found no AgentContent sources — it is looking in the wrong place")
    let missing = sourceNames.filter { !consumed.contains($0) }
    expect(missing.isEmpty,
           "the compiler's dependency record does not mention \(missing) — the build is stale or partial, so this gate would be describing code that is no longer there")

    // A blocklist here, not an allowlist: Foundation itself legitimately pulls in
    // a toolchain-dependent set (Combine, Dispatch, XPC, Observation, Security…),
    // so enumerating "allowed" would rot with every SDK. What must never appear
    // is a UI framework or another Continuum module.
    let forbiddenModules = [
        "AppKit", "UIKit", "SwiftUI", "Cocoa", "QuartzCore", "CoreAnimation",
        "ContinuumRevivedCore", "ContinuumRevivedSync", "ContinuumRevivedAgentUI",
        "ContinuumRevivedFileTree", "GhosttyKit", "GRDB"
    ]
    let present = forbiddenModules.filter {
        consumed.contains("/\($0).framework/") || consumed.contains("/\($0).swiftmodule")
    }
    expect(present.isEmpty,
           "the BUILT ContinuumRevivedAgentContent module consumed \(present) — this is the compiler's own record of the module this check is linked against, so the platform-neutral boundary really is broken")

    print("AgentContent built-module checks passed: the compiler's record for \(sourceNames.count) source file(s) across \(dependencyFiles.count) dependency file(s) names none of the \(forbiddenModules.count) forbidden modules")
}

runAgentContentModuleChecks()
runAgentContentPlatformNeutralityChecks()
runAgentContentManifestChecks()
runAgentContentBuiltModuleChecks()

// Ticket: docs/38-tickets/91-agent-tile-ux/P1.1-document-schema.md —
// the platform-neutral semantic document vocabulary and its exact JSON shape.
runDocumentSchemaChecks()

// Ticket: docs/38-tickets/91-agent-tile-ux/P1.2-stable-node-identity.md —
// stable child identity, duplicate paths, and revision transitions.
runNodeIdentityChecks()

// Ticket: docs/38-tickets/91-agent-tile-ux/P1.3-mutation-patch-vocabulary.md —
// the only content write vocabulary and stable-ID document patch contract.
runMutationVocabularyChecks()

// Ticket: docs/38-tickets/91-agent-tile-ux/P1.4-document-reducer.md —
// pure indexed mutation application and reconstructible entry lifecycle.
runDocumentReducerChecks()

// Ticket: docs/38-tickets/91-agent-tile-ux/P0.4-transcript-fixture-corpus.md —
// the canonical corpus every later parser, reducer, renderer and migration
// ticket reads from, held to its own declarations, hygiene and I5 rules.
runTranscriptFixtureCorpusChecks()

print("ContinuumRevivedAgentContentChecks passed")
