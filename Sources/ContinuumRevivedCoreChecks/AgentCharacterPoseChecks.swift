import ContinuumRevivedAgentUI
import ContinuumRevivedCore
import Foundation

// Plan: .plans/110-agent-characters/README.md, slice 2.
//
// The state machine, table-driven: every inbox state x attention x step, the
// clip expiries, the quiet clock and Reduce Motion. The last section drives the
// real turn-presence reducer with runtime events, so "a step failed" is witnessed
// from the event the runner emits, not from a hand-set date.
func runAgentCharacterPoseChecks() {
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAIL agent character pose: \(message)\n", stderr)
            exit(1)
        }
    }
    let now = Date(timeIntervalSinceReferenceDate: 820_000_000)
    var rows = 0

    // 1. Action from the latest step, across the kinds and the three CLIs' titles.
    let steps: [(ItemKind, String?, AgentCharacterLoop)] = [
        (.fileChange, nil, .type), (.fileChange, "Sources/App.swift", .type),
        (.webSearch, "swift concurrency", .dabble),
        (.reasoning, nil, .think), (.plan, nil, .think), (.assistantMessage, nil, .think),
        (.subagent, "Explore", .think), (.compaction, nil, .think), (.error, "boom", .think),
        // Claude's built-in tools, by name.
        (.mcpToolCall, "Edit", .type), (.mcpToolCall, "MultiEdit", .type), (.mcpToolCall, "Write", .type),
        (.mcpToolCall, "NotebookEdit", .type), (.mcpToolCall, "Grep", .dabble), (.mcpToolCall, "Glob", .dabble),
        (.mcpToolCall, "WebSearch", .dabble), (.mcpToolCall, "WebFetch", .dabble), (.mcpToolCall, "Read", .read),
        (.mcpToolCall, "TodoWrite", .think), (.commandExecution, "Bash", .run),
        // Pi's lowercase tools.
        (.unknown("tool"), "read", .read), (.unknown("tool"), "edit", .type), (.unknown("tool"), "grep", .dabble),
        (.commandExecution, "bash", .run),
        // Codex's command lines.
        (.commandExecution, "rg -n saveCanvas Sources", .dabble), (.commandExecution, "find . -name '*.swift'", .dabble),
        (.commandExecution, "ls -la", .dabble), (.commandExecution, "cat README.md", .read),
        (.commandExecution, "sed -n 1,80p Sources/App.swift", .read), (.commandExecution, "sed -i '' s/a/b/ f", .run),
        (.commandExecution, "swift build --product Array", .run), (.commandExecution, "git status", .run),
        (.commandExecution, "/usr/bin/grep -r foo .", .dabble), (.commandExecution, "FOO=1 head -5 x", .read),
        (.commandExecution, nil, .run),
        // Words, for a tool Array cannot classify.
        (.mcpToolCall, "Searching the web", .dabble), (.mcpToolCall, "Reading notes", .read),
        (.mcpToolCall, "mcp__linear__create_issue", .think),
    ]
    for (kind, title, want) in steps {
        let got = AgentCharacterActivityProjection.action(kind: kind, title: title)
        expect(got == want, "\(kind.rawValue) \(title ?? "nil") acts \(want), got \(got)")
        rows += 1
    }

    // 2. Before the first step: the title's first job word.
    let titles: [(String, AgentCharacterLoop?)] = [
        ("Fix the zoom stutter", .type), ("Find every caller of saveCanvas", .dabble),
        ("Review the sign-in PR", .read), ("Run the release matrix", .run), ("Audit the notification paths", .read),
        ("Write the release notes", .type), ("Delete the stale benches", nil), ("Hello there", nil),
        ("Re-check the fixes", .read), ("Quickly fixing tests", .type), ("Tests, then fix", .run),
    ]
    for (title, want) in titles {
        expect(AgentCharacterPose.action(forTitle: title) == want, "title \"\(title)\" acts \(String(describing: want))")
        rows += 1
    }

    // 3. Every state x attention x step x motion.
    let old = now.addingTimeInterval(-600)
    for state in InboxState.allCases {
        for attention in InboxAttention.allCases {
            for action in [nil] + AgentCharacterLoop.allCases.map(Optional.some) {
                for outcome in [nil, AgentCharacterActivity.Outcome.succeeded, .failed, .stopped] {
                    let activity = AgentCharacterActivity(
                        action: action, lastOutputAt: now.addingTimeInterval(-5), promptSentAt: old,
                        endedAt: old, outcome: outcome)
                    var snapshot = AgentCharacterSnapshot(state: state, attention: attention, activity: activity,
                                                          title: "Hello", allowsMotion: true)
                    let moving = AgentCharacterPose.resolve(snapshot, now: now)
                    snapshot.allowsMotion = false
                    let still = AgentCharacterPose.resolve(snapshot, now: now)
                    let label = "\(state) \(attention) \(String(describing: action)) \(String(describing: outcome))"
                    // Reduce Motion: always one held frame, the same one the moving plan rests on.
                    expect(still == .still(moving.still) && !still.isAnimated, "\(label): Reduce Motion is a still")
                    switch state {
                    case .working:
                        let loop = action ?? .think
                        expect(moving.segments == [.loop(loop, slow: false)] && moving.still == .loop(loop),
                               "\(label): working plays its step's loop")
                    case .approval, .input:
                        expect(moving.segments == [.repeating(.wave)] && moving.still == .clip(.wave),
                               "\(label): waits for you with a wave")
                    case .failed:
                        expect(moving == .still(.failed), "\(label): failed and seen holds the failed pose")
                    case .ready:
                        let pose: AgentCharacterStill = outcome == .succeeded ? .done : outcome == .failed ? .failed : .clip(.idle)
                        expect(moving == .still(pose), "\(label): resting holds still (\(pose))")
                    }
                    expect(moving.isAnimated == (state == .working || state == .approval || state == .input),
                           "\(label): only agents in motion animate")
                    rows += 1
                }
            }
        }
    }

    // 4. Clip expiries.
    func plan(_ state: InboxState, _ activity: AgentCharacterActivity, at seconds: TimeInterval) -> AgentCharacterPlan {
        AgentCharacterPose.resolve(AgentCharacterSnapshot(state: state, activity: activity), now: now.addingTimeInterval(seconds))
    }
    let failedStep = AgentCharacterActivity(action: .run, lastOutputAt: now, stepFailedAt: now)
    expect(plan(.working, failedStep, at: 0.74).segments == [.clip(.flinch, startedAt: now, duration: 0.75), .loop(.run, slow: false)],
           "a failed step flinches for 750 ms")
    expect(plan(.working, failedStep, at: 0.76).segments == [.loop(.run, slow: false)], "and then goes back to its loop")
    let prompted = AgentCharacterActivity(action: .type, lastOutputAt: now, promptSentAt: now)
    expect(plan(.working, prompted, at: 2.39).segments.first == .clip(.noticed, startedAt: now, duration: 2.4),
           "a new prompt is noticed for 2.4 s")
    expect(plan(.working, prompted, at: 2.41).segments == [.loop(.type, slow: false)], "and then the loop")
    let finished = AgentCharacterActivity(endedAt: now, outcome: .succeeded)
    expect(plan(.ready, finished, at: 2.39).segments == [.clip(.cheer, startedAt: now, duration: 2.4), .hold(.done)],
           "finishing cheers for 2.4 s, then holds done")
    expect(plan(.ready, finished, at: 2.41) == .still(.done), "and after 2.4 s it is still")
    let broke = AgentCharacterActivity(endedAt: now, outcome: .failed)
    expect(plan(.failed, broke, at: 1).segments == [.clip(.droop, startedAt: now, duration: 2.4), .hold(.failed)],
           "failing droops, then holds failed")
    expect(plan(.failed, broke, at: 2.41) == .still(.failed), "and after 2.4 s it is still")

    // 5. The quiet clock: half speed at 40 s, asleep at 180 s, and when to look again.
    let quiet = AgentCharacterActivity(action: .read, lastOutputAt: now)
    let fresh = plan(.working, quiet, at: 39.9)
    expect(fresh.segments == [.loop(.read, slow: false)] && fresh.revisitAt == now.addingTimeInterval(40),
           "under 40 s quiet: full speed, revisit at 40 s")
    let slow = plan(.working, quiet, at: 40)
    expect(slow.segments == [.loop(.read, slow: true)] && slow.revisitAt == now.addingTimeInterval(180),
           "40 s quiet: half speed, revisit at 180 s")
    let asleep = plan(.working, quiet, at: 180)
    expect(asleep.segments == [.repeating(.asleep)] && asleep.still == .clip(.asleep) && asleep.revisitAt == nil,
           "180 s quiet: asleep")
    let stillAsleep = AgentCharacterPose.resolve(
        AgentCharacterSnapshot(state: .working, activity: quiet, allowsMotion: false), now: now.addingTimeInterval(200))
    expect(stillAsleep == .still(.clip(.asleep)), "Reduce Motion shows the asleep pose still")

    // 6. Through the real reducer: a failed command flinches, a failed search does not.
    var presence = AgentTurnPresence()
    let t0 = now
    presence.arm(at: t0)
    presence.reduce(.turnStarted(threadId: "t", turnId: "u"), at: t0.addingTimeInterval(0.1))
    presence.reduce(.itemStarted(threadId: "t", itemId: "g", kind: .mcpToolCall, title: "Grep"), at: t0.addingTimeInterval(1))
    presence.reduce(.itemCompleted(threadId: "t", itemId: "g", kind: .mcpToolCall, status: .failed), at: t0.addingTimeInterval(2))
    expect(presence.lastStepFailedAt == nil, "a search that finds nothing is not a failure")
    var activity = AgentCharacterActivityProjection.activity(presence: presence, terminalEvent: nil, latestPromptAt: nil)
    expect(activity.action == .dabble, "between steps the character keeps its latest step (Grep → dabble)")
    presence.reduce(.itemStarted(threadId: "t", itemId: "b", kind: .commandExecution, title: "Bash"), at: t0.addingTimeInterval(3))
    activity = AgentCharacterActivityProjection.activity(presence: presence, terminalEvent: nil, latestPromptAt: nil)
    expect(activity.action == .run, "an open command runs")
    presence.reduce(.itemCompleted(threadId: "t", itemId: "b", kind: .commandExecution, status: .failed), at: t0.addingTimeInterval(4))
    activity = AgentCharacterActivityProjection.activity(presence: presence, terminalEvent: nil, latestPromptAt: nil)
    expect(activity.stepFailedAt == t0.addingTimeInterval(4) && activity.lastOutputAt == t0.addingTimeInterval(4),
           "a failed command stamps the flinch and the quiet clock")
    let flinch = AgentCharacterPose.resolve(AgentCharacterSnapshot(state: .working, activity: activity),
                                            now: t0.addingTimeInterval(4.2))
    expect(flinch.segments.first == .clip(.flinch, startedAt: t0.addingTimeInterval(4), duration: 0.75),
           "the reducer's failure reaches the character as a flinch")
    presence.reduce(.turnCompleted(threadId: "t", turnId: "u", outcome: .completed, errorMessage: nil), at: t0.addingTimeInterval(9))
    activity = AgentCharacterActivityProjection.activity(presence: presence, terminalEvent: nil, latestPromptAt: nil)
    expect(activity.outcome == .succeeded && activity.endedAt == t0.addingTimeInterval(9), "a completed turn is a success")
    presence.arm(at: t0.addingTimeInterval(20))
    expect(presence.lastStepFailedAt == nil, "a new prompt clears the failure")
    // With no live turn, the durable terminal event answers.
    let durable = AgentCharacterActivityProjection.activity(
        presence: nil, terminalEvent: AgentTerminalEvent(sequence: 1, turnID: nil, outcome: .runtimeError, endedAt: t0),
        latestPromptAt: t0)
    expect(durable.outcome == .failed && durable.endedAt == t0 && durable.promptSentAt == t0, "the record's terminal event")

    print("Agent character pose checks passed: \(rows) table rows, clip expiries, the 40 s / 180 s quiet clock, Reduce Motion, and the reducer's step failure")
}
