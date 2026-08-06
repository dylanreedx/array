import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// Queue 91 P2 — host-local What derivation. These checks pin the private
// observation side channel separately from the Codable runtime/activity streams.
// Tool arguments may inform the local projection, but never alter or widen either
// sync-safe stream.
func runAgentWhatProjectionChecks() {
    checkPiWhatObservationSideChannel()
    checkWhatProjectorLocationSeparation()
    checkWhatLifecycleAndStaleness()
    checkWhatDeduplication()
    print("Agent What projection checks passed: Pi tool/lifecycle observations, stable Home/Where, external targets, redaction, staleness, deduplication, and unchanged I5-safe event fan-out")
}

// P2.R1/P2.R4/P2.R6 — parse representative real Pi JSON shapes into a
// non-Codable local observation while proving the existing normalized and
// companion activity streams are byte-for-byte independent of the observer.
private func checkPiWhatObservationSideChannel() {
    let homePath = "/tmp/continuum-what/project"
    let secretCommand = "cd /tmp/continuum-what/OTHER && deploy --token SECRET-COMMAND-BODY"
    let secretQuery = "SECRET-SEARCH-QUERY-" + String(repeating: "q", count: 300)
    let fixture: [String] = [
        #"{"type":"session","version":3,"id":"SID-what","timestamp":"2026-08-06T00:00:00Z","cwd":"/tmp/continuum-what/project"}"#,
        #"{"type":"agent_start"}"#,
        #"{"type":"turn_start"}"#,
        #"{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","contentIndex":0,"delta":"SECRET-REASONING-BODY"}}"#,
        #"{"type":"tool_execution_start","toolCallId":"read-1","toolName":"read","args":{"path":"Sources/App.swift","offset":1,"limit":40}}"#,
        #"{"type":"tool_execution_end","toolCallId":"read-1","toolName":"read","result":{"content":[{"type":"text","text":"SECRET-FILE-BODY"}]},"isError":false}"#,
        #"{"type":"tool_execution_start","toolCallId":"edit-1","toolName":"edit","args":{"path":"/tmp/continuum-what/external/Router.swift","oldText":"SECRET-OLD","newText":"SECRET-NEW"}}"#,
        #"{"type":"tool_execution_end","toolCallId":"edit-1","toolName":"edit","isError":false}"#,
        "{\"type\":\"tool_execution_start\",\"toolCallId\":\"bash-1\",\"toolName\":\"bash\",\"args\":{\"command\":\"\(secretCommand)\",\"timeout\":30}}",
        #"{"type":"tool_execution_end","toolCallId":"bash-1","toolName":"bash","isError":false}"#,
        "{\"type\":\"tool_execution_start\",\"toolCallId\":\"grep-1\",\"toolName\":\"grep\",\"args\":{\"pattern\":\"\(secretQuery)\",\"path\":\"Sources\"}}",
        #"{"type":"tool_execution_end","toolCallId":"grep-1","toolName":"grep","isError":false}"#,
        #"{"type":"turn_end","message":{"role":"assistant"}}"#,
        #"{"type":"agent_settled"}"#,
    ]

    final class ObservationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [AgentRuntimeObservation] = []
        func append(_ observation: AgentRuntimeObservation) {
            lock.withLock { storage.append(observation) }
        }
        var observations: [AgentRuntimeObservation] { lock.withLock { storage } }
    }

    let observedAt = Date(timeIntervalSinceReferenceDate: 808_000_000)
    let box = ObservationBox()
    var observed = PiEventTranslator(
        workingDirectory: URL(fileURLWithPath: homePath, isDirectory: true),
        now: { observedAt })
    observed.onRuntimeObservation = { box.append($0) }
    let events = observed.translate(stream: fixture)

    var plain = PiEventTranslator(
        workingDirectory: URL(fileURLWithPath: homePath, isDirectory: true),
        now: { observedAt })
    let plainEvents = plain.translate(stream: fixture)
    expect(events == plainEvents,
           "Agent What: installing the local observer changed normalized event fan-out or ordering")

    let toolActivities = box.observations.compactMap { observation -> (String, AgentObservedActivity)? in
        guard case let .toolActivity(itemId, activity) = observation else { return nil }
        return (itemId, activity)
    }
    expect(toolActivities.map(\.0) == ["read-1", "edit-1", "bash-1", "grep-1"],
           "Agent What: expected one start observation per tool in source order, got \(toolActivities.map(\.0))")
    expect(toolActivities.map(\.1.operation) == [.reading, .editing, .running, .searching],
           "Agent What: read/edit/bash/grep operations classified incorrectly: \(toolActivities.map(\.1.operation))")
    expect(toolActivities[0].1.targetPath?.path == "\(homePath)/Sources/App.swift",
           "Agent What: relative read target must resolve against Pi runtime cwd")
    expect(toolActivities[1].1.targetPath?.path == "/tmp/continuum-what/external/Router.swift",
           "Agent What: absolute external edit target must remain absolute")
    expect(toolActivities[2].1.targetPath == nil,
           "Agent What: Bash command text must not be reinterpreted as a path target")
    expect(toolActivities[3].1.targetPath?.path == "\(homePath)/Sources",
           "Agent What: search scope must resolve without retaining its query")
    expect(toolActivities.allSatisfy { $0.1.startedAt == observedAt && $0.1.updatedAt == observedAt },
           "Agent What: local observations must carry evidence timestamps")

    let localDescription = String(describing: box.observations)
    for secret in [secretCommand, secretQuery, "SECRET-REASONING-BODY", "SECRET-FILE-BODY", "SECRET-OLD", "SECRET-NEW"] {
        expect(!localDescription.contains(secret),
               "Agent What: private observation retained forbidden command/query/body text: \(secret.prefix(40))")
    }
    expect(!((box.observations[0] as Any) is any Encodable),
           "Agent What: host-local runtime observations must not become Encodable")

    // Hostile path text is not useful filesystem identity and must not become a
    // future UI/log injection surface. Build with JSONSerialization so escaping is
    // identical to a real Pi line.
    func toolLine(id: String, path: String) -> String {
        let object: [String: Any] = [
            "type": "tool_execution_start",
            "toolCallId": id,
            "toolName": "read",
            "args": ["path": path],
        ]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    let hostileBox = ObservationBox()
    var hostile = PiEventTranslator(
        workingDirectory: URL(fileURLWithPath: homePath, isDirectory: true),
        now: { observedAt })
    hostile.onRuntimeObservation = { hostileBox.append($0) }
    _ = hostile.translate(stream: [
        toolLine(id: "control-path", path: "Sources/A\n\u{001B}[31mB.swift"),
        toolLine(id: "oversized-path", path: String(repeating: "x", count: 4_097)),
    ])
    let hostileActivities = hostileBox.observations.compactMap { observation -> AgentObservedActivity? in
        guard case let .toolActivity(_, activity) = observation else { return nil }
        return activity
    }
    expect(hostileActivities.count == 2 && hostileActivities.allSatisfy { $0.targetPath == nil },
           "Agent What: control-character/oversized paths must degrade to targetless activity")

    let encodedEvents = String(decoding: try! JSONEncoder().encode(events), as: UTF8.self)
    let drafts = events.compactMap {
        ManagedAgentActivityBridge.draft(
            for: $0,
            agentId: UUID(uuidString: "A9200000-0000-4000-8000-000000000001")!,
            tileId: nil,
            status: .working,
            now: observedAt)
    }
    let published = drafts.enumerated().map {
        AgentActivityEvent(stamping: $0.element, sequence: UInt64($0.offset), replicaId: UUID())
    }
    let encodedPublished = String(decoding: try! JSONEncoder().encode(published), as: UTF8.self)
    // AgentRuntimeEvent is the local transcript stream and deliberately carries
    // assistant/reasoning deltas. The existing sync bridge must drop those bodies;
    // tool args, cwd, and results must be absent from both layers.
    for secret in ["/tmp/continuum-what", secretCommand, secretQuery, "SECRET-FILE-BODY", "SECRET-OLD", "SECRET-NEW"] {
        expect(!encodedEvents.contains(secret) && !encodedPublished.contains(secret),
               "Agent What I5: private tool/session data crossed a Codable stream: \(secret.prefix(40))")
    }
    expect(!encodedPublished.contains("SECRET-REASONING-BODY"),
           "Agent What I5: reasoning text reached published companion activity")
}

// P2.R2/P2.R3 — tool targets change What only. The sole Where input is an
// explicit runtime working-directory observation; textual `cd` inside Bash was
// deliberately discarded by the adapter above.
private func checkWhatProjectorLocationSeparation() {
    let projectId = UUID(uuidString: "A9200000-0000-4000-8000-000000000010")!
    let home = AgentHome(
        projectId: projectId,
        projectRoot: URL(fileURLWithPath: "/tmp/continuum-what/project", isDirectory: true),
        checkoutRoot: URL(fileURLWithPath: "/tmp/continuum-what/project", isDirectory: true))
    let time = Date(timeIntervalSinceReferenceDate: 808_000_100)
    var projector = AgentLocationProjector(
        home: home,
        whereDirectory: home.checkoutRoot,
        configuration: .init(staleAfter: 60))
    projector.ingest(.workingDirectory(home.checkoutRoot, observedAt: time))
    projector.ingest(.toolActivity(
        itemId: "bash-1",
        activity: AgentObservedActivity(
            operation: .running,
            targetPath: nil,
            startedAt: time,
            updatedAt: time,
            evidenceSource: .toolEvent)))
    let afterBash = projector.snapshot(at: time)
    expect(afterBash.home == home && afterBash.workingLocation.directory == home.checkoutRoot,
           "Agent What: Bash text/operation must not change Home or Where")

    let external = URL(fileURLWithPath: "/tmp/continuum-what/reference/Router.swift")
    let editTime = time.addingTimeInterval(1)
    projector.ingest(.toolActivity(
        itemId: "edit-2",
        activity: AgentObservedActivity(
            operation: .editing,
            targetPath: external,
            startedAt: editTime,
            updatedAt: editTime,
            evidenceSource: .toolEvent)))
    let afterExternal = projector.snapshot(at: editTime)
    expect(afterExternal.home == home && afterExternal.workingLocation.directory == home.checkoutRoot,
           "Agent What: external activity must leave Home and Where stable")
    expect(afterExternal.what?.targetPath == external.standardizedFileURL
            && afterExternal.whatRelationToHome == .outside,
           "Agent What: external activity target must remain visibly outside Home")

    // The matching normalized start is consumed once and cannot erase the richer
    // path. Successful completion advances current What to thinking while retaining
    // the useful edit explicitly in the same canonical snapshot.
    projector.ingest(.itemStarted(
        threadId: "t", itemId: "edit-2", kind: .fileChange, title: "edit"),
        at: editTime.addingTimeInterval(0.1))
    expect(projector.snapshot(at: editTime.addingTimeInterval(0.1)).what?.targetPath
            == external.standardizedFileURL,
           "Agent What: matching itemStarted must not erase private path evidence")
    projector.ingest(.itemCompleted(
        threadId: "t", itemId: "edit-2", kind: .fileChange, status: .completed),
        at: editTime.addingTimeInterval(0.2))
    let afterCompletion = projector.snapshot(at: editTime.addingTimeInterval(0.2))
    expect(afterCompletion.what?.operation == .thinking,
           "Agent What: current operation must advance after tool completion")
    expect(afterCompletion.lastUsefulWhat?.targetPath == external.standardizedFileURL
            && afterCompletion.lastUsefulWhatRelationToHome == .outside,
           "Agent What: completed tool must retain its last useful external target separately")
}

// P2.R1/P2.R5 — lifecycle observations are content-free and expire only the
// What projection. Agent lifecycle/status derivation remains a separate owner.
private func checkWhatLifecycleAndStaleness() {
    let base = Date(timeIntervalSinceReferenceDate: 808_000_200)
    let home = AgentHome(
        projectId: nil,
        projectRoot: nil,
        checkoutRoot: URL(fileURLWithPath: "/tmp/continuum-what/lifecycle", isDirectory: true))
    var projector = AgentLocationProjector(
        home: home,
        whereDirectory: home.checkoutRoot,
        configuration: .init(staleAfter: 10))

    projector.ingest(.turnStarted(threadId: "t", turnId: "turn"), at: base)
    expect(projector.snapshot(at: base).what?.operation == .thinking,
           "Agent What: turn start must project content-free thinking")
    projector.ingest(.turnCompleted(
        threadId: "t", turnId: "turn", outcome: .completed, errorMessage: nil),
        at: base.addingTimeInterval(1))
    expect(projector.snapshot(at: base.addingTimeInterval(1)).what?.operation == .completed,
           "Agent What: successful turn completion must be observable")
    projector.ingest(.turnCompleted(
        threadId: "t", turnId: "turn-2", outcome: .interrupted, errorMessage: nil),
        at: base.addingTimeInterval(2))
    expect(projector.snapshot(at: base.addingTimeInterval(2)).what?.operation == .interrupted,
           "Agent What: interrupted turn must be observable")
    projector.ingest(.runtimeError(threadId: "t", message: "SECRET provider path /private/x"),
                     at: base.addingTimeInterval(3))
    expect(projector.snapshot(at: base.addingTimeInterval(3)).what?.operation == .failed,
           "Agent What: runtime errors must project failure without retaining the message")
    projector.ingest(.sessionStateChanged(.ready), at: base.addingTimeInterval(4))
    expect(projector.snapshot(at: base.addingTimeInterval(4)).what?.operation == .waiting,
           "Agent What: ready/settled state must project waiting")

    let usefulAt = base.addingTimeInterval(5)
    let lastUseful = AgentObservedActivity(
        operation: .reading,
        targetPath: home.checkoutRoot.appendingPathComponent("README.md"),
        startedAt: usefulAt,
        updatedAt: usefulAt,
        evidenceSource: .toolEvent)
    projector.ingest(.toolActivity(itemId: "read-last", activity: lastUseful))
    expect(projector.lastUsefulActivity == lastUseful,
           "Agent What: last useful tool activity must remain separate from lifecycle What")
    expect(projector.snapshot(at: base.addingTimeInterval(14)).what != nil
            && projector.snapshot(at: base.addingTimeInterval(14)).whatExpiresAt
                == base.addingTimeInterval(15),
           "Agent What: current activity expired early or omitted its exact UI refresh boundary")
    expect(projector.snapshot(at: base.addingTimeInterval(15)).what == nil
            && projector.snapshot(at: base.addingTimeInterval(15)).whatExpiresAt == nil,
           "Agent What: stale current activity/refresh boundary must clear at expiration")
    expect(projector.lastUsefulActivity == lastUseful
            && projector.snapshot(at: base.addingTimeInterval(15)).lastUsefulWhat == lastUseful,
           "Agent What: expiring current activity must not erase last useful activity")
}

// P2.11 — repeated provider updates for one semantic activity do not churn
// timestamps, while a meaningful target change replaces the current value.
private func checkWhatDeduplication() {
    let home = AgentHome(
        projectId: nil,
        projectRoot: nil,
        checkoutRoot: URL(fileURLWithPath: "/tmp/continuum-what/dedupe", isDirectory: true))
    let firstTime = Date(timeIntervalSinceReferenceDate: 808_000_300)
    let secondTime = firstTime.addingTimeInterval(1)
    var projector = AgentLocationProjector(home: home, whereDirectory: home.checkoutRoot)
    let first = AgentObservedActivity(
        operation: .reading,
        targetPath: home.checkoutRoot.appendingPathComponent("A.swift"),
        startedAt: firstTime,
        updatedAt: firstTime,
        evidenceSource: .toolEvent)
    let duplicate = AgentObservedActivity(
        operation: .reading,
        targetPath: home.checkoutRoot.appendingPathComponent("A.swift"),
        startedAt: secondTime,
        updatedAt: secondTime,
        evidenceSource: .toolEvent)
    projector.ingest(.toolActivity(itemId: "read-a", activity: first))
    projector.ingest(.toolActivity(itemId: "read-a-repeat", activity: duplicate))
    expect(projector.snapshot(at: secondTime).what == first,
           "Agent What: semantically duplicate activity must not churn evidence timestamps")

    let changed = AgentObservedActivity(
        operation: .reading,
        targetPath: home.checkoutRoot.appendingPathComponent("B.swift"),
        startedAt: secondTime,
        updatedAt: secondTime,
        evidenceSource: .toolEvent)
    projector.ingest(.toolActivity(itemId: "read-b", activity: changed))
    expect(projector.snapshot(at: secondTime).what == changed,
           "Agent What: a meaningful target change must replace current activity")

    // Delayed provider callbacks cannot move current What or Where backwards.
    let stale = AgentObservedActivity(
        operation: .editing,
        targetPath: home.checkoutRoot.appendingPathComponent("stale.swift"),
        startedAt: firstTime,
        updatedAt: firstTime,
        evidenceSource: .toolEvent)
    projector.ingest(.toolActivity(itemId: "stale", activity: stale))
    expect(projector.snapshot(at: secondTime).what == changed
            && projector.lastUsefulActivity == changed,
           "Agent What: an out-of-order tool observation moved current/last-useful activity backwards")
    let newerWhere = home.checkoutRoot.appendingPathComponent("newer", isDirectory: true)
    let olderWhere = home.checkoutRoot.appendingPathComponent("older", isDirectory: true)
    projector.ingest(.workingDirectory(newerWhere, observedAt: secondTime))
    projector.ingest(.workingDirectory(olderWhere, observedAt: firstTime))
    expect(projector.snapshot(at: secondTime).workingLocation.directory == newerWhere.standardizedFileURL,
           "Agent What: an out-of-order cwd observation moved Where backwards")

    // Suppression is one-shot: after consuming the normalized start that matches
    // private evidence, a malformed provider reuse of the same id is still visible.
    projector.ingest(.toolActivity(itemId: "reused", activity: changed))
    projector.ingest(.itemStarted(
        threadId: "t", itemId: "reused", kind: .commandExecution, title: "read"),
        at: secondTime)
    projector.ingest(.itemStarted(
        threadId: "t", itemId: "reused", kind: .commandExecution, title: "grep"),
        at: secondTime.addingTimeInterval(1))
    expect(projector.snapshot(at: secondTime.addingTimeInterval(1)).what?.operation == .searching,
           "Agent What: a missing completion/reused item id suppressed later generic activity")
}
