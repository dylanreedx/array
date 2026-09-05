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
    print("AgentFileCard checks passed: measured-or-absent line counts, codex kind/diff parity, per-operation file projection")
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
    expect(anchored == (added: 1, removed: 1),
           "replacementCounts: unchanged context must be peeled off, got \(anchored)")

    let pureInsert = AgentFileChangeCounting.replacementCounts(old: "a\nb", new: "a\nnew\nb")
    expect(pureInsert == (added: 1, removed: 0),
           "replacementCounts: an insertion removes nothing, got \(pureInsert)")
    let pureDelete = AgentFileChangeCounting.replacementCounts(old: "a\ngone\nb", new: "a\nb")
    expect(pureDelete == (added: 0, removed: 1),
           "replacementCounts: a deletion adds nothing, got \(pureDelete)")
    let identical = AgentFileChangeCounting.replacementCounts(old: "same", new: "same")
    expect(identical == (added: 0, removed: 0),
           "replacementCounts: an unchanged replacement is zero, got \(identical)")

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
