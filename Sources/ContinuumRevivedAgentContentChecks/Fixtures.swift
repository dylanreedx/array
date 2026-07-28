import Foundation

// Ticket: docs/38-tickets/91-agent-tile-ux/P0.4-transcript-fixture-corpus.md
//
// The canonical transcript corpus. Every later parser, reducer, renderer and
// migration ticket reads its source material from here instead of inventing a
// toy string at the top of its own check, so "the parser handles nested quotes"
// and "the renderer handles nested quotes" are statements about the SAME bytes.
//
// Two things are deliberate.
//
// 1. THE TEXT LIVES IN FILES, the metadata lives here. A 12 KB streamed message
//    inside a Swift literal is unreadable in a diff and tempting to trim; as a
//    file it is reviewable, and the packet's fence names `Fixtures/*.md` for
//    exactly that reason. The fixture's id IS its filename stem, so there is no
//    second place for the two to disagree, and the directory itself is checked
//    against the declarations in both directions below — a file nobody declared
//    and a declaration with no file are equally red.
//
// 2. STRUCTURED RECORDS ARE NOT MARKDOWN (`_DESIGN.md` locked decision 2). A
//    tool call, plan, diff, approval, question, error and notice are typed
//    blocks; their payload text is fixture material, but the KIND comes from the
//    fixture's declared form, never from a marker the parser would have to sniff
//    out of prose. `TranscriptFixtureForm` makes that split explicit and
//    `runTranscriptFixtureCorpusChecks()` gates it: a markup fixture may not
//    claim a structured kind, and a structured payload may not claim inline
//    markup runs. Those files carry the `.md` extension because the packet
//    fences the corpus to `*.md`; their contents are raw payload text, not
//    Markdown, and the form says so.
//
// Fixture ids are test API. Renaming one is a visible, deliberate diff in this
// file, in the file system, and in `ContinuumRevivedCoreChecks`, which names the
// ids it needs (see `AgentTranscriptFixtures.swift`).

/// How a fixture's bytes reach the semantic document.
enum TranscriptFixtureForm: Equatable {
    /// Provider-authored assistant/user text that may contain Markdown. The
    /// parser owns what blocks come out of it.
    case markup
    /// The raw body of ONE typed structured block. The kind is declared, not
    /// parsed: nothing in this text is a signal a Markdown parser should read.
    case structuredPayload(kind: String)
}

struct TranscriptFixture {
    /// Stable test API. Equals the fixture file's name without `.md`.
    let id: String
    let form: TranscriptFixtureForm
    /// The high-level semantic inventory this fixture is here to exercise. Not
    /// an exact AST — P2.x pins exact trees against these same files.
    let expectedBlockKinds: [String]
    /// Inline runs the fixture is here to exercise. Empty for structured
    /// payloads, which are not markup.
    let expectedInlineKinds: [String]
    /// True only for the redaction fixture(s): they carry synthetic sentinel
    /// secrets so a redaction path can be proven to remove something.
    let mayContainSensitiveSentinel: Bool
    /// Set on the streaming fixture: the number of deltas it must be splittable
    /// into for the coalescing budget checks.
    let minimumDeltaCount: Int?
    let note: String

    var fileName: String { "\(id).md" }

    /// Read from disk on every access. Fixture files are small and the corpus is
    /// read a handful of times per run; caching would only add a way for a check
    /// to be looking at bytes that are no longer on disk.
    var source: String { TranscriptFixtureCorpus.source(forFile: fileName) }
}

enum TranscriptFixtureCorpus {
    /// Resolved from this file rather than the working directory, so a check run
    /// from elsewhere reads the real corpus or fails, never an empty one.
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    static func source(forFile fileName: String) -> String {
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            fail("transcript fixture missing or unreadable at \(url.path)")
        }
        return text
    }

    /// Synthetic secrets, in a shape no real provider issues, so a scanner
    /// pointed at this repository never reports a live credential and a
    /// redaction check still has something concrete to remove.
    static let sensitiveSentinels = [
        "CONTINUUM-FIXTURE-SECRET-a1b2c3d4e5f6",
        "CONTINUUM-FIXTURE-PRIVATE-KEY-0f1e2d3c4b5a"
    ]

    /// Every built-in block family named in `_DESIGN.md` §6. The corpus must
    /// cover all of them; that is what makes it canonical rather than a
    /// convenient subset.
    static let requiredBlockFamilies: Set<String> = [
        "paragraph", "heading", "list", "listItem", "quote", "thematicBreak",
        "codeBlock", "toolCall", "commandOutput", "plan", "diff",
        "approval", "question", "error", "notice", "unknown"
    ]

    /// The semantic inline runs from `_DESIGN.md` §6.
    static let requiredInlineRuns: Set<String> = [
        "text", "emphasis", "strong", "inlineCode", "link", "softBreak", "hardBreak"
    ]

    /// Kinds a Markdown parser may legitimately produce from provider text.
    static let markupBlockKinds: Set<String> = [
        "paragraph", "heading", "list", "listItem", "quote", "thematicBreak",
        "codeBlock", "unknown"
    ]

    /// Kinds that only ever arrive as typed records. A markup fixture claiming
    /// one of these would mean the corpus had started smuggling structure
    /// through the parser.
    static let structuredBlockKinds: Set<String> = [
        "toolCall", "commandOutput", "plan", "diff",
        "approval", "question", "error", "notice"
    ]

    static let all: [TranscriptFixture] = [
        TranscriptFixture(
            id: "prose-plain",
            form: .markup,
            expectedBlockKinds: ["paragraph"],
            expectedInlineKinds: ["text", "softBreak"],
            mayContainSensitiveSentinel: false,
            minimumDeltaCount: nil,
            note: "The ordinary reading path: two paragraphs, no marks."
        ),
        TranscriptFixture(
            id: "prose-rich-inline",
            form: .markup,
            expectedBlockKinds: ["paragraph"],
            expectedInlineKinds: [
                "text", "emphasis", "strong", "inlineCode", "link", "softBreak", "hardBreak"
            ],
            mayContainSensitiveSentinel: false,
            minimumDeltaCount: nil,
            note: "Every inline run in one message, including both break kinds."
        ),
        TranscriptFixture(
            id: "headings-sections",
            form: .markup,
            expectedBlockKinds: ["heading", "paragraph", "thematicBreak"],
            expectedInlineKinds: ["text"],
            mayContainSensitiveSentinel: false,
            minimumDeltaCount: nil,
            note: "Three heading levels and a rule, for hierarchy and section spacing."
        ),
        TranscriptFixture(
            id: "nested-lists",
            form: .markup,
            expectedBlockKinds: ["list", "listItem", "paragraph"],
            expectedInlineKinds: ["text"],
            mayContainSensitiveSentinel: false,
            minimumDeltaCount: nil,
            note: "Ordered outer list, nested unordered items, and a loose item with a paragraph."
        ),
        TranscriptFixture(
            id: "quotes-nested",
            form: .markup,
            expectedBlockKinds: ["quote", "paragraph", "list", "listItem"],
            expectedInlineKinds: ["text"],
            mayContainSensitiveSentinel: false,
            minimumDeltaCount: nil,
            note: "A quote containing a list and a second-level quote."
        ),
        TranscriptFixture(
            id: "fence-closed-code",
            form: .markup,
            expectedBlockKinds: ["paragraph", "codeBlock"],
            expectedInlineKinds: ["text"],
            mayContainSensitiveSentinel: false,
            minimumDeltaCount: nil,
            note: "One fence with a language, one without."
        ),
        TranscriptFixture(
            id: "fence-open-streaming",
            form: .markup,
            expectedBlockKinds: ["paragraph", "codeBlock"],
            expectedInlineKinds: ["text"],
            mayContainSensitiveSentinel: false,
            minimumDeltaCount: nil,
            note: "An unterminated fence: code-in-progress must render, never vanish (§7)."
        ),
        TranscriptFixture(
            id: "links-policy",
            form: .markup,
            expectedBlockKinds: ["paragraph"],
            expectedInlineKinds: ["text", "link", "inlineCode"],
            mayContainSensitiveSentinel: false,
            minimumDeltaCount: nil,
            note: "Inline, titled, autolinked, bare, relative, empty, and code-quoted URLs for P2.6."
        ),
        TranscriptFixture(
            id: "malformed-markup",
            form: .markup,
            expectedBlockKinds: ["paragraph", "unknown", "codeBlock"],
            expectedInlineKinds: ["text"],
            mayContainSensitiveSentinel: false,
            minimumDeltaCount: nil,
            note: "Unbalanced emphasis, an unclosed link, raw HTML, a broken table, a stray fence."
        ),
        TranscriptFixture(
            id: "stream-5000-deltas",
            form: .markup,
            expectedBlockKinds: ["paragraph"],
            expectedInlineKinds: ["text"],
            mayContainSensitiveSentinel: false,
            minimumDeltaCount: 5_000,
            note: "Long enough to be split into 5,000 deltas for the coalescing budget."
        ),
        TranscriptFixture(
            id: "tool-call-arguments",
            form: .structuredPayload(kind: "toolCall"),
            expectedBlockKinds: ["toolCall"],
            expectedInlineKinds: [],
            mayContainSensitiveSentinel: false,
            minimumDeltaCount: nil,
            note: "A typed tool call's arguments, synthetic workspace paths only."
        ),
        TranscriptFixture(
            id: "command-output-long",
            form: .structuredPayload(kind: "commandOutput"),
            expectedBlockKinds: ["commandOutput"],
            expectedInlineKinds: [],
            mayContainSensitiveSentinel: false,
            minimumDeltaCount: nil,
            note: "Five kilobytes of build log: collapsing, truncation and reuse under length."
        ),
        TranscriptFixture(
            id: "plan-checklist",
            form: .structuredPayload(kind: "plan"),
            expectedBlockKinds: ["plan"],
            expectedInlineKinds: [],
            mayContainSensitiveSentinel: false,
            minimumDeltaCount: nil,
            note: "A plan with done and pending steps."
        ),
        TranscriptFixture(
            id: "diff-unified",
            form: .structuredPayload(kind: "diff"),
            expectedBlockKinds: ["diff"],
            expectedInlineKinds: [],
            mayContainSensitiveSentinel: false,
            minimumDeltaCount: nil,
            note: "A two-file unified diff with hunk headers, additions and removals."
        ),
        TranscriptFixture(
            id: "error-runner-failure",
            form: .structuredPayload(kind: "error"),
            expectedBlockKinds: ["error"],
            expectedInlineKinds: [],
            mayContainSensitiveSentinel: false,
            minimumDeltaCount: nil,
            note: "A typed failure with its recovery sentence."
        ),
        TranscriptFixture(
            id: "notice-local",
            form: .structuredPayload(kind: "notice"),
            expectedBlockKinds: ["notice"],
            expectedInlineKinds: [],
            mayContainSensitiveSentinel: false,
            minimumDeltaCount: nil,
            note: "A local notice: detach is a view lifecycle event, not an agent one."
        ),
        TranscriptFixture(
            id: "approval-request",
            form: .structuredPayload(kind: "approval"),
            expectedBlockKinds: ["approval"],
            expectedInlineKinds: [],
            mayContainSensitiveSentinel: false,
            minimumDeltaCount: nil,
            note: "A pending decision with its command, reason and choices."
        ),
        TranscriptFixture(
            id: "user-question",
            form: .structuredPayload(kind: "question"),
            expectedBlockKinds: ["question"],
            expectedInlineKinds: [],
            mayContainSensitiveSentinel: false,
            minimumDeltaCount: nil,
            note: "A question back to the owner, with choices."
        ),
        TranscriptFixture(
            id: "secrets-sentinel",
            form: .structuredPayload(kind: "toolCall"),
            expectedBlockKinds: ["toolCall"],
            expectedInlineKinds: [],
            mayContainSensitiveSentinel: true,
            minimumDeltaCount: nil,
            note: "Tool arguments carrying synthetic sentinel secrets, for redaction and I5."
        )
    ]

    static func fixture(_ id: String) -> TranscriptFixture {
        guard let match = all.first(where: { $0.id == id }) else {
            fail("no transcript fixture with id \(id) — fixture ids are test API; a rename must update every caller")
        }
        return match
    }

    /// Splits a fixture's source into exactly `count` non-empty deltas that
    /// concatenate back to the source. Character-indexed, so a delta boundary
    /// never lands inside a grapheme cluster.
    static func deltas(for fixture: TranscriptFixture, count: Int) -> [String] {
        let characters = Array(fixture.source)
        guard count > 0, characters.count >= count else {
            fail("fixture \(fixture.id) has \(characters.count) character(s), too few for \(count) non-empty deltas")
        }
        var deltas: [String] = []
        deltas.reserveCapacity(count)
        var start = 0
        for index in 0..<count {
            let end = characters.count * (index + 1) / count
            deltas.append(String(characters[start..<end]))
            start = end
        }
        return deltas
    }
}

// MARK: - Corpus gates

/// Text that must never appear in the corpus: a real home path, a real machine's
/// identity, an address, or anything shaped like a live credential. Fixtures are
/// written, never captured, so any hit here means a real transcript was pasted in.
private let forbiddenCorpusSubstrings = [
    "/Users/", "/home/", "/var/folders/", ".ssh/", "id_rsa", "id_ed25519",
    "-----BEGIN", "xoxb-", "xoxp-", "ghp_", "gho_", "github_pat_",
    "AKIA", "ASIA", "AIza", "eyJ"
]

/// Credential shapes that need a boundary to avoid firing on ordinary words
/// (`sk-` is inside "task-"), plus an address.
private let forbiddenCorpusPatterns = [
    "(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{8,}",
    "[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\\.[A-Za-z]{2,}"
]

private func matches(_ pattern: String, in text: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
        fail("the corpus scan cannot compile its own pattern \(pattern)")
    }
    return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

/// A marker every fixture declaring the given kind must actually contain. This
/// is what stops the declared inventory from being a comment: deleting the fence
/// out of the code fixture, or the hunk header out of the diff, contradicts the
/// metadata instead of quietly making a later parser check weaker.
///
/// Only unambiguous markers are listed. `paragraph`, `unknown`, `emphasis` and
/// the structured prose kinds (`approval`, `error`, …) have no syntax of their
/// own, so no probe can honestly assert them; they are covered by the parser and
/// renderer tickets that consume these files.
private let kindMarkers: [String: String] = [
    "heading": "^#{1,6} ",
    "list": "^[ \t>]*([-*+]|[0-9]+\\.) ",
    "quote": "^>",
    "thematicBreak": "^(-{3,}|\\*{3,}|_{3,})[ \t]*$",
    "codeBlock": "^```",
    "plan": "^- \\[[ x]\\] ",
    "diff": "^@@ ",
    "commandOutput": "^\\$ ",
    "toolCall": "\"arguments\"",
    "strong": "\\*\\*[^*]+\\*\\*",
    "inlineCode": "`[^`]+`",
    "link": "\\]\\(|<https?://",
    "hardBreak": "[^ ]  $"
]

func runTranscriptFixtureCorpusChecks() {
    let fixtures = TranscriptFixtureCorpus.all
    expect(fixtures.count >= 19,
           "the corpus declares \(fixtures.count) fixtures, fewer than the 19 P0.4 established — a fixture was dropped rather than deliberately replaced")

    // MARK: 1 · the directory and the declarations are the same set
    let onDisk = Set(
        ((try? FileManager.default.contentsOfDirectory(at: TranscriptFixtureCorpus.directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .map { $0.lastPathComponent }
    )
    expect(!onDisk.isEmpty, "no fixture files at \(TranscriptFixtureCorpus.directory.path) — the corpus scan is looking in the wrong place")
    let declared = Set(fixtures.map(\.fileName))
    expect(declared == onDisk,
           "the corpus directory and its declarations disagree — declared-but-missing: \(declared.subtracting(onDisk).sorted()), present-but-undeclared: \(onDisk.subtracting(declared).sorted())")

    var seenIDs: Set<String> = []
    for fixture in fixtures {
        expect(seenIDs.insert(fixture.id).inserted, "duplicate fixture id \(fixture.id)")
        expect(matches("^[a-z0-9]+(-[a-z0-9]+)*$", in: fixture.id),
               "fixture id \(fixture.id) is not lower-case kebab — ids are test API and must stay predictable")
        let source = fixture.source
        expect(!source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               "fixture \(fixture.id) is empty — an empty fixture makes every check that reads it vacuous")
        expect(!source.contains("\r"), "fixture \(fixture.id) contains a carriage return; the corpus is LF-only")
        expect(source.hasSuffix("\n"), "fixture \(fixture.id) does not end with a newline")
    }

    // MARK: 2 · every built-in family and inline run is covered
    let coveredBlocks = Set(fixtures.flatMap(\.expectedBlockKinds))
    let missingBlocks = TranscriptFixtureCorpus.requiredBlockFamilies.subtracting(coveredBlocks).sorted()
    expect(missingBlocks.isEmpty,
           "the corpus covers no fixture for block famil(ies) \(missingBlocks) — _DESIGN.md §6 names them as built-in")
    let unknownBlocks = coveredBlocks
        .subtracting(TranscriptFixtureCorpus.requiredBlockFamilies)
        .sorted()
    expect(unknownBlocks.isEmpty,
           "the corpus declares block kind(s) \(unknownBlocks) that are not built-in families — add them to _DESIGN.md's list deliberately, do not invent them in a fixture")

    let coveredInlines = Set(fixtures.flatMap(\.expectedInlineKinds))
    let missingInlines = TranscriptFixtureCorpus.requiredInlineRuns.subtracting(coveredInlines).sorted()
    expect(missingInlines.isEmpty,
           "the corpus covers no fixture for inline run(s) \(missingInlines)")
    let unknownInlines = coveredInlines.subtracting(TranscriptFixtureCorpus.requiredInlineRuns).sorted()
    expect(unknownInlines.isEmpty, "the corpus declares inline run(s) \(unknownInlines) that are not in _DESIGN.md §6")

    // MARK: 3 · structure never travels as Markdown (locked decision 2)
    for fixture in fixtures {
        switch fixture.form {
        case .markup:
            let smuggled = Set(fixture.expectedBlockKinds).intersection(TranscriptFixtureCorpus.structuredBlockKinds).sorted()
            expect(smuggled.isEmpty,
                   "markup fixture \(fixture.id) claims structured kind(s) \(smuggled) — a typed record must not be encoded as Markdown for a parser to sniff out (_DESIGN.md decision 2)")
        case let .structuredPayload(kind):
            expect(TranscriptFixtureCorpus.structuredBlockKinds.contains(kind),
                   "fixture \(fixture.id) declares structured payload kind \(kind), which is not a typed structured kind")
            expect(fixture.expectedBlockKinds == [kind],
                   "structured fixture \(fixture.id) holds one typed block's payload, so its inventory must be exactly [\(kind)], not \(fixture.expectedBlockKinds)")
            expect(fixture.expectedInlineKinds.isEmpty,
                   "structured fixture \(fixture.id) claims inline runs \(fixture.expectedInlineKinds) — its payload is raw text, not markup")
        }
    }

    // MARK: 4 · the declared inventory is visible in the bytes
    var probes = 0
    for fixture in fixtures {
        for kind in fixture.expectedBlockKinds + fixture.expectedInlineKinds {
            guard let marker = kindMarkers[kind] else { continue }
            probes += 1
            expect(matches(marker, in: fixture.source),
                   "fixture \(fixture.id) declares \(kind) but its text contains no \(kind) marker (/\(marker)/) — the declaration and the file disagree")
        }
    }
    expect(probes >= 19, "only \(probes) inventory probe(s) ran — the marker table has been gutted")
    // …and every marker in the table is exercised by some fixture, so a marker
    // can neither rot unused nor silently stop applying to the corpus.
    let probedKinds = Set(fixtures.flatMap { $0.expectedBlockKinds + $0.expectedInlineKinds })
    let unexercised = Set(kindMarkers.keys).subtracting(probedKinds).sorted()
    expect(unexercised.isEmpty,
           "marker(s) \(unexercised) are declared but no fixture claims that kind — either the corpus lost coverage or the marker is dead")

    // A soft break is a line break inside a paragraph, which has no marker of
    // its own: two adjacent non-blank lines are the whole signal.
    for fixture in fixtures where fixture.expectedInlineKinds.contains("softBreak") {
        let lines = fixture.source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let hasContinuation = zip(lines, lines.dropFirst()).contains { first, second in
            !first.trimmingCharacters(in: .whitespaces).isEmpty
                && !second.trimmingCharacters(in: .whitespaces).isEmpty
        }
        expect(hasContinuation,
               "fixture \(fixture.id) declares softBreak but has no paragraph that continues onto the next line")
    }

    // MARK: 5 · hygiene and I5
    //
    // The corpus is written material about a synthetic repository. Nothing in it
    // may name this machine, this account, an address, or a credential shape —
    // both because a fixture is not a place to leak one and because these files
    // are read by checks that assert what may cross the phone-sync boundary.
    var dynamicNeedles: [(String, String)] = [
        ("this machine's home directory", NSHomeDirectory()),
        ("this account's user name", NSUserName()),
        ("this machine's host name", ProcessInfo.processInfo.hostName)
    ]
    // A needle too short or too generic would fire on prose; drop it rather than
    // weaken the check for everything else, and say so.
    dynamicNeedles = dynamicNeedles.filter { $0.1.count >= 5 }
    expect(!dynamicNeedles.isEmpty, "no usable machine-identity needle — the hygiene scan would be vacuous")

    for fixture in fixtures {
        let source = fixture.source
        for needle in forbiddenCorpusSubstrings {
            expect(!source.contains(needle),
                   "fixture \(fixture.id) contains \(needle) — the corpus must be synthetic, with no real path or credential shape")
        }
        for pattern in forbiddenCorpusPatterns {
            expect(!matches(pattern, in: source),
                   "fixture \(fixture.id) matches /\(pattern)/ — the corpus must carry no address and no live-looking credential")
        }
        for (label, needle) in dynamicNeedles {
            expect(!source.contains(needle),
                   "fixture \(fixture.id) contains \(label) — a real transcript was pasted into the corpus")
        }

        // Both directions: an undeclared sentinel is a leak, and a declared one
        // that is not there is a redaction check with nothing to redact.
        let carriesSentinel = TranscriptFixtureCorpus.sensitiveSentinels.contains { source.contains($0) }
        expect(carriesSentinel == fixture.mayContainSensitiveSentinel,
               fixture.mayContainSensitiveSentinel
                   ? "fixture \(fixture.id) is declared to carry a sentinel secret but contains none — the redaction checks reading it would pass vacuously"
                   : "fixture \(fixture.id) carries a sentinel secret without declaring it — every fixture holding one must be marked so redaction and I5 checks can find it")
    }
    let sentinelBearers = fixtures.filter(\.mayContainSensitiveSentinel).map(\.id)
    expect(!sentinelBearers.isEmpty,
           "no fixture carries a sentinel secret — redaction has nothing to prove against")

    // MARK: 6 · the streaming fixture really splits
    let streaming = fixtures.filter { $0.minimumDeltaCount != nil }
    expect(!streaming.isEmpty, "no streaming fixture — the coalescing budget has no source material")
    for fixture in streaming {
        let count = fixture.minimumDeltaCount!
        expect(count >= 5_000,
               "streaming fixture \(fixture.id) declares only \(count) deltas; P0.4 requires at least 5,000")
        let deltas = TranscriptFixtureCorpus.deltas(for: fixture, count: count)
        expect(deltas.count == count, "\(fixture.id) split into \(deltas.count) deltas, expected \(count)")
        expect(deltas.allSatisfy { !$0.isEmpty }, "\(fixture.id) produced an empty delta; a no-op delta is not a stream step")
        expect(deltas.joined() == fixture.source,
               "\(fixture.id) deltas do not reassemble into the fixture source — the split loses or duplicates text")
    }

    print("Transcript fixture corpus checks passed: \(fixtures.count) fixtures cover \(TranscriptFixtureCorpus.requiredBlockFamilies.count) block famil(ies) and \(TranscriptFixtureCorpus.requiredInlineRuns.count) inline run(s), \(probes) inventory probe(s), \(sentinelBearers.count) sentinel-bearing fixture(s), \(streaming.count) streaming fixture(s)")
}
