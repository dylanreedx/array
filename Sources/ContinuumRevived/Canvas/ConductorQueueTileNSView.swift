import AppKit
import Darwin
import ContinuumRevivedCore

@MainActor
final class ConductorQueueTileNSView: TileNSView {
    private(set) var renderedTaskIds: [String] = []
    private(set) var emptyStateMessage: String?
    private(set) var warningMessages: [String] = []
    private(set) var observedText: String = ""
    private let projectRoot: URL?
    // All vnode bookkeeping is main-actor isolated; the SQLite process never is.
    private var watches: [String: (source: DispatchSourceFileSystemObject, identity: FileIdentity)] = [:]
    private var lastDatabaseIdentity: [String: FileIdentity] = [:]
    private var lastDirectoryAccess: [String: FileAccess] = [:]
    private var readInFlight = false
    private var readAgain = false
    private var retryGeneration: UInt64 = 0
    private var retryDelay: TimeInterval = 0.25
    private(set) var retryFireCount = 0
    private(set) var refreshRequestCount = 0
    private(set) var completedReadCount = 0
    private(set) var lastReadWasOnMainThread: Bool?

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int

        init?(_ path: String) {
            var info = Darwin.stat()
            guard lstat(path, &info) == 0 else { return nil }
            device = UInt64(info.st_dev)
            inode = UInt64(info.st_ino)
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
        }

        func sameFile(as other: FileIdentity) -> Bool {
            device == other.device && inode == other.inode
        }
    }

    private struct FileAccess: Equatable {
        let mode: UInt16
        let owner: UInt32
        let group: UInt32

        init?(_ path: String) {
            var info = Darwin.stat()
            guard lstat(path, &info) == 0 else { return nil }
            mode = info.st_mode
            owner = info.st_uid
            group = info.st_gid
        }
    }

    init(tile: Tile, snapshot: ConductorQueueSnapshot, emptyStateMessage: String? = "No conductor tasks") {
        self.projectRoot = nil
        super.init(tile: tile)
        apply(snapshot: snapshot, emptyStateMessage: emptyStateMessage)
    }

    convenience init(tile: Tile, projectRoot: URL) {
        self.init(tile: tile, projectRoot: projectRoot, startTimer: true)
    }

    init(tile: Tile, projectRoot: URL, startTimer: Bool) {
        self.projectRoot = projectRoot
        super.init(tile: tile)
        // Install the watches before the first read, so a concurrent write cannot
        // fall between an initial snapshot and observation being armed.
        if startTimer { updateWatches() }
        refreshNow()
    }

    func refreshNow() {
        guard let projectRoot else { return }
        refreshRequestCount += 1
        // Invalidate a failure retry when a new filesystem event arrives.
        retryGeneration &+= 1
        guard !readInFlight else {
            readAgain = true
            return
        }
        readInFlight = true
        Task.detached(priority: .utility) { [weak self] in
            let onMainThread = (pthread_main_np() != 0)
            let snapshot: ConductorQueueSnapshot
            let succeeded: Bool
            do {
                snapshot = try ConductorQueueReader().read(projectRoot: projectRoot)
                succeeded = true
            } catch {
                snapshot = ConductorQueueSnapshot(tasks: [], warnings: [String(describing: error)])
                succeeded = false
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.completedReadCount += 1
                self.lastReadWasOnMainThread = onMainThread
                self.apply(snapshot: snapshot)
                self.readInFlight = false
                if succeeded {
                    self.retryDelay = 0.25
                    self.retryGeneration &+= 1
                }
                if self.readAgain {
                    self.readAgain = false
                    self.refreshNow()
                } else if !succeeded {
                    self.scheduleFailureRetry()
                }
            }
        }
    }

    // A lock can clear without a filesystem change. Retry only failures, with
    // exponential backoff capped at five seconds; successful queues stay idle.
    private func scheduleFailureRetry() {
        let generation = retryGeneration
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 5)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.retryGeneration == generation else { return }
                self.retryFireCount += 1
                self.refreshNow()
            }
        }
    }

    // SQLite opens the database through any symlink and keeps its WAL beside the
    // resolved file, so the database and its directory are watched at the target.
    private func watchLocations(_ projectRoot: URL) -> (root: String, directory: String, database: String) {
        let directory = projectRoot.appendingPathComponent(".conductor", isDirectory: true).path
        let database = URL(fileURLWithPath: directory + "/conductor.db").resolvingSymlinksInPath().path
        return (projectRoot.path, directory, database)
    }

    private func updateWatches() {
        guard let projectRoot else { return }
        let (rootPath, directory, database) = watchLocations(projectRoot)
        let wal = database + "-wal"
        let filePaths = [database, wal]
        let identities = Dictionary(uniqueKeysWithValues: filePaths.compactMap { path in
            FileIdentity(path).map { (path, $0) }
        })
        // The root watch catches creation/replacement of .conductor, and the
        // directory watch catches db/WAL creation and atomic replacement.
        let paths = Array(Set([rootPath, directory, (database as NSString).deletingLastPathComponent])) + filePaths
        for path in Array(watches.keys) where !paths.contains(path) || FileIdentity(path).map({ !watches[path]!.identity.sameFile(as: $0) }) != false {
            watches.removeValue(forKey: path)?.source.cancel()
        }
        for path in paths where watches[path] == nil {
            guard let identity = FileIdentity(path) else { continue }
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in self?.filesystemChanged(path: path) }
            }
            source.setCancelHandler { close(fd) }
            watches[path] = (source, identity)
            source.resume()
        }
        lastDatabaseIdentity = identities
        lastDirectoryAccess = Dictionary(uniqueKeysWithValues: [rootPath, directory].compactMap { path in
            FileAccess(path).map { (path, $0) }
        })
    }

    private func filesystemChanged(path: String) {
        guard let projectRoot else { return }
        let database = watchLocations(projectRoot).database
        let old = lastDatabaseIdentity
        let oldAccess = lastDirectoryAccess
        updateWatches()
        // Directory events include SQLite's own -shm traffic. Do not re-read
        // for those unless the database or WAL actually changed.
        if path == database || path == database + "-wal" || old != lastDatabaseIdentity || oldAccess != lastDirectoryAccess {
            refreshNow()
        }
    }

    // Invoked by the conductor matrix leg. Counts calls into the actual refresh
    // path, not a model of its scheduling; it also exercises creation and WAL.
    static func runEventDrivenSelfCheck() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("array-conductor-events-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let tile = Tile(id: UUID(), kind: .conductorQueue, title: "Conductor Queue", frame: TileFrame(x: 0, y: 0, width: 500, height: 400), zPosition: .fromLegacyRank(1), runtimeRef: nil, metadata: TileMetadata())
        let view = ConductorQueueTileNSView(tile: tile, projectRoot: root, startTimer: true)
        func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() && Date() < deadline {
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            return condition()
        }
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "ConductorQueueEventCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        try require(waitUntil({ view.completedReadCount >= 1 }), "initial conductor read did not finish")
        let beforeIdle = view.refreshRequestCount
        _ = waitUntil({ false }, timeout: 1.5)
        let idleWakeups = view.refreshRequestCount - beforeIdle
        try require(idleWakeups == 0, "conductor made \(idleWakeups) idle refresh calls")
        try require(view.lastReadWasOnMainThread == false, "conductor read ran on the main thread")
        let directory = root.appendingPathComponent(".conductor", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = directory.appendingPathComponent("conductor.db")
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [db.path]
        let input = Pipe()
        sqlite.standardInput = input
        sqlite.standardOutput = FileHandle.nullDevice
        sqlite.standardError = FileHandle.nullDevice
        try sqlite.run()
        defer {
            try? input.fileHandleForWriting.close()
            if sqlite.isRunning { sqlite.terminate() }
        }
        let create = """
        CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT NOT NULL);
        CREATE TABLE tasks (id TEXT PRIMARY KEY, project_id TEXT, category TEXT NOT NULL, phase INTEGER NOT NULL, description TEXT NOT NULL, status TEXT NOT NULL, priority INTEGER NOT NULL, attempt_count INTEGER NOT NULL, updated_at INTEGER);
        INSERT INTO tasks VALUES ('event-task', NULL, 'qa', 1, 'observed', 'pending', 1, 0, 1);
        """
        input.fileHandleForWriting.write(Data((create + "\n").utf8))
        try require(waitUntil({ view.observedText.contains("event-task · pending") }), "db creation did not update the conductor queue")
        // Keep this connection open so the update remains in the WAL.
        input.fileHandleForWriting.write(Data("PRAGMA journal_mode=WAL; UPDATE tasks SET status='running' WHERE id='event-task';\n".utf8))
        try require(waitUntil({ view.observedText.contains("event-task · running") }), "WAL update did not reach the conductor queue")
        // Let the notifications from the WAL transaction settle before taking
        // a second idle sample with a populated database and open connection.
        _ = waitUntil({ false }, timeout: 0.5)
        let beforeDatabaseIdle = view.refreshRequestCount
        _ = waitUntil({ false }, timeout: 1.5)
        let databaseIdleWakeups = view.refreshRequestCount - beforeDatabaseIdle
        try require(databaseIdleWakeups == 0, "populated conductor queue made \(databaseIdleWakeups) idle refresh calls")
        // Hold an exclusive rollback-journal lock without changing the database.
        // Releasing this lock produces no required database/WAL write event.
        let lockRoot = root.appendingPathComponent("lock-project", isDirectory: true)
        let lockDir = lockRoot.appendingPathComponent(".conductor", isDirectory: true)
        try fm.createDirectory(at: lockDir, withIntermediateDirectories: true)
        let lockDB = lockDir.appendingPathComponent("conductor.db")
        let locker = Process()
        locker.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        locker.arguments = [lockDB.path]
        let lockInput = Pipe()
        locker.standardInput = lockInput
        locker.standardOutput = FileHandle.nullDevice
        locker.standardError = FileHandle.nullDevice
        try locker.run()
        defer {
            try? lockInput.fileHandleForWriting.close()
            if locker.isRunning { locker.terminate() }
        }
        lockInput.fileHandleForWriting.write(Data((create + "\nBEGIN EXCLUSIVE;\n").utf8))
        func locked() -> Bool {
            guard fm.fileExists(atPath: lockDB.path) else { return false }
            let probe = Process()
            probe.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            probe.arguments = [lockDB.path, "BEGIN IMMEDIATE; ROLLBACK;"]
            probe.standardOutput = FileHandle.nullDevice
            probe.standardError = FileHandle.nullDevice
            do { try probe.run() } catch { return false }
            probe.waitUntilExit()
            return probe.terminationStatus != 0
        }
        try require(waitUntil({ locked() }), "fixture did not acquire exclusive database lock")
        let lockedView = ConductorQueueTileNSView(tile: tile, projectRoot: lockRoot, startTimer: true)
        try require(waitUntil({ !lockedView.warningMessages.isEmpty }), "locked database did not show a warning")
        try require(waitUntil({ lockedView.retryFireCount > 0 && lockedView.completedReadCount >= 2 }), "failed read did not retry while locked")
        lockInput.fileHandleForWriting.write(Data("ROLLBACK;\n".utf8))
        try require(waitUntil({ lockedView.warningMessages.isEmpty && lockedView.observedText.contains("event-task · pending") }, timeout: 10), "queue did not recover after a lock was released")
        _ = waitUntil({ false }, timeout: 0.5)
        let recoveredIdle = lockedView.refreshRequestCount
        _ = waitUntil({ false }, timeout: 1.5)
        try require(lockedView.refreshRequestCount == recoveredIdle, "successful recovery continued retrying at idle")
        // A database reached through a symlink: writes land at the target.
        let linkRoot = root.appendingPathComponent("link-project", isDirectory: true)
        let linkDir = linkRoot.appendingPathComponent(".conductor", isDirectory: true)
        let targetDir = root.appendingPathComponent("link-target", isDirectory: true)
        try fm.createDirectory(at: linkDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let targetDB = targetDir.appendingPathComponent("real.db")
        try fm.createSymbolicLink(at: linkDir.appendingPathComponent("conductor.db"), withDestinationURL: targetDB)
        let linker = Process()
        linker.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        linker.arguments = [targetDB.path]
        let linkInput = Pipe()
        linker.standardInput = linkInput
        linker.standardOutput = FileHandle.nullDevice
        linker.standardError = FileHandle.nullDevice
        try linker.run()
        defer {
            try? linkInput.fileHandleForWriting.close()
            if linker.isRunning { linker.terminate() }
        }
        linkInput.fileHandleForWriting.write(Data((create + "\n").utf8))
        try require(waitUntil({ fm.fileExists(atPath: targetDB.path) }), "symlink fixture db was not created")
        let linkedView = ConductorQueueTileNSView(tile: tile, projectRoot: linkRoot, startTimer: true)
        try require(waitUntil({ linkedView.observedText.contains("event-task · pending") }), "symlinked db was not read")
        linkInput.fileHandleForWriting.write(Data("UPDATE tasks SET status='running' WHERE id='event-task';\n".utf8))
        try require(waitUntil({ linkedView.observedText.contains("event-task · running") }), "update through a symlinked db did not reach the queue")
        print("Conductor idle refresh callbacks in 1.5 s: empty=\(idleWakeups), populated=\(databaseIdleWakeups)")
    }

    private func apply(snapshot: ConductorQueueSnapshot, emptyStateMessage: String? = "No conductor tasks") {
        renderedTaskIds = snapshot.tasks.map(\.id)
        warningMessages = snapshot.warnings
        self.emptyStateMessage = snapshot.tasks.isEmpty && snapshot.warnings.isEmpty ? emptyStateMessage : nil
        observedText = Self.text(for: snapshot, emptyStateMessage: emptyStateMessage)

        let body = NSStackView()
        body.orientation = .vertical
        body.spacing = 8
        body.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        body.wantsLayer = true
        body.layer?.backgroundColor = NSColor(red: 0.10, green: 0.14, blue: 0.18, alpha: 1).cgColor

        let header = NSTextField(labelWithString: tile.title)
        header.font = NSFont.boldSystemFont(ofSize: 14)
        header.textColor = .white
        body.addArrangedSubview(header)

        if !snapshot.warnings.isEmpty {
            let warning = NSTextField(labelWithString: "Conductor queue unavailable: \(snapshot.warnings.joined(separator: "; "))")
            warning.font = NSFont.systemFont(ofSize: 12)
            warning.textColor = .systemOrange
            warning.lineBreakMode = .byTruncatingTail
            body.addArrangedSubview(warning)
        } else if snapshot.tasks.isEmpty {
            let empty = NSTextField(labelWithString: emptyStateMessage ?? "No conductor tasks")
            empty.font = NSFont.systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            body.addArrangedSubview(empty)
        } else {
            for task in snapshot.tasks {
                let label = NSTextField(labelWithString: Self.line(for: task))
                label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                label.textColor = .lightGray
                label.lineBreakMode = .byTruncatingTail
                body.addArrangedSubview(label)
            }
        }

        setContentView(body)
    }

    static func text(for snapshot: ConductorQueueSnapshot, emptyStateMessage: String? = "No conductor tasks") -> String {
        if !snapshot.warnings.isEmpty { return "Conductor queue unavailable: \(snapshot.warnings.joined(separator: "; "))" }
        guard !snapshot.tasks.isEmpty else { return emptyStateMessage ?? "No conductor tasks" }
        return snapshot.tasks.map(line(for:)).joined(separator: "\n")
    }

    private static func line(for task: ConductorQueueTask) -> String {
        let project = task.projectName ?? task.projectId ?? "no-project"
        return "\(task.id) · \(task.status) · p\(task.priority) · phase \(task.phase) · \(project) · attempts \(task.attemptCount) · \(task.description)"
    }

    deinit {
        for watch in watches.values { watch.source.cancel() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
