import CoreServices
import Foundation

/// `.plans/116` gap 20: a Managed lead that changes its own checkout through
/// its shell. Recording only: nothing here blocks, prompts or changes what any
/// agent sees. Its own serial queue does all the work; the ledger's queue only
/// appends the finished row.
///
/// The lead's own shell calls arrive on its runtime side channel. A Claude
/// in-process subagent's calls are not on it, and a delegated helper has its
/// own record, so a call here is the lead's.
///
/// What changed: FSEvents, file by file, for each lead checkout, from the
/// first lead shell call on it. An event counts for a call when it arrives
/// between `startSlack` before the host saw the call start and the host's flush
/// of pending events at the call's end. So a call that wrote nothing costs one
/// flush and no process; a deleted folder's files, and files written then
/// committed inside the call, are each seen. Events under `.git/` and `.array/`
/// never count, nor files git ignores (one `git check-ignore` over the changed
/// paths only, lock-free, bounded). An event counts for one call at most.
///
/// Telling the lead from the first helper: that helper shares the lead's
/// checkout. If any other agent on the same checkout was running when the call
/// started or ended (the supervisor's own state, read on main), ended a turn
/// within `startSlack` before the call started, or started or ended a turn
/// while it was open, the change is `ambiguous`, never the lead's.
///
/// Bounds: at most `maxEvents` events kept per checkout and `maxCandidates`
/// paths per call; git gets `gitTimeout` and `maxGitOutput`. Past any bound
/// the row says `changes: unknown` with the reason, never a count.
final class LeadCheckoutWatch: @unchecked Sendable {
    struct Change: Equatable {
        var modified = 0, added = 0, deleted = 0
        var paths: [String] = []
        var count: Int { modified + added + deleted }
    }
    enum Outcome: Equatable {
        case changed(Change, ambiguous: Bool)
        case unknown(reason: String, ambiguous: Bool)
    }

    static let startSlack: TimeInterval = 0.5
    /// FSEvents reaches this process a little after a write, and a flush can
    /// return before the delivery runs. A call's end is settled this long after
    /// the host saw it (off every request path), counting events that arrived
    /// by `endSlack` after it.
    static let settle: TimeInterval = 0.25
    static let endSlack: TimeInterval = 0.1
    static let maxPaths = 64
    static let maxEvents = 20_000
    static let maxCandidates = 2_000
    static let gitTimeout: TimeInterval = 2
    static let maxGitOutput = 1 << 20

    private let queue = DispatchQueue(label: "dev.array.lead-checkout", qos: .utility)
    private let deliveries = DispatchQueue(label: "dev.array.lead-checkout.events", qos: .utility)
    /// Set once, before the first call: `(lead, call, outcome)`, on this queue.
    var onOutcome: ((UUID, String, Outcome) -> Void)?

    private struct Event { var path: String; var flags: FSEventStreamEventFlags; var at: Date; var counted = false }
    /// One checkout's events. FSEvents delivers on `deliveries`, never on the
    /// watch's queue, so the watch can flush synchronously; the lock guards
    /// what the two share.
    private final class Stream {
        let root: String
        var stream: FSEventStreamRef?
        let lock = NSLock()
        var pending: [Event] = []          // lock
        var keepFrom: Date?                // lock: earliest open call's start less the slack
        var overflowAt: Date?              // lock: when events were last lost
        var events: [Event] = []           // watch queue only
        init(root: String) { self.root = root }

        /// On `deliveries`.
        func received(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
            let now = Date()
            lock.lock(); defer { lock.unlock() }
            for (index, path) in paths.enumerated() {
                let flag = flags[index]
                if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagKernelDropped
                                                  | kFSEventStreamEventFlagUserDropped) != 0 { overflowAt = now; continue }
                guard path.hasPrefix(root + "/"),
                      flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsSymlink) != 0 else { continue }
                let relative = String(path.dropFirst(root.count + 1))
                if relative == ".git" || relative.hasPrefix(".git/") || relative.hasPrefix(".array/") { continue }
                pending.append(Event(path: relative, flags: flag, at: now))
            }
            let from = keepFrom ?? now.addingTimeInterval(-LeadCheckoutWatch.startSlack)
            if let first = pending.firstIndex(where: { $0.at >= from }), first > 0 { pending.removeFirst(first) }
            else if pending.last.map({ $0.at < from }) == true { pending.removeAll() }
            if pending.count > LeadCheckoutWatch.maxEvents {
                pending.removeFirst(pending.count - LeadCheckoutWatch.maxEvents)
                overflowAt = now
            }
        }

        /// On the watch queue: everything delivered so far moves to `events`.
        func collect(keepFrom: Date?) -> Date? {
            lock.lock(); defer { lock.unlock() }
            events += pending; pending.removeAll()
            self.keepFrom = keepFrom
            return overflowAt
        }
    }
    private struct Call { var start: Date; var shared: Bool }
    private var streams: [String: Stream] = [:]
    private var open: [UUID: [String: Call]] = [:]
    private var turnOpen = Set<UUID>()
    private var turnEndedAt: [UUID: Date] = [:]
    private var roots: [UUID: String] = [:]
    private var resolved: [String: String] = [:]

    init() {}

    deinit { for stream in streams.values { stop(stream) } }

    private var settling = 0
    /// Waits for every hand-off so far, settled ends included. Checks only.
    func drain() {
        while queue.sync(execute: { settling }) > 0 { usleep(20_000) }
    }

    /// `lead`: a Managed lead, whose checkout is watched from this turn on, so
    /// its first shell call is seen whole.
    func turnStarted(agent: UUID, root: String?, lead: Bool = false) {
        queue.async {
            if let root {
                self.roots[agent] = self.resolve(root)
                if lead { self.ensureStream(self.roots[agent]!) }
            }
            self.turnOpen.insert(agent)
            self.markShared(by: agent)
        }
    }

    func turnEnded(agent: UUID) {
        let at = Date()
        queue.async {
            self.turnOpen.remove(agent)
            self.turnEndedAt[agent] = at
            self.markShared(by: agent)
        }
    }

    /// `busy`: another agent on this checkout was running as the call started.
    func shellStarted(lead: UUID, call: String, root: String, busy: Bool) {
        let at = Date()
        queue.async {
            let checkout = self.resolve(root)
            self.roots[lead] = checkout
            self.ensureStream(checkout)
            let recent = self.turnEndedAt.contains { $0.key != lead && self.roots[$0.key] == checkout && $0.value >= at.addingTimeInterval(-Self.startSlack) }
            let openTurn = self.turnOpen.contains { $0 != lead && self.roots[$0] == checkout }
            self.open[lead, default: [:]][call] = Call(start: at, shared: busy || recent || openTurn)
            _ = self.streams[checkout]?.collect(keepFrom: self.keepFrom(checkout))
        }
    }

    func shellEnded(lead: UUID, call: String, busy: Bool) {
        let end = Date()
        queue.async { self.settling += 1 }
        queue.asyncAfter(deadline: .now() + Self.settle) {
            self.settling -= 1
            guard let opened = self.open[lead]?.removeValue(forKey: call), let checkout = self.roots[lead],
                  let stream = self.streams[checkout] else { return }
            if let ref = stream.stream { FSEventStreamFlushSync(ref) }
            self.deliveries.sync {}
            let overflowAt = stream.collect(keepFrom: self.keepFrom(checkout))
            let ambiguous = opened.shared || busy || self.turnOpen.contains { $0 != lead && self.roots[$0] == checkout }
            let from = opened.start.addingTimeInterval(-Self.startSlack)
            var mine: [Event] = []
            let to = end.addingTimeInterval(Self.endSlack)
            for index in stream.events.indices where stream.events[index].at >= from && stream.events[index].at <= to && !stream.events[index].counted {
                stream.events[index].counted = true
                mine.append(stream.events[index])
            }
            let keep = self.keepFrom(checkout) ?? Date().addingTimeInterval(-Self.startSlack)
            stream.events.removeAll { $0.at < keep }
            if let overflowAt, overflowAt >= from {
                self.onOutcome?(lead, call, .unknown(reason: "tooManyEvents", ambiguous: ambiguous)); return
            }
            guard !mine.isEmpty else { return }
            switch Self.classify(mine, root: checkout) {
            case let .success(change) where change.count > 0:
                self.onOutcome?(lead, call, .changed(change, ambiguous: ambiguous))
            case .success: break
            case let .failure(reason): self.onOutcome?(lead, call, .unknown(reason: reason.rawValue, ambiguous: ambiguous))
            }
        }
    }

    // MARK: Events

    private func resolve(_ root: String) -> String {
        if let known = resolved[root] { return known }
        // realpath, not `resolvingSymlinksInPath`: Foundation strips `/private`,
        // and FSEvents reports `/private/var/...`.
        var path = URL(fileURLWithPath: root).standardizedFileURL.path
        if let real = realpath(root, nil) { path = String(cString: real); free(real) }
        resolved[root] = path
        return path
    }

    private func markShared(by agent: UUID) {
        guard let root = roots[agent] else { return }
        for (lead, calls) in open where lead != agent && roots[lead] == root {
            for call in calls.keys { open[lead]![call]!.shared = true }
        }
    }

    private func ensureStream(_ root: String) {
        guard streams[root] == nil else { return }
        let holder = Stream(root: root)
        streams[root] = holder
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(holder).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            Unmanaged<Stream>.fromOpaque(info).takeUnretainedValue().received(list, Array(UnsafeBufferPointer(start: flags, count: count)))
        }
        let created = FSEventStreamCreate(nil, callback, &context, [root] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                                                                   | kFSEventStreamCreateFlagUseCFTypes))
        guard let created else { return }
        FSEventStreamSetDispatchQueue(created, deliveries)
        guard FSEventStreamStart(created) else { FSEventStreamInvalidate(created); FSEventStreamRelease(created); return }
        holder.stream = created
    }

    private func stop(_ stream: Stream) {
        guard let ref = stream.stream else { return }
        FSEventStreamStop(ref); FSEventStreamInvalidate(ref); FSEventStreamRelease(ref)
    }

    /// The earliest moment an open call on this checkout could still claim.
    private func keepFrom(_ root: String) -> Date? {
        open.filter { roots[$0.key] == root }.flatMap { $0.value.values.map(\.start) }.min()?.addingTimeInterval(-Self.startSlack)
    }

    // MARK: Classification

    enum Unknown: String, Error { case tooManyPaths, gitTimedOut, gitOutputTooLarge, gitFailed }

    private static func classify(_ events: [Event], root: String) -> Result<Change, Unknown> {
        var created = Set<String>(), removedOrRenamed = Set<String>(), order: [String] = []
        for event in events {
            if !order.contains(event.path) { order.append(event.path) }
            if event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0 { created.insert(event.path) }
            if event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed) != 0 {
                removedOrRenamed.insert(event.path)
            }
        }
        guard order.count <= maxCandidates else { return .failure(.tooManyPaths) }
        let ignored: Set<String>
        switch Self.ignoredPaths(order, root: root) {
        case let .success(set): ignored = set
        case let .failure(reason): return .failure(reason)
        }
        var change = Change()
        for path in order.sorted() where !ignored.contains(path) {
            let exists = FileManager.default.fileExists(atPath: root + "/" + path)
            if !exists {
                // Created and removed inside the window: a temporary file, nothing changed.
                if Self.createdFirst(path, events) { continue }
                change.deleted += 1
            } else if created.contains(path) || removedOrRenamed.contains(path) {
                change.added += 1
            } else {
                change.modified += 1
            }
            change.paths.append(path)
        }
        if change.paths.count > maxPaths { change.paths = Array(change.paths.prefix(maxPaths)) }
        return .success(change)
    }

    /// Whether the first event for `path` in the window created it.
    private static func createdFirst(_ path: String, _ events: [Event]) -> Bool {
        guard let first = events.first(where: { $0.path == path }) else { return false }
        return first.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated) != 0
    }

    /// `git check-ignore` over these paths only: lock-free, timed, capped.
    /// Outside a repository nothing is ignored.
    static func ignoredPaths(_ paths: [String], root: String) -> Result<Set<String>, Unknown> {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "-C", root, "check-ignore", "--stdin", "-z"]
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return .failure(.gitFailed) }
        let feed = DispatchQueue(label: "dev.array.lead-checkout.feed")
        feed.async {
            input.fileHandleForWriting.write(Data(paths.joined(separator: "\0").utf8 + [0]))
            try? input.fileHandleForWriting.close()
        }
        var data = Data(), tooLarge = false
        let reader = DispatchQueue(label: "dev.array.lead-checkout.read")
        let readDone = DispatchSemaphore(value: 0)
        reader.async {
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                if data.count + chunk.count > maxGitOutput { tooLarge = true; process.terminate(); break }
                data.append(chunk)
            }
            readDone.signal()
        }
        if done.wait(timeout: .now() + gitTimeout) == .timedOut {
            process.terminate()
            _ = readDone.wait(timeout: .now() + 1)
            return .failure(.gitTimedOut)
        }
        _ = readDone.wait(timeout: .now() + 1)
        if tooLarge { return .failure(.gitOutputTooLarge) }
        // 0: some ignored; 1: none; 128: not a repository (nothing ignored).
        switch process.terminationStatus {
        case 0: return .success(Set(data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }))
        case 1, 128: return .success([])
        default: return .failure(.gitFailed)
        }
    }
}
