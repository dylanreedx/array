import Foundation

/// `.plans/116` gap 20: a Managed lead that changes its own checkout through
/// its shell. Recording only. Owned by `ManagedRunLedger` and run on its
/// queue; nothing here blocks, prompts or changes what any agent sees.
///
/// The lead's own shell calls arrive on its runtime side channel. A Claude
/// in-process subagent's calls are not on it, and a delegated helper has its
/// own record, so a call here is the lead's. When one ends, git lists the
/// checkout's changed files (ignored files, such as a build directory, and
/// Array's own `.array/` state never count). The queue may look seconds
/// later, so only times decide: a file counts when its modification time
/// falls inside the call, a deletion when its folder changed inside the call.
/// A file changed again before the host looked counts for the later change.
///
/// Telling the lead from the first helper: that helper shares the lead's
/// checkout. If any other agent on the same checkout was running when the
/// call started or ended (the supervisor's own running state, read on main),
/// or started or ended a turn in between (queue order, not clock time: a turn
/// start can reach the ledger after the supervisor already runs the agent),
/// the change cannot be told apart from that agent's and is recorded as
/// `ambiguous`, never as the lead's.
struct LeadCheckoutWatch {
    struct Change: Equatable {
        var modified = 0, added = 0, deleted = 0
        var paths: [String] = []
        var count: Int { modified + added + deleted }
    }

    /// Modification times are compared with the host's clock at the call's
    /// start and end. The host sees a start a little after the CLI began the
    /// call, so the window opens this much earlier. It sees the end after the
    /// command finished, so the window closes at the end.
    static let startSlack: TimeInterval = 0.5
    static let maxPaths = 64

    private struct Call { var start: Date; var shared: Bool }
    private var open: [UUID: [String: Call]] = [:]
    private var turnOpen = Set<UUID>()
    private var roots: [UUID: String] = [:]
    private var resolved: [String: String] = [:]
    /// Per checkout: (path, mtime) already counted, and deletions already counted.
    private var counted: [String: [String: Date]] = [:]
    private var deletions: [String: Set<String>] = [:]

    mutating func resolve(_ root: String) -> String {
        if let known = resolved[root] { return known }
        let path = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        resolved[root] = path
        return path
    }

    mutating func turnStarted(agent: UUID, root: String?) {
        if let root { roots[agent] = resolve(root) }
        turnOpen.insert(agent)
        markShared(by: agent)
    }

    mutating func turnEnded(agent: UUID) {
        turnOpen.remove(agent)
        markShared(by: agent)
    }

    /// Another agent's turn boundary while a lead's call on its checkout is open.
    private mutating func markShared(by agent: UUID) {
        guard let root = roots[agent] else { return }
        for (lead, calls) in open where lead != agent && roots[lead] == root {
            for call in calls.keys { open[lead]![call]!.shared = true }
        }
    }

    /// `busy`: another agent on this checkout was running as the call started.
    mutating func shellStarted(lead: UUID, call: String, root: String, at: Date, busy: Bool) {
        let checkout = resolve(root)
        roots[lead] = checkout
        let openTurn = turnOpen.contains { $0 != lead && roots[$0] == checkout }
        open[lead, default: [:]][call] = Call(start: at, shared: busy || openTurn)
    }

    /// nil when nothing counts or git cannot read the checkout.
    mutating func shellEnded(lead: UUID, call: String, at end: Date, busy: Bool) -> (Change, ambiguous: Bool)? {
        guard let opened = open[lead]?.removeValue(forKey: call), let checkout = roots[lead],
              let status = Self.status(checkout) else { return nil }
        let from = opened.start.addingTimeInterval(-Self.startSlack), to = end
        func changed(_ url: URL) -> Date? {
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  date >= from, date <= to else { return nil }
            return date
        }
        var change = Change()
        var paths: [String] = []
        for (path, kind) in status.entries.sorted(by: { $0.key < $1.key }) {
            guard let modified = changed(URL(fileURLWithPath: checkout).appendingPathComponent(path)),
                  counted[checkout]?[path] != modified else { continue }
            counted[checkout, default: [:]][path] = modified
            if kind == .added { change.added += 1 } else { change.modified += 1 }
            paths.append(path)
        }
        // A deletion leaves no file to date; its folder's change time stands in.
        deletions[checkout] = deletions[checkout, default: []].intersection(status.deleted)
        for path in status.deleted.sorted() where !deletions[checkout]!.contains(path) {
            guard changed(URL(fileURLWithPath: checkout).appendingPathComponent(path).deletingLastPathComponent()) != nil else { continue }
            deletions[checkout]!.insert(path)
            change.deleted += 1
            paths.append(path)
        }
        guard change.count > 0 else { return nil }
        change.paths = Array(paths.prefix(Self.maxPaths))
        let ambiguous = opened.shared || busy || turnOpen.contains { $0 != lead && roots[$0] == checkout }
        return (change, ambiguous)
    }

    enum Kind { case modified, added }
    struct Status { var entries: [String: Kind] = [:]; var deleted = Set<String>() }

    /// `git status` for the whole checkout, untracked files listed one by one.
    static func status(_ root: String) -> Status? {
        guard let data = try? HelperEvidence.git(["status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames"],
                                                 URL(fileURLWithPath: root)) else { return nil }
        var status = Status()
        for record in data.split(separator: 0) {
            let line = String(decoding: record, as: UTF8.self)
            guard line.count > 3 else { continue }
            let code = line.prefix(2), path = String(line.dropFirst(3))
            if path.hasPrefix(".array/") { continue }
            if code.contains("D") { status.deleted.insert(path) }
            else if code == "??" || code.contains("A") { status.entries[path] = .added }
            else { status.entries[path] = .modified }
        }
        return status
    }
}
