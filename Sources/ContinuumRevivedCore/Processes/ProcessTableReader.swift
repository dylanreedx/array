#if os(macOS)
import Darwin
import Foundation

/// Reads the process table straight from the kernel (`libproc`, `sysctl`):
/// no `ps` or `lsof` subprocess per tick.
///
/// Argument and environment reads are cached by pid + start time, so a steady
/// process table costs one `proc_pidinfo` per process per sample; only a new
/// process pays for `KERN_PROCARGS2` (failed reads are retried). Ownership
/// learned through ancestry survives reparenting for that exact process.
/// Not thread-safe: one reader per queue.
public final class ProcessTableReader {
    private struct Key: Hashable { let pid: Int32; let start: UInt64 }
    private struct Identity { let path: String; let arguments: [String]; let ownerTag: String?; let ownerFace: String? }
    private var identities: [Key: Identity] = [:]
    private var keysByPid: [Int32: Key] = [:]
    private var retainedOwners: [Key: String] = [:]
    private let uid = getuid()

    public init() {}

    /// Every process this user owns, without ports.
    public func sample() -> [ProcessSample] {
        var seen: Set<Key> = []
        var sampledKeys: [Int32: Key] = [:]
        var samples: [ProcessSample] = []
        for pid in Self.allPids() where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            // This read also fails for a zombie (exited, not yet reaped), which
            // `proc_listallpids` still lists: a killed job leaves at once even
            // while its parent has not got round to `wait`.
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == uid else { continue }
            let start = info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
            let key = Key(pid: pid, start: start)
            seen.insert(key)
            sampledKeys[pid] = key
            let identity: Identity
            if let cached = identities[key] {
                identity = cached
            } else {
                let read = Self.argumentsAndOwner(pid)
                identity = Identity(
                    path: read?.path ?? "", arguments: read?.arguments ?? [], ownerTag: read?.ownerTag,
                    ownerFace: read?.ownerFace)
                // A short-lived permission/exec race must not permanently
                // hide the process's command or its own owner tag.
                if read != nil { identities[key] = identity }
            }
            samples.append(ProcessSample(
                pid: pid,
                parentPid: Int32(info.pbi_ppid),
                startedAt: Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000),
                executablePath: identity.path,
                arguments: identity.arguments,
                ownerTag: identity.ownerTag,
                ownerFace: identity.ownerFace))
        }
        identities = identities.filter { seen.contains($0.key) }
        retainedOwners = retainedOwners.filter { seen.contains($0.key) }
        keysByPid = sampledKeys
        return samples
    }

    static func allPids() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return count > 0 ? Array(pids.prefix(Int(count))) : []
    }

    /// TCP ports `pid` is listening on.
    public static func listeningPorts(_ pid: Int32) -> [UInt16] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 8)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard got > 0 else { return [] }
        var ports: Set<UInt16> = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize,
                  info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            ports.insert(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
        }
        return ports.sorted()
    }

    /// Every listening process this user owns, for "what is on :3000?".
    public func listeningProcesses() -> [ProcessSample] {
        sample().compactMap { sample in
            let ports = Self.listeningPorts(sample.pid)
            guard !ports.isEmpty else { return nil }
            var withPorts = sample
            withPorts.listeningPorts = ports
            return withPorts
        }
    }

    /// `KERN_PROCARGS2`: argc, the exec path, then argv and envp as NUL-
    /// separated strings. Only the owner tag and face are kept from the environment.
    static func argumentsAndOwner(_ pid: Int32) -> (path: String, arguments: [String], ownerTag: String?, ownerFace: String?)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = MemoryLayout<Int32>.size
        let pathStart = index
        while index < size, buffer[index] != 0 { index += 1 }
        let path = String(decoding: buffer[pathStart..<index], as: UTF8.self)
        while index < size, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        var ownerTag: String?
        var ownerFace: String?
        let prefix = Array((AgentProcessAttribution.ownerEnvironmentKey + "=").utf8)
        let facePrefix = Array((AgentProcessAttribution.faceEnvironmentKey + "=").utf8)
        var start = index
        var strings = 0
        while index < size {
            if buffer[index] == 0 {
                if index == start {
                    // An empty argument inside argv; after argv, the end of
                    // the environment block.
                    guard strings < argc else { break }
                    arguments.append("")
                    strings += 1
                } else if strings < argc {
                    arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
                    strings += 1
                } else {
                    let length = index - start
                    if length > prefix.count, buffer[start..<(start + prefix.count)].elementsEqual(prefix) {
                        ownerTag = String(decoding: buffer[(start + prefix.count)..<index], as: UTF8.self)
                    } else if length > facePrefix.count,
                              buffer[start..<(start + facePrefix.count)].elementsEqual(facePrefix) {
                        ownerFace = String(decoding: buffer[(start + facePrefix.count)..<index], as: UTF8.self)
                    }
                    strings += 1
                }
                start = index + 1
            }
            index += 1
        }
        return (path, arguments, ownerTag, ownerFace)
    }
}
#endif

#if os(macOS)
extension ProcessTableReader {
    /// One tick of the tracker: the process table, the ports of the processes
    /// an agent owns, and the jobs they form, keyed by owner tag.
    ///
    /// Ports the host itself listens on are dropped: an agent launched by an
    /// older build inherited the workspace host's socket and would otherwise
    /// appear to be serving it.
    public func agentJobs(
        hostPid: Int32 = getpid(),
        internalPathPrefixes: [String],
        now: Date = Date(),
        minimumAge: TimeInterval = AgentProcessAttribution.minimumJobAge
    ) -> [String: [AgentBackgroundJob]] {
        var samples = sample()
        let currentOwners = AgentProcessAttribution.owners(in: samples, hostPid: hostPid)
        for index in samples.indices {
            let pid = samples[index].pid
            // Prefer what the current table proves. An untagged shell can
            // lose its tagged parent when the reply/CLI finishes; its last
            // established owner remains valid until this exact process exits.
            if let owner = currentOwners[pid] {
                samples[index].ownerTag = owner
            } else if let key = keysByPid[pid], let owner = retainedOwners[key] {
                samples[index].ownerTag = owner
            }
        }
        // Newly spawned descendants can inherit a retained owner's tag too.
        let owners = AgentProcessAttribution.owners(in: samples, hostPid: hostPid)
        for (pid, owner) in owners {
            if let key = keysByPid[pid] { retainedOwners[key] = owner }
        }
        let hostPorts = Set(Self.listeningPorts(hostPid))
        for index in samples.indices where owners[samples[index].pid] != nil {
            samples[index].listeningPorts = Self.listeningPorts(samples[index].pid)
                .filter { !hostPorts.contains($0) }
        }
        return AgentProcessAttribution.jobs(
            in: samples, hostPid: hostPid, internalPathPrefixes: internalPathPrefixes, now: now, minimumAge: minimumAge)
    }
}

/// Stopping a job the user picked from a list.
public enum AgentProcessControl {
    /// Whether `pid` is still the process that started at `startedAt`, and not
    /// one the OS has since given the same number.
    public static func isSameProcess(_ pid: Int32, startedAt: Date) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        let start = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
        return abs(start - startedAt.timeIntervalSince1970) < 0.001
    }

    /// SIGTERM to every process in the job, SIGKILL to whatever is left after
    /// `grace`. Blocks for at most `grace`; call it off the main thread. Returns
    /// the pids still alive at the end (empty on success).
    @discardableResult
    public static func terminate(_ job: AgentBackgroundJob, grace: TimeInterval = 2) -> [Int32] {
        func live() -> [Int32] {
            job.pids.filter { pid in job.startTimes[pid].map { isSameProcess(pid, startedAt: $0) } ?? false }
        }
        for pid in live() { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, !live().isEmpty { usleep(50_000) }
        for pid in live() { kill(pid, SIGKILL) }
        let killDeadline = Date().addingTimeInterval(1)
        while Date() < killDeadline, !live().isEmpty { usleep(20_000) }
        return live()
    }
}
#endif
