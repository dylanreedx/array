import Foundation

// Plan: .plans/110-agent-characters/README.md, slice 2 (§2.3, §4.1)
//
// What a character plays for an agent's state. Pure: the same inputs and `now`
// always give the same plan, so the sidebar row and the tile header agree, and a
// recycled cell lands on the pose the tile shows.
//
// The rule that keeps it cheap and calm: only agents in motion animate. A resting,
// finished or idle agent holds one frame, and everything at rest stays at rest.

/// What Array knows about an agent's latest work, for its character. Built by
/// Core from the turn presence (`AgentCharacterActivityProjection`).
public struct AgentCharacterActivity: Equatable, Sendable {
    public enum Outcome: String, Equatable, Sendable {
        case succeeded
        case failed
        /// Stopped, interrupted or lost: neither a cheer nor a droop.
        case stopped
    }

    /// The loop the latest tool step maps to; nil before the turn's first step.
    public var action: AgentCharacterLoop?
    /// The last time the provider said anything during the live turn.
    public var lastOutputAt: Date?
    /// When the person last sent the agent a prompt.
    public var promptSentAt: Date?
    /// When a tool step last completed with a failure.
    public var stepFailedAt: Date?
    /// When the last turn ended, and how.
    public var endedAt: Date?
    public var outcome: Outcome?

    public init(action: AgentCharacterLoop? = nil, lastOutputAt: Date? = nil, promptSentAt: Date? = nil,
                stepFailedAt: Date? = nil, endedAt: Date? = nil, outcome: Outcome? = nil) {
        self.action = action
        self.lastOutputAt = lastOutputAt
        self.promptSentAt = promptSentAt
        self.stepFailedAt = stepFailedAt
        self.endedAt = endedAt
        self.outcome = outcome
    }
}

/// Everything the resolver reads.
public struct AgentCharacterSnapshot: Equatable, Sendable {
    public var state: InboxState
    public var attention: InboxAttention
    public var activity: AgentCharacterActivity
    /// The agent's title, for its action before its first step ("Fix…" types).
    public var title: String
    /// False under Reduce Motion or Settings' "Never": every state is a still.
    public var allowsMotion: Bool

    public init(state: InboxState, attention: InboxAttention = .none, activity: AgentCharacterActivity = .init(),
                title: String = "", allowsMotion: Bool = true) {
        self.state = state
        self.attention = attention
        self.activity = activity
        self.title = title
        self.allowsMotion = allowsMotion
    }
}

/// What to play, in order, and the frame a still sprite shows.
public struct AgentCharacterPlan: Equatable, Sendable {
    public enum Segment: Equatable, Sendable {
        /// A work loop, repeating on the agent's own phase; `slow` is half speed.
        case loop(AgentCharacterLoop, slow: Bool)
        /// An act-now reaction that repeats: `wave`, `asleep`.
        case repeating(AgentCharacterClip)
        /// A one-shot clip that began at `startedAt` and lasts `duration`.
        case clip(AgentCharacterClip, startedAt: Date, duration: TimeInterval)
        /// One frame, held.
        case hold(AgentCharacterStill)
    }

    public let segments: [Segment]
    /// The model frame: what a paused, pictured or Reduce Motion sprite shows,
    /// and where every one-shot clip ends.
    public let still: AgentCharacterStill
    /// When time alone next changes the plan (slowing at 40 s, sleeping at 180 s).
    /// nil when only a new state can.
    public let revisitAt: Date?

    public init(segments: [Segment], still: AgentCharacterStill, revisitAt: Date?) {
        self.segments = segments
        self.still = still
        self.revisitAt = revisitAt
    }

    public var isAnimated: Bool {
        segments.contains { if case .hold = $0 { return false } else { return true } }
    }

    public static func still(_ still: AgentCharacterStill) -> AgentCharacterPlan {
        AgentCharacterPlan(segments: [.hold(still)], still: still, revisitAt: nil)
    }
}

public enum AgentCharacterPose {
    /// Quiet this long and the loop runs at half speed.
    public static let slowAfter: TimeInterval = 40
    /// Quiet this long and the character dozes ("maybe stuck").
    public static let asleepAfter: TimeInterval = 180
    public static let flinchDuration: TimeInterval = 0.75
    public static let noticedDuration: TimeInterval = 2.4
    /// Cheer and droop are spread over this, then the end pose holds.
    public static let reactionDuration: TimeInterval = 2.4

    public static func resolve(_ snapshot: AgentCharacterSnapshot, now: Date) -> AgentCharacterPlan {
        let plan = motionPlan(snapshot, now: now)
        guard snapshot.allowsMotion else {
            // Reduce Motion: each state's representative still; a cheer or droop
            // jumps straight to its end pose.
            return .still(plan.still)
        }
        return plan
    }

    private static func motionPlan(_ snapshot: AgentCharacterSnapshot, now: Date) -> AgentCharacterPlan {
        let activity = snapshot.activity
        func recent(_ date: Date?, within: TimeInterval) -> Date? {
            guard let date, now.timeIntervalSince(date) >= 0, now.timeIntervalSince(date) < within else { return nil }
            return date
        }
        switch snapshot.state {
        case .working:
            let action = activity.action ?? action(forTitle: snapshot.title) ?? .think
            let anchor = activity.lastOutputAt ?? activity.promptSentAt
            let quiet = anchor.map { max(0, now.timeIntervalSince($0)) } ?? 0
            if let anchor, quiet >= asleepAfter {
                _ = anchor
                return AgentCharacterPlan(segments: [.repeating(.asleep)], still: .clip(.asleep), revisitAt: nil)
            }
            let slow = quiet >= slowAfter
            let revisit = anchor.map { $0.addingTimeInterval(slow ? asleepAfter : slowAfter) }
            let base = AgentCharacterPlan.Segment.loop(action, slow: slow)
            if let sent = recent(activity.promptSentAt, within: noticedDuration) {
                return AgentCharacterPlan(segments: [.clip(.noticed, startedAt: sent, duration: noticedDuration), base],
                                          still: .loop(action), revisitAt: revisit)
            }
            if let failed = recent(activity.stepFailedAt, within: flinchDuration) {
                return AgentCharacterPlan(segments: [.clip(.flinch, startedAt: failed, duration: flinchDuration), base],
                                          still: .loop(action), revisitAt: revisit)
            }
            return AgentCharacterPlan(segments: [base], still: .loop(action), revisitAt: revisit)
        case .approval, .input:
            // Act now: the one resting-looking state that moves.
            return AgentCharacterPlan(segments: [.repeating(.wave)], still: .clip(.wave), revisitAt: nil)
        case .failed:
            if let ended = recent(activity.endedAt, within: reactionDuration) {
                return AgentCharacterPlan(segments: [.clip(.droop, startedAt: ended, duration: reactionDuration), .hold(.failed)],
                                          still: .failed, revisitAt: nil)
            }
            return .still(.failed)
        case .ready:
            switch activity.outcome {
            case .succeeded?:
                if let ended = recent(activity.endedAt, within: reactionDuration) {
                    return AgentCharacterPlan(segments: [.clip(.cheer, startedAt: ended, duration: reactionDuration), .hold(.done)],
                                              still: .done, revisitAt: nil)
                }
                return .still(.done)
            case .failed?:
                return .still(.failed)
            case .stopped?, nil:
                return .still(.clip(.idle))
            }
        }
    }

    // MARK: - Before the first step: the job word in the title

    private static let jobWords: [(AgentCharacterLoop, NSRegularExpression)] = [
        (.read, "re-?check|review|verify|verifi|check|audit|confirm|inspect|double-check|sanity|independent|vet"),
        (.run, "tests?|testing|ci|lint|render|benchmark|reproduce|repro|gate|smoke|run|start|restart|serve"),
        (.type, "fix|write|implement|add|port|update|rewrite|refactor|build|change|make|create|edit|prototype|remove|rename|migrate|patch|wire|tighten|clean|cleanup|batch|save|seed|integrate|keep|move|split|merge|redesign|polish|commit|push|draft|switch|replace|convert"),
        (.dabble, "find|search|look|list|read|explore|trace|locate|survey|investigate|map|scan|dig|collect|gather|summari[sz]e|where|count|capture|measure|compare"),
    ].map { loop, stems in
        // swiftlint:disable:next force_try
        (loop, try! NSRegularExpression(pattern: "\\b(\(stems))(s|es|ed|d|ing|ly)?\\b", options: [.caseInsensitive]))
    }

    /// The action a title's first job word names ("Fix…" types, "Find…" dabbles,
    /// "Review…" reads, "Run the tests" runs), or nil when it names none.
    public static func action(forTitle title: String) -> AgentCharacterLoop? {
        let range = NSRange(title.startIndex..., in: title)
        var best: (loop: AgentCharacterLoop, at: Int)?
        for (loop, pattern) in jobWords {
            guard let match = pattern.firstMatch(in: title, range: range) else { continue }
            if best == nil || match.range.location < best!.at { best = (loop, match.range.location) }
        }
        return best?.loop
    }
}
