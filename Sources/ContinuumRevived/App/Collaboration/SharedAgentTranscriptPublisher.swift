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
    private let details: @MainActor () -> [AgentNodeID: SharedAgentToolPresentation]
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
         details: @escaping @MainActor () -> [AgentNodeID: SharedAgentToolPresentation] = { [:] },
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
        self.init(agent: agent, stream: stream, generation: generation, sink: sink, helpers: roster, details: { [weak supervisor] in
            (supervisor?.sharedTranscriptToolBlocks(for: agent) ?? [:]).compactMapValues { SharedAgentToolPresentation(presented: $0) }
        }, detailRevision: { [weak supervisor] in
            supervisor?.sharedTranscriptDetailRevision(for: agent)
        }, imageData: { [weak supervisor] document in
            await supervisor?.sharedTranscriptImages(for: agent, document: document) ?? [:]
        }, chrome: chrome) { [weak supervisor] in
            supervisor?.transcriptDocument(for: agent)
        }
    }

    /// Ticks until stopped. A tick whose document version did not move costs a compare.
    func start() {
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, !self.superseded, !self.laneUnavailable else { return }
                await self.tick()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() { loop?.cancel(); loop = nil }

    /// One publish of whatever changed. Witnesses call this directly.
    func tick() async {
        guard !publishing, !superseded, !laneUnavailable, let current = document() else { return }
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
        let currentDetails = details()
        let imageIDs = Self.imageIDs(in: current.entries)
        if imageIDs != lastImageIDs || (cachedImages.count < imageIDs.count && Date().timeIntervalSince(lastImageRead) >= 5) {
            cachedImages = Self.boundedImages(await imageData(current))
            lastImageIDs = imageIDs; lastImageRead = Date()
        }
        let visible = published.isEmpty && lastVersion == current.version ? [] : window(of: current.entries)
        let visibleBlocks = Wire.blockIDs(in: visible)
        let visibleImages = Self.imageIDs(in: visible)
        if !needsCheckpoint, current.version == lastVersion, roster == publishedHelpers, !chromeChanged,
           currentDetails.filter({ visibleBlocks.contains($0.key) }) == publishedDetails,
           cachedImages.filter({ visibleImages.contains($0.key) }) == publishedImages {
            lastDetailRevision = revision; lastDetailAudit = now
            publishing = false; return
        }
        defer { publishing = false }
        do {
            if needsCheckpoint || bytesSinceCheckpoint > Lane.checkpointAfterBytes
                || cachedImages.filter({ visibleImages.contains($0.key) }) != publishedImages {
                try await sendCheckpoint(current, roster: roster, details: currentDetails, images: cachedImages, chrome: chromeNow)
            } else if var ops = current.version == lastVersion ? [] : patch(to: current.entries) {
                let keptIDs = Wire.blockIDs(in: window(of: current.entries))
                let nextDetails = currentDetails.filter { keptIDs.contains($0.key) }
                let changedIDs = Set(publishedDetails.keys).union(nextDetails.keys).filter { publishedDetails[$0] != nextDetails[$0] }
                let detailOps = changedIDs.sorted { $0.rawValue < $1.rawValue }.map { Wire.Op.toolDetail(block: $0, detail: nextDetails[$0]) }
                ops = ops.map(fitted) + detailOps
                if let roster, roster != publishedHelpers { ops.append(.helpers(roster)) }
                var chromeSent: Wire.Chrome?
                if chromeChanged, let chromeNow {
                    // A set travels once, before the first chrome that names it.
                    if let theme = chromeNow.theme, !sentThemes.contains(theme.hash) { ops.append(.characterTheme(theme)) }
                    ops.append(.chrome(chromeNow.chrome))
                    chromeSent = chromeNow.chrome
                }
                if !ops.isEmpty {
                    let body = try Wire.encode(Wire.Patch(ops: ops))
                    if body.count > Lane.maxFrameBytes {
                        try await sendCheckpoint(current, roster: roster, details: currentDetails, images: cachedImages, chrome: chromeNow)
                    } else {
                        let frame = Lane.Frame(generation: generation, sequence: through + 1, body: body)
                        try await sink.publish(stream: stream, checkpoint: nil, frames: [frame])
                        through += 1; frames += 1; bytesSinceCheckpoint += body.count
                        published = window(of: current.entries); publishedDetails = nextDetails
                        if let roster, roster != publishedHelpers { publishedHelpers = roster; onHelpersPublished?(roster) }
                        if let chromeSent {
                            publishedChrome = chromeSent; chromeOps += 1
                            if let theme = chromeNow?.theme { sentThemes.insert(theme.hash) }
                        }
                    }
                }
                lastVersion = current.version
            } else {
                try await sendCheckpoint(current, roster: roster, details: currentDetails, images: cachedImages, chrome: chromeNow)
            }
            lastDetailRevision = revision; lastDetailAudit = now
            lastError = nil
        } catch SharedAgentTranscriptRefusal.superseded {
            lastError = SharedAgentTranscriptRefusal.superseded; superseded = true; stop()
        } catch SharedAgentTranscriptRefusal.unavailable {
            lastError = SharedAgentTranscriptRefusal.unavailable; laneUnavailable = true; stop()
        } catch {
            // Refused, or lost after the relay took it: either way only a
            // checkpoint can say for certain what the guest holds.
            lastError = error; needsCheckpoint = true
        }
    }

    private func sendCheckpoint(_ current: AgentDocument, roster: [Wire.Helper]?, details: [AgentNodeID: SharedAgentToolPresentation],
                                images: [AgentImageAttachmentID: Data],
                                chrome chromeNow: (chrome: Wire.Chrome, theme: Wire.CharacterTheme?)?) async throws {
        // The roster rides inside the same limit (32 helpers, a few KiB), and
        // so do the chrome and a person's own set (at most 32 KiB deflated).
        let rosterBytes = try roster.map { try Wire.encode($0).count + 16 } ?? 0
        let window = Wire.window(current.entries, maxBytes: Lane.maxCheckpointBytes - rosterBytes, budget: budget,
                                 chrome: chromeNow?.chrome, characterTheme: chromeNow?.theme)
        var entries = window.entries
        var omitted = window.omittedEntries
        var selected: [AgentNodeID: SharedAgentToolPresentation] = [:]
        var body = Data()
        while true {
            let ids = Wire.blockIDs(in: entries)
            selected = details.filter { ids.contains($0.key) }
            let items = selected.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { id in
                selected[id].map { Wire.ToolDetail(block: id, detail: $0) }
            }
            body = try Wire.encode(Wire.Checkpoint(entries: entries, omittedEntries: omitted, helpers: roster, toolDetails: items,
                                                   chrome: chromeNow?.chrome, characterTheme: chromeNow?.theme))
            if body.count <= Lane.maxCheckpointBytes || entries.isEmpty { break }
            entries.removeFirst(); omitted += 1
        }
        let next = through + 1
        try await sink.publish(stream: stream, checkpoint: .init(generation: generation, through: next, body: body), frames: [])
        through = next; checkpoints += 1; bytesSinceCheckpoint = 0
        let visibleIDs = Self.imageIDs(in: entries)
        let selectedImages = images.filter { visibleIDs.contains($0.key) }
        var sentHashes: Set<String> = []
        for id in selectedImages.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let data = selectedImages[id] else { continue }
            let manifest = SharedAgentTranscriptImages.Manifest(attachment: id, data: data)
            try await sendImageOp(.imageManifest(manifest))
        }
        for id in selectedImages.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let data = selectedImages[id] else { continue }
            let hash = SharedAgentTranscriptImages.digest(data)
            guard sentHashes.insert(hash).inserted else { continue }
            for chunk in SharedAgentTranscriptImages.chunks(data) { try await sendImageOp(.imageChunk(chunk)) }
        }
        needsCheckpoint = false
        published = Array(current.entries.suffix(entries.count)); publishedDetails = selected; publishedImages = selectedImages
        lastVersion = current.version
        if let roster { let changed = roster != publishedHelpers; publishedHelpers = roster; if changed { onHelpersPublished?(roster) } }
        publishedChrome = chromeNow?.chrome
        sentThemes = Set(chromeNow?.theme.map { [$0.hash] } ?? [])
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

    private func sendImageOp(_ op: Wire.Op) async throws {
        let body = try Wire.encode(Wire.Patch(ops: [op]))
        let frame = Lane.Frame(generation: generation, sequence: through + 1, body: body)
        try await sink.publish(stream: stream, checkpoint: nil, frames: [frame])
        through += 1; frames += 1
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

    private static func imageIDs(in entries: [AgentEntry]) -> Set<AgentImageAttachmentID> {
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
    private func window(of entries: [AgentEntry]) -> [AgentEntry] {
        guard let first = published.first?.id, let start = entries.firstIndex(where: { $0.id == first }) else { return entries }
        return Array(entries[start...])
    }

    private func patch(to entries: [AgentEntry]) -> [Wire.Op]? {
        if let first = published.first?.id, !entries.contains(where: { $0.id == first }) { return nil }
        return Wire.patch(from: published, to: window(of: entries))
    }

    private func fitted(_ op: Wire.Op) -> Wire.Op {
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
