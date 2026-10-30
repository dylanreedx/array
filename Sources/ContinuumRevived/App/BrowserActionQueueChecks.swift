import AppKit
import ContinuumRevivedCore
import Foundation

@MainActor
func runBrowserActionQueueCheck() throws {
    guard ProcessInfo.processInfo.environment["CONTINUUM_APP_SUPPORT"] != nil,
          Bundle.main.bundleIdentifier != AppChannel.prodBundleIdentifier else {
        throw WorkspaceAPIChecks.Failure(message: "browser action queue check requires isolated app support and a dev binary")
    }
    let f = try WorkspaceAPIChecks.makeFixture()
    defer { f.tearDown() }
    let q = f.api.browserActionQueue
    let tile = UUID()
    var inputCount = 0
    var authorized = true
    var effects: [String] = []
    var answers: [String: WorkspaceAPIService.Reply] = [:]
    var timerFired = false
    func reply(_ text: String) -> WorkspaceAPIService.Reply { .result(["value": AnyHashableJSON(any: text)]) }
    func add(_ label: String, key: String, payload: String, deadline: TimeInterval,
             operation: String = "test", input: Int = 0, delay: UInt64 = 0) {
        q.submit(tileId: tile, agentId: f.agentId, key: key, operation: operation, payload: payload,
                 deadline: Date().addingTimeInterval(deadline), inputCount: input,
                 currentInputCount: { inputCount },
                 authorize: { authorized ? nil : WorkspaceAPIError(code: .permissionDenied, message: "revoked") },
                 action: { _ in
                     if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                     effects.append(label)
                     return reply(label)
                 }, completion: { answers[label] = $0 })
    }
    add("first", key: "a", payload: "one", deadline: 2, delay: 150_000_000)
    add("duplicate", key: "a", payload: "one", deadline: 2)
    add("conflict", key: "a", payload: "different", deadline: 2)
    add("opConflict", key: "a", payload: "one", deadline: 2, operation: "different")
    add("invalidDeadline", key: "invalid", payload: "invalid", deadline: 61)
    add("expired", key: "b", payload: "two", deadline: 0.05)
    add("takeover", key: "c", payload: "three", deadline: 2)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { timerFired = true }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { inputCount = 1 }
    let finish = Date().addingTimeInterval(3)
    while answers.count < 7, Date() < finish {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw WorkspaceAPIChecks.Failure(message: message) }
    }
    func error(_ label: String, _ code: WorkspaceAPIError.Code) -> Bool {
        guard case .error(let error)? = answers[label] else { return false }
        return error.code == code
    }
    try require(timerFired, "the main queue must remain responsive")
    try require(effects == ["first"], "only the first action may run; got \(effects)")
    try require(answers["first"] == answers["duplicate"], "same-key pending requests must share one outcome")
    try require(error("conflict", .idempotencyConflict), "different intent behind a key must conflict")
    try require(error("opConflict", .idempotencyConflict), "a different operation behind a key must conflict")
    try require(error("invalidDeadline", .invalidRequest), "unbounded deadlines must be refused")
    try require(error("expired", .busy), "queued action must expire at its original deadline")
    try require(error("takeover", .targetConflict), "queued action must stop on user takeover")
    add("replay", key: "a", payload: "one", deadline: 2, input: 1)
    try require(answers["replay"] == answers["first"] && effects == ["first"], "an uncertain in-flight effect must stay uncertain and never replay after takeover")
    authorized = false
    add("revokedReplay", key: "a", payload: "one", deadline: 2, input: 1)
    try require(error("revokedReplay", .permissionDenied), "revoked caller must not recover a cached browser result")
    add("revoked", key: "d", payload: "four", deadline: 2, input: 1)
    let deadline = Date().addingTimeInterval(1)
    while answers["revoked"] == nil, Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    try require(error("revoked", .permissionDenied), "permission must be rechecked before the action")
    authorized = true
    q.submit(tileId: UUID(), agentId: f.agentId, key: "dead-browser", operation: "test", payload: "dead",
             deadline: Date().addingTimeInterval(2), inputCount: inputCount,
             currentInputCount: { nil }, authorize: { nil },
             action: { _ in effects.append("dead-browser"); return reply("unexpected") },
             completion: { answers["dead-browser"] = $0 })
    guard case let .error(deadError)? = answers["dead-browser"] else {
        throw WorkspaceAPIChecks.Failure(message: "dead browser must return an error")
    }
    try require(deadError.code.rawValue == "browser_not_live" && !effects.contains("dead-browser"),
                "dead browser must have a distinct browser_not_live code and do nothing")

    // An action that outlives its deadline can still have an effect. The
    // reply is outcome-unknown, no retry replays it, and later work must not
    // overlap it even if that later request expires in the meantime.
    authorized = true
    let slowTile = UUID()
    func addSlow(_ label: String, key: String, payload: String, deadline: TimeInterval,
                 delay: UInt64 = 0) {
        q.submit(tileId: slowTile, agentId: f.agentId, key: key, operation: "test", payload: payload,
                 deadline: Date().addingTimeInterval(deadline), inputCount: inputCount,
                 currentInputCount: { inputCount }, authorize: { nil },
                 action: { _ in
                     if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                     effects.append(label)
                     return reply(label)
                 }, completion: { answers[label] = $0 })
    }
    addSlow("slow", key: "slow", payload: "slow", deadline: 0.05, delay: 500_000_000)
    addSlow("blocked", key: "blocked", payload: "blocked", deadline: 0.12)
    let timeout = Date().addingTimeInterval(3)
    while (answers["slow"] == nil || answers["blocked"] == nil), Date() < timeout {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    try require(error("slow", .outcomeUnknown), "a started action that times out must report an unknown outcome")
    try require(error("blocked", .busy) && !effects.contains("blocked"), "later actions must not overlap a timed-out action")
    addSlow("slow-replay", key: "slow", payload: "slow", deadline: 2)
    try require(answers["slow-replay"] == answers["slow"], "retry after timeout must reuse its outcome")
    let completionDeadline = Date().addingTimeInterval(3)
    while !effects.contains("slow"), Date() < completionDeadline {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    try require(effects.filter { $0 == "slow" }.count == 1 && !effects.contains("slow-replay"), "a timed-out action must never replay")
    // A rejection can synchronously call back into the service and enqueue
    // more work. The outer drain must not start a second action concurrently.
    let reentrantTile = UUID()
    func nested(_ label: String, delay: UInt64 = 0) {
        q.submit(tileId: reentrantTile, agentId: f.agentId, key: label, operation: "test", payload: label,
                 deadline: Date().addingTimeInterval(2), inputCount: inputCount,
                 currentInputCount: { inputCount }, authorize: { nil },
                 action: { _ in
                     if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                     effects.append(label)
                     return reply(label)
                 }, completion: { answers[label] = $0 })
    }
    q.submit(tileId: reentrantTile, agentId: f.agentId, key: "reentrant-denied", operation: "test", payload: "denied",
             deadline: Date().addingTimeInterval(2), inputCount: inputCount,
             currentInputCount: { inputCount },
             authorize: { WorkspaceAPIError(code: .permissionDenied, message: "revoked") },
             action: { _ in reply("unexpected") }, completion: { _ in
                 nested("reentrant-first", delay: 150_000_000)
                 nested("reentrant-second")
             })
    let nestedDeadline = Date().addingTimeInterval(3)
    while (answers["reentrant-first"] == nil || answers["reentrant-second"] == nil), Date() < nestedDeadline {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    try require(effects.filter { $0.hasPrefix("reentrant-") } == ["reentrant-first", "reentrant-second"],
                "reentrant completion must preserve per-tile order")
    // Cached results must not retain the action's captured browser/runtime.
    final class LifetimeToken: @unchecked Sendable {}
    weak var weakToken: LifetimeToken?
    do {
        let token = LifetimeToken()
        weakToken = token
        q.submit(tileId: UUID(), agentId: f.agentId, key: "lifetime", operation: "test", payload: "lifetime",
                 deadline: Date().addingTimeInterval(2), inputCount: inputCount,
                 currentInputCount: { _ = token; return inputCount },
                 authorize: { _ = token; return nil },
                 action: { _ in _ = token; return reply("lifetime") },
                 completion: { answers["lifetime"] = $0 })
    }
    let lifetimeDeadline = Date().addingTimeInterval(3)
    while answers["lifetime"] == nil, Date() < lifetimeDeadline {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    let releaseDeadline = Date().addingTimeInterval(1)
    while weakToken != nil, Date() < releaseDeadline {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    let lifetimeReleased = weakToken == nil

    // Access can be revoked while an asynchronous read is in flight. Its
    // potentially sensitive result must not be delivered or cached as success.
    authorized = true
    let revocationTile = UUID()
    q.submit(tileId: revocationTile, agentId: f.agentId, key: "inflight", operation: "test", payload: "private",
             deadline: Date().addingTimeInterval(2), inputCount: inputCount,
             currentInputCount: { inputCount },
             authorize: { authorized ? nil : WorkspaceAPIError(code: .permissionDenied, message: "revoked") },
             action: { _ in
                 try? await Task.sleep(nanoseconds: 150_000_000)
                 return reply("sensitive page data")
             }, completion: { answers["inflight"] = $0 })
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { authorized = false }
    let revocationDeadline = Date().addingTimeInterval(3)
    while answers["inflight"] == nil, Date() < revocationDeadline {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    let inflightDenied = error("inflight", .outcomeUnknown)
    try require(lifetimeReleased && inflightDenied,
                "cached actions must release their closures and deny results after revocation (released=\(lifetimeReleased), denied=\(inflightDenied))")
    authorized = true
    q.submit(tileId: revocationTile, agentId: f.agentId, key: "inflight", operation: "test", payload: "private",
             deadline: Date().addingTimeInterval(2), inputCount: inputCount,
             currentInputCount: { inputCount }, authorize: { nil },
             action: { _ in reply("unexpected replay") }, completion: { answers["inflight-replay"] = $0 })
    try require(error("inflight-replay", .outcomeUnknown), "reauthorization must not reveal a result produced after revocation")

    // A user taking over during an async action must not send that action's
    // later page data back as a successful result.
    let takeoverTile = UUID()
    let previousInput = inputCount
    q.submit(tileId: takeoverTile, agentId: f.agentId, key: "inflight-takeover", operation: "test", payload: "private",
             deadline: Date().addingTimeInterval(2), inputCount: previousInput,
             currentInputCount: { inputCount }, authorize: { nil },
             action: { _ in
                 try? await Task.sleep(nanoseconds: 150_000_000)
                 return reply("page after takeover")
             }, completion: { answers["inflight-takeover"] = $0 })
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { inputCount += 1 }
    let takeoverDeadline = Date().addingTimeInterval(3)
    while answers["inflight-takeover"] == nil, Date() < takeoverDeadline {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    try require(error("inflight-takeover", .outcomeUnknown), "user takeover during an action must not deliver the result")

    // A timeout must remain non-replayable even after this agent issues more
    // than the ordinary bounded result-cache capacity.
    for index in 0..<70 {
        var settled = false
        var succeeded = false
        q.submit(tileId: UUID(), agentId: f.agentId, key: "flood-\(index)", operation: "test", payload: "same",
                 deadline: Date().addingTimeInterval(3), inputCount: inputCount,
                 currentInputCount: { inputCount }, authorize: { nil },
                 action: { _ in reply("flood") }, completion: { result in
                     if case .result = result { succeeded = true }
                     settled = true
                 })
        let floodDeadline = Date().addingTimeInterval(3)
        while !settled, Date() < floodDeadline {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        try require(settled && succeeded, "retry-history flood request must finish")
    }
    addSlow("slow-after-flood", key: "slow", payload: "slow", deadline: 2)
    try require(error("slow-after-flood", .outcomeUnknown) && !effects.contains("slow-after-flood"),
                "an uncertain action must not replay after ordinary cache eviction")

    // One agent's traffic cannot evict another agent's retry history.
    let other = AgentID(rawValue: UUID())
    let ownTile = UUID()
    func ownRetry(_ label: String) {
        q.submit(tileId: ownTile, agentId: f.agentId, key: "isolated-key", operation: "test", payload: "same",
                 deadline: Date().addingTimeInterval(3), inputCount: inputCount,
                 currentInputCount: { inputCount }, authorize: { nil },
                 action: { _ in effects.append(label); return reply(label) },
                 completion: { answers[label] = $0 })
    }
    ownRetry("isolated-first")
    let ownDeadline = Date().addingTimeInterval(3)
    while answers["isolated-first"] == nil, Date() < ownDeadline {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    try require(answers["isolated-first"] != nil, "original isolated request must finish")
    for index in 0..<70 {
        var settled = false
        var succeeded = false
        q.submit(tileId: UUID(), agentId: other, key: "other-\(index)", operation: "test", payload: "same",
                 deadline: Date().addingTimeInterval(3), inputCount: inputCount,
                 currentInputCount: { inputCount }, authorize: { nil },
                 action: { _ in reply("other") }, completion: { result in
                     if case .result = result { succeeded = true }
                     settled = true
                 })
        let otherDeadline = Date().addingTimeInterval(3)
        while !settled, Date() < otherDeadline {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        try require(settled && succeeded, "other agent's request must finish")
    }
    ownRetry("isolated-replay")
    try require(answers["isolated-replay"] == answers["isolated-first"] && !effects.contains("isolated-replay"),
                "another agent must not evict this agent's retry result")
    // If all retained keys are uncertain, no safe eviction is possible.
    // Refuse a new action rather than forgetting a potentially committed one.
    let cappedAgent = AgentID(rawValue: UUID())
    var capTiles: [UUID] = []
    var capReplies = 0
    var capUnknown = 0
    var capStarted = 0
    var capReturned = 0
    for index in 0..<64 {
        let capTile = UUID()
        capTiles.append(capTile)
        q.submit(tileId: capTile, agentId: cappedAgent, key: "cap-\(index)", operation: "test", payload: "same",
                 deadline: Date().addingTimeInterval(0.5), inputCount: inputCount,
                 currentInputCount: { inputCount }, authorize: { nil },
                 action: { _ in
                     capStarted += 1
                     try? await Task.sleep(nanoseconds: 1_000_000_000)
                     capReturned += 1
                     return reply("late")
                 }, completion: { result in
                     if case let .error(error) = result, error.code == .outcomeUnknown { capUnknown += 1 }
                     capReplies += 1
                 })
    }
    let capDeadline = Date().addingTimeInterval(5)
    while capReplies < 64, Date() < capDeadline {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    try require(capReplies == 64 && capUnknown == 64, "all timed-out active actions must remain uncertain")
    var capRefusal: WorkspaceAPIService.Reply?
    var overflowRan = false
    q.submit(tileId: UUID(), agentId: cappedAgent, key: "overflow", operation: "test", payload: "same",
             deadline: Date().addingTimeInterval(3), inputCount: inputCount,
             currentInputCount: { inputCount }, authorize: { nil },
             action: { _ in overflowRan = true; return reply("overflow") },
             completion: { capRefusal = $0 })
    guard case let .error(capError)? = capRefusal else {
        throw WorkspaceAPIChecks.Failure(message: "full uncertain history must refuse a new action")
    }
    try require(capError.code == .busy && !overflowRan, "full uncertain history must fail closed")
    var capReplay: WorkspaceAPIService.Reply?
    q.submit(tileId: capTiles[0], agentId: cappedAgent, key: "cap-0", operation: "test", payload: "same",
             deadline: Date().addingTimeInterval(3), inputCount: inputCount,
             currentInputCount: { inputCount }, authorize: { nil },
             action: { _ in overflowRan = true; return reply("replayed") },
             completion: { capReplay = $0 })
    guard case let .error(replayError)? = capReplay else {
        throw WorkspaceAPIChecks.Failure(message: "uncertain capped action must remain recoverable")
    }
    try require(replayError.code == .outcomeUnknown && !overflowRan, "uncertain capped action must not replay")
    let returnDeadline = Date().addingTimeInterval(5)
    while capReturned < capStarted, Date() < returnDeadline {
        _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    try require(capReturned == capStarted, "late capped actions must finish before teardown")
    // Images are large and persist in retries. A host-wide bound must hold
    // even when several agents each take screenshots in one session.
    let imageQueue = BrowserActionQueue()
    let imageTile = UUID()
    let imageAgents = (0..<3).map { _ in AgentID(rawValue: UUID()) }
    let encoded = String(repeating: "a", count: 3 * 1_024 * 1_024)
    var imageReplies = 0
    var imageEffects = 0
    for n in 0..<3 {
        imageQueue.submit(tileId: imageTile, agentId: imageAgents[n], key: "image-\(n)", operation: "browser.take_screenshot", payload: "same",
            deadline: Date().addingTimeInterval(5), inputCount: 0, currentInputCount: { 0 }, authorize: { nil },
            action: { _ in imageEffects += 1; return .result(["image": AnyHashableJSON(any: ["mimeType": "image/png", "data": encoded])]) },
            completion: { _ in imageReplies += 1 })
    }
    let imageDeadline = Date().addingTimeInterval(5)
    while imageReplies < 3 && Date() < imageDeadline { _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
    try require(imageReplies == 3 && imageQueue.qaCachedImageBytes <= BrowserActionQueue.imageCacheByteLimit,
                "screenshot replay cache must have a host-wide byte bound")
    var imageRetry: WorkspaceAPIService.Reply?
    imageQueue.submit(tileId: imageTile, agentId: imageAgents[0], key: "image-0", operation: "browser.take_screenshot", payload: "same",
        deadline: Date().addingTimeInterval(2), inputCount: 0, currentInputCount: { 0 }, authorize: { nil },
        action: { _ in imageEffects += 1; return reply("unexpected") }, completion: { imageRetry = $0 })
    guard case let .error(imageRetryError)? = imageRetry else {
        throw WorkspaceAPIChecks.Failure(message: "an evicted screenshot must leave a tombstone")
    }
    try require(imageRetryError.code == .outcomeUnknown && imageEffects == 3, "an evicted screenshot must never replay its capture")
    // A stalled inventory scan must not hold the global open admission after
    // its deadline, and an old release must not free its successor's slot.
    let admission = BrowserOpenAdmission()
    var firstReservation: UUID?
    var secondReservation: UUID?
    var thirdReservation: UUID?
    Task { @MainActor in firstReservation = await admission.acquire(deadline: Date().addingTimeInterval(0.12)) }
    let firstDeadline = Date().addingTimeInterval(1)
    while firstReservation == nil && Date() < firstDeadline { _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
    Task { @MainActor in secondReservation = await admission.acquire(deadline: Date().addingTimeInterval(2)) }
    let secondDeadline = Date().addingTimeInterval(1)
    while secondReservation == nil && Date() < secondDeadline { _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
    guard let firstReservation, let secondReservation else {
        throw WorkspaceAPIChecks.Failure(message: "an expired inventory reservation must release the next browser open")
    }
    Task { @MainActor in thirdReservation = await admission.acquire(deadline: Date().addingTimeInterval(2)) }
    admission.release(firstReservation)
    let staleDeadline = Date().addingTimeInterval(0.1)
    while Date() < staleDeadline { _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
    try require(thirdReservation == nil, "a stale inventory completion must not release a later reservation")
    admission.release(secondReservation)
    let thirdDeadline = Date().addingTimeInterval(1)
    while thirdReservation == nil && Date() < thirdDeadline { _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01)) }
    try require(thirdReservation != nil, "the current reservation must admit its waiting successor")
    if let thirdReservation { admission.release(thirdReservation) }
    print("Browser action queue: FIFO, pending/completed idempotency, deadline, takeover, revocation, tombstone capacity, per-agent retry isolation, closure release, reentrancy and main-queue responsiveness passed")
}
