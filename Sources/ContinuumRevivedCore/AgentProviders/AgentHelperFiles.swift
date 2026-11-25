import Foundation
import ContinuumRevivedAgentContent

/// The files a helper created or rewrote, shown on its LEAD's turn.
///
/// In Managed mode a helper makes almost every file and the lead only reads it,
/// so the lead's turn — the one tile the user watches — never had a Changes
/// card. Each helper's created-file set is gathered from its own tool
/// observations, by the same facts its own card is built from (a `Write` the
/// result confirmed as created, a codex add, a shell's made files), and travels
/// with its result: when the lead receives the result, its turn gains one
/// file-change item holding those files, each stamped with the agent that made
/// it. A helper's own sub-helpers roll up the same way, because the item lands
/// in the helper's observations too.
///
/// Nothing is parsed from anyone's prose. The delivery is also logged, so a
/// restored lead shows the same card (`inject`).
public enum AgentHelperFiles {
    public struct File: Codable, Equatable, Sendable {
        public var path: String
        /// `add` (created) or `write` (rewrote).
        public var action: String
        public var addedLines: UInt?
        public var madeBy: UUID

        public init(path: String, action: String, addedLines: UInt?, madeBy: UUID) {
            self.path = path; self.action = action; self.addedLines = addedLines; self.madeBy = madeBy
        }
    }

    /// One helper result as its lead received it, with the files it carried.
    public struct Delivery: Codable, Equatable, Sendable {
        public var id: UUID
        public var lead: UUID
        public var helper: UUID
        public var at: Date
        public var files: [File]

        public init(id: UUID = UUID(), lead: UUID, helper: UUID, at: Date, files: [File]) {
            self.id = id; self.lead = lead; self.helper = helper; self.at = at; self.files = files
        }
    }

    static let itemPrefix = "array-helper-files-"
    public static func itemID(_ delivery: Delivery) -> String { itemPrefix + delivery.id.uuidString.lowercased() }

    /// The file facts the lead's item carries, as a translator would publish them.
    public static func observation(_ delivery: Delivery, at: Date) -> AgentToolDetailObservation {
        let urls = delivery.files.map { URL(fileURLWithPath: $0.path).standardizedFileURL }
        return AgentToolDetailObservation(
            phase: .started, toolName: "Files",
            fileChanges: delivery.files.map {
                .init(action: AgentToolDetailObservation.FileAction(rawValue: $0.action) ?? .write,
                      path: URL(fileURLWithPath: $0.path).lastPathComponent, addedLines: $0.addedLines, madeBy: $0.madeBy)
            },
            affectedFiles: urls, observedAt: at)
    }

    // MARK: gathering a helper's files

    /// One agent's created and rewritten files since they were last taken.
    /// Fed every tool observation the agent publishes; holds only calls that
    /// changed a file.
    public struct Tracker: Sendable {
        private var order: [String] = []
        private var targets: [String: [URL]] = [:]
        private var changes: [String: [AgentToolDetailObservation.FileChange]] = [:]
        static let maximumItems = 256

        public init() {}

        public var isEmpty: Bool { changes.isEmpty }

        public mutating func ingest(_ observation: AgentRuntimeObservation) {
            switch observation {
            case let .toolActivity(itemID, activity) where activity.operation == .editing:
                let urls = (activity.targetPath.map { [$0] } ?? []) + activity.otherTargets
                if !urls.isEmpty, targets[itemID] == nil { targets[itemID] = urls; note(itemID) }
            case let .toolDetail(itemID, detail) where detail.phase == .started:
                if !detail.affectedFiles.isEmpty { targets[itemID] = detail.affectedFiles; note(itemID) }
                if !detail.fileChanges.isEmpty { changes[itemID] = detail.fileChanges; note(itemID) }
            default:
                break
            }
        }

        private mutating func note(_ itemID: String) {
            guard !order.contains(itemID) else { return }
            order.append(itemID)
            // A long helper run without a delivery: keep the latest calls, and
            // never a target with no change for long.
            while order.count > Self.maximumItems {
                let dropped = order.removeFirst()
                targets[dropped] = nil; changes[dropped] = nil
            }
        }

        /// The files created (`add`) or rewritten (`write`), in the order they
        /// were made, one per path (a creation outranks a later rewrite), then
        /// forgotten. Paths are matched to changes by basename, as the card does.
        public mutating func take(madeBy agent: UUID) -> [File] {
            defer { order = []; targets = [:]; changes = [:] }
            var files: [File] = []
            var index: [String: Int] = [:]
            for itemID in order {
                guard let itemChanges = changes[itemID] else { continue }
                var available = targets[itemID] ?? []
                for change in itemChanges {
                    let name = change.path.split(separator: "/").last.map(String.init) ?? change.path
                    guard let at = available.firstIndex(where: { $0.lastPathComponent == name }) else { continue }
                    let url = available.remove(at: at).standardizedFileURL
                    guard change.action == .add || change.action == .write else { continue }
                    let file = File(path: url.path, action: change.action.rawValue,
                                    addedLines: change.addedLines, madeBy: change.madeBy ?? agent)
                    if let existing = index[url.path] {
                        if files[existing].action != "add" { files[existing] = file }
                    } else {
                        index[url.path] = files.count
                        files.append(file)
                    }
                }
            }
            return files
        }
    }

    // MARK: the log a restore reads

    /// Every delivery that carried files, so a restored lead shows its card.
    /// Channel-scoped like the rest of the app's own state; bounded.
    public final class Log: @unchecked Sendable {
        public static let capacity = 1000
        private let lock = NSLock()
        private var entries: [Delivery]
        private let fileURL: URL?

        public init(fileURL: URL?) {
            self.fileURL = fileURL
            if let fileURL, let data = try? Data(contentsOf: fileURL),
               let stored = try? JSONDecoder().decode([Delivery].self, from: data) {
                entries = stored
            } else {
                entries = []
            }
        }

        public func record(_ delivery: Delivery) {
            guard !delivery.files.isEmpty else { return }
            lock.lock()
            entries.append(delivery)
            if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
            let snapshot = entries
            lock.unlock()
            guard let fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }

        public func deliveries(lead: UUID) -> [Delivery] {
            lock.lock(); defer { lock.unlock() }
            return entries.filter { $0.lead == lead }
        }
    }

    // MARK: restore

    /// How far a delivery's receipt may sit from the message's own instant in
    /// the lead's session file and still be that message's.
    static let matchWindow: TimeInterval = 600

    /// A restored lead transcript with each helper result's files placed in the
    /// turn that result started or joined, as the live stream placed them.
    public static func inject(_ transcript: RehydratedTranscript, deliveries: [Delivery]) -> RehydratedTranscript {
        guard !deliveries.isEmpty else { return transcript }
        var unused = deliveries
        var steps: [RehydratedTranscriptStep] = []
        var stamps: [Date?] = []
        var waiting: [Delivery] = []
        for (index, step) in transcript.steps.enumerated() {
            let stamp = transcript.stepTimestamps[index]
            steps.append(step); stamps.append(stamp)
            switch step {
            case let .userPrompt(text):
                waiting = []
                guard let at = stamp else { continue }
                let senders: [UUID]
                switch AgentMessageEnvelope.classify(text) {
                case let .agentMessage(message): senders = message.senderAgentID.map { [$0] } ?? []
                case let .agentMessages(messages): senders = messages.compactMap(\.senderAgentID)
                default: senders = []
                }
                for sender in senders {
                    let candidates = unused.indices.filter {
                        unused[$0].helper == sender && abs(unused[$0].at.timeIntervalSince(at)) <= matchWindow
                    }
                    guard let best = candidates.min(by: {
                        abs(unused[$0].at.timeIntervalSince(at)) < abs(unused[$1].at.timeIntervalSince(at))
                    }) else { continue }
                    waiting.append(unused.remove(at: best))
                }
            case let .event(.turnStarted(threadId, _)) where !waiting.isEmpty:
                for delivery in waiting {
                    let itemID = itemID(delivery)
                    steps.append(.observation(.toolDetail(itemId: itemID, detail: observation(delivery, at: stamp ?? delivery.at))))
                    steps.append(.event(.itemStarted(threadId: threadId, itemId: itemID, kind: .fileChange, title: nil)))
                    steps.append(.event(.itemCompleted(threadId: threadId, itemId: itemID, kind: .fileChange, status: .completed)))
                    stamps += [stamp, stamp, stamp]
                }
                waiting = []
            default:
                break
            }
        }
        return RehydratedTranscript(steps: steps, restoredMessageCount: transcript.restoredMessageCount,
                                    omittedEarlier: transcript.omittedEarlier, stepTimestamps: stamps)
    }
}
