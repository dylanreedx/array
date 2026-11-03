import Foundation
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import ContinuumRevivedCollaborationClient
import ContinuumRevivedCollaborationProtocol

/// Where a host's transcript publishes go. Production is the area controller.
@MainActor
protocol SharedAgentTranscriptSink: AnyObject {
    func publish(stream: String, checkpoint: Collaboration.AgentTranscript.Checkpoint?,
                 frames: [Collaboration.AgentTranscript.Frame]) async throws
}

enum SharedAgentTranscriptRefusal: Error, Equatable {
    /// The relay cannot place the frames (gap, restart, retention): checkpoint.
    case checkpointRequired
    /// A newer session publishes this stream; this one is dead.
    case superseded
    /// The relay has no transcript lane (older than this build).
    case unavailable
}

/// Host side of a published agent's whole transcript: the supervisor's own
/// semantic document, sent as a checkpoint plus entry/block patches. The
/// teammate's view rebuilds that document and draws it with the host tile's
/// renderer. Read-only over the supervisor, like `SharedAgentProjector`.
///
/// No outbox: the published window is the only state. A patch is recomputed
/// from it on each tick, so a refused or lost publish costs one checkpoint,
/// never a divergent replica.
@MainActor
final class SharedAgentTranscriptPublisher {
    typealias Lane = Collaboration.AgentTranscript
    typealias Wire = SharedAgentTranscriptWire

    static let interval: Duration = .milliseconds(250)

    let agent: AgentID
    let stream: String
    let generation: UInt64
    private let document: @MainActor () -> AgentDocument?
    /// The shared agent's helper roster (main stream only; nil sends none).
    private let helpers: (@MainActor () -> [Wire.Helper])?
    /// The roster as the guest now holds it.
    private(set) var publishedHelpers: [Wire.Helper]?
    /// After a roster reaches the relay: the host session starts and stops
    /// each helper's own stream from it.
    var onHelpersPublished: (([Wire.Helper]) -> Void)?
    /// Presented tool details for one document; may do its work off the main actor.
    private let details: @MainActor (AgentDocument) async -> [AgentNodeID: SharedAgentToolPresentation]
    private let detailRevision: @MainActor () -> UInt64?
    private var lastDetailRevision: UInt64?
    private var lastDetailAudit = Date.distantPast
    private var publishedDetails: [AgentNodeID: SharedAgentToolPresentation] = [:]
    private let imageData: @MainActor (AgentDocument) async -> [AgentImageAttachmentID: Data]
    private var publishedImages: [AgentImageAttachmentID: Data] = [:]
    private var cachedImages: [AgentImageAttachmentID: Data] = [:]
    private var lastImageIDs: Set<AgentImageAttachmentID> = []
    private var lastImageRead = Date.distantPast
    /// The host tile's chrome now, and the person's own character set it
    /// names (agent-chrome). Nil: this publisher sends no chrome.
    private let chrome: (@MainActor () -> (chrome: Wire.Chrome, theme: Wire.CharacterTheme?)?)?
    /// The chrome the guest holds, and the sets it was sent since the last checkpoint.
    private(set) var publishedChrome: Wire.Chrome?
    private var sentThemes: Set<String> = []
    /// When this publisher last sent each large set's parts. Guests keep a set
    /// they were sent, so the parts ride a checkpoint at most once per
    /// `themePartsResendInterval` (for late joiners), never on every checkpoint.
    private var themePartsSentAt: [String: Date] = [:]
    static let themePartsResendInterval: TimeInterval = 10 * 60
    private(set) var chromeOps = 0
    private let sink: SharedAgentTranscriptSink
    private let budget: SharedAgentTranscriptBudget
    /// Host entries (before the budget) as the guest now holds them.
    private(set) var published: [AgentEntry] = []
    private(set) var through: UInt64 = 0
    private var lastVersion: UInt64?
    private var needsCheckpoint = true
    private var bytesSinceCheckpoint = 0
    private var loop: Task<Void, Never>?
    private var publishing = false
    private(set) var superseded = false
    private(set) var laneUnavailable = false
    private(set) var lastError: (any Error)?
    private(set) var checkpoints = 0
    private(set) var frames = 0

    init(agent: AgentID, stream: String = Lane.mainStream, generation: UInt64,
         budget: SharedAgentTranscriptBudget = SharedAgentTranscriptSafeBudget(),
         sink: SharedAgentTranscriptSink, helpers: (@MainActor () -> [Wire.Helper])? = nil,
         details: @escaping @MainActor (AgentDocument) async -> [AgentNodeID: SharedAgentToolPresentation] = { _ in [:] },
         detailRevision: @escaping @MainActor () -> UInt64? = { nil },
         imageData: @escaping @MainActor (AgentDocument) async -> [AgentImageAttachmentID: Data] = { _ in [:] },
         chrome: (@MainActor () -> (chrome: Wire.Chrome, theme: Wire.CharacterTheme?)?)? = nil,
         document: @escaping @MainActor () -> AgentDocument?) {
        self.agent = agent; self.stream = stream; self.generation = generation
        self.budget = budget; self.sink = sink; self.helpers = helpers; self.document = document
        self.details = details; self.detailRevision = detailRevision; self.imageData = imageData; self.chrome = chrome
    }

    /// The main stream carries the agent's helper roster; a helper's own
    /// stream (`childStream`) carries only its transcript.
    convenience init(supervisor: AgentSupervisor, agent: AgentID, stream: String = Lane.mainStream, generation: UInt64,
                     sink: SharedAgentTranscriptSink) {
        let roster: (@MainActor () -> [Wire.Helper])? = stream == Lane.mainStream ? { @MainActor [weak supervisor] in
            supervisor.map { SharedAgentHelpers.roster($0, lead: agent) } ?? []
        } : nil
        // Only the agent's own stream carries its tile's chrome; a helper's
        // stream is drawn inside the parent's transcript.
        var chrome: (@MainActor () -> (chrome: Wire.Chrome, theme: Wire.CharacterTheme?)?)?
        if stream == Lane.mainStream {
            let builder = SharedAgentChromeBuilder(supervisor: supervisor, agent: agent)
            chrome = { builder.build() }
        }
        self.init(agent: agent, stream: stream, generation: generation, sink: sink, helpers: roster, details: { [weak supervisor] document in
            await supervisor?.sharedTranscriptToolDetails(for: agent, document: document) ?? [:]
        }, detailRevision: { [weak supervisor] in
            supervisor?.sharedTranscriptDetailRevision(for: agent)
        }, imageData: { [weak supervisor] document in
            await supervisor?.sharedTranscriptImages(for: agent, document: document) ?? [:]
        }, chrome: chrome) { [weak supervisor] in
            supervisor?.transcriptDocument(for: agent)
        }
    }

    /// A refused or lost publish is retried as a whole checkpoint. Retrying
    /// that every tick is what kept a 0.7.40 relay saturated: each refusal
    /// (rate limit, eviction, a busy relay timing out) cost the next tick a
    /// full checkpoint. So failures in a row wait 1, 2, 4 ... up to 30 s.
    static let maxRetryDelay: Duration = .seconds(30)
    private(set) var consecutiveFailures = 0
    var retryDelay: Duration {
        guard consecutiveFailures > 0 else { return Self.interval }
        return min(Self.maxRetryDelay, .seconds(1 << min(consecutiveFailures - 1, 5)))
    }

    /// Ticks until stopped. A tick whose document version did not move costs a compare.
    func start() {
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, !self.superseded, !self.laneUnavailable else { return }
                await self.tick()
                try? await Task.sleep(for: self.retryDelay)
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    /// Witness only: plan on the main actor, as every publish did before the
    /// work moved off it. Same plan, same order; only the executor differs.
    var qaPlansOnMainActor = false
    /// Checks only: the clock that paces large sets' parts.
    var qaNow: () -> Date = Date.init
    /// Checks only: the next tick sends a checkpoint, as a refusal would.
    func qaRequestCheckpoint() { needsCheckpoint = true }

    /// Ticks called while one is away; resumed when it finishes.
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// One publish of whatever changed. Witnesses call this directly.
    ///
    /// The main actor reads the document and the publisher's own state, and
    /// sends; finding what changed, presenting tool details and encoding run
    /// off it, on values. Ticks never overlap: a tick called while another is
    /// away waits for it, then publishes what changed since. So frames leave in
    /// sequence, a checkpoint is never overtaken by an older patch, and when
    /// `tick()` returns, the document as it was at the call has been published.
    func tick() async {
        while publishing { await withCheckedContinuation { waiting.append($0) } }
        guard !superseded, !laneUnavailable, let current = document() else { return }
        let roster = helpers?()
        let revision = detailRevision()
        let now = Date()
        let chromeNow = chrome?()
        let chromeChanged = chromeNow.map { !Self.sameForGuest($0.chrome, publishedChrome) } ?? false
        // Detail changes have their own revision; periodic audits still notice
        // TTL expiry and images that were not ready at the previous read.
        if !needsCheckpoint, current.version == lastVersion, roster == publishedHelpers, !chromeChanged, let revision,
           revision == lastDetailRevision, now.timeIntervalSince(lastDetailAudit) < 5 { return }
        publishing = true
        defer {
            publishing = false
            let resumed = waiting; waiting = []
            resumed.forEach { $0.resume() }
        }
        let currentDetails = await details(current)
        let entries = current.entries
        let imageIDs = await offMain { Self.imageIDs(in: entries) }
        if imageIDs != lastImageIDs || (cachedImages.count < imageIDs.count && Date().timeIntervalSince(lastImageRead) >= 5) {
            cachedImages = Self.boundedImages(await imageData(current))
            lastImageIDs = imageIDs; lastImageRead = Date()
        }
        let state = State(current: current, roster: roster, details: currentDetails, images: cachedImages, budget: budget,
                          published: published, publishedDetails: publishedDetails, publishedImages: publishedImages,
                          publishedHelpers: publishedHelpers, lastVersion: lastVersion, needsCheckpoint: needsCheckpoint,
                          bytesSinceCheckpoint: bytesSinceCheckpoint, chrome: chromeNow, chromeChanged: chromeChanged,
                          sentThemes: sentThemes,
                          themePartsDue: chromeNow?.theme.map { theme in
                              themePartsSentAt[theme.hash].map { qaNow().timeIntervalSince($0) >= Self.themePartsResendInterval } ?? true
                          } ?? false)
        do {
            switch try await offMain({ try Self.plan(state) }) {
            case .unchanged:
                // Nothing reached the relay, so an earlier failure still stands.
                lastDetailRevision = revision; lastDetailAudit = now
                return
            case let .checkpoint(plan):
                try await sendCheckpoint(plan, current: current, roster: roster, chrome: chromeNow)
            case .noOps:
                lastVersion = current.version
            case let .patch(body, window, nextDetails):
                let frame = Lane.Frame(generation: generation, sequence: through + 1, body: body)
                try await sink.publish(stream: stream, checkpoint: nil, frames: [frame])
                through += 1; frames += 1; bytesSinceCheckpoint += body.count
                published = window; publishedDetails = nextDetails
                if let roster, roster != publishedHelpers { publishedHelpers = roster; onHelpersPublished?(roster) }
                // `plan` adds the chrome ops exactly when the chrome changed.
                if chromeChanged, let chromeNow {
                    publishedChrome = chromeNow.chrome; chromeOps += 1
                    if let theme = chromeNow.theme { sentThemes.insert(theme.hash) }
                }
                lastVersion = current.version
            }
            lastDetailRevision = revision; lastDetailAudit = now
            lastError = nil; consecutiveFailures = 0
        } catch SharedAgentTranscriptRefusal.superseded {
            lastError = SharedAgentTranscriptRefusal.superseded; superseded = true; stop()
        } catch SharedAgentTranscriptRefusal.unavailable {
            lastError = SharedAgentTranscriptRefusal.unavailable; laneUnavailable = true; stop()
        } catch {
            // Refused, or lost after the relay took it: either way only a
            // checkpoint can say for certain what the guest holds.
            lastError = error; needsCheckpoint = true; consecutiveFailures += 1
        }
    }

    private func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        if qaPlansOnMainActor { return try work() }
        return try await Task.detached(priority: .userInitiated) { try work() }.value
    }
    private func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        if qaPlansOnMainActor { return work() }
        return await Task.detached(priority: .userInitiated) { work() }.value
    }

    private func sendCheckpoint(_ plan: CheckpointPlan, current: AgentDocument, roster: [Wire.Helper]?,
                                chrome chromeNow: (chrome: Wire.Chrome, theme: Wire.CharacterTheme?)?) async throws {
        let next = through + 1
        try await sink.publish(stream: stream, checkpoint: .init(generation: generation, through: next, body: plan.body), frames: [])
        through = next; checkpoints += 1; bytesSinceCheckpoint = 0
        for body in plan.imageBodies {
            let frame = Lane.Frame(generation: generation, sequence: through + 1, body: body)
            try await sink.publish(stream: stream, checkpoint: nil, frames: [frame])
            through += 1; frames += 1
        }
        needsCheckpoint = false
        published = Array(current.entries.suffix(plan.kept)); publishedDetails = plan.details; publishedImages = plan.images
        lastVersion = current.version
        if let roster { let changed = roster != publishedHelpers; publishedHelpers = roster; if changed { onHelpersPublished?(roster) } }
        publishedChrome = chromeNow?.chrome
        sentThemes = Set(chromeNow?.theme.map { [$0.hash] } ?? [])
        if let hash = plan.themePartsHash { themePartsSentAt[hash] = qaNow() }
    }

    /// Whether the guest would draw `a` as it draws `b`. The character's last
    /// output time moves on every streamed delta; it changes the pose only
    /// after tens of seconds of quiet, so it alone resends at most every 10 s.
    static func sameForGuest(_ a: Wire.Chrome, _ b: Wire.Chrome?) -> Bool {
        guard var b else { return false }
        if let x = a.character?.lastOutputAt, let y = b.character?.lastOutputAt, abs(x.timeIntervalSince(y)) < 10 {
            b.character?.lastOutputAt = x
        }
        return a == b
    }

    // MARK: - Plan (off the main actor, on values)

    /// What one tick reads: the document and what the guest now holds.
    struct State: Sendable {
        let current: AgentDocument
        let roster: [Wire.Helper]?
        let details: [AgentNodeID: SharedAgentToolPresentation]
        let images: [AgentImageAttachmentID: Data]
        let budget: SharedAgentTranscriptBudget
        let published: [AgentEntry]
        let publishedDetails: [AgentNodeID: SharedAgentToolPresentation]
        let publishedImages: [AgentImageAttachmentID: Data]
        let publishedHelpers: [Wire.Helper]?
        let lastVersion: UInt64?
        let needsCheckpoint: Bool
        let bytesSinceCheckpoint: Int
        /// The host tile's chrome now, and whether the guest draws something else.
        let chrome: (chrome: Wire.Chrome, theme: Wire.CharacterTheme?)?
        let chromeChanged: Bool
        let sentThemes: Set<String>
        /// Whether a large set's parts may ride the next checkpoint.
        var themePartsDue = true
    }

    struct CheckpointPlan: Sendable {
        let body: Data
        /// Theme parts, then image manifests and distinct image chunks, encoded.
        let imageBodies: [Data]
        /// How many of the newest host entries it carries.
        let kept: Int
        let details: [AgentNodeID: SharedAgentToolPresentation]
        let images: [AgentImageAttachmentID: Data]
        /// The large set whose parts follow this checkpoint, if any.
        var themePartsHash: String?
    }

    enum Plan: Sendable {
        case unchanged
        case checkpoint(CheckpointPlan)
        /// The entries are unchanged on the wire; the version is noted.
        case noOps
        case patch(body: Data, window: [AgentEntry], details: [AgentNodeID: SharedAgentToolPresentation])
    }

    nonisolated static func plan(_ state: State) throws -> Plan {
        let current = state.current
        let visible = state.published.isEmpty && state.lastVersion == current.version ? [] : window(state.published, of: current.entries)
        let visibleBlocks = Wire.blockIDs(in: visible)
        let visibleImages = imageIDs(in: visible)
        let changedImages = state.images.filter({ visibleImages.contains($0.key) }) != state.publishedImages
        if !state.needsCheckpoint, current.version == state.lastVersion, state.roster == state.publishedHelpers, !state.chromeChanged,
           state.details.filter({ visibleBlocks.contains($0.key) }) == state.publishedDetails, !changedImages {
            return .unchanged
        }
        if state.needsCheckpoint || state.bytesSinceCheckpoint > Lane.checkpointAfterBytes || changedImages {
            return .checkpoint(try checkpoint(state))
        }
        guard var ops = current.version == state.lastVersion ? [] : patch(state.published, to: current.entries) else {
            return .checkpoint(try checkpoint(state))
        }
        let window = window(state.published, of: current.entries)
        let keptIDs = Wire.blockIDs(in: window)
        let nextDetails = state.details.filter { keptIDs.contains($0.key) }
        let published = state.publishedDetails
        let changedIDs = Set(published.keys).union(nextDetails.keys).filter { published[$0] != nextDetails[$0] }
        let detailOps = changedIDs.sorted { $0.rawValue < $1.rawValue }.map { Wire.Op.toolDetail(block: $0, detail: nextDetails[$0]) }
        ops = ops.map { fitted($0, budget: state.budget) } + detailOps
        if let roster = state.roster, roster != state.publishedHelpers { ops.append(.helpers(roster)) }
        if state.chromeChanged, let chrome = state.chrome {
            // A set travels once, before the first chrome that names it.
            if let theme = chrome.theme, !state.sentThemes.contains(theme.hash) {
                if theme.isInline {
                    ops.append(.characterTheme(theme))
                } else if state.themePartsDue {
                    // A set too large for one op follows a checkpoint in parts.
                    return .checkpoint(try checkpoint(state))
                }
                // Parts sent within the interval: guests that were sent them keep them.
            }
            ops.append(.chrome(chrome.chrome))
        }
        guard !ops.isEmpty else { return .noOps }
        let body = try Wire.encode(Wire.Patch(ops: ops))
        if body.count > Lane.maxFrameBytes { return .checkpoint(try checkpoint(state)) }
        return .patch(body: body, window: window, details: nextDetails)
    }

    nonisolated private static func checkpoint(_ state: State) throws -> CheckpointPlan {
        // The roster rides inside the same limit (32 helpers, a few KiB), and
        // so do the chrome and a person's own set (at most 32 KiB deflated).
        let rosterBytes = try state.roster.map { try Wire.encode($0).count + 16 } ?? 0
        // A set too large to ride inline follows the checkpoint in parts, when due.
        let partsTheme = state.chrome?.theme.flatMap { !$0.isInline && state.themePartsDue ? $0 : nil }
        let inlineTheme = state.chrome?.theme.flatMap { $0.isInline ? $0 : nil }
        let window = Wire.window(state.current.entries, maxBytes: Lane.maxCheckpointBytes - rosterBytes, budget: state.budget,
                                 chrome: state.chrome?.chrome, characterTheme: inlineTheme)
        var entries = window.entries
        var omitted = window.omittedEntries
        var selected: [AgentNodeID: SharedAgentToolPresentation] = [:]
        var body = Data()
        while true {
            let ids = Wire.blockIDs(in: entries)
            selected = state.details.filter { ids.contains($0.key) }
            let items = selected.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { id in
                selected[id].map { Wire.ToolDetail(block: id, detail: $0) }
            }
            body = try Wire.encode(Wire.Checkpoint(entries: entries, omittedEntries: omitted, helpers: state.roster, toolDetails: items,
                                                   chrome: state.chrome?.chrome, characterTheme: inlineTheme))
            if body.count <= Lane.maxCheckpointBytes || entries.isEmpty { break }
            entries.removeFirst(); omitted += 1
        }
        let visibleIDs = imageIDs(in: entries)
        var selectedImages = state.images.filter { visibleIDs.contains($0.key) }
        func bodies() throws -> [Data] {
            var imageBodies: [Data] = []
            if let theme = partsTheme {
                for part in theme.parts() { imageBodies.append(try Wire.encode(Wire.Patch(ops: [.characterThemePart(part)]))) }
            }
            var sentHashes: Set<String> = []
            for id in selectedImages.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard let data = selectedImages[id] else { continue }
                let manifest = SharedAgentTranscriptImages.Manifest(attachment: id, data: data)
                imageBodies.append(try Wire.encode(Wire.Patch(ops: [.imageManifest(manifest)])))
            }
            for id in selectedImages.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard let data = selectedImages[id] else { continue }
                let hash = SharedAgentTranscriptImages.digest(data)
                guard sentHashes.insert(hash).inserted else { continue }
                for chunk in SharedAgentTranscriptImages.chunks(data) { imageBodies.append(try Wire.encode(Wire.Patch(ops: [.imageChunk(chunk)]))) }
            }
            return imageBodies
        }
        var imageBodies = try bodies()
        // Base64 and op metadata count toward retention too. At the maximum
        // theme size, all 512 KiB of images plus their metadata may not fit.
        // Keep the theme complete and omit whole images until late join fits.
        while imageBodies.reduce(0, { $0 + $1.count }) > Lane.maxRetainedBytes,
              let drop = selectedImages.keys.sorted(by: { $0.rawValue < $1.rawValue }).last {
            selectedImages[drop] = nil
            imageBodies = try bodies()
        }
        return CheckpointPlan(body: body, imageBodies: imageBodies, kept: entries.count, details: selected, images: selectedImages,
                              themePartsHash: partsTheme?.hash)
    }

    private static func boundedImages(_ images: [AgentImageAttachmentID: Data]) -> [AgentImageAttachmentID: Data] {
        var selected: [AgentImageAttachmentID: Data] = [:]
        var hashes: Set<String> = []
        var bytes = 0
        for id in images.keys.sorted(by: { $0.rawValue < $1.rawValue }).prefix(64) {
            guard let data = images[id], !data.isEmpty, data.count <= SharedAgentTranscriptImages.maxImageBytes else { continue }
            let hash = SharedAgentTranscriptImages.digest(data)
            let cost = hashes.contains(hash) ? 0 : data.count
            guard bytes + cost <= SharedAgentTranscriptImages.maxTotalBytes else { continue }
            selected[id] = data; bytes += cost; hashes.insert(hash)
        }
        return selected
    }

    nonisolated private static func imageIDs(in entries: [AgentEntry]) -> Set<AgentImageAttachmentID> {
        var ids: Set<AgentImageAttachmentID> = []
        func visit(_ block: AgentBlock) {
            switch block.payload {
            case let .image(image): ids.insert(image.attachment.id)
            case let .imageGallery(gallery): gallery.images.forEach { ids.insert($0.attachment.id) }
            default: break
            }
            block.children.forEach(visit)
        }
        entries.forEach { $0.blocks.forEach(visit) }
        return ids
    }

    /// The current entries from the guest's first one on. Entries before the
    /// window stay on this Mac. Nil if the window's first entry is gone.
    nonisolated private static func window(_ published: [AgentEntry], of entries: [AgentEntry]) -> [AgentEntry] {
        guard let first = published.first?.id, let start = entries.firstIndex(where: { $0.id == first }) else { return entries }
        return Array(entries[start...])
    }

    nonisolated private static func patch(_ published: [AgentEntry], to entries: [AgentEntry]) -> [Wire.Op]? {
        if let first = published.first?.id, !entries.contains(where: { $0.id == first }) { return nil }
        return Wire.patch(from: published, to: window(published, of: entries))
    }

    nonisolated private static func fitted(_ op: Wire.Op, budget: SharedAgentTranscriptBudget) -> Wire.Op {
        guard case let .block(entry, block) = op else { return op }
        return .block(entry: entry, budget.fit(block, limit: Wire.maxBlockBytes))
    }
}

/// The area controller as a sink, with the relay's refusals made the publisher's.
@MainActor
final class SharedAreaControllerTranscriptSink: SharedAgentTranscriptSink {
    private weak var controller: SharedAreaController?
    private let object: SharedArea.ID<SharedArea.Object>
    private let host: SharedArea.ID<SharedArea.Host>
    init(controller: SharedAreaController?, object: SharedArea.ID<SharedArea.Object>, host: SharedArea.ID<SharedArea.Host>) {
        self.controller = controller; self.object = object; self.host = host
    }
    func publish(stream: String, checkpoint: Collaboration.AgentTranscript.Checkpoint?,
                 frames: [Collaboration.AgentTranscript.Frame]) async throws {
        guard let controller else { throw CollaborationClientError.server(status: 503, code: "notConnected") }
        do {
            try await controller.publishAgentTranscript(object: object, host: host, stream: stream, checkpoint: checkpoint, frames: frames)
        }
        catch CollaborationClientError.server(409, "resyncRequired") { throw SharedAgentTranscriptRefusal.checkpointRequired }
        catch CollaborationClientError.server(409, "revisionConflict") { throw SharedAgentTranscriptRefusal.superseded }
        catch CollaborationClientError.server(404, _) { throw SharedAgentTranscriptRefusal.unavailable }
    }
}
