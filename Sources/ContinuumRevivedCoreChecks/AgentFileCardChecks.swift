import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Foundation

// Ticket: TR-01 — file cards and reliable diff counts.
//
// The reported defect was a change card reading "0 files · line counts
// unavailable" for an edit whose absolute path was printed on the same card.
// Three separate things had to be true for that sentence to appear, and each
// one gets a witness here:
//
//   1. Nothing in the app ever computed a line count, for any provider.
//   2. The card's file list was built from the ACTIVITY channel, which carries
//      one target — so a four-file codex change drew one row, and a change
//      whose path never resolved drew none.
//   3. An empty list was rendered as the measurement "0 files" instead of an
//      admission that nothing was recorded.
//
// The counting rules are the fiddly half and are pinned exhaustively: CRLF,
// a missing final newline, an edit anchored in unchanged context, and a
// provider "diff" that is not a diff at all.
func runAgentFileCardChecks() {
    runFileChangeCountingChecks()
    runCodexFileChangeReaderChecks()
    runObservableChangedFilesChecks()
    runCapturedProviderShapeChecks()
    print("AgentFileCard checks passed: measured-or-absent line counts, codex kind/diff parity, per-operation file projection, and the three live-captured provider shapes")
}

/// The three shapes captured live on 2026-09-05, each with the production argv,
/// and each committed as a fixture beside this file:
///
///   codex-cli 0.153.4 `codex exec --json --skip-git-repo-check
///     -c approval_policy=never -c sandbox_mode=workspace-write -m <model> -C <cwd>`
///   pi 0.85.0 `pi -p --mode json --model <id> --thinking low --session-id <id>`
///
/// They settle three questions the earlier hand-written fixtures could not.
private func runCapturedProviderShapeChecks() {
    // 1. Codex exec sends NO diff. The old hand-written parity fixture invented
    //    a `diff` field for `changes[]`; the real stream has path and kind only,
    //    so a live codex card cannot have counts and must not pretend to.
    let execLines = loadFileCardFixture("codex-exec-file-change-live.jsonl")
    let execBox = ObservationBox()
    var exec = CodexEventTranslator(runToken: "captured")
    exec.onRuntimeObservation = execBox.append
    _ = exec.translate(stream: execLines)
    let execChanges = execBox.fileChanges
    expect(execChanges.count == 2,
           "captured codex exec: one file_change item carried TWO files; the card must show both, got \(execChanges.count)")
    expect(execChanges.map(\.action) == [.add, .edit],
           "captured codex exec: kinds drifted, got \(execChanges.map(\.action))")
    expect(execChanges.allSatisfy { !$0.hasAnyMeasuredCount },
           "captured codex exec: the stream carries no diff, so counts must stay unknown rather than be invented")

    // 2. The rollout DOES carry the patch, so a RESTORED codex change can be
    //    measured even though the live one cannot.
    let rollout = loadFileCardFixture("codex-rollout-apply-patch-live.jsonl")
    let restored = CodexSessionTranscriptReader.parse(
        lines: rollout, threadId: "t-codex", now: { Date(timeIntervalSince1970: 0) })
    let restoredChanges = restored.steps.compactMap { step -> AgentToolDetailObservation? in
        guard case let .observation(.toolDetail(_, detail)) = step else { return nil }
        return detail
    }.flatMap(\.fileChanges)
    expect(restoredChanges.count == 2,
           "captured codex rollout: the apply_patch envelope names two files, got \(restoredChanges.count)")
    expect(restoredChanges.first?.action == .edit
               && restoredChanges.first?.addedLines == 2
               && restoredChanges.first?.removedLines == 1,
           "captured codex rollout: the Update section is +2 −1, got \(String(describing: restoredChanges.first))")
    expect(restoredChanges.last?.action == .add
               && restoredChanges.last?.addedLines == 1
               && restoredChanges.last?.removedLines == 0,
           "captured codex rollout: a new file is +1 and a MEASURED −0, got \(String(describing: restoredChanges.last))")

    // 3. Pi's edit carries `edits[{oldText,newText}]` and its write carries
    //    `content` — so pi is measurable after all, which no committed fixture
    //    had ever shown.
    let piLines = loadFileCardFixture("pi-file-edit-live.jsonl")
    let piBox = ObservationBox()
    var pi = PiEventTranslator()
    pi.onRuntimeObservation = piBox.append
    _ = pi.translate(stream: ["{\"type\":\"session\",\"id\":\"captured\",\"cwd\":\"/tmp/fixture\"}",
                              "{\"type\":\"agent_start\"}"] + piLines)
    let piChanges = piBox.fileChanges
    let piEdit = piChanges.first { $0.action == .edit }
    let piWrite = piChanges.first { $0.action == .write }
    expect(piEdit?.addedLines == 2 && piEdit?.removedLines == 1,
           "captured pi edit: 'alpha/beta/delta' → 'ALPHA/beta/delta/gamma' is +2 −1, got \(String(describing: piEdit))")
    expect(piWrite?.addedLines == 1 && piWrite?.removedLines == nil,
           "captured pi write: one written line, and it cannot know what it replaced, got \(String(describing: piWrite))")
}

private func loadFileCardFixture(_ name: String) -> [String] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
        .appendingPathComponent(name)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        expect(false, "missing captured fixture \(name)")
        return []
    }
    return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

private func runFileChangeCountingChecks() {
    // A trailing newline TERMINATES the last line; it does not begin an empty
    // one. Both of these are two lines in every editor a user has ever opened.
    expect(AgentFileChangeCounting.lineCount("a\nb") == 2,
           "lineCount: text without a final newline lost its last line")
    expect(AgentFileChangeCounting.lineCount("a\nb\n") == 2,
           "lineCount: a terminating newline invented a phantom line")
    expect(AgentFileChangeCounting.lineCount("") == 0, "lineCount: empty text is zero lines")
    expect(AgentFileChangeCounting.lineCount("solo") == 1, "lineCount: one unterminated line is one line")

    // CRLF. Swift reads "\r\n" as ONE Character, so a Character-wise scan for
    // "\n" finds nothing and reports a whole CRLF file as a single line. This
    // is the assertion that forces the scalar-wise implementation.
    expect(AgentFileChangeCounting.lineCount("a\r\nb\r\n") == 2,
           "lineCount: CRLF text must count its line breaks, got \(AgentFileChangeCounting.lineCount("a\r\nb\r\n"))")
    expect(AgentFileChangeCounting.lineCount("a\r\nb") == 2,
           "lineCount: CRLF text without a final newline must keep its last line")

    // A one-line change inside an unchanged anchor is +1 −1, the way git says
    // it — not "+3 −3" because the tool call quoted three lines of context.
    let anchored = AgentFileChangeCounting.replacementCounts(
        old: "keep\nchange me\ntail", new: "keep\nchanged\ntail")
    expect(anchored?.added == 1 && anchored?.removed == 1,
           "replacementCounts: unchanged context must be peeled off, got \(String(describing: anchored))")

    // The shape that made the cheap version wrong, captured from pi: the first
    // line changes AND a line is appended, so there is no common prefix and no
    // common suffix — but the middle is untouched and must not be counted.
    let bothEnds = AgentFileChangeCounting.replacementCounts(
        old: "alpha\nbeta\ndelta\n", new: "ALPHA\nbeta\ndelta\ngamma\n")
    expect(bothEnds?.added == 2 && bothEnds?.removed == 1,
           "replacementCounts: an untouched middle must not count as rewritten, got \(String(describing: bothEnds))")

    let pureInsert = AgentFileChangeCounting.replacementCounts(old: "a\nb", new: "a\nnew\nb")
    expect(pureInsert?.added == 1 && pureInsert?.removed == 0,
           "replacementCounts: an insertion removes nothing, got \(String(describing: pureInsert))")
    let pureDelete = AgentFileChangeCounting.replacementCounts(old: "a\ngone\nb", new: "a\nb")
    expect(pureDelete?.added == 0 && pureDelete?.removed == 1,
           "replacementCounts: a deletion adds nothing, got \(String(describing: pureDelete))")
    let identical = AgentFileChangeCounting.replacementCounts(old: "same", new: "same")
    expect(identical?.added == 0 && identical?.removed == 0,
           "replacementCounts: an unchanged replacement is zero, got \(String(describing: identical))")

    // Too large to diff inside the budget: unknown, never an overcount. The
    // card prints these as measurements.
    let huge = (0..<600).map(String.init).joined(separator: "\n")
    let hugeOther = (0..<600).map { String($0 * 7) }.joined(separator: "\n")
    expect(AgentFileChangeCounting.replacementCounts(old: huge, new: hugeOther) == nil,
           "replacementCounts: a replacement past the diff budget must be unknown, not approximated")

    // A unified diff counts its content lines and ignores its file headers.
    let unified = AgentFileChangeCounting.unifiedDiffCounts(
        "--- a/x.swift\n+++ b/x.swift\n@@ -1,2 +1,3 @@\n context\n-old\n+new\n+extra\n")
    expect(unified?.added == 2 && unified?.removed == 1,
           "unifiedDiffCounts: +++/--- headers must not count as content, got \(String(describing: unified))")

    // And a body that is NOT a unified diff yields nothing rather than a
    // fabricated "+1 −0". This is the literal shape the committed codex
    // app-server capture carries in `changes[].diff`.
    expect(AgentFileChangeCounting.unifiedDiffCounts("edited\n") == nil,
           "unifiedDiffCounts: a body with no hunk header must be unknown, not counted")
    expect(AgentFileChangeCounting.unifiedDiffCounts("") == nil,
           "unifiedDiffCounts: empty text must be unknown")
}

/// Collects the host-local side channel the way the tile does.
private final class ObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AgentRuntimeObservation] = []
    func append(_ value: AgentRuntimeObservation) { lock.withLock { values.append(value) } }
    var fileChanges: [AgentToolDetailObservation.FileChange] {
        lock.withLock {
            values.compactMap { observation -> AgentToolDetailObservation? in
                guard case let .toolDetail(_, detail) = observation else { return nil }
                return detail
            }.flatMap(\.fileChanges)
        }
    }
}

private func runCodexFileChangeReaderChecks() {
    // Driven through the REAL translators, not their shared helper: the defect
    // this pins was a translator reading the wire wrongly, so a witness that
    // called the helper directly would agree with itself about a shape codex
    // does not send.

    // exec's string kind, plus a multi-file change. Every file survives; a
    // delete with no diff stays uncounted rather than claiming −0.
    let execBox = ObservationBox()
    var exec = CodexEventTranslator(runToken: "tr01")
    exec.onRuntimeObservation = execBox.append
    _ = exec.translate(stream: [
        #"{"type":"thread.started","thread_id":"tr01"}"#,
        #"{"type":"turn.started"}"#,
        #"{"type":"item.started","item":{"id":"i1","type":"file_change","status":"in_progress","changes":[{"path":"a.swift","kind":"update","diff":"@@ -1 +1,2 @@\n-old\n+new\n+more\n"},{"path":"b.swift","kind":"delete"},{"path":"c.swift","new_path":"d.swift","kind":"rename"}]}}"#,
    ])
    let execChanges = execBox.fileChanges
    expect(execChanges.count == 3,
           "codex exec: every changed file of one operation must reach the host, got \(execChanges.count)")
    expect(execChanges.map(\.action) == [.edit, .delete, .rename],
           "codex exec: string kinds drifted, got \(execChanges.map(\.action))")
    expect(execChanges[0].addedLines == 2 && execChanges[0].removedLines == 1,
           "codex exec: unified diff counts drifted, got \(String(describing: execChanges[0].addedLines))/\(String(describing: execChanges[0].removedLines))")
    expect(execChanges[1].addedLines == nil && execChanges[1].removedLines == nil,
           "codex exec: a delete with no diff must stay uncounted, never −0")
    expect(execChanges[2].renamePath == "d.swift", "codex exec: rename destination lost")

    // app-server's OBJECT kind — `{"type":"add"}`, verbatim from the committed
    // capture `Fixtures/codex-appserver-single-agent.jsonl`. Both translators
    // read `kind` as a String before this ticket, so EVERY app-server file
    // change reported an unknown action while the capture that proves the shape
    // sat in the checks fixtures.
    let appServerBox = ObservationBox()
    var appServer = CodexAppServerEventTranslator()
    appServer.onRuntimeObservation = appServerBox.append
    _ = appServer.translate(stream: [
        #"{"method":"item/started","params":{"threadId":"t","turnId":"u","item":{"id":"i1","type":"fileChange","status":"inProgress","changes":[{"path":"note.txt","kind":{"type":"add"},"diff":"edited\n"}]}}}"#,
    ])
    let appServerChanges = appServerBox.fileChanges
    expect(appServerChanges.map(\.action) == [.add],
           "codex app-server: object-shaped kind must resolve, got \(appServerChanges.map(\.action))")
    expect(appServerChanges.first?.addedLines == nil,
           "codex app-server: `\"edited\\n\"` is not a unified diff and must not produce counts")
}

private func runObservableChangedFilesChecks() {
    var record = AgentToolDetailRecord(
        identity: AgentToolDetailKey(
            scope: AgentToolDetailScope(
                agentID: "agent", threadID: "thread", turnID: "turn", provider: "runtime")!,
            providerItemID: "item"),
        updatedAt: Date())

    // The two host-local sources describe ONE operation: `affectedFiles` has
    // the full URL (from the activity channel, which carries a single target),
    // `fileChanges` has every file but only a basename. The card is built from
    // the join; from `affectedFiles` alone it showed one row of four.
    record.affectedFiles = [URL(fileURLWithPath: "/repo/Sources/App/Main.swift")]
    record.fileChanges = [
        .init(action: .edit, path: "Main.swift", addedLines: 4, removedLines: 2),
        .init(action: .add, path: "New.swift"),
        .init(action: .delete, path: "Old.swift"),
    ]
    let files = AgentToolDetailPresenter.observableChangedFiles(record)
    expect(files.count == 3,
           "observableChangedFiles: every file of one operation must appear, got \(files.count)")
    expect(files[0].displayName == "…/App/Main.swift",
           "observableChangedFiles: the richer URL display must win over the basename, got \(files[0].displayName)")
    expect(files[0].addedLineCount == 4 && files[0].removedLineCount == 2,
           "observableChangedFiles: measured counts must reach the card")
    expect(files[1].displayName == "New.swift" && files[1].action == .add,
           "observableChangedFiles: a file with no matching URL keeps its safe basename and action")
    expect(files[2].action == .delete && !files[2].hasAnyKnownCount,
           "observableChangedFiles: an unmeasured delete must carry no counts")

    // Same basename, different directories: two rows, and each URL is consumed
    // once. Collapsing these was explicitly out of scope — they are distinct
    // files, exactly as two edits to one path are distinct operations.
    var collision = record
    collision.affectedFiles = [
        URL(fileURLWithPath: "/repo/web/index.ts"),
        URL(fileURLWithPath: "/repo/api/index.ts"),
    ]
    collision.fileChanges = [
        .init(action: .edit, path: "index.ts"),
        .init(action: .edit, path: "index.ts"),
    ]
    let collided = AgentToolDetailPresenter.observableChangedFiles(collision)
    expect(collided.map(\.displayName) == ["…/web/index.ts", "…/api/index.ts"],
           "observableChangedFiles: same-basename files must stay distinct rows, got \(collided.map(\.displayName))")

    // A record with nothing but an affected file still names it — that is the
    // pre-existing behavior and it must not regress.
    var activityOnly = record
    activityOnly.fileChanges = []
    activityOnly.affectedFiles = [URL(fileURLWithPath: "/repo/Sources/Only.swift")]
    expect(AgentToolDetailPresenter.observableChangedFiles(activityOnly).map(\.displayName)
           == ["…/Sources/Only.swift"],
           "observableChangedFiles: an activity-only record must still name its file")

    // And an empty record produces an EMPTY list, never a fabricated row. The
    // renderer turns this into "Files not recorded"; inventing a placeholder
    // here would put the lie one layer deeper instead of removing it.
    var empty = record
    empty.fileChanges = []
    empty.affectedFiles = []
    expect(AgentToolDetailPresenter.observableChangedFiles(empty).isEmpty,
           "observableChangedFiles: nothing known must stay nothing")
}
