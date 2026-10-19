import Foundation

public struct AgentFileIndexEntry: Equatable, Sendable {
    public let relativePath: String
    public let fileURL: URL
    public let isDirectory: Bool

    public init(relativePath: String, fileURL: URL, isDirectory: Bool) {
        self.relativePath = relativePath
        self.fileURL = fileURL
        self.isDirectory = isDirectory
    }
}

/// Bounded file discovery for managed-agent `@` completion. Browsing begins at
/// the checkout but may move to an explicit host-local directory outside it.
/// Cache keys include agent/backend/root identity so scopes never cross tiles.
public actor AgentFileIndex {
    public typealias PathDiscovery = @Sendable (_ root: URL) -> [String]?

    private struct CacheKey: Hashable {
        let agentID: AgentID
        let backend: AgentBackend
        let root: String
    }

    /// An entry with what every query needs from it, worked out once when the
    /// index is built: its case- and diacritic-folded path, and the guarantee
    /// that a file is one a prompt can reference. Doing either per keystroke,
    /// and ranking through `String`, cost a 45k-entry folder half a second a key.
    private struct Indexed {
        let entry: AgentFileIndexEntry
        /// `canonical` of the relative path as UTF-8, without a trailing slash.
        let folded: [UInt8]
    }

    private struct Ranked {
        let entry: AgentFileIndexEntry
        let tier: Int
        let gap: Int
    }

    private let entryLimit: Int
    private let resultLimit: Int
    private let pathDiscovery: PathDiscovery?
    private var cache: [CacheKey: [Indexed]] = [:]

    public init(
        entryLimit: Int = 50_000,
        resultLimit: Int = 50,
        pathDiscovery: PathDiscovery? = nil
    ) {
        self.entryLimit = max(1, entryLimit)
        self.resultLimit = max(1, resultLimit)
        self.pathDiscovery = pathDiscovery
    }

    public func invalidate(context: AgentCompletionContext? = nil) {
        guard let context else {
            cache.removeAll()
            return
        }
        cache = cache.filter { key, _ in
            key.agentID != context.agentID || key.backend != context.backend
        }
    }

    public func entries(for context: AgentCompletionContext) async -> [AgentFileIndexEntry] {
        guard context.trustState == .trusted, !Task.isCancelled else { return [] }
        return await indexed(for: context, root: context.checkoutRoot.standardizedFileURL).map(\.entry)
    }

    /// Builds the checkout's index ahead of the first `@`, which otherwise waits
    /// on the whole scan (about 4s for a 45k-entry folder that is not a repo).
    public func prepare(for context: AgentCompletionContext) async {
        guard context.trustState == .trusted, !Task.isCancelled else { return }
        _ = await indexed(for: context, root: context.checkoutRoot.standardizedFileURL)
    }

    private func indexed(
        for context: AgentCompletionContext,
        root: URL
    ) async -> [Indexed] {
        let root = root.standardizedFileURL
        let key = cacheKey(for: context, root: root)
        if let cached = cache[key] { return cached }
        guard isDirectory(root), !isSymbolicLink(root) else { return [] }

        // Finish and cache a scan once it has started, even when the query that
        // initiated it has already been superseded by another keystroke. The
        // actor serializes requests: abandoning materialization here made every
        // queued query start the same full repository scan again, so normal
        // typing could keep `@` completion permanently behind the editor.
        let entries: [Indexed]
        if let paths = pathDiscovery?(root) ?? gitPaths(root: root) {
            entries = materialize(paths: paths, root: root)
        } else {
            entries = walk(root: root)
        }
        cache[key] = entries
        return entries
    }

    public func suggestions(for query: AgentCompletionQuery) async -> [AgentCompletion] {
        guard query.trigger == "@", let context = query.context,
              context.trustState == .trusted, !Task.isCancelled else { return [] }
        let checkoutRoot = context.checkoutRoot.standardizedFileURL
        let scopeURL: URL
        if let navigationPath = query.navigationPath, navigationPath.hasPrefix("/") {
            scopeURL = URL(fileURLWithPath: navigationPath, isDirectory: true).standardizedFileURL
        } else if let navigationPath = query.navigationPath, !navigationPath.isEmpty {
            scopeURL = checkoutRoot.appendingPathComponent(
                navigationPath,
                isDirectory: true
            ).standardizedFileURL
        } else {
            scopeURL = checkoutRoot
        }
        guard isDirectory(scopeURL), !isSymbolicLink(scopeURL) else { return [] }

        let needle = canonical(query.text)
        let isInsideCheckout = scopeURL.path == checkoutRoot.path
            || scopeURL.path.hasPrefix(checkoutRoot.path + "/")
        let indexRoot = isInsideCheckout ? checkoutRoot : scopeURL
        let scope = isInsideCheckout && scopeURL.path != checkoutRoot.path
            ? String(scopeURL.path.dropFirst(checkoutRoot.path.count + 1))
            : ""
        // Outside the checkout, act like shell path completion: filter the
        // current directory's immediate children. Recursively indexing a broad
        // parent such as the user's home or Documents directory makes a typed
        // relative path appear to hang and searches far beyond the requested
        // scope. Checkout-local fuzzy search keeps its existing recursive index.
        let indexed = !isInsideCheckout
            ? immediateEntries(root: scopeURL)
            : await indexed(for: context, root: indexRoot)
        guard !Task.isCancelled else { return [] }
        let visible = scope.isEmpty ? indexed : indexed.filter { path($0.entry.relativePath, isInside: scope) }
        let foldedScope = Array(canonical(scope).utf8)
        let foldedNeedle = Array(needle.utf8)

        let selected: [Ranked]
        if needle.isEmpty {
            selected = visible.compactMap { item in
                let entry = item.entry
                let local = localPath(entry.relativePath, inside: scope)
                guard !local.isEmpty,
                      !local.dropLast(entry.isDirectory ? 1 : 0).contains("/")
                else { return nil }
                return Ranked(entry: entry, tier: entry.isDirectory ? 0 : 1, gap: 0)
            }
        } else {
            selected = visible.compactMap { item in
                let local: ArraySlice<UInt8>
                if foldedScope.isEmpty {
                    local = item.folded[...]
                } else if item.folded.count > foldedScope.count,
                          item.folded[foldedScope.count] == UInt8(ascii: "/"),
                          item.folded.starts(with: foldedScope) {
                    local = item.folded[(foldedScope.count + 1)...]
                } else {
                    local = Array(canonical(localPath(item.entry.relativePath, inside: scope))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/")).utf8)[...]
                }
                guard let rank = fuzzyRank(needle: foldedNeedle, folded: local) else { return nil }
                return Ranked(entry: item.entry, tier: rank.tier, gap: rank.gap)
            }
        }

        // The index is a snapshot, so a path deleted since may still be in it.
        // Only the rows that will be shown pay for checking.
        var results: [AgentCompletion] = []
        for ranked in selected.sorted(by: rankedBefore) where results.count < resultLimit {
            guard FileManager.default.fileExists(atPath: ranked.entry.fileURL.path),
                  let completion = completion(for: ranked, context: context, root: indexRoot, scope: scope)
            else { continue }
            results.append(completion)
        }
        return results
    }

    private func immediateEntries(root: URL) -> [Indexed] {
        let excluded = Set([".git", ".array", ".build", "build", "DerivedData", "node_modules", ".cache"])
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]
        let children = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        )) ?? []
        return children.compactMap { child in
            guard let values = try? child.resourceValues(forKeys: keys),
                  values.isHidden != true,
                  values.isSymbolicLink != true,
                  !excluded.contains(child.lastPathComponent) else { return nil }
            return indexedEntry(
                relativePath: child.lastPathComponent,
                fileURL: child.standardizedFileURL,
                isDirectory: values.isDirectory == true
            )
        }
    }

    /// Nil for a file no prompt can reference, so no query has to ask again.
    private func indexedEntry(relativePath: String, fileURL: URL, isDirectory: Bool) -> Indexed? {
        guard isDirectory || AgentFileReferenceRules.referenceableContentType(for: fileURL) != nil else { return nil }
        return Indexed(
            entry: AgentFileIndexEntry(
                relativePath: isDirectory ? relativePath + "/" : relativePath,
                fileURL: fileURL,
                isDirectory: isDirectory
            ),
            folded: Array(canonical(relativePath).utf8)
        )
    }

    private func completion(
        for ranked: Ranked,
        context: AgentCompletionContext,
        root: URL,
        scope: String
    ) -> AgentCompletion? {
        let entry = ranked.entry
        let local = localPath(entry.relativePath, inside: scope).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let checkoutRoot = context.checkoutRoot.standardizedFileURL
        let displayPath: String
        if let checkoutRelative = relativePath(of: entry.fileURL, root: checkoutRoot) {
            displayPath = checkoutRelative
        } else {
            displayPath = entry.fileURL.standardizedFileURL.path
        }
        let provenance = AgentCompletionProvenance(
            backend: context.backend,
            scope: .project,
            sourceIdentifier: displayPath,
            invocationName: local
        )
        let payload: AgentCompletionPayload
        if entry.isDirectory {
            payload = .directory(DirectoryNavigationTarget(directoryURL: entry.fileURL))
        } else {
            guard let contentType = AgentFileReferenceRules.referenceableContentType(for: entry.fileURL) else { return nil }
            payload = .file(AgentPromptFileReference(
                displayName: entry.fileURL.lastPathComponent,
                contentType: contentType.identifier,
                fileURL: entry.fileURL
            ))
        }
        return AgentCompletion(
            id: "file:\(entry.fileURL.standardizedFileURL.path)",
            title: entry.fileURL.lastPathComponent + (entry.isDirectory ? "/" : ""),
            detail: displayPath,
            insertionText: "@" + displayPath,
            score: max(0, 10_000 - ranked.tier * 1_000 - min(ranked.gap, 999)),
            payload: payload,
            provenance: provenance
        )
    }

    /// Discovered paths (git's or an injected discovery's) become entries with
    /// one `lstat` each. Their parent directories are derived, not re-read: a
    /// directory holding a real, non-symlinked file is a directory.
    private func materialize(paths: [String], root: URL) -> [Indexed] {
        var kinds: [String: Bool] = [:]
        for rawPath in paths.prefix(entryLimit) {
            let relative = normalizedRelativePath(rawPath)
            guard !relative.isEmpty,
                  let url = containedURL(relativePath: relative, root: root),
                  let isDirectory = nonSymlinkKind(url) else { continue }
            // git lists a nested repository as one directory entry; it was never
            // offered, since nothing inside it is indexed.
            if !isDirectory { kinds[relative] = false }
            var parent = (relative as NSString).deletingLastPathComponent
            while !parent.isEmpty && parent != "." && kinds[parent] == nil {
                kinds[parent] = true
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        return kinds.keys.sorted().prefix(entryLimit).compactMap { relative in
            guard let url = containedURL(relativePath: relative, root: root) else { return nil }
            return indexedEntry(relativePath: relative, fileURL: url, isDirectory: kinds[relative] == true)
        }
    }

    /// Whether `url` is a directory, from one `lstat`; nil when it is missing or
    /// a symbolic link.
    private func nonSymlinkKind(_ url: URL) -> Bool? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return nil
        case S_IFDIR: return true
        default: return false
        }
    }

    /// `git ls-files` when it is available, nil otherwise — the caller then walks
    /// the directory tree itself (`walk`), the same path a checkout with
    /// no `.git` already takes.
    ///
    /// Subprocess-free on iOS: `Process` does not exist there, and this file lives
    /// in Core, which is shared with the iOS target. Returning nil is not a
    /// degradation of correctness — it selects the FileManager walk, which honours
    /// the same exclusions — so the only loss is git's ignore rules on a platform
    /// that cannot spawn git in the first place.
    private func gitPaths(root: URL) -> [String]? {
#if os(macOS)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root.path, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
#else
        return nil
#endif
    }

    /// The tree walk for a folder git cannot list. It already knows each
    /// child's kind, so its entries need no second look at the disk.
    private func walk(root: URL) -> [Indexed] {
        let excluded = Set([".git", ".array", ".build", "build", "DerivedData", "node_modules", ".cache"])
        var queue = [root]
        var walked = 0
        var result: [Indexed] = []
        while !queue.isEmpty && walked < entryLimit {
            let directory = queue.removeFirst()
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]
            let children = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants]
            ))?.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            for child in children where walked < entryLimit {
                guard let values = try? child.resourceValues(forKeys: keys),
                      values.isHidden != true,
                      values.isSymbolicLink != true,
                      !excluded.contains(child.lastPathComponent),
                      let relative = relativePath(of: child, root: root) else { continue }
                walked += 1
                let isDirectory = values.isDirectory == true
                if let item = indexedEntry(
                    relativePath: relative, fileURL: child.standardizedFileURL, isDirectory: isDirectory
                ) { result.append(item) }
                if isDirectory { queue.append(child) }
            }
        }
        return result
    }

    /// Both sides are `canonical` UTF-8; `candidate` has no leading or
    /// trailing slash. Gaps count bytes, which only reorders ties between
    /// non-ASCII names.
    private func fuzzyRank(needle: [UInt8], folded candidate: ArraySlice<UInt8>) -> (tier: Int, gap: Int)? {
        let slash = UInt8(ascii: "/")
        let basenameStart = candidate.lastIndex(of: slash).map { $0 + 1 } ?? candidate.startIndex
        let basename = candidate[basenameStart...]
        if basename.elementsEqual(needle) { return (0, 0) }
        if basename.starts(with: needle) { return (1, basename.count - needle.count) }
        if let gap = subsequenceGap(needle: needle, candidate: basename) { return (2, gap) }
        var componentStart = candidate.startIndex
        while componentStart < candidate.endIndex {
            if candidate[componentStart...].starts(with: needle) { return (3, candidate.count - needle.count) }
            guard let next = candidate[componentStart...].firstIndex(of: slash) else { break }
            componentStart = next + 1
        }
        if let gap = subsequenceGap(needle: needle, candidate: candidate) { return (4, gap) }
        return nil
    }

    private func subsequenceGap(needle: [UInt8], candidate: ArraySlice<UInt8>) -> Int? {
        var index = needle.startIndex
        var first = -1
        var last = -1
        for position in candidate.indices where index < needle.endIndex {
            if candidate[position] == needle[index] {
                if first < 0 { first = position }
                last = position
                index += 1
            }
        }
        guard index == needle.endIndex, first >= 0 else { return nil }
        return last - first + 1 - needle.count
    }

    private func rankedBefore(_ lhs: Ranked, _ rhs: Ranked) -> Bool {
        if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
        if lhs.gap != rhs.gap { return lhs.gap < rhs.gap }
        if lhs.entry.isDirectory != rhs.entry.isDirectory { return lhs.entry.isDirectory }
        if lhs.entry.relativePath.count != rhs.entry.relativePath.count {
            return lhs.entry.relativePath.count < rhs.entry.relativePath.count
        }
        return lhs.entry.relativePath < rhs.entry.relativePath
    }

    private func cacheKey(for context: AgentCompletionContext, root: URL) -> CacheKey {
        CacheKey(
            agentID: context.agentID,
            backend: context.backend,
            root: root.standardizedFileURL.path
        )
    }

    private func canonical(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private func normalizedRelativePath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }

    private func containedURL(relativePath: String, root: URL) -> URL? {
        let candidate = relativePath.isEmpty ? root : root.appendingPathComponent(relativePath)
        let standardized = candidate.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard standardized.path == rootPath || standardized.path.hasPrefix(rootPath + "/") else { return nil }
        return standardized
    }

    private func relativePath(of url: URL, root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func path(_ path: String, isInside scope: String) -> Bool {
        scope.isEmpty || path == scope || path.hasPrefix(scope + "/")
    }

    private func localPath(_ path: String, inside scope: String) -> String {
        guard !scope.isEmpty, path.hasPrefix(scope + "/") else { return path }
        return String(path.dropFirst(scope.count + 1))
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}

public struct AgentFileCompletionProvider: AgentCompletionProvider {
    public let providerID: String
    public let trigger: Character = "@"
    private let index: AgentFileIndex

    public init(providerID: String = "checkout.files", index: AgentFileIndex = AgentFileIndex()) {
        self.providerID = providerID
        self.index = index
    }

    public func suggestions(for query: AgentCompletionQuery) async -> [AgentCompletion] {
        await index.suggestions(for: query)
    }

    public func prepare(for context: AgentCompletionContext) async {
        await index.prepare(for: context)
    }
}
