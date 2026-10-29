import Foundation
import ContinuumRevivedAgentContent

/// `.plans/45` S4.3 — the display projection between the semantic `rows` and
/// the diffable snapshot. Dylan's decision 2: consecutive completed tool calls
/// cluster to one line ("6 steps · 5 searches, 1 fetch · 12.4s ✓"); while a
/// run is live, the tail row stays plain under an "N earlier steps" header;
/// failures never fold.
///
/// This is a PURE function over per-row facts. It deliberately does not touch
/// `rows == flatten(document)` — the two rejected alternatives (flatten-level
/// cluster rows, renderer-level 0pt rows) broke the equivalence oracle and the
/// row-gap witness respectively; the record is in the plan. Rebuilt O(rows)
/// once per visual apply, never per delta.
enum AgentTranscriptClusterPlanner {
    struct RowFact: Equatable {
        /// A top-level `.toolCall` / `.commandOutput` row.
        let isToolRow: Bool
        /// `.failed` / `.interrupted` / `.cancelled` — always renders plain and
        /// splits the run.
        let isFailure: Bool
        /// `.pending` / `.inProgress` — the live tail of a run renders plain.
        let isLive: Bool
        /// The row begins a new turn (a run never crosses this).
        let startsTurn: Bool
        /// The row's top-level node ID (block or reasoning entry).
        let id: AgentNodeID
        /// A LATER row already says everything this one does.
        ///
        /// One claude `Agent` call produces two rows: the tool call, and the
        /// durable `agentReference` chip that names the child it started. The
        /// chip carries the child's name, its live status and a way to open it;
        /// the tool row carries the word "Agent". Rendering both is how a single
        /// delegation came to occupy two rows and say less in each.
        ///
        /// Superseded rows are folded out of the DISPLAY list only. `rows` still
        /// equals `flatten(document)` and the block stays in the document, so
        /// nothing is lost — the same contract tool clustering already keeps.
        var isSuperseded: Bool = false
        /// Turn cards (direction C). The row belongs to a user entry.
        var isUser: Bool = false
        /// ...and is prose — the words that become the turn's Ask heading.
        var isUserProse: Bool = false
        /// A finished reasoning entry ("Thought 4s") — work, not answer.
        var isReasoning: Bool = false
        /// A file-change block: work in the log, a chip in the outcome.
        var isDiff: Bool = false
        /// Browser use folds separately from neighboring non-browser tools.
        var isBrowserAction: Bool = false

        /// What the turn's work strip folds: steps, thoughts and file changes.
        var isWork: Bool { isToolRow || isReasoning || isDiff }
    }

    struct Header: Equatable {
        /// A4.2 — distinguishes a `plan()` tool-cluster header ("6 steps ·
        /// 5 searches, 1 fetch · 12.4s ✓") from a `foldTurns()` whole-turn
        /// header ("Worked for 1m 12s · 8 tools"). The two share every other
        /// mechanism (fixed height, disclosure toggle, snapshot coverage) —
        /// only the summary text formatting branches on this.
        enum Scope: Equatable {
            case toolCluster
            case turn
            /// Turn cards: the user's prompt as the turn's heading. Always
            /// covers its rows; `isExpanded` lifts the two-line clamp.
            case ask
            /// Turn cards: the one live line that stands for the turn's work.
            /// Collapsed it covers the work; expanded the work log follows it.
            case workStrip
            /// Turn cards: an earlier turn folded to its Ask and one line of
            /// outcome. Expanded, the whole card replaces it.
            case foldedTurn
            /// Turn cards: the changed-file chips that close a turn. Synthetic;
            /// it covers nothing.
            case outcome

            var isTurnCard: Bool {
                switch self {
                case .ask, .workStrip, .foldedTurn, .outcome: return true
                case .toolCluster, .turn: return false
                }
            }
        }

        /// Stable while members append: derived from the FIRST member's ID, so
        /// the snapshot keeps the header instance and only member IDs churn.
        let id: AgentNodeID
        /// Semantic row indexes the header REPRESENTS (folded out of the
        /// snapshot when collapsed; rendered after the header when expanded).
        let memberIndexes: [Int]
        let isLive: Bool
        let isExpanded: Bool
        var scope: Scope = .toolCluster
        /// T3 — the whole turn's semantic row range, for a `.turn` header only.
        ///
        /// NOT derivable from `memberIndexes`: a turn header deliberately omits
        /// the turn-start row (the user prompt stays rendered, because the turn
        /// separator and the hover "sent at" reveal both key off it) and may omit
        /// a terminal assistant row. Those two are exactly the endpoints a turn's
        /// DURATION needs, and every folded member usually belongs to one entry —
        /// so a span measured over members alone is zero.
        var turnRange: Range<Int>?

        /// Whether the header stands in for its members on screen. An Ask is
        /// its rows however far it is unclamped; an outcome stands for nothing;
        /// everything else covers exactly while collapsed.
        var coversMembers: Bool {
            switch scope {
            case .ask: return true
            case .outcome: return false
            case .toolCluster, .turn, .workStrip, .foldedTurn: return !isExpanded
            }
        }

        /// A turn card's heading — the item a turn boundary sits above.
        var startsTurnCard: Bool { scope == .ask || scope == .foldedTurn }
    }

    enum Item: Equatable {
        case row(Int)
        case header(Header)
    }

    static func headerID(forFirstMember id: AgentNodeID) -> AgentNodeID {
        AgentNodeID(rawValue: "__cluster__\(id.rawValue)") ?? id
    }

    /// `.plans/45` A4.1 — the turn boundaries `plan()` already computed as a
    /// single index (`lastTurnStart`), pulled out as its own pure function so
    /// A4.2's turn-level fold pass can share it instead of re-deriving turn
    /// starts a second way. Every fact belongs to exactly one contiguous
    /// range; a `RowFact.startsTurn` at index `i` (`i > 0` by construction —
    /// see `AgentTranscriptListView.startsTurn`) closes the range ending at
    /// `i` and opens the next one.
    ///
    /// This is a NO-OP extraction: `plan()`'s only use of turn boundaries
    /// (`lastTurnStart`) is `turnRanges(facts: facts).last?.lowerBound ?? 0`,
    /// which is exactly what the old inline
    /// `facts.lastIndex(where: { $0.startsTurn }) ?? 0` computed. The
    /// equivalence is asserted directly in
    /// `TranscriptRhythmChecks.checkTurnRangesMatchLegacyLastTurnStart`.
    static func turnRanges(facts: [RowFact]) -> [Range<Int>] {
        guard !facts.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        var start = 0
        for index in facts.indices where index > 0 && facts[index].startsTurn {
            ranges.append(start..<index)
            start = index
        }
        ranges.append(start..<facts.count)
        return ranges
    }

    static func headerID(forTurnFirstMember id: AgentNodeID) -> AgentNodeID {
        AgentNodeID(rawValue: "__turn__\(id.rawValue)") ?? id
    }

    /// A4.2 — a SECOND pass over the `[Item]` list `plan()` already produced,
    /// folding an entire completed turn (everything but its terminal answer
    /// row) under one header, so a long-settled turn reads as one line instead
    /// of the whole exchange. This does not touch `rows == flatten(document)`
    /// either — same discipline as `plan()`, one layer up.
    ///
    /// Eligibility, deliberately narrow:
    /// - Only turns before the LAST one fold — the last turn is what the
    ///   reader is following now, streaming or not; `plan()` already gives the
    ///   same treatment to its tool runs via `tailStreaming`.
    /// - A turn containing any `isFailure` row never folds — `isFailure`
    ///   already covers `.interrupted`/`.cancelled`, so an interrupted turn
    ///   is naturally left fully visible rather than needing a separate
    ///   auto-expand rule.
    /// - The terminal item (the turn's last `.row`, when it is not a tool
    ///   row) is preserved OUTSIDE the fold so a folded turn still shows its
    ///   answer — it is excluded from `memberIndexes` for exactly this
    ///   reason: `AgentTranscriptListView.qaClusterProjectionMismatch`
    ///   requires every row be either displayed or covered, never both.
    /// - Folding fewer than 2 rows away is not worth a header — mirrors
    ///   `plan()`'s "runs of 1 never cluster".
    static func foldTurns(
        items: [Item],
        facts: [RowFact],
        turnRanges: [Range<Int>],
        isExpanded: (AgentNodeID) -> Bool
    ) -> [Item] {
        guard turnRanges.count > 1 else { return items }
        let foldableRanges = turnRanges.dropLast()

        func representativeRow(_ item: Item) -> Int {
            switch item {
            case let .row(index): return index
            case let .header(header): return header.memberIndexes.first ?? 0
            }
        }

        var result: [Item] = []
        result.reserveCapacity(items.count)
        var itemIndex = 0
        for range in foldableRanges {
            let sliceStart = itemIndex
            while itemIndex < items.count, range.contains(representativeRow(items[itemIndex])) {
                itemIndex += 1
            }
            let slice = items[sliceStart..<itemIndex]
            // The turn-start row (the user prompt) is left in place, always —
            // `AgentTranscriptListView`'s turn separator and hover "sent at"
            // reveal both key off it being a plain, rendered `.row`
            // (`qaTurnStartPointForChecks`). Folding begins after it.
            guard let leading = slice.first, slice.count > 2,
                  !range.contains(where: { facts[$0].isFailure })
            else {
                result.append(contentsOf: slice)
                continue
            }
            let middle = slice.dropFirst()

            var terminalItem: Item?
            if case let .row(row)? = middle.last, !facts[row].isToolRow {
                terminalItem = middle.last
            }
            let terminalRow: Int? = {
                if case let .row(row)? = terminalItem { return row }
                return nil
            }()
            let coveredIndexes = (terminalRow.map { terminal in
                range.filter { $0 != range.lowerBound && $0 != terminal }
            } ?? range.filter { $0 != range.lowerBound })
            // Threshold 3 tool rows, not 2 (mirrors `plan()`'s live-run
            // threshold, `.plans/45` 2026-08-24). A turn with one or two tool
            // calls reads fine in full; the fold earns its keep only once a
            // turn's middle is long enough that "Worked for …" is a genuine
            // compression, not a trade of three visible rows for one. This
            // floor is also what keeps every pre-existing rhythm fixture
            // (`.turnBoundary`'s three one-tool-call turns among them)
            // untouched by this pass — none of them clears it.
            guard coveredIndexes.filter({ facts[$0].isToolRow }).count >= 3 else {
                result.append(contentsOf: slice)
                continue
            }

            let id = headerID(forTurnFirstMember: facts[range.lowerBound].id)
            let header = Header(
                id: id, memberIndexes: coveredIndexes, isLive: false, isExpanded: isExpanded(id),
                scope: .turn, turnRange: range
            )
            result.append(leading)
            result.append(.header(header))
            if isExpanded(id) {
                result.append(contentsOf: middle)
            } else if let terminalItem {
                result.append(terminalItem)
            }
        }
        result.append(contentsOf: items[itemIndex...])
        return result
    }

    static func askID(forTurnFirstMember id: AgentNodeID) -> AgentNodeID {
        AgentNodeID(rawValue: "__ask__\(id.rawValue)") ?? id
    }

    static func workStripID(forTurnFirstMember id: AgentNodeID) -> AgentNodeID {
        AgentNodeID(rawValue: "__strip__\(id.rawValue)") ?? id
    }

    static func foldedTurnID(forTurnFirstMember id: AgentNodeID) -> AgentNodeID {
        AgentNodeID(rawValue: "__turncard__\(id.rawValue)") ?? id
    }

    static func outcomeID(forTurnFirstMember id: AgentNodeID) -> AgentNodeID {
        AgentNodeID(rawValue: "__outcome__\(id.rawValue)") ?? id
    }

    /// Direction C, "turn cards with a live head" (`.plans/70` S8). The TURN is
    /// the unit, and every turn has the same four-part shape:
    ///
    /// 1. **Ask** — the user's prose as the turn's heading (covers those rows).
    /// 2. **Work strip** — one line that stands for every step, thought and file
    ///    change in the turn. Collapsed it covers them; expanded, they follow it
    ///    in their original order (the work log).
    /// 3. **Answer** — everything else, in order: prose, code, plans, requests,
    ///    errors, subagent chips. Never folded into the strip, so a question the
    ///    agent asks or an error it hit is never hidden behind a disclosure.
    /// 4. **Outcome** — a synthetic chip row when the turn changed files.
    ///
    /// Turns before the newest fold to ONE item (Ask + one line of outcome)
    /// until the reader opens them. A second pass over `plan()`'s items, like
    /// `foldTurns`, and the same contract: `rows` is untouched, and every row is
    /// displayed or covered exactly once. O(items), run only where the plan is.
    ///
    /// A leading range with no user prompt (a restored-session notice, history
    /// that predates the first prompt) has no heading to hang a card on and is
    /// left exactly as `plan()` laid it out, unless it is the only turn there is.
    static func turnCards(
        items: [Item],
        facts: [RowFact],
        turnRanges: [Range<Int>],
        liveTail: Bool,
        isExpanded: (AgentNodeID) -> Bool
    ) -> [Item] {
        guard !facts.isEmpty, !turnRanges.isEmpty else { return items }

        func representativeRow(_ item: Item) -> Int {
            switch item {
            case let .row(index): return index
            case let .header(header): return header.memberIndexes.first ?? 0
            }
        }
        func rowsOf(_ item: Item) -> [Int] {
            switch item {
            case let .row(index): return [index]
            case let .header(header): return header.memberIndexes
            }
        }
        func isWork(_ item: Item) -> Bool {
            switch item {
            case let .row(index): return facts[index].isWork
            // `plan()` emits tool-run clusters only; a run is work by definition.
            case let .header(header): return header.scope == .toolCluster
            }
        }

        var result: [Item] = []
        result.reserveCapacity(items.count + turnRanges.count * 3)
        var itemIndex = 0
        for (turnIndex, range) in turnRanges.enumerated() {
            let sliceStart = itemIndex
            while itemIndex < items.count, range.contains(representativeRow(items[itemIndex])) {
                itemIndex += 1
            }
            let slice = items[sliceStart..<itemIndex]
            let isNewest = turnIndex == turnRanges.count - 1
            let firstID = facts[range.lowerBound].id

            var askRows: [Int] = []
            for item in slice {
                guard case let .row(index) = item, facts[index].isUserProse,
                      index == range.lowerBound || !facts[index].startsTurn
                else { break }
                askRows.append(index)
            }
            let hasAsk = !askRows.isEmpty
            guard hasAsk || isNewest else {
                result.append(contentsOf: slice)
                continue
            }

            if hasAsk, !isNewest {
                let foldID = foldedTurnID(forTurnFirstMember: firstID)
                if !isExpanded(foldID) {
                    result.append(.header(Header(
                        id: foldID, memberIndexes: slice.flatMap(rowsOf), isLive: false,
                        isExpanded: false, scope: .foldedTurn, turnRange: range)))
                    continue
                }
            }

            let rest = slice.dropFirst(askRows.count)
            // The user's own non-prose rows (an attached image) stay with the
            // Ask, above the strip, rather than drifting into the answer.
            let leadingUser = rest.prefix { item in
                if case let .row(index) = item { return facts[index].isUser }
                return false
            }
            let body = rest.dropFirst(leadingUser.count)
            let workItems = body.filter(isWork)
            let answerItems = body.filter { !isWork($0) }
            let workRows = workItems.flatMap(rowsOf)
            let live = isNewest && liveTail

            if hasAsk {
                let id = askID(forTurnFirstMember: firstID)
                result.append(.header(Header(
                    id: id, memberIndexes: askRows, isLive: false, isExpanded: isExpanded(id),
                    scope: .ask, turnRange: range)))
            }
            result.append(contentsOf: leadingUser)
            if hasAsk || live || !workRows.isEmpty {
                let id = workStripID(forTurnFirstMember: firstID)
                let expanded = !workRows.isEmpty && isExpanded(id)
                result.append(.header(Header(
                    id: id, memberIndexes: workRows, isLive: live, isExpanded: expanded,
                    scope: .workStrip, turnRange: range)))
                if expanded { result.append(contentsOf: workItems) }
            }
            result.append(contentsOf: answerItems)
            if workRows.contains(where: { facts[$0].isDiff }) {
                result.append(.header(Header(
                    id: outcomeID(forTurnFirstMember: firstID), memberIndexes: [], isLive: false,
                    isExpanded: false, scope: .outcome, turnRange: range)))
            }
        }
        result.append(contentsOf: items[itemIndex...])
        return result
    }

    /// - Parameters:
    ///   - tailStreaming: the transcript's thinking indicator is up — the LAST
    ///     turn is still producing output, and folding must not flicker through
    ///     that window (t3 adoption: fold decisions key on turn lifecycle, not
    ///     transient row state). Runs in earlier turns still fold.
    static func plan(
        facts: [RowFact],
        tailStreaming: Bool,
        isExpanded: (AgentNodeID) -> Bool
    ) -> [Item] {
        var items: [Item] = []
        items.reserveCapacity(facts.count)
        let lastTurnStart = turnRanges(facts: facts).last?.lowerBound ?? 0

        var index = 0
        while index < facts.count {
            if facts[index].isSuperseded { index += 1; continue }
            let fact = facts[index]
            guard fact.isToolRow, !fact.isFailure else {
                items.append(.row(index))
                index += 1
                continue
            }
            // Collect the maximal run: consecutive tool rows, same turn, no
            // failures (a failure terminates the run and renders plain).
            var run: [Int] = [index]
            var next = index + 1
            while next < facts.count,
                  facts[next].isToolRow,
                  !facts[next].isFailure,
                  !facts[next].startsTurn,
                  facts[next].isBrowserAction == fact.isBrowserAction {
                run.append(next)
                next += 1
            }
            defer { index = next }

            let liveIndex = run.firstIndex { facts[$0].isLive }
            if let liveIndex {
                // Live run: everything before the first live member folds under
                // an "N earlier steps" header; the live rows render plain.
                //
                // Threshold 3, not 1 (2026-08-24). Folding a single completed
                // row meant that every time tool k finished and tool k+1 went
                // live, the row the reader was looking at was DELETED and
                // replaced by "1 earlier step" — one hard shift per tool call,
                // mid-read. Keeping the last couple of steps visible is what
                // makes a running turn followable; the fold is for the tail of
                // a long run, not for its second entry.
                let earlier = Array(run[..<liveIndex])
                if earlier.count >= 3 {
                    items.append(.header(Header(
                        id: headerID(forFirstMember: facts[earlier[0]].id),
                        memberIndexes: earlier,
                        isLive: true,
                        isExpanded: isExpanded(headerID(forFirstMember: facts[earlier[0]].id))
                    )))
                    if isExpanded(headerID(forFirstMember: facts[earlier[0]].id)) {
                        items.append(contentsOf: earlier.map(Item.row))
                    }
                }
                items.append(contentsOf: run[liveIndex...].map(Item.row))
                continue
            }

            // Settled run in the STREAMING last turn: hold the fold until the
            // turn settles, so rows never vanish mid-stream.
            if tailStreaming, run[0] >= lastTurnStart {
                items.append(contentsOf: run.map(Item.row))
                continue
            }

            // Runs of 1 never cluster.
            guard run.count >= 2 else {
                items.append(.row(run[0]))
                continue
            }

            let id = headerID(forFirstMember: facts[run[0]].id)
            let expanded = isExpanded(id)
            items.append(.header(Header(
                id: id, memberIndexes: run, isLive: false, isExpanded: expanded
            )))
            if expanded {
                items.append(contentsOf: run.map(Item.row))
            }
        }
        return items
    }
}
