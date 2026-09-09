import ContinuumRevivedAgentContent
import Foundation

private func replyOptionID(_ raw: String) -> AgentNodeID {
    guard let id = AgentNodeID(rawValue: raw) else { fail("invalid reply-option check ID: \(raw)") }
    return id
}

/// Drives real Markdown through the real parser, because that is the only
/// supply the detector will ever see. A hand-built block tree would let the
/// detector agree with a shape the parser does not actually produce — the exact
/// way the tool-detail vocabulary stayed green for months while production was
/// empty.
private func parseAssistantEntry(
    _ markdown: String,
    lifecycle: AgentEntryLifecycle = .finished
) -> AgentEntry {
    let parser: any AgentMarkupParsing = MarkdownAgentMarkupParser()
    let entryID = replyOptionID("entry:reply-options")
    let parsed = parser.parse(markdown, entryID: entryID, previous: [])
    expect(parsed.diagnostics.isEmpty, "reply-option fixture parsed with diagnostics: \(parsed.diagnostics)")
    return AgentEntry(
        id: entryID,
        revision: 1,
        role: .assistant,
        provenance: .providerItem(provider: "check", itemID: "reply-options"),
        lifecycle: lifecycle,
        blocks: parsed.blocks
    )
}

private func detected(
    _ markdown: String, lifecycle: AgentEntryLifecycle = .finished
) -> [AgentReplyOption] {
    let entry = parseAssistantEntry(markdown, lifecycle: lifecycle)
    return AgentReplyOptionDetector.options(in: AgentDocument(version: 1, entries: [entry]))
}

/// Labels only, for the assertions that are about WHICH options were found.
private func options(_ markdown: String, lifecycle: AgentEntryLifecycle = .finished) -> [String] {
    detected(markdown, lifecycle: lifecycle).map(\.label)
}

/// Dylan's ask: "handle some parsing of the response like selecting options
/// rather than typing options."
///
/// The whole risk in this feature is the false positive. An offer that appears
/// when nothing was asked puts words in the user's mouth, and it appears at the
/// composer — the one place where a stray click sends text to a real agent. So
/// this leg spends most of its assertions on replies that must produce NOTHING,
/// and each negative names a shape a looser detector would have accepted.
func runReplyOptionChecks() {
    // 1. The shape the feature exists for: a question, then a short list.
    let asked = options(
        """
        I can take either route here. Which do you want?

        - Rewrite the resolver — keeps the API, drops the cache
        - Patch the call sites — smaller diff, leaves the duplication
        """
    )
    expect(asked == ["Rewrite the resolver", "Patch the call sites"],
           "a question followed by a two-item list must offer both items, got \(asked)")

    // Numbered phrasing is the same offer. This is the form Dylan is typing "2"
    // at today.
    let numbered = options(
        """
        Three ways to go about it. Which would you prefer?

        1. Ship it behind a flag
        2. Split the migration in two
        3. Revert and start over
        """
    )
    expect(numbered == ["Ship it behind a flag", "Split the migration in two", "Revert and start over"],
           "an ordered list under a question must offer its items verbatim, got \(numbered)")

    // Bold-lead items are the common LLM phrasing; the explanation after the
    // dash is not part of the answer.
    let bolded = options(
        """
        Which should I do first?

        - **Fix the leak** — it is the one users hit
        - **Add the test** — cheaper, and it pins the leak
        """
    )
    expect(bolded == ["Fix the leak", "Add the test"],
           "the leading phrase is the choice; the trailing clause is explanation. Got \(bolded)")

    // An invitation without a question mark still reads as an offer.
    let invited = options(
        """
        Both are defensible. Let me know which:

        - Keep the retry
        - Drop it
        """
    )
    expect(invited == ["Keep the retry", "Drop it"],
           "an explicit invitation must count as asking, got \(invited)")

    // 2. The negatives. Each of these is a reply a regex over "1." or a
    //    "does it end in a list" rule would have decorated with chips.
    let summary = options(
        """
        Done. Here is what changed:

        1. The resolver now caches by path
        2. The duplicated call site is gone
        3. Added a witness for both
        """
    )
    expect(summary.isEmpty, "a summary list is not a question; offered \(summary)")

    let noList = options("I went with the resolver rewrite. Want me to run the matrix?")
    expect(noList.isEmpty, "a question with no list has nothing to offer; offered \(noList)")

    let listFirst = options(
        """
        - Rewrite the resolver
        - Patch the call sites

        Both are fine, so I picked the first.
        """
    )
    expect(listFirst.isEmpty, "a list ABOVE the prose is not an answer set; offered \(listFirst)")

    let tooMany = options(
        """
        Which one?

        - One
        - Two
        - Three
        - Four
        - Five
        - Six
        - Seven
        """
    )
    expect(tooMany.isEmpty,
           "a list longer than \(AgentReplyOptionDetector.maximumOptions) is a document, not a "
           + "choice; offered \(tooMany)")

    // And the cap itself is REACHABLE. A planning reply routinely lays out five
    // or six approaches; the old cap of four rejected the whole set rather than
    // trimming it, so the replies that most needed the affordance never got it.
    let atTheCap = options(
        """
        Which one?

        - One
        - Two
        - Three
        - Four
        - Five
        - Six
        """
    )
    expect(atTheCap.count == AgentReplyOptionDetector.maximumOptions,
           "a list at exactly the cap must be offered whole; offered \(atTheCap)")

    let single = options(
        """
        Which one?

        - The only thing I can think of
        """
    )
    expect(single.isEmpty, "one item is not a choice; offered \(single)")

    let essay = options(
        """
        Which approach do you want?

        - \(String(repeating: "long ", count: 40))
        - Short one
        """
    )
    expect(essay.isEmpty,
           "an item longer than \(AgentReplyOptionDetector.maximumOptionLength) chars is prose in a "
           + "list; offered \(essay)")

    let duplicated = options(
        """
        Which one?

        - Keep it — for now
        - Keep it — forever
        """
    )
    expect(duplicated.isEmpty,
           "two items that chip to the SAME label cannot be told apart once clicked; offered "
           + "\(duplicated)")

    // 2b. The planning shapes. Measured against the detector before this
    //     change, five of seven realistic planning replies were rejected — and
    //     planning is exactly when Dylan wants the affordance. Each case below
    //     names the rule that used to reject it.

    // The question sits BELOW the options. Rejected before: the list had to be
    // the last block with the question immediately above it.
    let questionLast = options(
        """
        Two approaches:

        - **Incremental migration** — ship behind a flag, migrate callers over three
          releases. Lower risk, more code for longer.
        - **Big-bang cutover** — one release, all callers. Higher risk, less carrying cost.

        I'd lean incremental. Your call?
        """
    )
    expect(questionLast == ["Incremental migration", "Big-bang cutover"],
           "options laid out before the question must still be offered; got \(questionLast)")

    // A closing note after the list. Rejected before: the list was no longer last.
    let trailingNote = options(
        """
        Which do you want?

        - Rewrite the resolver
        - Patch the call sites

        Either way I'll add the witness first.
        """
    )
    expect(trailingNote == ["Rewrite the resolver", "Patch the call sites"],
           "a closing note after the list must not withdraw the offer; got \(trailingNote)")

    // Asking and recommending in one breath. Rejected before: the paragraph had
    // to END with the question mark.
    let askedAndRecommended = options(
        """
        Which do you want? I'd lean toward the first.

        - Rewrite the resolver
        - Patch the call sites
        """
    )
    expect(askedAndRecommended == ["Rewrite the resolver", "Patch the call sites"],
           "a question followed by a recommendation is still a question; got \(askedAndRecommended)")

    // 2c. The false positives the LIBERALISATION could have introduced.

    // The one that matters: a summary list followed by an unrelated question.
    // Accepting a question below a list without requiring it to refer BACK to a
    // set would turn every "here is what I did … shall I continue?" into chips.
    let summaryThenUnrelatedQuestion = options(
        """
        Done. Here is what changed:

        1. The resolver now caches by path
        2. The duplicated call site is gone

        Want me to run the matrix?
        """
    )
    expect(summaryThenUnrelatedQuestion.isEmpty,
           "a question BELOW a list must refer back to it; a summary followed by an unrelated "
           + "question is not a choice. Offered \(summaryThenUnrelatedQuestion)")

    // Two lists is a document — a summary and a plan, say. Picking either as
    // "the choices" would be a guess.
    let twoLists = options(
        """
        Which do you want?

        - Rewrite the resolver
        - Patch the call sites

        Here is what I already did:

        - Added the witness
        - Ran the matrix
        """
    )
    expect(twoLists.isEmpty,
           "a reply carrying two lists is a document, not a choice; offered \(twoLists)")

    // 2d. The reasoning is KEPT. Dropping the trailing clause is what made this
    //     a typing shortcut instead of a decision aid: when the question is
    //     "which approach", the tradeoff after the dash is the half you decide on.
    let withDetail = detected(
        """
        Which do you want?

        - **Rewrite the resolver** — keeps the API, drops the cache
        - Patch the call sites
        """
    )
    expect(withDetail.map(\.label) == ["Rewrite the resolver", "Patch the call sites"],
           "detail parsing changed the labels; got \(withDetail.map(\.label))")
    expect(withDetail.first?.detail == "keeps the API, drops the cache",
           "the reasoning after the separator must be kept; got \(String(describing: withDetail.first?.detail))")
    expect(withDetail.last?.detail == nil,
           "a bare label must carry no fabricated detail; got \(String(describing: withDetail.last?.detail))")

    // 3. A turn still being written offers nothing: the list grows item by item
    //    as the stream lands, and a strip that appeared mid-stream would flicker
    //    through exactly the states the reader is trying to follow.
    let streaming = options(
        """
        Which do you want?

        - Rewrite the resolver
        - Patch the call sites
        """,
        lifecycle: .open(markupBlockID: nil)
    )
    expect(streaming.isEmpty, "an open (streaming) entry must offer nothing; offered \(streaming)")

    // 4. Only the LAST entry, and only an assistant one. A question two turns
    //    back has been answered by definition — the user sent something after it.
    let question = parseAssistantEntry(
        """
        Which do you want?

        - Rewrite the resolver
        - Patch the call sites
        """
    )
    let userReply = AgentEntry(
        id: replyOptionID("entry:reply-options-user"),
        revision: 1,
        role: .user,
        provenance: .localPrompt(promptID: "p1"),
        lifecycle: .finished,
        blocks: [AgentBlock(
            id: replyOptionID("block:reply-options-user"),
            kind: .paragraph,
            payload: .paragraph([.text("the first one")])
        )]
    )
    let answered = AgentReplyOptionDetector.options(
        in: AgentDocument(version: 2, entries: [question, userReply])
    )
    expect(answered.isEmpty,
           "an offer must not outlive the turn that made it — the user has already replied; "
           + "offered \(answered)")

    print(
        "Reply-option checks passed: a settled assistant turn that asks and lists offers its "
        + "choices — including the planning shapes (question below the options, a closing note "
        + "after them, asking and recommending in one breath, and up to "
        + "\(AgentReplyOptionDetector.maximumOptions) of them) — each keeping the reasoning "
        + "after its label; and summaries, a summary followed by an unrelated question, two "
        + "lists, mid-stream turns, over-long items, single items, ambiguous labels and "
        + "already-answered questions offer nothing"
    )
}
