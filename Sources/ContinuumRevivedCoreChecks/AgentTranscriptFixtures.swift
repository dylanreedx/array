import Foundation

// Ticket: docs/38-tickets/91-agent-tile-ux/P0.4-transcript-fixture-corpus.md
//
// The Core-side reader for the transcript corpus. P0.5 drives the same fixtures
// through `PiEventTranslator` → `AgentRuntimeEvent` → the old cards and the new
// document to assert parity, and that harness lives here because Core owns the
// runtime-event boundary. AgentContent's check target cannot be linked from here
// (it is an executable, and it deliberately links AgentContent alone), so what is
// shared between the two legs is the DATA, not the code: both read the one
// corpus directory, and the gate below is that there is exactly one of them.
//
// Deliberately NOT restated here: the semantic inventory (which blocks and inline
// runs each fixture is for). That lives with the parser it describes, in
// `ContinuumRevivedAgentContentChecks/Fixtures.swift`; a second copy would be a
// second truth that drifts. This file names only what Core needs — the ids, the
// bytes, the sentinel boundary, and the delta sequence.

enum AgentTranscriptFixtures {
    /// The one corpus, addressed from this file so the path is checked by the
    /// compiler's view of the repository layout rather than a working directory.
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()          // ContinuumRevivedCoreChecks
        .deletingLastPathComponent()          // Sources
        .appendingPathComponent("ContinuumRevivedAgentContentChecks", isDirectory: true)
        .appendingPathComponent("Fixtures", isDirectory: true)

    /// Synthetic sentinel secrets. Kept in step with the corpus by the
    /// both-directions assertion in `runAgentTranscriptFixtureChecks()`: they must
    /// appear in exactly one fixture, so a corpus that stopped carrying them (or
    /// started spraying them everywhere) is red here too.
    static let sensitiveSentinels = [
        "CONTINUUM-FIXTURE-SECRET-a1b2c3d4e5f6",
        "CONTINUUM-FIXTURE-PRIVATE-KEY-0f1e2d3c4b5a"
    ]

    static let sentinelBearingFixtureID = "secrets-sentinel"

    /// The ids Core-side checks consume. Fixture ids are test API: renaming one in
    /// the corpus without updating this list is a failure here, which is the point.
    static let required = [
        "prose-plain",
        "prose-rich-inline",
        "fence-open-streaming",
        "malformed-markup",
        "stream-5000-deltas",
        "tool-call-arguments",
        "command-output-long",
        "plan-checklist",
        "diff-unified",
        "error-runner-failure",
        "notice-local",
        "approval-request",
        "user-question",
        "secrets-sentinel"
    ]

    static let streamingFixtureID = "stream-5000-deltas"
    static let streamingDeltaCount = 5_000

    static var fileNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .map { $0.lastPathComponent }
            .sorted()
    }

    static func source(_ id: String) -> String {
        let url = directory.appendingPathComponent("\(id).md", isDirectory: false)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            fputs("FAIL: transcript fixture \(id) missing at \(url.path)\n", stderr)
            Foundation.exit(1)
        }
        return text
    }

    /// The delta sequence a streamed message arrives as. Character-indexed, so a
    /// boundary never lands inside a grapheme cluster, and every delta carries at
    /// least one character.
    static func deltas(_ id: String, count: Int) -> [String] {
        let characters = Array(source(id))
        guard count > 0, characters.count >= count else {
            fputs("FAIL: fixture \(id) has \(characters.count) character(s), too few for \(count) non-empty deltas\n", stderr)
            Foundation.exit(1)
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

func runAgentTranscriptFixtureChecks() {
    // MARK: 1 · the corpus has exactly one home
    //
    // The cheapest way for a later ticket to "share" the corpus is to copy the
    // files next to the check that needs them, at which point the two legs stop
    // describing the same bytes and nothing notices. So: the shared directory
    // must exist, and no copy of any fixture may live anywhere else under
    // `Sources/`. Scoping this to one target would have left the next check
    // suite free to keep its own drifting copy, so the scan covers every target
    // and identifies a copy by CONTENT, two ways:
    //
    //   · byte-identical to any fixture, at any path and under any name — which
    //     catches a copy renamed on the way out of the corpus;
    //   · sharing a fixture's NAME *and* a substantial line of its text verbatim
    //     — the copy that has since DRIFTED, whose bytes no longer match.
    //
    // The name alone is never enough. This ticket does not own the `Sources/`
    // name space, so an unrelated `SomeTarget/Help/approval-request.md` written
    // from scratch is not a corpus copy and must stay green; what makes a file a
    // copy is that the corpus's words are in it.
    //
    // Everything the walk cannot read is recorded and fails the gate. A
    // uniqueness check that treats an unreadable subtree as "no copy here" would
    // be exactly the wrong way to be wrong.
    var isDirectory: ObjCBool = false
    expect(FileManager.default.fileExists(atPath: AgentTranscriptFixtures.directory.path, isDirectory: &isDirectory)
               && isDirectory.boolValue,
           "the shared transcript corpus is missing at \(AgentTranscriptFixtures.directory.path)")

    let names = AgentTranscriptFixtures.fileNames
    expect(names.count >= 19,
           "the shared corpus holds \(names.count) fixture file(s), fewer than the 19 P0.4 established")

    let sourcesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // ContinuumRevivedCoreChecks
        .deletingLastPathComponent()      // Sources
    let canonicalPath = AgentTranscriptFixtures.directory.resolvingSymlinksInPath().path
    // Size-keyed, so the byte comparison below reads at most the files that
    // could possibly be a copy rather than every source file in the package.
    var fixtureBytesBySize: [Int: [Data]] = [:]
    // Lines long enough that sharing one verbatim is not a coincidence. 24
    // characters is past every heading, marker and one-word line in the corpus.
    var fixtureLinesByName: [String: Set<String>] = [:]
    for name in names {
        let text = AgentTranscriptFixtures.source(String(name.dropLast(3)))
        fixtureBytesBySize[Data(text.utf8).count, default: []].append(Data(text.utf8))
        fixtureLinesByName[name] = Set(
            text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 24 }
        )
    }
    for (name, lines) in fixtureLinesByName {
        expect(!lines.isEmpty,
               "fixture \(name) has no line long enough to recognise a drifted copy by — the name+content rule below would never fire for it")
    }

    var copies: [String] = []
    var unreadable: [String] = []
    var scanned = 0
    func relativePath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "")
    }
    let walker = FileManager.default.enumerator(
        at: sourcesRoot,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [],
        errorHandler: { url, error in
            unreadable.append("\(relativePath(url)): \(error.localizedDescription)")
            return true                                // keep walking; the gate fails below
        }
    )
    if let walker {
        for case let url as URL in walker {
            let resolved = url.resolvingSymlinksInPath().path
            if resolved == canonicalPath || resolved.hasPrefix(canonicalPath + "/") { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
                unreadable.append("\(relativePath(url)): cannot read file metadata")
                continue
            }
            guard values.isRegularFile == true else { continue }
            scanned += 1
            let relative = relativePath(url)
            let sharesFixtureName = fixtureLinesByName[url.lastPathComponent] != nil
            let sizeCandidates = values.fileSize.flatMap { fixtureBytesBySize[$0] }
            // Read only what could be a copy: a file carrying a fixture's name, or
            // one whose size matches a fixture exactly.
            guard sharesFixtureName || sizeCandidates != nil else { continue }
            guard let data = try? Data(contentsOf: url) else {
                unreadable.append("\(relative): could be a copy of the corpus but cannot be read")
                continue
            }
            if sizeCandidates?.contains(data) == true {
                copies.append("\(relative) (byte-identical to a fixture)")
                continue
            }
            // Same name, different bytes: a copy that has drifted, if the
            // fixture's own words are still in it.
            if let fixtureLines = fixtureLinesByName[url.lastPathComponent] {
                let shared = Set(String(decoding: data, as: UTF8.self)
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) })
                    .intersection(fixtureLines)
                    .sorted()
                if let firstShared = shared.first {
                    copies.append("\(relative) (named after a fixture and repeats its text: \"\(firstShared)\")")
                }
            }
        }
    } else {
        expect(false, "cannot walk \(sourcesRoot.path) — the one-home scan would be vacuous")
    }
    expect(unreadable.isEmpty,
           "the one-home scan could not read \(unreadable) — an unreadable path is not evidence that the corpus has one home")
    expect(scanned > 0, "the one-home scan visited no file under \(sourcesRoot.path) — it is looking in the wrong place")
    expect(copies.isEmpty,
           "\(copies.sorted()) look like copies of the transcript corpus under Sources/ — the corpus has one home at \(AgentTranscriptFixtures.directory.path); read it, do not duplicate it")

    // MARK: 2 · every id Core-side work depends on is present and non-empty
    let onDisk = Set(names)
    for id in AgentTranscriptFixtures.required {
        expect(onDisk.contains("\(id).md"),
               "the corpus has no fixture \(id) — Core-side checks name it, so a rename must be made here too (fixture ids are test API)")
        let source = AgentTranscriptFixtures.source(id)
        expect(!source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               "fixture \(id) is empty; the Core-side checks reading it would be vacuous")
    }

    // MARK: 3 · the sentinel boundary
    //
    // I5 is about what may cross desktop→phone sync, and the fixtures are what a
    // later ticket will assert the derived projection does NOT carry. That only
    // works if the sentinels sit in exactly one known fixture: everywhere is a
    // leak, nowhere is a vacuous redaction check.
    var bearers: [String] = []
    for name in names {
        let id = String(name.dropLast(3))
        let source = AgentTranscriptFixtures.source(id)
        if AgentTranscriptFixtures.sensitiveSentinels.contains(where: { source.contains($0) }) {
            bearers.append(id)
        }
    }
    expect(bearers == [AgentTranscriptFixtures.sentinelBearingFixtureID],
           "sentinel secrets appear in \(bearers), expected exactly [\(AgentTranscriptFixtures.sentinelBearingFixtureID)]")
    let sentinelSource = AgentTranscriptFixtures.source(AgentTranscriptFixtures.sentinelBearingFixtureID)
    for sentinel in AgentTranscriptFixtures.sensitiveSentinels {
        expect(sentinelSource.contains(sentinel),
               "\(AgentTranscriptFixtures.sentinelBearingFixtureID) no longer carries \(sentinel) — the redaction checks that will read it need every sentinel present")
    }

    // MARK: 4 · the streamed message Core will replay
    let deltas = AgentTranscriptFixtures.deltas(
        AgentTranscriptFixtures.streamingFixtureID,
        count: AgentTranscriptFixtures.streamingDeltaCount
    )
    expect(deltas.count == AgentTranscriptFixtures.streamingDeltaCount,
           "the streaming fixture split into \(deltas.count) deltas, expected \(AgentTranscriptFixtures.streamingDeltaCount)")
    expect(deltas.allSatisfy { !$0.isEmpty }, "the streaming fixture produced an empty delta; a no-op delta is not a stream step")
    expect(deltas.joined() == AgentTranscriptFixtures.source(AgentTranscriptFixtures.streamingFixtureID),
           "the streaming deltas do not reassemble into the fixture source — replaying them would not reproduce the message")

    print("Agent transcript fixture checks passed: \(names.count) shared fixture(s), \(AgentTranscriptFixtures.required.count) required id(s), sentinels confined to \(AgentTranscriptFixtures.sentinelBearingFixtureID), \(deltas.count) replayable delta(s)")
}
