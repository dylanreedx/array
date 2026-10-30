import Foundation
import ContinuumRevivedCollaborationProtocol

#if os(macOS)
import CryptoKit

/// Owner-host capture of an immutable file/diff artifact revision (COL-16).
/// Reads the checkout and runs git read-only (`GIT_OPTIONAL_LOCKS=0`, no index
/// refresh). Only explicitly selected paths are read; unselected changes are
/// declared by count, never by name or content.
public struct SharedArtifactProducer {
    public typealias Artifact = Collaboration.Artifact
    public enum DiffRange: Equatable, Sendable { case workingTree, staged, branch(base: String) }
    public enum Selection: Equatable, Sendable {
        case files([String])
        /// `paths == nil` selects every tracked change in the range. Untracked
        /// files are never included unless named in `untracked`.
        case diff(DiffRange, paths: [String]?, untracked: [String])
    }
    public enum Failure: Error, Equatable {
        case notRepository, invalidPath(String), changedDuringCapture, gitFailed(String), tooManyEntries, tooLarge
    }
    public struct Applicability: Equatable, Sendable {
        public let changedPaths: Int
        public let baseMoved: Bool
        public var applies: Bool { changedPaths == 0 && !baseMoved }
    }

    let git: URL
    let timeout: TimeInterval
    let attempts: Int
    /// Checks-only seam between the two reads that must agree.
    let betweenReads: (() -> Void)?

    public init(gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git"), timeout: TimeInterval = 10, attempts: Int = 3,
                betweenReadsForChecks: (() -> Void)? = nil) {
        git = gitExecutableURL; self.timeout = timeout; self.attempts = attempts; betweenReads = betweenReadsForChecks
    }

    /// Two consecutive reads must produce the same claim, or the capture is
    /// retried; after `attempts` it refuses rather than publish a revision
    /// that never existed at any instant.
    public func capture(root: URL, object: SharedArea.ID<SharedArea.Object>, parent: SharedArea.ID<Artifact.RevisionTag>?,
                        selection: Selection, now: Date = Date()) throws -> Artifact.Capture {
        var previous = try read(root: root, selection: selection)
        for _ in 0..<attempts {
            betweenReads?()
            let next = try read(root: root, selection: selection)
            if next == previous {
                guard next.entries.count <= Artifact.Limits.entries else { throw Failure.tooManyEntries }
                let manifest = Artifact.Manifest(object: object, parent: parent, kind: next.kind, base: next.base,
                    declaration: next.declaration, entries: next.entries, capturedAt: Int64((now.timeIntervalSince1970 * 1000).rounded()))
                guard manifest.includedBytes <= Artifact.Limits.revisionBytes else { throw Failure.tooLarge }
                try Artifact.validate(manifest)
                return .init(manifest: manifest, blobs: next.blobs)
            }
            previous = next
        }
        throw Failure.changedDuringCapture
    }

    /// Does `manifest` still describe this checkout? Compares HEAD/merge base
    /// and each selected path's current bytes with the capture's source digest.
    public func applicability(of manifest: Artifact.Manifest, root: URL) throws -> Applicability {
        let checkout = try isolate(root)
        defer { checkout.discard() }
        let head = try headOID(checkout)
        var baseMoved = head != manifest.base.head
        if manifest.declaration.range == .branch, let ref = manifest.base.baseRef {
            baseMoved = baseMoved || (try? text(git(["merge-base", ref, "HEAD"], checkout))) != manifest.base.mergeBase
        }
        var changed = 0
        for entry in manifest.entries where try sourceDigest(root, entry.path) != entry.sourceDigest { changed += 1 }
        return .init(changedPaths: changed, baseMoved: baseMoved)
    }

    // MARK: - One read

    struct Read: Equatable {
        var kind: Artifact.Kind
        var base: Artifact.Base
        var declaration: Artifact.Declaration
        var entries: [Artifact.Entry]
        var blobs: [String: Data]
    }

    func read(root: URL, selection: Selection) throws -> Read {
        let checkout = try isolate(root)
        defer { checkout.discard() }
        let head = try headOID(checkout)
        switch selection {
        case let .files(paths):
            let status = try statusMap(checkout)
            var entries: [Artifact.Entry] = [], blobs: [String: Data] = [:]
            for path in paths {
                try validate(path)
                let change: Artifact.Change
                switch status[path] {
                case "??": change = .untracked
                case let s? where s.contains("D"): change = .deleted
                case let s? where s.contains("A"): change = .added
                case .some: change = .modified
                case nil: change = .unchanged
                }
                let (entry, bytes) = try fileEntry(root, path, change: change, mediaType: "text/plain", payload: { $0 })
                entries.append(entry); if let bytes { blobs[entry.blob!] = bytes }
            }
            let untracked = entries.contains { $0.change == .untracked && $0.coverage == .included }
            return Read(kind: .files, base: .init(head: head),
                declaration: .init(range: .files, includesCommitted: true, includesStaged: true, includesUnstaged: true,
                                   includesUntracked: untracked, omittedChangedPaths: 0, omittedUntrackedPaths: 0),
                entries: entries, blobs: blobs)
        case let .diff(range, selected, untrackedSelection):
            guard let head else { throw Failure.gitFailed("unbornHEAD") }
            var args: [String], declaration: (committed: Bool, staged: Bool, unstaged: Bool), base = Artifact.Base(head: head)
            switch range {
            case .workingTree: args = ["HEAD"]; declaration = (false, true, true)
            case .staged: args = ["--cached", "HEAD"]; declaration = (false, true, false)
            case let .branch(ref):
                guard !ref.hasPrefix("-"), !ref.isEmpty else { throw Failure.invalidPath(ref) }
                let mergeBase = text(try git(["merge-base", ref, "HEAD"], checkout))
                args = [mergeBase, "HEAD"]; declaration = (true, false, false)
                base = .init(head: head, mergeBase: mergeBase, baseRef: ref)
            }
            let changes = try nameStatus(checkout, args)
            let wanted = selected.map(Set.init)
            if let selected { for path in selected { try validate(path) } }
            var entries: [Artifact.Entry] = [], blobs: [String: Data] = [:]
            for change in changes where wanted?.contains(change.path) ?? true {
                var pathspec = [change.path]; if let old = change.previous { pathspec.append(old) }
                let patch = try git(["diff", "--no-ext-diff", "--no-color", "--no-textconv", "--find-renames", "--submodule=short"] + args + ["--"] + pathspec,
                                    checkout, limit: Artifact.Limits.blobBytes)
                let coverage: Artifact.Coverage
                if patch.overflowed { coverage = .oversized }
                else if patch.data.range(of: Data("\nSubproject commit ".utf8)) != nil { coverage = .submodule }
                else if patch.data.range(of: Data("\nBinary files ".utf8)) != nil || patch.data.range(of: Data("GIT binary patch".utf8)) != nil
                            || String(data: patch.data, encoding: .utf8) == nil { coverage = .binary }
                else { coverage = .included }
                let digest = coverage == .included ? Artifact.digest(patch.data) : nil
                if let digest { blobs[digest] = patch.data }
                entries.append(.init(path: change.path, previousPath: change.previous, change: change.kind, coverage: coverage,
                    blob: digest, length: digest == nil ? nil : patch.data.count, mediaType: digest == nil ? nil : "text/x-diff",
                    sourceDigest: try sourceDigest(root, change.path)))
            }
            let changedPaths = Set(changes.map(\.path))
            for path in selected ?? [] where !changedPaths.contains(path) {
                entries.append(.init(path: path, change: .unchanged, coverage: .unavailable, sourceDigest: try sourceDigest(root, path)))
            }
            var untrackedAll: [String] = []
            if range == .workingTree {
                untrackedAll = try git(["ls-files", "--others", "--exclude-standard", "-z"], checkout, limit: 4 << 20).data
                    .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            }
            var includedUntracked = 0
            for path in untrackedSelection {
                try validate(path)
                guard untrackedAll.contains(path) else {
                    entries.append(.init(path: path, change: .untracked, coverage: .unavailable, sourceDigest: try sourceDigest(root, path))); continue
                }
                let (entry, bytes) = try fileEntry(root, path, change: .untracked, mediaType: "text/x-diff", payload: { Self.newFilePatch(path, $0) })
                entries.append(entry)
                if let bytes { blobs[entry.blob!] = bytes; includedUntracked += 1 }
            }
            let selectedChanged = changes.filter { wanted?.contains($0.path) ?? true }.count
            return Read(kind: .diff, base: base,
                declaration: .init(range: range == .workingTree ? .workingTree : range == .staged ? .staged : .branch,
                    includesCommitted: declaration.committed, includesStaged: declaration.staged, includesUnstaged: declaration.unstaged,
                    includesUntracked: includedUntracked > 0, omittedChangedPaths: changes.count - selectedChanged,
                    omittedUntrackedPaths: untrackedAll.filter { !untrackedSelection.contains($0) }.count),
                entries: entries, blobs: blobs)
        }
    }

    /// Reads one selected working file under the bounded publication rules.
    private func fileEntry(_ root: URL, _ path: String, change: Artifact.Change, mediaType: String,
                           payload: (Data) -> Data) throws -> (Artifact.Entry, Data?) {
        let url = root.appendingPathComponent(path)
        func entry(_ coverage: Artifact.Coverage, _ digest: String = "") -> (Artifact.Entry, Data?) {
            (.init(path: path, change: change, coverage: coverage, sourceDigest: digest), nil)
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path), let type = attributes[.type] as? FileAttributeType else {
            return entry(.unavailable)
        }
        if type == .typeSymbolicLink { return entry(.symlink) }
        if type == .typeDirectory { return entry(FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) ? .submodule : .unavailable) }
        guard type == .typeRegular else { return entry(.unavailable) }
        let source = try sourceDigest(root, path)
        guard let size = attributes[.size] as? Int, size <= Artifact.Limits.blobBytes, let bytes = try? Data(contentsOf: url) else { return entry(.oversized, source) }
        guard !bytes.prefix(8000).contains(0), String(data: bytes, encoding: .utf8) != nil else { return entry(.binary, source) }
        guard Artifact.digest(bytes) == source else { return entry(.unavailable, source) }
        let published = payload(bytes)
        guard published.count <= Artifact.Limits.blobBytes else { return entry(.oversized, source) }
        let digest = Artifact.digest(published)
        return (.init(path: path, change: change, coverage: .included, blob: digest, length: published.count, mediaType: mediaType, sourceDigest: source), published)
    }

    static func newFilePatch(_ path: String, _ bytes: Data) -> Data {
        let text = String(decoding: bytes, as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        let trailingNewline = text.hasSuffix("\n")
        if trailingNewline { lines.removeLast() }
        var out = "diff --git a/\(path) b/\(path)\nnew file mode 100644\n--- /dev/null\n+++ b/\(path)\n"
        if !lines.isEmpty {
            out += "@@ -0,0 +1\(lines.count == 1 ? "" : ",\(lines.count)") @@\n"
            out += lines.map { "+" + $0 }.joined(separator: "\n") + "\n"
            if !trailingNewline { out += "\\ No newline at end of file\n" }
        }
        return Data(out.utf8)
    }

    /// Repository-relative, inside the work tree, never through a symlinked
    /// parent and never into `.git`.
    private func validate(_ path: String) throws {
        guard Artifact.isPortablePath(path), path.split(separator: "/").first != ".git" else { throw Failure.invalidPath(path) }
    }

    /// SHA-256 of a regular working file's bytes, streamed; "" when absent or
    /// not a regular file, or when reached through a symlinked parent.
    func sourceDigest(_ root: URL, _ path: String) throws -> String {
        let parts = path.split(separator: "/").map(String.init)
        var url = root
        for (index, part) in parts.enumerated() {
            url = url.appendingPathComponent(part)
            guard let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType else { return "" }
            if index < parts.count - 1 ? type != .typeDirectory : type != .typeRegular { return "" }
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func headOID(_ root: Checkout) throws -> String? {
        let result = try run(["rev-parse", "--verify", "-q", "HEAD"], root, limit: 4096)
        return result.status == 0 ? text(result) : nil
    }
    private func statusMap(_ root: Checkout) throws -> [String: String] {
        let out = try git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], root, limit: 4 << 20).data
        var map: [String: String] = [:]
        var records = out.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }[...]
        while let record = records.popFirst(), record.count > 3 {
            let code = String(record.prefix(2)), path = String(record.dropFirst(3))
            map[path] = code
            if code.contains("R") || code.contains("C") { _ = records.popFirst() }
        }
        return map
    }
    private struct NameStatus { let path: String; let previous: String?; let kind: Artifact.Change }
    private func nameStatus(_ root: Checkout, _ args: [String]) throws -> [NameStatus] {
        let out = try git(["diff", "--no-ext-diff", "--no-color", "--find-renames", "--name-status", "-z"] + args, root, limit: 4 << 20).data
        var fields = out.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }[...]
        var result: [NameStatus] = []
        while let status = fields.popFirst(), let first = fields.popFirst() {
            switch status.first {
            case "R", "C":
                guard let second = fields.popFirst() else { break }
                result.append(.init(path: second, previous: first, kind: .renamed))
            case "A": result.append(.init(path: first, previous: nil, kind: .added))
            case "D": result.append(.init(path: first, previous: nil, kind: .deleted))
            default: result.append(.init(path: first, previous: nil, kind: .modified))
            }
        }
        return result
    }

    /// `git diff` refreshes stale stat info and REWRITES the index even with
    /// optional locks off, so every read runs on a private copy of it.
    struct Checkout {
        let root: URL
        let index: URL?
        func discard() { if let index { try? FileManager.default.removeItem(at: index.deletingLastPathComponent()) } }
    }
    private func isolate(_ root: URL) throws -> Checkout {
        let plain = Checkout(root: root, index: nil)
        guard (try? git(["rev-parse", "--is-inside-work-tree"], plain)).map(text) == "true" else { throw Failure.notRepository }
        var path = text(try git(["rev-parse", "--git-path", "index"], plain))
        if !path.hasPrefix("/") { path = root.appendingPathComponent(path).path }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("array-artifact-index-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let copy = scratch.appendingPathComponent("index")
        if FileManager.default.fileExists(atPath: path) { try FileManager.default.copyItem(atPath: path, toPath: copy.path) }
        return Checkout(root: root, index: copy)
    }

    struct Output { let status: Int32; let data: Data; let overflowed: Bool }
    private func text(_ output: Output) -> String { String(decoding: output.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    private func git(_ arguments: [String], _ root: Checkout, limit: Int = 1 << 20) throws -> Output {
        let output = try run(arguments, root, limit: limit)
        guard output.status == 0 || output.overflowed else { throw Failure.gitFailed(arguments.first ?? "git") }
        return output
    }
    /// Bounded, timed, read-only git. Optional locks are off so status/diff
    /// never rewrite the source index while the owner keeps working.
    private func run(_ arguments: [String], _ checkout: Checkout, limit: Int) throws -> Output {
        let process = Process()
        process.executableURL = git
        // Pin output-shaping settings a personal config could change.
        process.arguments = ["--no-optional-locks", "-c", "core.quotepath=off", "-c", "core.fsmonitor=false", "-c", "color.ui=false",
                             "-c", "diff.noprefix=false", "-c", "diff.mnemonicPrefix=false", "-c", "diff.relative=false"] + arguments
        process.currentDirectoryURL = checkout.root
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment.removeValue(forKey: "GIT_DIR"); environment.removeValue(forKey: "GIT_WORK_TREE"); environment.removeValue(forKey: "GIT_INDEX_FILE")
        if let index = checkout.index { environment["GIT_INDEX_FILE"] = index.path }
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // A silent, hung git still ends: the watchdog closes its output.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }
        var data = Data(), overflowed = false
        let handle = stdout.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > limit { overflowed = true; process.terminate(); break }
        }
        process.waitUntilExit()
        if process.terminationReason == .uncaughtSignal && !overflowed { throw Failure.gitFailed("timeout") }
        return .init(status: process.terminationStatus, data: overflowed ? Data() : data, overflowed: overflowed)
    }
}
#endif
