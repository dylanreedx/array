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
    private struct CacheKey: Hashable {
        let agentID: AgentID
        let backend: AgentBackend
        let root: String
    }

    private struct Ranked {
        let entry: AgentFileIndexEntry
        let tier: Int
        let gap: Int
    }

    private let entryLimit: Int
    private let resultLimit: Int
    private var cache: [CacheKey: [AgentFileIndexEntry]] = [:]

    public init(entryLimit: Int = 50_000, resultLimit: Int = 50) {
        self.entryLimit = max(1, entryLimit)
        self.resultLimit = max(1, resultLimit)
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
        return await entries(for: context, root: context.checkoutRoot.standardizedFileURL)
    }

    private func entries(
        for context: AgentCompletionContext,
        root: URL
    ) async -> [AgentFileIndexEntry] {
        let root = root.standardizedFileURL
        let key = cacheKey(for: context, root: root)
        if let cached = cache[key] { return cached }
        guard isDirectory(root), !isSymbolicLink(root) else { return [] }

        let paths = gitPaths(root: root) ?? fallbackPaths(root: root)
        guard !Task.isCancelled else { return [] }
        let entries = materialize(paths: paths, root: root)
        guard !Task.isCancelled else { return [] }
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
            : await entries(for: context, root: indexRoot)
        guard !Task.isCancelled else { return [] }
        let visible = indexed.filter { entry in
            guard FileManager.default.fileExists(atPath: entry.fileURL.path) else { return false }
            guard entry.isDirectory || AgentFileReferenceRules.referenceableContentType(for: entry.fileURL) != nil else { return false }
            return path(entry.relativePath, isInside: scope)
        }

        let selected: [Ranked]
        if needle.isEmpty {
            selected = visible.compactMap { entry in
                let local = localPath(entry.relativePath, inside: scope)
                guard !local.isEmpty,
                      !local.dropLast(entry.isDirectory ? 1 : 0).contains("/")
                else { return nil }
                return Ranked(entry: entry, tier: entry.isDirectory ? 0 : 1, gap: 0)
            }
        } else {
            selected = visible.compactMap { entry in
                let local = localPath(entry.relativePath, inside: scope)
                guard let rank = fuzzyRank(needle: needle, path: local) else { return nil }
                return Ranked(entry: entry, tier: rank.tier, gap: rank.gap)
            }
        }

        return selected.sorted(by: rankedBefore)
            .prefix(resultLimit)
            .compactMap { completion(for: $0, context: context, root: indexRoot, scope: scope) }
    }

    private func immediateEntries(root: URL) -> [AgentFileIndexEntry] {
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
            let isDirectory = values.isDirectory == true
            return AgentFileIndexEntry(
                relativePath: child.lastPathComponent + (isDirectory ? "/" : ""),
                fileURL: child.standardizedFileURL,
                isDirectory: isDirectory
            )
        }
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

    private func materialize(paths: [String], root: URL) -> [AgentFileIndexEntry] {
        var allPaths: Set<String> = []
        for rawPath in paths.prefix(entryLimit) {
            guard !Task.isCancelled else { return [] }
            let relative = normalizedRelativePath(rawPath)
            guard !relative.isEmpty,
                  let url = containedURL(relativePath: relative, root: root),
                  FileManager.default.fileExists(atPath: url.path),
                  !isSymbolicLink(url) else { continue }
            allPaths.insert(relative)
            var parent = (relative as NSString).deletingLastPathComponent
            while !parent.isEmpty && parent != "." {
                allPaths.insert(parent + "/")
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        return allPaths.sorted().prefix(entryLimit).compactMap { relative in
            let directory = relative.hasSuffix("/")
            let clean = relative.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = containedURL(relativePath: clean, root: root),
                  directory ? isDirectory(url) : !isDirectory(url) else { return nil }
            return AgentFileIndexEntry(relativePath: directory ? clean + "/" : clean, fileURL: url, isDirectory: directory)
        }
    }

    /// `git ls-files` when it is available, nil otherwise — the caller then walks
    /// the directory tree itself (`fallbackPaths`), the same path a checkout with
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

    private func fallbackPaths(root: URL) -> [String] {
        let excluded = Set([".git", ".array", ".build", "build", "DerivedData", "node_modules", ".cache"])
        var queue = [root]
        var result: [String] = []
        while !queue.isEmpty && result.count < entryLimit && !Task.isCancelled {
            let directory = queue.removeFirst()
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]
            let children = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants]
            ))?.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            for child in children where result.count < entryLimit {
                guard let values = try? child.resourceValues(forKeys: keys),
                      values.isHidden != true,
                      values.isSymbolicLink != true,
                      !excluded.contains(child.lastPathComponent),
                      let relative = relativePath(of: child, root: root) else { continue }
                result.append(relative)
                if values.isDirectory == true { queue.append(child) }
            }
        }
        return result
    }

    private func fuzzyRank(needle: String, path: String) -> (tier: Int, gap: Int)? {
        let candidate = canonical(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        let basename = canonical((candidate as NSString).lastPathComponent)
        if basename == needle { return (0, 0) }
        if basename.hasPrefix(needle) { return (1, basename.count - needle.count) }
        if let gap = subsequenceGap(needle: needle, candidate: basename) { return (2, gap) }
        if candidate.split(separator: "/").contains(where: { $0.hasPrefix(needle) }) {
            return (3, candidate.count - needle.count)
        }
        if let gap = subsequenceGap(needle: needle, candidate: candidate) { return (4, gap) }
        return nil
    }

    private func subsequenceGap(needle: String, candidate: String) -> Int? {
        var index = needle.startIndex
        var first: String.Index?
        var last: String.Index?
        for position in candidate.indices where index < needle.endIndex {
            if candidate[position] == needle[index] {
                first = first ?? position
                last = position
                index = needle.index(after: index)
            }
        }
        guard index == needle.endIndex, let first, let last else { return nil }
        return candidate.distance(from: first, to: last) + 1 - needle.count
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
}
