import ContinuumRevivedRelayClient
import ContinuumRevivedRelayProtocol
import Foundation

// Plan 104 step 3: the phone's message draft outlives the composer view.
// The app model holds `PhoneMessageDrafts`; the composer reads it back on
// every appearance. These checks drive the same calls the composer and the
// model make: leave the agent while the Mac has not answered, come back, and
// the text, the waiting state and the sealed request (its idempotency key)
// are the ones that were sent — so a resend cannot mint a second message.
func runPhoneMessageDraftChecks() throws {
    struct Failure: Error { let message: String }
    func check(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }

    let agent = UUID(), other = UUID()
    var seals = 0
    func seal(_ text: String) -> RelayCommandRequest? {
        seals += 1
        return RelayCommandRequest(idempotencyKey: UUID(), kind: RelayCommandKind.agentMessage, agentID: agent, payload: Data(text.utf8))
    }

    // The model's store; a "screen" is a fresh read of it, as the view does.
    var drafts = PhoneMessageDrafts()
    drafts[agent].edit("run the tests")
    guard let first = drafts[agent].beginSend(seal: seal) else { throw Failure(message: "first send sealed nothing") }
    drafts[agent].finish(.waiting, for: first.idempotencyKey)

    // Leave the agent: the composer is discarded. Come back: a new read.
    let restored = drafts[agent]
    try check(restored.text == "run the tests", "draft text lost on leaving the agent (got \"\(restored.text)\")")
    try check(restored.delivery == .waiting && restored.locked, "waiting state lost on leaving the agent")
    try check(restored.inFlight?.idempotencyKey == first.idempotencyKey, "in-flight request lost on leaving the agent")
    try check(restored.pollKey == first.idempotencyKey, "status poll does not resume with the sent key")
    try check(drafts[other] == PhoneMessageDraft(), "one agent's draft leaked into another")

    // Locked while waiting: the text cannot change under the sealed request.
    drafts[agent].edit("something else")
    try check(drafts[agent].text == "run the tests", "text editable while the Mac has not answered")

    // The relay unreachable on a poll, then a resend: same bytes, same key.
    drafts[agent].finish(.unreachable("offline"), for: first.idempotencyKey)
    guard let resend = drafts[agent].beginSend(seal: seal) else { throw Failure(message: "resend sealed nothing") }
    try check(resend == first && seals == 1, "resend after coming back minted a new message (seals: \(seals))")

    // A late answer for a message the draft has moved past is ignored.
    drafts[agent].finish(.accepted, for: UUID())
    try check(drafts[agent].text == "run the tests", "a stale answer cleared the draft")

    // The Mac accepts: the draft clears, exactly as the composer did.
    drafts[agent].finish(.accepted, for: first.idempotencyKey)
    let done = drafts[agent]
    try check(done.text.isEmpty && done.inFlight == nil && done.delivery == .accepted && !done.locked, "accepted message not cleared")

    // Refused is final for that seal; editing after a failure is a new message.
    drafts[agent].edit("try again")
    guard let second = drafts[agent].beginSend(seal: seal) else { throw Failure(message: "second send sealed nothing") }
    drafts[agent].finish(.refused("busy"), for: second.idempotencyKey)
    try check(drafts[agent].text == "try again" && drafts[agent].inFlight == nil, "refused message lost its text or kept its seal")
    guard let third = drafts[agent].beginSend(seal: seal) else { throw Failure(message: "third send sealed nothing") }
    try check(third.idempotencyKey != second.idempotencyKey, "a retry after a refusal reused the refused seal")

    print("PASS: phone message draft survives leaving the agent; resend keeps its key (seals: \(seals))")
}
