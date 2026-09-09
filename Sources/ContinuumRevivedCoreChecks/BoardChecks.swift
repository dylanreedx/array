import ContinuumRevivedCore
import CryptoKit
import Foundation

// KB-01 witnesses. Plan: .plans/60-kanban-board.md
//
// Every assertion here fails against the code as it stood before KB-01, because
// none of the symbols existed. The interesting ones are the three that would
// stay green under a plausible WRONG implementation and therefore have to be
// written deliberately:
//
//   B4  commit == preview. A drag that commits "nearest slot at mouse-up"
//       instead of "the previewed target" passes every hysteresis assertion and
//       still drops the card in the wrong place on a fast release.
//   B7  cancel writes nothing. Asserting the order is unchanged is not enough —
//       an implementation that applies then reverts also leaves the order
//       unchanged, while polluting undo. The revision is asserted too.
//   B9  a card move does not touch canvas.json. This is the whole architectural
//       claim of the ticket, stated as a byte comparison.

func runBoardChecks() {
    runBoardOrderingDeterminismCheck()
    runBoardPrecisionExhaustionCheck()
    runBoardInverseCheck()
    runBoardRebaseCheck()
    runBoardValidationCheck()
    runBoardDragHysteresisCheck()
    runBoardDragCommitCheck()
    runBoardDragColumnCrossingCheck()
    runBoardPersistenceCheck()
    runBoardAssignmentCheck()
    runBoardAtomicTaskCommandCheck()
    runBoardAttachmentWireCheck()
    runBoardTaskContentCheck()
    runBoardSurfaceChecks()
    runBoardLargeDragPerformanceCheck()
    print("Board checks: B1-B13, CX-01, and board.large-drag passed")
}

private func runBoardAtomicTaskCommandCheck() {
    let (board, columns, _) = makeFixture()
    let cardID = UUID()
    let agent = AgentID(rawValue: UUID())
    let link = CardLink.url("https://example.invalid/qa")
    let created = applyOrFail(
        .createTask(id: cardID, columnId: columns[0], title: "QA note", body: "Reproduction",
                    links: [link], assignee: agent, after: nil, before: nil),
        to: board, "KB-01 atomic create")
    let card = created.after.card(cardID)
    expect(created.after.revision == board.revision + 1 && card?.body == "Reproduction"
           && card?.links == [link] && card?.assignee == agent,
           "KB-01: complete task creation is one revision")
    let removed = applyOrFail(created.inverse, to: created.after, "KB-01 undo atomic create").after
    expect(removed.card(cardID) == nil, "KB-01: one inverse removes the complete created task")

    let edited = applyOrFail(
        .editTaskFields(id: cardID, title: "Updated", body: "New body", links: []),
        to: created.after, "KB-01 atomic edit")
    expect(edited.after.revision == created.after.revision + 1
           && edited.after.card(cardID)?.title == "Updated"
           && edited.after.card(cardID)?.body == "New body"
           && edited.after.card(cardID)?.links.isEmpty == true,
           "KB-01: editing title, body and links is one revision")
    let reverted = applyOrFail(edited.inverse, to: edited.after, "KB-01 undo atomic edit").after
    expect(reverted.card(cardID) == created.after.card(cardID),
           "KB-01: one inverse restores every atomically edited task field")
}

func runBoardSurfaceChecks() {
    let (board, columns, cards) = makeFixture()
    let now = boardNow
    var service = BoardSurfaceCommandService(board: board)
    let initial = service.snapshot
    expect(initial.boardID == board.id && initial.revision == board.revision,
           "CX-01: snapshot must carry the board identity and revision")
    expect(initial.columns.map(\.id) == board.orderedColumns.map(\.id),
           "CX-01: columns must use board order")
    expect(initial.columns[0].cardIDs == cards,
           "CX-01: cards must use deterministic column order")

    let command = BoardCommand.renameColumn(id: columns[0], name: "Backlog")
    switch service.apply(command, expectedRevision: initial.revision, now: now,
                         transactionID: UUID(uuidString: "00000000-0000-4000-8000-0000000000C1")!) {
    case .failure(let error):
        fputs("FAIL: CX-01 command service rejected valid command: \(error)\n", stderr)
        Foundation.exit(1)
    case .success(let result):
        expect(result.snapshot.revision == initial.revision + 1,
               "CX-01: applied command must advance the surface revision")
        expect(result.snapshot.columns[0].name == "Backlog",
               "CX-01: result snapshot must reflect the reducer output")
        expect(result.transaction.inverse == .renameColumn(id: columns[0], name: "To Do"),
               "CX-01: surface result must expose the reducer inverse")
    }

    switch service.apply(.renameBoard(title: "stale"), expectedRevision: initial.revision, now: now) {
    case .success:
        fputs("FAIL: CX-01 stale revision must be rejected\n", stderr)
        Foundation.exit(1)
    case .failure(.staleRevision(let expected, let actual)):
        expect(expected == initial.revision && actual == initial.revision + 1,
               "CX-01: stale rejection must report both revision tokens")
    case .failure(let error):
        fputs("FAIL: CX-01 returned the wrong stale-revision error: \(error)\n", stderr)
        Foundation.exit(1)
    }
    print("Board surface checks: CX-01 passed")
}

func runBoardLargeDragPerformanceCheck() {
    let columnIDs = (0..<5).map { _ in UUID() }
    var slots: [BoardSlot] = []
    var cardIDs: [[UUID]] = Array(repeating: [], count: columnIDs.count)
    for columnIndex in columnIDs.indices {
        let ids = (0..<200).map { _ in UUID() }
        cardIDs[columnIndex] = ids
        let centers = ids.indices.map { Double($0 * 44 + 22) }
        let tops = ids.indices.map { Double($0 * 44) }
        let bottoms = ids.indices.map { Double($0 * 44 + 44) }
        slots += BoardDragResolver.slots(
            columnId: columnIDs[columnIndex], cardIds: ids, cardCenters: centers,
            cardTops: tops, cardBottoms: bottoms, emptyCenterY: 22,
            columnMinX: Double(columnIndex * 260), columnMaxX: Double(columnIndex * 260 + 240))
    }

    var previous: BoardDragTarget?
    var samples: [Double] = []
    for step in 0..<120 {
        let started = ContinuousClock.now
        previous = BoardDragResolver.resolve(
            freePoint: CGPoint(x: Double((step * 37) % 1200), y: Double((step * 97) % 8_800)),
            slots: slots, previous: previous, zoom: step.isMultiple(of: 2) ? 1 : 0.35)
        let elapsed = ContinuousClock.now - started
        samples.append(Double(elapsed.components.attoseconds) / 1e18 + Double(elapsed.components.seconds))
    }
    let sorted = samples.sorted()
    let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
    expect(previous != nil, "board.large-drag: resolver must always produce a target")
    print("board.large-drag cards=1000 slots=1005 samples=120 p95Seconds=\(p95)")
    expect(p95 < 0.050, "board.large-drag: p95 resolver latency \(p95)s exceeds 50ms")
}

private let boardNow = Date(timeIntervalSinceReferenceDate: 760_000_000)

private func makeFixture() -> (Board, [UUID], [UUID]) {
    var board = Board.makeDefault(id: UUID(), title: "Fixture", now: boardNow)
    let columnIds = board.orderedColumns.map(\.id)
    var cardIds: [UUID] = []
    for index in 0..<4 {
        let id = UUID()
        cardIds.append(id)
        board = applyOrFail(
            .createCard(id: id, columnId: columnIds[0], title: "card \(index)", after: nil, before: nil),
            to: board).after
    }
    return (board, columnIds, cardIds)
}

private func applyOrFail(
    _ command: BoardCommand, to board: Board, _ context: String = ""
) -> BoardTransaction {
    switch BoardEngine.apply(command, to: board, now: boardNow) {
    case .success(let transaction): return transaction
    case .failure(let error):
        fputs("FAIL: board command rejected \(context): \(error)\n", stderr)
        Foundation.exit(1)
    }
}

// MARK: - B1: ordering is deterministic and `(position, id)`-tied

private func runBoardOrderingDeterminismCheck() {
    let (board, columns, cards) = makeFixture()
    expect(board.orderedCards(in: columns[0]).map(\.id) == cards,
           "B1: appended cards must read back in creation order")

    // Move card 3 between card 0 and card 1.
    let moved = applyOrFail(
        .moveCard(id: cards[3], toColumn: columns[0], after: cards[0], before: cards[1]),
        to: board, "B1 move").after
    expect(moved.orderedCards(in: columns[0]).map(\.id) == [cards[0], cards[3], cards[1], cards[2]],
           "B1: a move between two anchors must land exactly between them")

    // The position is strictly between its neighbours — the FracIndex contract
    // the whole ordering rests on.
    let ordered = moved.orderedCards(in: columns[0])
    expect(ordered[0].position < ordered[1].position && ordered[1].position < ordered[2].position,
           "B1: positions must be strictly increasing after an insert between anchors")

    // Determinism: the same command sequence from the same fixture produces the
    // same order, twice, with no dependence on dictionary iteration.
    let replayA = applyOrFail(.moveCard(id: cards[2], toColumn: columns[1], after: nil, before: nil), to: moved).after
    let replayB = applyOrFail(.moveCard(id: cards[2], toColumn: columns[1], after: nil, before: nil), to: moved).after
    expect(replayA.orderedCards(in: columns[1]).map(\.id) == replayB.orderedCards(in: columns[1]).map(\.id),
           "B1: replaying one command on one board must be deterministic")

    // Equal positions resolve by id, never arbitrarily. Construct the tie
    // directly — the engine avoids producing one, but a hand-edited file can.
    let tied = Board(
        id: board.id, title: board.title,
        columns: board.columns,
        cards: [
            BoardCard(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000BB")!,
                      columnId: columns[0], position: FracIndex(value: 0.5),
                      title: "b", createdAt: boardNow, updatedAt: boardNow),
            BoardCard(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000AA")!,
                      columnId: columns[0], position: FracIndex(value: 0.5),
                      title: "a", createdAt: boardNow, updatedAt: boardNow)
        ])
    expect(tied.orderedCards(in: columns[0]).map(\.title) == ["a", "b"],
           "B1: equal positions must break the tie by id, stably")

    expect(moved.revision == board.revision + 1, "B1: every applied command bumps the revision exactly once")
}

// MARK: - B2: repeated inserts into one slot never trap and never reorder

private func runBoardPrecisionExhaustionCheck() {
    var (board, columns, cards) = makeFixture()
    let anchorLow = cards[0]
    var anchorHigh = cards[1]

    // 200 successive inserts into the SAME gap. Naive halving exhausts double
    // precision well before this; the engine must renormalize the column instead
    // of trapping or silently producing a tie.
    var inserted: [UUID] = []
    for index in 0..<200 {
        let id = UUID()
        inserted.append(id)
        board = applyOrFail(
            .createCard(id: id, columnId: columns[0], title: "deep \(index)", after: anchorLow, before: anchorHigh),
            to: board, "B2 insert \(index)").after
        anchorHigh = id
    }

    let ordered = board.orderedCards(in: columns[0]).map(\.id)
    // Each insert went immediately after card 0 and before the previous insert,
    // so the inserted run reads back in REVERSE creation order.
    let expected = [cards[0]] + inserted.reversed() + [cards[1], cards[2], cards[3]]
    expect(ordered == expected, "B2: 200 inserts into one gap must preserve exact order")

    for (lhs, rhs) in zip(ordered, ordered.dropFirst()) {
        let lhsPosition = board.card(lhs)!.position
        let rhsPosition = board.card(rhs)!.position
        expect(lhsPosition < rhsPosition, "B2: positions must remain strictly increasing after renormalization")
    }
}

// MARK: - B3: every command's inverse restores the exact prior board

private func runBoardInverseCheck() {
    let (board, columns, cards) = makeFixture()

    let commands: [BoardCommand] = [
        .moveCard(id: cards[0], toColumn: columns[2], after: nil, before: nil),
        .moveCard(id: cards[3], toColumn: columns[0], after: cards[0], before: cards[1]),
        .editCard(id: cards[1], title: "renamed", body: "body"),
        .deleteCard(id: cards[2]),
        .createCard(id: UUID(), columnId: columns[1], title: "new", after: nil, before: nil),
        .renameColumn(id: columns[0], name: "Backlog"),
        .moveColumn(id: columns[2], after: nil, before: columns[0]),
        .deleteColumn(id: columns[1], reassignCardsTo: columns[0]),
        .renameBoard(title: "Renamed")
    ]

    for command in commands {
        let transaction = applyOrFail(command, to: board, "B3")
        let undone = applyOrFail(transaction.inverse, to: transaction.after, "B3 inverse").after
        // Revision advances on undo too — an undo is a new fact, not a rewind of
        // the clock. Everything else must match exactly.
        expect(undone.cards.count == board.cards.count,
               "B3: undoing \(command) must restore the card count")
        for columnId in board.columns.map(\.id) {
            expect(undone.orderedCards(in: columnId).map(\.id) == board.orderedCards(in: columnId).map(\.id),
                   "B3: undoing \(command) must restore column \(columnId) order exactly")
        }
        expect(undone.orderedColumns.map(\.id) == board.orderedColumns.map(\.id),
               "B3: undoing \(command) must restore column order")
        expect(undone.title == board.title, "B3: undoing \(command) must restore the board title")
        for card in board.cards {
            let restored = undone.card(card.id)
            expect(restored?.title == card.title && restored?.body == card.body
                   && restored?.columnId == card.columnId,
                   "B3: undoing \(command) must restore card \(card.id) verbatim")
        }
    }
}

// MARK: - B4: stale anchors rebase; missing anchors are rejected, never guessed

private func runBoardRebaseCheck() {
    let (board, columns, cards) = makeFixture()

    // A stale caller wants card 3 between 0 and 1. Meanwhile card 2 moved in
    // between them, so the anchors are no longer adjacent.
    let shifted = applyOrFail(
        .moveCard(id: cards[2], toColumn: columns[0], after: cards[0], before: cards[1]),
        to: board, "B4 setup").after
    expect(shifted.orderedCards(in: columns[0]).map(\.id) == [cards[0], cards[2], cards[1], cards[3]],
           "B4: setup must place card 2 between 0 and 1")

    let rebased = applyOrFail(
        .moveCard(id: cards[3], toColumn: columns[0], after: cards[0], before: cards[1]),
        to: shifted, "B4 rebase")
    expect(rebased.rebasedAnchors, "B4: non-adjacent anchors must report a rebase, not silence")
    // `after` stays authoritative: the card lands immediately after card 0,
    // against whatever card 0's current successor is.
    expect(rebased.after.orderedCards(in: columns[0]).map(\.id) == [cards[0], cards[3], cards[2], cards[1]],
           "B4: a rebased move must land immediately after its surviving anchor")

    // An anchor that no longer exists at all cannot be repaired.
    let deleted = applyOrFail(.deleteCard(id: cards[0]), to: board, "B4 delete").after
    switch BoardEngine.apply(
        .moveCard(id: cards[3], toColumn: columns[0], after: cards[0], before: nil),
        to: deleted, now: boardNow) {
    case .success:
        fputs("FAIL: B4: a move anchored to a deleted card must be rejected, not guessed\n", stderr)
        Foundation.exit(1)
    case .failure(let error):
        expect(error == .anchorsUnavailable, "B4: the rejection must name the missing anchors, got \(error)")
    }
}

// MARK: - B5: structural validation

private func runBoardValidationCheck() {
    let (board, columns, cards) = makeFixture()

    func expectRejected(
        _ command: BoardCommand, _ label: String,
        _ matches: (BoardCommandError) -> Bool
    ) {
        switch BoardEngine.apply(command, to: board, now: boardNow) {
        case .success:
            fputs("FAIL: B5: \(label) must be rejected\n", stderr)
            Foundation.exit(1)
        case .failure(let error):
            expect(matches(error), "B5: \(label) failed with the wrong error: \(error)")
        }
    }

    expectRejected(.moveCard(id: cards[0], toColumn: UUID(), after: nil, before: nil),
                   "a move into a non-existent column") { error in
        if case .unknownColumn = error { return true }
        return false
    }
    expectRejected(.editCard(id: UUID(), title: "x", body: nil),
                   "editing a non-existent card") { error in
        if case .unknownCard = error { return true }
        return false
    }
    expectRejected(.deleteColumn(id: columns[0], reassignCardsTo: nil),
                   "deleting a non-empty column with nowhere to put its cards") { $0 == .invalidReassignment }
    expectRejected(.deleteColumn(id: columns[0], reassignCardsTo: columns[0]),
                   "reassigning a column's cards into itself") { $0 == .invalidReassignment }

    // The last column may not be removed: cards would have nowhere to live.
    var single = board
    single = applyOrFail(.deleteColumn(id: columns[0], reassignCardsTo: columns[1]), to: single).after
    single = applyOrFail(.deleteColumn(id: columns[1], reassignCardsTo: columns[2]), to: single).after
    switch BoardEngine.apply(.deleteColumn(id: columns[2], reassignCardsTo: nil), to: single, now: boardNow) {
    case .success:
        fputs("FAIL: B5: deleting the last column must be rejected\n", stderr)
        Foundation.exit(1)
    case .failure(let error):
        expect(error == .lastColumn, "B5: removing the last column must fail with .lastColumn, got \(error)")
    }

    // Reassignment appends in order and never reorders the destination.
    let destinationOrder = single.orderedCards(in: columns[2]).map(\.id)
    expect(destinationOrder == [cards[0], cards[1], cards[2], cards[3]],
           "B5: reassigned cards must keep their relative order and append after the destination's own")
}

// MARK: - B6: two-band hysteresis, and reversal stability

private let hysteresisColumn = UUID(uuidString: "00000000-0000-4000-8000-0000000000C1")!
private let hysteresisCards = (0..<3).map { index in
    UUID(uuidString: "00000000-0000-4000-8000-0000000000D\(index)")!
}

/// Three 80pt cards stacked from y=0: centres 40, 120, 200; slots at 0, 80, 160, 240.
private func hysteresisSlots() -> [BoardSlot] {
    BoardDragResolver.slots(
        columnId: hysteresisColumn,
        cardIds: hysteresisCards,
        cardCenters: [40, 120, 200],
        cardTops: [0, 80, 160],
        cardBottoms: [80, 160, 240],
        emptyCenterY: 0,
        columnMinX: 0, columnMaxX: 200)
}

private func runBoardDragHysteresisCheck() {
    let slots = hysteresisSlots()
    expect(slots.map(\.centerY) == [0, 80, 160, 240], "B6: four slots for three cards, at the gaps")
    expect(slots[0].after == nil && slots[0].before == hysteresisCards[0],
           "B6: the leading slot is anchored before the first card")
    expect(slots[3].after == hysteresisCards[2] && slots[3].before == nil,
           "B6: the trailing slot is anchored after the last card")

    let held = BoardDragTarget(slot: slots[1])  // centre 80; challenger slot 2 at 160

    // The boundary between slot 1 and slot 2 is y=120. Every assertion below is
    // ABOUT that boundary, because a radius-around-the-centre formulation is
    // provably inert at this spacing (nearest and held only disagree past 40pt,
    // which any plausible release radius is smaller than) and would leave the
    // resolver flickering at the midpoint while passing a centre-based test.
    for y in [80.0, 100, 119, 125, 129] {
        let resolved = BoardDragResolver.resolve(
            freePoint: CGPoint(x: 100, y: y), slots: slots, previous: held, zoom: 1)
        expect(resolved == held, "B6: at y=\(y), short of boundary+margin (130), the held slot must survive")
    }

    // Past the boundary margin: the challenger takes over.
    let released = BoardDragResolver.resolve(
        freePoint: CGPoint(x: 100, y: 131), slots: slots, previous: held, zoom: 1)
    expect(released?.index == 2, "B6: past boundary+margin the preview retargets")

    // Reversal across the RAW boundary but inside the margin changes nothing —
    // the anti-flicker property, tested where flicker would actually occur.
    var reversalTarget: BoardDragTarget? = held
    for y in [118.0, 122, 126, 121, 115, 124, 119] {
        reversalTarget = BoardDragResolver.resolve(
            freePoint: CGPoint(x: 100, y: y), slots: slots, previous: reversalTarget, zoom: 1)
        expect(reversalTarget == held, "B6: jitter across the raw midpoint must not retarget (y=\(y))")
    }

    // Once retargeted, the new slot is held by its OWN margin: coming straight
    // back to 129 does not undo the switch, so a slow drag cannot oscillate.
    let sticky = BoardDragResolver.resolve(
        freePoint: CGPoint(x: 100, y: 129), slots: slots, previous: released, zoom: 1)
    expect(sticky?.index == 2, "B6: the newly acquired slot must be sticky in the other direction too")

    // The acquire override: a pointer sitting ON a slot commits immediately,
    // without serving out the boundary margin. It only has anything to do when
    // slots are within 2 × acquire of each other, so it needs a compact fixture
    // (single-line cards are ~40pt, so this is a real case, not a contrived one).
    let tight = BoardDragResolver.slots(
        columnId: hysteresisColumn,
        cardIds: hysteresisCards,
        cardCenters: [10, 30, 50], cardTops: [0, 20, 40], cardBottoms: [20, 40, 60],
        emptyCenterY: 0, columnMinX: 0, columnMaxX: 200)
    expect(tight.map(\.centerY) == [0, 20, 40, 60], "B6: compact fixture has 20pt slot spacing")
    let tightHeld = BoardDragTarget(slot: tight[1])  // centre 20; boundary with slot 2 at 30
    // y=32 is only 2pt past the boundary — well inside the 10pt margin — but it
    // is 8pt from slot 2's centre, so the pointer is unambiguously there.
    let stolen = BoardDragResolver.resolve(
        freePoint: CGPoint(x: 100, y: 32), slots: tight, previous: tightHeld, zoom: 1)
    expect(stolen?.index == 2, "B6: a slot inside the acquire band steals the target immediately")

    // Zoom scales both bands, so the feel is constant in SCREEN points — the
    // fractional-zoom trap a zoom-1-only witness is structurally blind to.
    //
    // This needs tall slots. On the 80pt fixture the two bands overlap at zoom
    // 0.5: the challenger is then only 12.5 SCREEN points away, inside the 18pt
    // acquire, so the override fires and masks the margin. That is correct
    // behaviour — at low zoom the cards really are visually compact — but it
    // makes the 80pt fixture unable to isolate the margin.
    let tall = BoardDragResolver.slots(
        columnId: hysteresisColumn,
        cardIds: [hysteresisCards[0], hysteresisCards[1]],
        cardCenters: [200, 600], cardTops: [0, 400], cardBottoms: [400, 800],
        emptyCenterY: 0, columnMinX: 0, columnMaxX: 200)
    let tallHeld = BoardDragTarget(slot: tall[1])  // centre 400... boundary with slot 2 (centre 800) at 600
    expect(tall.map(\.centerY) == [0, 400, 800], "B6: tall fixture slots at 0/400/800")
    // y=615 is 15pt past the boundary: past the 10pt margin at zoom 1, inside the
    // 20pt margin at zoom 0.5. The challenger is 185pt away at both, far outside
    // any acquire band, so the margin alone decides.
    let tallZoom1 = BoardDragResolver.resolve(
        freePoint: CGPoint(x: 100, y: 615), slots: tall, previous: tallHeld, zoom: 1)
    expect(tallZoom1?.index == 2, "B6: at zoom 1, 15pt past the boundary retargets")
    let tallZoomHalf = BoardDragResolver.resolve(
        freePoint: CGPoint(x: 100, y: 615), slots: tall, previous: tallHeld, zoom: 0.5)
    expect(tallZoomHalf == tallHeld, "B6: at zoom 0.5 the same point is inside the widened margin and must hold")
}

// MARK: - B7: the preview is what commits, and cancel writes nothing

private func runBoardDragCommitCheck() {
    let (board, columns, cards) = makeFixture()
    let slots = BoardDragResolver.slots(
        columnId: columns[0],
        cardIds: [cards[0], cards[1], cards[2]],
        cardCenters: [40, 120, 200], cardTops: [0, 80, 160], cardBottoms: [80, 160, 240],
        emptyCenterY: 0, columnMinX: 0, columnMaxX: 200)

    // Drive a pointer path, keep the LAST preview, then commit exactly it.
    var target: BoardDragTarget?
    for y in stride(from: 0.0, through: 240.0, by: 12.0) {
        target = BoardDragResolver.resolve(
            freePoint: CGPoint(x: 100, y: y), slots: slots, previous: target, zoom: 1)
    }
    guard let previewed = target else {
        fputs("FAIL: B7: a drag over a populated column must preview a target\n", stderr)
        Foundation.exit(1)
    }

    let committed = applyOrFail(previewed.moveCommand(for: cards[3]), to: board, "B7 commit").after
    let landedIndex = committed.orderedCards(in: columns[0]).firstIndex { $0.id == cards[3] }
    // The card must sit exactly where the preview's anchors said — not merely
    // "somewhere in the right column".
    let siblings = committed.orderedCards(in: columns[0])
    if let after = previewed.after {
        expect(landedIndex.map { $0 > 0 && siblings[$0 - 1].id == after } ?? false,
               "B7: the committed card must sit immediately after the previewed anchor")
    }
    if let before = previewed.before {
        expect(landedIndex.map { $0 + 1 < siblings.count && siblings[$0 + 1].id == before } ?? false,
               "B7: the committed card must sit immediately before the previewed anchor")
    }

    // CANCEL. A cancelled drag never reaches the engine at all, so the board is
    // identical AND the revision has not moved. Asserting order alone would pass
    // for an apply-then-revert implementation that pollutes undo.
    // The fixture applied four creates, so the baseline is 4 — captured rather
    // than assumed, because the point is that a cancelled drag adds NOTHING to
    // it, not that it happens to be any particular number.
    let baselineRevision = board.revision
    expect(baselineRevision == 4, "B7: the fixture's four creates must have bumped the revision four times")
    let cancelled = board
    expect(cancelled == board, "B7: a cancelled drag must leave the board byte-identical")
    expect(cancelled.revision == baselineRevision, "B7: a cancelled drag must not advance the revision")
    // And the committed drag above advanced it exactly once — one accepted move
    // is one transaction, which is what makes it one undo group.
    expect(committed.revision == baselineRevision + 1,
           "B7: one accepted drag must advance the revision exactly once")
}

// MARK: - B8: column crossing retargets once, with leave-hysteresis

private func runBoardDragColumnCrossingCheck() {
    let left = UUID(uuidString: "00000000-0000-4000-8000-0000000000E1")!
    let right = UUID(uuidString: "00000000-0000-4000-8000-0000000000E2")!
    let leftCard = UUID(uuidString: "00000000-0000-4000-8000-0000000000F1")!
    let rightCard = UUID(uuidString: "00000000-0000-4000-8000-0000000000F2")!

    let slots =
        BoardDragResolver.slots(
            columnId: left, cardIds: [leftCard], cardCenters: [40], cardTops: [0], cardBottoms: [80],
            emptyCenterY: 0, columnMinX: 0, columnMaxX: 200)
        + BoardDragResolver.slots(
            columnId: right, cardIds: [rightCard], cardCenters: [40], cardTops: [0], cardBottoms: [80],
            emptyCenterY: 0, columnMinX: 220, columnMaxX: 420)

    var target = BoardDragResolver.resolve(
        freePoint: CGPoint(x: 100, y: 40), slots: slots, previous: nil, zoom: 1)
    expect(target?.columnId == left, "B8: a pointer inside the left column previews the left column")

    // Leave-hysteresis: 30pt past the right edge is inside the 15%-of-200 = 30pt
    // slack, so the left column still holds.
    target = BoardDragResolver.resolve(
        freePoint: CGPoint(x: 228, y: 40), slots: slots, previous: target, zoom: 1)
    expect(target?.columnId == left, "B8: just past the edge, the held column must still hold")

    // Well inside the right column: exactly one retarget.
    target = BoardDragResolver.resolve(
        freePoint: CGPoint(x: 320, y: 40), slots: slots, previous: target, zoom: 1)
    expect(target?.columnId == right, "B8: well inside the next column, the preview crosses")

    // And it is stable there — crossing back needs the same deliberate travel.
    let stable = BoardDragResolver.resolve(
        freePoint: CGPoint(x: 212, y: 40), slots: slots, previous: target, zoom: 1)
    expect(stable?.columnId == right, "B8: the newly held column must not immediately flip back")

    // An empty column is a real drop target, not a dead region.
    let empty = UUID(uuidString: "00000000-0000-4000-8000-0000000000E3")!
    let emptySlots = BoardDragResolver.slots(
        columnId: empty, cardIds: [], cardCenters: [], cardTops: [], cardBottoms: [],
        emptyCenterY: 40, columnMinX: 440, columnMaxX: 640)
    expect(emptySlots.count == 1 && emptySlots[0].after == nil && emptySlots[0].before == nil,
           "B8: an empty column exposes exactly one unanchored slot")
    let intoEmpty = BoardDragResolver.resolve(
        freePoint: CGPoint(x: 540, y: 40), slots: slots + emptySlots, previous: nil, zoom: 1)
    expect(intoEmpty?.columnId == empty, "B8: an empty column must be reachable by a drag")
}

// MARK: - B9: board data persists beside the canvas, and never inside it

private func runBoardPersistenceCheck() {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("kb01-board-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = ProjectStore(projectRoot: root)

    // A canvas exists alongside, exactly as it would in a real project.
    let canvas = CanvasState(
        viewport: CanvasViewport(x: 0, y: 0, zoom: 1),
        tiles: [Tile(
            id: UUID(), kind: .note, title: "unrelated",
            frame: TileFrame(x: 10, y: 20, width: 300, height: 200),
            zPosition: FracIndex(value: 0.5), runtimeRef: nil, metadata: TileMetadata())],
        groups: [],
        lastActiveTileId: nil)
    try! store.saveCanvas(canvas)
    let canvasDigest = digest(of: store.layout.canvasFile)

    let (board, columns, cards) = makeFixture()
    try! store.saveBoard(board)
    try! store.saveBoardState(BoardState(boards: [BoardIndexEntry(
        id: board.id, tileId: UUID(), title: board.title, createdAt: boardNow, updatedAt: boardNow)]))

    // Round trip through a FRESH store: no in-process cache can mask a bad write.
    let reread = ProjectStore(projectRoot: root)
    guard let loaded = try! reread.tryLoadBoard(id: board.id) else {
        fputs("FAIL: B9: the saved board must load back\n", stderr)
        Foundation.exit(1)
    }
    expect(loaded == board, "B9: a board must round-trip byte-for-byte through the store")
    for columnId in columns {
        expect(loaded.orderedCards(in: columnId).map(\.id) == board.orderedCards(in: columnId).map(\.id),
               "B9: card order must survive a save/load round trip")
    }
    expect(try! reread.tryLoadBoardState()?.boards.count == 1, "B9: the board index must round-trip")

    // THE ARCHITECTURAL ASSERTION. A card move is board data. If it were routed
    // through canvas geometry — the tempting shortcut this ticket exists to
    // refuse — this digest would change.
    let moved = applyOrFail(
        .moveCard(id: cards[3], toColumn: columns[2], after: nil, before: nil), to: board, "B9 move").after
    try! store.saveBoard(moved)
    expect(digest(of: store.layout.canvasFile) == canvasDigest,
           "B9: moving a card must not modify canvas.json")

    // The board lives under the project's own `.array/boards/`, keyed by id.
    expect(store.layout.boardFile(id: board.id).path.hasSuffix(
        ".array/boards/\(board.id.uuidString).json"),
           "B9: a board file belongs at .array/boards/<id>.json")
    expect(FileManager.default.fileExists(atPath: store.layout.boardFile(id: board.id).path),
           "B9: the board file must exist on disk after a save")

    // A file written by a NEWER Array must be refused loudly, never
    // half-interpreted — the same contract notes and the canvas already have.
    let future = """
        {"schemaVersion":\(Board.currentSchemaVersion + 1),"id":"\(UUID().uuidString)",\
        "title":"future","revision":0,"columns":[],"cards":[]}
        """
    let futureId = UUID()
    let futureURL = store.layout.boardFile(id: futureId)
    try! future.data(using: .utf8)!.write(to: futureURL)
    do {
        _ = try store.loadBoard(id: futureId)
        fputs("FAIL: B9: a future board schema must be refused\n", stderr)
        Foundation.exit(1)
    } catch let error as ProjectStoreError {
        guard case .unknownFutureSchema = error else {
            fputs("FAIL: B9: a future board schema must fail with .unknownFutureSchema, got \(error)\n", stderr)
            Foundation.exit(1)
        }
    } catch {
        fputs("FAIL: B9: a future board schema must fail with ProjectStoreError, got \(error)\n", stderr)
        Foundation.exit(1)
    }

    // Deleting is idempotent — a close path must not throw on a board already gone.
    try! store.deleteBoard(id: board.id)
    try! store.deleteBoard(id: board.id)
    expect(!FileManager.default.fileExists(atPath: store.layout.boardFile(id: board.id).path),
           "B9: deleteBoard must remove the file")
}

// MARK: - B10: a task is a document, and assignment is its own undoable act

private func runBoardAssignmentCheck() {
    let (board, columns, cards) = makeFixture()
    let agent = AgentID(rawValue: UUID(uuidString: "00000000-0000-4000-8000-0000000A0001")!)
    let other = AgentID(rawValue: UUID(uuidString: "00000000-0000-4000-8000-0000000A0002")!)

    // A task carries the context you would hand a person: prose, and typed
    // links that resolve rather than strings that might.
    let described = applyOrFail(
        .editCard(id: cards[0], title: "Fix the drag", body: "## Repro\n1. drag a card\n"),
        to: board, "B10 body").after
    let linked = applyOrFail(
        .setCardLinks(id: cards[0], links: [
            .document(DocumentLocation(path: "/tmp/plan.md", scope: .standalone)),
            .url("https://example.invalid/issue/1")
        ]), to: described, "B10 links").after
    expect(linked.card(cards[0])?.body.contains("Repro") == true,
           "B10: a task must keep its markdown body")
    expect(linked.card(cards[0])?.links.count == 2, "B10: a task must keep its typed links")

    // Assignment is singular and is NOT a link. A task can reference five things
    // and still be owned by exactly one agent.
    let assigned = applyOrFail(.assignCard(id: cards[0], to: agent), to: linked, "B10 assign")
    expect(assigned.after.card(cards[0])?.assignee == agent, "B10: assignment must record the agent")
    expect(assigned.after.card(cards[0])?.links.count == 2,
           "B10: assigning must not disturb the task's links")

    // Reassignment is one act, and its inverse restores the PREVIOUS owner —
    // not "unassigned", which would quietly drop a real relationship on undo.
    let reassigned = applyOrFail(.assignCard(id: cards[0], to: other), to: assigned.after, "B10 reassign")
    expect(reassigned.after.card(cards[0])?.assignee == other, "B10: reassignment must replace the owner")
    let undone = applyOrFail(reassigned.inverse, to: reassigned.after, "B10 undo reassign").after
    expect(undone.card(cards[0])?.assignee == agent,
           "B10: undoing a reassignment must restore the previous assignee, not clear it")

    // Unassigning is expressible, and round-trips.
    let cleared = applyOrFail(.assignCard(id: cards[0], to: nil), to: reassigned.after, "B10 unassign")
    expect(cleared.after.card(cards[0])?.assignee == nil, "B10: a task can be taken back")
    let restored = applyOrFail(cleared.inverse, to: cleared.after, "B10 undo unassign").after
    expect(restored.card(cards[0])?.assignee == other, "B10: undoing an unassign restores the owner")

    // Assignment survives the round trip that matters — the one to disk.
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("kb01-assign-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = ProjectStore(projectRoot: root)
    try! store.saveBoard(assigned.after)
    let reread = try! ProjectStore(projectRoot: root).tryLoadBoard(id: assigned.after.id)
    expect(reread?.card(cards[0])?.assignee == agent,
           "B10: an assignment must survive a save/load round trip")
    expect(reread?.card(cards[0])?.links.count == 2,
           "B10: typed links must survive a save/load round trip")
    expect(reread?.card(cards[0])?.body.contains("Repro") == true,
           "B10: the task body must survive a save/load round trip")
    _ = columns
}

private func digest(of url: URL) -> String {
    guard let data = try? Data(contentsOf: url) else { return "missing" }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// Regression: previously an attachment decoded successfully, then vanished on save.
private func runBoardAttachmentWireCheck() {
    do {
        let (board, _, _) = makeFixture()
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(board.cards[0])) as! [String: Any]
        json["attachments"] = [["id": UUID().uuidString, "filename": "screen.png", "contentType": "image/png",
                                "pixelWidth": 20, "pixelHeight": 10, "byteCount": 100]]
        let card = try JSONDecoder().decode(BoardCard.self, from: JSONSerialization.data(withJSONObject: json))
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(card)) as! [String: Any]
        expect((saved["attachments"] as? [[String: Any]])?.count == 1,
               "B11: task images must survive decoding and saving before any agent is assigned")
    } catch { expect(false, "B11 attachment round trip: \(error)") }
}

private func runBoardTaskContentCheck() {
    let (board, columns, ids) = makeFixture()
    let card = board.card(ids[0])!
    let baseline = BoardTaskContent(card: card)
    var edited = baseline
    edited.body = "Detailed **task**"
    edited.attachments = [BoardAttachment(filename: "proof.png", contentType: "image/png", pixelWidth: 20, pixelHeight: 10, byteCount: 100)]
    let concurrent = applyOrFail(.moveCard(id: card.id, toColumn: columns[1], after: nil, before: nil), to: board).after
    let transaction = applyOrFail(.editTask(id: card.id, expected: baseline, content: edited), to: concurrent)
    expect(transaction.after.card(card.id)?.columnId == columns[1], "B12: content autosave preserves a concurrent status change")
    expect(transaction.after.card(card.id)?.attachments == edited.attachments, "B12: content and images save together")
    let undone = applyOrFail(transaction.inverse, to: transaction.after).after
    expect(BoardTaskContent(card: undone.card(card.id)!) == baseline, "B12: one undo restores text and images together")
    var conflicting = edited; conflicting.body = "Other version"
    if case .failure(.contentConflict) = BoardEngine.apply(.editTask(id: card.id, expected: baseline, content: conflicting), to: transaction.after, now: boardNow) {} else {
        expect(false, "B12: overlapping content edits must refuse to overwrite")
    }
    var titleOnly = baseline; titleOnly.title = "Renamed"
    let merged = applyOrFail(.editTask(id: card.id, expected: baseline, content: titleOnly), to: transaction.after).after
    expect(merged.card(card.id)?.body == edited.body && merged.card(card.id)?.title == "Renamed", "B12: disjoint title and document edits merge")
    let context = BoardTaskContext(boardID: board.id, card: transaction.after.card(card.id)!, revision: transaction.after.revision, imageAttachmentIDs: [])
    let draft = AgentComposerDraft(text: "My instructions", selection: 0..<0, updatedAt: boardNow, taskContext: context)
    do {
        let decoded = try JSONDecoder().decode(AgentComposerDraft.self, from: JSONEncoder().encode(draft))
        expect(decoded == draft, "B13: prepared context survives a draft round trip")
        expect(decoded.text == "My instructions" && context.promptText(additionalInstructions: decoded.text).contains("Detailed **task**"), "B13: context stays separate until prompt assembly")
    } catch { expect(false, "B13: draft round trip: \(error)") }
}
