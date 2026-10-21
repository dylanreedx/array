import Foundation

// The process table and the CLIs' home folders are a Mac's; Core also builds for iOS.
#if os(macOS)
import Darwin

/// One discovery pass: which Claude and Codex sessions run on this Mac, where,
/// and who owns each.
///
/// Everything it reads is injected — the process table, the home folders, the
/// per-process cwd and open-file probes — so a check drives it with synthetic
/// files and processes and never reads anyone's real sessions. It keeps small
/// caches between passes (titles, rollout headers), so it is not thread-safe:
/// one instance per queue.
public final class ExternalSessionDiscovery {
    public struct Inputs {
        /// The user's home: Claude's files are under `<home>/.claude`.
        public var homeURL: URL
        /// `$CODEX_HOME`, else `<home>/.codex`.
        public var codexHomeURL: URL
        public var processes: [ProcessSample]
        /// This app. Ancestry stops here when looking for an owner tag.
        public var hostPid: Int32
        public var now: Date
        /// Codex files rollouts under `sessions/YYYY/MM/DD` in local time.
        public var calendar: Calendar
        public var processCwd: (Int32) -> String?
        public var openFiles: (Int32) -> [String]

        public init(
            homeURL: URL, codexHomeURL: URL? = nil, processes: [ProcessSample], hostPid: Int32,
            now: Date, calendar: Calendar = .current,
            processCwd: @escaping (Int32) -> String? = { _ in nil },
            openFiles: @escaping (Int32) -> [String] = { _ in [] }
        ) {
            self.homeURL = homeURL
            self.codexHomeURL = codexHomeURL ?? homeURL.appendingPathComponent(".codex", isDirectory: true)
            self.processes = processes
            self.hostPid = hostPid
            self.now = now
            self.calendar = calendar
            self.processCwd = processCwd
            self.openFiles = openFiles
        }
    }

    /// How far back Codex's dated rollout folders are scanned. A thread older
    /// than this that is still being written is missed; scanning the whole
    /// history every few seconds is the alternative.
    static let codexDaysScanned = 7
    /// Tail read for a Claude title. Claude re-writes `ai-title` every turn, so
    /// the newest is near the end.
    static let titleTailBytes = 64 * 1024

    private var claudeTitles: [String: (stamp: Date, title: String?)] = [:]
    private var rolloutMetas: [String: CodexRolloutLocator.SessionMeta] = [:]
    private var codexIndex: (stamp: Date, names: [String: String])?

    public init() {}

    public func discover(_ inputs: Inputs) -> ExternalSessionSnapshot {
        let claude = discoverClaude(inputs)
        let codex = discoverCodex(inputs)
        return ExternalSessionSnapshot(sessions: claude.sessions + codex, claudeUnreadable: claude.unreadable)
    }

    // MARK: Claude

    private func discoverClaude(_ inputs: Inputs) -> (sessions: [ExternalAgentSession], unreadable: Bool) {
        let folder = inputs.homeURL.appendingPathComponent(".claude/sessions", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? [])
            // `<pid>.json` only. The `.key` files beside them are never opened.
            .filter { $0.pathExtension == "json" }
        var records: [ClaudeLiveSessions.Record] = []
        for file in files {
            guard let pid = Int32(file.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: file),
                  let record = ClaudeLiveSessions.parse(data, filePid: pid) else { continue }
            records.append(record)
        }
        var seenTranscripts: Set<String> = []
        let result = ClaudeLiveSessions.sessions(
            records: records, fileCount: files.count, processes: inputs.processes,
            hostPid: inputs.hostPid, homeURL: inputs.homeURL
        ) { [self] _, transcript in
            seenTranscripts.insert(transcript.path)
            return claudeTitle(transcript)
        }
        claudeTitles = claudeTitles.filter { seenTranscripts.contains($0.key) }
        return result
    }

    /// Re-read only when the transcript has changed since the last pass.
    private func claudeTitle(_ transcript: URL) -> String? {
        let modified = (try? transcript.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        guard let modified else { return nil }
        if let cached = claudeTitles[transcript.path], cached.stamp == modified { return cached.title }
        let lines = ManagedTranscriptRehydrator.readTailLines(at: transcript, maxBytes: Self.titleTailBytes).lines
        let title = ClaudeLiveSessions.title(fromTranscriptLines: lines)
        claudeTitles[transcript.path] = (modified, title)
        return title
    }

    // MARK: Codex

    private func discoverCodex(_ inputs: Inputs) -> [ExternalAgentSession] {
        let sessionsRoot = inputs.codexHomeURL.appendingPathComponent("sessions", isDirectory: true)
        let rollouts = recentRollouts(sessionsRoot: sessionsRoot, inputs: inputs)
        return CodexLiveSessions.sessions(
            processes: inputs.processes, hostPid: inputs.hostPid, rollouts: rollouts,
            sessionsRoot: sessionsRoot, threadNames: codexThreadNames(inputs.codexHomeURL), now: inputs.now,
            processCwd: inputs.processCwd, openFiles: inputs.openFiles)
    }

    private func recentRollouts(sessionsRoot: URL, inputs: Inputs) -> [CodexLiveSessions.Rollout] {
        let locator = CodexRolloutLocator(sessionsRoot: sessionsRoot, archivedSessionsRoot: nil)
        var rollouts: [CodexLiveSessions.Rollout] = []
        var seen: Set<String> = []
        for offset in 0...Self.codexDaysScanned {
            guard let day = inputs.calendar.date(byAdding: .day, value: -offset, to: inputs.now) else { continue }
            let parts = inputs.calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let date = parts.day else { continue }
            let folder = sessionsRoot.appendingPathComponent(
                String(format: "%04d/%02d/%02d", year, month, date), isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl" {
                let path = file.standardizedFileURL.path
                guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate else { continue }
                seen.insert(path)
                // A rollout's first line never changes once written.
                let meta = rolloutMetas[path] ?? locator.readSessionMeta(from: file)
                guard let meta else { continue }
                rolloutMetas[path] = meta
                rollouts.append(CodexLiveSessions.Rollout(url: file, modified: modified, meta: meta))
            }
        }
        rolloutMetas = rolloutMetas.filter { seen.contains($0.key) }
        return rollouts
    }

    private func codexThreadNames(_ codexHome: URL) -> [String: String] {
        let index = codexHome.appendingPathComponent("session_index.jsonl")
        guard let modified = (try? index.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate else { return [:] }
        if let codexIndex, codexIndex.stamp == modified { return codexIndex.names }
        let names = CodexLiveSessions.threadNames(
            fromIndexLines: CodexRolloutLocator.lines(of: index, maxBytes: 8 * 1024 * 1024))
        codexIndex = (modified, names)
        return names
    }
}

/// What a process has open, straight from the kernel.
public enum ProcessFileProbe {
    /// The process's current directory.
    public static func currentDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    /// The paths of the files it holds open.
    public static func openVnodePaths(_ pid: Int32) -> [String] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 8)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize) == infoSize else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }
}

extension ExternalSessionDiscovery.Inputs {
    /// This Mac, now: the real process table and the user's real folders.
    public static func live(reader: ProcessTableReader, now: Date = Date()) -> Self {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        return Self(
            homeURL: home, codexHomeURL: codexHome, processes: reader.sample(), hostPid: getpid(), now: now,
            processCwd: ProcessFileProbe.currentDirectory, openFiles: ProcessFileProbe.openVnodePaths)
    }
}
#endif
