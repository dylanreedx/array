import AppKit
import ContinuumRevivedAgentContent
import ContinuumRevivedCore
import Darwin
import Foundation

/// Exercises the boot mount and its first helper-delivery recovery flush. Records
/// share a checkout, so the delivery journal is shared too. Old delivered rows
/// should be pruned once per checkout; pending and recent rows must survive.
@MainActor
enum RestoreDeliveryScalingChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
        if !value() { throw Failure(description: message()) }
    }

    private static func sessionKey(_ session: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in session.utf8 { hash ^= UInt64(byte); hash &*= 1_099_511_628_211 }
        return String(hash, radix: 16)
    }

    /// Samples process-local heap and open pipes without starting a child process.
    private final class Sampler: @unchecked Sendable {
        private let lock = NSLock()
        private var stopping = false
        private let group = DispatchGroup()
        private(set) var peakMalloc = 0
        private(set) var peakPipes = 0

        private func sample() {
            var stats = malloc_statistics_t()
            malloc_zone_statistics(nil, &stats)
            let size = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
            var pipes = 0
            if size > 0 {
                let stride = MemoryLayout<proc_fdinfo>.stride
                var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 8)
                let got = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
                if got > 0 {
                    pipes = fds.prefix(Int(got) / stride).filter { $0.proc_fdtype == PROX_FDTYPE_PIPE }.count
                }
            }
            lock.lock()
            peakMalloc = max(peakMalloc, stats.size_in_use)
            peakPipes = max(peakPipes, pipes)
            lock.unlock()
        }
        func start() {
            sample()
            group.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { group.leave() }
                while true {
                    lock.lock(); let done = stopping; lock.unlock()
                    if done { return }
                    sample()
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        }
        func currentPeaks() -> (malloc: Int, pipes: Int) {
            lock.lock(); defer { lock.unlock() }
            return (peakMalloc, peakPipes)
        }
        func stop() -> (malloc: Int, pipes: Int) {
            lock.lock(); stopping = true; lock.unlock()
            group.wait()
            sample()
            lock.lock(); defer { lock.unlock() }
            return (peakMalloc, peakPipes)
        }
    }

    static func run() async throws -> String {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("array-delivery-restore-\(UUID())", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let checkouts = [root.appendingPathComponent("checkout-a", isDirectory: true),
                         root.appendingPathComponent("checkout-b", isDirectory: true),
                         root.appendingPathComponent("checkout-other", isDirectory: true)]
        let support = root.appendingPathComponent("support", isDirectory: true)
        let transcriptRoot = support.appendingPathComponent("transcripts", isDirectory: true)
        for checkout in checkouts { try fm.createDirectory(at: checkout, withIntermediateDirectories: true) }
        let store = AgentStore(applicationSupportDirectory: support)
        try fm.createDirectory(at: store.layout.agentsDirectory, withIntermediateDirectories: true)
        let ids = (0..<2300).map { _ in AgentID(rawValue: UUID()) }
        let project = UUID()
        // JSONCodec uses whole-second ISO-8601 dates.
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let encoder = JSONCodec.makeEncoder()
        let text = String(repeating: "A saved transcript line with prior work. ", count: 128)
        let entry = AgentEntry(id: AgentNodeID(rawValue: "entry")!, role: .assistant,
            provenance: .localNotice(reason: "fixture"), lifecycle: .finished,
            blocks: [AgentBlock(id: AgentNodeID(rawValue: "block")!, kind: .paragraph, payload: .paragraph([.text(text)]))])
        let document = AgentDocument(version: 1, entries: [entry])
        for (i, id) in ids.enumerated() {
            try autoreleasepool {
                var record = AgentRecord(id: id, displayName: "Restore fixture \(i)", harness: .pi,
                    model: AgentCatalogQAFixture.pi[0], thinking: "none", cwd: checkouts[i < 394 ? 0 : (i < 761 ? 1 : 2)].path,
                    projectId: project, createdAt: now, lastActivityAt: now)
                record.automaticCharacterIndex = i % 8
                try encoder.encode(record).write(to: store.layout.agentFile(id: id))
                if i < 2200 {
                    let session = AgentTranscriptStore.canonicalSessionID(for: id)
                    let dir = transcriptRoot.appendingPathComponent(id.rawValue.uuidString, isDirectory: true)
                        .appendingPathComponent(sessionKey(session), isDirectory: true)
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    try encoder.encode(AgentTranscriptArchive(agentID: id, sessionID: session, document: document))
                        .write(to: dir.appendingPathComponent("snapshot.json"))
                }
            }
        }
        let transcripts = AgentTranscriptStore(root: transcriptRoot)
        let restoredDocument = try await transcripts.load(agentID: ids[0], sessionID: AgentTranscriptStore.canonicalSessionID(for: ids[0]))
        try expect(restoredDocument == document, "fixture transcript must be readable through the real store")

        // Retained rows force the old repeated cleanup path to decode the same
        // file again for each record. The 2 KiB text represents ordinary results.
        var retained: [(URL, SpawnResultFile.Delivery)] = []
        var expired: [URL] = []
        for (rootIndex, checkout) in checkouts.prefix(2).enumerated() {
            let deliveryDir = SpawnResultFile.directory(parentCwd: checkout.path).appendingPathComponent(".deliveries", isDirectory: true)
            try fm.createDirectory(at: deliveryDir, withIntermediateDirectories: true)
            let count = rootIndex == 0 ? 1305 : 367
            let start = rootIndex == 0 ? 0 : 394
            let agentCount = rootIndex == 0 ? 394 : 367
            for i in 0..<count {
                var row = SpawnResultFile.Delivery(helper: UUID(), turn: "turn-\(i)", recipient: ids[start + i % agentCount].rawValue,
                    text: String(repeating: "Result text. ", count: 170), now: now)
                if i >= count - 4 { row.phase = .delivered; row.completedAt = now.addingTimeInterval(-9 * 86_400) }
                else if i >= count - 6 { row.phase = .delivered }
                let url = SpawnResultFile.deliveryURL(parentCwd: checkout.path, helper: row.helper, turn: row.turn, recipient: row.recipient)!
                try encoder.encode(row).write(to: url)
                if i >= count - 4 { expired.append(url) } else { retained.append((url, row)) }
            }
        }
        let supervisor = AgentSupervisor(store: store, makeRunner: { _ in ScriptedAgentRunner(script: []) },
            warn: { _ in }, nameTitlerCommand: { _ in nil }, transcriptStore: transcripts)
        let suiteName = "array.restore-delivery-scaling.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw Failure(description: "could not create isolated defaults suite") }
        defaults.set(false, forKey: AgentRecordArchiveConfig.enabledKey)
        supervisor.recordArchiveDefaults = defaults
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let app = AppDelegate(); app.agentSupervisor = supervisor
        let canvas = CanvasNSView(canvasState: .init(viewport: .init(x: 0, y: 0, zoom: 1), tiles: [], groups: [], lastActiveTileId: nil))
        let beforeScans = SpawnResultFile.pruneEnumerationsForQA
        let beforeDecodes = SpawnResultFile.pruneDecodesForQA
        var initial = malloc_statistics_t(); malloc_zone_statistics(nil, &initial)
        let sampler = Sampler(); sampler.start()
        let baseline = sampler.currentPeaks()
        defer { _ = sampler.stop() }
        try app.mountWorkspaceSceneAtBoot(canvasView: canvas, spawner: nil, projectStore: nil,
            canvasState: RestoreScalingChecks.emptyCanvas, installsGlobalEventMonitors: false)
        await supervisor.flushHelperCompletions()
        let peak = sampler.stop()
        let scans = SpawnResultFile.pruneEnumerationsForQA - beforeScans
        let decodes = SpawnResultFile.pruneDecodesForQA - beforeDecodes
        supervisor.stopAll()
        print("METRIC delivery-restore records=2300 transcripts=2200 rows=1305/367 prune-scans=\(scans) prune-decodes=\(decodes) malloc-before=\(initial.size_in_use) malloc-peak=\(peak.malloc) pipes-before=\(baseline.pipes) pipes-peak=\(peak.pipes)")
        try expect(supervisor.records.count == ids.count, "all records restored")
        let decoder = JSONCodec.makeDecoder()
        for (url, expected) in retained {
            let actual = try decoder.decode(SpawnResultFile.Delivery.self, from: Data(contentsOf: url))
            try expect(actual == expected, "pending and recent deliveries survive recovery unchanged")
        }
        try expect(expired.allSatisfy { !fm.fileExists(atPath: $0.path) }, "old delivered rows are pruned")
        try expect(scans <= 3 && decodes <= 1672, "each checkout's delivery journal must be pruned once; scans=\(scans), decodes=\(decodes)")
        try expect(peak.malloc - initial.size_in_use < 256 * 1024 * 1024, "restore malloc peak exceeded 256 MiB above baseline")
        return "PASS delivery restore scaling: one prune per checkout; pending and recent rows preserved"
    }
}
